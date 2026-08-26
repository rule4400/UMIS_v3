import Foundation
import XCTest
@testable import RinkanUMIS

@MainActor
final class LANSceneCatalogApplicationLeaseTests: XCTestCase {
    func testFetchExclusionRejectsApplicationAndRoleShutdown() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let projectID = UUID()
        let version = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 1,
            marker: "first"
        )

        let fetchToken = try fixture.coordinator.beginFetchExclusionForTesting()
        XCTAssertTrue(fixture.coordinator.operationInProgress)
        XCTAssertEqual(fixture.coordinator.phase, .fetching)
        XCTAssertFalse(
            fixture.coordinator.canBeginReceivedSnapshotApplication(
                expectedVersion: version
            )
        )
        XCTAssertThrowsError(
            try fixture.coordinator.beginReceivedSnapshotApplication(
                expectedVersion: version
            )
        ) { error in
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .operationInProgress
            )
        }
        XCTAssertThrowsError(
            try fixture.coordinator.receivedSnapshotForExplicitApplication()
        ) { error in
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .operationInProgress
            )
        }
        XCTAssertFalse(fixture.coordinator.setOff())
        XCTAssertEqual(fixture.coordinator.mode, .client(projectID: projectID))

        try fixture.coordinator.finishFetchExclusionForTesting(fetchToken)
        XCTAssertFalse(fixture.coordinator.operationInProgress)
        XCTAssertTrue(
            fixture.coordinator.canBeginReceivedSnapshotApplication(
                expectedVersion: version
            )
        )
    }

    func testApplicationLeaseExcludesFetchConfigurationAndShutdown() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let projectID = UUID()
        let version = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 4,
            marker: "lease"
        )
        let lease = try fixture.coordinator.beginReceivedSnapshotApplication(
            expectedVersion: version
        )

        XCTAssertTrue(fixture.coordinator.operationInProgress)
        XCTAssertEqual(fixture.coordinator.phase, .applying)
        XCTAssertFalse(fixture.coordinator.setOff())
        XCTAssertEqual(fixture.coordinator.mode, .client(projectID: projectID))

        do {
            _ = try await fixture.coordinator.fetchSelectedService()
            XCTFail("fetch must not start while an application lease is active")
        } catch {
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .operationInProgress
            )
        }

        do {
            try await fixture.coordinator.configureClient(projectID: UUID())
            XCTFail("configuration must not start while an application lease is active")
        } catch {
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .operationInProgress
            )
        }

        try fixture.coordinator.cancelReceivedSnapshotApplication(lease)
        XCTAssertFalse(fixture.coordinator.operationInProgress)
        XCTAssertEqual(fixture.coordinator.phase, .ready)
        XCTAssertTrue(fixture.coordinator.setOff())
        XCTAssertEqual(fixture.coordinator.mode, .off)
    }

    func testExpectedVersionCASRejectsChangedCandidate() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let projectID = UUID()
        let first = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 10,
            marker: "first"
        )
        let second = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 11,
            marker: "second"
        )

        XCTAssertFalse(
            fixture.coordinator.canBeginReceivedSnapshotApplication(
                expectedVersion: first
            )
        )
        XCTAssertThrowsError(
            try fixture.coordinator.beginReceivedSnapshotApplication(
                expectedVersion: first
            )
        ) { error in
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .applicationCandidateChanged
            )
        }
        XCTAssertFalse(fixture.coordinator.operationInProgress)

        let lease = try fixture.coordinator.beginReceivedSnapshotApplication(
            expectedVersion: second
        )
        try fixture.coordinator.cancelReceivedSnapshotApplication(lease)
    }

    func testCommittedLeaseAppliesFrozenCandidateAndKeepsNewerRevisionPending() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let projectID = UUID()
        let committedVersion = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 20,
            marker: "committed"
        )
        let lease = try fixture.coordinator.beginReceivedSnapshotApplication(
            expectedVersion: committedVersion
        )
        var appliedCandidate: LANSceneCatalogApplicationCandidate?

        try fixture.coordinator.completeReceivedSnapshotApplication(
            lease,
            applyingPersistedCandidate: { candidate in
                appliedCandidate = candidate
                XCTAssertTrue(fixture.coordinator.operationInProgress)
                XCTAssertEqual(fixture.coordinator.phase, .applying)
            }
        )
        XCTAssertEqual(appliedCandidate?.version, committedVersion)
        XCTAssertEqual(appliedCandidate?.activeScenes.first?.name, "committed")
        XCTAssertFalse(fixture.coordinator.operationInProgress)

        let pendingVersion = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: projectID,
            revision: 21,
            marker: "pending"
        )
        XCTAssertEqual(fixture.coordinator.receivedVersion, pendingVersion)
        XCTAssertEqual(fixture.coordinator.receivedActiveScenes.first?.name, "pending")
        XCTAssertEqual(appliedCandidate?.version, committedVersion)
    }

    func testCompletedLeaseCannotBeReused() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let version = try fixture.coordinator.installReceivedSnapshotForTesting(
            projectID: UUID(),
            revision: 30,
            marker: "once"
        )
        let lease = try fixture.coordinator.beginReceivedSnapshotApplication(
            expectedVersion: version
        )
        try fixture.coordinator.completeReceivedSnapshotApplication(
            lease,
            applyingPersistedCandidate: { _ in }
        )

        var staleClosureRan = false
        XCTAssertThrowsError(
            try fixture.coordinator.completeReceivedSnapshotApplication(
                lease,
                applyingPersistedCandidate: { _ in staleClosureRan = true }
            )
        ) { error in
            XCTAssertEqual(
                error as? LANSceneCatalogCoordinatorError,
                .invalidApplicationLease
            )
        }
        XCTAssertFalse(staleClosureRan)
    }

    func testTransportRemainsExplicitlyExperimental() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        XCTAssertFalse(fixture.coordinator.productionEligible)
        XCTAssertEqual(
            fixture.coordinator.transportSecurityMode,
            .experimentalTLS12PSK
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LANSceneCatalogLeaseTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Fixture(
            coordinator: try LANSceneCatalogCoordinator(baseDirectoryURL: root),
            root: root
        )
    }

    private struct Fixture {
        let coordinator: LANSceneCatalogCoordinator
        let root: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
