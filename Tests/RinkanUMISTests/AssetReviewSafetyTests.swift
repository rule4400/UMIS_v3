import AppKit
import Darwin
import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

final class AssetReviewSafetyTests: XCTestCase {
    func testIngestScanAdmissionDefersForEveryReviewBoundary() {
        XCTAssertFalse(AppModel.ingestScanAdmissionMustWait(phase: .idle))
        XCTAssertFalse(
            AppModel.ingestScanAdmissionMustWait(phase: .scanning),
            "the current ingest scan may be deliberately replaced"
        )
        XCTAssertTrue(AppModel.ingestScanAdmissionMustWait(phase: .planning))
        XCTAssertTrue(AppModel.ingestScanAdmissionMustWait(phase: .idle, reviewIsScanning: true))
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                auditExportInFlight: true
            ),
            "a durable audit snapshot must not race an automatic card scan"
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                mediaCacheOperationInFlight: true
            ),
            "a cache-clear suspension boundary must defer automatic card scans"
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(phase: .idle, reviewMetadataIsLoading: true)
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(phase: .idle, reviewMetadataIsWriting: true)
        )
        XCTAssertTrue(AppModel.ingestScanAdmissionMustWait(phase: .idle, hasReviewScanTask: true))
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(phase: .idle, hasReviewMetadataTask: true)
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                mediaAccessQuiescenceLatched: true
            )
        )
        XCTAssertFalse(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true
            ),
            "a fresh scan is the only operation allowed to resolve unexpected-removal isolation"
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                reviewMetadataIsWriting: true,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true
            ),
            "review mutation always owns the boundary even if an older card isolation exists"
        )

        XCTAssertTrue(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: true,
                applicationReady: true,
                phase: .idle,
                ingestScanAdmissionMustWait: false,
                hasIngestScanTask: false,
                mediaAccessQuiescenceLatched: false,
                hasMediaReadIsolationGeneration: false,
                hasMediaReadIsolationTask: false,
                mediaReadIsolationFailed: false,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            ),
            "a normal idle source scan uses the shared exclusive-operation admission"
        )
        XCTAssertTrue(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                applicationReady: true,
                phase: .idle,
                ingestScanAdmissionMustWait: false,
                hasIngestScanTask: false,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: false,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            ),
            "a complete removal-isolation boundary must remain reachable by a fresh scan"
        )

        let blockedRecoveryStates: [(Bool, Bool, Bool, Bool, Bool, WorkspacePhase)] = [
            (false, true, true, false, false, .idle),
            (true, false, true, false, false, .idle),
            (true, true, false, false, false, .idle),
            (true, true, true, true, false, .idle),
            (true, true, true, false, true, .idle),
            (true, true, true, false, false, .scanning),
        ]
        for (latch, generation, task, quarantine, deferred, phase) in blockedRecoveryStates {
            XCTAssertFalse(
                AppModel.ingestSourceScanAdmissionAllowed(
                    canStartExclusiveOperation: false,
                    applicationReady: true,
                    phase: phase,
                    ingestScanAdmissionMustWait: false,
                    hasIngestScanTask: false,
                    mediaAccessQuiescenceLatched: latch,
                    hasMediaReadIsolationGeneration: generation,
                    hasMediaReadIsolationTask: task,
                    mediaReadIsolationFailed: false,
                    destructiveOutcomeQuarantined: quarantine,
                    hasDeferredCardScan: deferred
                )
            )
        }
        XCTAssertFalse(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                applicationReady: true,
                phase: .idle,
                ingestScanAdmissionMustWait: true,
                hasIngestScanTask: false,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: false,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            ),
            "rename, review, cache, audit, LAN, or another operation must retain the boundary"
        )
        XCTAssertFalse(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                applicationReady: false,
                phase: .idle,
                ingestScanAdmissionMustWait: false,
                hasIngestScanTask: false,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: false,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            )
        )
        XCTAssertFalse(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                applicationReady: true,
                phase: .idle,
                ingestScanAdmissionMustWait: false,
                hasIngestScanTask: true,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: false,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            ),
            "a cancelled scanner must actually unwind before any manual replacement scan starts"
        )
        XCTAssertFalse(
            AppModel.ingestSourceScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                applicationReady: true,
                phase: .idle,
                ingestScanAdmissionMustWait: false,
                hasIngestScanTask: false,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: true,
                destructiveOutcomeQuarantined: false,
                hasDeferredCardScan: false
            ),
            "failed media quiescence requires restart and cannot be retried through the source UI"
        )
        XCTAssertTrue(
            AppModel.ingestScanAdmissionMustWait(
                phase: .idle,
                mediaAccessQuiescenceLatched: true,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                mediaReadIsolationFailed: true
            )
        )
        let isolationGeneration = UUID()
        XCTAssertTrue(
            AppModel.preservesRestartRequiredIsolationFailure(
                requiredIsolationGeneration: isolationGeneration,
                currentIsolationGeneration: isolationGeneration,
                mediaReadIsolationFailed: true
            )
        )
        XCTAssertFalse(
            AppModel.preservesRestartRequiredIsolationFailure(
                requiredIsolationGeneration: isolationGeneration,
                currentIsolationGeneration: UUID(),
                mediaReadIsolationFailed: true
            )
        )
        XCTAssertTrue(
            AppModel.ingestScanBoundaryRetirementIsVisible(
                hasActiveIngestScanTask: true,
                phase: .ready
            ),
            "obsolete scanners still retiring must remain visible after the current scan settles"
        )
        XCTAssertFalse(
            AppModel.ingestScanBoundaryRetirementIsVisible(
                hasActiveIngestScanTask: true,
                phase: .scanning
            ),
            "the ordinary scanning presentation already covers an active current scanner"
        )
        XCTAssertFalse(AppModel.permitsNewMediaIsolationAttempt(mediaReadIsolationFailed: true))
        XCTAssertTrue(AppModel.permitsNewMediaIsolationAttempt(mediaReadIsolationFailed: false))
    }

    func testCacheClearResumePolicyRejectsNewRemovalIsolationOrDestructiveQuarantine() {
        let originalIsolation = UUID()
        let replacementIsolation = UUID()

        XCTAssertTrue(
            AppModel.permitsMediaReadResumeAfterCacheClear(
                expectedIsolationGeneration: nil,
                currentIsolationGeneration: nil,
                mediaAccessQuiescenceLatched: false,
                destructiveOutcomeQuarantined: false
            )
        )
        XCTAssertFalse(
            AppModel.permitsMediaReadResumeAfterCacheClear(
                expectedIsolationGeneration: originalIsolation,
                currentIsolationGeneration: originalIsolation,
                mediaAccessQuiescenceLatched: false,
                destructiveOutcomeQuarantined: false
            ),
            "cache clear must never begin or resume while any isolation generation exists"
        )
        XCTAssertFalse(
            AppModel.permitsMediaReadResumeAfterCacheClear(
                expectedIsolationGeneration: originalIsolation,
                currentIsolationGeneration: replacementIsolation,
                mediaAccessQuiescenceLatched: true,
                destructiveOutcomeQuarantined: false
            ),
            "a removal that starts during cache clear must keep the pipeline suspended"
        )
        XCTAssertFalse(
            AppModel.permitsMediaReadResumeAfterCacheClear(
                expectedIsolationGeneration: originalIsolation,
                currentIsolationGeneration: originalIsolation,
                mediaAccessQuiescenceLatched: true,
                destructiveOutcomeQuarantined: false
            )
        )
        XCTAssertFalse(
            AppModel.permitsMediaReadResumeAfterCacheClear(
                expectedIsolationGeneration: originalIsolation,
                currentIsolationGeneration: originalIsolation,
                mediaAccessQuiescenceLatched: false,
                destructiveOutcomeQuarantined: true
            )
        )
    }

    func testMediaCacheClearAdmissionRejectsCaptureDateEnrichmentAndStaleIsolation() {
        XCTAssertTrue(
            AppModel.mediaCacheClearAdmissionAllowed(
                canStartExclusiveOperation: true,
                captureDateMetadataIsLoading: false,
                hasCaptureDateEnrichmentTask: false,
                hasMediaReadIsolationGeneration: false,
                hasMediaReadIsolationTask: false,
                hasMediaPipeline: true
            )
        )
        XCTAssertFalse(
            AppModel.mediaCacheClearAdmissionAllowed(
                canStartExclusiveOperation: true,
                captureDateMetadataIsLoading: true,
                hasCaptureDateEnrichmentTask: true,
                hasMediaReadIsolationGeneration: false,
                hasMediaReadIsolationTask: false,
                hasMediaPipeline: true
            ),
            "cache clear must not cancel progressive metadata into an mtime fallback"
        )
        XCTAssertFalse(
            AppModel.mediaCacheClearAdmissionAllowed(
                canStartExclusiveOperation: true,
                captureDateMetadataIsLoading: false,
                hasCaptureDateEnrichmentTask: false,
                hasMediaReadIsolationGeneration: true,
                hasMediaReadIsolationTask: true,
                hasMediaPipeline: true
            ),
            "a stale or active card isolation must fail closed even if its latch invariant regresses"
        )
        XCTAssertFalse(
            AppModel.mediaCacheClearAdmissionAllowed(
                canStartExclusiveOperation: false,
                captureDateMetadataIsLoading: false,
                hasCaptureDateEnrichmentTask: false,
                hasMediaReadIsolationGeneration: false,
                hasMediaReadIsolationTask: false,
                hasMediaPipeline: true
            )
        )
    }

    func testMediaCacheUsageSummaryUsesLatestMeasurementGeneration() {
        let oldMeasurement = UUID()
        let currentMeasurement = UUID()

        XCTAssertFalse(AppModel.acceptsMediaCacheSummary(
            measurementGeneration: oldMeasurement,
            currentGeneration: currentMeasurement
        ))
        XCTAssertTrue(AppModel.acceptsMediaCacheSummary(
            measurementGeneration: currentMeasurement,
            currentGeneration: currentMeasurement
        ))
    }

    func testProjectDeletionUsesTheSharedExclusiveOperationAdmission() {
        XCTAssertTrue(
            AppModel.projectDeletionAdmissionAllowed(
                canStartExclusiveOperation: true,
                hasSelectedProject: true,
                hasProjectStore: true
            )
        )
        XCTAssertFalse(
            AppModel.projectDeletionAdmissionAllowed(
                canStartExclusiveOperation: !AppModel.ingestScanAdmissionMustWait(
                    phase: .idle,
                    reviewMetadataIsWriting: true
                ),
                hasSelectedProject: true,
                hasProjectStore: true
            ),
            "a review metadata write must keep project deletion outside the common boundary"
        )
        XCTAssertFalse(
            AppModel.projectDeletionAdmissionAllowed(
                canStartExclusiveOperation: true,
                hasSelectedProject: false,
                hasProjectStore: true
            )
        )
    }

    func testReviewScanRevalidatesAdmissionAfterModalEventLoop() {
        XCTAssertTrue(
            AppModel.reviewScanAdmissionAllowed(
                canStartExclusiveOperation: true,
                reviewIsScanning: false,
                reviewMetadataIsLoading: false,
                reviewMetadataIsWriting: false
            )
        )
        XCTAssertFalse(
            AppModel.reviewScanAdmissionAllowed(
                canStartExclusiveOperation: false,
                reviewIsScanning: false,
                reviewMetadataIsLoading: false,
                reviewMetadataIsWriting: false
            ),
            "a card scan admitted by the modal event loop must block the later review scan"
        )
        XCTAssertFalse(
            AppModel.reviewScanAdmissionAllowed(
                canStartExclusiveOperation: true,
                reviewIsScanning: true,
                reviewMetadataIsLoading: false,
                reviewMetadataIsWriting: false
            )
        )
    }

    @MainActor
    func testNewReviewSourceInvalidatesOldMutationCapabilityBeforeScanCanFail() {
        let model = AppModel()
        let oldRoot = URL(fileURLWithPath: "/tmp/umis-review-old", isDirectory: true)
        let requestedRoot = URL(fileURLWithPath: "/tmp/umis-review-requested", isDirectory: true)
        let assetID = UUID()
        let sourceVolumeID = SourceVolumeID()
        let fingerprint = FileFingerprint(
            device: 10,
            inode: 20,
            byteSize: 30,
            modifiedSeconds: 40,
            modifiedNanoseconds: 50
        )
        let oldAsset = AppAsset(
            id: assetID,
            url: oldRoot.appendingPathComponent("old.jpg"),
            relativePath: "old.jpg",
            byteCount: 30,
            modifiedAt: Date(timeIntervalSince1970: 40),
            category: .photo,
            sourceVolumeID: sourceVolumeID,
            fingerprint: fingerprint
        )

        model.reviewSourceURL = oldRoot
        model.reviewSourceVolumeID = sourceVolumeID
        model.reviewSourceRootPath = oldRoot.path
        model.reviewSourceRootDevice = 10
        model.reviewSourceRootInode = 99
        model.reviewSourceVolumeUUID = "old-volume"
        model.reviewSourceIsReadOnly = false
        model.reviewSourceIsLocal = true
        model.reviewSourceIsEjectable = false
        model.reviewSourceIsInternal = true
        model.reviewAssets = [oldAsset]
        model.reviewSelectedAssetIDs = [assetID]
        model.reviewRatings = [assetID: .fiveStars]
        model.reviewRatingLoadedAssetIDs = [assetID]
        model.reviewRatingExplicitAssetIDs = [assetID]
        model.reviewLabelNumbers = [assetID: 2]
        model.reviewLabelLoadedAssetIDs = [assetID]

        model.invalidateReviewSourceStateForScan(requestedURL: requestedRoot)

        XCTAssertEqual(model.reviewSourceURL, requestedRoot.standardizedFileURL)
        XCTAssertTrue(model.reviewAssets.isEmpty)
        XCTAssertTrue(model.reviewSelectedAssetIDs.isEmpty)
        XCTAssertEqual(model.reviewVisibleSelectionCount, 0)
        XCTAssertNil(model.reviewSourceRootPath)
        XCTAssertNil(model.reviewSourceRootDevice)
        XCTAssertNil(model.reviewSourceRootInode)
        XCTAssertNil(model.reviewSourceVolumeUUID)
        XCTAssertNil(model.reviewSourceIsReadOnly)
        XCTAssertFalse(model.reviewSourceIsLocal)
        XCTAssertTrue(model.reviewSourceIsEjectable)
        XCTAssertFalse(model.reviewSourceIsInternal)
        XCTAssertTrue(model.reviewRatings.isEmpty)
        XCTAssertTrue(model.reviewRatingLoadedAssetIDs.isEmpty)
        XCTAssertTrue(model.reviewRatingExplicitAssetIDs.isEmpty)
        XCTAssertTrue(model.reviewLabelNumbers.isEmpty)
        XCTAssertTrue(model.reviewLabelLoadedAssetIDs.isEmpty)
        XCTAssertNotNil(
            model.reviewMutationBlockReason,
            "a failed requested-source scan must never restore write admission for the old archive"
        )
    }

    func testCommittedReviewRootKeepsValidatedFoundationSpellingForTemporaryAlias() throws {
        let validatedSpelling = URL(
            fileURLWithPath: "/tmp/umis-review-root-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: validatedSpelling,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: validatedSpelling) }
        let scannerSpelling = URL(
            fileURLWithPath: "/private\(validatedSpelling.path)",
            isDirectory: true
        )

        XCTAssertEqual(
            try AppModel.committedReviewRootURL(
                scanResultRoot: scannerSpelling,
                validatedIdentityRoot: validatedSpelling
            ),
            validatedSpelling
        )
    }

    func testCommittedReviewRootRejectsAGenuinelyDifferentDirectory() throws {
        let firstRoot = URL(
            fileURLWithPath: "/tmp/umis-review-first-\(UUID().uuidString)",
            isDirectory: true
        )
        let secondRoot = URL(
            fileURLWithPath: "/tmp/umis-review-second-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        XCTAssertThrowsError(
            try AppModel.committedReviewRootURL(
                scanResultRoot: firstRoot,
                validatedIdentityRoot: secondRoot
            )
        ) { error in
            XCTAssertEqual(String(describing: error), "identityChanged")
        }
    }

    @MainActor
    func testPartialReviewScanPublishesBoundedPrivacySafeIssueSummaryAlongsideAssets() {
        let sourceVolumeID = SourceVolumeID()
        let fingerprint = FileFingerprint(
            device: 10,
            inode: 20,
            byteSize: 30,
            modifiedSeconds: 40,
            modifiedNanoseconds: 50
        )
        let asset = MediaAsset(
            sourceVolumeID: sourceVolumeID,
            relativePath: "accepted/photo.jpg",
            canonicalURL: URL(fileURLWithPath: "/archive/accepted/photo.jpg"),
            originalName: "photo.jpg",
            pathExtension: "jpg",
            byteSize: fingerprint.byteSize,
            kind: .photo,
            fingerprint: fingerprint
        )
        let partialResult = ScanResult(
            root: URL(fileURLWithPath: "/archive", isDirectory: true),
            sourceVolumeID: sourceVolumeID,
            assets: [asset],
            inventory: [
                InventoryEntry(
                    relativePath: asset.relativePath,
                    type: .regularFile,
                    classification: .requiredByUser,
                    byteSize: fingerprint.byteSize,
                    fingerprint: fingerprint,
                    mediaAssetID: asset.id
                ),
            ],
            issues: [
                ScanIssue(
                    relativePath: "changing/clip.mov",
                    message: "Entry changed before the scan completed"
                ),
                ScanIssue(
                    relativePath: "/Users/private-person/secret.jpg",
                    message: "Foundation failure: NSFilePath=/Volumes/Secret/secret.jpg"
                ),
                ScanIssue(
                    relativePath: "locked/photo.jpg",
                    message: "Permission denied at /Volumes/Secret/locked/photo.jpg"
                ),
            ],
            inventoryDigest: "partial-result"
        )
        let model = AppModel()

        model.reviewAssets = partialResult.assets.map(AppAsset.init(coreAsset:))
        model.adoptReviewScanIssues(from: partialResult, sampleLimit: 2)

        XCTAssertEqual(model.reviewAssets.map(\.relativePath), ["accepted/photo.jpg"])
        XCTAssertEqual(model.reviewScanIssueCount, 3)
        XCTAssertEqual(model.reviewScanIssueSamples.count, 2)
        XCTAssertEqual(
            model.reviewScanIssueSamples.first,
            "changing/clip.mov: 走査中に内容が変更されました"
        )
        XCTAssertTrue(model.reviewScanIssueSamples[1].hasPrefix("場所非表示: "))
        XCTAssertEqual(model.reviewScanIssueStatusSummary, "走査中に確認できなかった項目 3件")
        let displayed = model.reviewScanIssueSamples.joined(separator: "\n")
        XCTAssertFalse(displayed.contains("/Users/"))
        XCTAssertFalse(displayed.contains("/Volumes/"))
        XCTAssertFalse(displayed.contains("private-person"))
    }

    @MainActor
    func testReviewScanIssueStateClearsForCleanResultAndAtNextScanStart() {
        let sourceVolumeID = SourceVolumeID()
        let issueResult = ScanResult(
            root: URL(fileURLWithPath: "/archive", isDirectory: true),
            sourceVolumeID: sourceVolumeID,
            assets: [],
            inventory: [],
            issues: [ScanIssue(relativePath: "unstable.mov", message: "changed")],
            inventoryDigest: "with-issue"
        )
        var cleanResult = issueResult
        cleanResult.issues = []
        cleanResult.inventoryDigest = "clean"
        let model = AppModel()

        model.adoptReviewScanIssues(from: issueResult)
        XCTAssertEqual(model.reviewScanIssueCount, 1)

        model.adoptReviewScanIssues(from: cleanResult)
        XCTAssertEqual(model.reviewScanIssueCount, 0)
        XCTAssertTrue(model.reviewScanIssueSamples.isEmpty)
        XCTAssertNil(model.reviewScanIssueStatusSummary)

        model.adoptReviewScanIssues(from: issueResult)
        model.invalidateReviewSourceStateForScan(
            requestedURL: URL(fileURLWithPath: "/archive-again", isDirectory: true)
        )
        XCTAssertEqual(model.reviewScanIssueCount, 0)
        XCTAssertTrue(model.reviewScanIssueSamples.isEmpty)
        XCTAssertNil(model.reviewScanIssueStatusSummary)
    }

    func testHiddenSelectionIsRemovedAtEveryMutationBoundaryHelper() {
        let visible = UUID()
        let hidden = UUID()
        XCTAssertEqual(
            AppModel.visibleSelection([visible, hidden], within: [visible]),
            [visible]
        )
    }

    func testSuccessfulWriteClearsOnlyItsOwnMetadataErrorDomain() {
        let assetID = UUID()
        var ratingErrors = [assetID: "XMP error"]
        var labelErrors = [assetID: "Finder error"]
        let successfulLabelWrite = ReviewMetadataWriteResult(
            assetID: assetID,
            error: nil,
            fingerprintAfter: nil,
            warning: nil,
            ratingIsExplicit: nil
        )
        AppModel.applyReviewDomainErrorResult(
            successfulLabelWrite,
            domain: .finderLabel,
            ratingErrors: &ratingErrors,
            labelErrors: &labelErrors
        )
        XCTAssertEqual(ratingErrors[assetID], "XMP error")
        XCTAssertNil(labelErrors[assetID])

        labelErrors[assetID] = "Finder error"
        let successfulRatingWrite = ReviewMetadataWriteResult(
            assetID: assetID,
            error: nil,
            fingerprintAfter: nil,
            warning: nil,
            ratingIsExplicit: true
        )
        AppModel.applyReviewDomainErrorResult(
            successfulRatingWrite,
            domain: .rating,
            ratingErrors: &ratingErrors,
            labelErrors: &labelErrors
        )
        XCTAssertNil(ratingErrors[assetID])
        XCTAssertEqual(labelErrors[assetID], "Finder error")
    }

    func testFailedRatingWritePreservesIndependentCompatibilityWarning() {
        let assetID = UUID()
        var warnings = [assetID: "Adobe sidecar互換性は未検証"]
        AppModel.applyReviewRatingWarningResult(
            ReviewMetadataWriteResult(
                assetID: assetID,
                error: "concurrent modification",
                fingerprintAfter: nil,
                warning: nil,
                ratingIsExplicit: nil
            ),
            warnings: &warnings
        )
        XCTAssertEqual(warnings[assetID], "Adobe sidecar互換性は未検証")

        AppModel.applyReviewRatingWarningResult(
            ReviewMetadataWriteResult(
                assetID: assetID,
                error: nil,
                fingerprintAfter: nil,
                warning: nil,
                ratingIsExplicit: true
            ),
            warnings: &warnings
        )
        XCTAssertNil(warnings[assetID])
    }

    func testRecoveryRetainedErrorsAreFatalBatchSignals() {
        XCTAssertTrue(AppModel.isRecoveryRetained(
            AdobeXMPRatingServiceError.recoveryRetained(
                path: "/archive/a.jpg",
                recoveryDirectoryLeaf: ".umis-xmp-recovery-test",
                originalBackupRetained: true,
                cleanupIncomplete: true,
                reason: "test"
            )
        ))
        XCTAssertTrue(AppModel.isRecoveryRetained(
            AssetMetadataError.recoveryRetained(
                path: "/archive/a.xmp",
                recoveryDirectoryLeaf: ".umis-xmp-recovery-test",
                reason: "test"
            )
        ))
        XCTAssertFalse(AppModel.isRecoveryRetained(
            AssetMetadataError.concurrentModification("/archive/a.jpg")
        ))
    }

    func testReturnAndSpaceOpenPreviewButNavigationKeysDoNot() {
        XCTAssertTrue(AssetCollectionKeyboardPolicy.opensPreview(forKeyCode: 36))
        XCTAssertTrue(AssetCollectionKeyboardPolicy.opensPreview(forKeyCode: 49))
        XCTAssertFalse(AssetCollectionKeyboardPolicy.opensPreview(forKeyCode: 123))
        XCTAssertFalse(AssetCollectionKeyboardPolicy.opensPreview(forKeyCode: 124))
    }

    func testRatingBadgeDistinguishesMissingExplicitZeroRejectAndStars() {
        XCTAssertEqual(
            ReviewRatingBadgePresentation.make(
                rating: .unrated,
                isLoaded: true,
                isExplicit: false,
                isLoading: false
            ),
            ReviewRatingBadgePresentation(
                text: "未設定",
                accessibilityDescription: "Adobe XMP評価は未設定",
                tone: .secondary
            )
        )
        XCTAssertEqual(
            ReviewRatingBadgePresentation.make(
                rating: .unrated,
                isLoaded: true,
                isExplicit: true,
                isLoading: false
            ).text,
            "0"
        )
        XCTAssertEqual(
            ReviewRatingBadgePresentation.make(
                rating: .rejected,
                isLoaded: true,
                isExplicit: true,
                isLoading: false
            ).text,
            "×"
        )
        XCTAssertEqual(
            ReviewRatingBadgePresentation.make(
                rating: .fiveStars,
                isLoaded: true,
                isExplicit: true,
                isLoading: false
            ).text,
            "5★"
        )
        XCTAssertEqual(
            ReviewRatingBadgePresentation.make(
                rating: .unrated,
                isLoaded: false,
                isExplicit: false,
                isLoading: true
            ).text,
            "…"
        )
    }

    @MainActor
    func testAssetCardVoiceOverPressOpensPreviewAndExposesMetadataDetails() throws {
        let asset = makeAsset(
            filename: "IMG_0042.JPG",
            relativePath: "Day2/入学式/IMG_0042.JPG",
            inode: 42
        )
        let item = AssetCollectionItem()
        var openedAssetID: UUID?
        item.configure(
            asset: asset,
            sceneName: nil,
            isExcluded: false,
            rating: .threeStars,
            ratingIsLoaded: true,
            ratingIsExplicit: true,
            labelNumber: 0,
            labelIsLoaded: true,
            hasMetadataError: true,
            metadataErrorMessage: "XMPの読み込みに失敗",
            metadataWarningMessage: "Adobe sidecar互換性は未検証",
            metadataIsLoading: false,
            isReviewContext: true,
            mediaPipeline: nil
        ) { openedAssetID = $0.id }

        XCTAssertTrue(item.view.accessibilityPerformPress())
        XCTAssertEqual(openedAssetID, asset.id)
        let value = try XCTUnwrap(item.view.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Adobe XMP評価 3つ星"))
        XCTAssertTrue(value.contains("XMPの読み込みに失敗"))
        XCTAssertTrue(value.contains("Adobe sidecar互換性は未検証"))
        let help = try XCTUnwrap(item.view.accessibilityHelp())
        XCTAssertTrue(help.contains(asset.relativePath))
        XCTAssertTrue(help.contains("XMPの読み込みに失敗"))
        XCTAssertTrue(help.contains("Adobe sidecar互換性は未検証"))
    }

    func testBrowserFilterMatchesFilenameRelativeFolderAndCategory() {
        let asset = AppAsset(
            id: UUID(),
            url: URL(fileURLWithPath: "/archive/Day1/IMG_0001.JPG"),
            relativePath: "Day1/入学式/IMG_0001.JPG",
            byteCount: 4,
            modifiedAt: .distantPast,
            category: .photo,
            sourceVolumeID: SourceVolumeID(),
            fingerprint: FileFingerprint(
                device: 1,
                inode: 2,
                byteSize: 4,
                modifiedSeconds: 3,
                modifiedNanoseconds: 0
            )
        )

        XCTAssertTrue(asset.matchesBrowserFilter(searchText: "img_0001", category: nil))
        XCTAssertTrue(asset.matchesBrowserFilter(searchText: "入学式", category: .photo))
        XCTAssertFalse(asset.matchesBrowserFilter(searchText: "入学式", category: .movie))
        XCTAssertFalse(asset.matchesBrowserFilter(searchText: "卒業式", category: nil))
    }

    func testReviewScanPolicyIncludesEveryKnownAdobeFormatIndependentlyOfProjectSettings() async throws {
        let policy = AppModel.reviewMediaScanPolicy()
        try policy.validate()
        XCTAssertTrue(policy.categoryRules.allSatisfy(\.isEnabled))
        let declaredExtensions = policy.categoryRules.reduce(into: Set<String>()) {
            $0.formUnion($1.extensions)
        }
        XCTAssertTrue(
            AdobeXMPRatingService.formatSupport.knownReviewExtensions.isSubset(of: declaredExtensions)
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umis-review-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedKinds: [String: MediaKind] = [
            "A.PSD": .photo,
            "B.GIF": .photo,
            "C.M4V": .movie,
            "D.X3F": .rawPhoto,
            "E.R3D": .movie,
            "F.HEIC": .photo,
            "G.MXF": .movie,
            "H.M4A": .audio,
            "I.WAV": .audio,
            "J.DNG": .rawPhoto,
        ]
        for filename in expectedKinds.keys {
            try Data("review-fixture".utf8).write(to: root.appendingPathComponent(filename))
        }
        try Data("unsupported".utf8).write(
            to: root.appendingPathComponent("K.UMISUNKNOWN")
        )

        let result = try await MediaScanner().scan(
            root: root,
            sourceVolumeID: SourceVolumeID(),
            policy: policy
        )
        let kindByFilename = Dictionary(uniqueKeysWithValues: result.assets.map {
            ($0.canonicalURL.lastPathComponent, $0.kind)
        })
        for (filename, expectedKind) in expectedKinds {
            XCTAssertEqual(kindByFilename[filename], expectedKind, filename)
        }
        XCTAssertNil(kindByFilename["K.UMISUNKNOWN"])
        XCTAssertEqual(
            AppModel.unsupportedReviewRegularFilePaths(in: result.inventory),
            ["K.UMISUNKNOWN"]
        )
    }

    private func makeAsset(filename: String, relativePath: String, inode: UInt64) -> AppAsset {
        AppAsset(
            id: UUID(),
            url: URL(fileURLWithPath: "/archive/\(relativePath)"),
            relativePath: relativePath,
            byteCount: 4,
            modifiedAt: .distantPast,
            category: .photo,
            sourceVolumeID: SourceVolumeID(),
            fingerprint: FileFingerprint(
                device: 1,
                inode: inode,
                byteSize: 4,
                modifiedSeconds: 3,
                modifiedNanoseconds: 0
            )
        )
    }

    @MainActor
    func testTileGapIsExactlyOnePhysicalPixelAtOneXAndTwoX() {
        let layout = ExactGapCollectionViewFlowLayout()

        layout.updateBackingScaleFactor(1)
        XCTAssertEqual(layout.minimumInteritemSpacing, 1, accuracy: 0.000_001)
        XCTAssertEqual(layout.minimumLineSpacing, 1, accuracy: 0.000_001)
        XCTAssertEqual(layout.sectionInset.left, 1, accuracy: 0.000_001)

        layout.updateBackingScaleFactor(2)
        XCTAssertEqual(layout.minimumInteritemSpacing, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(layout.minimumLineSpacing, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(layout.sectionInset.left, 0.5, accuracy: 0.000_001)
    }

    @MainActor
    func testLaidOutTileEdgesRemainOnePhysicalPixelApart() throws {
        for scale in [CGFloat(1), CGFloat(2)] {
            let layout = ExactGapCollectionViewFlowLayout()
            layout.itemSize = NSSize(width: 100, height: 80)
            layout.updateBackingScaleFactor(scale)
            let collectionView = NSCollectionView(
                frame: NSRect(x: 0, y: 0, width: 220, height: 300)
            )
            let dataSource = FourItemCollectionDataSource()
            collectionView.dataSource = dataSource
            collectionView.collectionViewLayout = layout
            let scrollView = NSScrollView(frame: collectionView.frame)
            scrollView.documentView = collectionView
            collectionView.reloadData()
            scrollView.layoutSubtreeIfNeeded()
            collectionView.layoutSubtreeIfNeeded()
            layout.prepare()

            let first = try XCTUnwrap(
                layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
            )
            let second = try XCTUnwrap(
                layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))
            )
            let third = try XCTUnwrap(
                layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))
            )

            XCTAssertEqual(
                (second.frame.minX - first.frame.minX - layout.itemSize.width) * scale,
                1,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                third.frame.minX,
                first.frame.minX,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                (third.frame.minY - first.frame.maxY) * scale,
                1,
                accuracy: 0.000_001
            )

            collectionView.dataSource = nil
            scrollView.documentView = nil
            withExtendedLifetime(dataSource) {}
        }
    }

    func testLeaseRejectsAncestorSymlinkPresentBeforeAccess() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "nef")
        defer { fixture.cleanup() }
        let rootFingerprint = try FileFingerprint.capture(at: fixture.root)
        let assetFingerprint = try FileFingerprint.capture(at: fixture.originalAsset)

        try fixture.replaceAssetParentWithSymlink()

        XCTAssertThrowsError(try ReviewFileAccessLease(
            rootURL: fixture.root,
            rootDevice: rootFingerprint.device,
            rootInode: rootFingerprint.inode,
            fileURL: fixture.originalAsset,
            expectedFingerprint: assetFingerprint
        )) { error in
            guard case UMISCoreError.symbolicLinkRejected = error else {
                return XCTFail("Expected symbolicLinkRejected, got \(error)")
            }
        }
    }

    func testCoordinationGateRunsAccessorForExactFrozenPath() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "jpg")
        defer { fixture.cleanup() }
        let root = fixture.root
        let expectedURL = fixture.originalAsset
        let intents = [ReviewCoordinationIntent(url: expectedURL, access: .read)]

        let suppliedURL = try ReviewFileCoordinationGate.coordinate(
            intents: intents,
            frozenRootURL: root
        ) { suppliedURLs in
            try XCTUnwrap(suppliedURLs.first)
        }

        XCTAssertEqual(suppliedURL.standardizedFileURL, expectedURL.standardizedFileURL)
    }

    func testCoordinationGateRejectsMovedOrSymlinkRedirectedSuppliedURL() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "jpg")
        defer { fixture.cleanup() }
        let intents = [ReviewCoordinationIntent(url: fixture.originalAsset, access: .write)]

        XCTAssertThrowsError(try ReviewFileCoordinationGate.requireSuppliedURLs(
            [fixture.decoyAsset],
            match: intents,
            frozenRootURL: fixture.root
        )) { error in
            XCTAssertEqual(error as? UMISCoreError, .identityChanged)
        }

        try fixture.replaceAssetParentWithSymlink()
        XCTAssertThrowsError(try ReviewFileCoordinationGate.requireSuppliedURLs(
            [fixture.originalAsset],
            match: intents,
            frozenRootURL: fixture.root
        )) { error in
            XCTAssertEqual(error as? UMISCoreError, .identityChanged)
        }
    }

    func testFinderLabelWriteCannotBeRedirectedByAncestorReplacement() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "jpg")
        defer { fixture.cleanup() }
        let rootFingerprint = try FileFingerprint.capture(at: fixture.root)
        let originalFingerprint = try FileFingerprint.capture(at: fixture.originalAsset)
        let lease = try ReviewFileAccessLease(
            rootURL: fixture.root,
            rootDevice: rootFingerprint.device,
            rootInode: rootFingerprint.inode,
            fileURL: fixture.originalAsset,
            expectedFingerprint: originalFingerprint
        )

        let service = FinderColorLabelService()
        try lease.withExpectedFileDescriptor(expectedFingerprint: originalFingerprint) { descriptor in
            try service.writeLabelNumber(
                2,
                atFileDescriptor: descriptor,
                displayURL: fixture.originalAsset,
                expectedFingerprint: originalFingerprint
            )
        }
        XCTAssertEqual(try service.readLabelNumber(at: fixture.originalAsset), 2)
        try lease.withExpectedFileDescriptor(expectedFingerprint: originalFingerprint) { descriptor in
            try service.writeLabelNumber(
                0,
                atFileDescriptor: descriptor,
                displayURL: fixture.originalAsset,
                expectedFingerprint: originalFingerprint
            )
        }

        try fixture.replaceAssetParentWithSymlink()

        XCTAssertThrowsError(
            try lease.withExpectedFileDescriptor(expectedFingerprint: originalFingerprint) { descriptor in
                try service.writeLabelNumber(
                    3,
                    atFileDescriptor: descriptor,
                    displayURL: fixture.originalAsset,
                    expectedFingerprint: originalFingerprint
                )
            }
        )
        XCTAssertEqual(try service.readLabelNumber(at: fixture.movedOriginalAsset), 0)
        XCTAssertEqual(try service.readLabelNumber(at: fixture.decoyAsset), 0)
    }

    func testRawSidecarWriteStaysInPinnedParentAfterAncestorReplacement() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "nef")
        defer { fixture.cleanup() }
        let rootFingerprint = try FileFingerprint.capture(at: fixture.root)
        let originalFingerprint = try FileFingerprint.capture(at: fixture.originalAsset)
        let lease = try ReviewFileAccessLease(
            rootURL: fixture.root,
            rootDevice: rootFingerprint.device,
            rootInode: rootFingerprint.inode,
            fileURL: fixture.originalAsset,
            expectedFingerprint: originalFingerprint
        )

        let service = AdobeXMPRatingService()
        let result = try lease.withMetadataCapability(
            expectedFingerprint: originalFingerprint
        ) { parentDescriptor, leafName in
            try service.writeRating(
                .twoStars,
                parentFileDescriptor: parentDescriptor,
                mediaLeafName: leafName,
                displayURL: fixture.originalAsset,
                expectedFingerprint: originalFingerprint,
                context: AdobeXMPRatingMutationContext(hasLatestVerifiedReceipt: false)
            )
        }

        XCTAssertEqual(result.storage, .cameraRawSidecar)
        try fixture.replaceAssetParentWithSymlink()
        XCTAssertThrowsError(
            try lease.withMetadataCapability(
                expectedFingerprint: originalFingerprint
            ) { parentDescriptor, leafName in
                try service.writeRating(
                    .fourStars,
                    parentFileDescriptor: parentDescriptor,
                    mediaLeafName: leafName,
                    displayURL: fixture.originalAsset,
                    expectedFingerprint: originalFingerprint,
                    context: AdobeXMPRatingMutationContext(hasLatestVerifiedReceipt: false)
                )
            }
        )
        XCTAssertEqual(try service.readRating(
            mediaURL: fixture.movedOriginalAsset,
            expectedFingerprint: originalFingerprint
        ).rating, .twoStars)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.movedOriginalParent.appendingPathComponent("ASSET.xmp").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.decoyParent.appendingPathComponent("ASSET.xmp").path
            )
        )
    }

    func testMetadataLeaseStillValidatesArchiveBoundaryWhenOperationThrows() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "nef")
        defer { fixture.cleanup() }
        let rootFingerprint = try FileFingerprint.capture(at: fixture.root)
        let assetFingerprint = try FileFingerprint.capture(at: fixture.originalAsset)
        let lease = try ReviewFileAccessLease(
            rootURL: fixture.root,
            rootDevice: rootFingerprint.device,
            rootInode: rootFingerprint.inode,
            fileURL: fixture.originalAsset,
            expectedFingerprint: assetFingerprint
        )

        XCTAssertThrowsError(
            try lease.withMetadataCapability(expectedFingerprint: assetFingerprint) { _, _ -> Void in
                try fixture.replaceAssetParentWithSymlink()
                throw InjectedReviewLeaseFailure()
            }
        ) { error in
            XCTAssertEqual(
                error as? UMISCoreError,
                .identityChanged,
                "post-operation archive boundary failure must take priority over the injected error"
            )
        }
    }

    func testFinderLeaseStillValidatesArchiveBoundaryWhenOperationThrows() throws {
        let fixture = try ReviewLeaseFixture(fileExtension: "jpg")
        defer { fixture.cleanup() }
        let rootFingerprint = try FileFingerprint.capture(at: fixture.root)
        let assetFingerprint = try FileFingerprint.capture(at: fixture.originalAsset)
        let lease = try ReviewFileAccessLease(
            rootURL: fixture.root,
            rootDevice: rootFingerprint.device,
            rootInode: rootFingerprint.inode,
            fileURL: fixture.originalAsset,
            expectedFingerprint: assetFingerprint
        )

        XCTAssertThrowsError(
            try lease.withExpectedFileDescriptor(expectedFingerprint: assetFingerprint) { _ -> Void in
                try fixture.replaceAssetParentWithSymlink()
                throw InjectedReviewLeaseFailure()
            }
        ) { error in
            XCTAssertEqual(
                error as? UMISCoreError,
                .identityChanged,
                "post-operation archive boundary failure must take priority over the injected error"
            )
        }
    }
}

