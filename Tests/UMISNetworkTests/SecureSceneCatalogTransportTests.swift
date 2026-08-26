import Foundation
import XCTest
@testable import UMISNetwork

final class SecureSceneCatalogTransportTests: XCTestCase, @unchecked Sendable {
    func testTLSPSKServerFetchesAndVerifiesSignedFullSnapshot() async throws {
        let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let authorityID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let authorityEpoch = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let signingKey = try SceneCatalogSigningKey(
            rawRepresentation: Data((0...31).map(UInt8.init))
        )
        let snapshot = try signingKey.sign(SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: 7,
            generatedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z"),
            scenes: []
        ))
        let credential = try PairedSceneCatalogCredential(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            catalogPublicKeyFingerprint: .hash(signingKey.publicKeyRawRepresentation),
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
            pskIdentity: UUID(),
            transportPSK: Data(repeating: 0xa5, count: 32)
        )
        let server = try SecureSceneCatalogServer(
            serviceName: "UMIS Transport Test \(UUID().uuidString.prefix(8))",
            pairedClients: [credential],
            snapshotProvider: { snapshot }
        )
        let events = server.events()
        try server.start()
        defer { server.stop() }
        let port = try await waitForReadyPort(events)

        let received = try await SecureSceneCatalogClient().fetchFullSnapshot(
            host: "127.0.0.1",
            port: port,
            credential: credential,
            timeout: 5
        )
        XCTAssertEqual(received.projectID, projectID)
        XCTAssertEqual(received.catalogID, catalogID)
        XCTAssertEqual(received.revision, 7)
        XCTAssertEqual(received.payloadSHA256, snapshot.payloadSHA256)
        _ = try SceneCatalogVerifier.verify(received, trust: credential.catalogTrust)

        let wrongPSK = try PairedSceneCatalogCredential(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            catalogPublicKeyFingerprint: .hash(signingKey.publicKeyRawRepresentation),
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
            pskIdentity: credential.pskIdentity,
            transportPSK: Data(repeating: 0x5a, count: 32)
        )
        do {
            _ = try await SecureSceneCatalogClient().fetchFullSnapshot(
                host: "127.0.0.1",
                port: port,
                credential: wrongPSK,
                timeout: 1
            )
            XCTFail("a client without the paired PSK must not receive a snapshot")
        } catch {
            XCTAssertTrue(
                error is SecureSceneCatalogTransportError,
                "unexpected error: \(error)"
            )
        }
    }

    func testPairingCredentialRefusesFingerprintMismatch() throws {
        let signingKey = try SceneCatalogSigningKey(
            rawRepresentation: Data((0...31).map(UInt8.init))
        )
        XCTAssertThrowsError(try PairedSceneCatalogCredential(
            projectID: UUID(),
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID(),
            catalogPublicKeyFingerprint: SHA256Value.hash(Data(repeating: 0, count: 32)),
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
            pskIdentity: UUID(),
            transportPSK: Data(repeating: 1, count: 32)
        )) {
            XCTAssertEqual(
                $0 as? SceneCatalogPairingCredentialError,
                .publicKeyFingerprintMismatch
            )
        }
    }

    private func waitForReadyPort(
        _ events: AsyncStream<SecureSceneCatalogServerEvent>
    ) async throws -> UInt16 {
        try await withThrowingTaskGroup(of: UInt16.self) { group in
            group.addTask {
                for await event in events {
                    if case .stateChanged(.ready(let port)) = event, let port {
                        return port
                    }
                    if case .stateChanged(.failed(let reason)) = event {
                        throw SecureSceneCatalogTransportError.connectionFailed(reason)
                    }
                }
                throw SecureSceneCatalogTransportError.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw SecureSceneCatalogTransportError.timedOut
            }
            guard let port = try await group.next() else {
                throw SecureSceneCatalogTransportError.cancelled
            }
            group.cancelAll()
            return port
        }
    }
}
