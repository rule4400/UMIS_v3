import Darwin
import Foundation

public struct CatalogHighWaterMark: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let catalogID: UUID
    public let acceptedAuthorityID: UUID
    public let authorityEpoch: UUID
    public let highestRevision: UInt64
    public let acceptedPayloadDigest: SHA256Value
    public let trustedCatalogKeyID: String
    public let acceptedHandoffChainDigest: SHA256Value?

    public init(
        projectID: UUID,
        catalogID: UUID,
        acceptedAuthorityID: UUID,
        authorityEpoch: UUID,
        highestRevision: UInt64,
        acceptedPayloadDigest: SHA256Value,
        trustedCatalogKeyID: String,
        acceptedHandoffChainDigest: SHA256Value? = nil
    ) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.acceptedAuthorityID = acceptedAuthorityID
        self.authorityEpoch = authorityEpoch
        self.highestRevision = highestRevision
        self.acceptedPayloadDigest = acceptedPayloadDigest
        self.trustedCatalogKeyID = trustedCatalogKeyID
        self.acceptedHandoffChainDigest = acceptedHandoffChainDigest
    }
}

public enum SnapshotAcceptance: Equatable, Sendable {
    case applied(CatalogVersionRef)
    case replay(CatalogVersionRef)
}

public enum SceneCatalogAcceptanceError: Error, Equatable, Sendable {
    case revisionRollback(received: UInt64, highestAccepted: UInt64)
    case splitBrain(revision: UInt64)
    case checkpointTrustMismatch
    case cachedSnapshotConflict
}

public enum DurableStorageError: Error, Equatable, Sendable {
    case invalidFileName
    case corruptEnvelope
    case checksumMismatch
    case io(operation: String, code: Int32)
}

