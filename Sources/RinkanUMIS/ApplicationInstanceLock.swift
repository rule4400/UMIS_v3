import Darwin
import Foundation

enum ApplicationInstanceLockError: LocalizedError {
    case alreadyRunning
    case unavailable(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "RINKAN UMISの別プロセスがすでに起動しています"
        case .unavailable(let path, let code):
            return "単一起動ロックを確立できません (\(path), errno=\(code))"
        }
    }
}

/// Holds a process-wide, non-blocking advisory lock for the full application lifetime.
///
/// `LSMultipleInstancesProhibited` blocks ordinary Launch Services duplication. This lock is the
/// second boundary for direct executable launches. If it cannot be established, AppModel remains
/// inert and never starts scanning, copying, ejecting, or erasing media.
final class ApplicationInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private static func setLock(_ type: Int16, on descriptor: Int32) -> Int32 {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    init(applicationSupportRoot: URL) throws {
        let lockDirectory = applicationSupportRoot
            .appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = lockDirectory.appendingPathComponent("application.lock", isDirectory: false)
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw ApplicationInstanceLockError.unavailable(path: lockURL.path, code: errno)
        }
        guard Self.setLock(Int16(F_WRLCK), on: descriptor) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ApplicationInstanceLockError.alreadyRunning
            }
            throw ApplicationInstanceLockError.unavailable(path: lockURL.path, code: code)
        }
        _ = Darwin.fchmod(descriptor, mode_t(0o600))
        self.descriptor = descriptor
    }

    deinit {
        _ = Self.setLock(Int16(F_UNLCK), on: descriptor)
        _ = Darwin.close(descriptor)
    }
}
