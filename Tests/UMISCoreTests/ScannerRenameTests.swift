import Foundation
import XCTest
@testable import UMISCore

final class ScannerRenameTests: XCTestCase {
    func testRescanReusesStableAssetIDAndContentIdentityChangeGetsNewID() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let file = try fixture.writeSource(data: Data("first".utf8))
        let sourceID = SourceVolumeID()
        let scanner = MediaScanner()
        let first = try await scanner.scan(root: fixture.source, sourceVolumeID: sourceID)
        let second = try await scanner.scan(root: fixture.source, sourceVolumeID: sourceID)
        XCTAssertEqual(first.assets.first?.id, second.assets.first?.id)

        try Data("changed and longer".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        let changed = try await scanner.scan(root: fixture.source, sourceVolumeID: sourceID)
        XCTAssertNotEqual(first.assets.first?.id, changed.assets.first?.id)
    }

    func testExplicitExclusionRemovesDeliveryAndInvalidIDsAreRejected() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A.MOV", data: Data("a".utf8))
        _ = try fixture.writeSource(name: "B.MOV", data: Data("b".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let excluded = try XCTUnwrapValue(scan.assets.first?.id)
        let destination = DestinationID()
        let required = try scan.validatedRequiredSet(
            destinationID: destination,
            explicitlyExcludedAssetIDs: [excluded]
        )
        XCTAssertFalse(required.assetIDs.contains(excluded))
        XCTAssertFalse(required.deliveries.contains(where: { $0.assetID == excluded }))
        XCTAssertFalse(required.isStructurallyEligibleForErase)
        XCTAssertFalse(required.hasAuditedExplicitExclusions)

        let evidence = try scan.makeExplicitExclusionEvidence(
            assetID: excluded,
            reason: "Operator confirmed this clip is an accidental camera test",
            operatorIdentifier: "operator-001",
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let audited = try scan.validatedRequiredSet(
            destinationID: destination,
            explicitlyExcludedAssetIDs: [excluded],
            explicitExclusions: [evidence]
        )
        XCTAssertTrue(audited.isStructurallyEligibleForErase)
        XCTAssertTrue(audited.hasAuditedExplicitExclusions)
        do {
            _ = try scan.validatedRequiredSet(
                destinationID: destination,
                explicitlyExcludedAssetIDs: [MediaAssetID()]
            )
            XCTFail("Expected invalid exclusion")
        } catch { }
    }

    func testDragAndDropOverlappingInputsDeduplicatesAndRejectsSymlinkTarget() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let file = try fixture.writeSource(data: Data("movie".utf8))
        let link = fixture.root.appendingPathComponent("external-link.MOV")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let result = try await MediaScanner().scan(items: [fixture.source, file, link])
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertTrue(result.inventory.contains(where: { $0.type == .symbolicLink && $0.classification == .unknown }))
    }

    func testProjectMediaPolicyKeepsDisabledHiddenAndExcludedFolderMediaVisibleUntilReviewed() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "B.JPG", data: Data("photo".utf8))
        _ = try fixture.writeSource(name: ".HIDDEN.JPG", data: Data("hidden".utf8))
        _ = try fixture.writeSource(name: "CACHE/C.JPG", data: Data("cache".utf8))
        let movieCategory = ProjectCategory(
            displayName: "Movie",
            folderName: "Movies",
            extensions: ["mov"],
            mediaKind: .movie,
            isEnabled: false
        )
        let photoCategory = ProjectCategory(
            displayName: "Photo",
            folderName: "Photos",
            extensions: ["jpg"],
            mediaKind: .photo
        )
        let policy = MediaScanPolicy(
            categoryRules: [movieCategory, photoCategory],
            excludedFolderNames: ["cache"]
        )
        let scan = try await MediaScanner().scan(root: fixture.source, policy: policy)
        XCTAssertEqual(scan.assets.count, 4)
        XCTAssertEqual(scan.assets.first(where: { $0.originalName == "A.MOV" })?.categoryID, movieCategory.id)
        XCTAssertEqual(scan.assets.first(where: { $0.originalName == "B.JPG" })?.categoryID, photoCategory.id)
        XCTAssertTrue(scan.inventory.contains(where: {
            $0.relativePath == "A.MOV" && $0.classification == .disabledByPolicyNeedsReview
        }))
        XCTAssertTrue(scan.inventory.contains(where: {
            $0.relativePath == ".HIDDEN.JPG" && $0.classification == .hiddenEntryNeedsReview
        }))
        XCTAssertTrue(scan.inventory.contains(where: {
            $0.relativePath == "CACHE/C.JPG" && $0.classification == .excludedFolderNeedsReview
        }), "\(scan.inventory.map { ($0.relativePath, $0.classification.rawValue) })")

