import Foundation
import UMISMedia
import XCTest
import UMISCore
@testable import RinkanUMIS

final class AssetCollectionPerformancePolicyTests: XCTestCase {
    func testTileThumbnailRequestMatchesActualViewportAtOneX() {
        XCTAssertEqual(
            MediaRequestSizingPolicy.assetTileThumbnailPixelSize(backingScaleFactor: 1),
            MediaPixelSize(width: 152, height: 83)
        )
    }

    func testTileThumbnailRequestMatchesActualViewportAtTwoX() {
        XCTAssertEqual(
            MediaRequestSizingPolicy.assetTileThumbnailPixelSize(backingScaleFactor: 2),
            MediaPixelSize(width: 304, height: 166)
        )
    }

    func testTileThumbnailRequestCapsUnexpectedBackingScaleAtRetinaDensity() {
        XCTAssertEqual(
            MediaRequestSizingPolicy.assetTileThumbnailPixelSize(backingScaleFactor: 4),
            MediaPixelSize(width: 304, height: 166)
        )
    }

    func testPreviewRequestUsesDisplayScaleAndStableBuckets() {
        XCTAssertEqual(
            MediaRequestSizingPolicy.previewPixelSize(
                viewportPointSize: CGSize(width: 640, height: 360),
                backingScaleFactor: 1
            ),
            MediaPixelSize(width: 640, height: 384)
        )
        XCTAssertEqual(
            MediaRequestSizingPolicy.previewPixelSize(
                viewportPointSize: CGSize(width: 640, height: 360),
                backingScaleFactor: 2
            ),
            MediaPixelSize(width: 1_280, height: 768)
        )
    }

    func testPreviewRequestNeverExceedsPreviousQualityCeiling() {
        XCTAssertEqual(
            MediaRequestSizingPolicy.previewPixelSize(
                viewportPointSize: CGSize(width: 10_000, height: 10_000),
                backingScaleFactor: 4
            ),
            MediaPixelSize(width: 1_920, height: 1_080)
        )
    }

