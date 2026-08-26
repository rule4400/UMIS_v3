import CryptoKit
import Darwin
import Foundation

/// Mount-session identity registry populated by the app's Disk Arbitration callback adapter.
/// A BSD name or display name is never accepted as the registry key.
public actor VolumeIdentityRegistry {
    private var identities: [SourceVolumeID: VolumeIdentity] = [:]

    public init() {}

    public func registerAppearance(_ identity: VolumeIdentity) {
        identities[identity.id] = identity
    }

    public func update(_ identity: VolumeIdentity) throws {
        guard let previous = identities[identity.id],
              previous.arrivalGeneration == identity.arrivalGeneration else {
            throw UMISCoreError.identityChanged
        }
        identities[identity.id] = identity
    }

    public func registerDisappearance(sourceVolumeID: SourceVolumeID, arrivalGeneration: UUID) {
        guard identities[sourceVolumeID]?.arrivalGeneration == arrivalGeneration else { return }
        identities.removeValue(forKey: sourceVolumeID)
    }

    public func current(sourceVolumeID: SourceVolumeID) throws -> VolumeIdentity {
        guard let identity = identities[sourceVolumeID] else { throw UMISCoreError.identityChanged }
        return identity
    }

    public func contains(sourceVolumeID: SourceVolumeID) -> Bool {
        identities[sourceVolumeID] != nil
    }
}

public struct DiskArbitrationIdentityEvidence: Sendable, Hashable {
    public var mediaRegistryEntryID: UInt64
    public var parentChainDigest: String
    public var isEjectable: Bool
    public var physicalMediaEvidence: PhysicalMediaEvidence

    public init(
        mediaRegistryEntryID: UInt64,
        parentChainDigest: String,
        isEjectable: Bool,
        physicalMediaEvidence: PhysicalMediaEvidence = .unknown
    ) {
        self.mediaRegistryEntryID = mediaRegistryEntryID
        self.parentChainDigest = parentChainDigest
        self.isEjectable = isEjectable
        self.physicalMediaEvidence = physicalMediaEvidence
    }
}

/// Converts a Disk Arbitration appearance into a normalized identity. It cross-checks URL resource
/// values, `diskutil info -plist`, and whole-disk topology. Missing safety fields fail closed.
public actor DiskutilIdentityResolver {
    private let runner: any ProcessRunning
    private let diskutilURL: URL

    public init(
        runner: any ProcessRunning = POSIXProcessRunner(),
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    ) {
        self.runner = runner
        self.diskutilURL = diskutilURL
    }

    public func resolve(
        mountURL: URL,
        sourceID: SourceVolumeID = SourceVolumeID(),
        arrivalGeneration: UUID = UUID(),
        diskArbitrationEvidence: DiskArbitrationIdentityEvidence
    ) async throws -> VolumeIdentity {
        guard diskArbitrationEvidence.physicalMediaEvidence.hasTrustedCameraCardProof else {
            throw UMISCoreError.unsafeEraseTarget(
                "Disk Arbitration/IOKit evidence does not prove an eligible Secure Digital camera card"
            )
        }
        let mountURL = mountURL.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey,
            .volumeUUIDStringKey,
            .volumeTotalCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeNameKey,
        ]
        let values = try mountURL.resourceValues(forKeys: keys)
        guard values.volumeIsLocal == true,
              let resourceInternal = values.volumeIsInternal,
              let resourceRemovable = values.volumeIsRemovable,
              let resourceReadOnly = values.volumeIsReadOnly,
              let resourceCapacity = values.volumeTotalCapacity,
              let resourceVolumeUUIDString = values.volumeUUIDString,
              let resourceVolumeUUID = UUID(uuidString: resourceVolumeUUIDString) else {
            throw UMISCoreError.unsafeEraseTarget("Volume resource values are incomplete or identify a non-local volume")
        }
        let infoResult = try await runner.run(ProcessRequest(
            executableURL: diskutilURL,
            arguments: ["info", "-plist", mountURL.path],
            timeout: 10,
            timeoutAction: .terminateProcessGroup,
            maximumCapturedOutputBytes: 1_048_576
        ))
        guard !infoResult.timedOut, infoResult.exitCode == 0 else {
            throw UMISCoreError.backendFailure("diskutil info -plist failed while resolving a volume")
        }
        let info = try DiskutilInfo(data: infoResult.standardOutput)
        guard info.deviceIdentifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              info.parentWholeDisk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              info.totalSize == Int64(resourceCapacity),
              info.internalMedia == resourceInternal,
              info.removableMedia == resourceRemovable,
              info.writable == !resourceReadOnly,
              info.volumeUUID == resourceVolumeUUID,
              info.mountPoint.map({ URL(fileURLWithPath: $0).standardizedFileURL == mountURL }) == true,
              info.virtualOrPhysical?.caseInsensitiveCompare("Physical") == .orderedSame,
              info.diskImage == false else {
            throw UMISCoreError.identityChanged
        }
        let topology = try await resolveTopology(wholeDisk: info.parentWholeDisk)
        guard topology.partitionIdentifiers == [info.deviceIdentifier] else {
            throw UMISCoreError.unsafeEraseTarget("Only a single leaf partition is supported")
        }
        let mountFingerprint = try FileFingerprint.capture(at: mountURL)
        let identity = VolumeIdentity(
            id: sourceID,
            volumeUUID: info.volumeUUID,
            mediaUUID: info.mediaUUID,
            mediaRegistryEntryID: diskArbitrationEvidence.mediaRegistryEntryID,
            parentChainDigest: diskArbitrationEvidence.parentChainDigest,
            bsdName: info.deviceIdentifier,
            wholeDiskBSDName: info.parentWholeDisk,
            mountURL: mountURL,
            displayName: values.volumeName ?? info.volumeName ?? mountURL.lastPathComponent,
            capacityBytes: info.totalSize,
            volumeDeviceIdentifier: mountFingerprint.device,
            physicalMediaEvidence: diskArbitrationEvidence.physicalMediaEvidence,
            fileSystem: info.fileSystem ?? values.volumeLocalizedFormatDescription,
            isInternal: info.internalMedia,
            isRemovable: info.removableMedia,
            isEjectable: values.volumeIsEjectable ?? diskArbitrationEvidence.isEjectable,
            isWritable: info.writable,
            isNetwork: false,
            isDiskImage: false,
            partitionCount: topology.partitionIdentifiers.count,
            arrivalGeneration: arrivalGeneration,
            identityStrength: .strongForCurrentInsertion
        )
        guard !identity.isInternal, identity.isRemovable, identity.isWritable, identity.isEjectable else {
            throw UMISCoreError.unsafeEraseTarget("Resolved media is internal, non-removable, read-only, or non-ejectable")
        }
        return identity
    }

    private func resolveTopology(wholeDisk: String) async throws -> DiskTopology {
        let result = try await runner.run(ProcessRequest(
            executableURL: diskutilURL,
            arguments: ["list", "-plist", wholeDisk],
            timeout: 10,
            timeoutAction: .terminateProcessGroup,
            maximumCapturedOutputBytes: 1_048_576
        ))
        guard !result.timedOut, result.exitCode == 0 else {
            throw UMISCoreError.backendFailure("diskutil list -plist failed")
        }
        let object = try PropertyListSerialization.propertyList(from: result.standardOutput, options: [], format: nil)
        guard let dictionary = object as? [String: Any],
              let disks = dictionary["AllDisksAndPartitions"] as? [[String: Any]],
              let whole = disks.first(where: { $0["DeviceIdentifier"] as? String == wholeDisk }),
              let partitions = whole["Partitions"] as? [[String: Any]] else {
            throw UMISCoreError.backendFailure("diskutil list plist omitted partition topology")
        }
        let identifiers = partitions.compactMap { $0["DeviceIdentifier"] as? String }
        guard identifiers.count == partitions.count else {
            throw UMISCoreError.backendFailure("Partition topology contained an unidentified entry")
        }
        return DiskTopology(partitionIdentifiers: identifiers)
    }
}

