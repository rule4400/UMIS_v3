import Foundation

public enum OutboxState: String, Codable, CaseIterable, Sendable {
    case pending
    case inFlight
    case acknowledged
    case retryScheduled
    case pausedForAuth
    case deadLetter
}

public struct OutboxRecord: Codable, Hashable, Sendable, Identifiable {
    public let event: CanonicalIngestEvent
    public let payloadDigest: SHA256Value
    public var state: OutboxState
    public var attemptCount: UInt32
    public var attemptID: UUID?
    public var claimedAt: Date?
    public var leaseUntil: Date?
    public var nextAttemptAt: Date?
    public var acknowledgedAt: Date?
    public var serverReceiptID: String?
    public var correlationID: String?
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    public var id: UUID { event.eventID }
}

public struct OutboxLease: Hashable, Sendable {
    public let attemptID: UUID
    public let claimedAt: Date
    public let leaseUntil: Date
    public let events: [CanonicalIngestEvent]

    public init(
        attemptID: UUID,
        claimedAt: Date,
        leaseUntil: Date,
        events: [CanonicalIngestEvent]
    ) {
        self.attemptID = attemptID
        self.claimedAt = claimedAt
        self.leaseUntil = leaseUntil
        self.events = events
    }
}

public struct OutboxRetryPolicy: Codable, Hashable, Sendable {
    public let baseDelaySeconds: TimeInterval
    public let maximumDelaySeconds: TimeInterval
    public let maximumAttempts: UInt32

    public init(
        baseDelaySeconds: TimeInterval = 2,
        maximumDelaySeconds: TimeInterval = 3_600,
        maximumAttempts: UInt32 = 20
    ) {
        precondition(baseDelaySeconds > 0 && baseDelaySeconds.isFinite)
        precondition(maximumDelaySeconds >= baseDelaySeconds && maximumDelaySeconds.isFinite)
        precondition(maximumAttempts > 0)
        self.baseDelaySeconds = baseDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
        self.maximumAttempts = maximumAttempts
    }

    /// Exponential backoff with full jitter. `randomUnit` is injectable to make
    /// retry decisions deterministic in tests and audit logs.
    public func delaySeconds(attemptCount: UInt32, randomUnit: Double) -> TimeInterval {
        let exponent = min(Int(max(attemptCount, 1) - 1), 62)
        let ceiling = min(maximumDelaySeconds, baseDelaySeconds * pow(2, Double(exponent)))
        return ceiling * min(max(randomUnit, 0), 1)
    }
}

public enum OutboxEnqueueResult: Equatable, Sendable {
    case inserted
    case alreadyPresent
}

public enum OutboxTransportFailure: Equatable, Sendable {
    case retryable(errorCode: String?, retryAfterSeconds: UInt64?)
    case authenticationRequired(errorCode: String?)
    case permanent(errorCode: String?)
}

public enum DurableOutboxError: Error, Equatable, Sendable {
    case invalidFileName
    case invalidClaimLimit
    case invalidLeaseDuration
    case eventIDPayloadMismatch(UUID)
    case nonMonotonicJobSequence(jobID: UUID, received: UInt64, highest: UInt64)
    case corruptDatabase
    case duplicateReceiptEventID(UUID)
    case receiptEventNotClaimed(UUID)
    case unknownAttempt(UUID)
    case eventNotFound(UUID)
    case eventNotRetryable(UUID)
}

private struct DurableOutboxDatabase: Codable, Sendable {
    let schemaVersion: UInt16
    var records: [OutboxRecord]
}