    func testSelectionOnlyUpdateDoesNotTraverseContentMetadataOrThumbnails() {
        let generation = UUID()
        let state = AssetCollectionUpdateState(
            contentRevision: 41,
            metadataRevision: 82,
            selectionRevision: 3,
            thumbnailReloadGeneration: generation,
            hasMediaPipeline: true
        )

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: state, incoming: state),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: false,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false,
                applySelection: false
            )
        )
    }

    func testSelectionRevisionAppliesOnlySelectionWithoutRefreshingContentOrThumbnails() {
        let previous = state(content: 1, metadata: 10, selection: 20)
        let incoming = state(content: 1, metadata: 10, selection: 21)

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: previous, incoming: incoming),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: false,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false,
                applySelection: true
            )
        )
    }

    func testMetadataRevisionRefreshesOnlyVisibleMetadata() {
        let previous = state(content: 1, metadata: 10)
        let incoming = state(content: 1, metadata: 11)

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: previous, incoming: incoming),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: true,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false,
                applySelection: false
            )
        )
    }

    func testThumbnailGenerationRefreshesVisibleAndNearVisibleWithoutContentReload() {
        let previous = state(content: 1, metadata: 10, generation: UUID())
        let incoming = state(content: 1, metadata: 10, generation: UUID())

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: previous, incoming: incoming),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: false,
                refreshVisibleThumbnails: true,
                refreshNearVisibleThumbnails: true,
                applySelection: false
            )
        )
    }

    func testPipelineAvailabilityRefreshesVisibleAndNearVisibleWithoutContentReload() {
        let previous = state(content: 1, metadata: 10, hasMediaPipeline: false)
        let incoming = state(content: 1, metadata: 10, hasMediaPipeline: true)

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: previous, incoming: incoming),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: false,
                refreshVisibleThumbnails: true,
                refreshNearVisibleThumbnails: true,
                applySelection: false
            )
        )
    }

    func testContentRevisionOwnsVisibleConfigurationWithoutSecondThumbnailPass() {
        let previous = state(content: 1, metadata: 10, generation: UUID())
        let incoming = state(content: 2, metadata: 10, generation: UUID())
        let decision = AssetCollectionUpdatePolicy.decision(
            previous: previous,
            incoming: incoming
        )

        XCTAssertTrue(decision.rebuildContent)
        XCTAssertFalse(decision.refreshVisibleMetadata)
        XCTAssertFalse(decision.refreshVisibleThumbnails)
        XCTAssertFalse(decision.refreshNearVisibleThumbnails)
        XCTAssertTrue(decision.applySelection)
    }

    func testInitialUpdateBuildsContentAndSeedsMetadataOnce() {
        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(
                previous: nil,
                incoming: state(content: 1, metadata: 1)
            ),
            AssetCollectionUpdateDecision(
                rebuildContent: true,
                refreshVisibleMetadata: true,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false,
                applySelection: true
            )
        )
    }

    func testSelectionDeltaRestoresRequestedSelectionClearedBySnapshot() {
        let requested = UUID()

        XCTAssertEqual(
            AssetCollectionSelectionPolicy.delta(
                requestedAvailableIDs: [requested],
                actualSelectedIDs: []
            ),
            AssetCollectionSelectionDelta(select: [requested], deselect: [])
        )
    }

    func testSelectionDeltaReturnsNoOpForEqualActualSelection() {
        let first = UUID()
        let second = UUID()
        let selected: Set<UUID> = [first, second]

        XCTAssertTrue(
            AssetCollectionSelectionPolicy.delta(
                requestedAvailableIDs: selected,
                actualSelectedIDs: selected
            ).isEmpty
        )
    }

    func testSelectionDeltaTouchesOnlyChangedIDs() {
        let retained = UUID()
        let removed = UUID()
        let added = UUID()

        XCTAssertEqual(
            AssetCollectionSelectionPolicy.delta(
                requestedAvailableIDs: [retained, added],
                actualSelectedIDs: [retained, removed]
            ),
            AssetCollectionSelectionDelta(select: [added], deselect: [removed])
        )
    }

    func testAccessibilitySelectionTogglePreservesTheRestOfAMultiSelection() {
        let retained = UUID()
        let toggled = UUID()
        let selected: Set<UUID> = [retained, toggled]

        XCTAssertEqual(
            AssetCollectionSelectionPolicy.toggling(toggled, in: selected),
            [retained]
        )
        XCTAssertEqual(
            AssetCollectionSelectionPolicy.toggling(toggled, in: [retained]),
            [retained, toggled]
        )
    }

    @MainActor
    func testDisabledAssetItemRejectsAccessibilityActionsUntilReenabled() throws {
        let item = AssetCollectionItem()
        let asset = AppAsset(
            id: UUID(),
            url: URL(fileURLWithPath: "/source/IMG_0001.JPG"),
            relativePath: "IMG_0001.JPG",
            byteCount: 1,
            modifiedAt: .distantPast,
            category: .photo,
            sourceVolumeID: SourceVolumeID(),
            fingerprint: FileFingerprint(
                device: 1,
                inode: 1,
                byteSize: 1,
                modifiedSeconds: 0,
                modifiedNanoseconds: 0
            )
        )
        var pressCount = 0
        var toggleCount = 0
        item.configure(
            asset: asset,
            sceneName: nil,
            isExcluded: false,
            rating: .unrated,
            ratingIsLoaded: true,
            ratingIsExplicit: false,
            labelNumber: 0,
            labelIsLoaded: true,
            hasMetadataError: false,
            metadataErrorMessage: nil,
            metadataWarningMessage: nil,
            metadataIsLoading: false,
            isReviewContext: true,
            mediaPipeline: nil,
            interactionsAreEnabled: true,
            onToggleSelection: {
                toggleCount += 1
                return true
            },
            onOpen: { _ in pressCount += 1 }
        )

        let initialAction = try XCTUnwrap(item.view.accessibilityCustomActions()?.first)
        XCTAssertTrue(initialAction.handler?() ?? false)
        XCTAssertEqual(toggleCount, 1)

        item.updateInteractionsEnabled(false)
        XCTAssertFalse(item.view.accessibilityPerformPress())
        XCTAssertEqual(pressCount, 0)
        XCTAssertNil(item.view.accessibilityCustomActions())
        XCTAssertFalse(
            initialAction.handler?() ?? true,
            "an accessibility client holding the old action must still be rejected while busy"
        )
        XCTAssertEqual(toggleCount, 1)

        item.updateInteractionsEnabled(true)
        XCTAssertTrue(item.view.accessibilityPerformPress())
        XCTAssertEqual(pressCount, 1)
        let restoredAction = try XCTUnwrap(item.view.accessibilityCustomActions()?.first)
        XCTAssertTrue(restoredAction.handler?() ?? false)
        XCTAssertEqual(toggleCount, 2)
    }

    private func state(
        content: UInt64,
        metadata: UInt64,
        selection: UInt64 = 0,
        generation: UUID? = nil,
        hasMediaPipeline: Bool = true
    ) -> AssetCollectionUpdateState {
        AssetCollectionUpdateState(
            contentRevision: content,
            metadataRevision: metadata,
            selectionRevision: selection,
            thumbnailReloadGeneration: generation,
            hasMediaPipeline: hasMediaPipeline
        )
    }
}
