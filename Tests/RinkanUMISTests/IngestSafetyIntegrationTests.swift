import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

final class IngestSafetyIntegrationTests: XCTestCase {
    func testCompanionSelectionAndPlanningShareSceneSequenceAndPrimary() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("CAM001.MOV", [1])
        _ = try fixture.write("CAM001.XMP", [2])
        _ = try fixture.write("CAM001.SRT", [3])
        _ = try fixture.write("VOICE001.WAV", [4])
        let scan = try await fixture.scanRoot()
        let movie = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "mov" })
        let sidecars = scan.assets.filter { $0.kind == .sidecar }
        let audio = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "wav" })
        XCTAssertEqual(sidecars.count, 2)

        let expanded = AppModel.expandedCompanionAssetIDs(
            [movie.id.rawValue],
            assets: scan.assets
        )
        XCTAssertEqual(expanded, Set(([movie] + sidecars).map { $0.id.rawValue }))
        XCTAssertFalse(expanded.contains(audio.id.rawValue))

        let cameraScene = UUID()
        let audioScene = UUID()
        var assignments = Dictionary(
            uniqueKeysWithValues: ([movie] + sidecars).map { ($0.id.rawValue, cameraScene) }
        )
        assignments[audio.id.rawValue] = audioScene
        let layout = try AppModel.companionPlanningLayout(
            assets: scan.assets,
            sceneAssignments: assignments
        )
        let cameraPlacements = layout.filter { expanded.contains($0.assetID.rawValue) }
        XCTAssertEqual(Set(cameraPlacements.map(\.primaryAssetID)), [movie.id])
        XCTAssertEqual(Set(cameraPlacements.map(\.sceneID)), [cameraScene])
        XCTAssertEqual(Set(cameraPlacements.map(\.sequence)).count, 1)
        let audioPlacement = try XCTUnwrap(layout.first { $0.assetID == audio.id })
        XCTAssertEqual(audioPlacement.primaryAssetID, audio.id)
        XCTAssertEqual(audioPlacement.sceneID, audioScene)
        XCTAssertNotEqual(audioPlacement.sequence, cameraPlacements[0].sequence)
    }

    func testCompanionPlanningFailsClosedForMismatchSidecarOnlyAndAmbiguousPrimary() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("CAM002.MOV", [1])
        _ = try fixture.write("CAM002.WAV", [2])
        _ = try fixture.write("CAM002.XMP", [3])
        let scan = try await fixture.scanRoot()
        let movie = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "mov" })
        let audio = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "wav" })
        let sidecar = try XCTUnwrap(scan.assets.first { $0.kind == .sidecar })

        XCTAssertThrowsError(try AppModel.companionPlanningLayout(
            assets: [movie, audio, sidecar],
            sceneAssignments: [
                movie.id.rawValue: UUID(),
                audio.id.rawValue: UUID(),
                sidecar.id.rawValue: UUID(),
            ]
        ))
        XCTAssertThrowsError(try AppModel.companionPlanningLayout(
            assets: [sidecar],
            sceneAssignments: [sidecar.id.rawValue: UUID()]
        ))

        let firstScene = UUID()
        let secondScene = UUID()
        XCTAssertThrowsError(try AppModel.companionPlanningLayout(
            assets: [movie, sidecar],
            sceneAssignments: [
                movie.id.rawValue: firstScene,
                sidecar.id.rawValue: secondScene,
            ]
        ))

        // Audited exclusion happens before layout. Removing the extra primary makes ownership
        // unambiguous without detaching the included companion from its remaining primary.
        let allowed = try AppModel.companionPlanningLayout(
            assets: [movie, sidecar],
            sceneAssignments: [
                movie.id.rawValue: firstScene,
                sidecar.id.rawValue: firstScene,
            ]
        )
        XCTAssertEqual(Set(allowed.map(\.primaryAssetID)), [movie.id])
    }

    func testEqualStemPrimariesWithoutSidecarRemainIndependentInUI() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("SOLO.MOV", [1])
        _ = try fixture.write("SOLO.WAV", [2])
        let scan = try await fixture.scanRoot()
        let movie = try XCTUnwrap(scan.assets.first { $0.kind == .movie })

        XCTAssertEqual(
            AppModel.expandedCompanionAssetIDs([movie.id.rawValue], assets: scan.assets),
            [movie.id.rawValue]
        )
    }

    func testSelectionCopyExpandsPrimaryOrSidecarToCompleteLogicalGroup() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("SELECT001.MOV", [1])
        _ = try fixture.write("SELECT001.XMP", [2])
        _ = try fixture.write("SELECT001.SRT", [3])
        _ = try fixture.write("INDEPENDENT.WAV", [4])
        let scan = try await fixture.scanRoot()
        let primary = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "mov" })
        let xmp = try XCTUnwrap(scan.assets.first { $0.pathExtension.lowercased() == "xmp" })
        let companionIDs = Set(
            scan.assets
                .filter { $0.originalName.hasPrefix("SELECT001.") }
                .map(\.id)
        )

        XCTAssertEqual(
            try AppModel.expandedValidatedCompanionSelection(
                selectedIDs: [primary.id],
                assets: scan.assets
            ),
            companionIDs
        )
        XCTAssertEqual(
            try AppModel.expandedValidatedCompanionSelection(
                selectedIDs: [xmp.id],
                assets: scan.assets
            ),
            companionIDs
        )
    }

    func testSelectionCopyKeepsSidecarlessPrimariesIndependentAndRejectsUnsafeLayouts() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("SOLO.MOV", [1])
        _ = try fixture.write("SOLO.WAV", [2])
        let independentScan = try await fixture.scanRoot()
        let movie = try XCTUnwrap(independentScan.assets.first { $0.kind == .movie })
        XCTAssertEqual(
            try AppModel.expandedValidatedCompanionSelection(
                selectedIDs: [movie.id],
                assets: independentScan.assets
            ),
            [movie.id]
        )

        let ambiguous = try IngestSafetyFixture()
        defer { ambiguous.cleanup() }
        _ = try ambiguous.write("AMBIG.MOV", [3])
        _ = try ambiguous.write("AMBIG.WAV", [4])
        _ = try ambiguous.write("AMBIG.XMP", [5])
        let ambiguousScan = try await ambiguous.scanRoot()
        let ambiguousMovie = try XCTUnwrap(ambiguousScan.assets.first { $0.kind == .movie })
        XCTAssertThrowsError(try AppModel.expandedValidatedCompanionSelection(
            selectedIDs: [ambiguousMovie.id],
            assets: ambiguousScan.assets
        ))

        let sidecarOnly = try IngestSafetyFixture()
        defer { sidecarOnly.cleanup() }
        _ = try sidecarOnly.write("ORPHAN.XMP", [6])
        let sidecarScan = try await sidecarOnly.scanRoot()
        let orphan = try XCTUnwrap(sidecarScan.assets.first)
        XCTAssertThrowsError(try AppModel.expandedValidatedCompanionSelection(
            selectedIDs: [orphan.id],
            assets: sidecarScan.assets
        ))
    }

    func testSelectionCopyFreshInventoryPreflightRejectsCompanionAddedAfterSelection() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("LATE001.MOV", [1])
        let baseline = try await fixture.scanRoot()
        let selectedPrimary = try XCTUnwrap(baseline.assets.first)

        _ = try fixture.write("LATE001.XMP", [2])
        let fresh = try await fixture.scanRoot()
        XCTAssertFalse(AppModel.isExactPlanFreezeInventoryMatch(
            baseline: baseline,
            fresh: fresh
        ))
        XCTAssertEqual(
            try AppModel.expandedValidatedCompanionSelection(
                selectedIDs: [selectedPrimary.id],
                assets: fresh.assets
            ),
            Set(fresh.assets.map(\.id))
        )
    }

    func testSafeEjectRuntimeFeatureGateIsExplicitAndDefaultClosed() {
        XCTAssertFalse(AppModel.destructiveRuntimeFeatureEnabled(nil, boundaryAvailable: true))
        XCTAssertFalse(AppModel.destructiveRuntimeFeatureEnabled("", boundaryAvailable: true))
        XCTAssertFalse(AppModel.destructiveRuntimeFeatureEnabled("true", boundaryAvailable: true))
        XCTAssertFalse(AppModel.destructiveRuntimeFeatureEnabled("0", boundaryAvailable: true))
        XCTAssertFalse(AppModel.destructiveRuntimeFeatureEnabled("1", boundaryAvailable: false))
        XCTAssertTrue(AppModel.destructiveRuntimeFeatureEnabled("1", boundaryAvailable: true))

        XCTAssertFalse(DiskutilCardEraseBackend.isBundledProductionBoundaryAvailable)
        XCTAssertFalse(SafeEjectService.isBundledProductionBoundaryAvailable)
    }

    func testPlanFreezeExactInventoryDetectsNewCompanionUnknownAndEmptyDirectory() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("CAM003.MOV", [1, 2, 3])
        var baseline = try await fixture.scanRoot()
        baseline.assets[0].capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let unchanged = try await fixture.scanRoot()
        XCTAssertTrue(AppModel.isExactPlanFreezeInventoryMatch(
            baseline: baseline,
            fresh: unchanged
        ), "Native capturedAt enrichment is the only ignored field")

        _ = try fixture.write("CAM003.XMP", [4])
        _ = try fixture.write("UNRECOGNIZED.BIN", [5])
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("EMPTY", isDirectory: true),
            withIntermediateDirectories: false
        )
        let changed = try await fixture.scanRoot()
        XCTAssertFalse(AppModel.isExactPlanFreezeInventoryMatch(
            baseline: baseline,
            fresh: changed
        ))
        XCTAssertTrue(changed.inventory.contains { $0.classification == .requiredCompanion })
        XCTAssertTrue(changed.inventory.contains { $0.classification == .unknown })
        XCTAssertTrue(changed.emptyUserDirectoryPathsRequiringReview.contains("EMPTY"))
    }

    func testItemScopeFreshScanAndProjectTransitionNeverExpandToSiblingFiles() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        let selected = try fixture.write("SELECTED.MOV", [1])
        _ = try fixture.write("SELECTED.XMP", [2])
        _ = try fixture.write("SIBLING.MOV", [3])
        let scope = AppSourceScanScope.normalizedItems([selected])
        let scan = try await AppModel.scanInventory(
            scope: scope,
            sourceVolumeID: fixture.sourceVolumeID,
            policy: fixture.policy
        )

        XCTAssertEqual(scan.assets.map(\.originalName), ["SELECTED.MOV"])
        XCTAssertEqual(scan.inventory.map(\.relativePath), ["SELECTED.MOV"])
        XCTAssertFalse(scan.inventory.contains { $0.relativePath == "SELECTED.XMP" })
        XCTAssertFalse(scan.inventory.contains { $0.relativePath == "SIBLING.MOV" })
        XCTAssertEqual(scope, AppSourceScanScope.normalizedItems([selected, selected]))
    }

    func testStrongIdentityIsRetainedForPartialScopeButEraseRequiresMountedRoot() async throws {
        let fixture = try IngestSafetyFixture()
        defer { fixture.cleanup() }
        let selected = try fixture.write("PARTIAL.MOV", [1])
        let scan = try await AppModel.scanInventory(
            scope: .normalizedItems([selected]),
            sourceVolumeID: fixture.sourceVolumeID,
            policy: fixture.policy
        )
        let strong = fixture.strongIdentity()

        let retained = AppModel.sourceIdentityAfterItemsScan(
            strongIdentity: strong,
            scan: scan
        )
        XCTAssertEqual(retained.securityDigest, strong.securityDigest)
        XCTAssertEqual(retained.identityStrength, .strongForCurrentInsertion)
        XCTAssertFalse(AppModel.scanScopeCoversCompleteCard(
            .normalizedItems([selected]),
            identity: retained
        ))
        XCTAssertTrue(AppModel.scanScopeCoversCompleteCard(
            .normalizedRoot(fixture.root),
            identity: retained
        ))
    }

    func testSceneVersionIncrementAndRenumberFailClosedAtPersistenceLimit() throws {
        XCTAssertEqual(AppModel.incrementedSceneEntityVersion(1), 2)
        XCTAssertEqual(AppModel.incrementedSceneEntityVersion(Int.max - 2), Int.max - 1)
        XCTAssertNil(AppModel.incrementedSceneEntityVersion(Int.max - 1))
        XCTAssertNil(AppModel.incrementedSceneEntityVersion(Int.max))

        let blocked = AppScene(
            id: UUID(),
            day: 1,
            number: 99,
            name: "Blocked",
            entityVersion: Int.max - 1
        )
        XCTAssertThrowsError(try AppModel.renumberedScenes([blocked], day: 1))
        XCTAssertEqual(blocked.number, 99)
        XCTAssertEqual(blocked.entityVersion, Int.max - 1)
    }
}

private final class IngestSafetyFixture {
    let root: URL
    let sourceVolumeID = SourceVolumeID()
    let policy = MediaScanPolicy(categoryRules: [
        ProjectCategory(
            displayName: "Movie",
            folderName: "Movie",
            extensions: ["mov"],
            mediaKind: .movie,
            sortOrder: 0
        ),
        ProjectCategory(
            displayName: "Audio",
            folderName: "Audio",
            extensions: ["wav"],
            mediaKind: .audio,
            sortOrder: 1
        ),
    ])

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinkanUMIS-IngestSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    func scanRoot() async throws -> ScanResult {
        try await MediaScanner().scan(
            root: root,
            sourceVolumeID: sourceVolumeID,
            policy: policy
        )
    }

    func strongIdentity() -> VolumeIdentity {
        VolumeIdentity(
            id: sourceVolumeID,
            mountURL: root,
            displayName: "Fixture Card",
            capacityBytes: 1_000_000,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isWritable: true,
            isNetwork: false,
            isDiskImage: false,
            identityStrength: .strongForCurrentInsertion
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
