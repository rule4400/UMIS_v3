import CryptoKit
import Foundation
import XCTest
@testable import UMISNetwork

final class SceneCatalogSecurityTests: XCTestCase, @unchecked Sendable {
    private let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let authorityID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let authorityEpoch = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    func testProtocolV1FixedVector() throws {
        let signingKey = try fixedSigningKey()
        let payload = try fixedPayload(revision: 1)
        let canonical = payload.canonicalBytes()
        let expectedJSON = #"{"authorityEpoch":"44444444-4444-4444-4444-444444444444","authorityID":"33333333-3333-3333-3333-333333333333","catalogID":"22222222-2222-2222-2222-222222222222","generatedAt":"2026-01-01T00:00:00Z","projectID":"11111111-1111-1111-1111-111111111111","protocolVersion":1,"revision":1,"scenes":[],"schemaVersion":1}"#

        XCTAssertEqual(canonical, Data(expectedJSON.utf8))
        XCTAssertEqual(canonical.count, 312)
        XCTAssertEqual(
            SHA256Value.hash(canonical).hex,
            "4a8243c7296e82c59586b64403a609180c29b816b677183ca0415ee3780b2e45"
        )
        XCTAssertEqual(
            signingKey.publicKeyRawRepresentation.lowercaseHex,
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )

        let snapshot = try signingKey.sign(payload)
        let expectedSignature = Data(lowercaseHex:
            "0e9939e5cc01b5e6cb56737c5a81fed9ba7fdbd288a2097eff9a4ef2bfbd650e" +
                "fd2226a47e1c4f77a6bceec91005da062482a627a537b2142a992bffe67d0001"
        )!
        // Current CryptoKit uses hedged Ed25519 signing, so newly produced
        // signatures need not byte-match. The normative fixed signature must
        // nevertheless verify over the exact canonical signed bytes.
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: signingKey.publicKeyRawRepresentation
        )
        XCTAssertTrue(publicKey.isValidSignature(expectedSignature, for: try snapshot.signedBytes()))
        let verified = try SceneCatalogVerifier.verify(snapshot, trust: try fixedTrust())
        XCTAssertEqual(verified.payload, payload)
        XCTAssertEqual(verified.version.payloadDigest, snapshot.payloadSHA256)
    }

    func testPayloadAndSignatureTamperingAreRejected() throws {
        let snapshot = try fixedSigningKey().sign(try fixedPayload(revision: 1))
        var changedPayload = snapshot.payloadBytes
        changedPayload[changedPayload.startIndex] ^= 0x01
        let payloadTamper = replacing(snapshot, payloadBytes: changedPayload)
        XCTAssertThrowsError(try SceneCatalogVerifier.verify(payloadTamper, trust: fixedTrust())) {
            XCTAssertEqual($0 as? SceneCatalogVerificationError, .payloadDigestMismatch)
        }

        var changedSignature = snapshot.detachedSignature
        changedSignature[changedSignature.startIndex] ^= 0x01
        let signatureTamper = replacing(snapshot, detachedSignature: changedSignature)
        XCTAssertThrowsError(try SceneCatalogVerifier.verify(signatureTamper, trust: fixedTrust())) {
            XCTAssertEqual($0 as? SceneCatalogVerificationError, .invalidSignature)
        }
    }

    func testAtomicStoreReplayRollbackSplitBrainAndRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try fixedSigningKey()
        let revisionOne = try key.sign(fixedPayload(revision: 1))
        let store = try AtomicVerifiedSnapshotStore(directoryURL: directory, trust: fixedTrust())

        let firstAcceptance = try await store.accept(revisionOne)
        let secondAcceptance = try await store.accept(revisionOne)
        XCTAssertEqual(firstAcceptance, .applied(version(of: revisionOne)))
        XCTAssertEqual(secondAcceptance, .replay(version(of: revisionOne)))

        let restarted = try AtomicVerifiedSnapshotStore(directoryURL: directory, trust: fixedTrust())
        let restoredSnapshot = await restarted.currentSnapshot()
        let restoredCheckpoint = await restarted.highWaterMark()
        XCTAssertEqual(restoredSnapshot?.version, version(of: revisionOne))
        XCTAssertEqual(restoredCheckpoint?.highestRevision, 1)

        let revisionZero = try key.sign(fixedPayload(revision: 0))
        do {
            _ = try await restarted.accept(revisionZero)
            XCTFail("rollback must be refused")
        } catch {
            XCTAssertEqual(
                error as? SceneCatalogAcceptanceError,
                .revisionRollback(received: 0, highestAccepted: 1)
            )
        }

        let conflictingPayload = SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: 1,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:01Z"),
            scenes: []
        )
        let conflicting = try key.sign(conflictingPayload)
        do {
            _ = try await restarted.accept(conflicting)
            XCTFail("same revision with another digest must be refused")
        } catch {
            XCTAssertEqual(error as? SceneCatalogAcceptanceError, .splitBrain(revision: 1))
        }
    }

    func testCheckpointSurvivesSnapshotCachePurge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try fixedSigningKey()
        let store = try AtomicVerifiedSnapshotStore(directoryURL: directory, trust: fixedTrust())
        _ = try await store.accept(key.sign(fixedPayload(revision: 2)))
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(AtomicVerifiedSnapshotStore.defaultSnapshotFileName)
        )

        let reopened = try AtomicVerifiedSnapshotStore(directoryURL: directory, trust: fixedTrust())
        let snapshotAfterPurge = await reopened.currentSnapshot()
        let checkpointAfterPurge = await reopened.highWaterMark()
        XCTAssertNil(snapshotAfterPurge)
        XCTAssertEqual(checkpointAfterPurge?.highestRevision, 2)
        do {
            _ = try await reopened.accept(key.sign(fixedPayload(revision: 1)))
            XCTFail("cache purge must not reset the checkpoint")
        } catch {
            XCTAssertEqual(
                error as? SceneCatalogAcceptanceError,
                .revisionRollback(received: 1, highestAccepted: 2)
            )
        }
    }

    func testUnknownEpochIsRejected() throws {
        let key = try fixedSigningKey()
        let otherEpoch = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let payload = SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: otherEpoch,
            revision: 2,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:01Z"),
            scenes: []
        )
        let snapshot = try key.sign(payload)
        XCTAssertThrowsError(try SceneCatalogVerifier.verify(snapshot, trust: fixedTrust())) {
            XCTAssertEqual($0 as? SceneCatalogVerificationError, .untrustedAuthorityEpoch)
        }
    }

    func testMasterRejectsStaleRevisionAndCommandIDReuse() async throws {
        let key = try fixedSigningKey()
        let fixedTime = try CanonicalTimestamp("2026-01-01T00:00:00Z")
        let master = try SceneCatalogMaster(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            signingKey: key,
            timestampProvider: { fixedTime }
        )
        let commandID = UUID()
        let deviceID = UUID()
        let sceneID = UUID()
        let first = SceneCatalogCommand(
            commandID: commandID,
            actorDeviceID: deviceID,
            projectID: projectID,
            catalogID: catalogID,
            baseRevision: 0,
            mutation: .create(SceneDraft(
                projectID: projectID,
                sceneID: sceneID,
                dayIndex: 1,
                dayLabel: "Day 1",
                sceneNumber: "001",
                name: "Opening",
                sortKey: "0001"
            ))
        )
        guard case .applied(let firstSnapshot) = try await master.apply(first) else {
            return XCTFail("first command should apply")
        }
        XCTAssertEqual(firstSnapshot.revision, 1)
        guard case .duplicate(let duplicateVersion) = try await master.apply(first) else {
            return XCTFail("same command should be idempotent")
        }
        XCTAssertEqual(duplicateVersion.revision, 1)

        let reused = SceneCatalogCommand(
            commandID: commandID,
            actorDeviceID: deviceID,
            projectID: projectID,
            catalogID: catalogID,
            baseRevision: 1,
            mutation: .setLifecycle(
                sceneID: sceneID,
                lifecycle: .archived,
                expectedEntityVersion: 1
            )
        )
        guard case .conflict(let reuseConflict) = try await master.apply(reused) else {
            return XCTFail("same command ID with another payload must conflict")
        }
        XCTAssertEqual(reuseConflict.reason, .commandIDPayloadMismatch)

        let stale = SceneCatalogCommand(
            actorDeviceID: deviceID,
            projectID: projectID,
            catalogID: catalogID,
            baseRevision: 0,
            mutation: .setLifecycle(
                sceneID: sceneID,
                lifecycle: .archived,
                expectedEntityVersion: 1
            )
        )
        guard case .conflict(let staleConflict) = try await master.apply(stale) else {
            return XCTFail("stale base revision must conflict")
        }
        XCTAssertEqual(staleConflict.reason, .staleBaseRevision)
        let currentRevision = await master.currentRevision()
        XCTAssertEqual(currentRevision, 1)
    }

    func testSchemaRejectsWrongProjectOrderingAndNonNFC() throws {
        let key = try fixedSigningKey()
        let sceneA = SceneRecord(
            projectID: projectID,
            sceneID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            dayIndex: 1,
            dayLabel: "Day 1",
            sceneNumber: "1",
            name: "A",
            sortKey: "2",
            entityVersion: 1,
            lifecycle: .active
        )
        let sceneB = SceneRecord(
            projectID: projectID,
            sceneID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            dayIndex: 1,
            dayLabel: "Day 1",
            sceneNumber: "2",
            name: "B",
            sortKey: "1",
            entityVersion: 1,
            lifecycle: .active
        )
        let unordered = SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: 1,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z"),
            scenes: [sceneA, sceneB]
        )
        XCTAssertThrowsError(try key.sign(unordered)) {
            XCTAssertEqual($0 as? SceneCatalogSchemaError, .scenesNotCanonicallyOrdered)
        }

        var nonNFC = sceneB
        nonNFC.name = "e\u{301}"
        let invalidText = SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: 1,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z"),
            scenes: [nonNFC]
        )
        XCTAssertThrowsError(try key.sign(invalidText))

        let wrongProjectScene = SceneRecord(
            projectID: UUID(),
            sceneID: UUID(),
            dayIndex: 1,
            dayLabel: "Day 1",
            sceneNumber: "3",
            name: "Wrong project",
            sortKey: "3",
            entityVersion: 1,
            lifecycle: .active
        )
        let wrongProject = SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: 1,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z"),
            scenes: [wrongProjectScene]
        )
        XCTAssertThrowsError(try key.sign(wrongProject)) {
            XCTAssertEqual(
                $0 as? SceneCatalogSchemaError,
                .sceneProjectMismatch(sceneID: wrongProjectScene.sceneID)
            )
        }
    }

    func testTrustKeyIDMustMatchPublicKeyDigest() throws {
        let key = try fixedSigningKey()
        XCTAssertThrowsError(try SceneCatalogTrust(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            trustedCatalogKeyID: String(repeating: "0", count: 64),
            publicKeyRawRepresentation: key.publicKeyRawRepresentation
        )) {
            XCTAssertEqual($0 as? UMISNetworkValidationError, .catalogKeyIDMismatch)
        }
    }

    private func fixedSigningKey() throws -> SceneCatalogSigningKey {
        try SceneCatalogSigningKey(rawRepresentation: Data((0...31).map(UInt8.init)))
    }

    private func fixedTrust() throws -> SceneCatalogTrust {
        let key = try fixedSigningKey()
        return try SceneCatalogTrust(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            trustedCatalogKeyID: key.keyID,
            publicKeyRawRepresentation: key.publicKeyRawRepresentation
        )
    }

    private func fixedPayload(revision: UInt64) throws -> SceneCatalogSnapshotPayload {
        SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: revision,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z"),
            scenes: []
        )
    }

    private func replacing(
        _ source: SignedSceneCatalogSnapshot,
        payloadBytes: Data? = nil,
        detachedSignature: Data? = nil
    ) -> SignedSceneCatalogSnapshot {
        SignedSceneCatalogSnapshot(
            protocolMajor: source.protocolMajor,
            protocolMinor: source.protocolMinor,
            messageType: source.messageType,
            projectID: source.projectID,
            catalogID: source.catalogID,
            authorityID: source.authorityID,
            authorityEpoch: source.authorityEpoch,
            revision: source.revision,
            payloadBytes: payloadBytes ?? source.payloadBytes,
            payloadSHA256: source.payloadSHA256,
            detachedSignature: detachedSignature ?? source.detachedSignature
        )
    }

    private func version(of snapshot: SignedSceneCatalogSnapshot) -> CatalogVersionRef {
        CatalogVersionRef(
            projectID: snapshot.projectID,
            catalogID: snapshot.catalogID,
            authorityID: snapshot.authorityID,
            authorityEpoch: snapshot.authorityEpoch,
            revision: snapshot.revision,
            payloadDigest: snapshot.payloadSHA256
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UMISNetworkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
