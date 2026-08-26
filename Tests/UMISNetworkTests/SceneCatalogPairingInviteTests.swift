import Foundation
import XCTest
@testable import UMISNetwork

final class SceneCatalogPairingInviteTests: XCTestCase, @unchecked Sendable {
    func testSignedShortLivedInviteRequiresConfirmationAndIsConsumedOnceDurably() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = Scope()
        let key = try fixedSigningKey()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let issuer = try SceneCatalogPairingInviteIssuer(
            directoryURL: directory,
            projectID: scope.projectID,
            catalogID: scope.catalogID,
            authorityID: scope.authorityID,
            authorityEpoch: scope.authorityEpoch,
            serviceName: "UMIS Master",
            signingKey: key
        )
        let artifact = try await issuer.issue(now: now, validFor: 120)
        XCTAssertTrue(artifact.description.contains("<redacted>"))
        XCTAssertFalse(artifact.description.contains(artifact.qrPayload()))

        let inspected = try SceneCatalogPairingInviteImporter.inspect(
            qrPayload: artifact.qrPayload(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(inspected.projectID, scope.projectID)
        XCTAssertEqual(inspected.catalogPublicKeyFingerprint, .hash(key.publicKeyRawRepresentation))
        XCTAssertEqual(inspected.role, .viewer)

        XCTAssertThrowsError(try SceneCatalogPairingInviteImporter.confirm(
            exportedData: artifact.exportedData,
            expectedCatalogFingerprint: inspected.catalogPublicKeyFingerprint,
            expectedSAS: inspected.sas,
            operatorConfirmed: false,
            now: now.addingTimeInterval(1)
        )) {
            XCTAssertEqual(
                $0 as? SceneCatalogPairingInviteError,
                .operatorConfirmationRequired
            )
        }

        let imported = try SceneCatalogPairingInviteImporter.confirm(
            exportedData: artifact.exportedData,
            expectedCatalogFingerprint: inspected.catalogPublicKeyFingerprint,
            expectedSAS: inspected.sas,
            operatorConfirmed: true,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(imported.projectID, scope.projectID)
        XCTAssertEqual(imported.pskIdentity, inspected.pskIdentity)
        XCTAssertTrue(imported.description.contains("<redacted>"))

        let approved = try await issuer.approveAndConsume(
            artifact,
            confirmedClientSAS: inspected.sas,
            operatorConfirmed: true,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(approved.pskIdentity, imported.pskIdentity)
        let consumedState = await issuer.state(inviteID: inspected.inviteID)
        XCTAssertEqual(consumedState, .consumed)
        do {
            _ = try await issuer.approveAndConsume(
                artifact,
                confirmedClientSAS: inspected.sas,
                operatorConfirmed: true,
                now: now.addingTimeInterval(3)
            )
            XCTFail("an invite must be consumable only once")
        } catch {
            XCTAssertEqual(
                error as? SceneCatalogPairingInviteError,
                .inviteAlreadyConsumed
            )
        }

        let restartArtifact = try await issuer.issue(
            now: now.addingTimeInterval(4),
            validFor: 120
        )

        let reopened = try SceneCatalogPairingInviteIssuer(
            directoryURL: directory,
            projectID: scope.projectID,
            catalogID: scope.catalogID,
            authorityID: scope.authorityID,
            authorityEpoch: scope.authorityEpoch,
            serviceName: "UMIS Master",
            signingKey: key
        )
        let reopenedState = await reopened.state(inviteID: inspected.inviteID)
        XCTAssertEqual(reopenedState, .consumed)
        let restartApproved = try await reopened.approveAndConsume(
            exportedData: restartArtifact.exportedData,
            confirmedClientSAS: restartArtifact.summary.sas,
            operatorConfirmed: true,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(restartApproved.pskIdentity, restartArtifact.summary.pskIdentity)
    }

    func testInviteTamperExpiryFingerprintAndSASAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = Scope()
        let key = try fixedSigningKey()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let issuer = try SceneCatalogPairingInviteIssuer(
            directoryURL: directory,
            projectID: scope.projectID,
            catalogID: scope.catalogID,
            authorityID: scope.authorityID,
            authorityEpoch: scope.authorityEpoch,
            serviceName: "UMIS Master",
            signingKey: key
        )
        let artifact = try await issuer.issue(now: now, validFor: 30)
        let summary = try SceneCatalogPairingInviteImporter.inspect(
            exportedData: artifact.exportedData,
            now: now
        )

        var tampered = artifact.exportedData
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try SceneCatalogPairingInviteImporter.inspect(
            exportedData: tampered,
            now: now
        )) {
            XCTAssertEqual($0 as? SceneCatalogPairingInviteError, .invalidSignature)
        }

        XCTAssertThrowsError(try SceneCatalogPairingInviteImporter.inspect(
            exportedData: artifact.exportedData,
            now: now.addingTimeInterval(31)
        )) {
            XCTAssertEqual($0 as? SceneCatalogPairingInviteError, .expired)
        }

        XCTAssertThrowsError(try SceneCatalogPairingInviteImporter.confirm(
            exportedData: artifact.exportedData,
            expectedCatalogFingerprint: SHA256Value.hash(Data(repeating: 0, count: 32)),
            expectedSAS: summary.sas,
            operatorConfirmed: true,
            now: now
        )) {
            XCTAssertEqual($0 as? SceneCatalogPairingInviteError, .fingerprintMismatch)
        }

        let wrongSAS = try PairingSAS(rawValue: "0000-0000-0000-0000")
        XCTAssertThrowsError(try SceneCatalogPairingInviteImporter.confirm(
            exportedData: artifact.exportedData,
            expectedCatalogFingerprint: summary.catalogPublicKeyFingerprint,
            expectedSAS: wrongSAS,
            operatorConfirmed: true,
            now: now
        )) {
            XCTAssertEqual($0 as? SceneCatalogPairingInviteError, .sasMismatch)
        }
    }

    func testCredentialVaultUsesDeviceOnlyKeychainPolicyWithoutCodableSurface() throws {
        let vault = try SceneCatalogCredentialVault()
        XCTAssertEqual(vault.service, SceneCatalogCredentialVault.defaultService)
        XCTAssertFalse(PairedSceneCatalogCredential.self is any Codable.Type)
        XCTAssertFalse(SceneCatalogPairingInviteArtifact.self is any Codable.Type)
    }

    func testSigningKeyKeychainCodecBindsScopeAndMetadataExcludesPrivateSeed() throws {
        let scope = SceneCatalogAuthorityScope(
            projectID: UUID(),
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID()
        )
        let signingKey = try fixedSigningKey()
        let createdAt = try CanonicalTimestamp("2026-01-01T00:00:00Z")
        let encoded = try SigningKeyKeychainCodec.encode(
            scope: scope,
            signingKey: signingKey,
            createdAt: createdAt
        )
        let decoded = try SigningKeyKeychainCodec.decode(encoded, expectedScope: scope)
        XCTAssertEqual(
            decoded.signingKey.publicKeyRawRepresentation,
            signingKey.publicKeyRawRepresentation
        )
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertTrue(decoded.signingKey.description.contains("<redacted>"))

        let metadata = SceneCatalogAuthorityMetadata(
            scope: scope,
            catalogKeyID: signingKey.keyID,
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
            createdAt: createdAt
        )
        let metadataData = try JSONEncoder().encode(metadata)
        XCTAssertNil(metadataData.range(of: signingKey.keychainPrivateKeyRawRepresentation))

        let otherScope = SceneCatalogAuthorityScope(
            projectID: scope.projectID,
            catalogID: scope.catalogID,
            authorityID: scope.authorityID,
            authorityEpoch: UUID()
        )
        XCTAssertThrowsError(try SigningKeyKeychainCodec.decode(
            encoded,
            expectedScope: otherScope
        )) {
            XCTAssertEqual(
                $0 as? SceneCatalogSigningKeyVaultError,
                .malformedKeyMaterial
            )
        }
    }

    func testAuthorityVaultRejectsMetadataForAnotherKeyOrProject() throws {
        let projectID = UUID()
        let scope = SceneCatalogAuthorityScope(
            projectID: projectID,
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID()
        )
        let signingKey = try fixedSigningKey()
        let createdAt = try CanonicalTimestamp("2026-01-01T00:00:00Z")
        let metadata = SceneCatalogAuthorityMetadata(
            scope: scope,
            catalogKeyID: signingKey.keyID,
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
            createdAt: createdAt
        )
        let identity = SceneCatalogSigningIdentity(
            signingKey: signingKey,
            metadata: metadata
        )
        XCTAssertNoThrow(try SceneCatalogAuthorityVault.validate(
            identity: identity,
            expectedMetadata: metadata,
            projectID: projectID
        ))

        let differentKey = SceneCatalogSigningKey.generate()
        let mismatchedMetadata = SceneCatalogAuthorityMetadata(
            scope: scope,
            catalogKeyID: differentKey.keyID,
            catalogPublicKeyRawRepresentation: differentKey.publicKeyRawRepresentation,
            createdAt: createdAt
        )
        XCTAssertThrowsError(try SceneCatalogAuthorityVault.validate(
            identity: identity,
            expectedMetadata: mismatchedMetadata,
            projectID: projectID
        )) {
            XCTAssertEqual(
                $0 as? SceneCatalogSigningKeyVaultError,
                .authorityMetadataMismatch
            )
        }

        XCTAssertThrowsError(try SceneCatalogAuthorityVault.validate(
            identity: identity,
            expectedMetadata: metadata,
            projectID: UUID()
        )) {
            XCTAssertEqual(
                $0 as? SceneCatalogSigningKeyVaultError,
                .authorityMetadataMismatch
            )
        }
    }

    private struct Scope {
        let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let authorityID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let authorityEpoch = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    }

    private func fixedSigningKey() throws -> SceneCatalogSigningKey {
        try SceneCatalogSigningKey(rawRepresentation: Data((0...31).map(UInt8.init)))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UMISPairingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