private struct DiskTopology: Sendable {
    var partitionIdentifiers: [String]
}

public enum RetainedMediaClaimPurpose: String, Codable, Hashable, Sendable {
    case erase
    case eject
}

public enum RetainedMediaClaimAssurance: String, Codable, Hashable, Sendable {
    /// The provider retains an exclusive DADisk/IOMedia object (or an equivalently strong native
    /// object) across unmount/revalidation and the immediately following destructive call.
    case retainedDiskArbitrationObject
    /// Deterministic test doubles only. Production backends reject this assurance level.
    case deterministicTestDouble
}

/// Provider-owned retained claim. The UUID is only a lookup key; the provider must keep the native
/// object alive and exclusive. A BSD name, volume path, or cached registry record is insufficient.
public struct RetainedMediaClaim: Sendable, Hashable {
    public let handleID: UUID
    public let purpose: RetainedMediaClaimPurpose
    public let expectedIdentityDigest: String
    public let freshlyRevalidatedIdentity: VolumeIdentity
    public let evidenceDigest: String
    public let claimedAt: Date
    public let expiresAt: Date

    public init(
        handleID: UUID = UUID(),
        purpose: RetainedMediaClaimPurpose,
        expectedIdentityDigest: String,
        freshlyRevalidatedIdentity: VolumeIdentity,
        evidenceDigest: String,
        claimedAt: Date = Date(),
        expiresAt: Date
    ) throws {
        let normalizedEvidence = evidenceDigest.lowercased()
        guard expectedIdentityDigest.utf8.count == 64,
              normalizedEvidence.utf8.count == 64,
              normalizedEvidence.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }),
              expiresAt > claimedAt else {
            throw UMISCoreError.invalidPlan("Invalid retained-media claim evidence or lifetime")
        }
        self.handleID = handleID
        self.purpose = purpose
        self.expectedIdentityDigest = expectedIdentityDigest
        self.freshlyRevalidatedIdentity = freshlyRevalidatedIdentity
        self.evidenceDigest = normalizedEvidence
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
    }
}

