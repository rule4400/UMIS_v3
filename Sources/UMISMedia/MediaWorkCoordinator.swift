import Foundation

/// Priority queue + in-flight request coalescing. This actor intentionally owns only
/// a bounded number of unstructured Tasks; callers own cancellation through their
/// awaiting task and never need to retain an implementation-specific token.
actor MediaWorkCoordinator<Key: Hashable & Sendable, Value: Sendable> {
    typealias Operation = @Sendable () async -> Result<Value, MediaPipelineFailure>

    struct Snapshot: Sendable, Equatable {
        let pendingCount: Int
        let runningCount: Int
        let subscriberCount: Int
        let operationStartCount: Int
    }

    private enum State {
        case pending
        case running
    }

    private struct Entry {
        var priority: MediaRequestPriority
        let sequence: UInt64
        let operation: Operation
        var waiters: [UUID: CheckedContinuation<Result<Value, MediaPipelineFailure>, Never>]
        var task: Task<Void, Never>?
        var priorityBooster: Task<Void, Never>?
        var state: State
    }

    private let maximumConcurrency: Int
    private var entries: [Key: Entry] = [:]
    private var runningCount = 0
    private var nextSequence: UInt64 = 0
    private var operationStartCount = 0

    init(maximumConcurrency: Int) {
        self.maximumConcurrency = max(1, maximumConcurrency)
    }

    func request(
        key: Key,
        priority: MediaRequestPriority,
        operation: @escaping Operation
    ) async throws -> Value {
        if Task.isCancelled { throw MediaPipelineFailure(.cancelled) }
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    key: key,
                    waiterID: waiterID,
                    priority: priority,
                    continuation: continuation,
                    operation: operation
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, for: key) }
        }
        return try result.get()
    }

    func cancelAll() {
        let cancellation = Result<Value, MediaPipelineFailure>.failure(.init(.cancelled))
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            for continuation in entry.waiters.values {
                continuation.resume(returning: cancellation)
            }
            entry.waiters.removeAll(keepingCapacity: false)
            if entry.state == .running {
                entry.task?.cancel()
                entry.priorityBooster?.cancel()
                entries[key] = entry
            } else {
                entries.removeValue(forKey: key)
            }
        }
    }

    /// Cancels every subscriber and does not return until work which was already
    /// running has left its generator. Destructive volume operations use this
    /// stronger barrier before unmounting removable media.
    func cancelAllAndWait() async {
        cancelAll()
        while true {
            let tasks = entries.values.compactMap(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            pendingCount: entries.values.filter { $0.state == .pending }.count,
            runningCount: runningCount,
            subscriberCount: entries.values.reduce(0) { $0 + $1.waiters.count },
            operationStartCount: operationStartCount
        )
    }

    func resetStatistics() {
        operationStartCount = 0
    }

    private func enqueue(
        key: Key,
        waiterID: UUID,
        priority: MediaRequestPriority,
        continuation: CheckedContinuation<Result<Value, MediaPipelineFailure>, Never>,
        operation: @escaping Operation
    ) {
        if Task.isCancelled {
            continuation.resume(returning: .failure(.init(.cancelled)))
            return
        }
        if var existing = entries[key] {
            let isUpgrade = priority > existing.priority
            existing.priority = max(existing.priority, priority)
            existing.waiters[waiterID] = continuation
            if isUpgrade, existing.state == .running, let runningTask = existing.task {
                existing.priorityBooster?.cancel()
                // Awaiting a lower-priority Task from this higher-priority Task donates
                // priority through Swift's task escalation machinery without restarting
                // or duplicating the shared decode.
                existing.priorityBooster = Task(priority: priority.taskPriority) {
                    await runningTask.value
                }
            }
            entries[key] = existing
        } else {
            nextSequence &+= 1
            entries[key] = Entry(
                priority: priority,
                sequence: nextSequence,
                operation: operation,
                waiters: [waiterID: continuation],
                task: nil,
                priorityBooster: nil,
                state: .pending
            )
        }
        pump()
    }

    private func cancel(waiterID: UUID, for key: Key) {
        guard var entry = entries[key], let continuation = entry.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(returning: .failure(.init(.cancelled)))
        if entry.waiters.isEmpty {
            switch entry.state {
            case .pending:
                entries.removeValue(forKey: key)
            case .running:
                entry.task?.cancel()
                entry.priorityBooster?.cancel()
                entries[key] = entry
            }
        } else {
            entries[key] = entry
        }
    }

    private func pump() {
        while runningCount < maximumConcurrency {
            guard let key = entries
                .filter({ $0.value.state == .pending && !$0.value.waiters.isEmpty })
                .max(by: { lhs, rhs in
                    if lhs.value.priority == rhs.value.priority {
                        return lhs.value.sequence > rhs.value.sequence
                    }
                    return lhs.value.priority < rhs.value.priority
                })?
                .key,
                var entry = entries[key]
            else {
                return
            }

            entry.state = .running
            runningCount += 1
            operationStartCount += 1
            let operation = entry.operation
            let task = Task(priority: entry.priority.taskPriority) { [weak self] in
                let result = await operation()
                await self?.finish(key: key, result: result)
            }
            entry.task = task
            entries[key] = entry
        }
    }

    private func finish(key: Key, result: Result<Value, MediaPipelineFailure>) {
        guard let entry = entries.removeValue(forKey: key) else {
            // `cancelAll` deliberately retains running entries, so this is defensive.
            runningCount = max(0, runningCount - 1)
            pump()
            return
        }
        entry.priorityBooster?.cancel()
        runningCount = max(0, runningCount - 1)
        let delivered: Result<Value, MediaPipelineFailure>
        if entry.task?.isCancelled == true {
            delivered = .failure(.init(.cancelled))
        } else {
            delivered = result
        }
        for continuation in entry.waiters.values {
            continuation.resume(returning: delivered)
        }
        pump()
    }
}
