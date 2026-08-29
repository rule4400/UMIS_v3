import Foundation
import XCTest
@testable import UMISCore

final class IngestEngineTests: XCTestCase {
    func testPlanRejectsMissingOrWrongDestinationDeliveryObligations() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (basePlan, asset) = try await makeSingleFilePlan(fixture: fixture, data: Data("obligation".utf8))

        var missing = basePlan
        missing.requiredSet.deliveries = []
        XCTAssertThrowsError(try missing.validate())

        var wrongDestination = basePlan
        wrongDestination.requiredSet.deliveries = [
            RequiredDelivery(assetID: asset.id, destinationID: DestinationID()),
        ]
        XCTAssertThrowsError(try wrongDestination.validate())

        var missingItem = basePlan
        missingItem.items = []
        XCTAssertThrowsError(try missingItem.validate())
    }

    func testNetworkDestinationIsCopyGradeButNotEraseGradeWithoutCertifiedProfile() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (basePlan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("network copy".utf8))
        var networkDestination = basePlan.destination
        networkDestination.isNetwork = true
        networkDestination.durabilityProfileID = nil
        let lifecycleAuthority = UUID()
        networkDestination.networkMountLifecycleAuthorityID = lifecycleAuthority
        networkDestination.backingEvidence = DestinationBackingEvidence(
            kind: .networkMount,
            provenance: .networkMountLifecycle,
            backingStoreIdentifier: networkDestination.volumeIdentifier
        )
        XCTAssertTrue(networkDestination.hasCopyGradeIdentity)
        XCTAssertFalse(networkDestination.hasEraseGradeIdentity)
        XCTAssertNoThrow(try VolumeIndependenceValidator.validate(
            source: basePlan.sourceVolume,
            destination: networkDestination,
            assurance: .copyGrade
        ))
        XCTAssertThrowsError(try VolumeIndependenceValidator.validate(
            source: basePlan.sourceVolume,
            destination: networkDestination,
            assurance: .eraseGrade
        ))

        networkDestination.durabilityProfileID = "caller-invented-profile"
        XCTAssertFalse(networkDestination.hasEraseGradeIdentity)
        var networkPlan = basePlan
        networkPlan.destination = networkDestination
        networkPlan.requiredSet.deliveries = Set(
            networkPlan.requiredSet.assetIDs.map {
                RequiredDelivery(assetID: $0, destinationID: networkDestination.id)
            }
        )
        XCTAssertNoThrow(try networkPlan.validate())

        let matchingWitness = NetworkMountLifecycleWitness(
            authorityID: lifecycleAuthority,
            generation: networkDestination.mountGeneration
        )
        XCTAssertNoThrow(try NetworkMountLifecycleValidator.validate(
            expected: networkDestination,
            freshWitness: matchingWitness
        ))
        XCTAssertThrowsError(try NetworkMountLifecycleValidator.validate(
            expected: networkDestination,
            freshWitness: NetworkMountLifecycleWitness(
                authorityID: lifecycleAuthority,
                generation: UUID()
            )
        ))
        XCTAssertThrowsError(try DestinationIdentityResolver().revalidate(networkDestination))

        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await IngestEngine(store: store).execute(plan: networkPlan)
            XCTFail("Network ingest without a fresh mount observer must fail closed")
        } catch let error as UMISCoreError {
            guard case .eraseNotEligible = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let revalidations = LockedIntRecorder()
        let observedSwapEngine = IngestEngine(
            store: store,
            chunkSize: 4_096,
            destinationRevalidator: { expected in
                let call = revalidations.snapshot().count + 1
                revalidations.append(Int64(call))
                if call == 1 { return expected }
                throw UMISCoreError.identityChanged
            }
        )
        do {
            _ = try await observedSwapEngine.execute(plan: networkPlan)
            XCTFail("A remount generation change before atomic commit must block delivery")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .identityChanged)
        }
        XCTAssertGreaterThanOrEqual(revalidations.snapshot().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: networkPlan.items[0].finalURL.path))
    }

    func testEraseGradeRejectsUnknownVirtualAndDiskImageDestinationBacking() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("backing proof".utf8))
        XCTAssertTrue(plan.destination.hasEraseGradeIdentity)

        for kind in [
            DestinationBackingKind.unknown,
            .virtualDevice,
            .diskImage,
        ] {
            var destination = plan.destination
            destination.backingEvidence = DestinationBackingEvidence(
                kind: kind,
                provenance: .unknown,
                backingStoreIdentifier: nil
            )
            XCTAssertTrue(destination.hasCopyGradeIdentity)
            XCTAssertFalse(destination.hasEraseGradeIdentity)
            XCTAssertThrowsError(try VolumeIndependenceValidator.validate(
                source: plan.sourceVolume,
                destination: destination,
                assurance: .eraseGrade
            ))
        }
    }

    func testHappyPathUsesPartialFullVerificationAndDurableJournal() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data, expectedHash: sha256(data))
        let store = try OperationStore(databaseURL: fixture.database)
        let receipt = try await IngestEngine(store: store, chunkSize: 16_384).execute(plan: plan)

        XCTAssertEqual(receipt.deliveries.count, 1)
        XCTAssertEqual(receipt.deliveries[0].state, .durableCommitted)
        XCTAssertEqual(try Data(contentsOf: plan.items[0].finalURL), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OperationStore.partialURL(for: plan.items[0], plan: plan).path))
        let schemaVersion = try await store.schemaVersion()
        let auditCount = try await store.auditEventCount()
        XCTAssertEqual(schemaVersion, OperationStore.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(auditCount, 2)
    }

    func testExistingDifferentFileIsCollisionAndNeverOverwritten() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let sourceData = Data("SOURCE".utf8)
        let existingData = Data("TARGET".utf8)
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: sourceData)
        try existingData.write(to: plan.items[0].finalURL)
        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await IngestEngine(store: store).execute(plan: plan)
            XCTFail("Expected collision")
        } catch let error as UMISCoreError {
            guard case .collision = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: plan.items[0].finalURL), existingData)
    }

    func testExecuteRejectsDestinationRootReplacementBeforeCopy() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("destination identity".utf8))
        let displaced = fixture.root.appendingPathComponent("displaced-destination")
        try FileManager.default.moveItem(at: fixture.destination, to: displaced)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await IngestEngine(store: store).execute(plan: plan)
            XCTFail("A same-path replacement destination must be rejected before copy")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .identityChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].finalURL.path))
    }

    func testAtomicCommitRejectsDestinationAncestorSymlinkReplacement() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (basePlan, _) = try await makeSingleFilePlan(
            fixture: fixture,
            data: Data("must never be redirected".utf8)
        )
        var plan = basePlan
        let deliveryParent = fixture.destination.appendingPathComponent("MOVIES", isDirectory: true)
        let finalURL = deliveryParent.appendingPathComponent("DELIVERED.MOV")
        plan.items[0].finalURL = finalURL
        try plan.validate()

        let displacedParent = fixture.destination.appendingPathComponent("MOVIES-original", isDirectory: true)
        let redirectTarget = fixture.source
        let store = try OperationStore(databaseURL: fixture.database)
        let engine = IngestEngine(
            store: store,
            chunkSize: 4_096,
            testingHooks: CopyTestingHooks(afterCommitIntentBeforeRename: { _ in
                try FileManager.default.moveItem(at: deliveryParent, to: displacedParent)
                try FileManager.default.createSymbolicLink(
                    at: deliveryParent,
                    withDestinationURL: redirectTarget
                )
            })
        )
        do {
            _ = try await engine.execute(plan: plan)
            XCTFail("An ancestor symlink introduced at commit must fail closed")
        } catch let error as UMISCoreError {
            switch error {
            case .symbolicLinkRejected, .identityChanged: break
            default: XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("DELIVERED.MOV").path
        ))
        let summary = try await store.operation(id: plan.runID.rawValue)
        XCTAssertNotEqual(summary?.status, .completed)
    }

    func testNewDestinationAncestorFsyncFailuresNeverPublishDurableReceipt() async throws {
        // Two nested final-directory creations each require child fsync followed by parent fsync.
        // Inject a failure at every boundary and prove no durable receipt/final delivery is issued.
        for failureCall in 1 ... 4 {
            let fixture = try CoreFixture(); defer { fixture.cleanup() }
            let (basePlan, _) = try await makeSingleFilePlan(
                fixture: fixture,
                data: Data("ancestor durability".utf8)
            )
            var plan = basePlan
            plan.items[0].finalURL = fixture.destination
                .appendingPathComponent("DAY01", isDirectory: true)
                .appendingPathComponent("MOVIES", isDirectory: true)
                .appendingPathComponent("DURABLE.MOV")
            try plan.validate()
            let store = try OperationStore(databaseURL: fixture.database)
            let calls = LockedIntRecorder()
            let engine = IngestEngine(
                store: store,
                chunkSize: 4_096,
                testingHooks: CopyTestingHooks(destinationDirectorySynchronizer: { descriptor, path in
                    let call = calls.snapshot().count + 1
                    calls.append(Int64(call))
                    if call == failureCall {
                        throw UMISCoreError.posix(operation: "injected directory fsync", code: EIO, path: path)
                    }
                    try POSIXFile.synchronize(descriptor: descriptor, path: path)
                })
            )
            do {
                _ = try await engine.execute(plan: plan)
                XCTFail("Injected ancestor fsync failure \(failureCall) must stop ingest")
            } catch let error as UMISCoreError {
                guard case .posix = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].finalURL.path))
            let receipt = try await store.loadReceipt(runID: plan.runID)
            XCTAssertNil(receipt)
            let operation = try await store.operation(id: plan.runID.rawValue)
            XCTAssertNotEqual(operation?.status, .completed)
            let journal = try await store.items(operationID: plan.runID.rawValue)
            XCTAssertTrue(journal.allSatisfy { $0.state != .durableCommitted })
        }
    }

    func testFinalVerificationRejectsDestinationAncestorSymlinkReplacement() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data("counterfeit-safe".utf8)
        let (basePlan, _) = try await makeSingleFilePlan(fixture: fixture, data: data)
        var plan = basePlan
        let deliveryParent = fixture.destination.appendingPathComponent("STILLS", isDirectory: true)
        // Redirecting this path to the source card resolves to the original A001.MOV with the exact
        // expected bytes. Hash-only verification would accept it and authorize erasing that card.
        plan.items[0].finalURL = deliveryParent.appendingPathComponent(
            plan.items[0].asset.originalName
        )
        try plan.validate()
        let store = try OperationStore(databaseURL: fixture.database)
        _ = try await IngestEngine(store: store).execute(plan: plan)

        let displacedParent = fixture.destination.appendingPathComponent("STILLS-original", isDirectory: true)
        try FileManager.default.moveItem(at: deliveryParent, to: displacedParent)
        try FileManager.default.createSymbolicLink(
            at: deliveryParent,
            withDestinationURL: fixture.source
        )
        do {
            _ = try await FinalVerificationService(store: store).verify(
                runID: plan.runID,
                currentIdentity: plan.sourceVolume
            )
            XCTFail("A symlink-redirected delivery must never produce erase evidence")
        } catch let error as UMISCoreError {
            switch error {
            case .symbolicLinkRejected, .identityChanged: break
            default: XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testVerifyIdenticalDuplicateRequiresFreshFullHash() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data("same-content".utf8)
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data, duplicatePolicy: .verifyIdentical)
        try data.write(to: plan.items[0].finalURL)
        let store = try OperationStore(databaseURL: fixture.database)
        let receipt = try await IngestEngine(store: store).execute(plan: plan)
        XCTAssertEqual(receipt.deliveries.first?.state, .durableVerifiedExisting)
        XCTAssertEqual(receipt.deliveries.first?.sourceSHA256, sha256(data))
    }

    func testExpectedSourceHashMismatchLeavesNoFinal() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(
            fixture: fixture,
            data: Data("real content".utf8),
            expectedHash: String(repeating: "0", count: 64)
        )
        let store = try OperationStore(databaseURL: fixture.database)
        do {
            _ = try await IngestEngine(store: store).execute(plan: plan)
            XCTFail("Expected hash mismatch")
        } catch let error as UMISCoreError {
            guard case .hashMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].finalURL.path))
    }

    func testDestinationCorruptionDetectedBeforeAtomicCommit() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data(repeating: 0x4a, count: 100_000))
        let store = try OperationStore(databaseURL: fixture.database)
        let engine = IngestEngine(
            store: store,
            chunkSize: 8_192,
            testingHooks: CopyTestingHooks(beforeDestinationVerification: { partial in
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data([0xff]))
                try handle.close()
            })
        )
        do {
            _ = try await engine.execute(plan: plan)
            XCTFail("Expected destination hash mismatch")
        } catch let error as UMISCoreError {
            guard case .hashMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].finalURL.path))
    }

    func testCancelLeavesCheckpointAndResumeValidatesPrefix() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data((0 ..< 2_000_000).map { UInt8($0 % 239) })
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data)
        let store = try OperationStore(databaseURL: fixture.database)
        let cancellation = OperationCancellation()
        let engine = IngestEngine(store: store, chunkSize: 4_096)
        do {
            _ = try await engine.execute(plan: plan, cancellation: cancellation) { progress in
                if progress.completedBytes >= 16_384 { await cancellation.cancel() }
            }
            XCTFail("Expected cancellation")
        } catch let error as UMISCoreError {
            XCTAssertEqual(error, .cancelled)
        }
        let partial = OperationStore.partialURL(for: plan.items[0], plan: plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        let partialSize = try FileFingerprint.capture(at: partial).byteSize
        XCTAssertGreaterThan(partialSize, 0)
        XCTAssertLessThan(partialSize, Int64(data.count))

        await cancellation.reset()
        let receipt = try await engine.resume(runID: plan.runID, cancellation: cancellation)
        XCTAssertEqual(receipt.deliveries.first?.state, .durableCommitted)
        XCTAssertEqual(try Data(contentsOf: plan.items[0].finalURL), data)
    }

    func testDurableCheckpointsAreBatchedAndFsyncPrecedesPublishedOffset() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data((0 ..< 2_000_000).map { UInt8($0 % 251) })
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data)
        let store = try OperationStore(databaseURL: fixture.database)
        let checkpoints = LockedIntRecorder()
        let engine = IngestEngine(
            store: store,
            chunkSize: 4_096,
            durableCheckpointBytes: 256 * 1_024,
            durableCheckpointInterval: 3_600,
            testingHooks: CopyTestingHooks(afterDurableCheckpoint: { checkpoints.append($0) })
        )
        _ = try await engine.execute(plan: plan)
        let offsets = checkpoints.snapshot()
        XCTAssertGreaterThanOrEqual(offsets.count, 4)
        XCTAssertLessThan(offsets.count, 16, "Checkpoint writes must be batched, not one SQLite FULL commit per chunk")
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertEqual(offsets.last, Int64(data.count))
    }

    func testResumeTruncatesUnjournaledPartialTailBeforeHashingPrefix() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let data = Data("abcdefgh".utf8)
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: data)
        let store = try OperationStore(databaseURL: fixture.database)
        try await store.createIngest(plan)
        let partial = OperationStore.partialURL(for: plan.items[0], plan: plan)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abcdUNJOURNALED".utf8).write(to: partial)
        let stored = try await store.item(operationID: plan.runID.rawValue, itemID: plan.items[0].id)
        var journal = try XCTUnwrapValue(stored)
        journal.state = .copying
        journal.bytesCopied = 4
        try await store.updateItem(journal)

        let receipt = try await IngestEngine(store: store, chunkSize: 4_096).resume(runID: plan.runID)
        XCTAssertEqual(receipt.deliveries.count, 1)
        XCTAssertEqual(try Data(contentsOf: plan.items[0].finalURL), data)
    }

    func testOperationHistoryErrorAndRedactedAuditReadAPIs() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("journal".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        try await store.createIngest(plan)
        let storedItem = try await store.item(
            operationID: plan.runID.rawValue,
            itemID: plan.items[0].id
        )
        var item = try XCTUnwrapValue(storedItem)
        item.state = .failed
        item.error = "Sensitive path: \(item.finalURL.path)"
        try await store.updateItem(item)
        try await store.setOperationStatus(.failed, id: plan.runID.rawValue)
        let sensitivePayload = Data("/Volumes/Archive/Project/A001.MOV".utf8)
        try await store.appendAudit(
            operationID: plan.runID.rawValue,
            event: "test.failure",
            payload: sensitivePayload
        )

        let history = try await store.operations(limit: 10, kind: .ingest, status: .failed)
        XCTAssertEqual(history.map(\.id), [plan.runID.rawValue])
        let failures = try await store.itemErrors(operationID: plan.runID.rawValue)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.state, .failed)

        let redacted = try await store.auditExport(operationID: plan.runID.rawValue)
        XCTAssertEqual(redacted.count, 1)
        XCTAssertTrue(redacted[0].isPayloadRedacted)
        XCTAssertTrue(redacted[0].payload.isEmpty)
        let authorized = try await store.auditExport(
            operationID: plan.runID.rawValue,
            includeSensitivePayload: true
        )
        XCTAssertEqual(authorized.first?.payload, sensitivePayload)
        XCTAssertFalse(authorized[0].isPayloadRedacted)
    }

    func testResumeRehashesCompletedDestinationAndTransitionsToRecoveryRequiredOnReplacement() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let (plan, _) = try await makeSingleFilePlan(fixture: fixture, data: Data("AAAA".utf8))
        let store = try OperationStore(databaseURL: fixture.database)
        let engine = IngestEngine(store: store)
        _ = try await engine.execute(plan: plan)

        let unchanged = try await engine.resume(runID: plan.runID)
        XCTAssertEqual(unchanged.runID, plan.runID)
        try Data("BBBB".utf8).write(to: plan.items[0].finalURL)
        do {
            _ = try await engine.resume(runID: plan.runID)
            XCTFail("Resume must not trust a stale durable receipt")
        } catch { }
        let summary = try await store.operation(id: plan.runID.rawValue)
        XCTAssertEqual(summary?.status, .recoveryRequired)
        let failures = try await store.itemErrors(operationID: plan.runID.rawValue)
        XCTAssertEqual(failures.first?.state, .conflict)

        do {
            _ = try await engine.resume(runID: plan.runID)
            XCTFail("Recovery-required operations need explicit review")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
