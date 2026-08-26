import Foundation
import XCTest
@testable import UMISCore

final class EraseSafetyTests: XCTestCase {
    func testPhysicalMediaEligibilityRejectsUnknownGenericUSBAndSSD() throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        var identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        XCTAssertTrue(identity.isCameraCardEraseEligible)

        identity.mediaUUID = nil
        XCTAssertFalse(
            identity.isCameraCardEraseEligible,
            "Erase must remain disabled when durable physical quarantine cannot survive remount"
        )
        identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)

        identity.physicalMediaEvidence = .unknown
        XCTAssertFalse(identity.isCameraCardEraseEligible)
        identity.physicalMediaEvidence = PhysicalMediaEvidence(
            classification: .genericUSBStorage,
            provenance: .diskArbitrationAndIOKit,
            transportProtocol: "USB",
            mediaType: "SD Card",
            registryClassChain: ["IOUSBMassStorageInterfaceNub", "IOMedia"]
        )
        XCTAssertFalse(identity.isCameraCardEraseEligible)
        identity.physicalMediaEvidence = PhysicalMediaEvidence(
            classification: .solidStateDrive,
            provenance: .diskArbitrationAndIOKit,
            transportProtocol: "USB",
            mediaType: "SSD",
            registryClassChain: ["IOBlockStorageDevice", "IOMedia"]
        )
        XCTAssertFalse(identity.isCameraCardEraseEligible)
        identity.physicalMediaEvidence = PhysicalMediaEvidence(
            classification: .secureDigitalCard,
            provenance: .diskArbitrationAndIOKit,
            transportProtocol: "USB",
            mediaType: "SDXC",
            registryClassChain: ["IOUSBMassStorageInterfaceNub", "IOMedia"]
        )
        XCTAssertFalse(identity.isCameraCardEraseEligible, "A generic USB reader requires a future signed allowlist")
    }

    func testActivityLeaseAlwaysReleasesOnSuccessAndFailure() async throws {
        let registry = VolumeIOActivityRegistry()
        let sourceID = SourceVolumeID()
        let activeInside = try await registry.withActivity(sourceVolumeID: sourceID) {
            await registry.isActive(sourceVolumeID: sourceID)
        }
        XCTAssertTrue(activeInside)
        let activeAfterSuccess = await registry.isActive(sourceVolumeID: sourceID)
        XCTAssertFalse(activeAfterSuccess)
        do {
            let _: Bool = try await registry.withActivity(sourceVolumeID: sourceID) {
                throw TestSupportError.missingValue("lease failure")
            }
            XCTFail("Expected injected failure")
        } catch { }
        let activeAfterFailure = await registry.isActive(sourceVolumeID: sourceID)
        XCTAssertFalse(activeAfterFailure)

        try await registry.withQuiescedVolume(sourceVolumeID: sourceID) {
            let isQuiesced = await registry.isDestructivelyQuiesced(sourceVolumeID: sourceID)
            XCTAssertTrue(isQuiesced)
            do {
                _ = try await registry.withActivity(sourceVolumeID: sourceID) { true }
                XCTFail("New source I/O must fail closed during a destructive reservation")
            } catch let error as UMISCoreError {
                guard case .eraseNotEligible = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        let quiescedAfter = await registry.isDestructivelyQuiesced(sourceVolumeID: sourceID)
        XCTAssertFalse(quiescedAfter)
    }

    func testOneShotTokenCannotBeReused() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data("critical camera original".utf8)
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data)
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let evidence = try await FinalVerificationService(store: store).verify(
            runID: plan.runID,
            currentIdentity: plan.sourceVolume
        )
        let gate = EraseGate(store: store)
        let profile = try CardFormatProfile(label: "CARD_001")
        let backend = SimulatedCardEraseBackend(identity: plan.sourceVolume)
        let token = try await gate.issue(
            evidence: evidence,
            profile: profile,
            currentIdentity: plan.sourceVolume
        )
        let result = try await gate.consume(token: token, profile: profile, backend: backend)
        XCTAssertEqual(result.outcome, .completed)
        let invocationCountAfterSuccess = await backend.invocationCount()
        XCTAssertEqual(invocationCountAfterSuccess, 1)
        do {
            _ = try await gate.consume(token: token, profile: profile, backend: backend)
            XCTFail("Expected replay rejection")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .reusedToken)
        }
        let invocationCountAfterReplay = await backend.invocationCount()
        XCTAssertEqual(invocationCountAfterReplay, 1)
    }

    func testConfirmedSerialEraseDoesNotExposeAConfirmationWindowToken() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("serial erase".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let backend = SimulatedCardEraseBackend(identity: plan.sourceVolume)
        let activity = VolumeIOActivityRegistry()
        let result = try await EraseGate(store: store, activity: activity).eraseAfterUserConfirmation(
            runID: plan.runID,
            profile: try CardFormatProfile(label: "SERIAL_01"),
            currentIdentity: plan.sourceVolume,
            backend: backend
        )
        XCTAssertEqual(result.outcome, .completed)
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 1)
        let auditTypes = try await store.auditExport(
            operationID: plan.runID.rawValue,
            limit: 1_000
        ).map(\.eventType)
        let preparedIndex = try XCTUnwrapValue(auditTypes.firstIndex(of: "erase.targetPrepared"))
        let issuedIndex = try XCTUnwrapValue(auditTypes.lastIndex(of: "erase.tokenIssued"))
        let consumedIndex = try XCTUnwrapValue(auditTypes.lastIndex(of: "erase.tokenConsumed"))
        let completedIndex = try XCTUnwrapValue(auditTypes.lastIndex(of: "erase.completed"))
        XCTAssertLessThan(preparedIndex, issuedIndex)
        XCTAssertLessThan(issuedIndex, consumedIndex)
        XCTAssertLessThan(consumedIndex, completedIndex)
        let remainsQuiesced = await activity.isDestructivelyQuiesced(sourceVolumeID: plan.sourceVolume.id)
        XCTAssertFalse(remainsQuiesced)
    }

    func testLegacyTokenConsumptionReverifiesDeletedDestinationAndFailsClosed() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("must remain copied".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let evidence = try await FinalVerificationService(store: store).verify(
            runID: plan.runID,
            currentIdentity: plan.sourceVolume
        )
        let gate = EraseGate(store: store)
        let profile = try CardFormatProfile(label: "REVERIFY")
        let token = try await gate.issue(
            evidence: evidence,
            profile: profile,
            currentIdentity: plan.sourceVolume
        )
        try FileManager.default.removeItem(at: plan.items[0].finalURL)
        let backend = SimulatedCardEraseBackend(identity: plan.sourceVolume)
        do {
            _ = try await gate.consume(token: token, profile: profile, backend: backend)
            XCTFail("Destination deletion during confirmation must revoke erase eligibility")
        } catch { }
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        do {
            _ = try await gate.consume(token: token, profile: profile, backend: backend)
            XCTFail("Failed destructive attempts still consume the nonce")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .reusedToken)
        }
    }

    func testIdentityChangeAfterGateLookupPreventsEraseAndConsumesToken() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("original".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let evidence = try await FinalVerificationService(store: store).verify(
            runID: plan.runID,
            currentIdentity: plan.sourceVolume
        )
        let gate = EraseGate(store: store)
        let profile = try CardFormatProfile(label: "CARD_002")
        let backend = SimulatedCardEraseBackend(identity: plan.sourceVolume)
        var exchanged = plan.sourceVolume
        exchanged.arrivalGeneration = UUID()
        await backend.changeIdentityAfterNextLookup(to: exchanged)
        let token = try await gate.issue(evidence: evidence, profile: profile, currentIdentity: plan.sourceVolume)
        do {
            _ = try await gate.consume(token: token, profile: profile, backend: backend)
            XCTFail("Expected identity change")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .identityChanged)
        }
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        do {
            _ = try await gate.consume(token: token, profile: profile, backend: backend)
            XCTFail("Consumed token must not revive")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .reusedToken)
        }
    }

    func testEmptyRequiredSetNeverIssuesToken() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let sourceID = SourceVolumeID()
        let identity = makeStrongVolume(id: sourceID, mountURL: fixture.source)
        let empty = RequiredSet(
            assetIDs: [],
            deliveries: [],
            inventoryDigest: "empty",
            systemMetadataAllowlistDigest: MediaScanner.systemMetadataAllowlistDigest
        )
        let evidence = FinalVerificationEvidence(
            ingestReceipt: IngestReceipt(
                runID: IngestRunID(),
                sourceIdentityDigest: identity.securityDigest,
                requiredSetDigest: try StableDigest.encode(empty),
                deliveries: []
            ),
            requiredSet: empty,
            sourceFullHashes: [:],
            destinationFullHashes: [:],
            sourceManifestDigest: "empty",
            destinationIdentityDigest: "none",
            localJournalDurablyCommitted: true,
            noSourceWorkerIsRunning: true
        )
        do {
            _ = try await EraseGate().issue(
                evidence: evidence,
                profile: try CardFormatProfile(label: "EMPTY"),
                currentIdentity: identity
            )
            XCTFail("Empty Required Set must never be vacuously eligible")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testActualDiskutilBackendUsesInjectedRunnerAndPostFormatProbe() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("must be copied first".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let evidence = try await FinalVerificationService(store: store).verify(
            runID: plan.runID,
            currentIdentity: plan.sourceVolume
        )
        let registry = VolumeIdentityRegistry()
        await registry.registerAppearance(plan.sourceVolume)
        let profile = try CardFormatProfile(label: "CARD_003")
        let runner = RecordingDiskutilRunner(
            registry: registry,
            sourceRoot: fixture.source,
            identity: plan.sourceVolume,
            label: profile.label
        )
        let claimProvider = DeterministicRetainedMediaClaimProvider(registry: registry)
        let backend = DiskutilCardEraseBackend(
            registry: registry,
            runner: runner,
            testingClaimProvider: claimProvider,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil"),
            postFormatTimeout: 2
        )
        let gate = EraseGate(store: store)
        let token = try await gate.issue(evidence: evidence, profile: profile, currentIdentity: plan.sourceVolume)
        let result = try await gate.consume(token: token, profile: profile, backend: backend)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.postFormatProbeSucceeded)
        let arguments = await runner.recordedArguments()
        XCTAssertTrue(arguments.contains(["eraseVolume", "ExFAT", "CARD_003", "disk99s1"]))
        XCTAssertFalse(
            arguments.contains(where: { $0.first == "unmount" }),
            "Unmount belongs to the retained native claim provider, never a path/BSD helper"
        )
        let retainedClaims = await claimProvider.retainedCount()
        XCTAssertEqual(retainedClaims, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/test-only/fake-diskutil"))
    }

    func testEraseTimeoutPermanentlyQuarantinesOldSourceIdentity() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(
            fixture: fixture,
            data: Data("timeout must quarantine".utf8)
        )
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let registry = VolumeIdentityRegistry()
        await registry.registerAppearance(plan.sourceVolume)
        let activity = VolumeIOActivityRegistry()
        let profile = try CardFormatProfile(label: "UNKNOWN_01")
        let runner = RecordingDiskutilRunner(
            registry: registry,
            sourceRoot: fixture.source,
            identity: plan.sourceVolume,
            label: profile.label,
            eraseTimesOut: true
        )
        let claimProvider = DeterministicRetainedMediaClaimProvider(registry: registry)
        let backend = DiskutilCardEraseBackend(
            registry: registry,
            runner: runner,
            testingClaimProvider: claimProvider,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
        )
        let gate = EraseGate(store: store, activity: activity)
        let result = try await gate.eraseAfterUserConfirmation(
            runID: plan.runID,
            profile: profile,
            currentIdentity: plan.sourceVolume,
            backend: backend
        )
        XCTAssertEqual(result.outcome, .outcomeUnknown)
        let retainedClaims = await claimProvider.retainedCount()
        XCTAssertEqual(
            retainedClaims,
            1,
            "An indeterminate destructive helper must retain its native media claim"
        )
        let quarantined = await activity.isQuarantined(sourceVolumeID: plan.sourceVolume.id)
        XCTAssertTrue(quarantined)
        let durableRecord = try await store.destructiveQuarantine(for: plan.sourceVolume)
        XCTAssertEqual(durableRecord?.operationID, plan.runID.rawValue)
        do {
            _ = try await activity.withActivity(sourceVolumeID: plan.sourceVolume.id) { true }
            XCTFail("Unknown erase outcome must block all subsequent media I/O")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await gate.eraseAfterUserConfirmation(
                runID: plan.runID,
                profile: profile,
                currentIdentity: plan.sourceVolume,
                backend: backend
            )
            XCTFail("A quarantined physical identity must not be erased again")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }

        // Simulate both a process restart and Disk Arbitration assigning a new mount-session ID.
        // The physical media UUID remains stable, so the durable quarantine must carry forward.
        let relaunchedStore = try OperationStore(databaseURL: fixture.database)
        let relaunchedActivity = VolumeIOActivityRegistry()
        var reappearedIdentity = plan.sourceVolume
        reappearedIdentity.id = SourceVolumeID()
        reappearedIdentity.arrivalGeneration = UUID()
        reappearedIdentity.bsdName = "disk100s1"
        reappearedIdentity.wholeDiskBSDName = "disk100"
        do {
            try await relaunchedActivity.registerAppearance(
                identity: reappearedIdentity,
                durableStore: relaunchedStore
            )
            XCTFail("A new SourceVolumeID for the same physical card must remain quarantined")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let reappearedQuarantined = await relaunchedActivity.isQuarantined(
            sourceVolumeID: reappearedIdentity.id
        )
        XCTAssertTrue(reappearedQuarantined)
    }

    func testTerminatingProcessTimeoutReturnsOnlyAfterChildExitAndReap() async throws {
        let start = Date()
        let result = try await POSIXProcessRunner().run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.1,
            timeoutAction: .terminateProcessGroup
        ))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.terminationSignal, 9)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            0.8,
            "Timeout result must wait for SIGKILL exit/reap before destructive quiesce can release"
        )
    }

    func testInternalMediaIsRejectedBeforeBackendInvocation() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        var identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        identity.isInternal = true
        let empty = RequiredSet(
            assetIDs: [],
            deliveries: [],
            inventoryDigest: "x",
            systemMetadataAllowlistDigest: "x"
        )
        let evidence = FinalVerificationEvidence(
            ingestReceipt: IngestReceipt(
                runID: IngestRunID(),
                sourceIdentityDigest: identity.securityDigest,
                requiredSetDigest: "x",
                deliveries: []
            ),
            requiredSet: empty,
            sourceFullHashes: [:],
            destinationFullHashes: [:],
            sourceManifestDigest: "x",
            destinationIdentityDigest: "x",
            localJournalDurablyCommitted: true,
            noSourceWorkerIsRunning: true
        )
        do {
            _ = try await EraseGate().issue(
                evidence: evidence,
                profile: try CardFormatProfile(label: "INTERNAL"),
                currentIdentity: identity
            )
            XCTFail("Internal media must be rejected")
        } catch let error as UMISCoreError {
            guard case .unsafeEraseTarget = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSafeEjectRejectsActiveIOThenWaitsForDisappearanceCallback() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        let registry = VolumeIdentityRegistry()
        let activity = VolumeIOActivityRegistry()
        let store = try OperationStore(databaseURL: fixture.database)
        await registry.registerAppearance(identity)
        try await activity.begin(sourceVolumeID: identity.id)
        let runner = RecordingEjectRunner(
            registry: registry,
            identity: identity,
            activity: activity
        )
        let claimProvider = DeterministicRetainedMediaClaimProvider(
            registry: registry,
            activity: activity
        )
        let service = SafeEjectService(
            registry: registry,
            activity: activity,
            store: store,
            runner: runner,
            testingClaimProvider: claimProvider,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
        )
        do {
            try await service.eject(expectedIdentity: identity)
            XCTFail("Active source I/O must block eject")
        } catch { }
        let callsWhileActive = await runner.invocationCount()
        XCTAssertEqual(callsWhileActive, 0)

        await activity.end(sourceVolumeID: identity.id)
        try await service.eject(expectedIdentity: identity)
        let callsAfterSuccess = await runner.invocationCount()
        XCTAssertEqual(callsAfterSuccess, 0, "Safe eject must not re-resolve a retained claim through diskutil")
        let retainedEjectCalls = await claimProvider.ejectCount()
        XCTAssertEqual(retainedEjectCalls, 1)
        let sawQuiescence = await claimProvider.sawEjectQuiescence()
        XCTAssertTrue(sawQuiescence)
        let competingActivityRejected = await claimProvider.competingEjectActivityWasRejected()
        XCTAssertTrue(competingActivityRejected)
        let remainsRegistered = await registry.contains(sourceVolumeID: identity.id)
        XCTAssertFalse(remainsRegistered)
        let reservationReleased = await activity.isDestructivelyQuiesced(
            sourceVolumeID: identity.id
        )
        XCTAssertFalse(reservationReleased)
    }

    func testFinalVerificationRejectsNewSourceEntry() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("original".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        _ = try fixture.writeSource(name: "LATE.MOV", data: Data("late write".utf8))
        do {
            _ = try await FinalVerificationService(store: store).verify(
                runID: plan.runID,
                currentIdentity: plan.sourceVolume
            )
            XCTFail("A new source entry must invalidate erase eligibility")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFinalVerificationRejectsDestinationReplacementWithSameSize() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("AAAA".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        try Data("BBBB".utf8).write(to: plan.items[0].finalURL)
        do {
            _ = try await FinalVerificationService(store: store).verify(
                runID: plan.runID,
                currentIdentity: plan.sourceVolume
            )
            XCTFail("Same-size destination replacement must fail full hash verification")
        } catch let error as UMISCoreError {
            switch error {
            case .hashMismatch, .sourceChanged: break
            default: XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFinalVerificationReusesFrozenMediaScanPolicy() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A.MOV", data: Data("movie".utf8))
        _ = try fixture.writeSource(name: "B.JPG", data: Data("photo".utf8))
        let movie = ProjectCategory(
            displayName: "Movie",
            folderName: "Movies",
            extensions: ["mov"],
            mediaKind: .movie,
            isEnabled: false
        )
        let photo = ProjectCategory(
            displayName: "Photo",
            folderName: "Photos",
            extensions: ["jpg"],
            mediaKind: .photo
        )
        let settings = ProjectSettings(categories: [movie, photo])
        let policy = MediaScanPolicy(projectSettings: settings)
        let sourceID = SourceVolumeID()
        let scan = try await MediaScanner().scan(
            root: fixture.source,
            sourceVolumeID: sourceID,
            policy: policy
        )
        let destination = try DestinationIdentityResolver().resolve(rootURL: fixture.destination)
        let allIDs = Set(scan.assets.map(\.id))
        let required = try scan.validatedRequiredSet(
            selectedAssetIDs: allIDs,
            destinationID: destination.id
        )
        XCTAssertTrue(required.isStructurallyEligibleForErase)
        let items = scan.assets.map { asset in
            IngestPlanItem(
                asset: asset,
                sourceURL: asset.canonicalURL,
                finalURL: fixture.destination.appendingPathComponent(asset.originalName),
                expectedSourceFingerprint: asset.fingerprint
            )
        }
        let plan = IngestPlan(
            project: Project(name: "Policy Project", settings: settings),
            sourceVolume: makeStrongVolume(id: sourceID, mountURL: fixture.source),
            destination: destination,
            requiredSet: required,
            scanPolicy: policy,
            items: items
        )
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)
        let evidence = try await FinalVerificationService(store: store).verify(
            runID: plan.runID,
            currentIdentity: plan.sourceVolume
        )
        XCTAssertEqual(Set(evidence.sourceFullHashes.keys), allIDs)
    }

    func testSamePhysicalVolumeFolderIsRejectedByPlanAndEraseGate() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "A.MOV", data: Data("original".utf8))
        let folderOnCard = fixture.source.appendingPathComponent("COPIED", isDirectory: true)
        try FileManager.default.createDirectory(at: folderOnCard, withIntermediateDirectories: true)
        let sourceID = SourceVolumeID()
        let scan = try await MediaScanner().scan(root: fixture.source, sourceVolumeID: sourceID)
        let asset = try XCTUnwrapValue(scan.assets.first)
        let destination = try DestinationIdentityResolver().resolve(rootURL: folderOnCard)
        var source = makeStrongVolume(id: sourceID, mountURL: fixture.source)
        source.volumeUUID = try XCTUnwrapValue(destination.volumeIdentifier.flatMap(UUID.init(uuidString:)))
        source.volumeDeviceIdentifier = destination.volumeDeviceIdentifier
        let required = try scan.validatedRequiredSet(destinationID: destination.id)
        let plan = IngestPlan(
            project: Project(name: "Unsafe Same Volume"),
            sourceVolume: source,
            destination: destination,
            requiredSet: required,
            items: [IngestPlanItem(
                asset: asset,
                sourceURL: asset.canonicalURL,
                finalURL: folderOnCard.appendingPathComponent(asset.originalName),
                expectedSourceFingerprint: asset.fingerprint
            )]
        )
        do {
            try plan.validate()
            XCTFail("Copying to another folder on the source card must never be erase-grade")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let dummyReceipt = IngestReceipt(
            runID: plan.runID,
            sourceIdentityDigest: source.securityDigest,
            requiredSetDigest: try StableDigest.encode(required),
            deliveries: []
        )
        let evidence = FinalVerificationEvidence(
            ingestReceipt: dummyReceipt,
            requiredSet: required,
            sourceFullHashes: [:],
            destinationFullHashes: [:],
            sourceManifestDigest: required.inventoryDigest,
            destinationIdentity: destination,
            destinationIdentityDigest: try StableDigest.encode(destination),
            localJournalDurablyCommitted: true,
            noSourceWorkerIsRunning: true
        )
        do {
            _ = try await EraseGate().issue(
                evidence: evidence,
                profile: try CardFormatProfile(label: "SAME_VOLUME"),
                currentIdentity: source,
                currentDestinationIdentity: destination
            )
            XCTFail("EraseGate must independently reject a same-volume destination")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testProductionEraseBackendWithoutNativeClaimFailsBeforeAnyHelperCommand() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        let registry = VolumeIdentityRegistry()
        await registry.registerAppearance(identity)
        let runner = RecordingDiskutilRunner(
            registry: registry,
            sourceRoot: fixture.source,
            identity: identity,
            label: "FAILCLOSED"
        )
        let backend = DiskutilCardEraseBackend(
            registry: registry,
            runner: runner,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
        )
        do {
            _ = try await backend.prepareDestructiveTarget(
                expectedIdentity: identity,
                timeout: 1
            )
            XCTFail("A production backend without a retained native claim must be unavailable")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let arguments = await runner.recordedArguments()
        XCTAssertTrue(arguments.isEmpty)
    }

    func testClaimAcquisitionTimeoutDoesNotUnmountOrInvokeEraseHelper() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        let registry = VolumeIdentityRegistry()
        await registry.registerAppearance(identity)
        let runner = RecordingDiskutilRunner(
            registry: registry,
            sourceRoot: fixture.source,
            identity: identity,
            label: "TIMEOUT"
        )
        let claimProvider = DeterministicRetainedMediaClaimProvider(registry: registry)
        await claimProvider.failAcquisition(with: .backendFailure("Injected claim timeout"))
        let backend = DiskutilCardEraseBackend(
            registry: registry,
            runner: runner,
            testingClaimProvider: claimProvider,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
        )
        do {
            _ = try await backend.prepareDestructiveTarget(
                expectedIdentity: identity,
                timeout: 0.01
            )
            XCTFail("Injected claim timeout must fail closed")
        } catch let error as UMISCoreError {
            guard case .backendFailure = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let arguments = await runner.recordedArguments()
        XCTAssertFalse(arguments.contains(where: { ["unmount", "eraseVolume"].contains($0.first) }))
        let retainedClaims = await claimProvider.retainedCount()
        XCTAssertEqual(retainedClaims, 0)
    }

    func testRetainedClaimRejectsBSDReuseUnplugAndTopologyChangeBeforeErase() async throws {
        enum Mutation: String, CaseIterable { case bsdReuse, unplug, topology }

        for mutation in Mutation.allCases {
            let fixture = try CoreFixture()
            defer { fixture.cleanup() }
            let (plan, _) = try await makeSingleFilePlan(
                fixture: fixture,
                data: Data("claim-bound-\(mutation.rawValue)".utf8)
            )
            let store = try OperationStore(databaseURL: fixture.database)
            _ = try await IngestEngine(store: store).execute(plan: plan)
            let registry = VolumeIdentityRegistry()
            await registry.registerAppearance(plan.sourceVolume)
            let activity = VolumeIOActivityRegistry()
            let runner = RecordingDiskutilRunner(
                registry: registry,
                sourceRoot: fixture.source,
                identity: plan.sourceVolume,
                label: "BOUNDARY"
            )
            let claimProvider = DeterministicRetainedMediaClaimProvider(registry: registry)
            switch mutation {
            case .bsdReuse:
                var replacement = plan.sourceVolume
                replacement.arrivalGeneration = UUID()
                replacement.mediaUUID = UUID()
                // Deliberately retain disk99/disk99s1: BSD equality must grant no authority.
                await claimProvider.replaceAfterFirstRevalidation(with: replacement)
            case .unplug:
                await claimProvider.disappearAfterFirstRevalidationCallback()
            case .topology:
                var changedTopology = plan.sourceVolume
                changedTopology.partitionCount = 2
                changedTopology.parentChainDigest = "changed-parent-chain"
                await claimProvider.replaceAfterFirstRevalidation(with: changedTopology)
            }
            let backend = DiskutilCardEraseBackend(
                registry: registry,
                runner: runner,
                testingClaimProvider: claimProvider,
                diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
            )
            do {
                _ = try await EraseGate(store: store, activity: activity)
                    .eraseAfterUserConfirmation(
                        runID: plan.runID,
                        profile: try CardFormatProfile(label: "BOUNDARY"),
                        currentIdentity: plan.sourceVolume,
                        backend: backend
                    )
                XCTFail("\(mutation.rawValue) must invalidate the retained destructive handle")
            } catch let error as UMISCoreError {
                XCTAssertEqual(error, .identityChanged, "Mutation: \(mutation.rawValue)")
            }
            let arguments = await runner.recordedArguments()
            XCTAssertFalse(
                arguments.contains(where: { $0.first == "eraseVolume" }),
                "Mutation: \(mutation.rawValue)"
            )
            let retainedClaims = await claimProvider.retainedCount()
            XCTAssertEqual(retainedClaims, 0, "Mutation: \(mutation.rawValue)")
            let quarantine = try await store.destructiveQuarantine(for: plan.sourceVolume)
            XCTAssertNotNil(
                quarantine,
                "A failure after token consumption remains durably quarantined: \(mutation.rawValue)"
            )
        }
    }

    func testPreparedBackendHandleAndCapabilityAreOneShot() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        let backend = SimulatedCardEraseBackend(identity: identity)
        let prepared = try await backend.prepareDestructiveTarget(
            expectedIdentity: identity,
            timeout: 5
        )
        let capability = ConsumedEraseCapability(
            nonce: UUID(),
            expectedIdentityDigest: identity.securityDigest,
            preparedHandleID: prepared.handleID,
            destructiveHandleDigest: prepared.authorizationBindingDigest
        )
        _ = try await backend.erase(
            preparedTarget: prepared,
            profile: try CardFormatProfile(label: "ONESHOT"),
            authorization: capability
        )
        do {
            _ = try await backend.erase(
                preparedTarget: prepared,
                profile: try CardFormatProfile(label: "ONESHOT"),
                authorization: capability
            )
            XCTFail("A consumed native handle must never be replayable")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .reusedToken)
        }
    }

    func testSafeEjectWithoutNativeClaimFailsBeforeProcessRunner() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let identity = makeStrongVolume(id: SourceVolumeID(), mountURL: fixture.source)
        let registry = VolumeIdentityRegistry()
        let activity = VolumeIOActivityRegistry()
        let store = try OperationStore(databaseURL: fixture.database)
        await registry.registerAppearance(identity)
        let runner = RecordingEjectRunner(registry: registry, identity: identity)
        let service = SafeEjectService(
            registry: registry,
            activity: activity,
            store: store,
            runner: runner,
            diskutilURL: URL(fileURLWithPath: "/test-only/fake-diskutil")
        )
        do {
            try await service.eject(expectedIdentity: identity)
            XCTFail("Safe eject must be unavailable without a retained native claim provider")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let invocations = await runner.invocationCount()
        XCTAssertEqual(invocations, 0)
        let remainsRegistered = await registry.contains(sourceVolumeID: identity.id)
        XCTAssertTrue(remainsRegistered)
    }
}
