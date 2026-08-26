import Foundation

/// The level of storage identity proof required at a call site. Copy-grade identity permits a
/// stable, writable network mount, while erase-grade additionally requires a product-approved
/// durability profile for network storage.
public enum DestinationIdentityAssurance: Sendable {
    case copyGrade
    case eraseGrade
}

/// Product-controlled boundary for network durability certification. Caller-provided strings are
/// never trusted merely because they are non-empty. No network profile is certified in this build;
/// a future signed profile verifier can add identifiers here without weakening existing plans.
public enum DestinationDurabilityProfileRegistry {
    public static let approvedNetworkEraseProfileIDs: Set<String> = []

    public static func isApprovedForErase(_ profileID: String?) -> Bool {
        guard let profileID else { return false }
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && approvedNetworkEraseProfileIDs.contains(normalized)
    }
}

public struct DestinationIdentityResolver: Sendable {
    public init() {}

    public func resolve(
        rootURL: URL,
        destinationID: DestinationID = DestinationID(),
        mountGeneration: UUID? = nil,
        networkMountLifecycleWitness: NetworkMountLifecycleWitness? = nil,
        durabilityProfileID: String? = nil,
        backingEvidence: DestinationBackingEvidence? = nil
    ) throws -> DestinationIdentity {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UMISCoreError.invalidPath("Destination root does not exist or is not a directory")
        }
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .fileResourceIdentifierKey,
            .volumeURLKey,
        ]
        let values = try root.resourceValues(forKeys: keys)
        guard let fileSystem = values.volumeLocalizedFormatDescription, !fileSystem.isEmpty,
              let isLocal = values.volumeIsLocal,
              let isInternal = values.volumeIsInternal,
              let isReadOnly = values.volumeIsReadOnly,
              values.fileResourceIdentifier != nil else {
            throw UMISCoreError.eraseNotEligible("Destination filesystem identity is incomplete")
        }
        let rootFingerprint = try FileFingerprint.capture(at: root)
        let rootIdentifier = try StableDigest.encode([
            String(rootFingerprint.device),
            String(rootFingerprint.inode),
        ])
        let isNetwork = !isLocal
        let resolvedMountGeneration: UUID
        let networkAuthorityID: UUID?
        if isNetwork {
            guard let witness = networkMountLifecycleWitness,
                  mountGeneration == nil || mountGeneration == witness.generation else {
                throw UMISCoreError.eraseNotEligible(
                    "Network destination requires a fresh app mount-lifecycle witness"
                )
            }
            resolvedMountGeneration = witness.generation
            networkAuthorityID = witness.authorityID
        } else {
            guard networkMountLifecycleWitness == nil else {
                throw UMISCoreError.identityChanged
            }
            resolvedMountGeneration = mountGeneration ?? UUID()
            networkAuthorityID = nil
        }
        let volumeIdentifier: String
        if let volumeUUID = values.volumeUUIDString, !volumeUUID.isEmpty {
            volumeIdentifier = volumeUUID
        } else if isNetwork, let volumeRoot = values.volume {
            // Some SMB/NFS implementations expose no UUID. This copy-grade identifier remains
            // bound to the mounted volume URL, filesystem, and POSIX device. It never grants
            // erase-grade durability without a product-approved profile and fresh generation.
            volumeIdentifier = "network:" + (try StableDigest.encode([
                volumeRoot.standardizedFileURL.path.precomposedStringWithCanonicalMapping,
                fileSystem,
                String(rootFingerprint.device),
            ]))
        } else {
            throw UMISCoreError.eraseNotEligible("Local destination volume UUID is unavailable")
        }
        let resolvedBackingEvidence: DestinationBackingEvidence
        if let backingEvidence {
            resolvedBackingEvidence = backingEvidence
        } else if isNetwork {
            resolvedBackingEvidence = DestinationBackingEvidence(
                kind: .networkMount,
                provenance: .networkMountLifecycle,
                backingStoreIdentifier: volumeIdentifier
            )
        } else if isInternal {
            resolvedBackingEvidence = DestinationBackingEvidence(
                kind: .physicalDevice,
                provenance: .foundationInternalVolume,
                backingStoreIdentifier: volumeIdentifier
            )
        } else {
            // Foundation cannot reliably distinguish an external physical disk from a mounted disk
            // image/virtual block device. The app must supply DA + diskutil evidence to enable erase.
            resolvedBackingEvidence = .unknown
        }
        let identity = DestinationIdentity(
            id: destinationID,
            rootURL: root,
            volumeIdentifier: volumeIdentifier,
            fileSystem: fileSystem,
            rootFileIdentifier: rootIdentifier,
            volumeDeviceIdentifier: rootFingerprint.device,
            mountGeneration: resolvedMountGeneration,
            networkMountLifecycleAuthorityID: networkAuthorityID,
            isNetwork: isNetwork,
            isWritable: !isReadOnly,
            durabilityProfileID: durabilityProfileID,
            backingEvidence: resolvedBackingEvidence
        )
        guard identity.hasCopyGradeIdentity else {
            throw UMISCoreError.eraseNotEligible("Destination is read-only or lacks stable copy identity")
        }
        return identity
    }

    public func revalidate(
        _ expected: DestinationIdentity,
        freshNetworkMountLifecycleWitness: NetworkMountLifecycleWitness? = nil
    ) throws -> DestinationIdentity {
        if expected.isNetwork {
            guard let witness = freshNetworkMountLifecycleWitness else {
                throw UMISCoreError.eraseNotEligible(
                    "Fresh network mount lifecycle evidence is required at every I/O boundary"
                )
            }
            try NetworkMountLifecycleValidator.validate(expected: expected, freshWitness: witness)
        } else if freshNetworkMountLifecycleWitness != nil {
            throw UMISCoreError.identityChanged
        }
        let current = try resolve(
            rootURL: expected.rootURL,
            destinationID: expected.id,
            mountGeneration: expected.mountGeneration,
            networkMountLifecycleWitness: freshNetworkMountLifecycleWitness,
            durabilityProfileID: expected.durabilityProfileID,
            backingEvidence: expected.backingEvidence
        )
        guard current == expected else { throw UMISCoreError.identityChanged }
        return current
    }
}

