import CSQLite
import CryptoKit
import Foundation

public enum OperationKind: String, Codable, Sendable {
    case ingest
    case copyAndRename
    case erase
    case eject
}

public enum OperationStatus: String, Codable, Sendable {
    case planned
    case running
    case cancelled
    case failed
    case rolledBack
    case completed
    case recoveryRequired
}

public enum JournalItemState: String, Codable, Sendable {
    case planned
    case copying
    case partialWritten
    case sourceHashed
    case destinationHashed
    /// Durable intent persisted immediately before the no-replace rename. On recovery, the
    /// partial/final presence pair plus full hashes determines whether this operation committed.
    case atomicCommitIntent
    case atomicCommitted
    case durableCommitted
    case durableVerifiedExisting
    case conflict
    case cancelled
    case failed
    case rolledBack
}

public struct JournalItemRecord: Codable, Hashable, Sendable {
    public var operationID: UUID
    public var itemID: IngestItemID
    public var assetID: MediaAssetID
    public var state: JournalItemState
    public var bytesCopied: Int64
    public var partialURL: URL
    public var finalURL: URL
    public var sourceSHA256: String?
    public var destinationSHA256: String?
    public var receipt: DeliveryReceipt?
    public var error: String?
    public var updatedAt: Date

    public init(
        operationID: UUID,
        itemID: IngestItemID,
        assetID: MediaAssetID,
        state: JournalItemState,
        bytesCopied: Int64,
        partialURL: URL,
        finalURL: URL,
        sourceSHA256: String? = nil,
        destinationSHA256: String? = nil,
        receipt: DeliveryReceipt? = nil,
        error: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.itemID = itemID
        self.assetID = assetID
        self.state = state
        self.bytesCopied = bytesCopied
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.sourceSHA256 = sourceSHA256
        self.destinationSHA256 = destinationSHA256
        self.receipt = receipt
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct OperationSummary: Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var status: OperationStatus
    public var createdAt: Date
    public var updatedAt: Date
}

public struct AuditEventRecord: Codable, Hashable, Sendable {
    public var sequence: Int64
    public var operationID: UUID?
    public var eventType: String
    /// Empty unless `auditExport(..., includeSensitivePayload: true)` was explicitly requested.
    /// Audit payloads may contain full local/network paths and backend diagnostic details.
    public var payload: Data
    public var isPayloadRedacted: Bool
    /// SHA-256 of the original payload remains visible even when the sensitive payload is redacted.
    public var payloadDigest: String
    public var previousHash: String
    public var eventHash: String
    public var createdAt: Date
    public var chainVerification: AuditChainEntryVerification
    /// Epoch membership is explicit so a filtered/redacted export cannot make an
    /// unverified legacy row appear to belong to the canonical v2 chain.
    public var epoch: AuditChainEpoch
    public var isEpochGenesis: Bool
    /// Present only on the canonical genesis that seals a preceding legacy epoch.
    public var predecessorEpochDigest: String?

    public init(
        sequence: Int64,
        operationID: UUID?,
        eventType: String,
        payload: Data,
        isPayloadRedacted: Bool,
        payloadDigest: String = String(repeating: "0", count: 64),
        previousHash: String,
        eventHash: String,
        createdAt: Date,
        chainVerification: AuditChainEntryVerification = .legacyUnverifiable,
        epoch: AuditChainEpoch = .unknown,
        isEpochGenesis: Bool = false,
        predecessorEpochDigest: String? = nil
    ) {
        self.sequence = sequence
        self.operationID = operationID
        self.eventType = eventType
        self.payload = payload
        self.isPayloadRedacted = isPayloadRedacted
        self.payloadDigest = payloadDigest
        self.previousHash = previousHash
        self.eventHash = eventHash
        self.createdAt = createdAt
        self.chainVerification = chainVerification
        self.epoch = epoch
        self.isEpochGenesis = isEpochGenesis
        self.predecessorEpochDigest = predecessorEpochDigest
    }
}

public enum AuditChainEpoch: String, Codable, Hashable, Sendable {
    /// Original v1 material is retained byte-for-byte and sealed, but remains untrusted.
    case sealedLegacyV1
    case canonicalV2
    case unknown
}

public enum AuditChainEntryVerification: String, Codable, Hashable, Sendable {
    case verified
    case legacyUnverifiable
    case invalid
}

public enum AuditChainStatus: String, Codable, Hashable, Sendable {
    case empty
    case verified
    case legacyUnverifiable
    /// The legacy prefix is explicitly untrusted but immutable under a digest-bound
    /// canonical v2 genesis, and the complete canonical suffix verifies.
    case sealedLegacyAndVerified
    case invalid
}

public struct AuditChainVerificationReport: Codable, Hashable, Sendable {
    public var status: AuditChainStatus
    public var eventCount: Int
    public var verifiedEventCount: Int
    public var firstUntrustedSequence: Int64?
    public var diagnostic: String?
    public var legacySealedEventCount: Int
    public var canonicalEpochStartSequence: Int64?
    public var legacyEpochDigest: String?

    public init(
        status: AuditChainStatus,
        eventCount: Int,
        verifiedEventCount: Int,
        firstUntrustedSequence: Int64? = nil,
        diagnostic: String? = nil,
        legacySealedEventCount: Int = 0,
        canonicalEpochStartSequence: Int64? = nil,
        legacyEpochDigest: String? = nil
    ) {
        self.status = status
        self.eventCount = eventCount
        self.verifiedEventCount = verifiedEventCount
        self.firstUntrustedSequence = firstUntrustedSequence
        self.diagnostic = diagnostic
        self.legacySealedEventCount = legacySealedEventCount
        self.canonicalEpochStartSequence = canonicalEpochStartSequence
        self.legacyEpochDigest = legacyEpochDigest
    }

    /// `true` means the database is safe to extend. It does not claim that sealed
    /// legacy events are trustworthy; those remain individually marked unverified.
    public var isTrusted: Bool {
        status == .empty || status == .verified || status == .sealedLegacyAndVerified
    }
}

/// Durable fail-closed marker created before an authorized destructive backend is invoked. The
/// opaque physical key survives a new `SourceVolumeID`, remount, and application restart. Records
/// are cleared internally only after the backend reports and proves a fully completed outcome;
/// there is intentionally no public manual-clear API.
public struct DestructiveQuarantineRecord: Codable, Hashable, Sendable {
    public var physicalKey: PhysicalMediaQuarantineKey
    public var operationID: UUID
    public var sourceIdentityDigest: String
    public var reason: String
    public var createdAt: Date

