import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore
@testable import UMISMedia

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

    func testCoordinatorCancelledMetadataCannotBecomeSuccessfulMTimeFallback() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "CANCELLED.JPG", bytes: [31, 32, 33])
        let basic = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )
        let pipeline = try MediaPipeline(
            configuration: MediaPipelineConfiguration(
                cacheDirectory: fixture.root.appendingPathComponent("cache", isDirectory: true),
                memoryBudgetBytes: 1_024 * 1_024,
                diskHardLimitBytes: 4 * 1_024 * 1_024,
                maximumConcurrentMetadata: 1
            ),
            generator: AlwaysCancelledMetadataGenerator()
        )

        do {
            _ = try await AppModel.enrichingCaptureDates(
                in: basic,
                mediaPipeline: pipeline,
                assumedTimeZone: .gmt
            )
            XCTFail("coordinator cancellation must abort enrichment instead of freezing mtime")
        } catch is CancellationError {
            // Expected: planning may now perform a fresh extraction under its own boundary.
        }
        XCTAssertNil(basic.assets.first?.capturedAt)
        XCTAssertFalse(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: nil,
            completedTimeZoneIdentifier: nil,
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: TimeZone.gmt.identifier,
            currentScan: basic,
            proposedScan: basic
        ))

        let freshlyExtracted = try await AppModel.enrichingCaptureDates(
            in: basic,
            mediaPipeline: nil,
            assumedTimeZone: .gmt
        )
        XCTAssertEqual(freshlyExtracted.assets.first?.capturedAt, basic.assets.first?.modifiedAt)
        XCTAssertTrue(AppModel.permitsCaptureDatePlanFreeze(
            completedGeneration: fixture.generation,
            completedTimeZoneIdentifier: TimeZone.gmt.identifier,
            currentGeneration: fixture.generation,
            expectedTimeZoneIdentifier: TimeZone.gmt.identifier,
            currentScan: freshlyExtracted,
            proposedScan: freshlyExtracted
        ))
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

    func testCardDisappearanceMatchesActiveOrInFlightInsertionButNotMissingOrReplacedInsertion() throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        let arrivalGeneration = UUID()
        let expected = fixture.strongIdentity(arrivalGeneration: arrivalGeneration)

        XCTAssertTrue(AppModel.cardDisappearanceMatches(
            sourceID: expected.id,
            arrivalGeneration: arrivalGeneration,
            active: expected,
            inFlight: nil
        ))
        XCTAssertTrue(AppModel.cardDisappearanceMatches(
            sourceID: expected.id,
            arrivalGeneration: arrivalGeneration,
            active: nil,
            inFlight: expected
        ), "An in-flight scan must remain correlated with a physical removal before publication")
        XCTAssertFalse(AppModel.cardDisappearanceMatches(
            sourceID: expected.id,
            arrivalGeneration: arrivalGeneration,
            active: nil,
            inFlight: nil
        ))
        XCTAssertFalse(AppModel.cardDisappearanceMatches(
            sourceID: expected.id,
            arrivalGeneration: UUID(),
            active: nil,
            inFlight: expected
        ), "Reusing the source ID at the same mount must not substitute for the removed insertion")
        XCTAssertFalse(AppModel.cardDisappearanceMatches(
            sourceID: SourceVolumeID(),
            arrivalGeneration: arrivalGeneration,
            active: nil,
            inFlight: expected
        ))
    }

    func testStrongRootScanPublicationRequiresExactCurrentInsertionAndGeneration() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write(name: "ROOT.JPG", bytes: [41, 42, 43])
        let scan = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )
        let expected = fixture.strongIdentity()
        let scope = AppSourceScanScope.normalizedRoot(fixture.root)

        func permits(
            inFlight: VolumeIdentity?,
            current: VolumeIdentity?,
            inFlightGeneration: UUID? = fixture.generation,
            currentGeneration: UUID = fixture.generation
        ) -> Bool {
            AppModel.permitsStrongScanPublication(
                expected: expected,
                inFlight: inFlight,
                current: current,
                scan: scan,
                scope: scope,
                expectedScanGeneration: fixture.generation,
                inFlightScanGeneration: inFlightGeneration,
                currentScanGeneration: currentGeneration
            )
        }

        XCTAssertTrue(permits(inFlight: expected, current: expected))
        XCTAssertTrue(AppModel.ownsInFlightStrongScan(
            expected: expected,
            expectedScanGeneration: fixture.generation,
            inFlight: expected,
            inFlightScanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation
        ))
        XCTAssertFalse(permits(inFlight: expected, current: nil),
                       "A removal observed synchronously before its callback must block publication")
        XCTAssertFalse(permits(inFlight: nil, current: expected),
                       "A scan without its in-flight insertion lease must fail closed")

        var differentSource = expected
        differentSource.id = SourceVolumeID()
        XCTAssertFalse(permits(inFlight: expected, current: differentSource))
        XCTAssertFalse(permits(inFlight: differentSource, current: expected))

        var differentArrival = expected
        differentArrival.arrivalGeneration = UUID()
        XCTAssertFalse(permits(inFlight: expected, current: differentArrival),
                       "The same mount and source ID from a different arrival is not the same insertion")
        XCTAssertFalse(permits(inFlight: differentArrival, current: expected))

        var differentSecurityDigest = expected
        differentSecurityDigest.capacityBytes += 1
        XCTAssertEqual(differentSecurityDigest.id, expected.id)
        XCTAssertEqual(differentSecurityDigest.arrivalGeneration, expected.arrivalGeneration)
        XCTAssertNotEqual(differentSecurityDigest.securityDigest, expected.securityDigest)
        XCTAssertFalse(permits(inFlight: expected, current: differentSecurityDigest))
        XCTAssertFalse(permits(inFlight: differentSecurityDigest, current: expected))

        XCTAssertFalse(permits(
            inFlight: expected,
            current: expected,
            inFlightGeneration: UUID()
        ))
        XCTAssertFalse(permits(
            inFlight: expected,
            current: expected,
            currentGeneration: UUID()
        ), "A scan replaced while identity revalidation awaits must not publish")
        XCTAssertFalse(AppModel.ownsInFlightStrongScan(
            expected: expected,
            expectedScanGeneration: fixture.generation,
            inFlight: differentSource,
            inFlightScanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation
        ), "An obsolete validator must not isolate or cancel its replacement scan")
        XCTAssertFalse(AppModel.ownsInFlightStrongScan(
            expected: expected,
            expectedScanGeneration: fixture.generation,
            inFlight: expected,
            inFlightScanGeneration: fixture.generation,
            currentScanGeneration: UUID()
        ))

        let failureStateGeneration = UUID()
        let replacementIsolationGeneration = UUID()
        XCTAssertTrue(AppModel.ownsStrongScanIsolationFailureState(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: failureStateGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: true
        ))
        XCTAssertFalse(AppModel.ownsStrongScanIsolationFailureState(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: UUID(),
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: true
        ), "A failed old task must not replace a newer scan's phase or status")
        XCTAssertTrue(AppModel.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: failureStateGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: true,
            isolationSucceeded: true
        ))
        XCTAssertFalse(AppModel.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: UUID(),
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: true,
            isolationSucceeded: true
        ), "A newer scan must retain ownership of phase and status after the old isolation awaits")
        XCTAssertFalse(AppModel.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: failureStateGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: UUID(),
            mediaAccessQuiescenceLatched: true,
            isolationSucceeded: true
        ))
        XCTAssertFalse(AppModel.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: failureStateGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: false,
            isolationSucceeded: true
        ))
        XCTAssertFalse(AppModel.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: failureStateGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: replacementIsolationGeneration,
            mediaAccessQuiescenceLatched: true,
            isolationSucceeded: false
        ))

        let replacementScanGeneration = UUID()
        XCTAssertTrue(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ))
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: fixture.generation,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ))
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: true,
            reviewMetadataIsWriting: false
        ), "A stale scan must not resume across a cache-clear suspension owner")
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: true,
            hasMediaReadIsolationTask: true,
            mediaAccessQuiescenceLatched: true,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ), "A stale scan must not resume across a newer card isolation")
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: true
        ))
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: true,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ))
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: true,
            destructiveOutcomeQuarantined: false,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ))
        XCTAssertFalse(AppModel.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: fixture.generation,
            currentScanGeneration: replacementScanGeneration,
            hasMediaReadIsolationGeneration: false,
            hasMediaReadIsolationTask: false,
            mediaAccessQuiescenceLatched: false,
            destructiveOutcomeQuarantined: true,
            mediaCacheOperationInFlight: false,
            reviewMetadataIsWriting: false
        ))
    }

    func testStrongRootScanPublicationRejectsScopeRootAndSourceIDMismatch() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try fixture.write(name: "ROOT.MOV", bytes: [51, 52, 53])
        let scan = try await MediaScanner().scan(
            root: fixture.root,
            sourceVolumeID: fixture.sourceVolumeID
        )
        let expected = fixture.strongIdentity()

        func permits(scan proposedScan: ScanResult, scope: AppSourceScanScope) -> Bool {
            AppModel.permitsStrongScanPublication(
                expected: expected,
                inFlight: expected,
                current: expected,
                scan: proposedScan,
                scope: scope,
                expectedScanGeneration: fixture.generation,
                inFlightScanGeneration: fixture.generation,
                currentScanGeneration: fixture.generation
            )
        }

        XCTAssertFalse(permits(
            scan: scan,
            scope: AppSourceScanScope.normalizedRoot(nested)
        ))

        var mismatchedRoot = scan
        mismatchedRoot.root = nested
        XCTAssertFalse(permits(
            scan: mismatchedRoot,
            scope: AppSourceScanScope.normalizedRoot(fixture.root)
        ))

        var mismatchedSource = scan
        mismatchedSource.sourceVolumeID = SourceVolumeID()
        XCTAssertFalse(permits(
            scan: mismatchedSource,
            scope: AppSourceScanScope.normalizedRoot(fixture.root)
        ))
    }

    func testStrongItemScanPublicationAcceptsOnlyItemsContainedByExactInsertion() async throws {
        let fixture = try ProgressiveScanFixture()
        defer { fixture.cleanup() }
        let first = try fixture.write(name: "ITEM-A.JPG", bytes: [61, 62])
        let second = try fixture.write(name: "ITEM-B.MOV", bytes: [63, 64, 65])
        let selectedItems = [first, second]
        let scan = try await MediaScanner().scan(
            items: selectedItems,
            sourceVolumeID: fixture.sourceVolumeID
        )
        let expected = fixture.strongIdentity()

        func permits(scope: AppSourceScanScope) -> Bool {
            AppModel.permitsStrongScanPublication(
                expected: expected,
                inFlight: expected,
                current: expected,
                scan: scan,
                scope: scope,
                expectedScanGeneration: fixture.generation,
                inFlightScanGeneration: fixture.generation,
                currentScanGeneration: fixture.generation
            )
        }

        XCTAssertTrue(permits(scope: AppSourceScanScope.normalizedItems(selectedItems)))

        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).JPG", isDirectory: false)
        XCTAssertFalse(permits(
            scope: AppSourceScanScope.normalizedItems([first, outside])
        ), "Every drag-and-drop item must remain beneath the exact physical mount")
        XCTAssertFalse(permits(scope: AppSourceScanScope.normalizedItems([])))
    }
}

private actor AlwaysCancelledMetadataGenerator: MediaGenerating {
    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        .failure(.init(.cancelled))
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        .failure(.init(.cancelled))
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

    func strongIdentity(arrivalGeneration: UUID = UUID()) -> VolumeIdentity {
        VolumeIdentity(
            id: sourceVolumeID,
            volumeUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            mediaUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            mediaRegistryEntryID: 987_654,
            parentChainDigest: "progressive-scan-parent-chain",
            bsdName: "disk99s1",
            wholeDiskBSDName: "disk99",
            mountURL: root,
            displayName: "Fixture Card",
            capacityBytes: 1_000_000,
            volumeDeviceIdentifier: 9_999_999,
            blockSize: 512,
            fileSystem: "ExFAT",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isWritable: true,
            isNetwork: false,
            isDiskImage: false,
            arrivalGeneration: arrivalGeneration,
            identityStrength: .strongForCurrentInsertion
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