/// Durable at-least-once outbox with explicit leases and per-event receipts.
///
/// The store never marks omitted batch members as acknowledged. A process or
/// ACK loss leaves them in-flight until lease expiry, then reclaims the exact
/// same event ID and canonical payload.
public actor DurableOutboxStore {
    public static let defaultFileName = "sd-management-outbox"

    private let file: AtomicRecordFile
    private var recordsByID: [UUID: OutboxRecord]

    public init(
        directoryURL: URL,
        fileName: String = DurableOutboxStore.defaultFileName
    ) throws {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"),
              !fileName.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DurableOutboxError.invalidFileName
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = AtomicRecordFile(url: directoryURL.appendingPathComponent(fileName))
        let database = try file.read(DurableOutboxDatabase.self)
        var indexed: [UUID: OutboxRecord] = [:]
        if let database {
            guard database.schemaVersion == 1 else { throw DurableOutboxError.corruptDatabase }
            for record in database.records {
                try record.event.validate()
                guard try record.event.payloadDigest() == record.payloadDigest,
                      indexed.updateValue(record, forKey: record.id) == nil,
                      Self.hasValidStateShape(record) else {
                    throw DurableOutboxError.corruptDatabase
                }
            }
        }
        self.file = file
        self.recordsByID = indexed
    }

    public func enqueue(
        _ event: CanonicalIngestEvent,
        now: Date = Date()
    ) throws -> OutboxEnqueueResult {
        try event.validate()
        let digest = try event.payloadDigest()
        if let existing = recordsByID[event.eventID] {
            guard existing.payloadDigest == digest else {
                throw DurableOutboxError.eventIDPayloadMismatch(event.eventID)
            }
            return .alreadyPresent
        }
        let highestSequence = recordsByID.values
            .filter { $0.event.jobID == event.jobID }
            .map(\.event.jobSequence)
            .max()
        if let highestSequence, event.jobSequence <= highestSequence {
            throw DurableOutboxError.nonMonotonicJobSequence(
                jobID: event.jobID,
                received: event.jobSequence,
                highest: highestSequence
            )
        }
        var next = recordsByID
        next[event.eventID] = OutboxRecord(
            event: event,
            payloadDigest: digest,
            state: .pending,
            attemptCount: 0,
            attemptID: nil,
            claimedAt: nil,
            leaseUntil: nil,
            nextAttemptAt: nil,
            acknowledgedAt: nil,
            serverReceiptID: nil,
            correlationID: nil,
            lastErrorCode: nil,
            createdAt: now,
            updatedAt: now
        )
        try commit(next)
        return .inserted
    }

    public func claim(
        limit: Int,
        now: Date = Date(),
        leaseDuration: TimeInterval = 60
    ) throws -> OutboxLease? {
        guard limit > 0 else { throw DurableOutboxError.invalidClaimLimit }
        guard leaseDuration > 0, leaseDuration.isFinite else {
            throw DurableOutboxError.invalidLeaseDuration
        }
        var next = recordsByID
        var changed = false
        for id in next.keys {
            guard var record = next[id], record.state == .inFlight,
                  let leaseUntil = record.leaseUntil, leaseUntil <= now else { continue }
            record.state = .pending
            Self.clearLease(&record)
            record.updatedAt = now
            next[id] = record
            changed = true
        }

        let eligible = next.values.filter { record in
            switch record.state {
            case .pending:
                return true
            case .retryScheduled:
                return record.nextAttemptAt.map { $0 <= now } ?? true
            default:
                return false
            }
        }.sorted(by: Self.deliveryOrder).prefix(limit)

        guard !eligible.isEmpty else {
            if changed { try commit(next) }
            return nil
        }
        let attemptID = UUID()
        let leaseUntil = now.addingTimeInterval(leaseDuration)
        var leasedEvents: [CanonicalIngestEvent] = []
        for eligibleRecord in eligible {
            var record = eligibleRecord
            guard record.attemptCount < UInt32.max else {
                throw DurableOutboxError.corruptDatabase
            }
            record.state = .inFlight
            record.attemptCount += 1
            record.attemptID = attemptID
            record.claimedAt = now
            record.leaseUntil = leaseUntil
            record.nextAttemptAt = nil
            record.updatedAt = now
            next[record.id] = record
            leasedEvents.append(record.event)
        }
        try commit(next)
        return OutboxLease(
            attemptID: attemptID,
            claimedAt: now,
            leaseUntil: leaseUntil,
            events: leasedEvents
        )
    }

    public func apply(
        _ receipt: PublishReceipt,
        toAttempt attemptID: UUID,
        now: Date = Date(),
        retryPolicy: OutboxRetryPolicy = OutboxRetryPolicy(),
        randomUnit: Double = Double.random(in: 0...1)
    ) throws {
        let resultIDs = receipt.results.map(\.eventID)
        guard Set(resultIDs).count == resultIDs.count else {
            var seen = Set<UUID>()
            let duplicate = resultIDs.first { !seen.insert($0).inserted } ?? UUID()
            throw DurableOutboxError.duplicateReceiptEventID(duplicate)
        }
        let claimed = recordsByID.values.filter {
            $0.state == .inFlight && $0.attemptID == attemptID
        }
        guard !claimed.isEmpty else { throw DurableOutboxError.unknownAttempt(attemptID) }
        let claimedIDs = Set(claimed.map(\.id))
        for result in receipt.results where !claimedIDs.contains(result.eventID) {
            throw DurableOutboxError.receiptEventNotClaimed(result.eventID)
        }

        var next = recordsByID
        for result in receipt.results {
            guard var record = next[result.eventID] else { continue }
            switch result.status {
            case .accepted, .duplicate:
                record.state = .acknowledged
                record.acknowledgedAt = now
                record.serverReceiptID = result.serverReceiptID
                record.correlationID = result.correlationID
                record.lastErrorCode = nil
                Self.clearLease(&record)
            case .retryable:
                scheduleRetry(
                    &record,
                    now: now,
                    retryAfterSeconds: result.retryAfterSeconds,
                    errorCode: result.errorCode,
                    policy: retryPolicy,
                    randomUnit: randomUnit
                )
            case .permanent:
                record.state = .deadLetter
                record.lastErrorCode = result.errorCode
                record.serverReceiptID = result.serverReceiptID
                record.correlationID = result.correlationID
                Self.clearLease(&record)
            }
            record.updatedAt = now
            next[result.eventID] = record
        }
        // Receipt omissions intentionally remain inFlight for lease recovery.
        try commit(next)
    }

    public func recordTransportFailure(
        attemptID: UUID,
        failure: OutboxTransportFailure,
        now: Date = Date(),
        retryPolicy: OutboxRetryPolicy = OutboxRetryPolicy(),
        randomUnit: Double = Double.random(in: 0...1)
    ) throws {
        let claimed = recordsByID.values.filter {
            $0.state == .inFlight && $0.attemptID == attemptID
        }
        guard !claimed.isEmpty else { throw DurableOutboxError.unknownAttempt(attemptID) }
        var next = recordsByID
        for claimedRecord in claimed {
            var record = claimedRecord
            switch failure {
            case .retryable(let errorCode, let retryAfterSeconds):
                scheduleRetry(
                    &record,
                    now: now,
                    retryAfterSeconds: retryAfterSeconds,
                    errorCode: errorCode,
                    policy: retryPolicy,
                    randomUnit: randomUnit
                )
            case .authenticationRequired(let errorCode):
                record.state = .pausedForAuth
                record.lastErrorCode = errorCode
                Self.clearLease(&record)
            case .permanent(let errorCode):
                record.state = .deadLetter
                record.lastErrorCode = errorCode
                Self.clearLease(&record)
            }
            record.updatedAt = now
            next[record.id] = record
        }
        try commit(next)
    }

    public func manualRetry(eventID: UUID, now: Date = Date()) throws {
        guard var record = recordsByID[eventID] else {
            throw DurableOutboxError.eventNotFound(eventID)
        }
        guard record.state == .deadLetter || record.state == .pausedForAuth ||
                record.state == .retryScheduled else {
            throw DurableOutboxError.eventNotRetryable(eventID)
        }
        record.state = .pending
        record.nextAttemptAt = nil
        record.lastErrorCode = nil
        Self.clearLease(&record)
        record.updatedAt = now
        var next = recordsByID
        next[eventID] = record
        try commit(next)
    }

    public func allRecords() -> [OutboxRecord] {
        recordsByID.values.sorted(by: Self.deliveryOrder)
    }

    public func records(in state: OutboxState) -> [OutboxRecord] {
        recordsByID.values.filter { $0.state == state }.sorted(by: Self.deliveryOrder)
    }

    public func record(eventID: UUID) -> OutboxRecord? { recordsByID[eventID] }

    private func scheduleRetry(
        _ record: inout OutboxRecord,
        now: Date,
        retryAfterSeconds: UInt64?,
        errorCode: String?,
        policy: OutboxRetryPolicy,
        randomUnit: Double
    ) {
        if record.attemptCount >= policy.maximumAttempts {
            record.state = .deadLetter
            record.lastErrorCode = errorCode ?? "retry_limit_exhausted"
            Self.clearLease(&record)
            return
        }
        let jitter = policy.delaySeconds(
            attemptCount: record.attemptCount,
            randomUnit: randomUnit
        )
        let serverMinimum = retryAfterSeconds.map { TimeInterval($0) } ?? 0
        record.state = .retryScheduled
        record.nextAttemptAt = now.addingTimeInterval(max(jitter, serverMinimum))
        record.lastErrorCode = errorCode
        Self.clearLease(&record, preservingNextAttempt: true)
    }

    private func commit(_ next: [UUID: OutboxRecord]) throws {
        let database = DurableOutboxDatabase(
            schemaVersion: 1,
            records: next.values.sorted(by: Self.deliveryOrder)
        )
        try file.write(database)
        recordsByID = next
    }

    private static func clearLease(
        _ record: inout OutboxRecord,
        preservingNextAttempt: Bool = false
    ) {
        record.attemptID = nil
        record.claimedAt = nil
        record.leaseUntil = nil
        if !preservingNextAttempt { record.nextAttemptAt = nil }
    }

    private static func hasValidStateShape(_ record: OutboxRecord) -> Bool {
        switch record.state {
        case .inFlight:
            return record.attemptID != nil && record.claimedAt != nil &&
                record.leaseUntil != nil && record.nextAttemptAt == nil
        case .retryScheduled:
            return record.attemptID == nil && record.claimedAt == nil &&
                record.leaseUntil == nil && record.nextAttemptAt != nil
        default:
            return record.attemptID == nil && record.claimedAt == nil &&
                record.leaseUntil == nil && record.nextAttemptAt == nil
        }
    }

    private static func deliveryOrder(_ lhs: OutboxRecord, _ rhs: OutboxRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.event.jobID == rhs.event.jobID,
           lhs.event.jobSequence != rhs.event.jobSequence {
            return lhs.event.jobSequence < rhs.event.jobSequence
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