        let destinationID = DestinationID()
        let automatic = try scan.validatedRequiredSet(destinationID: destinationID)
        XCTAssertFalse(automatic.isStructurallyEligibleForErase)
        XCTAssertEqual(automatic.assetIDs.count, 1)
        XCTAssertEqual(automatic.unknownEntryCount, 3)

        let enabled = try XCTUnwrapValue(scan.assets.first(where: { $0.originalName == "B.JPG" })?.id)
        let reviewedExclusions = Set(scan.assets.map(\.id)).subtracting([enabled])
        let exclusionEvidence = try reviewedExclusions.map {
            try scan.makeExplicitExclusionEvidence(
                assetID: $0,
                reason: "Project policy item reviewed and intentionally excluded",
                operatorIdentifier: "operator-001",
                confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let reviewed = try scan.validatedRequiredSet(
            selectedAssetIDs: [enabled],
            destinationID: destinationID,
            explicitlyExcludedAssetIDs: reviewedExclusions,
            explicitExclusions: exclusionEvidence
        )
        XCTAssertTrue(reviewed.isStructurallyEligibleForErase)
        XCTAssertEqual(reviewed.assetIDs, [enabled])
        XCTAssertEqual(reviewed.explicitlyExcludedAssetIDs, reviewedExclusions)

        do {
            _ = try scan.validatedRequiredSet(
                selectedAssetIDs: [enabled],
                destinationID: destinationID,
                explicitlyExcludedAssetIDs: [enabled]
            )
            XCTFail("Selection and explicit exclusion must be disjoint")
        } catch { }
    }

    func testMediaPolicyLeavesUnknownExtensionInInventoryAndRejectsDuplicateRules() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "README.BIN", data: Data("unknown".utf8))
        let categoryA = ProjectCategory(displayName: "A", folderName: "A", extensions: ["bin"])
        let categoryB = ProjectCategory(displayName: "B", folderName: "B", extensions: [".BIN"])
        do {
            _ = try await MediaScanner().scan(
                root: fixture.source,
                policy: MediaScanPolicy(categoryRules: [categoryA, categoryB])
            )
            XCTFail("Duplicate extension ownership must fail")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let scan = try await MediaScanner().scan(
            root: fixture.source,
            policy: MediaScanPolicy(categoryRules: [])
        )
        XCTAssertTrue(scan.assets.isEmpty)
        XCTAssertTrue(scan.inventory.contains(where: {
            $0.relativePath == "README.BIN" && $0.classification == .unknown
        }))
    }

