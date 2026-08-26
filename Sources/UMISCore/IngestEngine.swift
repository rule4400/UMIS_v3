import CryptoKit
import Darwin
import Foundation

public struct IngestProgress: Sendable, Hashable {
    public var runID: IngestRunID
    public var itemID: IngestItemID
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(runID: IngestRunID, itemID: IngestItemID, completedBytes: Int64, totalBytes: Int64) {
        self.runID = runID
        self.itemID = itemID
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public typealias IngestProgressHandler = @Sendable (IngestProgress) async -> Void
public typealias DestinationIdentityRevalidationHandler = @Sendable (
    _ expected: DestinationIdentity
) async throws -> DestinationIdentity

struct CopyTestingHooks: Sendable {
    var beforeDestinationVerification: (@Sendable (URL) throws -> Void)?
    var afterCommitIntentBeforeRename: (@Sendable (URL) throws -> Void)?
    var afterAtomicRenameBeforeJournalUpdate: (@Sendable (URL) throws -> Void)?
    var afterAtomicJournalBeforeDirectorySync: (@Sendable (URL) throws -> Void)?
    var afterDirectorySyncBeforeReceipt: (@Sendable (URL) throws -> Void)?
    var afterReceiptPreparedBeforeJournalUpdate: (@Sendable (URL) throws -> Void)?
    var afterDurableReceiptJournalBeforeAudit: (@Sendable (URL) throws -> Void)?
    var afterDurableCheckpoint: (@Sendable (Int64) -> Void)?
    var destinationDirectorySynchronizer: DestinationPathAccess.DirectorySynchronizer?

    init(
        beforeDestinationVerification: (@Sendable (URL) throws -> Void)? = nil,
        afterCommitIntentBeforeRename: (@Sendable (URL) throws -> Void)? = nil,
        afterAtomicRenameBeforeJournalUpdate: (@Sendable (URL) throws -> Void)? = nil,
        afterAtomicJournalBeforeDirectorySync: (@Sendable (URL) throws -> Void)? = nil,
        afterDirectorySyncBeforeReceipt: (@Sendable (URL) throws -> Void)? = nil,
        afterReceiptPreparedBeforeJournalUpdate: (@Sendable (URL) throws -> Void)? = nil,
        afterDurableReceiptJournalBeforeAudit: (@Sendable (URL) throws -> Void)? = nil,
        afterDurableCheckpoint: (@Sendable (Int64) -> Void)? = nil,
        destinationDirectorySynchronizer: DestinationPathAccess.DirectorySynchronizer? = nil
    ) {
        self.beforeDestinationVerification = beforeDestinationVerification
        self.afterCommitIntentBeforeRename = afterCommitIntentBeforeRename
        self.afterAtomicRenameBeforeJournalUpdate = afterAtomicRenameBeforeJournalUpdate
        self.afterAtomicJournalBeforeDirectorySync = afterAtomicJournalBeforeDirectorySync
        self.afterDirectorySyncBeforeReceipt = afterDirectorySyncBeforeReceipt
        self.afterReceiptPreparedBeforeJournalUpdate = afterReceiptPreparedBeforeJournalUpdate
        self.afterDurableReceiptJournalBeforeAudit = afterDurableReceiptJournalBeforeAudit
        self.afterDurableCheckpoint = afterDurableCheckpoint
        self.destinationDirectorySynchronizer = destinationDirectorySynchronizer
    }
}

public actor IngestEngine {
    private let store: OperationStore
    private let chunkSize: Int
    private let durableCheckpointBytes: Int64
    private let durableCheckpointInterval: Duration
    private let hooks: CopyTestingHooks
    private let destinationRevalidator: DestinationIdentityRevalidationHandler?

    public init(
        store: OperationStore,
        chunkSize: Int = 1_048_576,
        durableCheckpointBytes: Int64 = 64 * 1_024 * 1_024,
        durableCheckpointInterval: TimeInterval = 2,
        destinationRevalidator: DestinationIdentityRevalidationHandler? = nil
    ) {
        self.store = store
        let resolvedChunkSize = max(4_096, chunkSize)
        self.chunkSize = resolvedChunkSize
        self.durableCheckpointBytes = max(Int64(resolvedChunkSize), durableCheckpointBytes)
        self.durableCheckpointInterval = .milliseconds(
            Int64(max(0.1, durableCheckpointInterval) * 1_000)
        )
        self.destinationRevalidator = destinationRevalidator
        hooks = CopyTestingHooks()
    }

    init(
        store: OperationStore,
        chunkSize: Int,
        durableCheckpointBytes: Int64 = 64 * 1_024 * 1_024,
        durableCheckpointInterval: TimeInterval = 2,
        testingHooks: CopyTestingHooks,
        destinationRevalidator: DestinationIdentityRevalidationHandler? = nil
    ) {
        self.store = store
        let resolvedChunkSize = max(4_096, chunkSize)
        self.chunkSize = resolvedChunkSize
        self.durableCheckpointBytes = max(Int64(resolvedChunkSize), durableCheckpointBytes)
        self.durableCheckpointInterval = .milliseconds(
            Int64(max(0.1, durableCheckpointInterval) * 1_000)
        )
        self.destinationRevalidator = destinationRevalidator
        hooks = testingHooks
    }

    public func execute(
        plan: IngestPlan,
        operationKind: OperationKind = .ingest,
        cancellation: OperationCancellation? = nil,
        progress: IngestProgressHandler? = nil
    ) async throws -> IngestReceipt {
        try plan.validate()
        let currentDestination = try await revalidateDestination(plan.destination)
        guard currentDestination == plan.destination else { throw UMISCoreError.identityChanged }
        try await store.createIngest(plan, kind: operationKind)
        return try await perform(plan: plan, cancellation: cancellation, progress: progress)
    }

    public func resume(
        runID: IngestRunID,
        currentSourceIdentity: VolumeIdentity? = nil,
        currentDestinationIdentity: DestinationIdentity? = nil,
        cancellation: OperationCancellation? = nil,
        progress: IngestProgressHandler? = nil
    ) async throws -> IngestReceipt {
        let plan = try await store.loadIngestPlan(runID: runID)
        try plan.validate()
        guard let operation = try await store.operation(id: runID.rawValue) else {
            throw UMISCoreError.journalMissing(runID.rawValue.uuidString)
        }
        guard operation.status != .recoveryRequired, operation.status != .rolledBack else {
            throw UMISCoreError.invalidPlan("Operation requires explicit recovery review and cannot be resumed automatically")
        }
        if let currentSourceIdentity,
           currentSourceIdentity.securityDigest != plan.sourceVolume.securityDigest {
            throw UMISCoreError.identityChanged
        }
        let expectedDestination = currentDestinationIdentity ?? plan.destination
        let resolvedDestination = try await revalidateDestination(expectedDestination)
        guard resolvedDestination == plan.destination else { throw UMISCoreError.identityChanged }
        return try await perform(plan: plan, cancellation: cancellation, progress: progress)
    }

    private func perform(
        plan: IngestPlan,
        cancellation: OperationCancellation?,
        progress: IngestProgressHandler?
    ) async throws -> IngestReceipt {
        var recoveryRequired = false
        do {
            if let completed = try await store.loadReceipt(runID: plan.runID) {
                do {
                    try await revalidateCompletedReceipt(
                        completed,
                        plan: plan,
                        cancellation: cancellation
                    )
                    try await store.appendAudit(
                        operationID: plan.runID.rawValue,
                        event: "operation.resumeReceiptRevalidated"
                    )
                    return completed
                } catch {
                    recoveryRequired = true
                    throw error
                }
            }
            try await store.setOperationStatus(.running, id: plan.runID.rawValue)
            try await store.appendAudit(operationID: plan.runID.rawValue, event: "operation.started")
            var receipts: [DeliveryReceipt] = []
            for item in plan.items {
                try Task.checkCancellation()
                try await cancellation?.check()
                if let existing = try await store.item(operationID: plan.runID.rawValue, itemID: item.id),
                   let receipt = existing.receipt,
                   existing.state == .durableCommitted || existing.state == .durableVerifiedExisting {
                    do {
                        let verified = try await revalidateDurableReceipt(
                            receipt,
                            item: item,
                            plan: plan,
                            journal: existing,
                            cancellation: cancellation
                        )
                        receipts.append(verified)
                        continue
                    } catch {
                        var conflict = existing
                        conflict.state = .conflict
                        conflict.error = "Resume validation failed: \(error)"
                        conflict.updatedAt = Date()
                        try? await store.updateItem(conflict)
                        recoveryRequired = true
                        throw error
                    }
                }
                let receipt = try await copy(
                    item: item,
                    plan: plan,
                    cancellation: cancellation,
                    progress: progress
                )
                receipts.append(receipt)
            }

            let requiredDigest = try StableDigest.encode(plan.requiredSet)
            let receipt = IngestReceipt(
                runID: plan.runID,
                sourceIdentityDigest: plan.sourceVolume.securityDigest,
                requiredSetDigest: requiredDigest,
                deliveries: receipts
            )
            try await store.saveReceipt(receipt)
            try await store.appendAudit(
                operationID: plan.runID.rawValue,
                event: "operation.completed",
                payload: try StableJSON.encode(receipt)
            )
            return receipt
        } catch {
            let status: OperationStatus = recoveryRequired
                ? .recoveryRequired
                : (isCancellation(error) ? .cancelled : .failed)
            try? await store.setOperationStatus(status, id: plan.runID.rawValue)
            try? await store.appendAudit(
                operationID: plan.runID.rawValue,
                event: status == .cancelled
                    ? "operation.cancelled"
                    : (status == .recoveryRequired ? "operation.recoveryRequired" : "operation.failed"),
                payload: Data(String(describing: error).utf8)
            )
            throw normalizeCancellation(error)
        }
    }

    private func revalidateCompletedReceipt(
        _ receipt: IngestReceipt,
        plan: IngestPlan,
        cancellation: OperationCancellation?
    ) async throws {
        guard receipt.runID == plan.runID,
              receipt.sourceIdentityDigest == plan.sourceVolume.securityDigest,
              receipt.requiredSetDigest == (try StableDigest.encode(plan.requiredSet)) else {
            throw UMISCoreError.invalidPlan("Completed receipt no longer matches the frozen ingest plan")
        }
        let grouped = Dictionary(grouping: receipt.deliveries, by: \.itemID)
        guard receipt.deliveries.count == plan.items.count,
              grouped.count == plan.items.count,
              grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw UMISCoreError.invalidPlan("Completed receipt delivery set is incomplete or duplicated")
        }
        for item in plan.items {
            try Task.checkCancellation()
            try await cancellation?.check()
            guard let delivery = grouped[item.id]?.first,
                  let journal = try await store.item(operationID: plan.runID.rawValue, itemID: item.id),
                  let journalReceipt = journal.receipt,
                  journalReceipt == delivery,
                  journal.state == .durableCommitted || journal.state == .durableVerifiedExisting else {
                throw UMISCoreError.journalMissing("Completed item \(item.id.rawValue.uuidString) lacks durable journal evidence")
            }
            do {
                _ = try await revalidateDurableReceipt(
                    delivery,
                    item: item,
                    plan: plan,
                    journal: journal,
                    cancellation: cancellation
                )
            } catch {
                var conflict = journal
                conflict.state = .conflict
                conflict.error = "Completed receipt revalidation failed: \(error)"
                conflict.updatedAt = Date()
                try? await store.updateItem(conflict)
                throw error
            }
        }
    }

    private func revalidateDurableReceipt(
        _ receipt: DeliveryReceipt,
        item: IngestPlanItem,
        plan: IngestPlan,
        journal: JournalItemRecord,
        cancellation: OperationCancellation?
    ) async throws -> DeliveryReceipt {
        guard receipt.itemID == item.id,
              receipt.assetID == item.asset.id,
              receipt.destinationID == plan.destination.id,
              receipt.finalURL.standardizedFileURL == item.finalURL.standardizedFileURL,
              receipt.sourceSHA256 == receipt.destinationSHA256,
              journal.itemID == item.id,
              journal.assetID == item.asset.id else {
            throw UMISCoreError.invalidPlan("Durable receipt is not bound to the frozen item")
        }
        let currentFinalFingerprint = try DestinationPathAccess.fingerprint(
            item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        )
        guard currentFinalFingerprint == receipt.finalFingerprint else {
            throw UMISCoreError.sourceChanged(item.finalURL.path)
        }
        let source = try await StreamingSHA256.hashFile(
            at: item.sourceURL,
            expectedFingerprint: item.expectedSourceFingerprint,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
        if let expected = item.expectedContentSHA256, source.sha256 != expected.lowercased() {
            throw UMISCoreError.hashMismatch(item.sourceURL.path)
        }
        let destination = try await StreamingSHA256.hashDestinationFile(
            at: item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier,
            expectedFingerprint: receipt.finalFingerprint,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
        guard source.byteSize == receipt.byteSize,
              destination.byteSize == receipt.byteSize,
              source.sha256 == receipt.sourceSHA256,
              destination.sha256 == receipt.destinationSHA256 else {
            throw UMISCoreError.hashMismatch(item.finalURL.path)
        }
        return receipt
    }

    private func copy(
        item: IngestPlanItem,
        plan: IngestPlan,
        cancellation: OperationCancellation?,
        progress: IngestProgressHandler?
    ) async throws -> DeliveryReceipt {
        try PathSafety.requireDescendant(item.finalURL, of: plan.destination.rootURL)
        guard item.asset.sourceVolumeID == plan.sourceVolume.id else {
            throw UMISCoreError.invalidPlan("Asset source volume does not match frozen source volume")
        }
        let partial = OperationStore.partialURL(for: item, plan: plan)
        try PathSafety.requireDescendant(partial, of: plan.destination.rootURL)
        try DestinationPathAccess.prepareParent(
            for: item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier,
            directorySynchronizer: hooks.destinationDirectorySynchronizer
        )
        try DestinationPathAccess.prepareParent(
            for: partial,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier,
            directorySynchronizer: hooks.destinationDirectorySynchronizer
        )

        guard var journal = try await store.item(operationID: plan.runID.rawValue, itemID: item.id) else {
            throw UMISCoreError.journalMissing(item.id.rawValue.uuidString)
        }

        if try DestinationPathAccess.regularFileExists(
            item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        ) {
            let isRecovery = journal.state == .destinationHashed
                || journal.state == .atomicCommitIntent
                || journal.state == .atomicCommitted
            guard item.duplicatePolicy == .verifyIdentical || isRecovery else {
                journal.state = .conflict
                journal.error = "Destination already exists"
                try await store.updateItem(journal)
                throw UMISCoreError.collision(item.finalURL.path)
            }
            return try await verifyExisting(item: item, plan: plan, journal: journal, cancellation: cancellation)
        }

        let sourceDescriptor = try POSIXFile.openReadOnlyNoFollow(item.sourceURL)
        defer { Darwin.close(sourceDescriptor) }
        let sourceBefore = try POSIXFile.fingerprint(descriptor: sourceDescriptor, path: item.sourceURL.path)
        guard sourceBefore == item.expectedSourceFingerprint else {
            throw UMISCoreError.sourceChanged(item.sourceURL.path)
        }

        var sourceHasher = SHA256()
        var copied: Int64 = 0
        var destinationDescriptor: Int32 = -1
        do {
            if try DestinationPathAccess.regularFileExists(
                partial,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            ) {
                let expectedOffset = journal.bytesCopied
                let actualSize = try DestinationPathAccess.fingerprint(
                    partial,
                    destination: plan.destination,
                    sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
                ).byteSize
                guard actualSize >= expectedOffset else {
                    throw UMISCoreError.journalMissing("Partial file is shorter than the durable checkpoint")
                }
                if actualSize > expectedOffset {
                    // A crash may leave OS-flushed bytes beyond the last fsync->journal boundary.
                    // Discard only that uncommitted tail, then re-hash the durable prefix.
                    try DestinationPathAccess.truncateAndSynchronize(
                        partial,
                        byteSize: expectedOffset,
                        destination: plan.destination,
                        sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
                    )
                }
                try await validatePartialPrefix(
                    sourceDescriptor: sourceDescriptor,
                    sourceURL: item.sourceURL,
                    partialURL: partial,
                    plan: plan,
                    expectedOffset: expectedOffset,
                    hasher: &sourceHasher,
                    cancellation: cancellation
                )
                copied = expectedOffset
                destinationDescriptor = try DestinationPathAccess.openAppendWrite(
                    partial,
                    destination: plan.destination,
                    sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
                )
            } else {
                guard journal.bytesCopied == 0 else {
                    throw UMISCoreError.journalMissing("Partial file missing for non-zero checkpoint")
                }
                destinationDescriptor = try DestinationPathAccess.openExclusiveWrite(
                    partial,
                    destination: plan.destination,
                    sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
                )
            }

            journal.state = .copying
            journal.error = nil
            try await store.updateItem(journal)
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            var lastDurableOffset = copied
            let checkpointClock = ContinuousClock()
            var lastCheckpoint = checkpointClock.now
            while true {
                try Task.checkCancellation()
                try await cancellation?.check()
                let amount = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(sourceDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                }
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw UMISCoreError.posix(operation: "read source", code: errno, path: item.sourceURL.path)
                }
                if amount == 0 { break }
                try buffer.withUnsafeBytes { rawBuffer in
                    let bytes = UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: amount)
                    try POSIXFile.writeAll(descriptor: destinationDescriptor, bytes: bytes, path: partial.path)
                }
                sourceHasher.update(data: Data(buffer[0 ..< amount]))
                copied += Int64(amount)
                await progress?(IngestProgress(
                    runID: plan.runID,
                    itemID: item.id,
                    completedBytes: copied,
                    totalBytes: sourceBefore.byteSize
                ))
                let checkpointDueToBytes = copied - lastDurableOffset >= durableCheckpointBytes
                let checkpointDueToTime = lastCheckpoint.duration(to: checkpointClock.now) >= durableCheckpointInterval
                if checkpointDueToBytes || checkpointDueToTime {
                    // Durability ordering is strict: partial fsync first, SQLite FULL checkpoint second.
                    try POSIXFile.synchronize(descriptor: destinationDescriptor, path: partial.path)
                    journal.bytesCopied = copied
                    journal.state = .copying
                    journal.updatedAt = Date()
                    try await store.updateItem(journal)
                    lastDurableOffset = copied
                    lastCheckpoint = checkpointClock.now
                    hooks.afterDurableCheckpoint?(copied)
                }
            }
            try POSIXFile.synchronize(descriptor: destinationDescriptor, path: partial.path)
            journal.bytesCopied = copied
            journal.state = .partialWritten
            journal.updatedAt = Date()
            try await store.updateItem(journal)
            if copied != lastDurableOffset { hooks.afterDurableCheckpoint?(copied) }
            guard Darwin.close(destinationDescriptor) == 0 else {
                destinationDescriptor = -1
                throw UMISCoreError.posix(operation: "close partial", code: errno, path: partial.path)
            }
            destinationDescriptor = -1

            let sourceAfter = try POSIXFile.fingerprint(descriptor: sourceDescriptor, path: item.sourceURL.path)
            guard sourceBefore == sourceAfter, copied == sourceBefore.byteSize else {
                throw UMISCoreError.sourceChanged(item.sourceURL.path)
            }
            let sourceHash = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = item.expectedContentSHA256, expected.lowercased() != sourceHash {
                throw UMISCoreError.hashMismatch(item.sourceURL.path)
            }
            journal.state = .sourceHashed
            journal.sourceSHA256 = sourceHash
            journal.bytesCopied = copied
            journal.updatedAt = Date()
            try await store.updateItem(journal)

            try hooks.beforeDestinationVerification?(partial)
            let destinationHash = try await StreamingSHA256.hashDestinationFile(
                at: partial,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier,
                chunkSize: chunkSize,
                cancellation: cancellation
            )
            guard destinationHash.byteSize == copied, destinationHash.sha256 == sourceHash else {
                throw UMISCoreError.hashMismatch(partial.path)
            }
            journal.state = .destinationHashed
            journal.destinationSHA256 = destinationHash.sha256
            journal.updatedAt = Date()
            try await store.updateItem(journal)

            // This SQLite write is the durable ownership/commit intent. It precedes the atomic
            // no-replace rename so crash recovery can distinguish and prove every possible commit.
            journal.state = .atomicCommitIntent
            journal.updatedAt = Date()
            try await store.updateItem(journal)
            let destinationAtCommit = try await revalidateDestination(plan.destination)
            guard destinationAtCommit == plan.destination else { throw UMISCoreError.identityChanged }
            try hooks.afterCommitIntentBeforeRename?(item.finalURL)
            try DestinationPathAccess.atomicRenameNoReplace(
                from: partial,
                to: item.finalURL,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            )
            try hooks.afterAtomicRenameBeforeJournalUpdate?(item.finalURL)
            journal.state = .atomicCommitted
            journal.updatedAt = Date()
            try await store.updateItem(journal)
            try hooks.afterAtomicJournalBeforeDirectorySync?(item.finalURL)
            try DestinationPathAccess.synchronizeParent(
                of: item.finalURL,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            )
            try hooks.afterDirectorySyncBeforeReceipt?(item.finalURL)
            let finalFingerprint = try DestinationPathAccess.fingerprint(
                item.finalURL,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            )
            let receipt = DeliveryReceipt(
                itemID: item.id,
                assetID: item.asset.id,
                destinationID: plan.destination.id,
                finalURL: item.finalURL,
                byteSize: copied,
                sourceSHA256: sourceHash,
                destinationSHA256: destinationHash.sha256,
                finalFingerprint: finalFingerprint,
                state: .durableCommitted
            )
            journal.state = .durableCommitted
            journal.receipt = receipt
            journal.updatedAt = Date()
            try hooks.afterReceiptPreparedBeforeJournalUpdate?(item.finalURL)
            try DestinationPathAccess.verifyCommittedFile(
                item.finalURL,
                expectedFingerprint: finalFingerprint,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            )
            try await store.updateItem(journal)
            try hooks.afterDurableReceiptJournalBeforeAudit?(item.finalURL)
            try DestinationPathAccess.verifyCommittedFile(
                item.finalURL,
                expectedFingerprint: finalFingerprint,
                destination: plan.destination,
                sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
            )
            try await store.appendAudit(
                operationID: plan.runID.rawValue,
                event: "item.durableCommitted",
                payload: try StableJSON.encode(receipt)
            )
            return receipt
        } catch {
            var synchronizedOpenPartial = false
            if destinationDescriptor >= 0 {
                if (try? POSIXFile.synchronize(descriptor: destinationDescriptor, path: partial.path)) != nil {
                    synchronizedOpenPartial = true
                }
                Darwin.close(destinationDescriptor)
            }
            if synchronizedOpenPartial,
               let durableSize = try? DestinationPathAccess.fingerprint(
                   partial,
                   destination: plan.destination,
                   sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
               ).byteSize {
                // Only publish an offset after its preceding partial-file fsync succeeded.
                journal.bytesCopied = durableSize
            }
            if journal.state != .atomicCommitted
                && journal.state != .atomicCommitIntent
                && journal.state != .destinationHashed
                && journal.state != .durableCommitted {
                journal.state = isCancellation(error) ? .cancelled : .failed
            }
            journal.error = String(describing: error)
            journal.updatedAt = Date()
            try? await store.updateItem(journal)
            throw normalizeCancellation(error)
        }
    }

    private func revalidateDestination(
        _ expected: DestinationIdentity
    ) async throws -> DestinationIdentity {
        if let destinationRevalidator {
            return try await destinationRevalidator(expected)
        }
        return try DestinationIdentityResolver().revalidate(expected)
    }

    private func verifyExisting(
        item: IngestPlanItem,
        plan: IngestPlan,
        journal: JournalItemRecord,
        cancellation: OperationCancellation?
    ) async throws -> DeliveryReceipt {
        let sourceHash = try await StreamingSHA256.hashFile(
            at: item.sourceURL,
            expectedFingerprint: item.expectedSourceFingerprint,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
        if let expected = item.expectedContentSHA256, expected.lowercased() != sourceHash.sha256 {
            throw UMISCoreError.hashMismatch(item.sourceURL.path)
        }
        let destinationHash = try await StreamingSHA256.hashDestinationFile(
            at: item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
        guard sourceHash.byteSize == destinationHash.byteSize, sourceHash.sha256 == destinationHash.sha256 else {
            var failed = journal
            failed.state = .conflict
            failed.sourceSHA256 = sourceHash.sha256
            failed.destinationSHA256 = destinationHash.sha256
            failed.error = "Existing destination differs"
            try await store.updateItem(failed)
            throw UMISCoreError.hashMismatch(item.finalURL.path)
        }
        try DestinationPathAccess.synchronizeParent(
            of: item.finalURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        )
        let receipt = DeliveryReceipt(
            itemID: item.id,
            assetID: item.asset.id,
            destinationID: plan.destination.id,
            finalURL: item.finalURL,
            byteSize: sourceHash.byteSize,
            sourceSHA256: sourceHash.sha256,
            destinationSHA256: destinationHash.sha256,
            finalFingerprint: destinationHash.fingerprintAfter,
            state: .durableVerifiedExisting
        )
        var completed = journal
        completed.state = .durableVerifiedExisting
        completed.bytesCopied = sourceHash.byteSize
        completed.sourceSHA256 = sourceHash.sha256
        completed.destinationSHA256 = destinationHash.sha256
        completed.receipt = receipt
        completed.error = nil
        completed.updatedAt = Date()
        try DestinationPathAccess.verifyCommittedFile(
            item.finalURL,
            expectedFingerprint: destinationHash.fingerprintAfter,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        )
        try await store.updateItem(completed)
        try await store.appendAudit(
            operationID: plan.runID.rawValue,
            event: "item.durableVerifiedExisting",
            payload: try StableJSON.encode(receipt)
        )
        return receipt
    }

    private func validatePartialPrefix(
        sourceDescriptor: Int32,
        sourceURL: URL,
        partialURL: URL,
        plan: IngestPlan,
        expectedOffset: Int64,
        hasher: inout SHA256,
        cancellation: OperationCancellation?
    ) async throws {
        guard expectedOffset >= 0 else { throw UMISCoreError.invalidPlan("Negative resume offset") }
        let partialDescriptor = try DestinationPathAccess.openReadOnly(
            partialURL,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        )
        defer { Darwin.close(partialDescriptor) }
        let partialFingerprint = try POSIXFile.fingerprint(descriptor: partialDescriptor, path: partialURL.path)
        guard partialFingerprint.byteSize == expectedOffset else {
            throw UMISCoreError.hashMismatch("Partial size differs from journal: \(partialURL.path)")
        }
        var remaining = expectedOffset
        var sourceBuffer = [UInt8](repeating: 0, count: chunkSize)
        var partialBuffer = [UInt8](repeating: 0, count: chunkSize)
        while remaining > 0 {
            try Task.checkCancellation()
            try await cancellation?.check()
            let requested = min(chunkSize, Int(remaining))
            let sourceRead = sourceBuffer.withUnsafeMutableBytes { Darwin.read(sourceDescriptor, $0.baseAddress, requested) }
            let partialRead = partialBuffer.withUnsafeMutableBytes { Darwin.read(partialDescriptor, $0.baseAddress, requested) }
            guard sourceRead == requested, partialRead == requested else {
                throw UMISCoreError.hashMismatch("Unable to validate partial prefix: \(partialURL.path)")
            }
            guard sourceBuffer[0 ..< requested].elementsEqual(partialBuffer[0 ..< requested]) else {
                throw UMISCoreError.hashMismatch("Partial content differs from source: \(partialURL.path)")
            }
            hasher.update(data: Data(sourceBuffer[0 ..< requested]))
            remaining -= Int64(requested)
        }
        _ = sourceURL
    }
}

enum StableJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
}

private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case UMISCoreError.cancelled = error { return true }
    return false
}

private func normalizeCancellation(_ error: Error) -> Error {
    isCancellation(error) ? UMISCoreError.cancelled : error
}