private struct InjectedReviewLeaseFailure: Error {}

@MainActor
private final class FourItemCollectionDataSource: NSObject, NSCollectionViewDataSource {
    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        4
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}

private final class ReviewLeaseFixture {
    let temporaryRoot: URL
    let root: URL
    let originalParent: URL
    let movedOriginalParent: URL
    let decoyParent: URL
    let originalAsset: URL
    let movedOriginalAsset: URL
    let decoyAsset: URL

    init(fileExtension: String) throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umis-review-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        root = temporaryRoot.appendingPathComponent("archive", isDirectory: true)
        originalParent = root.appendingPathComponent("nested", isDirectory: true)
        movedOriginalParent = temporaryRoot.appendingPathComponent("moved-original", isDirectory: true)
        decoyParent = temporaryRoot.appendingPathComponent("decoy", isDirectory: true)
        originalAsset = originalParent.appendingPathComponent("ASSET.\(fileExtension)")
        movedOriginalAsset = movedOriginalParent.appendingPathComponent("ASSET.\(fileExtension)")
        decoyAsset = decoyParent.appendingPathComponent("ASSET.\(fileExtension)")

        try FileManager.default.createDirectory(
            at: originalParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: decoyParent,
            withIntermediateDirectories: true
        )
        try Data([0x55, 0x4D, 0x49, 0x53]).write(to: originalAsset, options: .withoutOverwriting)
        try Data([0x44, 0x45, 0x43, 0x4F, 0x59]).write(to: decoyAsset, options: .withoutOverwriting)
    }

    func replaceAssetParentWithSymlink() throws {
        try FileManager.default.moveItem(at: originalParent, to: movedOriginalParent)
        try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: decoyParent)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}