    func testSystemMetadataAllowlistIsExactRootRegularFileAndSizeBounded() async throws {
        XCTAssertTrue(MediaScanner.matchesSystemMetadataAllowlist(
            relativePath: ".DS_Store",
            entryType: .regularFile,
            byteSize: 32_768,
            isMountedVolumeRoot: true
        ))
        XCTAssertFalse(MediaScanner.matchesSystemMetadataAllowlist(
            relativePath: "DCIM/.DS_Store",
            entryType: .regularFile,
            byteSize: 32_768,
            isMountedVolumeRoot: true
        ))
        XCTAssertFalse(MediaScanner.matchesSystemMetadataAllowlist(
            relativePath: ".DS_Store",
            entryType: .regularFile,
            byteSize: 1_048_577,
            isMountedVolumeRoot: true
        ))
        XCTAssertFalse(MediaScanner.matchesSystemMetadataAllowlist(
            relativePath: ".DS_Store",
            entryType: .symbolicLink,
            byteSize: 10,
            isMountedVolumeRoot: true
        ))
        XCTAssertFalse(MediaScanner.matchesSystemMetadataAllowlist(
            relativePath: ".DS_Store",
            entryType: .regularFile,
            byteSize: 10,
            isMountedVolumeRoot: false
        ))

        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        try Data("user file".utf8).write(to: fixture.source.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent("DCIM"),
            withIntermediateDirectories: true
        )
        try Data("nested user file".utf8).write(
            to: fixture.source.appendingPathComponent("DCIM/.DS_Store")
        )
        let scan = try await MediaScanner().scan(root: fixture.source)
        let storeEntries = scan.inventory.filter { $0.relativePath.hasSuffix(".DS_Store") }
        XCTAssertEqual(storeEntries.count, 2)
        XCTAssertTrue(storeEntries.allSatisfy { $0.classification == .unknown })
    }