public enum NetworkMountLifecycleValidator {
    public static func validate(
        expected: DestinationIdentity,
        freshWitness: NetworkMountLifecycleWitness
    ) throws {
        guard expected.isNetwork,
              expected.networkMountLifecycleAuthorityID == freshWitness.authorityID,
              expected.mountGeneration == freshWitness.generation,
              expected.backingEvidence.kind == .networkMount,
              expected.backingEvidence.provenance == .networkMountLifecycle else {
            throw UMISCoreError.identityChanged
        }
    }
}

/// Proves that copied data is durable on storage independent from the removable source. A mere
/// different folder/path is never sufficient: local volumes require both UUID and POSIX device proof.
public enum VolumeIndependenceValidator {
    public static func validate(
        source: VolumeIdentity,
        destination: DestinationIdentity,
        assurance: DestinationIdentityAssurance = .eraseGrade
    ) throws {
        switch assurance {
        case .copyGrade:
            guard destination.hasCopyGradeIdentity else {
                throw UMISCoreError.eraseNotEligible("Destination identity is not copy-grade")
            }
        case .eraseGrade:
            guard destination.hasEraseGradeIdentity else {
                throw UMISCoreError.eraseNotEligible(
                    "Destination identity is not erase-grade; network storage requires a product-approved durability profile"
                )
            }
        }
        guard !source.isNetwork, !source.isDiskImage else {
            throw UMISCoreError.eraseNotEligible("Erase source must be a local physical volume")
        }
        if let sourceRoot = source.mountURL {
            let sourcePath = sourceRoot.standardizedFileURL.path
            let destinationPath = destination.rootURL.standardizedFileURL.path
            let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePrefix) {
                throw UMISCoreError.eraseNotEligible("Destination is located on the source card")
            }
        } else {
            throw UMISCoreError.eraseNotEligible("Source mount identity is unavailable")
        }

        // A local removable card is physically independent from a network destination. Network
        // destinations have their own durability-profile and mount-generation requirements.
        if destination.isNetwork { return }

        guard let sourceUUID = source.volumeUUID,
              let destinationUUIDString = destination.volumeIdentifier,
              let destinationUUID = UUID(uuidString: destinationUUIDString),
              let sourceDevice = source.volumeDeviceIdentifier,
              let destinationDevice = destination.volumeDeviceIdentifier else {
            throw UMISCoreError.eraseNotEligible(
                "Unable to prove that source and destination are different physical volumes"
            )
        }
        guard sourceUUID != destinationUUID, sourceDevice != destinationDevice else {
            throw UMISCoreError.eraseNotEligible(
                "Source card and destination resolve to the same physical volume"
            )
        }
    }
}
