import Foundation
import UMISMedia
import XCTest
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
            thumbnailReloadGeneration: generation,
            hasMediaPipeline: true
        )

        XCTAssertEqual(
            AssetCollectionUpdatePolicy.decision(previous: state, incoming: state),
            AssetCollectionUpdateDecision(
                rebuildContent: false,
                refreshVisibleMetadata: false,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false
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
                refreshNearVisibleThumbnails: false
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
                refreshNearVisibleThumbnails: true
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
                refreshNearVisibleThumbnails: true
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
                refreshNearVisibleThumbnails: false
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

    private func state(
        content: UInt64,
        metadata: UInt64,
        generation: UUID? = nil,
        hasMediaPipeline: Bool = true
    ) -> AssetCollectionUpdateState {
        AssetCollectionUpdateState(
            contentRevision: content,
            metadataRevision: metadata,
            thumbnailReloadGeneration: generation,
            hasMediaPipeline: hasMediaPipeline
        )
    }
}
