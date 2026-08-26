import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

@MainActor
final class ProgressiveScanTests: XCTestCase {
    func testFolderRenameTemplateFreezesProjectTimeZoneIntoPlannerRule() throws {
        let rule = try AppModel.renameRule(
            from: "{date}_{original}",
            timeZoneIdentifier: "Asia/Tokyo"
        )

        XCTAssertEqual(rule.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(rule.tokens, [.capturedDate, .originalStem])
    }

    func testBasicInventoryBecomesReadyBeforeCaptureDatesAreFrozen() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "A.JPG", bytes: [1, 2, 3])
        let scan = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )

        XCTAssertEqual(AppModel.phaseAfterBasicInventory(scan), .ready)
        XCTAssertTrue(scan.assets.allSatisfy { $0.capturedAt == nil })
        XCTAssertFalse(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: nil,
            completedTimeZoneIdentifier: nil,
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: "Asia/Tokyo",
            currentScan: scan,
            proposedScan: scan
        ))
    }

    func testLateEnrichmentAcceptsOnlyCurrentGenerationAndUnchangedInventory() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "A.MOV", bytes: [4, 5, 6])
        let scan = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )
        let attempt = UUID()

        XCTAssertTrue(AppModel.acceptsLateCaptureDateEnrichment(
            baseline: scan,
            taskGeneration: fixture.generation,
            currentGeneration: fixture.generation,
            taskAttempt: attempt,
            currentAttempt: attempt,
            currentScan: scan
        ))
        XCTAssertFalse(AppModel.acceptsLateCaptureDateEnrichment(
            baseline: scan,
            taskGeneration: fixture.generation,
            currentGeneration: UUID(),
            taskAttempt: attempt,
            currentAttempt: attempt,
            currentScan: scan
        ))

        var changedInventory = scan
        changedInventory.assets[0].fingerprint.byteSize += 1
        XCTAssertFalse(AppModel.acceptsLateCaptureDateEnrichment(
            baseline: scan,
            taskGeneration: fixture.generation,
            currentGeneration: fixture.generation,
            taskAttempt: attempt,
            currentAttempt: attempt,
            currentScan: changedInventory
        ))
    }

    func testPlanFreezeRequiresExactEnrichedSnapshotGenerationAndTimeZone() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "A.CR3", bytes: [7, 8, 9])
        let basic = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )
        var enriched = basic
        enriched.assets[0].capturedAt = Date(timeIntervalSince1970: 1_787_666_400)

        XCTAssertFalse(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: fixture.generation,
            completedTimeZoneIdentifier: "Asia/Tokyo",
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: "Asia/Tokyo",
            currentScan: enriched,
            proposedScan: basic
        ))
        XCTAssertTrue(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: fixture.generation,
            completedTimeZoneIdentifier: "Asia/Tokyo",
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: "Asia/Tokyo",
            currentScan: enriched,
            proposedScan: enriched
        ))
        XCTAssertFalse(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: fixture.generation,
            completedTimeZoneIdentifier: "GMT",
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: "Asia/Tokyo",
            currentScan: enriched,
            proposedScan: enriched
        ))
    }

    func testFallbackFreezesEveryCaptureDateAndFreezeValidationRejectsMutation() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        let firstURL = try fixture.write(name: "A.JPG", bytes: [10, 11])
        _ = try fixture.write(name: "B.MOV", bytes: [12, 13, 14])
        let basic = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )

        let enriched = try await AppModel.enrichingCaptureDates(
            in: basic,
            mediaPipeline: nil,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        )
        XCTAssertEqual(enriched.assets.count, 2)
        XCTAssertTrue(enriched.assets.allSatisfy { asset in
            asset.capturedAt == asset.modifiedAt && asset.capturedAt != nil
        })
        try await AppModel.validateSourceFingerprints(in: enriched)

        try Data([10, 11, 99]).write(to: firstURL)
        do {
            try await AppModel.validateSourceFingerprints(in: enriched)
            XCTFail("A plan-freeze validation must reject any changed source asset")
        } catch let error as UMISCoreError {
            guard case .sourceChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSameMountPathReuseCannotResumeMediaForOldSourceOrIsolationGeneration() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "NEW.JPG", bytes: [20, 21, 22])
        let newSourceVolumeID = SourceVolumeID()
        let freshScan = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: newSourceVolumeID
        )
        let isolationGeneration = UUID()

        XCTAssertFalse(AppModel.permitsMediaReadResumeAfterFreshScan(
            scan: freshScan,
            expectedSourceVolumeID: fixture.sourceVolumeID,
            scanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation,
            isolationGeneration: isolationGeneration,
            currentIsolationGeneration: isolationGeneration
        ), "The reused mount path must not substitute for the new source-volume identity")
        XCTAssertFalse(AppModel.permitsMediaReadResumeAfterFreshScan(
            scan: freshScan,
            expectedSourceVolumeID: newSourceVolumeID,
            scanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation,
            isolationGeneration: isolationGeneration,
            currentIsolationGeneration: UUID()
        ))
        XCTAssertTrue(AppModel.permitsMediaReadResumeAfterFreshScan(
            scan: freshScan,
            expectedSourceVolumeID: newSourceVolumeID,
            scanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation,
            isolationGeneration: isolationGeneration,
            currentIsolationGeneration: isolationGeneration
        ))
    }
}

private final class ProgressiveScanFixture {
    let root: URL
    let sourceVolumeID = SourceVolumeID()
    let generation = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinkanUMIS-ProgressiveScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(name: String, bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
