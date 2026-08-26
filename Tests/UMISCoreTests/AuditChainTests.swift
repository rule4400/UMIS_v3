import Foundation
import XCTest
@testable import UMISCore

final class AuditChainTests: XCTestCase {
    func testCanonicalAuditChainAndRedactedExportRemainVerifiable() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let store = try OperationStore(databaseURL: fixture.database)
        let operationID = UUID()
        try await store.appendAudit(
            operationID: operationID,
            event: "test.started",
            payload: Data("sensitive-path".utf8)
        )
        try await store.appendAudit(
            operationID: operationID,
            event: "test.completed",
            payload: Data("receipt".utf8)
        )

        let report = try await store.verifyAuditChain()
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.eventCount, 2)
        XCTAssertEqual(report.verifiedEventCount, 2)
        XCTAssertNil(report.firstUntrustedSequence)

        let redacted = try await store.auditExport(operationID: operationID)
        XCTAssertEqual(redacted.count, 2)
        XCTAssertTrue(redacted.allSatisfy(\.isPayloadRedacted))
        XCTAssertTrue(redacted.allSatisfy(\.payload.isEmpty))
        XCTAssertTrue(redacted.allSatisfy { $0.payloadDigest.utf8.count == 64 })
        XCTAssertTrue(redacted.allSatisfy { $0.chainVerification == .verified })
        let sensitive = try await store.auditExport(
            operationID: operationID,
            includeSensitivePayload: true
        )
        XCTAssertEqual(sensitive.first?.payload, Data("sensitive-path".utf8))
        XCTAssertEqual(sensitive.map(\.payloadDigest), redacted.map(\.payloadDigest))
    }

    func testAuditChainDetectsEverySecurityBoundFieldAndForkTampering() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let otherOperationID = UUID().uuidString.lowercased()
        let mutations: [(String, String)] = [
            ("payload", "UPDATE audit_events SET payload=X'74616d7065726564' WHERE sequence=1"),
            ("operation", "UPDATE audit_events SET operation_id='\(otherOperationID)' WHERE sequence=1"),
            ("event", "UPDATE audit_events SET event_type='tampered.event' WHERE sequence=1"),
            ("timestamp", "UPDATE audit_events SET created_at_micros=created_at_micros+1 WHERE sequence=1"),
            ("previous", "UPDATE audit_events SET previous_hash='\(String(repeating: "f", count: 64))' WHERE sequence=2"),
            ("event-hash", "UPDATE audit_events SET event_hash='\(String(repeating: "e", count: 64))' WHERE sequence=1"),
            ("fork-gap", "UPDATE audit_events SET sequence=5 WHERE sequence=2"),
            ("sequence-overflow", "UPDATE audit_events SET sequence=9223372036854775807 WHERE sequence=2"),
        ]

        for (index, mutation) in mutations.enumerated() {
            let database = fixture.root.appendingPathComponent("audit-tamper-\(index).sqlite")
            let store = try OperationStore(databaseURL: database)
            let operationID = UUID()
            try await store.appendAudit(
                operationID: operationID,
                event: "test.one",
                payload: Data("one".utf8)
            )
            try await store.appendAudit(
                operationID: operationID,
                event: "test.two",
                payload: Data("two".utf8)
            )
            try Self.runSQLite(database: database, statement: mutation.1)

            let report = try await store.verifyAuditChain()
            XCTAssertEqual(report.status, .invalid, "Mutation was not detected: \(mutation.0)")
            XCTAssertNotNil(report.firstUntrustedSequence)
            let exported = try await store.auditExport()
            XCTAssertTrue(
                exported.contains(where: { $0.chainVerification == .invalid }),
                "Export did not expose invalid verification: \(mutation.0)"
            )
            do {
                try await store.appendAudit(operationID: operationID, event: "must.block")
                XCTFail("Appending to a corrupt chain must fail: \(mutation.0)")
            } catch let error as UMISCoreError {
                guard case .sqlite = error else { return XCTFail("Unexpected error: \(error)") }
            }
            do {
                _ = try OperationStore(databaseURL: database)
                XCTFail("Startup must reject a corrupt audit chain: \(mutation.0)")
            } catch let error as UMISCoreError {
                guard case .sqlite = error else { return XCTFail("Unexpected startup error: \(error)") }
            }
        }
    }

    func testLegacyAuditRowsAreSealedWithoutBlessingAndCanonicalAppendContinues() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("legacy-audit.sqlite")
        try Self.runSQLite(
            database: database,
            statement: """
            PRAGMA user_version=3;
            CREATE TABLE operations(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, plan_json BLOB NOT NULL,
                receipt_json BLOB, created_at REAL NOT NULL, updated_at REAL NOT NULL
            ) STRICT;
            CREATE TABLE operation_items(
                operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
                item_id TEXT NOT NULL, asset_id TEXT NOT NULL, state TEXT NOT NULL,
                bytes_copied INTEGER NOT NULL DEFAULT 0 CHECK(bytes_copied >= 0),
                partial_path TEXT NOT NULL, final_path TEXT NOT NULL, source_hash TEXT,
                destination_hash TEXT, receipt_json BLOB, error TEXT, updated_at REAL NOT NULL,
                PRIMARY KEY(operation_id, item_id)
            ) STRICT;
            CREATE TABLE audit_events(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT, event_type TEXT NOT NULL,
                payload BLOB NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            ) STRICT;
            CREATE TABLE destructive_quarantines(
                physical_key TEXT PRIMARY KEY, operation_id TEXT NOT NULL,
                source_identity_digest TEXT NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL
            ) STRICT;
            INSERT INTO audit_events(operation_id,event_type,payload,previous_hash,event_hash,created_at)
            VALUES(NULL,'legacy',X'00','0000000000000000000000000000000000000000000000000000000000000000',
            '1111111111111111111111111111111111111111111111111111111111111111',1.0);
            """
        )

        let store = try OperationStore(databaseURL: database)
        let report = try await store.verifyAuditChain()
        let migratedSchemaVersion = try await store.schemaVersion()
        XCTAssertEqual(migratedSchemaVersion, OperationStore.currentSchemaVersion)
        XCTAssertEqual(report.status, .sealedLegacyAndVerified)
        XCTAssertEqual(report.eventCount, 2)
        XCTAssertEqual(report.verifiedEventCount, 1)
        XCTAssertEqual(report.legacySealedEventCount, 1)
        XCTAssertEqual(report.canonicalEpochStartSequence, 2)
        XCTAssertEqual(report.legacyEpochDigest?.count, 64)
        XCTAssertTrue(report.isTrusted)
        let exported = try await store.auditExport()
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported.first?.chainVerification, .legacyUnverifiable)
        XCTAssertEqual(exported.first?.epoch, .sealedLegacyV1)
        XCTAssertEqual(exported.first?.isEpochGenesis, true)
        XCTAssertEqual(exported[1].chainVerification, .verified)
        XCTAssertEqual(exported[1].epoch, .canonicalV2)
        XCTAssertTrue(exported[1].isEpochGenesis)
        XCTAssertEqual(exported[1].predecessorEpochDigest, report.legacyEpochDigest)

        let sensitive = try await store.auditExport(includeSensitivePayload: true)
        XCTAssertEqual(sensitive.first?.payload, Data([0]))
        try await store.appendAudit(operationID: nil, event: "canonical.afterMigration")
        let continued = try await store.verifyAuditChain()
        XCTAssertEqual(continued.status, .sealedLegacyAndVerified)
        XCTAssertEqual(continued.eventCount, 3)
        XCTAssertEqual(continued.verifiedEventCount, 2)

        let reopened = try OperationStore(databaseURL: database)
        let reopenedCount = try await reopened.auditEventCount()
        let reopenedReport = try await reopened.verifyAuditChain()
        XCTAssertEqual(reopenedCount, 3)
        XCTAssertEqual(reopenedReport.status, .sealedLegacyAndVerified)
    }

    func testLegacyAuditMigrationSupportsV1ThroughV3AndPreservesOperationFilter() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        for schemaVersion in 1 ... 3 {
            let database = fixture.root.appendingPathComponent(
                "legacy-audit-v\(schemaVersion).sqlite"
            )
            let operationID = UUID()
            try Self.createLegacyDatabase(
                database: database,
                schemaVersion: schemaVersion,
                operationID: operationID
            )

            let store = try OperationStore(databaseURL: database)
            let report = try await store.verifyAuditChain()
            let migratedSchemaVersion = try await store.schemaVersion()
            XCTAssertEqual(migratedSchemaVersion, OperationStore.currentSchemaVersion)
            XCTAssertEqual(report.status, .sealedLegacyAndVerified)
            XCTAssertEqual(report.eventCount, 3)
            XCTAssertEqual(report.verifiedEventCount, 1)
            XCTAssertEqual(report.legacySealedEventCount, 2)
            XCTAssertEqual(report.canonicalEpochStartSequence, 3)

            // v1-v3 stored UUID strings using UUID.uuidString's upper-case representation.
            // Filtering remains able to export those exact legacy rows after canonical v2 moved
            // new IDs to lower-case storage.
            let filtered = try await store.auditExport(
                operationID: operationID,
                includeSensitivePayload: true
            )
            XCTAssertEqual(filtered.map(\.sequence), [1])
            XCTAssertEqual(filtered.first?.payload, Data([0]))
            XCTAssertEqual(filtered.first?.epoch, .sealedLegacyV1)
            XCTAssertEqual(filtered.first?.chainVerification, .legacyUnverifiable)
        }
    }

    func testTamperingSealedLegacyEpochInvalidatesGenesisAndBlocksStartupAndAppend() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("legacy-seal-tamper.sqlite")
        try Self.createLegacyV3Database(database: database)
        let store = try OperationStore(databaseURL: database)
        let initialReport = try await store.verifyAuditChain()
        XCTAssertEqual(initialReport.status, .sealedLegacyAndVerified)

        try Self.runSQLite(
            database: database,
            statement: "UPDATE audit_events SET payload=X'74616d7065726564' WHERE sequence=1"
        )
        let report = try await store.verifyAuditChain()
        XCTAssertEqual(report.status, .invalid)
        XCTAssertEqual(report.canonicalEpochStartSequence, 2)
        let exported = try await store.auditExport()
        XCTAssertEqual(exported.first?.epoch, .sealedLegacyV1)
        XCTAssertEqual(exported[1].chainVerification, .invalid)
        do {
            try await store.appendAudit(operationID: nil, event: "must.block")
            XCTFail("A changed sealed legacy epoch must block canonical append")
        } catch let error as UMISCoreError {
            guard case .sqlite = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try OperationStore(databaseURL: database)) { error in
            guard case UMISCoreError.sqlite = error else {
                return XCTFail("Unexpected startup error: \(error)")
            }
        }
    }

    func testLegacySealMigrationRollsBackAtomicallyAndCanRetry() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("legacy-seal-rollback.sqlite")
        try Self.runSQLite(
            database: database,
            statement: """
            PRAGMA user_version=4;
            CREATE TABLE audit_events(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT, event_type TEXT NOT NULL,
                payload BLOB NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL, chain_version INTEGER NOT NULL DEFAULT 1,
                payload_digest TEXT, created_at_micros INTEGER
            ) STRICT;
            INSERT INTO audit_events(
                operation_id,event_type,payload,previous_hash,event_hash,created_at,chain_version
            ) VALUES(
                NULL,'legacy',X'00',
                '0000000000000000000000000000000000000000000000000000000000000000',
                '1111111111111111111111111111111111111111111111111111111111111111',1.0,1
            );
            CREATE TRIGGER reject_audit_epoch_genesis
            BEFORE INSERT ON audit_events WHEN NEW.chain_version=2
            BEGIN SELECT RAISE(ABORT, 'forced migration failure'); END;
            """
        )

        XCTAssertThrowsError(try OperationStore(databaseURL: database))
        XCTAssertEqual(try Self.sqliteScalar(database: database, query: "PRAGMA user_version"), 4)
        XCTAssertEqual(
            try Self.sqliteScalar(database: database, query: "SELECT COUNT(*) FROM audit_events"),
            1
        )

        try Self.runSQLite(
            database: database,
            statement: "DROP TRIGGER reject_audit_epoch_genesis"
        )
        let recovered = try OperationStore(databaseURL: database)
        let recoveredVersion = try await recovered.schemaVersion()
        let recoveredCount = try await recovered.auditEventCount()
        let recoveredReport = try await recovered.verifyAuditChain()
        XCTAssertEqual(recoveredVersion, OperationStore.currentSchemaVersion)
        XCTAssertEqual(recoveredCount, 2)
        XCTAssertEqual(recoveredReport.status, .sealedLegacyAndVerified)
    }

    func testV4CanonicalDatabaseUpgradesWithoutInjectingLegacyGenesis() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("canonical-v4.sqlite")
        var original: OperationStore? = try OperationStore(databaseURL: database)
        try await original?.appendAudit(operationID: nil, event: "canonical.existing")
        let originalCount = try await original?.auditEventCount()
        XCTAssertEqual(originalCount, 1)
        original = nil
        try Self.runSQLite(
            database: database,
            statement: "DROP TABLE audit_chain_head; PRAGMA user_version=4"
        )

        let upgraded = try OperationStore(databaseURL: database)
        let upgradedVersion = try await upgraded.schemaVersion()
        let upgradedCount = try await upgraded.auditEventCount()
        XCTAssertEqual(upgradedVersion, OperationStore.currentSchemaVersion)
        XCTAssertEqual(upgradedCount, 1)
        let report = try await upgraded.verifyAuditChain()
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.legacySealedEventCount, 0)
        XCTAssertNil(report.legacyEpochDigest)
        XCTAssertEqual(report.canonicalEpochStartSequence, 1)
    }

    func testNormalTenThousandAppendsNeverRescanHistoricalRows() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("audit-head-scaling.sqlite")
        let store = try OperationStore(databaseURL: database)
        let before = await store.auditAppendInstrumentationForTesting()
        XCTAssertEqual(before.fullChainVerificationPassCount, 1)
        XCTAssertEqual(before.fullChainVerifiedRowCount, 0)
        XCTAssertEqual(before.headBoundaryVerificationCount, 0)

        let operationID = UUID()
        for index in 0 ..< 10_000 {
            try await store.appendAudit(
                operationID: operationID,
                event: "scale.append.\(index)"
            )
        }

        let afterAppend = await store.auditAppendInstrumentationForTesting()
        XCTAssertEqual(afterAppend.fullChainVerificationPassCount, before.fullChainVerificationPassCount)
        XCTAssertEqual(afterAppend.fullChainVerifiedRowCount, before.fullChainVerifiedRowCount)
        XCTAssertEqual(
            afterAppend.headBoundaryVerificationCount - before.headBoundaryVerificationCount,
            10_000
        )
        let appendedEventCount = try await store.auditEventCount()
        XCTAssertEqual(appendedEventCount, 10_000)

        // Explicit verification intentionally remains O(N), independent of the append fast path.
        let report = try await store.verifyAuditChain()
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.eventCount, 10_000)
        XCTAssertEqual(report.verifiedEventCount, 10_000)
        let afterExplicitVerification = await store.auditAppendInstrumentationForTesting()
        XCTAssertEqual(
            afterExplicitVerification.fullChainVerificationPassCount,
            afterAppend.fullChainVerificationPassCount + 1
        )
        XCTAssertEqual(
            afterExplicitVerification.fullChainVerifiedRowCount,
            afterAppend.fullChainVerifiedRowCount + 10_000
        )

        let exported = try await store.auditExport(operationID: operationID, limit: 10_000)
        XCTAssertEqual(exported.count, 10_000)
        XCTAssertTrue(exported.allSatisfy { $0.chainVerification == .verified })
        let afterExplicitExport = await store.auditAppendInstrumentationForTesting()
        XCTAssertEqual(
            afterExplicitExport.fullChainVerificationPassCount,
            afterExplicitVerification.fullChainVerificationPassCount + 1
        )
        XCTAssertEqual(
            afterExplicitExport.fullChainVerifiedRowCount,
            afterExplicitVerification.fullChainVerifiedRowCount + 10_000
        )
    }

    func testPersistedTrustedHeadTamperingBlocksAppendAndStartup() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("audit-head-tamper.sqlite")
        let store = try OperationStore(databaseURL: database)
        try await store.appendAudit(operationID: nil, event: "head.one")
        try await store.appendAudit(operationID: nil, event: "head.two")
        try Self.runSQLite(
            database: database,
            statement: "UPDATE audit_chain_head SET event_hash='\(String(repeating: "e", count: 64))'"
        )

        do {
            try await store.appendAudit(operationID: nil, event: "must.block")
            XCTFail("A changed durable audit head must block append")
        } catch let error as UMISCoreError {
            guard case .sqlite = error else { return XCTFail("Unexpected append error: \(error)") }
        }
        let eventCountAfterTamper = try await store.auditEventCount()
        XCTAssertEqual(eventCountAfterTamper, 2)
        XCTAssertThrowsError(try OperationStore(databaseURL: database)) { error in
            guard case UMISCoreError.sqlite = error else {
                return XCTFail("Unexpected startup error: \(error)")
            }
        }
    }

    func testAuditEventAndTrustedHeadRollBackAsOneTransaction() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("audit-head-rollback.sqlite")
        let store = try OperationStore(databaseURL: database)
        try await store.appendAudit(operationID: nil, event: "baseline")
        try Self.runSQLite(
            database: database,
            statement: """
            CREATE TRIGGER reject_audit_head_update
            BEFORE UPDATE ON audit_chain_head
            BEGIN SELECT RAISE(ABORT, 'forced trusted-head failure'); END;
            """
        )

        do {
            try await store.appendAudit(operationID: nil, event: "must.rollback")
            XCTFail("A failed audit-head CAS must roll back the inserted event")
        } catch let error as UMISCoreError {
            guard case .sqlite = error else { return XCTFail("Unexpected append error: \(error)") }
        }
        let eventCountAfterRollback = try await store.auditEventCount()
        XCTAssertEqual(eventCountAfterRollback, 1)
        XCTAssertEqual(
            try Self.sqliteScalar(database: database, query: "SELECT sequence FROM audit_chain_head"),
            1
        )

        try Self.runSQLite(
            database: database,
            statement: "DROP TRIGGER reject_audit_head_update"
        )
        try await store.appendAudit(operationID: nil, event: "after.rollback")
        let report = try await store.verifyAuditChain()
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.eventCount, 2)
        XCTAssertEqual(
            try Self.sqliteScalar(database: database, query: "SELECT sequence FROM audit_chain_head"),
            2
        )
    }

    private static func createLegacyV3Database(database: URL) throws {
        try runSQLite(
            database: database,
            statement: """
            PRAGMA user_version=3;
            CREATE TABLE operations(
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, plan_json BLOB NOT NULL,
                receipt_json BLOB, created_at REAL NOT NULL, updated_at REAL NOT NULL
            ) STRICT;
            CREATE TABLE operation_items(
                operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
                item_id TEXT NOT NULL, asset_id TEXT NOT NULL, state TEXT NOT NULL,
                bytes_copied INTEGER NOT NULL DEFAULT 0 CHECK(bytes_copied >= 0),
                partial_path TEXT NOT NULL, final_path TEXT NOT NULL, source_hash TEXT,
                destination_hash TEXT, receipt_json BLOB, error TEXT, updated_at REAL NOT NULL,
                PRIMARY KEY(operation_id, item_id)
            ) STRICT;
            CREATE TABLE audit_events(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT, event_type TEXT NOT NULL,
                payload BLOB NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL
            ) STRICT;
            CREATE TABLE destructive_quarantines(
                physical_key TEXT PRIMARY KEY, operation_id TEXT NOT NULL,
                source_identity_digest TEXT NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL
            ) STRICT;
            INSERT INTO audit_events(operation_id,event_type,payload,previous_hash,event_hash,created_at)
            VALUES(NULL,'legacy',X'00','0000000000000000000000000000000000000000000000000000000000000000',
            '1111111111111111111111111111111111111111111111111111111111111111',1.0);
            """
        )
    }

    private static func createLegacyDatabase(
        database: URL,
        schemaVersion: Int,
        operationID: UUID
    ) throws {
        guard (1 ... 3).contains(schemaVersion) else {
            throw TestSupportError.missingValue("Unsupported legacy schema fixture")
        }
        var statement = """
        CREATE TABLE operations(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, plan_json BLOB NOT NULL,
            receipt_json BLOB, created_at REAL NOT NULL, updated_at REAL NOT NULL
        ) STRICT;
        CREATE TABLE operation_items(
            operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
            item_id TEXT NOT NULL, asset_id TEXT NOT NULL, state TEXT NOT NULL,
            bytes_copied INTEGER NOT NULL DEFAULT 0 CHECK(bytes_copied >= 0),
            partial_path TEXT NOT NULL, final_path TEXT NOT NULL, source_hash TEXT,
            destination_hash TEXT, receipt_json BLOB, error TEXT, updated_at REAL NOT NULL,
            PRIMARY KEY(operation_id, item_id)
        ) STRICT;
        CREATE TABLE audit_events(
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT, event_type TEXT NOT NULL,
            payload BLOB NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        ) STRICT;
        """
        if schemaVersion >= 2 {
            statement += """

            CREATE INDEX operation_status_updated_idx ON operations(status, updated_at);
            CREATE INDEX operation_item_state_idx ON operation_items(operation_id, state);
            CREATE INDEX audit_operation_idx ON audit_events(operation_id, sequence);
            """
        }
        if schemaVersion >= 3 {
            statement += """

            CREATE TABLE destructive_quarantines(
                physical_key TEXT PRIMARY KEY, operation_id TEXT NOT NULL,
                source_identity_digest TEXT NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL
            ) STRICT;
            CREATE INDEX destructive_quarantine_created_idx ON destructive_quarantines(created_at);
            """
        }
        statement += """

        INSERT INTO audit_events(operation_id,event_type,payload,previous_hash,event_hash,created_at)
        VALUES(
            '\(operationID.uuidString)','legacy.one',X'00',
            '0000000000000000000000000000000000000000000000000000000000000000',
            '1111111111111111111111111111111111111111111111111111111111111111',1.0
        );
        INSERT INTO audit_events(operation_id,event_type,payload,previous_hash,event_hash,created_at)
        VALUES(
            NULL,'legacy.two',X'01',
            '1111111111111111111111111111111111111111111111111111111111111111',
            '2222222222222222222222222222222222222222222222222222222222222222',2.0
        );
        PRAGMA user_version=\(schemaVersion);
        """
        try runSQLite(database: database, statement: statement)
    }

    private static func sqliteScalar(database: URL, query: String) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, query]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown sqlite3 error"
            throw TestSupportError.missingValue(diagnostic)
        }
        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, let value = Int(output) else {
            throw TestSupportError.missingValue("Expected scalar SQLite integer")
        }
        return value
    }

    private static func runSQLite(database: URL, statement: String) throws {
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, statement]
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown sqlite3 error"
            throw TestSupportError.missingValue(diagnostic)
        }
    }
}
