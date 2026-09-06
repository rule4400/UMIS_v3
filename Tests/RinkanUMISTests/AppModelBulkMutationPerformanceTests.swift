import Combine
import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

@MainActor
final class AppModelBulkMutationPerformanceTests: XCTestCase {
    func testSelectionRevisionChangesOnlyWhenSelectionContentChanges() {
        let model = AppModel()
        let first = UUID()
        let second = UUID()
        let initialIngestRevision = model.ingestCollectionSelectionRevision
        let initialReviewRevision = model.reviewCollectionSelectionRevision

        model.selectedAssetIDs = [first, second]
        XCTAssertEqual(model.ingestCollectionSelectionRevision, initialIngestRevision &+ 1)
        model.selectedAssetIDs = [second, first]
        XCTAssertEqual(
            model.ingestCollectionSelectionRevision,
            initialIngestRevision &+ 1,
            "assigning the same large logical selection must not trigger reconciliation"
        )
        model.selectedAssetIDs.remove(first)
        XCTAssertEqual(model.ingestCollectionSelectionRevision, initialIngestRevision &+ 2)

        model.reviewSelectedAssetIDs = [first]
        XCTAssertEqual(model.reviewCollectionSelectionRevision, initialReviewRevision &+ 1)
        model.reviewSelectedAssetIDs = [first]
        XCTAssertEqual(model.reviewCollectionSelectionRevision, initialReviewRevision &+ 1)
        model.reviewSelectedAssetIDs.removeAll()
        XCTAssertEqual(model.reviewCollectionSelectionRevision, initialReviewRevision &+ 2)
    }

    func testTwentyThousandSceneAssignmentsPublishAndReviseOncePerBatch() {
        let model = AppModel()
        let assetIDs = Set((0 ..< 20_000).map { _ in UUID() })
        let sceneID = UUID()
        var publicationCount = 0
        let publication = model.$sceneAssignments
            .dropFirst()
            .sink { _ in publicationCount += 1 }
        let initialRevision = model.ingestCollectionMetadataRevision

        model.applySceneAssignmentBatch(assetIDs, sceneID: sceneID)

        XCTAssertEqual(model.sceneAssignments.count, 20_000)
        XCTAssertTrue(model.sceneAssignments.values.allSatisfy { $0 == sceneID })
        XCTAssertEqual(model.assignmentCount(for: sceneID), 20_000)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(model.ingestCollectionMetadataRevision, initialRevision &+ 1)

        model.applySceneAssignmentBatch(assetIDs, sceneID: sceneID)
        XCTAssertEqual(publicationCount, 1, "an unchanged batch must not publish")
        XCTAssertEqual(model.ingestCollectionMetadataRevision, initialRevision &+ 1)

        model.applySceneAssignmentBatch(assetIDs, sceneID: nil)
        XCTAssertTrue(model.sceneAssignments.isEmpty)
        XCTAssertEqual(model.assignmentCount(for: sceneID), 0)
        XCTAssertEqual(publicationCount, 2)
        XCTAssertEqual(model.ingestCollectionMetadataRevision, initialRevision &+ 2)

        model.applySceneAssignmentBatch(assetIDs, sceneID: nil)
        XCTAssertEqual(publicationCount, 2, "an already-removed batch must not publish")
        XCTAssertEqual(model.ingestCollectionMetadataRevision, initialRevision &+ 2)
        withExtendedLifetime(publication) {}
    }

    func testTwentyThousandExplicitExclusionsPublishEachCollectionAtMostOnce() throws {
        let model = AppModel()
        let assetIDs = (0 ..< 20_000).map { _ in UUID() }
        let assetIDSet = Set(assetIDs)
        let sceneID = UUID()
        model.applySceneAssignmentBatch(assetIDSet, sceneID: sceneID)

        let sourceVolumeID = SourceVolumeID()
        let assets = assetIDs.enumerated().map { offset, assetID in
            let filename = "asset-\(offset).MOV"
            return MediaAsset(
                id: MediaAssetID(rawValue: assetID),
                sourceVolumeID: sourceVolumeID,
                relativePath: "bulk/asset-\(offset).MOV",
                canonicalURL: URL(fileURLWithPath: "/tmp/umis-bulk-test/\(filename)"),
                originalName: filename,
                pathExtension: "MOV",
                byteSize: 1,
                kind: .movie,
                fingerprint: FileFingerprint(
                    device: 1,
                    inode: UInt64(offset + 1),
                    byteSize: 1,
                    modifiedSeconds: 1,
                    modifiedNanoseconds: 0
                )
            )
        }
        let evidence = try AppModel.makeExplicitExclusionEvidenceBatch(
            assets: assets,
            assetIDs: assetIDSet,
            reason: "Bulk publication regression test",
            operatorIdentifier: "test-operator",
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(evidence.count, 20_000)
        model.assets = assets.map(AppAsset.init(coreAsset:))
        XCTAssertEqual(model.assignedCount, 20_000)
        model.selectedAssetIDs = assetIDSet
        model.excludeSelectionFromIngest()
        XCTAssertEqual(model.pendingExclusionAssets.count, 20_000)
        XCTAssertEqual(model.pendingExclusionTotalBytes, 20_000)
        model.cancelPendingAssetExclusion()
        var exclusionPublicationCount = 0
        var scenePublicationCount = 0
        let exclusionPublication = model.$explicitlyExcludedAssetIDs
            .dropFirst()
            .sink { _ in exclusionPublicationCount += 1 }
        let scenePublication = model.$sceneAssignments
            .dropFirst()
            .sink { _ in scenePublicationCount += 1 }
        let initialRevision = model.ingestCollectionMetadataRevision

        model.commitExplicitAssetExclusionEvidence(evidence)

        XCTAssertEqual(model.explicitlyExcludedAssetIDs, assetIDSet)
        XCTAssertEqual(model.assignedCount, 0)
        XCTAssertEqual(model.explicitExclusionAssets.count, 20_000)
        XCTAssertEqual(model.explicitExclusionTotalBytes, 20_000)
        XCTAssertEqual(
            model.explicitExclusionAssets,
            model.explicitExclusionAssets.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        )
        XCTAssertTrue(model.sceneAssignments.isEmpty)
        XCTAssertEqual(exclusionPublicationCount, 1)
        XCTAssertEqual(scenePublicationCount, 1)
        let revisionAfterCommit = model.ingestCollectionMetadataRevision
        XCTAssertGreaterThan(revisionAfterCommit, initialRevision)
        XCTAssertLessThanOrEqual(
            revisionAfterCommit,
            initialRevision &+ 2,
            "revision changes are bounded by the two Published collections, never asset count"
        )

        model.commitExplicitAssetExclusionEvidence(evidence)
        XCTAssertEqual(exclusionPublicationCount, 1, "an unchanged exclusion set must not publish")
        XCTAssertEqual(scenePublicationCount, 1, "already-removed assignments must not publish")
        XCTAssertEqual(model.ingestCollectionMetadataRevision, revisionAfterCommit)
        withExtendedLifetime((exclusionPublication, scenePublication)) {}
    }
}