    public init(
        physicalKey: PhysicalMediaQuarantineKey,
        operationID: UUID,
        sourceIdentityDigest: String,
        reason: String,
        createdAt: Date
    ) {
        self.physicalKey = physicalKey
        self.operationID = operationID
        self.sourceIdentityDigest = sourceIdentityDigest
        self.reason = reason
        self.createdAt = createdAt
    }
}

struct AuditAppendInstrumentation: Equatable, Sendable {
    var fullChainVerificationPassCount: Int
    var fullChainVerifiedRowCount: Int
    var headBoundaryVerificationCount: Int
}

public actor OperationStore {
    public static let currentSchemaVersion = 6

    private let connection: SQLiteConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var trustedAuditHead = AuditTrustedHead.empty
    private var lastObservedSQLiteDataVersion: Int64 = 0
    private var auditInstrumentation = AuditAppendInstrumentation(
        fullChainVerificationPassCount: 0,
        fullChainVerifiedRowCount: 0,
        headBoundaryVerificationCount: 0
    )

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connection = try SQLiteConnection(path: databaseURL.path)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try connection.configureAndMigrate()
        try Self.migrateLegacyAuditEpochIfNeeded(connection: connection)
        try Self.migrateTrustedAuditHeadIfNeeded(connection: connection)
        let startupRows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
        let startupVerification = try Self.verifyAuditRows(startupRows).report
        guard startupVerification.isTrusted else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Audit chain verification failed at startup: \(startupVerification.diagnostic ?? "unknown corruption")"
            )
        }
        let computedHead = try Self.trustedAuditHead(
            rows: startupRows,
            verification: startupVerification
        )
        let persistedHead = try Self.loadTrustedAuditHead(connection: connection)
        guard persistedHead == computedHead else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Persisted audit head does not match the fully verified chain"
            )
        }
        trustedAuditHead = computedHead
        lastObservedSQLiteDataVersion = try connection.scalarInt("PRAGMA data_version")
        auditInstrumentation.fullChainVerificationPassCount = 1
        auditInstrumentation.fullChainVerifiedRowCount = startupRows.count
    }

    public func schemaVersion() throws -> Int {
        Int(try connection.scalarInt("PRAGMA user_version"))
    }

    public func createIngest(_ plan: IngestPlan, kind: OperationKind = .ingest) throws {
        try plan.validate()
        let operationID = plan.runID.rawValue
        let planData = try encoder.encode(plan)
        let now = Date().timeIntervalSince1970
        try connection.transaction {
            try connection.execute(
                """
                INSERT OR IGNORE INTO operations(id, kind, status, plan_json, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?)
                """,
                [.text(operationID.uuidString), .text(kind.rawValue), .text(OperationStatus.planned.rawValue), .blob(planData), .double(now), .double(now)]
            )
            guard let existing = try connection.queryOne(
                "SELECT plan_json FROM operations WHERE id = ?",
                [.text(operationID.uuidString)]
            ), case let .blob(existingPlanData)? = existing["plan_json"] else {
                throw UMISCoreError.journalMissing(operationID.uuidString)
            }
            let existingPlan = try decoder.decode(IngestPlan.self, from: existingPlanData)
            // Compare normalized persisted representations. Date encoding and backward-compatible
            // decoding can intentionally normalize fields without weakening the frozen-plan binding.
            let normalizedRequestedPlan = try decoder.decode(IngestPlan.self, from: planData)
            guard existingPlan == normalizedRequestedPlan else {
                throw UMISCoreError.invalidPlan("Operation ID is already bound to a different frozen plan")
            }
            for item in plan.items {
                let partial = Self.partialURL(for: item, plan: plan)
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO operation_items(
                        operation_id, item_id, asset_id, state, bytes_copied,
                        partial_path, final_path, updated_at
                    ) VALUES(?, ?, ?, ?, 0, ?, ?, ?)
                    """,
                    [
                        .text(operationID.uuidString),
                        .text(item.id.rawValue.uuidString),
                        .text(item.asset.id.rawValue.uuidString),
                        .text(JournalItemState.planned.rawValue),
                        .text(partial.path),
                        .text(item.finalURL.path),
                        .double(now),
                    ]
                )
            }
        }
    }

    public func loadIngestPlan(runID: IngestRunID) throws -> IngestPlan {
        guard let row = try connection.queryOne(
            "SELECT plan_json FROM operations WHERE id = ?",
            [.text(runID.rawValue.uuidString)]
        ), case let .blob(data)? = row["plan_json"] else {
            throw UMISCoreError.journalMissing(runID.rawValue.uuidString)
        }
        return try decoder.decode(IngestPlan.self, from: data)
    }

    public func setOperationStatus(_ status: OperationStatus, id: UUID) throws {
        try connection.execute(
            "UPDATE operations SET status = ?, updated_at = ? WHERE id = ?",
            [.text(status.rawValue), .double(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
        guard connection.changes > 0 else { throw UMISCoreError.journalMissing(id.uuidString) }
    }

    public func saveReceipt(_ receipt: IngestReceipt) throws {
        let data = try encoder.encode(receipt)
        try connection.execute(
            "UPDATE operations SET receipt_json = ?, status = ?, updated_at = ? WHERE id = ?",
            [
                .blob(data),
                .text(OperationStatus.completed.rawValue),
                .double(Date().timeIntervalSince1970),
                .text(receipt.runID.rawValue.uuidString),
            ]
        )
        guard connection.changes > 0 else { throw UMISCoreError.journalMissing(receipt.runID.rawValue.uuidString) }
    }

    public func loadReceipt(runID: IngestRunID) throws -> IngestReceipt? {
        guard let row = try connection.queryOne(
            "SELECT receipt_json FROM operations WHERE id = ?",
            [.text(runID.rawValue.uuidString)]
        ) else { throw UMISCoreError.journalMissing(runID.rawValue.uuidString) }
        guard case let .blob(data)? = row["receipt_json"] else { return nil }
        return try decoder.decode(IngestReceipt.self, from: data)
    }

    public func updateItem(_ record: JournalItemRecord) throws {
        let receiptData = try record.receipt.map { try encoder.encode($0) }
        try connection.execute(
            """
            UPDATE operation_items
            SET state = ?, bytes_copied = ?, source_hash = ?, destination_hash = ?,
                receipt_json = ?, error = ?, updated_at = ?
            WHERE operation_id = ? AND item_id = ?
            """,
            [
                .text(record.state.rawValue),
                .integer(record.bytesCopied),
                record.sourceSHA256.map(SQLiteValue.text) ?? .null,
                record.destinationSHA256.map(SQLiteValue.text) ?? .null,
                receiptData.map(SQLiteValue.blob) ?? .null,
                record.error.map(SQLiteValue.text) ?? .null,
                .double(record.updatedAt.timeIntervalSince1970),
                .text(record.operationID.uuidString),
                .text(record.itemID.rawValue.uuidString),
            ]
        )
        guard connection.changes > 0 else { throw UMISCoreError.journalMissing(record.itemID.rawValue.uuidString) }
    }

    public func item(operationID: UUID, itemID: IngestItemID) throws -> JournalItemRecord? {
        guard let row = try connection.queryOne(
            "SELECT * FROM operation_items WHERE operation_id = ? AND item_id = ?",
            [.text(operationID.uuidString), .text(itemID.rawValue.uuidString)]
        ) else { return nil }
        return try decodeJournalItem(row)
    }

    public func items(operationID: UUID) throws -> [JournalItemRecord] {
        try connection.query(
            "SELECT * FROM operation_items WHERE operation_id = ? ORDER BY rowid",
            [.text(operationID.uuidString)]
        ).map(decodeJournalItem)
    }

    public func unfinishedOperations() throws -> [OperationSummary] {
        try connection.query(
            """
            SELECT id, kind, status, created_at, updated_at FROM operations
            WHERE status NOT IN ('completed') ORDER BY updated_at DESC
            """
        ).compactMap(Self.decodeOperationSummary)
    }

    /// Read-only history query for the restart/recovery UI. `limit` is bounded to avoid loading an
    /// unbounded journal into memory. Filters are translated only into fixed SQL fragments.
    public func operations(
        limit: Int = 200,
        kind: OperationKind? = nil,
        status: OperationStatus? = nil
    ) throws -> [OperationSummary] {
        guard (1 ... 10_000).contains(limit) else {
            throw UMISCoreError.invalidPlan("Operation history limit must be between 1 and 10000")
        }
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let kind {
            conditions.append("kind = ?")
            bindings.append(.text(kind.rawValue))
        }
        if let status {
            conditions.append("status = ?")
            bindings.append(.text(status.rawValue))
        }
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        bindings.append(.integer(Int64(limit)))
        return try connection.query(
            "SELECT id, kind, status, created_at, updated_at FROM operations\(whereClause) ORDER BY updated_at DESC LIMIT ?",
            bindings
        ).compactMap(Self.decodeOperationSummary)
    }

    public func operation(id: UUID) throws -> OperationSummary? {
        guard let row = try connection.queryOne(
            "SELECT id, kind, status, created_at, updated_at FROM operations WHERE id = ?",
            [.text(id.uuidString)]
        ) else { return nil }
        guard let summary = Self.decodeOperationSummary(row) else {
            throw UMISCoreError.sqlite(code: SQLITE_CORRUPT, message: "Malformed operations row")
        }
        return summary
    }

    /// Returns journal rows requiring user attention. The URLs and `error` strings can contain
    /// sensitive local/network paths; callers must redact them before telemetry or support export.
    public func itemErrors(operationID: UUID) throws -> [JournalItemRecord] {
        try connection.query(
            """
            SELECT * FROM operation_items
            WHERE operation_id = ? AND (error IS NOT NULL OR state IN ('failed', 'conflict', 'rolledBack'))
            ORDER BY rowid
            """,
            [.text(operationID.uuidString)]
        ).map(decodeJournalItem)
    }

    /// Exports hash-chain metadata with payloads redacted by default. Set `includeSensitivePayload`
    /// only for a user-authorized local export because payloads may contain full paths.
    public func auditExport(
        operationID: UUID? = nil,
        limit: Int = 1_000,
        includeSensitivePayload: Bool = false
    ) throws -> [AuditEventRecord] {
        guard (1 ... 100_000).contains(limit) else {
            throw UMISCoreError.invalidPlan("Audit export limit must be between 1 and 100000")
        }
        let allRows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
        let verification = try fullyVerifyAuditRows(allRows)
        let rows: [SQLiteRow]
        if let operationID {
            rows = try connection.query(
                "SELECT * FROM audit_events WHERE operation_id = ? COLLATE NOCASE ORDER BY sequence LIMIT ?",
                [.text(operationID.uuidString.lowercased()), .integer(Int64(limit))]
            )
        } else {
            rows = try connection.query(
                "SELECT * FROM audit_events ORDER BY sequence LIMIT ?",
                [.integer(Int64(limit))]
            )
        }
        return try rows.map { row in
            guard let sequence = row["sequence"]?.intValue,
                  let eventType = row["event_type"]?.textValue,
                  case let .blob(storedPayload)? = row["payload"],
                  let previousHash = row["previous_hash"]?.textValue,
                  let eventHash = row["event_hash"]?.textValue,
                  let created = row["created_at"]?.doubleValue else {
                throw UMISCoreError.sqlite(code: SQLITE_CORRUPT, message: "Malformed audit_events row")
            }
            let operationID = row["operation_id"]?.textValue.flatMap(UUID.init(uuidString:))
            let payloadDigest = row["payload_digest"]?.textValue
                ?? Self.sha256Hex(storedPayload)
            let chainVersion = row["chain_version"]?.intValue ?? 1
            let epoch: AuditChainEpoch = switch chainVersion {
            case 1: .sealedLegacyV1
            case 2: .canonicalV2
            default: .unknown
            }
            let canonicalStart = verification.report.canonicalEpochStartSequence
            let isEpochGenesis = epoch == .sealedLegacyV1
                ? sequence == 1
                : sequence == canonicalStart
            return AuditEventRecord(
                sequence: sequence,
                operationID: operationID,
                eventType: eventType,
                payload: includeSensitivePayload ? storedPayload : Data(),
                isPayloadRedacted: !includeSensitivePayload,
                payloadDigest: payloadDigest,
                previousHash: previousHash,
                eventHash: eventHash,
                createdAt: Date(timeIntervalSince1970: created),
                chainVerification: verification.entryStatus[sequence] ?? .invalid,
                epoch: epoch,
                isEpochGenesis: isEpochGenesis,
                predecessorEpochDigest: sequence == canonicalStart
                    ? verification.report.legacyEpochDigest
                    : nil
            )
        }
    }

    public func appendAudit(operationID: UUID?, event: String, payload: Data = Data()) throws {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEvent.isEmpty, normalizedEvent.utf8.count <= 1_024,
              normalizedEvent != Self.legacyEpochGenesisEvent,
              payload.count <= 16 * 1_024 * 1_024 else {
            throw UMISCoreError.invalidPlan("Audit event type or payload exceeds the supported bound")
        }
        var committedHead: AuditTrustedHead?
        var transactionDataVersion: Int64?
        try connection.transaction {
            let currentDataVersion = try connection.scalarInt("PRAGMA data_version")
            transactionDataVersion = currentDataVersion
            let persistedHead = try Self.loadTrustedAuditHead(connection: connection)
            let appendHead: AuditTrustedHead

            if currentDataVersion != lastObservedSQLiteDataVersion {
                // Another SQLite connection committed since startup/the last append. Normal app
                // writes use this same connection and do not rotate `data_version`, so only this
                // exceptional path pays for a complete historical verification.
                let existingRows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
                let existingVerification = try fullyVerifyAuditRows(existingRows).report
                guard existingVerification.isTrusted else {
                    throw UMISCoreError.sqlite(
                        code: SQLITE_CORRUPT,
                        message: "Refusing to append to an unverified audit chain: \(existingVerification.status.rawValue)"
                    )
                }
                let computedHead = try Self.trustedAuditHead(
                    rows: existingRows,
                    verification: existingVerification
                )
                guard persistedHead == computedHead else {
                    throw UMISCoreError.sqlite(
                        code: SQLITE_CORRUPT,
                        message: "Persisted audit head does not match the externally changed chain"
                    )
                }
                appendHead = computedHead
            } else {
                guard persistedHead == trustedAuditHead else {
                    throw UMISCoreError.sqlite(
                        code: SQLITE_CORRUPT,
                        message: "Persisted audit head changed without a verified chain transition"
                    )
                }
                appendHead = trustedAuditHead
            }

            try Self.verifyAuditHeadBoundary(connection: connection, head: appendHead)
            auditInstrumentation.headBoundaryVerificationCount += 1
            let sequence = try Self.nextAuditSequence(after: appendHead.sequence)
            let previousHash = appendHead.eventHash
            let timestampMicros = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded(.down))
            let payloadDigest = Self.sha256Hex(payload)
            let material = AuditCanonicalMaterial(
                chainVersion: 2,
                sequence: sequence,
                operationID: operationID?.uuidString.lowercased(),
                eventType: normalizedEvent,
                payloadDigest: payloadDigest,
                timestampMicros: timestampMicros,
                previousHash: previousHash
            )
            let eventHash = try Self.auditHash(material)
            try connection.execute(
                """
                INSERT INTO audit_events(
                    sequence, operation_id, event_type, payload, previous_hash, event_hash,
                    created_at, chain_version, payload_digest, created_at_micros
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(sequence),
                    operationID.map { .text($0.uuidString.lowercased()) } ?? .null,
                    .text(normalizedEvent),
                    .blob(payload),
                    .text(previousHash),
                    .text(eventHash),
                    .double(Double(timestampMicros) / 1_000_000),
                    .integer(2),
                    .text(payloadDigest),
                    .integer(timestampMicros),
                ]
            )
            let nextHead = try appendHead.appending(
                sequence: sequence,
                eventHash: eventHash
            )
            try connection.execute(
                """
                UPDATE audit_chain_head
                SET sequence = ?, event_count = ?, event_hash = ?, status = ?,
                    legacy_epoch_digest = ?, canonical_epoch_start_sequence = ?,
                    updated_at_micros = ?
                WHERE singleton = 1 AND sequence = ? AND event_count = ? AND event_hash = ?
                """,
                [
                    .integer(nextHead.sequence),
                    .integer(nextHead.eventCount),
                    .text(nextHead.eventHash),
                    .text(nextHead.status.rawValue),
                    nextHead.legacyEpochDigest.map(SQLiteValue.text) ?? .null,
                    nextHead.canonicalEpochStartSequence.map(SQLiteValue.integer) ?? .null,
                    .integer(timestampMicros),
                    .integer(appendHead.sequence),
                    .integer(appendHead.eventCount),
                    .text(appendHead.eventHash),
                ]
            )
            guard connection.changes == 1 else {
                throw UMISCoreError.sqlite(
                    code: SQLITE_BUSY,
                    message: "Audit head compare-and-swap failed"
                )
            }
            committedHead = nextHead
        }
        guard let committedHead, let transactionDataVersion else {
            throw UMISCoreError.sqlite(
                code: SQLITE_INTERNAL,
                message: "Audit append committed without publishing its trusted head"
            )
        }
        trustedAuditHead = committedHead
        // This connection's own commit does not change its `PRAGMA data_version`. Keeping the value
        // observed while BEGIN IMMEDIATE was held ensures a later external commit cannot be missed.
        lastObservedSQLiteDataVersion = transactionDataVersion
    }

    /// Verifies the complete global chain, including events outside a UI filter. Legacy version-1
    /// rows are reported as untrusted rather than silently re-hashed and blessed during migration.
    public func verifyAuditChain() throws -> AuditChainVerificationReport {
        let rows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
        return try fullyVerifyAuditRows(rows).report
    }

    public func auditEventCount() throws -> Int {
        Int(try connection.scalarInt("SELECT COUNT(*) FROM audit_events"))
    }

    func auditAppendInstrumentationForTesting() -> AuditAppendInstrumentation {
        auditInstrumentation
    }

    /// Persists a physical-media quarantine before a destructive backend starts. Repeating the
    /// call for the same card retains the earliest creation time while updating the diagnostic.
    @discardableResult
    public func recordDestructiveQuarantine(
        identity: VolumeIdentity,
        operationID: UUID,
        reason: String
    ) throws -> DestructiveQuarantineRecord {
        let key = try identity.physicalQuarantineKey()
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty, normalizedReason.utf8.count <= 4_096 else {
            throw UMISCoreError.invalidPlan("Destructive quarantine reason is empty or too large")
        }
        let createdAt = Date()
        try connection.execute(
            """
            INSERT INTO destructive_quarantines(
                physical_key, operation_id, source_identity_digest, reason, created_at
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(physical_key) DO UPDATE SET
                operation_id = excluded.operation_id,
                source_identity_digest = excluded.source_identity_digest,
                reason = excluded.reason
            """,
            [
                .text(key.rawValue),
                .text(operationID.uuidString),
                .text(identity.securityDigest),
                .text(normalizedReason),
                .double(createdAt.timeIntervalSince1970),
            ]
        )
        return try destructiveQuarantine(for: identity) ?? DestructiveQuarantineRecord(
            physicalKey: key,
            operationID: operationID,
            sourceIdentityDigest: identity.securityDigest,
            reason: normalizedReason,
            createdAt: createdAt
        )
    }

    public func destructiveQuarantine(for identity: VolumeIdentity) throws -> DestructiveQuarantineRecord? {
        let key = try identity.physicalQuarantineKey()
        guard let row = try connection.queryOne(
            "SELECT * FROM destructive_quarantines WHERE physical_key = ?",
            [.text(key.rawValue)]
        ) else { return nil }
        return try Self.decodeDestructiveQuarantine(row)
    }

    /// Diagnostic/read-only listing. Absence from this bounded list must never be used as proof
    /// that a specific card is unquarantined; use `destructiveQuarantine(for:)` for that decision.
    public func destructiveQuarantines(limit: Int = 200) throws -> [DestructiveQuarantineRecord] {
        guard (1 ... 10_000).contains(limit) else {
            throw UMISCoreError.invalidPlan("Destructive quarantine limit must be between 1 and 10000")
        }
        return try connection.query(
            "SELECT * FROM destructive_quarantines ORDER BY created_at DESC LIMIT ?",
            [.integer(Int64(limit))]
        ).map(Self.decodeDestructiveQuarantine)
    }

    /// Internal success-only resolution. Unknown, failed, cancelled, or post-validation-failed
    /// destructive outcomes never call this method.
    func resolveDestructiveQuarantineAfterKnownCompletion(
        identity: VolumeIdentity,
        operationID: UUID
    ) throws {
        let key = try identity.physicalQuarantineKey()
        try connection.execute(
            "DELETE FROM destructive_quarantines WHERE physical_key = ? AND operation_id = ?",
            [.text(key.rawValue), .text(operationID.uuidString)]
        )
    }

    public static func partialURL(for item: IngestPlanItem, plan: IngestPlan) -> URL {
        plan.destination.rootURL
            .appendingPathComponent(".umis-partial", isDirectory: true)
            .appendingPathComponent(plan.runID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(item.id.rawValue.uuidString + ".partial", isDirectory: false)
    }

    private func decodeJournalItem(_ row: SQLiteRow) throws -> JournalItemRecord {
        guard
            let operationString = row["operation_id"]?.textValue,
            let operationID = UUID(uuidString: operationString),
            let itemString = row["item_id"]?.textValue,
            let itemUUID = UUID(uuidString: itemString),
            let assetString = row["asset_id"]?.textValue,
            let assetUUID = UUID(uuidString: assetString),
            let stateString = row["state"]?.textValue,
            let state = JournalItemState(rawValue: stateString),
            let bytes = row["bytes_copied"]?.intValue,
            let partial = row["partial_path"]?.textValue,
            let final = row["final_path"]?.textValue,
            let updated = row["updated_at"]?.doubleValue
        else { throw UMISCoreError.sqlite(code: SQLITE_CORRUPT, message: "Malformed operation_items row") }
        let receipt: DeliveryReceipt?
        if case let .blob(data)? = row["receipt_json"] {
            receipt = try decoder.decode(DeliveryReceipt.self, from: data)
        } else {
            receipt = nil
        }
        return JournalItemRecord(
            operationID: operationID,
            itemID: IngestItemID(rawValue: itemUUID),
            assetID: MediaAssetID(rawValue: assetUUID),
            state: state,
            bytesCopied: bytes,
            partialURL: URL(fileURLWithPath: partial),
            finalURL: URL(fileURLWithPath: final),
            sourceSHA256: row["source_hash"]?.textValue,
            destinationSHA256: row["destination_hash"]?.textValue,
            receipt: receipt,
            error: row["error"]?.textValue,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private func fullyVerifyAuditRows(
        _ rows: [SQLiteRow]
    ) throws -> AuditRowsVerification {
        auditInstrumentation.fullChainVerificationPassCount += 1
        auditInstrumentation.fullChainVerifiedRowCount += rows.count
        return try Self.verifyAuditRows(rows)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func auditHash(_ material: AuditCanonicalMaterial) throws -> String {
        sha256Hex(try StableJSON.encode(material))
    }

    private static let zeroAuditHash = String(repeating: "0", count: 64)
    private static let legacyEpochGenesisEvent = "audit.legacyEpoch.sealed"

    /// Schema v5 is a semantic, one-time migration. It never rewrites legacy rows or their hashes.
    /// Instead it seals their exact stored representation and starts a separately verifiable v2
    /// epoch whose genesis is cryptographically bound to that seal digest.
    private static func migrateLegacyAuditEpochIfNeeded(
        connection: SQLiteConnection
    ) throws {
        let version = Int(try connection.scalarInt("PRAGMA user_version"))
        guard version < 5 else { return }
        guard version == 4 else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Audit epoch migration requires schema v4, found v\(version)"
            )
        }

        try connection.transaction {
            let rows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
            let verification = try verifyAuditRows(rows)
            switch verification.report.status {
            case .empty, .verified, .sealedLegacyAndVerified:
                break
            case .legacyUnverifiable:
                let legacyRows = try rows.map(decodeAuditRow)
                guard !legacyRows.isEmpty,
                      legacyRows.allSatisfy({ $0.chainVersion == 1 }) else {
                    throw UMISCoreError.sqlite(
                        code: SQLITE_CORRUPT,
                        message: "Legacy audit epoch is not one contiguous v1 prefix"
                    )
                }
                let seal = try legacyEpochSeal(for: legacyRows)
                let sequence = try nextAuditSequence(after: legacyRows.last?.sequence ?? 0)
                let timestampMicros = Int64(
                    (Date().timeIntervalSince1970 * 1_000_000).rounded(.down)
                )
                let payloadDigest = sha256Hex(seal.payload)
                let material = AuditCanonicalMaterial(
                    chainVersion: 2,
                    sequence: sequence,
                    operationID: nil,
                    eventType: legacyEpochGenesisEvent,
                    payloadDigest: payloadDigest,
                    timestampMicros: timestampMicros,
                    previousHash: seal.digest
                )
                let eventHash = try auditHash(material)
                try connection.execute(
                    """
                    INSERT INTO audit_events(
                        sequence, operation_id, event_type, payload, previous_hash, event_hash,
                        created_at, chain_version, payload_digest, created_at_micros
                    ) VALUES(?, NULL, ?, ?, ?, ?, ?, 2, ?, ?)
                    """,
                    [
                        .integer(sequence),
                        .text(legacyEpochGenesisEvent),
                        .blob(seal.payload),
                        .text(seal.digest),
                        .text(eventHash),
                        .double(Double(timestampMicros) / 1_000_000),
                        .text(payloadDigest),
                        .integer(timestampMicros),
                    ]
                )
                let migratedRows = try connection.query(
                    "SELECT * FROM audit_events ORDER BY sequence"
                )
                let migrated = try verifyAuditRows(migratedRows).report
                guard migrated.status == .sealedLegacyAndVerified,
                      migrated.legacyEpochDigest == seal.digest,
                      migrated.canonicalEpochStartSequence == sequence else {
                    throw UMISCoreError.sqlite(
                        code: SQLITE_CORRUPT,
                        message: "Legacy audit epoch seal did not verify before commit"
                    )
                }
            case .invalid:
                throw UMISCoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Refusing to seal an invalid legacy audit epoch: \(verification.report.diagnostic ?? "unknown corruption")"
                )
            }
            try connection.execute("PRAGMA user_version=5")
        }
    }

    /// Schema v6 materializes the fully verified chain head. Startup still verifies every row;
    /// subsequent appends compare this durable head with the last canonical row under
    /// `BEGIN IMMEDIATE`, avoiding a historical scan for every copied item.
    private static func migrateTrustedAuditHeadIfNeeded(
        connection: SQLiteConnection
    ) throws {
        let version = Int(try connection.scalarInt("PRAGMA user_version"))
        guard version < currentSchemaVersion else { return }
        guard version == 5 else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Trusted audit-head migration requires schema v5, found v\(version)"
            )
        }

        try connection.transaction {
            let rows = try connection.query("SELECT * FROM audit_events ORDER BY sequence")
            let verification = try verifyAuditRows(rows).report
            guard verification.isTrusted else {
                throw UMISCoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Cannot create a trusted head for an invalid audit chain"
                )
            }
            let head = try trustedAuditHead(rows: rows, verification: verification)
            try connection.execute(
                """
                CREATE TABLE audit_chain_head(
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    sequence INTEGER NOT NULL CHECK(sequence >= 0),
                    event_count INTEGER NOT NULL CHECK(event_count >= 0),
                    event_hash TEXT NOT NULL CHECK(length(event_hash) = 64),
                    status TEXT NOT NULL CHECK(status IN ('empty', 'verified', 'sealedLegacyAndVerified')),
                    legacy_epoch_digest TEXT,
                    canonical_epoch_start_sequence INTEGER,
                    updated_at_micros INTEGER NOT NULL CHECK(updated_at_micros >= 0),
                    CHECK(sequence = event_count),
                    CHECK(
                        (event_count = 0 AND status = 'empty'
                            AND event_hash = '\(zeroAuditHash)'
                            AND legacy_epoch_digest IS NULL
                            AND canonical_epoch_start_sequence IS NULL)
                        OR
                        (event_count > 0 AND status = 'verified'
                            AND legacy_epoch_digest IS NULL
                            AND canonical_epoch_start_sequence = 1)
                        OR
                        (event_count > 0 AND status = 'sealedLegacyAndVerified'
                            AND length(legacy_epoch_digest) = 64
                            AND canonical_epoch_start_sequence > 1
                            AND canonical_epoch_start_sequence <= sequence)
                    )
                ) STRICT
                """
            )
            try insertTrustedAuditHead(
                head,
                connection: connection,
                updatedAtMicros: Int64((Date().timeIntervalSince1970 * 1_000_000).rounded(.down))
            )
            try connection.execute("PRAGMA user_version=6")
        }
    }

    private static func insertTrustedAuditHead(
        _ head: AuditTrustedHead,
        connection: SQLiteConnection,
        updatedAtMicros: Int64
    ) throws {
        try connection.execute(
            """
            INSERT INTO audit_chain_head(
                singleton, sequence, event_count, event_hash, status,
                legacy_epoch_digest, canonical_epoch_start_sequence, updated_at_micros
            ) VALUES(1, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(head.sequence),
                .integer(head.eventCount),
                .text(head.eventHash),
                .text(head.status.rawValue),
                head.legacyEpochDigest.map(SQLiteValue.text) ?? .null,
                head.canonicalEpochStartSequence.map(SQLiteValue.integer) ?? .null,
                .integer(updatedAtMicros),
            ]
        )
    }

    private static func loadTrustedAuditHead(
        connection: SQLiteConnection
    ) throws -> AuditTrustedHead {
        let rows = try connection.query("SELECT * FROM audit_chain_head")
        guard rows.count == 1,
              let row = rows.first,
              row["singleton"]?.intValue == 1,
              let sequence = row["sequence"]?.intValue,
              let eventCount = row["event_count"]?.intValue,
              let eventHash = row["event_hash"]?.textValue,
              let statusRaw = row["status"]?.textValue,
              let status = AuditChainStatus(rawValue: statusRaw),
              let updatedAtMicros = row["updated_at_micros"]?.intValue,
              updatedAtMicros >= 0 else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Trusted audit-head row is missing or malformed"
            )
        }
        let legacyEpochDigest = row["legacy_epoch_digest"]?.textValue
        let canonicalStart = row["canonical_epoch_start_sequence"]?.intValue
        return try AuditTrustedHead(
            validatingSequence: sequence,
            eventCount: eventCount,
            eventHash: eventHash,
            status: status,
            legacyEpochDigest: legacyEpochDigest,
            canonicalEpochStartSequence: canonicalStart
        )
    }

    private static func trustedAuditHead(
        rows: [SQLiteRow],
        verification: AuditChainVerificationReport
    ) throws -> AuditTrustedHead {
        guard verification.isTrusted, verification.eventCount == rows.count else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "An unverified chain cannot become the trusted audit head"
            )
        }
        guard let last = rows.last else {
            guard verification.status == .empty else {
                throw UMISCoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Empty audit storage has a non-empty verification status"
                )
            }
            return .empty
        }
        guard let sequence = last["sequence"]?.intValue,
              let eventHash = last["event_hash"]?.textValue,
              let eventCount = Int64(exactly: rows.count) else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Verified audit rows do not have a representable head"
            )
        }
        return try AuditTrustedHead(
            validatingSequence: sequence,
            eventCount: eventCount,
            eventHash: eventHash,
            status: verification.status,
            legacyEpochDigest: verification.legacyEpochDigest,
            canonicalEpochStartSequence: verification.canonicalEpochStartSequence
        )
    }

    private static func verifyAuditHeadBoundary(
        connection: SQLiteConnection,
        head: AuditTrustedHead
    ) throws {
        let rows = try connection.query(
            "SELECT * FROM audit_events ORDER BY sequence DESC LIMIT 1"
        )
        if head.eventCount == 0 {
            guard rows.isEmpty, head == .empty else {
                throw UMISCoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Empty trusted audit head has a stored event"
                )
            }
            return
        }
        guard rows.count == 1,
              let row = rows.first else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Trusted audit head has no final event"
            )
        }
        let decoded = try decodeAuditRow(row)
        do {
            try validateCanonicalAuditRow(decoded)
        } catch let failure as AuditVerificationFailure {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Final audit row is not canonical: \(failure.reason)"
            )
        }
        guard decoded.sequence == head.sequence,
              decoded.eventHash == head.eventHash,
              decoded.chainVersion == 2 else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Final audit row does not match the trusted head"
            )
        }
    }

    private static func decodeAuditRow(_ row: SQLiteRow) throws -> AuditStoredRow {
        guard let sequence = row["sequence"]?.intValue,
              let eventType = row["event_type"]?.textValue,
              case let .blob(payload)? = row["payload"],
              let previousHash = row["previous_hash"]?.textValue,
              let eventHash = row["event_hash"]?.textValue,
              let createdAt = row["created_at"]?.doubleValue else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Malformed audit_events row"
            )
        }
        let operationIDStorage = row["operation_id"] ?? .null
        guard operationIDStorage == .null || operationIDStorage.textValue != nil else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Audit operation ID has an invalid storage type"
            )
        }
        return AuditStoredRow(
            sequence: sequence,
            operationIDStorage: operationIDStorage,
            eventType: eventType,
            payload: payload,
            previousHash: previousHash,
            eventHash: eventHash,
            createdAt: createdAt,
            chainVersion: row["chain_version"]?.intValue ?? 1,
            payloadDigest: row["payload_digest"]?.textValue,
            createdAtMicros: row["created_at_micros"]?.intValue
        )
    }

    private static func legacyEpochSeal(
        for rows: [AuditStoredRow]
    ) throws -> LegacyAuditSeal {
        guard let first = rows.first, let last = rows.last, !rows.isEmpty else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Cannot seal an empty legacy audit epoch"
            )
        }
        guard rows.allSatisfy({ $0.chainVersion == 1 }) else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Legacy audit seal contains a non-v1 row"
            )
        }
        let storedRows = try rows.map { row -> LegacyAuditStoredRowMaterial in
            let operationID: String?
            switch row.operationIDStorage {
            case .null: operationID = nil
            case let .text(raw): operationID = raw
            default:
                throw UMISCoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Legacy audit operation ID has an invalid storage type"
                )
            }
            return LegacyAuditStoredRowMaterial(
                sequence: row.sequence,
                operationID: operationID,
                eventType: row.eventType,
                payloadDigest: sha256Hex(row.payload),
                previousHash: row.previousHash,
                eventHash: row.eventHash,
                createdAtBitPattern: row.createdAt.bitPattern,
                chainVersion: row.chainVersion,
                storedPayloadDigest: row.payloadDigest,
                storedCreatedAtMicros: row.createdAtMicros
            )
        }
        let material = LegacyAuditEpochDigestMaterial(
            domain: "jp.rinkan.umis.audit.legacy-epoch-seal",
            schemaVersion: 1,
            eventCount: storedRows.count,
            firstSequence: first.sequence,
            lastSequence: last.sequence,
            rows: storedRows
        )
        let digest = sha256Hex(try StableJSON.encode(material))
        let envelope = LegacyAuditEpochSealEnvelope(
            schemaVersion: 1,
            legacyEpochDigest: digest,
            eventCount: storedRows.count,
            firstSequence: first.sequence,
            lastSequence: last.sequence
        )
        return LegacyAuditSeal(
            digest: digest,
            payload: try StableJSON.encode(envelope)
        )
    }

    private static func canonicalOperationID(_ storage: SQLiteValue) throws -> String? {
        switch storage {
        case .null:
            return nil
        case let .text(raw):
            guard let parsed = UUID(uuidString: raw),
                  raw == parsed.uuidString.lowercased() else {
                throw AuditVerificationFailure(reason: "Audit operation ID is malformed")
            }
            return parsed.uuidString.lowercased()
        default:
            throw AuditVerificationFailure(
                reason: "Audit operation ID has an invalid storage type"
            )
        }
    }

    private static func validateCanonicalAuditRow(_ row: AuditStoredRow) throws {
        guard row.chainVersion == 2 else {
            throw AuditVerificationFailure(reason: "Audit row is not canonical v2")
        }
        let operationID = try canonicalOperationID(row.operationIDStorage)
        guard let payloadDigest = row.payloadDigest,
              payloadDigest == payloadDigest.lowercased(),
              payloadDigest.utf8.count == 64,
              payloadDigest == sha256Hex(row.payload),
              let timestampMicros = row.createdAtMicros,
              row.createdAt == Double(timestampMicros) / 1_000_000 else {
            throw AuditVerificationFailure(
                reason: "Audit payload digest or timestamp representation does not match"
            )
        }
        let material = AuditCanonicalMaterial(
            chainVersion: 2,
            sequence: row.sequence,
            operationID: operationID,
            eventType: row.eventType,
            payloadDigest: payloadDigest,
            timestampMicros: timestampMicros,
            previousHash: row.previousHash
        )
        guard row.eventHash == (try auditHash(material)) else {
            throw AuditVerificationFailure(
                reason: "Audit canonical event hash does not match"
            )
        }
    }

    private static func nextAuditSequence(after sequence: Int64) throws -> Int64 {
        let (next, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else {
            throw UMISCoreError.sqlite(
                code: SQLITE_CORRUPT,
                message: "Audit sequence exhausted the signed 64-bit range"
            )
        }
        return next
    }

    private static func verifyAuditRows(_ rows: [SQLiteRow]) throws -> AuditRowsVerification {
        guard !rows.isEmpty else {
            return AuditRowsVerification(
                report: AuditChainVerificationReport(
                    status: .empty,
                    eventCount: 0,
                    verifiedEventCount: 0
                ),
                entryStatus: [:]
            )
        }
        let decoded = try rows.map(decodeAuditRow)
        var entryStatus: [Int64: AuditChainEntryVerification] = [:]
        var expectedSequence: Int64 = 1
        var sawCanonical = false
        var structuralFailure: (sequence: Int64, reason: String)?
        for row in decoded {
            if structuralFailure == nil, row.sequence != expectedSequence {
                structuralFailure = (
                    row.sequence,
                    "Audit sequence is missing, duplicated, or reordered"
                )
            }
            let (nextSequence, sequenceOverflow) = row.sequence.addingReportingOverflow(1)
            if sequenceOverflow {
                if structuralFailure == nil {
                    structuralFailure = (
                        row.sequence,
                        "Audit sequence exhausted the signed 64-bit range"
                    )
                }
            } else {
                expectedSequence = nextSequence
            }
            switch row.chainVersion {
            case 1:
                if sawCanonical, structuralFailure == nil {
                    structuralFailure = (
                        row.sequence,
                        "Legacy audit material appears after the canonical epoch began"
                    )
                }
            case 2:
                sawCanonical = true
            default:
                if structuralFailure == nil {
                    structuralFailure = (row.sequence, "Unsupported audit chain version")
                }
            }
        }

        let legacyRows = decoded.prefix { $0.chainVersion == 1 }
        var expectedLegacyPrevious = zeroAuditHash
        for row in legacyRows {
            if structuralFailure == nil, row.previousHash != expectedLegacyPrevious {
                structuralFailure = (
                    row.sequence,
                    "Legacy audit previous-hash structure is inconsistent"
                )
            }
            expectedLegacyPrevious = row.eventHash
        }
        if let structuralFailure {
            for row in decoded {
                entryStatus[row.sequence] = .invalid
            }
            return AuditRowsVerification(
                report: AuditChainVerificationReport(
                    status: .invalid,
                    eventCount: decoded.count,
                    verifiedEventCount: 0,
                    firstUntrustedSequence: structuralFailure.sequence,
                    diagnostic: structuralFailure.reason,
                    legacySealedEventCount: legacyRows.count
                ),
                entryStatus: entryStatus
            )
        }

        let legacyDigest = legacyRows.isEmpty
            ? nil
            : try legacyEpochSeal(for: Array(legacyRows)).digest
        for row in legacyRows {
            entryStatus[row.sequence] = .legacyUnverifiable
        }
        let canonicalRows = decoded.dropFirst(legacyRows.count)
        guard !canonicalRows.isEmpty else {
            return AuditRowsVerification(
                report: AuditChainVerificationReport(
                    status: .legacyUnverifiable,
                    eventCount: decoded.count,
                    verifiedEventCount: 0,
                    firstUntrustedSequence: legacyRows.first?.sequence,
                    diagnostic: "Legacy audit material is not yet sealed by a canonical epoch",
                    legacySealedEventCount: legacyRows.count,
                    legacyEpochDigest: legacyDigest
                ),
                entryStatus: entryStatus
            )
        }

        let canonicalStart = canonicalRows.first?.sequence
        var expectedCanonicalPrevious = legacyDigest ?? zeroAuditHash
        var verifiedCount = 0
        var canonicalFailure: (sequence: Int64, reason: String)?
        if !legacyRows.isEmpty,
           let genesis = canonicalRows.first,
           let legacyDigest {
            let expectedSeal = try legacyEpochSeal(for: Array(legacyRows))
            if genesis.eventType != legacyEpochGenesisEvent
                || genesis.operationIDStorage != .null
                || genesis.previousHash != legacyDigest
                || genesis.payload != expectedSeal.payload {
                canonicalFailure = (
                    genesis.sequence,
                    "Canonical genesis does not bind the exact sealed legacy epoch"
                )
            }
        }

        for row in canonicalRows {
            if canonicalFailure != nil {
                entryStatus[row.sequence] = .invalid
                continue
            }
            guard row.previousHash == expectedCanonicalPrevious else {
                canonicalFailure = (row.sequence, "Audit previous-hash link does not match")
                entryStatus[row.sequence] = .invalid
                continue
            }
            do {
                try validateCanonicalAuditRow(row)
                entryStatus[row.sequence] = .verified
                verifiedCount += 1
                expectedCanonicalPrevious = row.eventHash
            } catch let failure as AuditVerificationFailure {
                canonicalFailure = (row.sequence, failure.reason)
                entryStatus[row.sequence] = .invalid
            }
        }

        if let canonicalFailure {
            return AuditRowsVerification(
                report: AuditChainVerificationReport(
                    status: .invalid,
                    eventCount: decoded.count,
                    verifiedEventCount: verifiedCount,
                    firstUntrustedSequence: canonicalFailure.sequence,
                    diagnostic: canonicalFailure.reason,
                    legacySealedEventCount: legacyRows.count,
                    canonicalEpochStartSequence: canonicalStart,
                    legacyEpochDigest: legacyDigest
                ),
                entryStatus: entryStatus
            )
        }
        let status: AuditChainStatus = legacyRows.isEmpty
            ? .verified
            : .sealedLegacyAndVerified
        return AuditRowsVerification(
            report: AuditChainVerificationReport(
                status: status,
                eventCount: decoded.count,
                verifiedEventCount: verifiedCount,
                firstUntrustedSequence: legacyRows.first?.sequence,
                diagnostic: legacyRows.isEmpty
                    ? nil
                    : "Legacy epoch remains unverified and is sealed by the canonical genesis",
                legacySealedEventCount: legacyRows.count,
                canonicalEpochStartSequence: canonicalStart,
                legacyEpochDigest: legacyDigest
            ),
            entryStatus: entryStatus
        )
    }

    private static func decodeOperationSummary(_ row: SQLiteRow) -> OperationSummary? {
        guard
            let idString = row["id"]?.textValue,
            let id = UUID(uuidString: idString),
            let kindRaw = row["kind"]?.textValue,
            let kind = OperationKind(rawValue: kindRaw),
            let statusRaw = row["status"]?.textValue,
            let status = OperationStatus(rawValue: statusRaw),
            let created = row["created_at"]?.doubleValue,
            let updated = row["updated_at"]?.doubleValue
        else { return nil }
        return OperationSummary(
            id: id,
            kind: kind,
            status: status,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private static func decodeDestructiveQuarantine(
        _ row: SQLiteRow
    ) throws -> DestructiveQuarantineRecord {
        guard let keyRaw = row["physical_key"]?.textValue,
              let operationRaw = row["operation_id"]?.textValue,
              let operationID = UUID(uuidString: operationRaw),
              let sourceIdentityDigest = row["source_identity_digest"]?.textValue,
              sourceIdentityDigest.utf8.count == 64,
              let reason = row["reason"]?.textValue,
              !reason.isEmpty,
              let createdAt = row["created_at"]?.doubleValue else {
            throw UMISCoreError.sqlite(code: SQLITE_CORRUPT, message: "Malformed destructive_quarantines row")
        }
        return DestructiveQuarantineRecord(
            physicalKey: try PhysicalMediaQuarantineKey(rawValue: keyRaw),
            operationID: operationID,
            sourceIdentityDigest: sourceIdentityDigest,
            reason: reason,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

private struct AuditCanonicalMaterial: Codable, Hashable, Sendable {
    var chainVersion: Int
    var sequence: Int64
    var operationID: String?
    var eventType: String
    var payloadDigest: String
    var timestampMicros: Int64
    var previousHash: String
}

private struct AuditStoredRow: Sendable {
    var sequence: Int64
    var operationIDStorage: SQLiteValue
    var eventType: String
    var payload: Data
    var previousHash: String
    var eventHash: String
    var createdAt: Double
    var chainVersion: Int64
    var payloadDigest: String?
    var createdAtMicros: Int64?
}

private struct LegacyAuditStoredRowMaterial: Codable, Hashable, Sendable {
    var sequence: Int64
    var operationID: String?
    var eventType: String
    var payloadDigest: String
    var previousHash: String
    var eventHash: String
    var createdAtBitPattern: UInt64
    var chainVersion: Int64
    var storedPayloadDigest: String?
    var storedCreatedAtMicros: Int64?
}

private struct LegacyAuditEpochDigestMaterial: Codable, Hashable, Sendable {
    var domain: String
    var schemaVersion: Int
    var eventCount: Int
    var firstSequence: Int64
    var lastSequence: Int64
    var rows: [LegacyAuditStoredRowMaterial]
}

private struct LegacyAuditEpochSealEnvelope: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var legacyEpochDigest: String
    var eventCount: Int
    var firstSequence: Int64
    var lastSequence: Int64
}

private struct LegacyAuditSeal: Sendable {
    var digest: String
    var payload: Data
}

private struct AuditVerificationFailure: Error, Sendable {
    var reason: String
}

private struct AuditRowsVerification: Sendable {
    var report: AuditChainVerificationReport
    var entryStatus: [Int64: AuditChainEntryVerification]
}

/// The durable, startup-verified boundary used to make the normal append path independent of
/// historical chain length. This is deliberately stricter than the SQLite table constraints so a
/// future migration or externally modified database cannot be accepted merely because it parses.
private struct AuditTrustedHead: Equatable, Sendable {
    static let empty = AuditTrustedHead(
        uncheckedSequence: 0,
        eventCount: 0,
        eventHash: String(repeating: "0", count: 64),
        status: .empty,
        legacyEpochDigest: nil,
        canonicalEpochStartSequence: nil
    )

    var sequence: Int64
    var eventCount: Int64
    var eventHash: String
    var status: AuditChainStatus
    var legacyEpochDigest: String?
    var canonicalEpochStartSequence: Int64?

    init(
        validatingSequence sequence: Int64,
        eventCount: Int64,
        eventHash: String,
        status: AuditChainStatus,
        legacyEpochDigest: String?,
        canonicalEpochStartSequence: Int64?
    ) throws {
        guard sequence >= 0,
              eventCount >= 0,
              sequence == eventCount,
              Self.isCanonicalSHA256(eventHash) else {
            throw Self.corrupt("Trusted audit-head counters or hash are malformed")
        }

        switch status {
        case .empty:
            guard sequence == 0,
                  eventHash == Self.empty.eventHash,
                  legacyEpochDigest == nil,
                  canonicalEpochStartSequence == nil else {
                throw Self.corrupt("Empty trusted audit head has non-empty state")
            }
        case .verified:
            guard sequence > 0,
                  legacyEpochDigest == nil,
                  canonicalEpochStartSequence == 1 else {
                throw Self.corrupt("Canonical trusted audit head has inconsistent epoch metadata")
            }
        case .sealedLegacyAndVerified:
            guard sequence > 0,
                  let legacyEpochDigest,
                  Self.isCanonicalSHA256(legacyEpochDigest),
                  let canonicalEpochStartSequence,
                  canonicalEpochStartSequence > 1,
                  canonicalEpochStartSequence <= sequence else {
                throw Self.corrupt("Sealed-legacy trusted audit head has inconsistent epoch metadata")
            }
        case .legacyUnverifiable, .invalid:
            throw Self.corrupt("An untrusted audit status cannot be materialized as a trusted head")
        }

        self.init(
            uncheckedSequence: sequence,
            eventCount: eventCount,
            eventHash: eventHash,
            status: status,
            legacyEpochDigest: legacyEpochDigest,
            canonicalEpochStartSequence: canonicalEpochStartSequence
        )
    }

    func appending(sequence nextSequence: Int64, eventHash nextEventHash: String) throws -> Self {
        let (expectedSequence, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow, nextSequence == expectedSequence else {
            throw Self.corrupt("Audit append does not immediately follow the trusted head")
        }
        let (nextCount, countOverflow) = eventCount.addingReportingOverflow(1)
        guard !countOverflow, nextCount == nextSequence else {
            throw Self.corrupt("Audit event count cannot advance with the append sequence")
        }

        return try Self(
            validatingSequence: nextSequence,
            eventCount: nextCount,
            eventHash: nextEventHash,
            status: status == .empty ? .verified : status,
            legacyEpochDigest: legacyEpochDigest,
            canonicalEpochStartSequence: status == .empty ? 1 : canonicalEpochStartSequence
        )
    }

    private init(
        uncheckedSequence sequence: Int64,
        eventCount: Int64,
        eventHash: String,
        status: AuditChainStatus,
        legacyEpochDigest: String?,
        canonicalEpochStartSequence: Int64?
    ) {
        self.sequence = sequence
        self.eventCount = eventCount
        self.eventHash = eventHash
        self.status = status
        self.legacyEpochDigest = legacyEpochDigest
        self.canonicalEpochStartSequence = canonicalEpochStartSequence
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func corrupt(_ message: String) -> UMISCoreError {
        UMISCoreError.sqlite(code: SQLITE_CORRUPT, message: message)
    }
}

private enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var textValue: String? { if case let .text(value) = self { value } else { nil } }
    var intValue: Int64? { if case let .integer(value) = self { value } else { nil } }
    var doubleValue: Double? {
        switch self {
        case let .double(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
}

private typealias SQLiteRow = [String: SQLiteValue]

private final class SQLiteConnection: @unchecked Sendable {
    private var database: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let database { sqlite3_close_v2(database) }
            database = nil
            throw UMISCoreError.sqlite(code: code, message: message)
        }
        sqlite3_extended_result_codes(database, 1)
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    var changes: Int { Int(sqlite3_changes(database)) }

    func configureAndMigrate() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
        let version = Int(try scalarInt("PRAGMA user_version"))
        guard version <= OperationStore.currentSchemaVersion else {
            throw UMISCoreError.sqlite(code: SQLITE_ERROR, message: "Database schema \(version) is newer than this app")
        }
        if version < 1 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE operations(
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        status TEXT NOT NULL,
                        plan_json BLOB NOT NULL,
                        receipt_json BLOB,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    ) STRICT
                    """
                )
                try execute(
                    """
                    CREATE TABLE operation_items(
                        operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
                        item_id TEXT NOT NULL,
                        asset_id TEXT NOT NULL,
                        state TEXT NOT NULL,
                        bytes_copied INTEGER NOT NULL DEFAULT 0 CHECK(bytes_copied >= 0),
                        partial_path TEXT NOT NULL,
                        final_path TEXT NOT NULL,
                        source_hash TEXT,
                        destination_hash TEXT,
                        receipt_json BLOB,
                        error TEXT,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY(operation_id, item_id)
                    ) STRICT
                    """
                )
                try execute(
                    """
                    CREATE TABLE audit_events(
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        operation_id TEXT,
                        event_type TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        previous_hash TEXT NOT NULL,
                        event_hash TEXT NOT NULL UNIQUE,
                        created_at REAL NOT NULL
                    ) STRICT
                    """
                )
                try execute("PRAGMA user_version=1")
            }
        }
        if Int(try scalarInt("PRAGMA user_version")) < 2 {
            try transaction {
                try execute("CREATE INDEX operation_status_updated_idx ON operations(status, updated_at)")
                try execute("CREATE INDEX operation_item_state_idx ON operation_items(operation_id, state)")
                try execute("CREATE INDEX audit_operation_idx ON audit_events(operation_id, sequence)")
                try execute("PRAGMA user_version=2")
            }
        }
        if Int(try scalarInt("PRAGMA user_version")) < 3 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE destructive_quarantines(
                        physical_key TEXT PRIMARY KEY,
                        operation_id TEXT NOT NULL,
                        source_identity_digest TEXT NOT NULL,
                        reason TEXT NOT NULL,
                        created_at REAL NOT NULL
                    ) STRICT
                    """
                )
                try execute("CREATE INDEX destructive_quarantine_created_idx ON destructive_quarantines(created_at)")
                try execute("PRAGMA user_version=3")
            }
        }
        if Int(try scalarInt("PRAGMA user_version")) < 4 {
            try transaction {
                // Existing rows retain chain_version=1 and null canonical fields. They are exposed
                // as legacyUnverifiable and can never be silently re-hashed into trusted history.
                try execute("ALTER TABLE audit_events ADD COLUMN chain_version INTEGER NOT NULL DEFAULT 1")
                try execute("ALTER TABLE audit_events ADD COLUMN payload_digest TEXT")
                try execute("ALTER TABLE audit_events ADD COLUMN created_at_micros INTEGER")
                try execute("PRAGMA user_version=4")
            }
        }
    }

    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { try check(code); return }
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { try check(code); return rows }
            var row: SQLiteRow = [:]
            for index in 0 ..< sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 {
                        row[name] = .blob(Data())
                    } else if let pointer = sqlite3_column_blob(statement, index) {
                        row[name] = .blob(Data(bytes: pointer, count: count))
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
    }

    func queryOne(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteRow? {
        try query(sql, bindings).first
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        guard let row = try queryOne(sql), let value = row.values.first?.intValue else {
            throw UMISCoreError.sqlite(code: SQLITE_ERROR, message: "Expected integer result")
        }
        return value
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case let .integer(number):
                code = sqlite3_bind_int64(statement, index, number)
            case let .double(number):
                code = sqlite3_bind_double(statement, index, number)
            case let .text(string):
                code = sqlite3_bind_text(statement, index, string, -1, transient)
            case let .blob(data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
            }
            try check(code)
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            throw UMISCoreError.sqlite(code: code, message: message)
        }
    }
}
