import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

@MainActor
final class AssetBrowserSelectionInvariantTests: XCTestCase {
    func testIngestSelectionNarrowsSynchronouslyForSearchCategoryAndSourceChanges() {
        let model = AppModel(initializeServices: false)
        let photo = asset(index: 1, name: "IMG_0001.JPG", category: .photo)
        let movie = asset(index: 2, name: "CLIP_0002.MOV", category: .movie)
        model.assets = [photo, movie]
        model.selectedAssetIDs = [photo.id, movie.id]

        model.ingestAssetSearchText = "IMG"

        XCTAssertEqual(model.ingestBrowserProjection.visibleAssetIDs, [photo.id])
        XCTAssertEqual(model.selectedAssetIDs, [photo.id])

        model.ingestAssetSearchText = ""
        XCTAssertEqual(model.ingestBrowserProjection.visibleAssetIDs, [photo.id, movie.id])
        XCTAssertEqual(
            model.selectedAssetIDs,
            [photo.id],
            "clearing a filter must not silently restore a previously hidden selection"
        )

        model.selectedAssetIDs = [photo.id, movie.id]
        model.ingestAssetCategoryFilter = .movie
        XCTAssertEqual(model.selectedAssetIDs, [movie.id])

        model.ingestAssetCategoryFilter = nil
        XCTAssertEqual(model.selectedAssetIDs, [movie.id])
        model.assets = [photo]
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
    }

    func testReviewSelectionNarrowsSynchronouslyForSearchCategoryAndSourceChanges() {
        let model = AppModel(initializeServices: false)
        let photo = asset(index: 3, name: "IMG_0003.JPG", category: .photo)
        let movie = asset(index: 4, name: "CLIP_0004.MOV", category: .movie)
        model.reviewAssets = [photo, movie]
        model.reviewSelectedAssetIDs = [photo.id, movie.id]

        model.reviewAssetSearchText = "CLIP"

        XCTAssertEqual(model.reviewBrowserProjection.visibleAssetIDs, [movie.id])
        XCTAssertEqual(model.reviewSelectedAssetIDs, [movie.id])

        model.reviewAssetSearchText = ""
        XCTAssertEqual(model.reviewBrowserProjection.visibleAssetIDs, [photo.id, movie.id])
        XCTAssertEqual(
            model.reviewSelectedAssetIDs,
            [movie.id],
            "clearing a filter must not silently restore a previously hidden selection"
        )

        model.reviewSelectedAssetIDs = [photo.id, movie.id]
        model.reviewAssetCategoryFilter = .photo
        XCTAssertEqual(model.reviewSelectedAssetIDs, [photo.id])

        model.reviewAssetCategoryFilter = nil
        XCTAssertEqual(model.reviewSelectedAssetIDs, [photo.id])
        model.reviewSelectedAssetIDs = [movie.id]
        model.reviewAssets = [movie]
        XCTAssertEqual(model.reviewSelectedAssetIDs, [movie.id])
        model.reviewAssets = [photo]
        XCTAssertTrue(model.reviewSelectedAssetIDs.isEmpty)
    }

    func testTwentyThousandUnchangedVisibleSelectionsDoNotAdvanceSelectionRevisions() {
        let model = AppModel(initializeServices: false)
        let assets = (0 ..< 20_000).map {
            asset(index: $0 + 10, name: "bulk-\($0).JPG", category: .photo)
        }
        let allIDs = Set(assets.map(\.id))
        model.assets = assets
        model.reviewAssets = assets
        model.selectedAssetIDs = allIDs
        model.reviewSelectedAssetIDs = allIDs
        let ingestRevision = model.ingestCollectionSelectionRevision
        let reviewRevision = model.reviewCollectionSelectionRevision

        model.ingestAssetSearchText = "bulk-"
        model.ingestAssetCategoryFilter = .photo
        model.reviewAssetSearchText = "bulk-"
        model.reviewAssetCategoryFilter = .photo

        XCTAssertEqual(model.selectedAssetIDs, allIDs)
        XCTAssertEqual(model.reviewSelectedAssetIDs, allIDs)
        XCTAssertEqual(
            model.ingestCollectionSelectionRevision,
            ingestRevision,
            "an unchanged 20k selection must not trigger AppKit selection reconciliation"
        )
        XCTAssertEqual(
            model.reviewCollectionSelectionRevision,
            reviewRevision,
            "an unchanged 20k selection must not trigger AppKit selection reconciliation"
        )
    }

    private func asset(index: Int, name: String, category: AssetCategory) -> AppAsset {
        AppAsset(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/umis-selection-invariant/\(name)"),
            relativePath: "media/\(name)",
            byteCount: 1,
            modifiedAt: .distantPast,
            category: category,
            sourceVolumeID: SourceVolumeID(),
            fingerprint: FileFingerprint(
                device: 1,
                inode: UInt64(index + 1),
                byteSize: 1,
                modifiedSeconds: 0,
                modifiedNanoseconds: 0
            )
        )
    }
}