/// File-backed, verified scene snapshot storage.
///
/// The high-water checkpoint is deliberately a different file from the cache.
/// Removing a damaged snapshot therefore does not reset rollback protection.
/// Callers should place `directoryURL` in Application Support with device-only
/// permissions and must never expose "clear cache" as checkpoint deletion.
public actor AtomicVerifiedSnapshotStore {
    public static let defaultSnapshotFileName = "scene-catalog.snapshot"
    public static let defaultCheckpointFileName = "scene-catalog.high-water"

    private let trust: SceneCatalogTrust
    private let snapshotFile: AtomicRecordFile
    private let checkpointFile: AtomicRecordFile
    private var checkpoint: CatalogHighWaterMark?
    private var current: VerifiedSceneCatalogSnapshot?

    public init(
        directoryURL: URL,
        trust: SceneCatalogTrust,
        snapshotFileName: String = AtomicVerifiedSnapshotStore.defaultSnapshotFileName,
        checkpointFileName: String = AtomicVerifiedSnapshotStore.defaultCheckpointFileName
    ) throws {
        guard Self.isSafeFileName(snapshotFileName),
              Self.isSafeFileName(checkpointFileName),
              snapshotFileName != checkpointFileName else {
            throw DurableStorageError.invalidFileName
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.trust = trust
        self.snapshotFile = AtomicRecordFile(url: directoryURL.appendingPathComponent(snapshotFileName))
        self.checkpointFile = AtomicRecordFile(url: directoryURL.appendingPathComponent(checkpointFileName))

        let loadedCheckpoint: CatalogHighWaterMark? = try checkpointFile.read(
            CatalogHighWaterMark.self
        )
        if let loadedCheckpoint {
            guard loadedCheckpoint.projectID == trust.projectID,
                  loadedCheckpoint.catalogID == trust.catalogID,
                  loadedCheckpoint.acceptedAuthorityID == trust.authorityID,
                  loadedCheckpoint.authorityEpoch == trust.authorityEpoch,
                  loadedCheckpoint.trustedCatalogKeyID == trust.trustedCatalogKeyID else {
                throw SceneCatalogAcceptanceError.checkpointTrustMismatch
            }
        }

        var effectiveCheckpoint = loadedCheckpoint
        var loadedCurrent: VerifiedSceneCatalogSnapshot?
        if let envelope = try snapshotFile.read(SignedSceneCatalogSnapshot.self) {
            let verified = try SceneCatalogVerifier.verify(envelope, trust: trust)
            if let loadedCheckpoint {
                if verified.version.revision < loadedCheckpoint.highestRevision {
                    // A restored or stale cache must not become visible. Keep the
                    // checkpoint and wait for a fresh full snapshot.
                    loadedCurrent = nil
                } else if verified.version.revision == loadedCheckpoint.highestRevision {
                    guard verified.version.payloadDigest == loadedCheckpoint.acceptedPayloadDigest else {
                        throw SceneCatalogAcceptanceError.cachedSnapshotConflict
                    }
                    loadedCurrent = verified
                } else {
                    // Crash recovery: snapshot is written before its checkpoint.
                    // Its signature is valid, so safely advance the checkpoint.
                    let recovered = Self.makeCheckpoint(verified, trust: trust)
                    try checkpointFile.write(recovered)
                    effectiveCheckpoint = recovered
                    loadedCurrent = verified
                }
            } else {
                let recovered = Self.makeCheckpoint(verified, trust: trust)
                try checkpointFile.write(recovered)
                effectiveCheckpoint = recovered
                loadedCurrent = verified
            }
        }
        self.checkpoint = effectiveCheckpoint
        self.current = loadedCurrent
    }

    public func accept(_ snapshot: SignedSceneCatalogSnapshot) throws -> SnapshotAcceptance {
        let verified = try SceneCatalogVerifier.verify(snapshot, trust: trust)
        if let checkpoint {
            if verified.version.revision < checkpoint.highestRevision {
                throw SceneCatalogAcceptanceError.revisionRollback(
                    received: verified.version.revision,
                    highestAccepted: checkpoint.highestRevision
                )
            }
            if verified.version.revision == checkpoint.highestRevision {
                guard verified.version.payloadDigest == checkpoint.acceptedPayloadDigest else {
                    throw SceneCatalogAcceptanceError.splitBrain(revision: verified.version.revision)
                }
                return .replay(verified.version)
            }
        }

        let nextCheckpoint = Self.makeCheckpoint(verified, trust: trust)
        // Fail-safe order: a newer verified cache may exist briefly without an
        // advanced checkpoint, never the opposite. Initialization recovers it.
        try snapshotFile.write(snapshot)
        try checkpointFile.write(nextCheckpoint)
        checkpoint = nextCheckpoint
        current = verified
        return .applied(verified.version)
    }

    public func currentSnapshot() -> VerifiedSceneCatalogSnapshot? { current }
    public func highWaterMark() -> CatalogHighWaterMark? { checkpoint }

    private static func makeCheckpoint(
        _ snapshot: VerifiedSceneCatalogSnapshot,
        trust: SceneCatalogTrust
    ) -> CatalogHighWaterMark {
        CatalogHighWaterMark(
            projectID: snapshot.version.projectID,
            catalogID: snapshot.version.catalogID,
            acceptedAuthorityID: snapshot.version.authorityID,
            authorityEpoch: snapshot.version.authorityEpoch,
            highestRevision: snapshot.version.revision,
            acceptedPayloadDigest: snapshot.version.payloadDigest,
            trustedCatalogKeyID: trust.trustedCatalogKeyID
        )
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

private struct AtomicRecordEnvelope: Codable, Sendable {
    let storageVersion: UInt16
    let payload: Data
    let payloadSHA256: SHA256Value
}

struct AtomicRecordFile: Sendable {
    let url: URL

    func read<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let encoded = try Data(contentsOf: url, options: [.mappedIfSafe])
        let envelope: AtomicRecordEnvelope
        do {
            envelope = try JSONDecoder().decode(AtomicRecordEnvelope.self, from: encoded)
        } catch {
            throw DurableStorageError.corruptEnvelope
        }
        guard envelope.storageVersion == 1 else {
            throw DurableStorageError.corruptEnvelope
        }
        guard SHA256Value.hash(envelope.payload) == envelope.payloadSHA256 else {
            throw DurableStorageError.checksumMismatch
        }
        do {
            return try JSONDecoder().decode(type, from: envelope.payload)
        } catch {
            throw DurableStorageError.corruptEnvelope
        }
    }

    func write<Value: Encodable>(_ value: Value) throws {
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try payloadEncoder.encode(value)
        let envelope = AtomicRecordEnvelope(
            storageVersion: 1,
            payload: payload,
            payloadSHA256: .hash(payload)
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.atomicWrite(envelopeEncoder.encode(envelope), to: url)
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            let temporaryDescriptor = Darwin.open(temporary.path, O_RDONLY | O_NOFOLLOW)
            guard temporaryDescriptor >= 0 else {
                throw DurableStorageError.io(operation: "open temporary", code: errno)
            }
            defer { Darwin.close(temporaryDescriptor) }
            guard Darwin.fsync(temporaryDescriptor) == 0 else {
                throw DurableStorageError.io(operation: "fsync temporary", code: errno)
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw DurableStorageError.io(operation: "rename", code: errno)
            }
            let directoryDescriptor = Darwin.open(
                destination.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY
            )
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                _ = Darwin.close(directoryDescriptor)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
