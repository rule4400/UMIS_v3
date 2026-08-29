import AdobeXMPBridge
import Darwin
import Foundation

/// Where UMIS persisted the Adobe rating. Only `.embedded` is advertised as embedded Adobe XMP.
/// The fallback sidecar is deliberately labelled as compatibility-unverified because Adobe video
/// applications can differ in whether they consume sidecars for otherwise embeddable containers.
public enum AdobeXMPRatingStorage: String, Codable, Hashable, Sendable {
    case embedded
    case cameraRawSidecar
    case compatibilityUnverifiedSidecar
}

/// Logical access requested from NSFileCoordinator by the app's outer review-operation gate.
public enum AdobeXMPCoordinationAccess: String, Codable, Hashable, Sendable {
    case read
    case write
    case contentIndependentMetadataWrite
}

public struct AdobeXMPCoordinationIntent: Hashable, Sendable {
    public let url: URL
    public let access: AdobeXMPCoordinationAccess

    public init(url: URL, access: AdobeXMPCoordinationAccess) {
        self.url = url
        self.access = access
    }
}

public struct AdobeXMPRatingCoordinationPlan: Hashable, Sendable {
    public let storage: AdobeXMPRatingStorage
    public let intents: [AdobeXMPCoordinationIntent]

    public init(storage: AdobeXMPRatingStorage, intents: [AdobeXMPCoordinationIntent]) {
        self.storage = storage
        self.intents = intents
    }
}

public struct AdobeXMPRatingCapability: Hashable, Sendable {
    public let storage: AdobeXMPRatingStorage
    public let canRead: Bool
    public let canWrite: Bool
    public let usesAdobeSmartHandler: Bool
    public let supportsSafeUpdate: Bool
    public let warning: String?

    public init(
        storage: AdobeXMPRatingStorage,
        canRead: Bool,
        canWrite: Bool,
        usesAdobeSmartHandler: Bool,
        supportsSafeUpdate: Bool,
        warning: String?
    ) {
        self.storage = storage
        self.canRead = canRead
        self.canWrite = canWrite
        self.usesAdobeSmartHandler = usesAdobeSmartHandler
        self.supportsSafeUpdate = supportsSafeUpdate
        self.warning = warning
    }
}

public struct AdobeXMPRatingReadResult: Hashable, Sendable {
    public let rating: AdobeRating
    public let hasExplicitRating: Bool
    public let storage: AdobeXMPRatingStorage
    public let fingerprint: FileFingerprint

    public init(
        rating: AdobeRating,
        hasExplicitRating: Bool,
        storage: AdobeXMPRatingStorage,
        fingerprint: FileFingerprint
    ) {
        self.rating = rating
        self.hasExplicitRating = hasExplicitRating
        self.storage = storage
        self.fingerprint = fingerprint
    }
}

public struct AdobeXMPRatingWriteResult: Hashable, Sendable {
    public let rating: AdobeRating
    public let storage: AdobeXMPRatingStorage
    /// Embedded safe update commonly replaces the inode. The UI must use this new fingerprint for
    /// every subsequent mutation instead of reusing the scan-time value.
    public let fingerprintAfter: FileFingerprint
    public let compatibilityWarning: String?
    /// A committed value exists, but private recovery cleanup did not fully complete. The current
    /// batch authorization is invalidated so a later asset cannot silently continue.
    public let recoveryAttentionRequired: Bool

    public init(
        rating: AdobeRating,
        storage: AdobeXMPRatingStorage,
        fingerprintAfter: FileFingerprint,
        compatibilityWarning: String?,
        recoveryAttentionRequired: Bool = false
    ) {
        self.rating = rating
        self.storage = storage
        self.fingerprintAfter = fingerprintAfter
        self.compatibilityWarning = compatibilityWarning
        self.recoveryAttentionRequired = recoveryAttentionRequired
    }
}

/// A mutation gate supplied by the app at the last possible point before filesystem access.
/// Passing this context is mandatory so a verified ingest receipt can never be invalidated while
/// it is still eligible to authorize card initialization.
public struct AdobeXMPRatingMutationContext: Hashable, Sendable {
    public let hasLatestVerifiedReceipt: Bool
    /// Clean-root authorization returned by `MetadataRecoveryInspector.prepareWriteTree` for this
    /// top-level batch. When absent, Core retains the slower direct-parent fail-closed scan.
    public let recoveryWriteAuthorization: MetadataRecoveryWriteAuthorization?

    public init(
        hasLatestVerifiedReceipt: Bool,
        recoveryWriteAuthorization: MetadataRecoveryWriteAuthorization? = nil
    ) {
        self.hasLatestVerifiedReceipt = hasLatestVerifiedReceipt
        self.recoveryWriteAuthorization = recoveryWriteAuthorization
    }
}

public struct AdobeXMPRatingConfiguration: Hashable, Sendable {
    /// Dynamic media at or above this size uses an appended sidecar rather than risking an opaque,
    /// full-container rewrite. Four GiB is intentionally conservative until a progress/cancellation
    /// bridge and a camera-specific large-file qualification corpus are available.
    public var maximumEmbeddedDynamicMediaBytes: Int64
    /// Safe-update preflight reserves this many bytes in addition to one complete source file.
    public var safeUpdateReserveBytes: Int64

    public init(
        maximumEmbeddedDynamicMediaBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        safeUpdateReserveBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.maximumEmbeddedDynamicMediaBytes = maximumEmbeddedDynamicMediaBytes
        self.safeUpdateReserveBytes = safeUpdateReserveBytes
    }

    public static let `default` = AdobeXMPRatingConfiguration()
}

public enum AdobeXMPRatingServiceError: Error, Equatable, CustomStringConvertible, Sendable {
    case pendingVerifiedReceipt
    case removableVolume(String)
    case nonInternalVolume(String)
    case readOnlyVolume(String)
    case incompleteVolumeSafetyEvidence(String)
    case insufficientSafeUpdateSpace(required: Int64, available: Int64)
    case unsupportedEmbeddedFormat(String)
    case ambiguousCameraRawSidecar(mediaPath: String, conflictingPath: String, sidecarPath: String)
    case recoveryRetained(
        path: String,
        recoveryDirectoryLeaf: String,
        originalBackupRetained: Bool?,
        cleanupIncomplete: Bool,
        reason: String
    )
    case bridge(status: UInt32, path: String, message: String)