/// Native claim boundary used by erase and eject. For `.erase`, `acquire` must claim first, unmount
/// while the claim remains retained, then obtain fresh DA/IOKit/registry/topology evidence. For
/// `.eject`, it must retain the same whole-media object and freshly revalidate it. The provider must
/// never reconstruct authority from a BSD name after the native object has been released.
public protocol RetainedMediaClaimProviding: Sendable {
    var assurance: RetainedMediaClaimAssurance { get }
    func acquire(
        expectedIdentity: VolumeIdentity,
        purpose: RetainedMediaClaimPurpose,
        timeout: TimeInterval
    ) async throws -> RetainedMediaClaim
    func revalidate(_ claim: RetainedMediaClaim) async throws -> VolumeIdentity
    /// Ejects by calling DADiskEject (or an equivalently strong API) on the retained native object.
    /// Resolving a fresh command target from the claim's BSD name is expressly forbidden.
    func ejectRetained(_ claim: RetainedMediaClaim, timeout: TimeInterval) async throws
    func release(_ claim: RetainedMediaClaim) async
}

public actor DiskutilCardEraseBackend: CardEraseBackend {
    /// This build does not bundle a formatter that executes on a retained opaque media handle.
    /// UI code must keep card initialization unavailable even when a development feature flag is set.
    public nonisolated static let isBundledProductionBoundaryAvailable = false

    private struct ActiveClaim: Sendable {
        var nativeClaim: RetainedMediaClaim
        var preparedTarget: PreparedCardEraseTarget
    }

    private let registry: VolumeIdentityRegistry
    private let runner: any ProcessRunning
    private let claimProvider: (any RetainedMediaClaimProviding)?
    private let testingOnlyAllowsTestDouble: Bool
    private let diskutilURL: URL
    private let infoTimeout: TimeInterval
    private let eraseTimeout: TimeInterval
    private let postFormatTimeout: TimeInterval
    private var activeClaims: [UUID: ActiveClaim] = [:]
    /// A destructive helper timeout is deliberately not released. The provider retains the native
    /// claim until process exit/manual reconciliation, while the durable store quarantines the card.
    private var indeterminateClaims: [UUID: RetainedMediaClaim] = [:]

    public init(
        registry: VolumeIdentityRegistry,
        runner: any ProcessRunning = POSIXProcessRunner(),
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil"),
        infoTimeout: TimeInterval = 10,
        eraseTimeout: TimeInterval = 120,
        postFormatTimeout: TimeInterval = 30
    ) {
        self.registry = registry
        self.runner = runner
        claimProvider = nil
        testingOnlyAllowsTestDouble = false
        self.diskutilURL = diskutilURL
        self.infoTimeout = infoTimeout
        self.eraseTimeout = eraseTimeout
        self.postFormatTimeout = postFormatTimeout
    }

    init(
        registry: VolumeIdentityRegistry,
        runner: any ProcessRunning,
        testingClaimProvider: any RetainedMediaClaimProviding,
        diskutilURL: URL,
        infoTimeout: TimeInterval = 10,
        eraseTimeout: TimeInterval = 120,
        postFormatTimeout: TimeInterval = 30
    ) {
        self.registry = registry
        self.runner = runner
        claimProvider = testingClaimProvider
        testingOnlyAllowsTestDouble = true
        self.diskutilURL = diskutilURL
        self.infoTimeout = infoTimeout
        self.eraseTimeout = eraseTimeout
        self.postFormatTimeout = postFormatTimeout
    }

    public func currentIdentity(expectedSourceID: SourceVolumeID) async throws -> VolumeIdentity {
        let identity = try await registry.current(sourceVolumeID: expectedSourceID)
        try Self.requireSafeLeaf(identity)
        let info = try await readInfo(bsdName: identity.bsdName!)
        try info.validateBeforeErase(against: identity)
        return identity
    }

    public func prepareDestructiveTarget(
        expectedIdentity: VolumeIdentity,
        timeout: TimeInterval
    ) async throws -> PreparedCardEraseTarget {
        guard testingOnlyAllowsTestDouble else {
            // `diskutil eraseVolume <bsd>` re-resolves the target from a recyclable BSD name. Even
            // with a retained DADisk claim, that is not a call *on the opaque handle*. Until a
            // product-qualified handle-bound formatter exists, production must never reach it.
            throw UMISCoreError.eraseNotEligible(
                "Card initialization is unavailable: no handle-bound native formatter is installed"
            )
        }
        guard let claimProvider else {
            throw UMISCoreError.eraseNotEligible(
                "Card initialization is unavailable: no retained Disk Arbitration claim provider is installed"
            )
        }
        guard claimProvider.assurance == .retainedDiskArbitrationObject
            || testingOnlyAllowsTestDouble else {
            throw UMISCoreError.eraseNotEligible(
                "Card initialization rejected a non-production retained-media claim provider"
            )
        }
        try Self.requireSafeLeaf(expectedIdentity)
        let mountedObservation = try await currentIdentity(expectedSourceID: expectedIdentity.id)
        guard mountedObservation.matchesSameEraseTarget(as: expectedIdentity) else {
            throw UMISCoreError.identityChanged
        }
        let claim = try await claimProvider.acquire(
            expectedIdentity: expectedIdentity,
            purpose: .erase,
            timeout: timeout
        )
        do {
            guard claim.purpose == .erase,
                  claim.expectedIdentityDigest == expectedIdentity.securityDigest,
                  claim.expiresAt > Date() else {
                throw UMISCoreError.identityChanged
            }
            let freshIdentity = try await claimProvider.revalidate(claim)
            guard freshIdentity.matchesSameEraseTarget(as: expectedIdentity),
                  freshIdentity.matchesSameEraseTarget(as: claim.freshlyRevalidatedIdentity) else {
                throw UMISCoreError.identityChanged
            }
            try Self.requireSafeLeaf(freshIdentity)
            let prepared = try PreparedCardEraseTarget(
                handleID: claim.handleID,
                authorizedIdentity: expectedIdentity,
                freshlyRevalidatedIdentity: freshIdentity,
                claimEvidenceDigest: claim.evidenceDigest,
                preparedAt: claim.claimedAt,
                expiresAt: claim.expiresAt
            )
            guard activeClaims[prepared.handleID] == nil,
                  indeterminateClaims[prepared.handleID] == nil else {
                throw UMISCoreError.reusedToken
            }
            activeClaims[prepared.handleID] = ActiveClaim(
                nativeClaim: claim,
                preparedTarget: prepared
            )
            return prepared
        } catch {
            await claimProvider.release(claim)
            throw error
        }
    }

    public func erase(
        preparedTarget: PreparedCardEraseTarget,
        profile: CardFormatProfile,
        authorization: ConsumedEraseCapability
    ) async throws -> CardEraseResult {
        guard let claimProvider,
              let active = activeClaims.removeValue(forKey: preparedTarget.handleID) else {
            throw UMISCoreError.reusedToken
        }
        let expectedIdentity = active.preparedTarget.authorizedIdentity
        guard active.preparedTarget == preparedTarget,
              authorization.expectedIdentityDigest == expectedIdentity.securityDigest,
              authorization.preparedHandleID == preparedTarget.handleID,
              authorization.destructiveHandleDigest == preparedTarget.authorizationBindingDigest else {
            await claimProvider.release(active.nativeClaim)
            throw UMISCoreError.invalidToken
        }
        try Self.requireSafeLeaf(expectedIdentity)
        _ = try CardFormatProfile.validateLabel(profile.label)
        let leaf = preparedTarget.freshlyRevalidatedIdentity.bsdName!
        do {
            let immediatelyFresh = try await claimProvider.revalidate(active.nativeClaim)
            guard immediatelyFresh.matchesSameEraseTarget(
                as: preparedTarget.freshlyRevalidatedIdentity
            ), Date() <= preparedTarget.expiresAt else {
                throw UMISCoreError.identityChanged
            }
        } catch {
            await claimProvider.release(active.nativeClaim)
            throw error
        }

        let erase: ProcessExecutionResult
        do {
            erase = try await runner.run(ProcessRequest(
                executableURL: diskutilURL,
                arguments: ["eraseVolume", profile.fileSystem.rawValue, profile.label, leaf],
                timeout: eraseTimeout,
                // Killing diskutil does not prove that a filesystem operation stopped.
                timeoutAction: .leaveRunningAndReportUnknown
            ))
        } catch {
            await claimProvider.release(active.nativeClaim)
            throw error
        }
        if erase.timedOut {
            indeterminateClaims[preparedTarget.handleID] = active.nativeClaim
            return CardEraseResult(
                outcome: .outcomeUnknown,
                beforeIdentity: expectedIdentity,
                afterIdentity: nil,
                postFormatProbeSucceeded: false
            )
        }
        guard erase.exitCode == 0 else {
            await claimProvider.release(active.nativeClaim)
            throw UMISCoreError.backendFailure("diskutil eraseVolume exited with \(erase.exitCode.map(String.init) ?? "unknown status")")
        }

        // The helper has exited normally. Release the retained claim so the newly formatted volume
        // can remount, then require an independent post-format identity and write/read proof.
        await claimProvider.release(active.nativeClaim)

        guard let after = try await awaitPostFormatIdentity(before: expectedIdentity) else {
            return CardEraseResult(
                outcome: .postFormatValidationFailed,
                beforeIdentity: expectedIdentity,
                afterIdentity: nil,
                postFormatProbeSucceeded: false
            )
        }
        let postInfo = try await readInfo(bsdName: after.bsdName ?? leaf)
        do {
            try postInfo.validateAfterErase(against: after, profile: profile)
            try await performPostFormatProbe(on: after)
            return CardEraseResult(
                outcome: .completed,
                beforeIdentity: expectedIdentity,
                afterIdentity: after,
                postFormatProbeSucceeded: true
            )
        } catch {
            return CardEraseResult(
                outcome: .postFormatValidationFailed,
                beforeIdentity: expectedIdentity,
                afterIdentity: after,
                postFormatProbeSucceeded: false
            )
        }
    }

    public func abandonPreparedTarget(_ preparedTarget: PreparedCardEraseTarget) async {
        guard let claimProvider,
              let active = activeClaims.removeValue(forKey: preparedTarget.handleID) else { return }
        await claimProvider.release(active.nativeClaim)
    }

    private func readInfo(bsdName: String) async throws -> DiskutilInfo {
        guard bsdName.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw UMISCoreError.unsafeEraseTarget("Invalid leaf BSD identifier")
        }
        let result = try await runner.run(ProcessRequest(
            executableURL: diskutilURL,
            arguments: ["info", "-plist", bsdName],
            timeout: infoTimeout,
            timeoutAction: .terminateProcessGroup,
            maximumCapturedOutputBytes: 1_048_576
        ))
        guard !result.timedOut, result.exitCode == 0 else {
            throw UMISCoreError.backendFailure("diskutil info -plist failed")
        }
        return try DiskutilInfo(data: result.standardOutput)
    }

    private func awaitPostFormatIdentity(before: VolumeIdentity) async throws -> VolumeIdentity? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(postFormatTimeout * 1_000)))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let current = try? await registry.current(sourceVolumeID: before.id),
               current.matchesPhysicalContinuityAfterFormat(as: before),
               current.mountURL != nil,
               current.isWritable {
                return current
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func performPostFormatProbe(on identity: VolumeIdentity) async throws {
        guard let root = identity.mountURL else {
            throw UMISCoreError.backendFailure("Formatted volume did not remount")
        }
        try validateNoOldUserData(at: root)
        let probe = root.appendingPathComponent(".umis-format-probe-\(UUID().uuidString)")
        try PathSafety.requireDescendant(probe, of: root)
        let payload = Data("RINKAN-UMIS-FORMAT-PROBE-\(UUID().uuidString)".utf8)
        let descriptor = try POSIXFile.openExclusiveWrite(probe)
        do {
            try payload.withUnsafeBytes {
                try POSIXFile.writeAll(descriptor: descriptor, bytes: $0, path: probe.path)
            }
            try POSIXFile.synchronize(descriptor: descriptor, path: probe.path)
        } catch {
            Darwin.close(descriptor)
            try? POSIXFile.removeIfExists(probe)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            try? POSIXFile.removeIfExists(probe)
            throw UMISCoreError.posix(operation: "close post-format probe", code: errno, path: probe.path)
        }
        let hash = try await StreamingSHA256.hashFile(at: probe)
        let expected = CryptoKit.SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard hash.sha256 == expected, hash.byteSize == payload.count else {
            try? POSIXFile.removeIfExists(probe)
            throw UMISCoreError.hashMismatch(probe.path)
        }
        try POSIXFile.removeIfExists(probe)
        try POSIXFile.synchronizeDirectory(root)
    }

    private func validateNoOldUserData(at root: URL) throws {
        let allowedRootMetadata: Set<String> = [
            ".Spotlight-V100",
            ".fseventsd",
            ".Trashes",
            ".TemporaryItems",
            ".DocumentRevisions-V100",
            ".DS_Store",
            ".VolumeIcon.icns",
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries {
            guard allowedRootMetadata.contains(entry.lastPathComponent) else {
                throw UMISCoreError.backendFailure("Post-format volume still contains a non-system entry")
            }
            if entry.lastPathComponent == ".Trashes" {
                let enumerator = FileManager.default.enumerator(
                    at: entry,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: []
                )
                while let candidate = enumerator?.nextObject() as? URL {
                    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true || values.isSymbolicLink == true {
                        throw UMISCoreError.backendFailure("Post-format Trash contains data")
                    }
                }
            }
        }
    }

    private static func requireSafeLeaf(_ identity: VolumeIdentity) throws {
        guard identity.identityStrength == .strongForCurrentInsertion,
              identity.isCameraCardEraseEligible,
              !identity.isInternal,
              identity.isRemovable,
              identity.isWritable,
              !identity.isNetwork,
              !identity.isDiskImage,
              identity.partitionCount == 1,
              let leaf = identity.bsdName,
              leaf.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              let whole = identity.wholeDiskBSDName,
              whole.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        else {
            throw UMISCoreError.unsafeEraseTarget(
                "Target is not a proven Secure Digital camera card on a strong removable single-leaf volume"
            )
        }
    }
}

struct DiskutilInfo: Sendable {
    var deviceIdentifier: String
    var parentWholeDisk: String
    var totalSize: Int64
    var internalMedia: Bool
    var removableMedia: Bool
    var writable: Bool
    var volumeUUID: UUID?
    var mediaUUID: UUID?
    var fileSystem: String?
    var volumeName: String?
    var mountPoint: String?
    var virtualOrPhysical: String?
    var diskImage: Bool?

    init(data: Data) throws {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any],
              let deviceIdentifier = dictionary["DeviceIdentifier"] as? String,
              let parentWholeDisk = dictionary["ParentWholeDisk"] as? String,
              let total = (dictionary["TotalSize"] as? NSNumber)?.int64Value,
              let internalMedia = dictionary["Internal"] as? Bool,
              let removableMedia = dictionary["RemovableMedia"] as? Bool,
              let writable = dictionary["Writable"] as? Bool else {
            throw UMISCoreError.backendFailure("diskutil info plist omitted a required safety field")
        }
        self.deviceIdentifier = deviceIdentifier
        self.parentWholeDisk = parentWholeDisk
        totalSize = total
        self.internalMedia = internalMedia
        self.removableMedia = removableMedia
        self.writable = writable
        volumeUUID = (dictionary["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:))
        mediaUUID = (dictionary["MediaUUID"] as? String).flatMap(UUID.init(uuidString:))
        fileSystem = dictionary["FilesystemName"] as? String ?? dictionary["FilesystemType"] as? String
        volumeName = dictionary["VolumeName"] as? String
        mountPoint = dictionary["MountPoint"] as? String
        virtualOrPhysical = dictionary["VirtualOrPhysical"] as? String
        diskImage = dictionary["DiskImage"] as? Bool
    }

    func validateBeforeErase(against expected: VolumeIdentity) throws {
        guard deviceIdentifier == expected.bsdName,
              parentWholeDisk == expected.wholeDiskBSDName,
              totalSize == expected.capacityBytes,
              internalMedia == expected.isInternal,
              !internalMedia,
              removableMedia == expected.isRemovable,
              removableMedia,
              writable == expected.isWritable,
              writable else {
            throw UMISCoreError.identityChanged
        }
        if let expectedUUID = expected.volumeUUID, volumeUUID != expectedUUID { throw UMISCoreError.identityChanged }
        if let expectedMediaUUID = expected.mediaUUID, mediaUUID != expectedMediaUUID { throw UMISCoreError.identityChanged }
    }

    func validateAfterErase(against expected: VolumeIdentity, profile: CardFormatProfile) throws {
        guard deviceIdentifier == expected.bsdName,
              parentWholeDisk == expected.wholeDiskBSDName,
              totalSize == expected.capacityBytes,
              !internalMedia,
              removableMedia,
              writable,
              fileSystem?.caseInsensitiveCompare(profile.fileSystem.rawValue) == .orderedSame,
              volumeName == profile.label,
              mountPoint != nil else {
            throw UMISCoreError.backendFailure("Post-format diskutil identity/profile validation failed")
        }
    }
}

extension VolumeIdentity {
    func matchesSameEraseTarget(as other: VolumeIdentity) -> Bool {
        id == other.id
            && arrivalGeneration == other.arrivalGeneration
            && volumeUUID == other.volumeUUID
            && mediaUUID == other.mediaUUID
            && mediaRegistryEntryID == other.mediaRegistryEntryID
            && parentChainDigest == other.parentChainDigest
            && physicalMediaEvidence == other.physicalMediaEvidence
            && bsdName == other.bsdName
            && wholeDiskBSDName == other.wholeDiskBSDName
            && capacityBytes == other.capacityBytes
            && isInternal == other.isInternal
            && isRemovable == other.isRemovable
            && partitionCount == other.partitionCount
    }

    func matchesPhysicalContinuityAfterFormat(as before: VolumeIdentity) -> Bool {
        id == before.id
            && arrivalGeneration == before.arrivalGeneration
            && mediaUUID == before.mediaUUID
            && mediaRegistryEntryID == before.mediaRegistryEntryID
            && parentChainDigest == before.parentChainDigest
            && physicalMediaEvidence == before.physicalMediaEvidence
            && bsdName == before.bsdName
            && wholeDiskBSDName == before.wholeDiskBSDName
            && capacityBytes == before.capacityBytes
            && !isInternal
            && isRemovable
            && partitionCount == 1
    }
}

public actor VolumeIOActivityRegistry {
    private var activityCounts: [SourceVolumeID: Int] = [:]
    private var destructivelyQuiesced: Set<SourceVolumeID> = []
    private var quarantinedAfterUnknownDestructiveOutcome: [SourceVolumeID: String] = [:]
    private var physicalKeyBySourceVolumeID: [SourceVolumeID: PhysicalMediaQuarantineKey] = [:]
    private var quarantinedPhysicalKeys: [PhysicalMediaQuarantineKey: String] = [:]

    public init() {}

    public func begin(sourceVolumeID: SourceVolumeID) throws {
        guard !destructivelyQuiesced.contains(sourceVolumeID),
              quarantinedAfterUnknownDestructiveOutcome[sourceVolumeID] == nil,
              physicalKeyBySourceVolumeID[sourceVolumeID].map({ quarantinedPhysicalKeys[$0] == nil }) ?? true else {
            throw UMISCoreError.eraseNotEligible(
                "Source volume is reserved or quarantined by a destructive action"
            )
        }
        activityCounts[sourceVolumeID, default: 0] += 1
    }

    public func end(sourceVolumeID: SourceVolumeID) {
        let newValue = max(0, (activityCounts[sourceVolumeID] ?? 0) - 1)
        if newValue == 0 { activityCounts.removeValue(forKey: sourceVolumeID) }
        else { activityCounts[sourceVolumeID] = newValue }
    }

    public func isActive(sourceVolumeID: SourceVolumeID) -> Bool {
        (activityCounts[sourceVolumeID] ?? 0) > 0
    }

    /// Acquires and releases an activity lease as one actor-owned operation. The `defer` runs for
    /// success, thrown errors, and cooperative cancellation, so UI code never has to pair begin/end.
    public func withActivity<T: Sendable>(
        sourceVolumeID: SourceVolumeID,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard !destructivelyQuiesced.contains(sourceVolumeID),
              quarantinedAfterUnknownDestructiveOutcome[sourceVolumeID] == nil,
              physicalKeyBySourceVolumeID[sourceVolumeID].map({ quarantinedPhysicalKeys[$0] == nil }) ?? true else {
            throw UMISCoreError.eraseNotEligible(
                "Source volume is reserved or quarantined by a destructive action"
            )
        }
        try begin(sourceVolumeID: sourceVolumeID)
        defer { end(sourceVolumeID: sourceVolumeID) }
        return try await operation()
    }

    /// Prevents new `withActivity` leases for the duration of a confirmed destructive action.
    /// Existing work fails the request immediately instead of being cancelled implicitly.
    public func withQuiescedVolume<T: Sendable>(
        sourceVolumeID: SourceVolumeID,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard !destructivelyQuiesced.contains(sourceVolumeID),
              quarantinedAfterUnknownDestructiveOutcome[sourceVolumeID] == nil,
              physicalKeyBySourceVolumeID[sourceVolumeID].map({ quarantinedPhysicalKeys[$0] == nil }) ?? true,
              (activityCounts[sourceVolumeID] ?? 0) == 0 else {
            throw UMISCoreError.eraseNotEligible("Source volume cannot be quiesced while media I/O is active")
        }
        destructivelyQuiesced.insert(sourceVolumeID)
        defer {
            destructivelyQuiesced.remove(sourceVolumeID)
        }
        return try await operation()
    }

    public func isDestructivelyQuiesced(sourceVolumeID: SourceVolumeID) -> Bool {
        destructivelyQuiesced.contains(sourceVolumeID)
    }

    /// Registers a fresh Disk Arbitration identity before the app exposes it for scan, playback,
    /// ingest, eject, or erase. This durable lookup is what carries an unknown destructive outcome
    /// across a newly generated `SourceVolumeID` and an application restart.
    public func registerAppearance(
        identity: VolumeIdentity,
        durableStore: OperationStore
    ) async throws {
        let key = try identity.physicalQuarantineKey()
        physicalKeyBySourceVolumeID[identity.id] = key
        if let durable = try await durableStore.destructiveQuarantine(for: identity) {
            quarantinedPhysicalKeys[key] = durable.reason
            quarantinedAfterUnknownDestructiveOutcome[identity.id] = durable.reason
        }
        guard quarantinedPhysicalKeys[key] == nil else {
            throw UMISCoreError.eraseNotEligible(
                "This physical card has an unresolved destructive outcome and remains quarantined"
            )
        }
    }

    /// Identity-bound activity API for Disk Arbitration volumes. UI integrations should prefer
    /// this overload (or call `registerAppearance` first) instead of relying on a mount-session ID.
    public func withActivity<T: Sendable>(
        identity: VolumeIdentity,
        durableStore: OperationStore,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await registerAppearance(identity: identity, durableStore: durableStore)
        return try await withActivity(sourceVolumeID: identity.id, operation: operation)
    }

    /// Identity-bound destructive reservation. A durable quarantine is checked before the
    /// reservation is acquired, so a new mount-session ID cannot bypass an earlier timeout.
    public func withQuiescedVolume<T: Sendable>(
        identity: VolumeIdentity,
        durableStore: OperationStore,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await registerAppearance(identity: identity, durableStore: durableStore)
        return try await withQuiescedVolume(sourceVolumeID: identity.id, operation: operation)
    }

    /// Permanently blocks further in-process access after a destructive helper timed out and may
    /// still be changing the medium. A new Disk Arbitration appearance should receive a new
    /// `SourceVolumeID`; this quarantine is intentionally not user-clearable for the old identity.
    public func quarantineAfterUnknownDestructiveOutcome(
        sourceVolumeID: SourceVolumeID,
        reason: String
    ) {
        quarantinedAfterUnknownDestructiveOutcome[sourceVolumeID] = reason
    }

    public func isQuarantined(sourceVolumeID: SourceVolumeID) -> Bool {
        quarantinedAfterUnknownDestructiveOutcome[sourceVolumeID] != nil
            || physicalKeyBySourceVolumeID[sourceVolumeID].map({ quarantinedPhysicalKeys[$0] != nil }) == true
    }

    /// Marks the physical card in memory before awaiting the durable SQLite write. If persistence
    /// fails, the current process remains fail-closed and the caller receives an error rather than
    /// an apparently final destructive result.
    func quarantinePhysicalMedia(
        identity: VolumeIdentity,
        operationID: UUID,
        reason: String,
        durableStore: OperationStore
    ) async throws {
        let key = try identity.physicalQuarantineKey()
        physicalKeyBySourceVolumeID[identity.id] = key
        quarantinedPhysicalKeys[key] = reason
        quarantinedAfterUnknownDestructiveOutcome[identity.id] = reason
        _ = try await durableStore.recordDestructiveQuarantine(
            identity: identity,
            operationID: operationID,
            reason: reason
        )
    }

    /// Called only after a completed backend result and post-format write/read probe. This is not
    /// exposed as a public recovery control; ambiguous outcomes require an explicit future manual
    /// reconciliation workflow.
    func resolvePhysicalQuarantineAfterKnownCompletion(
        identity: VolumeIdentity,
        operationID: UUID,
        durableStore: OperationStore
    ) async throws {
        let key = try identity.physicalQuarantineKey()
        try await durableStore.resolveDestructiveQuarantineAfterKnownCompletion(
            identity: identity,
            operationID: operationID
        )
        quarantinedPhysicalKeys.removeValue(forKey: key)
        quarantinedAfterUnknownDestructiveOutcome.removeValue(forKey: identity.id)
    }
}

public actor SafeEjectService {
    /// This build does not bundle a product-qualified DADisk claim/eject provider. UI code must not
    /// advertise safe eject merely because its development feature flag is set.
    public nonisolated static let isBundledProductionBoundaryAvailable = false

    private let registry: VolumeIdentityRegistry
    private let activity: VolumeIOActivityRegistry
    private let claimProvider: (any RetainedMediaClaimProviding)?
    private let testingOnlyAllowsTestDouble: Bool
    private let store: OperationStore?

    public init(
        registry: VolumeIdentityRegistry,
        activity: VolumeIOActivityRegistry,
        store: OperationStore? = nil,
        runner: any ProcessRunning = POSIXProcessRunner(),
        claimProvider: (any RetainedMediaClaimProviding)? = nil,
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    ) {
        self.registry = registry
        self.activity = activity
        self.store = store
        self.claimProvider = claimProvider
        testingOnlyAllowsTestDouble = false
        // Compatibility parameters are intentionally ignored. Ejecting by resolving a BSD name
        // through a process helper cannot satisfy the retained-native-object boundary.
        _ = runner
        _ = diskutilURL
    }

    init(
        registry: VolumeIdentityRegistry,
        activity: VolumeIOActivityRegistry,
        store: OperationStore,
        runner: any ProcessRunning,
        testingClaimProvider: any RetainedMediaClaimProviding,
        diskutilURL: URL
    ) {
        self.registry = registry
        self.activity = activity
        self.store = store
        claimProvider = testingClaimProvider
        testingOnlyAllowsTestDouble = true
        _ = runner
        _ = diskutilURL
    }

    public func eject(expectedIdentity: VolumeIdentity, timeout: TimeInterval = 15) async throws {
        guard let store else {
            throw UMISCoreError.eraseNotEligible(
                "Safe eject requires the durable operation store to check physical-media quarantine"
            )
        }
        try await activity.withQuiescedVolume(identity: expectedIdentity, durableStore: store) { [self] in
            try await performEject(expectedIdentity: expectedIdentity, timeout: timeout)
        }
    }

    /// Runs only while `VolumeIOActivityRegistry` owns the destructive reservation. A cached
    /// registry entry is not authority: the provider must retain and freshly revalidate a native
    /// media object through the eject command.
    private func performEject(expectedIdentity: VolumeIdentity, timeout: TimeInterval) async throws {
        guard timeout > 0, let claimProvider else {
            throw UMISCoreError.eraseNotEligible(
                "Safe eject is unavailable: no retained Disk Arbitration claim provider is installed"
            )
        }
        guard claimProvider.assurance == .retainedDiskArbitrationObject
            || testingOnlyAllowsTestDouble else {
            throw UMISCoreError.eraseNotEligible(
                "Safe eject rejected a non-production retained-media claim provider"
            )
        }
        let claim = try await claimProvider.acquire(
            expectedIdentity: expectedIdentity,
            purpose: .eject,
            timeout: timeout
        )
        let current: VolumeIdentity
        do {
            current = try await claimProvider.revalidate(claim)
        } catch {
            await claimProvider.release(claim)
            throw error
        }
        guard claim.purpose == .eject,
              claim.expectedIdentityDigest == expectedIdentity.securityDigest,
              claim.freshlyRevalidatedIdentity.matchesSameEraseTarget(as: expectedIdentity),
              current.matchesSameEraseTarget(as: expectedIdentity),
              current.matchesSameEraseTarget(as: claim.freshlyRevalidatedIdentity),
              Date() <= claim.expiresAt,
              let whole = current.wholeDiskBSDName,
              whole.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              !current.isInternal,
              current.isRemovable else {
            await claimProvider.release(claim)
            throw UMISCoreError.identityChanged
        }
        do {
            _ = whole
            try await claimProvider.ejectRetained(claim, timeout: timeout)
        } catch {
            await claimProvider.release(claim)
            throw error
        }
        await claimProvider.release(claim)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if !(await registry.contains(sourceVolumeID: expectedIdentity.id)) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UMISCoreError.backendFailure("Eject command returned success but disappearance callback was not observed")
    }
}
