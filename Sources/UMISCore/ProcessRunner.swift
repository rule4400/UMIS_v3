import Darwin
import Dispatch
import Foundation

public enum ProcessTimeoutAction: Sendable {
    /// Appropriate for non-destructive helpers such as info and eject.
    case terminateProcessGroup
    /// Appropriate once a filesystem erase has started: report unknown, but never imply that killing is safe.
    case leaveRunningAndReportUnknown
}

public struct ProcessRequest: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var timeout: TimeInterval
    public var timeoutAction: ProcessTimeoutAction
    public var maximumCapturedOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        timeoutAction: ProcessTimeoutAction = .terminateProcessGroup,
        maximumCapturedOutputBytes: Int = 65_536
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.timeoutAction = timeoutAction
        self.maximumCapturedOutputBytes = maximumCapturedOutputBytes
    }
}

public struct ProcessExecutionResult: Sendable, Hashable {
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var standardOutput: Data
    public var standardError: Data
    public var timedOut: Bool

    public init(
        exitCode: Int32?,
        terminationSignal: Int32?,
        standardOutput: Data,
        standardError: Data,
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessExecutionResult
}

/// Fixed-executable process runner. It never constructs a shell command, gives every child its own
/// process group, bounds captured output, and has explicit destructive-operation timeout semantics.
public struct POSIXProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessExecutionResult {
        guard request.executableURL.isFileURL, request.executableURL.path.hasPrefix("/"), request.timeout > 0 else {
            throw UMISCoreError.invalidPlan("Process executable must be an absolute file URL and timeout must be positive")
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: false)
        let stdoutURL = tempRoot.appendingPathComponent("stdout")
        let stderrURL = tempRoot.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            try? FileManager.default.removeItem(at: tempRoot)
            throw UMISCoreError.backendFailure("Unable to create bounded process output files")
        }
        let stdoutFD: Int32 = stdoutURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        }
        let stderrFD: Int32 = stderrURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        }
        guard stdoutFD >= 0, stderrFD >= 0 else {
            if stdoutFD >= 0 { Darwin.close(stdoutFD) }
            if stderrFD >= 0 { Darwin.close(stderrFD) }
            try? FileManager.default.removeItem(at: tempRoot)
            throw UMISCoreError.backendFailure("Unable to open process output files")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutFD)
        posix_spawn_file_actions_addclose(&actions, stderrFD)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argumentStrings = [request.executableURL.path] + request.arguments
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        arguments.append(nil)
        let environmentStrings = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        environment.append(nil)
        defer {
            for pointer in arguments where pointer != nil { free(pointer) }
            for pointer in environment where pointer != nil { free(pointer) }
        }

        var processID: pid_t = 0
        let spawnCode: Int32 = request.executableURL.path.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processID,
                        executable,
                        &actions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        Darwin.close(stdoutFD)
        Darwin.close(stderrFD)
        guard spawnCode == 0 else {
            try? FileManager.default.removeItem(at: tempRoot)
            throw UMISCoreError.posix(operation: "posix_spawn", code: spawnCode, path: request.executableURL.path)
        }

        let completion = ProcessCompletion(
            processID: processID,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            tempRoot: tempRoot,
            maximumOutputBytes: max(0, request.maximumCapturedOutputBytes),
            timeoutAction: request.timeoutAction
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.start(timeout: request.timeout, continuation: continuation)
            }
        } onCancel: {
            completion.cancelByCaller()
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let processID: pid_t
    private let stdoutURL: URL
    private let stderrURL: URL
    private let tempRoot: URL
    private let maximumOutputBytes: Int
    private let timeoutAction: ProcessTimeoutAction
    private var continuation: CheckedContinuation<ProcessExecutionResult, Error>?
    private var processSource: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var responseDelivered = false
    private var processExited = false
    private var timedOut = false
    private var cancelledByCaller = false

    init(
        processID: pid_t,
        stdoutURL: URL,
        stderrURL: URL,
        tempRoot: URL,
        maximumOutputBytes: Int,
        timeoutAction: ProcessTimeoutAction
    ) {
        self.processID = processID
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.tempRoot = tempRoot
        self.maximumOutputBytes = maximumOutputBytes
        self.timeoutAction = timeoutAction
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<ProcessExecutionResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        let queue = DispatchQueue(label: "jp.rinkan.umis.process.\(processID)")
        let source = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        lock.lock()
        processSource = source
        self.timer = timer
        lock.unlock()
        source.setEventHandler { [self] in processDidExit() }
        timer.setEventHandler { [self] in didTimeout() }
        source.resume()
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
    }

    func cancelByCaller() {
        if timeoutAction == .terminateProcessGroup {
            lock.lock()
            guard !responseDelivered else { lock.unlock(); return }
            cancelledByCaller = true
            timer?.cancel()
            timer = nil
            lock.unlock()
            terminateProcessGroup()
        } else {
            // Once destructive filesystem work starts, task cancellation cannot prove it stopped.
            lock.lock()
            timedOut = true
            lock.unlock()
            deliver(.success(ProcessExecutionResult(
                exitCode: nil,
                terminationSignal: nil,
                standardOutput: readBounded(stdoutURL),
                standardError: readBounded(stderrURL),
                timedOut: true
            )))
        }
    }

    private func didTimeout() {
        if timeoutAction == .terminateProcessGroup {
            lock.lock()
            guard !responseDelivered else { lock.unlock(); return }
            timedOut = true
            timer?.cancel()
            timer = nil
            lock.unlock()
            // Keep the continuation pending until the process source observes exit and waitpid has
            // reaped the child. Callers therefore retain their destructive quiesce reservation.
            terminateProcessGroup()
            return
        }
        lock.lock()
        timedOut = true
        lock.unlock()
        let result = ProcessExecutionResult(
            exitCode: nil,
            terminationSignal: nil,
            standardOutput: readBounded(stdoutURL),
            standardError: readBounded(stderrURL),
            timedOut: true
        )
        deliver(.success(result))
    }

    private func processDidExit() {
        var status: Int32 = 0
        while Darwin.waitpid(processID, &status, 0) < 0, errno == EINTR {}
        let signal = status & 0x7f
        let exitCode: Int32? = signal == 0 ? (status >> 8) & 0xff : nil
        let terminationSignal: Int32? = signal == 0 ? nil : signal
        lock.lock()
        processExited = true
        let wasTimedOut = timedOut
        let wasCancelled = cancelledByCaller
        lock.unlock()
        if wasCancelled {
            deliver(.failure(CancellationError()))
        } else {
            deliver(.success(ProcessExecutionResult(
                exitCode: exitCode,
                terminationSignal: terminationSignal,
                standardOutput: readBounded(stdoutURL),
                standardError: readBounded(stderrURL),
                timedOut: wasTimedOut
            )))
        }
        cleanupIfPossible()
    }

    private func terminateProcessGroup() {
        Darwin.kill(-processID, SIGTERM)
        let pid = processID
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            let stillOwned = !processExited
            lock.unlock()
            if stillOwned, Darwin.kill(pid, 0) == 0 { Darwin.kill(-pid, SIGKILL) }
        }
    }

    private func deliver(_ result: Result<ProcessExecutionResult, Error>) {
        lock.lock()
        guard !responseDelivered, let continuation else { lock.unlock(); return }
        responseDelivered = true
        self.continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation.resume(with: result)
        cleanupIfPossible()
    }

    private func readBounded(_ url: URL) -> Data {
        guard maximumOutputBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maximumOutputBytes)) ?? Data()
    }

    private func cleanupIfPossible() {
        lock.lock()
        let shouldCleanup = responseDelivered && processExited
        if shouldCleanup {
            processSource?.cancel()
            processSource = nil
        }
        lock.unlock()
        if shouldCleanup { try? FileManager.default.removeItem(at: tempRoot) }
    }
}