    public var description: String {
        switch self {
        case .pendingVerifiedReceipt:
            return "A verified ingest receipt is active; rating mutation is blocked until erase eligibility is cleared"
        case let .removableVolume(path):
            return "Ratings are never written to removable media: \(path)"
        case let .nonInternalVolume(path):
            return "Ratings are only written to a local, internal, non-ejectable volume: \(path)"
        case let .readOnlyVolume(path):
            return "The rating destination volume is read-only: \(path)"
        case let .incompleteVolumeSafetyEvidence(path):
            return "Volume safety properties are incomplete for: \(path)"
        case let .insufficientSafeUpdateSpace(required, available):
            return "Safe embedded XMP update requires \(required) bytes but only \(available) bytes are available"
        case let .unsupportedEmbeddedFormat(path):
            return "Adobe XMP Toolkit did not provide a safe embedded handler for: \(path)"
        case let .ambiguousCameraRawSidecar(mediaPath, conflictingPath, sidecarPath):
            return "Camera RAW sidecar \(sidecarPath) is shared by \(mediaPath) and \(conflictingPath)"
        case let .recoveryRetained(
            path,
            recoveryDirectoryLeaf,
            originalBackupRetained,
            cleanupIncomplete,
            reason
        ):
            let backupState: String
            switch originalBackupRetained {
            case .some(true):
                backupState = "the original backup is retained"
            case .some(false):
                backupState = "the original backup is no longer linked"
            case .none:
                backupState = "the original-backup state is unknown"
            }
            let cleanupState = cleanupIncomplete ? "cleanup is incomplete" : "cleanup state is unknown"
            return "XMP recovery requires attention at \(path) (\(recoveryDirectoryLeaf)): "
                + "\(reason); \(backupState); \(cleanupState)"
        case let .bridge(status, path, message):
            return "Adobe XMP bridge error \(status) at \(path): \(message)"
        }
    }
}

enum AdobeXMPEmbeddedRecoveryTestFault: Hashable, Sendable {
    case failUpperReadback
    case replaceTargetBeforeFinalization
    case changeTargetMetadataBeforeFinalization
}

/// Extension-level candidate routing shared by review scanning and the live Adobe XMP router.
///
/// An embedded candidate is not a promise that an arbitrary file with that suffix can be updated:
/// the live route still requires a matching Adobe smart handler, safe-update capability, and (for
/// dynamic media) the configured size/free-space preflight. Any failed capability probe falls back
/// to the collision-free filename-plus-extension sidecar route.
public enum AdobeXMPRatingFormatRoute: String, Codable, Hashable, Sendable {
    case embeddedStillCandidate
    case embeddedDynamicCandidate
    case manufacturerRawSidecar
    case fallbackSidecar
}

/// Read-only format inventory for constructing the app's review-only scan policy without copying
/// Core's extension tables. Unknown nonempty extensions remain valid fallback-sidecar candidates,
/// but only the explicitly known fallback set is added automatically to a review scan.
public struct AdobeXMPRatingFormatSupport: Hashable, Sendable {
    public let embeddedStillExtensions: Set<String>
    public let embeddedDynamicExtensions: Set<String>
    public let manufacturerRawExtensions: Set<String>
    public let knownFallbackSidecarExtensions: Set<String>

    public var knownReviewExtensions: Set<String> {
        embeddedStillExtensions
            .union(embeddedDynamicExtensions)
            .union(manufacturerRawExtensions)
            .union(knownFallbackSidecarExtensions)
    }

    public func routeCandidate(forPathExtension pathExtension: String) -> AdobeXMPRatingFormatRoute {
        let normalized = pathExtension
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if manufacturerRawExtensions.contains(normalized) { return .manufacturerRawSidecar }
        if embeddedStillExtensions.contains(normalized) { return .embeddedStillCandidate }
        if embeddedDynamicExtensions.contains(normalized) { return .embeddedDynamicCandidate }
        return .fallbackSidecar
    }

    public func isKnownReviewExtension(_ pathExtension: String) -> Bool {
        let normalized = pathExtension
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return knownReviewExtensions.contains(normalized)
    }

    fileprivate init(
        embeddedStillExtensions: Set<String>,
        embeddedDynamicExtensions: Set<String>,
        manufacturerRawExtensions: Set<String>,
        knownFallbackSidecarExtensions: Set<String>
    ) {
        self.embeddedStillExtensions = embeddedStillExtensions
        self.embeddedDynamicExtensions = embeddedDynamicExtensions
        self.manufacturerRawExtensions = manufacturerRawExtensions
        self.knownFallbackSidecarExtensions = knownFallbackSidecarExtensions
    }
}

/// Format-aware, identity-bound Adobe rating service.
///
/// Embedded-capable formats are never silently opened with packet scanning. Manufacturer RAW uses
/// strict stem-based Camera Raw sidecars. HEIC/MXF/R3D/unknown formats and conservative dynamic-media
/// fallbacks use strict filename-plus-extension sidecars, preventing same-stem RAW/JPEG/MOV assets
/// from sharing metadata accidentally.
public struct AdobeXMPRatingService: Sendable {
    public static let formatSupport = AdobeXMPRatingFormatSupport(
        embeddedStillExtensions: [
            "jpg", "jpeg", "tif", "tiff", "dng", "psd", "png", "gif",
        ],
        embeddedDynamicExtensions: [
            "mov", "mp4", "m4v", "m4a",
        ],
        manufacturerRawExtensions: [
            "3fr", "arw", "cr2", "cr3", "crw", "dcr", "erf", "iiq", "k25", "kdc",
            "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2",
            "rwl", "sr2", "srf", "srw", "x3f",
        ],
        knownFallbackSidecarExtensions: [
            "heic", "heif", "mxf", "r3d",
        ]
    )
    private final class RawSiblingProbeMetrics: @unchecked Sendable {
        private let lock = NSLock()
        private var candidateLookups = 0