    func testEmptyDirectoryCannotBeSilentlyLostBeforeErase() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "DCIM/A.MOV", data: Data("movie".utf8))
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent("USER_EMPTY"),
            withIntermediateDirectories: true
        )
        let scan = try await MediaScanner().scan(root: fixture.source)
        XCTAssertEqual(scan.emptyUserDirectoryPathsRequiringReview, ["USER_EMPTY"])
        let destinationID = DestinationID()
        let unresolved = try scan.validatedRequiredSet(destinationID: destinationID)
        XCTAssertEqual(unresolved.unresolvedDirectoryEntryCount, 1)
        XCTAssertFalse(unresolved.isStructurallyEligibleForErase)

        let directoryEvidence = try scan.makeEmptyDirectoryExclusionEvidence(
            relativePath: "USER_EMPTY",
            reason: "Operator confirmed that empty folder structure is not required",
            operatorIdentifier: "operator-001",
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reviewed = try scan.validatedRequiredSet(
            destinationID: destinationID,
            explicitDirectoryExclusions: [directoryEvidence]
        )
        XCTAssertEqual(reviewed.unresolvedDirectoryEntryCount, 0)
        XCTAssertTrue(reviewed.isStructurallyEligibleForErase)
        XCTAssertTrue(reviewed.hasAuditedDirectoryExclusions)
    }

    func testPortablePathPolicyRejectsWindowsAndSMBHazardsButAllowsJapanese() throws {
        XCTAssertEqual(try PathSafety.validateComponent("動画_シーン01"), "動画_シーン01")
        for invalid in [
            "CON", "con.mov", "PRN.JPG", "AUX", "NUL", "COM1.MOV", "LPT9.XML",
            "bad:name", ".hidden", "trailing.", "trailing ", "bad?name", "bad\\name",
        ] {
            XCTAssertThrowsError(try PathSafety.validateComponent(invalid), "Expected rejection for \(invalid)")
        }
        XCTAssertEqual(
            PathSafety.portableCollisionKey("Folder/Café.MOV"),
            PathSafety.portableCollisionKey("folder/Café.mov")
        )
        XCTAssertEqual(
            PathSafety.portableCollisionKey("ＡＢＣ.MOV"),
            PathSafety.portableCollisionKey("abc.mov")
        )
    }

    func testCopyAndRenamePreviewEqualsExecutionAndLeavesOriginalUntouched() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let original = try fixture.writeSource(name: "A001.MOV", data: Data("movie payload".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let asset = try XCTUnwrapValue(scan.assets.first)
        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: [RenameRequest(asset: asset, context: RenameContext(sceneCode: "SC01"))],
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
        XCTAssertEqual(plan.items.first?.afterRelativePath, "SC01_0001.MOV")
        let store = try OperationStore(databaseURL: fixture.database)
        let receipt = try await CopyAndRenameEngine(store: store).execute(plan: plan)
        XCTAssertEqual(receipt.planDigest, plan.planDigest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("SC01_0001.MOV")),
            Data("movie payload".utf8)
        )
    }

    func testRenamePlannerAssignsIndependentSequencesToEqualStemPrimariesWithoutSidecar() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "SOLO.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "SOLO.WAV", data: Data("audio".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let requests = scan.assets.map {
            RenameRequest(asset: $0, context: RenameContext(sceneCode: "SC01"))
        }

        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: requests,
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
        XCTAssertEqual(Set(plan.items.map(\.sequenceNumber)), [1, 2])
        XCTAssertEqual(
            Set(plan.items.map(\.afterRelativePath)),
            ["SC01_0001.MOV", "SC01_0002.WAV"]
        )

        let store = try OperationStore(databaseURL: fixture.database)
        let receipt = try await CopyAndRenameEngine(store: store).execute(plan: plan)
        XCTAssertEqual(receipt.ingestReceipt.deliveries.count, 2)
    }

    func testRenamePlannerSharesPrimarySequenceStemAndContextWithSidecar() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "CAM001.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "CAM001.XMP", data: Data("metadata".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let requests = scan.assets.map { asset in
            RenameRequest(
                asset: asset,
                context: RenameContext(
                    sceneCode: asset.kind == .sidecar ? "SIDECAR" : "PRIMARY"
                )
            )
        }

        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: requests,
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
        XCTAssertEqual(Set(plan.items.map(\.sequenceNumber)), [1])
        XCTAssertEqual(
            Set(plan.items.map(\.afterRelativePath)),
            ["PRIMARY_0001.MOV", "PRIMARY_0001.XMP"]
        )
        XCTAssertEqual(Set(plan.items.map(\.companionGroupKey)).count, 1)

        let store = try OperationStore(databaseURL: fixture.database)
        let receipt = try await CopyAndRenameEngine(store: store).execute(plan: plan)
        XCTAssertEqual(receipt.ingestReceipt.deliveries.count, 2)
    }

    func testRenameSequenceOrderUsesPrimaryCaptureDateNotOlderSidecarModificationDate() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "LATER.MOV", data: Data("later movie".utf8))
        _ = try fixture.writeSource(name: "LATER.XMP", data: Data("old metadata".utf8))
        _ = try fixture.writeSource(name: "EARLIER.MOV", data: Data("earlier movie".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        var requests = scan.assets.map { asset -> RenameRequest in
            var asset = asset
            switch asset.originalName {
            case "EARLIER.MOV":
                asset.capturedAt = Date(timeIntervalSince1970: 1_000)
                asset.modifiedAt = Date(timeIntervalSince1970: 1_000)
            case "LATER.MOV":
                asset.capturedAt = Date(timeIntervalSince1970: 2_000)
                asset.modifiedAt = Date(timeIntervalSince1970: 2_000)
            case "LATER.XMP":
                asset.capturedAt = nil
                asset.modifiedAt = Date(timeIntervalSince1970: 1)
            default:
                break
            }
            return RenameRequest(asset: asset)
        }
        // Input order must not become an implicit group-order tie breaker either.
        requests.reverse()

        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: requests,
            rule: RenameRule(tokens: [.sequence])
        )
        let earlier = try XCTUnwrapValue(
            plan.items.first { $0.beforeRelativePath == "EARLIER.MOV" }
        )
        let laterPrimary = try XCTUnwrapValue(
            plan.items.first { $0.beforeRelativePath == "LATER.MOV" }
        )
        let laterSidecar = try XCTUnwrapValue(
            plan.items.first { $0.beforeRelativePath == "LATER.XMP" }
        )
        XCTAssertEqual(earlier.sequenceNumber, 1)
        XCTAssertEqual(laterPrimary.sequenceNumber, 2)
        XCTAssertEqual(laterSidecar.sequenceNumber, 2)
        XCTAssertEqual(plan.items.map(\.beforeRelativePath), [
            "EARLIER.MOV",
            "LATER.MOV",
            "LATER.XMP",
        ])
    }

    func testRenamePlannerRejectsSidecarOnlyAndAmbiguousMultiPrimaryBeforePreview() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "CAM002.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "CAM002.JPG", data: Data("photo".utf8))
        _ = try fixture.writeSource(name: "CAM002.XMP", data: Data("metadata".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let sidecar = try XCTUnwrapValue(scan.assets.first { $0.kind == .sidecar })

        do {
            _ = try await RenamePlanner().plan(
                sourceRoot: fixture.source,
                destinationRoot: fixture.destination,
                requests: [RenameRequest(asset: sidecar)],
                rule: RenameRule(tokens: [.sequence])
            )
            XCTFail("A sidecar-only selection must fail during preview planning")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }

        do {
            _ = try await RenamePlanner().plan(
                sourceRoot: fixture.source,
                destinationRoot: fixture.destination,
                requests: scan.assets.map { RenameRequest(asset: $0) },
                rule: RenameRule(tokens: [.sequence])
            )
            XCTFail("Multiple primaries plus a sidecar must fail during preview planning")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRenameCapturedDateUsesPlanFrozenLocalTimeZoneInsteadOfUTC() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "MIDNIGHT.MOV", data: Data("time-zone".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        var asset = try XCTUnwrapValue(scan.assets.first)
        asset.capturedAt = try XCTUnwrapValue(
            ISO8601DateFormatter().date(from: "2026-08-26T15:30:00Z")
        )
        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: [RenameRequest(asset: asset)],
            rule: RenameRule(
                tokens: [.capturedDate],
                timeZoneIdentifier: "Asia/Tokyo"
            )
        )
        XCTAssertEqual(plan.rule.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(plan.items.first?.afterRelativePath, "20260827.MOV")
    }

    func testCopyAndRenameRejectsCompanionAddedAfterPreview() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A001.MOV", data: Data("movie payload".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let asset = try XCTUnwrapValue(scan.assets.first)
        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: [RenameRequest(asset: asset, context: RenameContext(sceneCode: "SC01"))],
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
        _ = try fixture.writeSource(name: "A001.XMP", data: Data("late companion".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await CopyAndRenameEngine(store: store).execute(plan: plan)
            XCTFail("A companion added after preview must invalidate the transaction")
        } catch let error as UMISCoreError {
            guard case .sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].ingestItem.finalURL.path))
    }

    func testRenamePlannerBlocksUnicodeNormalizationCollision() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A.MOV", data: Data("a".utf8))
        _ = try fixture.writeSource(name: "B.MOV", data: Data("b".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let requests = [
            RenameRequest(asset: scan.assets[0], context: RenameContext(sceneName: "Caf\u{00E9}")),
            RenameRequest(asset: scan.assets[1], context: RenameContext(sceneName: "Cafe\u{0301}")),
        ]
        do {
            _ = try await RenamePlanner().plan(
                sourceRoot: fixture.source,
                destinationRoot: fixture.destination,
                requests: requests,
                rule: RenameRule(tokens: [.sceneName])
            )
            XCTFail("Expected normalized collision")
        } catch let error as UMISCoreError {
            guard case .collision = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCopyAndRenameRollsBackEarlierGroupMemberWhenLaterMemberCollides() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A001.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "A001.XML", data: Data("sidecar".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let requests = scan.assets.map { RenameRequest(asset: $0, context: RenameContext(sceneCode: "SC01")) }
        let plan = try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: requests,
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
        let xml = try XCTUnwrapValue(plan.items.first(where: { $0.afterRelativePath.hasSuffix(".XML") }))
        try Data("external collision".utf8).write(to: xml.ingestItem.finalURL)
        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await CopyAndRenameEngine(store: store).execute(plan: plan)
            XCTFail("Expected collision")
        } catch { }
        let mov = try XCTUnwrapValue(plan.items.first(where: { $0.afterRelativePath.hasSuffix(".MOV") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mov.ingestItem.finalURL.path))
        XCTAssertEqual(try Data(contentsOf: xml.ingestItem.finalURL), Data("external collision".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("A001.MOV").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("A001.XML").path))
    }

    func testCopyAndRenameRollsBackAtEveryAtomicCommitBoundary() async throws {
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterCommitIntentBeforeRename: { _ in throw TestSupportError.missingValue("intent fault") }
        ))
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterAtomicRenameBeforeJournalUpdate: { _ in throw TestSupportError.missingValue("rename fault") }
        ))
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterAtomicJournalBeforeDirectorySync: { _ in throw TestSupportError.missingValue("journal fault") }
        ))
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterDirectorySyncBeforeReceipt: { _ in throw TestSupportError.missingValue("fsync fault") }
        ))
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterReceiptPreparedBeforeJournalUpdate: { _ in
                throw TestSupportError.missingValue("receipt journal fault")
            }
        ))
        try await assertAtomicBoundaryRollback(CopyTestingHooks(
            afterDurableReceiptJournalBeforeAudit: { _ in
                throw TestSupportError.missingValue("receipt audit fault")
            }
        ))
    }

    func testCopyAndRenameRequiresRecoveryWhenCommitCannotBeProven() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let plan = try await makeRenameFaultPlan(fixture: fixture)
        let store = try OperationStore(databaseURL: fixture.database)
        let engine = CopyAndRenameEngine(
            store: store,
            chunkSize: 4_096,
            testingHooks: CopyTestingHooks(afterAtomicRenameBeforeJournalUpdate: { finalURL in
                try Data("externally changed after atomic rename".utf8).write(to: finalURL)
                throw TestSupportError.missingValue("post-rename corruption")
            })
        )
        do {
            _ = try await engine.execute(plan: plan)
            XCTFail("Unprovable rollback must fail")
        } catch let error as UMISCoreError {
            guard case .backendFailure = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let operation = try await store.operation(id: plan.transactionID.rawValue)
        XCTAssertEqual(operation?.status, .recoveryRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.items[0].ingestItem.finalURL.path))
    }

    private func assertAtomicBoundaryRollback(_ hooks: CopyTestingHooks) async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let plan = try await makeRenameFaultPlan(fixture: fixture)
        let store = try OperationStore(databaseURL: fixture.database)
        let engine = CopyAndRenameEngine(store: store, chunkSize: 4_096, testingHooks: hooks)
        do {
            _ = try await engine.execute(plan: plan)
            XCTFail("Expected injected boundary fault")
        } catch { }
        let operation = try await store.operation(id: plan.transactionID.rawValue)
        XCTAssertEqual(operation?.status, .rolledBack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].ingestItem.finalURL.path))
        let partial = fixture.destination
            .appendingPathComponent(".umis-partial")
            .appendingPathComponent(plan.transactionID.rawValue.uuidString)
            .appendingPathComponent(plan.items[0].ingestItem.id.rawValue.uuidString + ".partial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    private func makeRenameFaultPlan(fixture: CoreFixture) async throws -> RenamePlan {
        _ = try fixture.writeSource(name: "FAULT.MOV", data: Data("atomic boundary payload".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let asset = try XCTUnwrapValue(scan.assets.first)
        return try await RenamePlanner().plan(
            sourceRoot: fixture.source,
            destinationRoot: fixture.destination,
            requests: [RenameRequest(asset: asset, context: RenameContext(sceneCode: "SC01"))],
            rule: RenameRule(tokens: [.sceneCode, .sequence])
        )
    }
}