        func increment() {
            lock.lock()
            candidateLookups += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            candidateLookups = 0
            lock.unlock()
        }

        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return candidateLookups
        }
    }

    private static let rawSiblingProbeMetrics = RawSiblingProbeMetrics()
    static func resetRawSiblingCandidateLookupCountForTesting() {
        rawSiblingProbeMetrics.reset()
    }
    static var rawSiblingCandidateLookupCountForTesting: Int {
        rawSiblingProbeMetrics.value()
    }

    public let configuration: AdobeXMPRatingConfiguration
    private let embeddedRecoveryTestFault: AdobeXMPEmbeddedRecoveryTestFault?

    public init(configuration: AdobeXMPRatingConfiguration = .default) {
        self.configuration = configuration
        embeddedRecoveryTestFault = nil
    }

    init(
        configuration: AdobeXMPRatingConfiguration = .default,
        embeddedRecoveryTestFault: AdobeXMPEmbeddedRecoveryTestFault
    ) {
        self.configuration = configuration
        self.embeddedRecoveryTestFault = embeddedRecoveryTestFault
    }

    public func probe(
        mediaURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> AdobeXMPRatingCapability {
        try requireExpectedFingerprint(expectedFingerprint, at: mediaURL)
        return try withCompatibilityParentCapability(mediaURL) { parentDescriptor, leaf in
            try probe(
                parentFileDescriptor: parentDescriptor,
                mediaLeafName: leaf,
                displayURL: mediaURL,
                expectedFingerprint: expectedFingerprint
            )
        }
    }

    public func readRating(
        mediaURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> AdobeXMPRatingReadResult {
        try requireExpectedFingerprint(expectedFingerprint, at: mediaURL)
        return try withCompatibilityParentCapability(mediaURL) { parentDescriptor, leaf in
            try readRating(
                parentFileDescriptor: parentDescriptor,
                mediaLeafName: leaf,
                displayURL: mediaURL,
                expectedFingerprint: expectedFingerprint
            )
        }
    }

    private func withCompatibilityParentCapability<Value>(
        _ mediaURL: URL,
        operation: (Int32, String) throws -> Value
    ) throws -> Value {
        let parentURL = mediaURL.deletingLastPathComponent()
        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw UMISCoreError.posix(
                operation: "open compatibility XMP parent",
                code: errno,
                path: parentURL.path
            )
        }
        defer { Darwin.close(parentDescriptor) }
        return try operation(parentDescriptor, mediaURL.lastPathComponent)
    }

    /// Compatibility-test adapter only. Production callers outside UMISCore cannot invoke a
    /// path-authorized mutation; the app must supply its frozen parent-directory capability.
    func writeRating(
        _ rating: AdobeRating,
        mediaURL: URL,
        expectedFingerprint: FileFingerprint,
        context: AdobeXMPRatingMutationContext
    ) throws -> AdobeXMPRatingWriteResult {
        guard !context.hasLatestVerifiedReceipt else {
            throw AdobeXMPRatingServiceError.pendingVerifiedReceipt
        }
        try requireExpectedFingerprint(expectedFingerprint, at: mediaURL)
        return try coordinateWriting(mediaURL) { coordinatedURL in
            try requireExpectedFingerprint(expectedFingerprint, at: coordinatedURL)
            let parentURL = coordinatedURL.deletingLastPathComponent()
            let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard parentDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "open compatibility-test XMP parent",
                    code: errno,
                    path: parentURL.path
                )
            }
            defer { Darwin.close(parentDescriptor) }
            return try writeRating(
                rating,
                parentFileDescriptor: parentDescriptor,
                mediaLeafName: coordinatedURL.lastPathComponent,
                displayURL: coordinatedURL,
                expectedFingerprint: expectedFingerprint,
                context: context
            )
        }
    }

    /// Computes the exact logical files that the app must coordinate for one capability-bound
    /// operation. Route selection and strict sidecar resolution are shared with the actual read or
    /// write; callers must recompute and compare this plan inside the coordinator accessor before
    /// opening a mutation lease, rather than following a coordinator-supplied replacement URL.
    public func coordinationPlan(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        forWriting: Bool
    ) throws -> AdobeXMPRatingCoordinationPlan {
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        let volume: VolumeEvidence?
        if forWriting {
            volume = try requireWritableNonRemovableVolume(at: displayURL)
            try requireDescriptorVolumeBinding(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint
            )
        } else {
            volume = nil
        }
        let selectedRoute = try route(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint,
            forWriting: forWriting,
            volumeEvidence: volume
        )
        switch selectedRoute {
        case .embedded:
            return AdobeXMPRatingCoordinationPlan(
                storage: .embedded,
                intents: [
                    AdobeXMPCoordinationIntent(
                        url: displayURL,
                        access: forWriting ? .write : .read
                    ),
                ]
            )
        case .cameraRawSidecar:
            return try sidecarCoordinationPlan(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint,
                naming: .replacingMediaExtension,
                storage: .cameraRawSidecar,
                forWriting: forWriting
            )
        case .fallbackSidecar:
            return try sidecarCoordinationPlan(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint,
                naming: .appendingToMediaFilename,
                storage: .compatibilityUnverifiedSidecar,
                forWriting: forWriting
            )
        }
    }

    /// Capability-bound probe. `displayURL` is used only for diagnostics and volume-policy
    /// evidence; every media/sidecar access is authorized by `parentFileDescriptor + mediaLeafName`.
    public func probe(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> AdobeXMPRatingCapability {
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        switch try route(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint,
            forWriting: false
        ) {
        case .embedded:
            let probe = try bridgeProbe(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint
            )
            guard probe.has_smart_handler != 0,
                  probe.can_read_embedded_xmp != 0,
                  probe.can_put_embedded_xmp != 0,
                  probe.supports_safe_update != 0,
                  probe.handler_uses_sidecar == 0 else {
                throw AdobeXMPRatingServiceError.unsupportedEmbeddedFormat(displayURL.path)
            }
            return AdobeXMPRatingCapability(
                storage: .embedded,
                canRead: true,
                canWrite: true,
                usesAdobeSmartHandler: true,
                supportsSafeUpdate: true,
                warning: nil
            )
        case .cameraRawSidecar:
            return AdobeXMPRatingCapability(
                storage: .cameraRawSidecar,
                canRead: true,
                canWrite: true,
                usesAdobeSmartHandler: false,
                supportsSafeUpdate: true,
                warning: nil
            )
        case .fallbackSidecar:
            return AdobeXMPRatingCapability(
                storage: .compatibilityUnverifiedSidecar,
                canRead: true,
                canWrite: true,
                usesAdobeSmartHandler: false,
                supportsSafeUpdate: true,
                warning: Self.sidecarCompatibilityWarning
            )
        }
    }

    public func readRating(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> AdobeXMPRatingReadResult {
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        let selectedRoute = try route(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint,
            forWriting: false
        )
        switch selectedRoute {
        case .embedded:
            let bridgeResult = try bridgeRead(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint
            )
            let fingerprint = FileFingerprint(bridgeResult.identity)
            guard fingerprint == expectedFingerprint else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            return AdobeXMPRatingReadResult(
                rating: try AdobeRating(validating: Int(bridgeResult.rating)),
                hasExplicitRating: bridgeResult.has_explicit_rating != 0,
                storage: .embedded,
                fingerprint: fingerprint
            )
        case .cameraRawSidecar:
            return try readSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint,
                naming: .replacingMediaExtension,
                storage: .cameraRawSidecar
            )
        case .fallbackSidecar:
            return try readSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint,
                naming: .appendingToMediaFilename,
                storage: .compatibilityUnverifiedSidecar
            )
        }
    }

    public func writeRating(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        context: AdobeXMPRatingMutationContext
    ) throws -> AdobeXMPRatingWriteResult {
        guard !context.hasLatestVerifiedReceipt else {
            throw AdobeXMPRatingServiceError.pendingVerifiedReceipt
        }
        if let authorization = context.recoveryWriteAuthorization {
            try authorization.requireAuthorizedParent(
                parentFileDescriptor,
                displayURL: displayURL
            )
        } else {
            try MetadataRecoveryWriteGuard.requireNoPendingRecovery(
                parentFileDescriptor: parentFileDescriptor,
                displayURL: displayURL
            )
        }
        let volume = try requireWritableNonRemovableVolume(at: displayURL)
        try requireDescriptorVolumeBinding(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint
        )
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        let selectedRoute = try route(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint,
            forWriting: true,
            volumeEvidence: volume
        )
        do {
            let result: AdobeXMPRatingWriteResult
            switch selectedRoute {
            case .embedded:
                let probe = try bridgeProbe(
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedFingerprint: expectedFingerprint
                )
                guard probe.has_smart_handler != 0,
                      probe.can_put_embedded_xmp != 0,
                      probe.supports_safe_update != 0,
                      probe.handler_uses_sidecar == 0 else {
                    throw AdobeXMPRatingServiceError.unsupportedEmbeddedFormat(displayURL.path)
                }
                try requireSafeUpdateCapacity(
                    fileSize: expectedFingerprint.byteSize,
                    availableCapacity: volume.availableCapacity
                )
                let bridgeResult = try bridgeWrite(
                    rating,
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedFingerprint: expectedFingerprint
                )
                result = try completeAnchoredEmbeddedWrite(
                    rating,
                    bridgeResult: bridgeResult,
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL
                )
            case .cameraRawSidecar:
                result = try writeSidecar(
                    rating,
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedFingerprint: expectedFingerprint,
                    naming: .replacingMediaExtension,
                    storage: .cameraRawSidecar,
                    warning: nil
                )
            case .fallbackSidecar:
                result = try writeSidecar(
                    rating,
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedFingerprint: expectedFingerprint,
                    naming: .appendingToMediaFilename,
                    storage: .compatibilityUnverifiedSidecar,
                    warning: Self.sidecarCompatibilityWarning
                )
            }
            if result.recoveryAttentionRequired {
                context.recoveryWriteAuthorization?.invalidate(
                    reason: "A committed metadata update left recovery cleanup requiring attention"
                )
            }
            return result
        } catch {
            // Once a mutation path has started, any failure invalidates the O(1) batch lease. The
            // caller must perform a fresh root scan before another asset, preventing a pre-commit
            // recovery directory from being bypassed by the cached clean-tree evidence.
            context.recoveryWriteAuthorization?.invalidate(
                reason: "A metadata mutation failed; a fresh recovery scan is required: \(error)"
            )
            throw error
        }
    }

    private enum Route {
        case embedded
        case cameraRawSidecar
        case fallbackSidecar
    }

    private struct VolumeEvidence {
        let isLocal: Bool
        let isInternal: Bool
        let isEjectable: Bool
        let isRemovable: Bool
        let isReadOnly: Bool
        let availableCapacity: Int64?
    }

    private static let sidecarCompatibilityWarning =
        "この形式は安全のためfilename.ext.xmpへ保存しました。対象Adobe製品でのsidecar認識は未保証です。"

    private struct BridgeRecoveryFinalization {
        let result: UMISXMPRecoveryFinalizeResult
        let diagnostic: String
    }

    /// Finishes the descriptor-capability transaction. The bridge's own readback is intentionally
    /// not the linearization point: Core reopens the committed leaf through the held parent FD,
    /// verifies identity and xmp:Rating independently, and only then authorizes deletion of the
    /// pre-update inode. Every nonzero token is consumed on both success and failure paths.
    private func completeAnchoredEmbeddedWrite(
        _ rating: AdobeRating,
        bridgeResult: UMISXMPRatingResult,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL
    ) throws -> AdobeXMPRatingWriteResult {
        let postFingerprint = FileFingerprint(bridgeResult.identity)
        let bridgeRecoveryLeaf = Self.recoveryDirectoryLeaf(from: bridgeResult)
        guard bridgeResult.has_pending_recovery != 0,
              bridgeResult.recovery_token != 0,
              !bridgeRecoveryLeaf.isEmpty else {
            if bridgeResult.recovery_token != 0 {
                _ = try? bridgeFinalizeRecovery(
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedCommittedFingerprint: postFingerprint,
                    recoveryToken: bridgeResult.recovery_token,
                    upperReadbackVerified: false
                )
            }
            throw AdobeXMPRatingServiceError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: bridgeRecoveryLeaf.isEmpty
                    ? "unknown-recovery-directory"
                    : bridgeRecoveryLeaf,
                originalBackupRetained: nil,
                cleanupIncomplete: true,
                reason: "The safe-update bridge returned without a finalizable recovery token"
            )
        }

        do {
            guard bridgeResult.has_explicit_rating != 0,
                  bridgeResult.rating == Int32(rating.rawValue) else {
                throw AdobeXMPRatingServiceError.bridge(
                    status: UInt32(UMIS_XMP_STATUS_VERIFICATION_FAILED),
                    path: displayURL.path,
                    message: "The bridge write result did not contain the requested rating"
                )
            }
            try requireExpectedFingerprint(
                postFingerprint,
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL
            )
            let upperReadback = try bridgeRead(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: postFingerprint
            )
            guard FileFingerprint(upperReadback.identity) == postFingerprint,
                  upperReadback.has_explicit_rating != 0,
                  upperReadback.rating == Int32(rating.rawValue) else {
                throw AdobeXMPRatingServiceError.bridge(
                    status: UInt32(UMIS_XMP_STATUS_VERIFICATION_FAILED),
                    path: displayURL.path,
                    message: "Independent Core readback did not contain the requested rating"
                )
            }
            try applyEmbeddedRecoveryTestFault(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL
            )
        } catch {
            let finalization = try? bridgeFinalizeRecovery(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedCommittedFingerprint: postFingerprint,
                recoveryToken: bridgeResult.recovery_token,
                upperReadbackVerified: false
            )
            let retainedLeaf = finalization.map {
                Self.recoveryDirectoryLeaf(from: $0.result)
            }.flatMap(Self.nilIfEmpty) ?? bridgeRecoveryLeaf
            throw AdobeXMPRatingServiceError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: retainedLeaf,
                originalBackupRetained: finalization.map {
                    $0.result.original_backup_retained != 0
                },
                cleanupIncomplete: finalization?.result.cleanup_incomplete != 0,
                reason: "Independent Core readback failed: \(error)"
            )
        }

        let finalization: BridgeRecoveryFinalization
        do {
            finalization = try bridgeFinalizeRecovery(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedCommittedFingerprint: postFingerprint,
                recoveryToken: bridgeResult.recovery_token,
                upperReadbackVerified: true
            )
        } catch {
            throw AdobeXMPRatingServiceError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: bridgeRecoveryLeaf,
                originalBackupRetained: nil,
                cleanupIncomplete: true,
                reason: "Recovery finalization failed after verified readback: \(error)"
            )
        }

        let finalizedLeaf = Self.nilIfEmpty(
            Self.recoveryDirectoryLeaf(from: finalization.result)
        ) ?? bridgeRecoveryLeaf
        if finalization.result.cleanup_completed == 0,
           finalization.result.original_backup_retained != 0 {
            throw AdobeXMPRatingServiceError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: finalizedLeaf,
                originalBackupRetained: true,
                cleanupIncomplete: finalization.result.cleanup_incomplete != 0,
                reason: Self.nilIfEmpty(finalization.diagnostic)
                    ?? "Committed XMP or its recovery witnesses changed before cleanup"
            )
        }
        let warning: String?
        if finalization.result.cleanup_completed != 0 {
            warning = nil
        } else {
            let backupDescription = finalization.result.original_backup_retained != 0
                ? "original backup retained"
                : "original backup is no longer linked"
            let residueDescription = finalization.result.cleanup_incomplete != 0
                ? "cleanup residue remains"
                : "cleanup state is unknown"
            let diagnostic = Self.nilIfEmpty(finalization.diagnostic)
                ?? "Recovery cleanup did not complete"
            warning = "\(diagnostic) [\(finalizedLeaf); \(backupDescription); \(residueDescription)]"
        }
        return AdobeXMPRatingWriteResult(
            rating: rating,
            storage: .embedded,
            fingerprintAfter: postFingerprint,
            compatibilityWarning: warning,
            recoveryAttentionRequired: finalization.result.cleanup_completed == 0
        )
    }

    private func applyEmbeddedRecoveryTestFault(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL
    ) throws {
        guard let embeddedRecoveryTestFault else { return }
        switch embeddedRecoveryTestFault {
        case .failUpperReadback:
            throw AssetMetadataError.concurrentModification(displayURL.path)
        case .replaceTargetBeforeFinalization:
            let replacementLeaf = ".umis-test-xmp-replacement-\(UUID().uuidString)"
            let replacementDescriptor = replacementLeaf.withCString {
                Darwin.openat(
                    parentFileDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard replacementDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "create embedded recovery test replacement",
                    code: errno,
                    path: displayURL.path
                )
            }
            defer { Darwin.close(replacementDescriptor) }
            let bytes = Data("deterministic-concurrent-replacement".utf8)
            let writeResult = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(replacementDescriptor, buffer.baseAddress, buffer.count)
            }
            guard writeResult == bytes.count, Darwin.fsync(replacementDescriptor) == 0 else {
                throw UMISCoreError.posix(
                    operation: "write embedded recovery test replacement",
                    code: errno,
                    path: displayURL.path
                )
            }
            let renameResult = replacementLeaf.withCString { replacement in
                mediaLeafName.withCString { target in
                    Darwin.renameat(parentFileDescriptor, replacement, parentFileDescriptor, target)
                }
            }
            guard renameResult == 0, Darwin.fsync(parentFileDescriptor) == 0 else {
                throw UMISCoreError.posix(
                    operation: "install embedded recovery test replacement",
                    code: errno,
                    path: displayURL.path
                )
            }
        case .changeTargetMetadataBeforeFinalization:
            let descriptor = mediaLeafName.withCString {
                Darwin.openat(parentFileDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "open embedded recovery test target",
                    code: errno,
                    path: displayURL.path
                )
            }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  Darwin.fchmod(descriptor, status.st_mode ^ mode_t(S_IXUSR)) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                throw UMISCoreError.posix(
                    operation: "change embedded recovery test ctime",
                    code: errno,
                    path: displayURL.path
                )
            }
        }
    }

    private func route(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        forWriting: Bool,
        volumeEvidence: VolumeEvidence? = nil
    ) throws -> Route {
        let pathExtension = (mediaLeafName as NSString).pathExtension.lowercased()
        let formatRoute = Self.formatSupport.routeCandidate(forPathExtension: pathExtension)
        if formatRoute == .manufacturerRawSidecar {
            try requireUnambiguousCameraRawSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                volumeIsCaseSensitive: try volumeSupportsCaseSensitiveNames(at: displayURL)
            )
            return .cameraRawSidecar
        }
        guard formatRoute == .embeddedStillCandidate
                || formatRoute == .embeddedDynamicCandidate else {
            return .fallbackSidecar
        }

        if formatRoute == .embeddedDynamicCandidate {
            let appendedService = strictSidecarService(naming: .appendingToMediaFilename)
            if try appendedService.sidecarExists(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedMediaFingerprint: expectedFingerprint
            ) {
                return .fallbackSidecar
            }
            if forWriting,
               expectedFingerprint.byteSize >= configuration.maximumEmbeddedDynamicMediaBytes {
                return .fallbackSidecar
            }
            if forWriting {
                guard let volumeEvidence else { return .fallbackSidecar }
                if !volumeEvidence.isLocal { return .fallbackSidecar }
                guard let available = volumeEvidence.availableCapacity,
                      available >= safeUpdateRequiredBytes(fileSize: expectedFingerprint.byteSize) else {
                    return .fallbackSidecar
                }
            }
        }
        // Extension membership is only a candidate list. The descriptor-bound smart-handler probe
        // is the final routing authority, so a renamed/corrupt MP4 or an installed Toolkit build
        // without a safe handler falls back to the collision-free filename.ext.xmp path before the
        // app computes its NSFileCoordinator intents.
        do {
            let probe = try bridgeProbe(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint
            )
            let canReadEmbedded = probe.has_smart_handler != 0
                && probe.can_read_embedded_xmp != 0
                && probe.handler_uses_sidecar == 0
            let canWriteSafely = canReadEmbedded
                && probe.can_put_embedded_xmp != 0
                && probe.supports_safe_update != 0
            return (forWriting ? canWriteSafely : canReadEmbedded) ? .embedded : .fallbackSidecar
        } catch AdobeXMPRatingServiceError.unsupportedEmbeddedFormat {
            return .fallbackSidecar
        }
    }

    private func readSidecar(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        naming: XMPSidecarNaming,
        storage: AdobeXMPRatingStorage
    ) throws -> AdobeXMPRatingReadResult {
        let rawVolumeIsCaseSensitive = storage == .cameraRawSidecar
            ? try volumeSupportsCaseSensitiveNames(at: displayURL)
            : nil
        if storage == .cameraRawSidecar {
            try requireUnambiguousCameraRawSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                volumeIsCaseSensitive: rawVolumeIsCaseSensitive!
            )
        }
        let service = strictSidecarService(naming: naming)
        let sidecarResult = try service.readRatingResult(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedFingerprint
        )
        if storage == .cameraRawSidecar {
            try requireUnambiguousCameraRawSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                volumeIsCaseSensitive: rawVolumeIsCaseSensitive!
            )
        }
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        return AdobeXMPRatingReadResult(
            rating: sidecarResult.rating,
            hasExplicitRating: sidecarResult.hasExplicitRating,
            storage: storage,
            fingerprint: expectedFingerprint
        )
    }

    private func writeSidecar(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        naming: XMPSidecarNaming,
        storage: AdobeXMPRatingStorage,
        warning: String?
    ) throws -> AdobeXMPRatingWriteResult {
        let rawVolumeIsCaseSensitive = storage == .cameraRawSidecar
            ? try volumeSupportsCaseSensitiveNames(at: displayURL)
            : nil
        if storage == .cameraRawSidecar {
            try requireUnambiguousCameraRawSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                volumeIsCaseSensitive: rawVolumeIsCaseSensitive!
            )
        }
        let service = strictSidecarService(naming: naming)
        let sidecarWrite = try service.writeRatingResultAfterTopLevelRecoveryCheck(
            rating,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedFingerprint
        )
        let persisted = try service.readRatingResult(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedFingerprint
        )
        guard persisted.rating == rating, persisted.hasExplicitRating else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        if storage == .cameraRawSidecar {
            try requireUnambiguousCameraRawSidecar(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                displayURL: displayURL,
                volumeIsCaseSensitive: rawVolumeIsCaseSensitive!
            )
        }
        try requireExpectedFingerprint(
            expectedFingerprint,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        return AdobeXMPRatingWriteResult(
            rating: rating,
            storage: storage,
            fingerprintAfter: expectedFingerprint,
            compatibilityWarning: Self.combinedWarning(warning, sidecarWrite.recoveryWarning),
            recoveryAttentionRequired: sidecarWrite.recoveryAttentionRequired
        )
    }

    private func strictSidecarService(naming: XMPSidecarNaming) -> AdobeXMPSidecarRatingService {
        AdobeXMPSidecarRatingService(
            preferredNaming: naming,
            resolutionPolicy: .strictPreferred
        )
    }

    private func sidecarCoordinationPlan(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint,
        naming: XMPSidecarNaming,
        storage: AdobeXMPRatingStorage,
        forWriting: Bool
    ) throws -> AdobeXMPRatingCoordinationPlan {
        let sidecarURL = try strictSidecarService(naming: naming).resolvedSidecarURL(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedFingerprint
        )
        return AdobeXMPRatingCoordinationPlan(
            storage: storage,
            intents: [
                AdobeXMPCoordinationIntent(url: displayURL, access: .read),
                AdobeXMPCoordinationIntent(
                    url: sidecarURL,
                    access: forWriting ? .write : .read
                ),
            ]
        )
    }

    private static func combinedWarning(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func requireUnambiguousCameraRawSidecar(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        volumeIsCaseSensitive: Bool
    ) throws {
        try requireValidMediaLeaf(mediaLeafName, displayURL: displayURL)
        var mediaStatus = stat()
        let mediaLookup = mediaLeafName.withCString {
            Darwin.fstatat(parentFileDescriptor, $0, &mediaStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard mediaLookup == 0 else {
            throw UMISCoreError.posix(
                operation: "fstatat RAW media capability",
                code: errno,
                path: displayURL.path
            )
        }
        guard (mediaStatus.st_mode & S_IFMT) == S_IFREG else {
            if (mediaStatus.st_mode & S_IFMT) == S_IFLNK {
                throw UMISCoreError.symbolicLinkRejected(displayURL.path)
            }
            throw UMISCoreError.notRegularFile(displayURL.path)
        }
        guard mediaStatus.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(displayURL.path)
        }
        let stem = (mediaLeafName as NSString).deletingPathExtension
        for rawExtension in Self.formatSupport.manufacturerRawExtensions.sorted() {
            let variants = volumeIsCaseSensitive
                ? Self.asciiCaseVariants(of: rawExtension)
                : [rawExtension]
            for extensionVariant in variants {
                let sibling = stem + "." + extensionVariant
                Self.rawSiblingProbeMetrics.increment()
                var siblingStatus = stat()
                let lookup = sibling.withCString {
                    Darwin.fstatat(parentFileDescriptor, $0, &siblingStatus, AT_SYMLINK_NOFOLLOW)
                }
                if lookup != 0 {
                    if errno == ENOENT { continue }
                    throw UMISCoreError.posix(
                        operation: "fstatat RAW sidecar sibling",
                        code: errno,
                        path: displayURL.deletingLastPathComponent().appendingPathComponent(sibling).path
                    )
                }
                if siblingStatus.st_dev == mediaStatus.st_dev,
                   siblingStatus.st_ino == mediaStatus.st_ino {
                    continue
                }
                let siblingURL = displayURL.deletingLastPathComponent().appendingPathComponent(sibling)
                guard (siblingStatus.st_mode & S_IFMT) != S_IFLNK else {
                    throw UMISCoreError.symbolicLinkRejected(siblingURL.path)
                }
                guard (siblingStatus.st_mode & S_IFMT) == S_IFREG else {
                    throw UMISCoreError.notRegularFile(siblingURL.path)
                }
                guard siblingStatus.st_nlink == 1 else {
                    throw AssetMetadataError.hardLinkRejected(siblingURL.path)
                }
                let sidecarLeaf = stem + ".xmp"
                throw AdobeXMPRatingServiceError.ambiguousCameraRawSidecar(
                    mediaPath: displayURL.path,
                    conflictingPath: siblingURL.path,
                    sidecarPath: displayURL.deletingLastPathComponent().appendingPathComponent(sidecarLeaf).path
                )
            }
        }
    }

    /// RAW extensions are ASCII and at most three characters in the supported set, so a
    /// case-sensitive filesystem needs no directory enumeration: all spelling variants are a
    /// fixed maximum of eight direct lookups. Stem casing is intentionally exact because distinct
    /// stems produce distinct sidecar leaves on a case-sensitive volume.
    static func asciiCaseVariants(of value: String) -> [String] {
        var variants = [""]
        for scalar in value.unicodeScalars {
            let character = Character(String(scalar))
            let lower = String(character).lowercased()
            let upper = String(character).uppercased()
            if lower == upper {
                variants = variants.map { $0 + String(character) }
            } else {
                variants = variants.flatMap { [$0 + lower, $0 + upper] }
            }
        }
        return Array(Set(variants)).sorted()
    }

    private func requireExpectedFingerprint(
        _ expected: FileFingerprint,
        at mediaURL: URL
    ) throws {
        let current = try FileFingerprint.capture(at: mediaURL)
        guard current == expected else {
            throw AssetMetadataError.concurrentModification(mediaURL.path)
        }
        var status = stat()
        let result = mediaURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw UMISCoreError.posix(operation: "lstat XMP target", code: errno, path: mediaURL.path)
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw UMISCoreError.symbolicLinkRejected(mediaURL.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(mediaURL.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(mediaURL.path)
        }
    }

    private func requireExpectedFingerprint(
        _ expected: FileFingerprint,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL
    ) throws {
        try requireValidMediaLeaf(mediaLeafName, displayURL: displayURL)
        var parentStatus = stat()
        guard Darwin.fstat(parentFileDescriptor, &parentStatus) == 0 else {
            throw UMISCoreError.posix(
                operation: "fstat XMP parent capability",
                code: errno,
                path: displayURL.deletingLastPathComponent().path
            )
        }
        guard (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw UMISCoreError.invalidPath("XMP parent capability is not a directory: \(displayURL.path)")
        }
        let descriptor = mediaLeafName.withCString {
            Darwin.openat(parentFileDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw UMISCoreError.symbolicLinkRejected(displayURL.path) }
            throw UMISCoreError.posix(
                operation: "openat XMP capability target",
                code: errno,
                path: displayURL.path
            )
        }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw UMISCoreError.posix(operation: "fstat XMP capability target", code: errno, path: displayURL.path)
        }
        guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(displayURL.path)
        }
        guard descriptorStatus.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(displayURL.path)
        }
        let descriptorFingerprint = FileFingerprint(
            device: UInt64(descriptorStatus.st_dev),
            inode: UInt64(descriptorStatus.st_ino),
            byteSize: Int64(descriptorStatus.st_size),
            modifiedSeconds: Int64(descriptorStatus.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(descriptorStatus.st_mtimespec.tv_nsec)
        )
        guard descriptorFingerprint == expected else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        var leafStatus = stat()
        let lookup = mediaLeafName.withCString {
            Darwin.fstatat(parentFileDescriptor, $0, &leafStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard lookup == 0 else {
            throw UMISCoreError.posix(operation: "fstatat XMP capability target", code: errno, path: displayURL.path)
        }
        guard (leafStatus.st_mode & S_IFMT) != S_IFLNK else {
            throw UMISCoreError.symbolicLinkRejected(displayURL.path)
        }
        guard (leafStatus.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(displayURL.path)
        }
        guard leafStatus.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(displayURL.path)
        }
        let leafFingerprint = FileFingerprint(
            device: UInt64(leafStatus.st_dev),
            inode: UInt64(leafStatus.st_ino),
            byteSize: Int64(leafStatus.st_size),
            modifiedSeconds: Int64(leafStatus.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(leafStatus.st_mtimespec.tv_nsec)
        )
        guard leafFingerprint == expected else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
    }

    private func requireValidMediaLeaf(_ leaf: String, displayURL: URL) throws {
        guard !leaf.isEmpty,
              leaf != ".",
              leaf != "..",
              !leaf.contains("/"),
              !leaf.unicodeScalars.contains(where: { $0.value == 0 }),
              leaf.utf8.count <= Int(NAME_MAX) else {
            throw UMISCoreError.invalidPath("Expected one valid media filename component: \(displayURL.path)")
        }
    }

    private func requireWritableNonRemovableVolume(at mediaURL: URL) throws -> VolumeEvidence {
        let values = try mediaURL.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let isLocal = values.volumeIsLocal,
              let isInternal = values.volumeIsInternal,
              let isEjectable = values.volumeIsEjectable,
              let isRemovable = values.volumeIsRemovable,
              let isReadOnly = values.volumeIsReadOnly else {
            throw AdobeXMPRatingServiceError.incompleteVolumeSafetyEvidence(mediaURL.path)
        }
        try Self.validateVolumeSafetyFlags(
            isLocal: isLocal,
            isInternal: isInternal,
            isEjectable: isEjectable,
            isRemovable: isRemovable,
            isReadOnly: isReadOnly,
            path: mediaURL.path
        )
        return VolumeEvidence(
            isLocal: isLocal,
            isInternal: isInternal,
            isEjectable: isEjectable,
            isRemovable: isRemovable,
            isReadOnly: isReadOnly,
            availableCapacity: values.volumeAvailableCapacityForImportantUsage
        )
    }

    static func validateVolumeSafetyFlags(
        isLocal: Bool,
        isInternal: Bool,
        isEjectable: Bool,
        isRemovable: Bool,
        isReadOnly: Bool,
        path: String
    ) throws {
        guard !isRemovable else {
            throw AdobeXMPRatingServiceError.removableVolume(path)
        }
        guard isLocal, isInternal, !isEjectable else {
            throw AdobeXMPRatingServiceError.nonInternalVolume(path)
        }
        guard !isReadOnly else {
            throw AdobeXMPRatingServiceError.readOnlyVolume(path)
        }
    }

    private func requireDescriptorVolumeBinding(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws {
        try requireValidMediaLeaf(mediaLeafName, displayURL: displayURL)
        var parentStatus = stat()
        guard Darwin.fstat(parentFileDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw AdobeXMPRatingServiceError.incompleteVolumeSafetyEvidence(displayURL.path)
        }
        guard UInt64(parentStatus.st_dev) == expectedFingerprint.device else {
            throw AdobeXMPRatingServiceError.incompleteVolumeSafetyEvidence(displayURL.path)
        }
        // The display URL is never used for mutation authority. Opening it here only proves that
        // the volume-policy evidence was gathered from the same live inode as the held capability.
        guard try FileFingerprint.capture(at: displayURL) == expectedFingerprint else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
    }

    private func requireSafeUpdateCapacity(fileSize: Int64, availableCapacity: Int64?) throws {
        guard let availableCapacity else {
            throw AdobeXMPRatingServiceError.incompleteVolumeSafetyEvidence("safe-update capacity")
        }
        let required = safeUpdateRequiredBytes(fileSize: fileSize)
        guard availableCapacity >= required else {
            throw AdobeXMPRatingServiceError.insufficientSafeUpdateSpace(
                required: required,
                available: availableCapacity
            )
        }
    }

    private func volumeSupportsCaseSensitiveNames(at displayURL: URL) throws -> Bool {
        let values = try displayURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let isCaseSensitive = values.volumeSupportsCaseSensitiveNames else {
            throw AdobeXMPRatingServiceError.incompleteVolumeSafetyEvidence(displayURL.path)
        }
        return isCaseSensitive
    }

    private func safeUpdateRequiredBytes(fileSize: Int64) -> Int64 {
        let nonnegativeFileSize = max(fileSize, 0)
        let reserve = max(configuration.safeUpdateReserveBytes, 0)
        let (sum, overflow) = nonnegativeFileSize.addingReportingOverflow(reserve)
        return overflow ? Int64.max : sum
    }

    private func bridgeProbe(
        _ mediaURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> UMISXMPProbeResult {
        var expected = UMISXMPFileIdentity(expectedFingerprint)
        var output = UMISXMPProbeResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaURL.path.withCString { path in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_probe_file(
                        path,
                        expectedPointer,
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        try requireBridgeSuccess(status, path: mediaURL.path, error: error)
        guard output.abi_version == UMIS_XMP_BRIDGE_ABI_VERSION else {
            throw AdobeXMPRatingServiceError.bridge(
                status: UInt32(UMIS_XMP_STATUS_INTERNAL_ERROR),
                path: mediaURL.path,
                message: "AdobeXMPBridge ABI version mismatch"
            )
        }
        return output
    }

    private func bridgeRead(
        _ mediaURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> UMISXMPRatingResult {
        var expected = UMISXMPFileIdentity(expectedFingerprint)
        var output = UMISXMPRatingResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaURL.path.withCString { path in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_read_embedded_rating(
                        path,
                        expectedPointer,
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        try requireBridgeSuccess(status, path: mediaURL.path, error: error)
        return output
    }

    private func bridgeProbe(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> UMISXMPProbeResult {
        var expected = UMISXMPFileIdentity(expectedFingerprint)
        var output = UMISXMPProbeResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaLeafName.withCString { leaf in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_probe_file_at(
                        parentFileDescriptor,
                        leaf,
                        expectedPointer,
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        try requireBridgeSuccess(status, path: displayURL.path, error: error)
        guard output.abi_version == UMIS_XMP_BRIDGE_ABI_VERSION else {
            throw AdobeXMPRatingServiceError.bridge(
                status: UInt32(UMIS_XMP_STATUS_INTERNAL_ERROR),
                path: displayURL.path,
                message: "AdobeXMPBridge ABI version mismatch"
            )
        }
        return output
    }

    private func bridgeRead(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> UMISXMPRatingResult {
        var expected = UMISXMPFileIdentity(expectedFingerprint)
        var output = UMISXMPRatingResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaLeafName.withCString { leaf in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_read_embedded_rating_at(
                        parentFileDescriptor,
                        leaf,
                        expectedPointer,
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        try requireBridgeSuccess(status, path: displayURL.path, error: error)
        return output
    }

    private func bridgeWrite(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> UMISXMPRatingResult {
        var expected = UMISXMPFileIdentity(expectedFingerprint)
        var output = UMISXMPRatingResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaLeafName.withCString { leaf in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_write_embedded_rating_at(
                        parentFileDescriptor,
                        leaf,
                        expectedPointer,
                        Int32(rating.rawValue),
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        let recoveryLeaf = Self.recoveryDirectoryLeaf(from: output)
        if status != UInt32(UMIS_XMP_STATUS_OK),
           output.has_pending_recovery != 0 || output.recovery_token != 0 || !recoveryLeaf.isEmpty {
            if output.recovery_token != 0 {
                // A failure result is never eligible to delete the original. Consume the
                // process-local token so the bridge does not retain descriptors indefinitely.
                _ = try? bridgeFinalizeRecovery(
                    parentFileDescriptor: parentFileDescriptor,
                    mediaLeafName: mediaLeafName,
                    displayURL: displayURL,
                    expectedCommittedFingerprint: FileFingerprint(output.identity),
                    recoveryToken: output.recovery_token,
                    upperReadbackVerified: false
                )
            }
            throw AdobeXMPRatingServiceError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: Self.nilIfEmpty(recoveryLeaf)
                    ?? "unknown-recovery-directory",
                originalBackupRetained: nil,
                cleanupIncomplete: true,
                reason: Self.bridgeDiagnostic(error)
            )
        }
        try requireBridgeSuccess(status, path: displayURL.path, error: error)
        return output
    }

    private func bridgeFinalizeRecovery(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedCommittedFingerprint: FileFingerprint,
        recoveryToken: UInt64,
        upperReadbackVerified: Bool
    ) throws -> BridgeRecoveryFinalization {
        var expected = UMISXMPFileIdentity(expectedCommittedFingerprint)
        var output = UMISXMPRecoveryFinalizeResult()
        var error = [CChar](repeating: 0, count: 2_048)
        let status = mediaLeafName.withCString { leaf in
            withUnsafePointer(to: &expected) { expectedPointer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    umis_xmp_finalize_recovery_at(
                        parentFileDescriptor,
                        leaf,
                        expectedPointer,
                        recoveryToken,
                        upperReadbackVerified ? 1 : 0,
                        &output,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        try requireBridgeSuccess(status, path: displayURL.path, error: error)
        guard output.abi_version == UMIS_XMP_BRIDGE_ABI_VERSION else {
            throw AdobeXMPRatingServiceError.bridge(
                status: UInt32(UMIS_XMP_STATUS_INTERNAL_ERROR),
                path: displayURL.path,
                message: "AdobeXMPBridge recovery ABI version mismatch"
            )
        }
        return BridgeRecoveryFinalization(
            result: output,
            diagnostic: Self.bridgeDiagnostic(error)
        )
    }

    private static func recoveryDirectoryLeaf(from result: UMISXMPRatingResult) -> String {
        var bytes = result.recovery_directory_leaf
        return withUnsafeBytes(of: &bytes) { rawBuffer in
            decodeNullTerminatedUTF8(rawBuffer)
        }
    }

    private static func recoveryDirectoryLeaf(
        from result: UMISXMPRecoveryFinalizeResult
    ) -> String {
        var bytes = result.recovery_directory_leaf
        return withUnsafeBytes(of: &bytes) { rawBuffer in
            decodeNullTerminatedUTF8(rawBuffer)
        }
    }

    private static func decodeNullTerminatedUTF8(_ rawBuffer: UnsafeRawBufferPointer) -> String {
        let end = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
        return String(decoding: rawBuffer[..<end], as: UTF8.self)
    }

    private static func bridgeDiagnostic(_ error: [CChar]) -> String {
        error.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, base.pointee != 0 else {
                return "No diagnostic was returned"
            }
            return String(cString: base)
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func requireBridgeSuccess(
        _ status: UMISXMPStatus,
        path: String,
        error: [CChar]
    ) throws {
        guard status == UInt32(UMIS_XMP_STATUS_OK) else {
            let message = Self.bridgeDiagnostic(error)
            if status == UInt32(UMIS_XMP_STATUS_CONCURRENT_MODIFICATION) {
                throw AssetMetadataError.concurrentModification(path)
            }
            if status == UInt32(UMIS_XMP_STATUS_SYMLINK_REJECTED) {
                throw UMISCoreError.symbolicLinkRejected(path)
            }
            if status == UInt32(UMIS_XMP_STATUS_NOT_REGULAR_FILE) {
                throw UMISCoreError.notRegularFile(path)
            }
            if status == UInt32(UMIS_XMP_STATUS_NO_SMART_HANDLER)
                || status == UInt32(UMIS_XMP_STATUS_EMBEDDED_UPDATE_UNAVAILABLE)
                || status == UInt32(UMIS_XMP_STATUS_SAFE_UPDATE_UNAVAILABLE) {
                throw AdobeXMPRatingServiceError.unsupportedEmbeddedFormat(path)
            }
            throw AdobeXMPRatingServiceError.bridge(
                status: status,
                path: path,
                message: message
            )
        }
    }

    private func pathExistsNoFollow(_ url: URL) throws -> Bool {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &value)
        }
        if result == 0 {
            guard (value.st_mode & S_IFMT) != S_IFLNK else {
                throw UMISCoreError.symbolicLinkRejected(url.path)
            }
            guard (value.st_mode & S_IFMT) == S_IFREG else {
                throw UMISCoreError.notRegularFile(url.path)
            }
            return true
        }
        if errno == ENOENT { return false }
        throw UMISCoreError.posix(operation: "lstat XMP sidecar", code: errno, path: url.path)
    }

    private func coordinateReading<Value>(
        _ url: URL,
        body: (URL) throws -> Value
    ) throws -> Value {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) {
            coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinationError {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: coordinationError.localizedDescription
            )
        }
        guard let result else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: "coordinator did not execute the embedded XMP read"
            )
        }
        return try result.get()
    }

    private func coordinateWriting<Value>(
        _ url: URL,
        body: (URL) throws -> Value
    ) throws -> Value {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
            coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinationError {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: coordinationError.localizedDescription
            )
        }
        guard let result else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: "coordinator did not execute the embedded XMP write"
            )
        }
        return try result.get()
    }
}

private extension UMISXMPFileIdentity {
    init(_ fingerprint: FileFingerprint) {
        self.init()
        device = fingerprint.device
        inode = fingerprint.inode
        byte_size = fingerprint.byteSize
        modified_seconds = fingerprint.modifiedSeconds
        modified_nanoseconds = fingerprint.modifiedNanoseconds
    }
}

private extension FileFingerprint {
    init(_ identity: UMISXMPFileIdentity) {
        self.init(
            device: identity.device,
            inode: identity.inode,
            byteSize: identity.byte_size,
            modifiedSeconds: identity.modified_seconds,
            modifiedNanoseconds: identity.modified_nanoseconds
        )
    }
}
