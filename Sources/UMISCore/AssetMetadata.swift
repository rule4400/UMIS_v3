import Darwin
import Foundation

/// Adobe XMP Basic `xmp:Rating` values.
///
/// Adobe defines `-1` as rejected, `0` as unrated, and `1...5` as star ratings.
/// Absence of the property is read as `.unrated`.
public enum AdobeRating: Int, CaseIterable, Codable, Hashable, Sendable {
    case rejected = -1
    case unrated = 0
    case oneStar = 1
    case twoStars = 2
    case threeStars = 3
    case fourStars = 4
    case fiveStars = 5

    public init(validating rawValue: Int) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw AssetMetadataError.invalidAdobeRating(rawValue)
        }
        self = value
    }

    public var starCount: Int? {
        rawValue >= 0 ? rawValue : nil
    }

    public var isRejected: Bool { self == .rejected }
}

/// A sidecar rating together with whether `xmp:Rating` was actually present in the XMP packet.
///
/// XMP defines an absent rating as zero, but callers that synchronize metadata must still be able
/// to distinguish an absent property from an explicitly stored zero.
public struct AdobeXMPSidecarRatingReadResult: Equatable, Sendable {
    public let rating: AdobeRating
    public let hasExplicitRating: Bool

    public init(rating: AdobeRating, hasExplicitRating: Bool) {
        self.rating = rating
        self.hasExplicitRating = hasExplicitRating
    }
}

/// Result of a descriptor-capability sidecar mutation. A non-nil warning means the requested
/// rating was durably read back, but the private recovery directory could not be proven unchanged
/// and was therefore retained instead of being deleted.
public struct AdobeXMPSidecarRatingWriteResult: Equatable, Sendable {
    public let sidecarURL: URL
    public let recoveryWarning: String?
    /// True when the committed rating was read back but recovery cleanup left any artifact that
    /// must be surfaced and must block the remainder of the current metadata batch.
    public let recoveryAttentionRequired: Bool

    public init(
        sidecarURL: URL,
        recoveryWarning: String?,
        recoveryAttentionRequired: Bool = false
    ) {
        self.sidecarURL = sidecarURL
        self.recoveryWarning = recoveryWarning
        self.recoveryAttentionRequired = recoveryAttentionRequired
    }
}

/// Sidecar naming variants encountered in photo and dynamic-media workflows.
public enum XMPSidecarNaming: String, Codable, Hashable, Sendable {
    /// `IMG_0001.CR3` -> `IMG_0001.xmp` (Adobe Camera Raw convention).
    case replacingMediaExtension
    /// `clip.mxf` -> `clip.mxf.xmp`. This is an explicit opt-in convention, not a claim that every
    /// Adobe dynamic-media handler uses this placement.
    case appendingToMediaFilename
}

/// Controls whether a sidecar service may adopt the other naming convention when it already
/// exists. Format-routing code must use `.strictPreferred`: a camera RAW `IMG_0001.xmp` must never
/// be mistaken for the sidecar of `IMG_0001.JPG`, `IMG_0001.MOV`, or another same-stem asset.
public enum XMPSidecarResolutionPolicy: String, Codable, Hashable, Sendable {
    /// Legacy/general-purpose behavior. Both names are inspected and two distinct files fail closed.
    case acceptExistingVariants
    /// Only `preferredNaming` is inspected, read, or written.
    case strictPreferred
}

enum AdobeXMPSidecarRecoveryTestFault: Hashable, Sendable {
    case replaceReplacementBeforeCommit
    case changeExistingMetadataBeforeCommit
    case replaceTargetAfterCommit
    case replaceRecoveryArtifactBeforeCleanup
    case changeTargetMetadataBeforeCleanup
    case failAfterOriginalCleanup
    case failAfterSealedManifestCleanup
    case failAfterPendingManifestCleanup
    case failAfterCleanupManifestCleanup
}

public enum AssetMetadataError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidAdobeRating(Int)
    case malformedXMP(path: String, reason: String)
    case conflictingXMPRatings(path: String)
    case ambiguousXMPSidecars(first: String, second: String)
    case concurrentModification(String)
    case hardLinkRejected(String)
    case recoveryRetained(path: String, recoveryDirectoryLeaf: String, reason: String)
    case invalidFinderLabelNumber(Int)
    case metadataCoordinationFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidAdobeRating(value):
            "Invalid Adobe XMP rating \(value); expected -1 or 0...5"
        case let .malformedXMP(path, reason):
            "Malformed XMP at \(path): \(reason)"
        case let .conflictingXMPRatings(path):
            "Conflicting xmp:Rating values at \(path)"
        case let .ambiguousXMPSidecars(first, second):
            "Both supported XMP sidecars exist; refusing to choose between \(first) and \(second)"
        case let .concurrentModification(path):
            "Metadata changed concurrently: \(path)"
        case let .hardLinkRejected(path):
            "Hard-linked files are not accepted as metadata mutation targets: \(path)"
        case let .recoveryRetained(path, recoveryDirectoryLeaf, reason):
            "Metadata recovery was retained for \(path) in \(recoveryDirectoryLeaf): \(reason)"
        case let .invalidFinderLabelNumber(number):
            "Invalid Finder label number \(number); expected 0...7"
        case let .metadataCoordinationFailed(path, reason):
            "Metadata coordination failed at \(path): \(reason)"
        }
    }
}

/// Reads and writes the Adobe-defined `xmp:Rating` property in a standard XMP sidecar without
/// rewriting the media file.
///
/// Existing RDF/XML is parsed and modified in place at the XML-node level. Unknown namespaces,
/// properties, comments, and processing instructions remain in the document. Malformed packets are
/// never replaced. The new packet is fully written and fsynced beside the sidecar, then atomically
/// renamed into place. Media and sidecar symbolic links and hard links are rejected.
///
/// This service intentionally does not claim embedded-XMP compatibility. Adobe applications usually
/// use sidecars for proprietary camera RAW and some dynamic-media formats, while JPEG, TIFF, PSD,
/// DNG, and several video containers may use embedded XMP instead. Whether an Adobe application
/// consumes a sidecar for a particular format also depends on that application's settings.
public struct AdobeXMPSidecarRatingService: Sendable {
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"

    public let preferredNaming: XMPSidecarNaming
    public let resolutionPolicy: XMPSidecarResolutionPolicy
    private let recoveryTestFault: AdobeXMPSidecarRecoveryTestFault?

    public init(
        preferredNaming: XMPSidecarNaming = .replacingMediaExtension,
        resolutionPolicy: XMPSidecarResolutionPolicy = .acceptExistingVariants
    ) {
        self.preferredNaming = preferredNaming
        self.resolutionPolicy = resolutionPolicy
        recoveryTestFault = nil
    }

    init(
        preferredNaming: XMPSidecarNaming,
        resolutionPolicy: XMPSidecarResolutionPolicy,
        recoveryTestFault: AdobeXMPSidecarRecoveryTestFault
    ) {
        self.preferredNaming = preferredNaming
        self.resolutionPolicy = resolutionPolicy
        self.recoveryTestFault = recoveryTestFault
    }

    /// Resolves an existing sidecar under either supported naming convention. If neither exists,
    /// returns the configured preferred path. Two distinct existing sidecars are ambiguous and are
    /// rejected so metadata is never silently split or overwritten.
    public func sidecarURL(forMediaAt mediaURL: URL) throws -> URL {
        try Self.requireRegularFileNoFollow(mediaURL)
        guard mediaURL.pathExtension.caseInsensitiveCompare("xmp") != .orderedSame else {
            throw UMISCoreError.invalidPath("An XMP file cannot be its own media sidecar: \(mediaURL.path)")
        }
        let replacing = Self.sidecarCandidate(for: mediaURL, naming: .replacingMediaExtension)
        let appending = Self.sidecarCandidate(for: mediaURL, naming: .appendingToMediaFilename)

        // An `.xmp` input would make one candidate equal the media itself. Such a file is metadata,
        // not a supported media target.
        guard replacing.standardizedFileURL != mediaURL.standardizedFileURL,
              appending.standardizedFileURL != mediaURL.standardizedFileURL else {
            throw UMISCoreError.invalidPath("An XMP file cannot be its own media sidecar: \(mediaURL.path)")
        }

        if resolutionPolicy == .strictPreferred {
            let preferred = preferredNaming == .replacingMediaExtension ? replacing : appending
            return try Self.existingSidecar(matchingExtensionCaseInsensitively: preferred) ?? preferred
        }

        let replacingExisting = try Self.existingSidecar(matchingExtensionCaseInsensitively: replacing)
        let appendingExisting = replacing.standardizedFileURL == appending.standardizedFileURL
            ? replacingExisting
            : try Self.existingSidecar(matchingExtensionCaseInsensitively: appending)

        if let replacingExisting, let appendingExisting,
           replacingExisting.standardizedFileURL != appendingExisting.standardizedFileURL {
            throw AssetMetadataError.ambiguousXMPSidecars(
                first: replacingExisting.path,
                second: appendingExisting.path
            )
        }
        if let replacingExisting { return replacingExisting }
        if let appendingExisting { return appendingExisting }
        return Self.sidecarCandidate(for: mediaURL, naming: preferredNaming)
    }

    public func readRating(
        forMediaAt mediaURL: URL,
        expectedMediaFingerprint: FileFingerprint? = nil
    ) throws -> AdobeRating {
        try readRatingResult(
            forMediaAt: mediaURL,
            expectedMediaFingerprint: expectedMediaFingerprint
        ).rating
    }

    public func readRatingResult(
        forMediaAt mediaURL: URL,
        expectedMediaFingerprint: FileFingerprint? = nil
    ) throws -> AdobeXMPSidecarRatingReadResult {
        try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
        let sidecar = try sidecarURL(forMediaAt: mediaURL)
        guard try Self.pathExistsWithoutFollowingSymlink(sidecar) else {
            try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
            return AdobeXMPSidecarRatingReadResult(rating: .unrated, hasExplicitRating: false)
        }
        let result = try Self.coordinateReading(sidecar) { coordinatedURL in
            let loaded = try Self.readRegularFileNoFollow(coordinatedURL)
            let document = try Self.parseXMP(loaded.data, at: coordinatedURL)
            return try Self.ratingResult(in: document, at: coordinatedURL)
        }
        try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
        return result
    }

    /// Compatibility-test adapter only. Production metadata writes use the descriptor overload.
    @discardableResult
    func writeRating(
        _ rating: AdobeRating,
        forMediaAt mediaURL: URL,
        expectedMediaFingerprint: FileFingerprint? = nil
    ) throws -> URL {
        try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
        let sidecar = try sidecarURL(forMediaAt: mediaURL)
        try Self.coordinateWriting(sidecar) { coordinatedURL in
            try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
            let loaded: LoadedMetadataFile?
            if try Self.pathExistsWithoutFollowingSymlink(coordinatedURL) {
                loaded = try Self.readRegularFileNoFollow(coordinatedURL)
            } else {
                loaded = nil
            }

            let document: XMLDocument
            if let loaded {
                document = try Self.parseXMP(loaded.data, at: coordinatedURL)
                // Refuse to conceal invalid/fractional/conflicting external values. The caller can
                // surface the problem for an explicit repair workflow instead of silently
                // normalizing metadata it did not understand.
                _ = try Self.rating(in: document, at: coordinatedURL)
            } else {
                document = try Self.makeNewXMPDocument()
            }
            try Self.setRating(rating, in: document, at: coordinatedURL)
            let encoded = document.xmlData(options: [.nodePreserveAll])
            guard !encoded.isEmpty else {
                throw AssetMetadataError.malformedXMP(
                    path: coordinatedURL.path,
                    reason: "serialization returned no data"
                )
            }
            try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
            try Self.atomicWrite(
                encoded,
                to: coordinatedURL,
                replacing: loaded?.snapshot
            )
        }
        try Self.requireExpectedMediaFingerprint(expectedMediaFingerprint, at: mediaURL)
        return sidecar
    }

    /// Reads a sidecar using only a borrowed parent-directory capability and one media leaf.
    /// `displayURL` is diagnostic/UI context and never supplies filesystem authority.
    public func readRatingResult(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> AdobeXMPSidecarRatingReadResult {
        let mediaDescriptor = try Self.openAndValidateMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        defer { Darwin.close(mediaDescriptor) }
        let resolved = try anchoredSidecar(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        guard let expectedSidecar = resolved.snapshot else {
            try Self.requireMediaCapability(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                mediaDescriptor: mediaDescriptor,
                displayURL: displayURL,
                expectedFingerprint: expectedMediaFingerprint
            )
            return AdobeXMPSidecarRatingReadResult(rating: .unrated, hasExplicitRating: false)
        }
        let loaded = try Self.readAnchoredRegularFile(
            parentFileDescriptor: parentFileDescriptor,
            leafName: resolved.leaf,
            expectedSnapshot: expectedSidecar,
            displayURL: resolved.displayURL
        )
        let document = try Self.parseXMP(loaded.data, at: resolved.displayURL)
        let result = try Self.ratingResult(in: document, at: resolved.displayURL)
        try Self.requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        return result
    }

    public func readRating(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> AdobeRating {
        try readRatingResult(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedMediaFingerprint
        ).rating
    }

    public func sidecarExists(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> Bool {
        let mediaDescriptor = try Self.openAndValidateMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        defer { Darwin.close(mediaDescriptor) }
        let resolved = try anchoredSidecar(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        try Self.requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        return resolved.snapshot != nil
    }

    /// Resolves the exact sidecar URL used by the descriptor-capability route without deriving
    /// filesystem authority from that URL. This is intended for an outer NSFileCoordinator plan.
    public func resolvedSidecarURL(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> URL {
        let mediaDescriptor = try Self.openAndValidateMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        defer { Darwin.close(mediaDescriptor) }
        let resolved = try anchoredSidecar(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        try Self.requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        return resolved.displayURL
    }

    /// Internal descriptor-capability primitive used by the policy-enforcing top-level Adobe
    /// service. Keeping mutation package-internal prevents callers from bypassing verified-receipt,
    /// volume, recovery-authorization, and format-routing gates. Existing sidecars use RENAME_SWAP
    /// and new sidecars use RENAME_EXCL; ACLs, xattrs, and mode are copied descriptor-to-descriptor.
    @discardableResult
    func writeRating(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> URL {
        try writeRatingResult(
            rating,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedMediaFingerprint
        ).sidecarURL
    }

    @discardableResult
    func writeRatingResult(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> AdobeXMPSidecarRatingWriteResult {
        try writeRatingResultImpl(
            rating,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedMediaFingerprint,
            recoveryGuardAlreadySatisfied: false
        )
    }

    /// Used only by the top-level Adobe service after it has validated either a clean-tree batch
    /// authorization or the direct-parent recovery guard. Keeping this internal prevents a second
    /// O(N) enumeration for the same logical mutation without weakening the standalone public API.
    func writeRatingResultAfterTopLevelRecoveryCheck(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint
    ) throws -> AdobeXMPSidecarRatingWriteResult {
        try writeRatingResultImpl(
            rating,
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedMediaFingerprint: expectedMediaFingerprint,
            recoveryGuardAlreadySatisfied: true
        )
    }

    private func writeRatingResultImpl(
        _ rating: AdobeRating,
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedMediaFingerprint: FileFingerprint,
        recoveryGuardAlreadySatisfied: Bool
    ) throws -> AdobeXMPSidecarRatingWriteResult {
        if !recoveryGuardAlreadySatisfied {
            try MetadataRecoveryWriteGuard.requireNoPendingRecovery(
                parentFileDescriptor: parentFileDescriptor,
                displayURL: displayURL
            )
        }
        let mediaDescriptor = try Self.openAndValidateMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        defer { Darwin.close(mediaDescriptor) }

        let resolved = try anchoredSidecar(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            displayURL: displayURL
        )
        var existingDescriptor: Int32 = -1
        var loaded: LoadedMetadataFile?
        if let expectedSidecar = resolved.snapshot {
            existingDescriptor = try Self.openAnchoredRegularFile(
                parentFileDescriptor: parentFileDescriptor,
                leafName: resolved.leaf,
                expectedSnapshot: expectedSidecar,
                displayURL: resolved.displayURL,
                writable: false
            )
            do {
                loaded = try Self.readAnchoredRegularFile(
                    descriptor: existingDescriptor,
                    parentFileDescriptor: parentFileDescriptor,
                    leafName: resolved.leaf,
                    expectedSnapshot: expectedSidecar,
                    displayURL: resolved.displayURL
                )
            } catch {
                Darwin.close(existingDescriptor)
                throw error
            }
        }
        defer {
            if existingDescriptor >= 0 { Darwin.close(existingDescriptor) }
        }

        let document: XMLDocument
        if let loaded {
            document = try Self.parseXMP(loaded.data, at: resolved.displayURL)
            _ = try Self.rating(in: document, at: resolved.displayURL)
        } else {
            document = try Self.makeNewXMPDocument()
        }
        try Self.setRating(rating, in: document, at: resolved.displayURL)
        let encoded = document.xmlData(options: [.nodePreserveAll])
        guard !encoded.isEmpty else {
            throw AssetMetadataError.malformedXMP(
                path: resolved.displayURL.path,
                reason: "serialization returned no data"
            )
        }

        let commit = try Self.commitAnchoredSidecar(
            encoded,
            parentFileDescriptor: parentFileDescriptor,
            destinationLeaf: resolved.leaf,
            destinationDisplayURL: resolved.displayURL,
            replacing: resolved.snapshot,
            existingDescriptor: existingDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            mediaDisplayURL: displayURL,
            expectedMediaFingerprint: expectedMediaFingerprint,
            testFault: recoveryTestFault
        )
        try Self.requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: displayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        do {
            let persisted = try Self.readAnchoredRegularFile(
                parentFileDescriptor: parentFileDescriptor,
                leafName: resolved.leaf,
                expectedSnapshot: commit.committedSnapshot,
                displayURL: resolved.displayURL
            )
            let persistedDocument = try Self.parseXMP(persisted.data, at: resolved.displayURL)
            let persistedResult = try Self.ratingResult(in: persistedDocument, at: resolved.displayURL)
            guard persistedResult.rating == rating, persistedResult.hasExplicitRating else {
                throw AssetMetadataError.concurrentModification(resolved.displayURL.path)
            }
            try Self.requireMediaCapability(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                mediaDescriptor: mediaDescriptor,
                displayURL: displayURL,
                expectedFingerprint: expectedMediaFingerprint
            )
            let cleanup = commit.recovery.finalizeAfterVerifiedReadback(
                committedSnapshot: commit.committedSnapshot,
                displayURL: resolved.displayURL
            )
            if !cleanup.committedSuccessMayReturn {
                throw AssetMetadataError.recoveryRetained(
                    path: resolved.displayURL.path,
                    recoveryDirectoryLeaf: commit.recovery.directoryLeaf,
                    reason: cleanup.warning
                        ?? "Sidecar recovery integrity could not be verified after readback"
                )
            }
            return AdobeXMPSidecarRatingWriteResult(
                sidecarURL: resolved.displayURL,
                recoveryWarning: cleanup.warning,
                recoveryAttentionRequired: cleanup.cleanupIncomplete
            )
        } catch let metadataError as AssetMetadataError {
            if case .recoveryRetained = metadataError { throw metadataError }
            let retained = commit.recovery.retain(
                reason: "Sidecar upper-layer readback did not verify: \(String(describing: metadataError))"
            )
            throw AssetMetadataError.recoveryRetained(
                path: resolved.displayURL.path,
                recoveryDirectoryLeaf: commit.recovery.directoryLeaf,
                reason: retained.warning ?? String(describing: metadataError)
            )
        } catch {
            let retained = commit.recovery.retain(
                reason: "Sidecar upper-layer readback did not verify: \(String(describing: error))"
            )
            throw AssetMetadataError.recoveryRetained(
                path: resolved.displayURL.path,
                recoveryDirectoryLeaf: commit.recovery.directoryLeaf,
                reason: retained.warning ?? String(describing: error)
            )
        }
    }

    private static func requireExpectedMediaFingerprint(
        _ expected: FileFingerprint?,
        at mediaURL: URL
    ) throws {
        guard let expected else { return }
        try requireRegularFileNoFollow(mediaURL)
        guard try FileFingerprint.capture(at: mediaURL) == expected else {
            throw AssetMetadataError.concurrentModification(mediaURL.path)
        }
    }

    private struct AnchoredSidecarResolution {
        let leaf: String
        let displayURL: URL
        let snapshot: MetadataFileSnapshot?
    }

    private struct AnchoredSidecarCommit {
        let committedSnapshot: MetadataFileSnapshot
        let recovery: AnchoredSidecarRecovery
    }

    /// A two-phase recovery transaction for capability-bound sidecars. The directory and every
    /// entry stay open across durable readback. Cleanup is deliberately best-effort under the
    /// documented non-malicious-process threat model because macOS has no exact-inode unlink API.
    private final class AnchoredSidecarRecovery {
        struct CleanupOutcome {
            let warning: String?
            let originalBackupRetained: Bool
            let cleanupIncomplete: Bool
            /// A warning-only committed result is permitted only when no original existed or Core
            /// itself already verified unlink of the old inode. A substituted/missing recovery
            /// artifact before that boundary is a structured failure even when `st_nlink == 0`.
            let committedSuccessMayReturn: Bool
        }

        private struct Artifact {
            var leaf: String
            var descriptor: Int32
            var snapshot: MetadataFileSnapshot
        }

        private var parentDescriptor: Int32 = -1
        private var directoryDescriptor: Int32 = -1
        private var pendingManifestDescriptor: Int32 = -1
        private var sealedManifestDescriptor: Int32 = -1
        private var cleanupManifestDescriptor: Int32 = -1
        private var oldArtifact: Artifact?
        private let targetLeaf: String
        private let originalSnapshot: MetadataFileSnapshot?
        private let testFault: AdobeXMPSidecarRecoveryTestFault?
        private(set) var directoryLeaf = ""
        private var parentDevice: UInt64 = 0
        private var parentInode: UInt64 = 0
        private var directorySnapshot: MetadataFileSnapshot?
        private var pendingManifestSnapshot: MetadataFileSnapshot?
        private var sealedManifestSnapshot: MetadataFileSnapshot?
        private var cleanupManifestSnapshot: MetadataFileSnapshot?
        private var committedSnapshot: MetadataFileSnapshot?
        private var originalWasDeleted = false

        init(
            parentFileDescriptor: Int32,
            targetLeaf: String,
            originalSnapshot: MetadataFileSnapshot?,
            testFault: AdobeXMPSidecarRecoveryTestFault?,
            displayURL: URL
        ) throws {
            self.targetLeaf = targetLeaf
            self.originalSnapshot = originalSnapshot
            self.testFault = testFault
            parentDescriptor = Darwin.fcntl(parentFileDescriptor, F_DUPFD_CLOEXEC, 0)
            guard parentDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "duplicate sidecar recovery parent",
                    code: errno,
                    path: displayURL.path
                )
            }
            var parentStatus = stat()
            guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
                  (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
                throw UMISCoreError.posix(
                    operation: "validate sidecar recovery parent",
                    code: errno == 0 ? ENOTDIR : errno,
                    path: displayURL.path
                )
            }
            parentDevice = UInt64(parentStatus.st_dev)
            parentInode = UInt64(parentStatus.st_ino)

            for _ in 0 ..< 128 {
                let candidate = ".umis-xmp-recovery-\(Self.randomHex())"
                let result = candidate.withCString {
                    Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
                }
                if result == 0 {
                    directoryLeaf = candidate
                    break
                }
                if errno != EEXIST {
                    throw UMISCoreError.posix(
                        operation: "mkdirat sidecar recovery",
                        code: errno,
                        path: displayURL.path
                    )
                }
            }
            guard !directoryLeaf.isEmpty else {
                throw UMISCoreError.posix(
                    operation: "allocate sidecar recovery directory",
                    code: EEXIST,
                    path: displayURL.path
                )
            }
            directoryDescriptor = directoryLeaf.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard directoryDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "open sidecar recovery directory",
                    code: errno,
                    path: displayURL.path
                )
            }
            guard Darwin.fchmod(directoryDescriptor, S_IRWXU) == 0 else {
                throw UMISCoreError.posix(
                    operation: "restrict sidecar recovery directory",
                    code: errno,
                    path: displayURL.path
                )
            }
            try refreshDirectorySnapshot(displayURL: displayURL)

            pendingManifestDescriptor = "manifest.pending.json".withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard pendingManifestDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "create pending recovery manifest",
                    code: errno,
                    path: displayURL.path
                )
            }
            let pending = try manifestData(
                state: "pendingCommit",
                committed: nil,
                artifact: nil
            )
            try pending.withUnsafeBytes {
                try AdobeXMPSidecarRatingService.writeAll(
                    descriptor: pendingManifestDescriptor,
                    bytes: $0,
                    displayPath: displayURL.path
                )
            }
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                pendingManifestDescriptor,
                displayPath: displayURL.path
            )
            pendingManifestSnapshot = try validatedRegularBinding(
                descriptor: pendingManifestDescriptor,
                leaf: "manifest.pending.json",
                expected: nil,
                displayURL: displayURL
            )
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                directoryDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                parentDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
            try refreshDirectorySnapshot(displayURL: displayURL)
        }

        deinit {
            if let oldArtifact { Darwin.close(oldArtifact.descriptor) }
            if cleanupManifestDescriptor >= 0 { Darwin.close(cleanupManifestDescriptor) }
            if sealedManifestDescriptor >= 0 { Darwin.close(sealedManifestDescriptor) }
            if pendingManifestDescriptor >= 0 { Darwin.close(pendingManifestDescriptor) }
            if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
            if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
        }

        func makeReplacement(displayURL: URL) throws -> (descriptor: Int32, leaf: String) {
            for _ in 0 ..< 128 {
                let leaf = "replacement-\(Self.randomHex()).partial"
                let descriptor = leaf.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        S_IRUSR | S_IWUSR
                    )
                }
                if descriptor >= 0 { return (descriptor, leaf) }
                if errno != EEXIST {
                    throw UMISCoreError.posix(
                        operation: "create sidecar recovery replacement",
                        code: errno,
                        path: displayURL.path
                    )
                }
            }
            throw UMISCoreError.posix(
                operation: "allocate sidecar recovery replacement",
                code: EEXIST,
                path: displayURL.path
            )
        }

        func replacementDirectoryDescriptor() -> Int32 { directoryDescriptor }

        func injectReplacementFaultIfRequested(
            replacementLeaf: String,
            displayURL: URL
        ) throws {
            guard testFault == .replaceReplacementBeforeCommit else { return }
            try replaceLeafWithTestFile(
                parentDescriptor: directoryDescriptor,
                leaf: replacementLeaf,
                displayURL: displayURL
            )
        }

        func injectPostCommitFaultIfRequested(displayURL: URL) throws {
            guard testFault == .replaceTargetAfterCommit else { return }
            try replaceLeafWithTestFile(
                parentDescriptor: parentDescriptor,
                leaf: targetLeaf,
                displayURL: displayURL
            )
        }

        func replacementSnapshot(
            descriptor: Int32,
            leaf: String,
            expected: MetadataFileSnapshot? = nil,
            displayURL: URL
        ) throws -> MetadataFileSnapshot {
            try validatedRegularBinding(
                descriptor: descriptor,
                leaf: leaf,
                expected: expected,
                displayURL: displayURL
            )
        }

        func bindOldArtifact(
            leaf: String,
            descriptor: Int32,
            displayURL: URL
        ) throws {
            let snapshot = try validatedRegularBinding(
                descriptor: descriptor,
                leaf: leaf,
                expected: nil,
                displayURL: displayURL
            )
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else {
                throw UMISCoreError.posix(
                    operation: "duplicate old sidecar recovery artifact",
                    code: errno,
                    path: displayURL.path
                )
            }
            if let oldArtifact { Darwin.close(oldArtifact.descriptor) }
            oldArtifact = Artifact(leaf: leaf, descriptor: duplicate, snapshot: snapshot)
        }

        func seal(
            committedDescriptor: Int32,
            committedSnapshot: MetadataFileSnapshot,
            displayURL: URL
        ) throws {
            _ = try validatedTargetBinding(
                descriptor: committedDescriptor,
                expected: committedSnapshot,
                displayURL: displayURL
            )
            if let oldArtifact {
                _ = try validatedRegularBinding(
                    descriptor: oldArtifact.descriptor,
                    leaf: oldArtifact.leaf,
                    expected: oldArtifact.snapshot,
                    displayURL: displayURL
                )
            }
            guard let pendingManifestSnapshot else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            _ = try validatedRegularBinding(
                descriptor: pendingManifestDescriptor,
                leaf: "manifest.pending.json",
                expected: pendingManifestSnapshot,
                displayURL: displayURL
            )

            sealedManifestDescriptor = "manifest.sealed.json".withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard sealedManifestDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "create sealed recovery manifest",
                    code: errno,
                    path: displayURL.path
                )
            }
            let sealed = try manifestData(
                state: "awaitingUpperReadback",
                committed: committedSnapshot,
                artifact: oldArtifact?.snapshot
            )
            try sealed.withUnsafeBytes {
                try AdobeXMPSidecarRatingService.writeAll(
                    descriptor: sealedManifestDescriptor,
                    bytes: $0,
                    displayPath: displayURL.path
                )
            }
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                sealedManifestDescriptor,
                displayPath: displayURL.path
            )
            sealedManifestSnapshot = try validatedRegularBinding(
                descriptor: sealedManifestDescriptor,
                leaf: "manifest.sealed.json",
                expected: nil,
                displayURL: displayURL
            )
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                directoryDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                parentDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
            try refreshDirectorySnapshot(displayURL: displayURL)
            self.committedSnapshot = committedSnapshot
        }

        func finalizeAfterVerifiedReadback(
            committedSnapshot: MetadataFileSnapshot,
            displayURL: URL
        ) -> CleanupOutcome {
            do {
                guard self.committedSnapshot == committedSnapshot else {
                    return retain(reason: "Committed sidecar witness changed before recovery cleanup")
                }
                try injectCleanupFaultIfRequested(displayURL: displayURL)
                try validateParent(displayURL: displayURL)
                guard try AdobeXMPSidecarRatingService.snapshotAt(
                    parentFileDescriptor: parentDescriptor,
                    leafName: targetLeaf,
                    displayURL: displayURL
                ) == committedSnapshot else {
                    throw AssetMetadataError.concurrentModification(displayURL.path)
                }
                try validateDirectory(displayURL: displayURL)
                try validateManifests(displayURL: displayURL)
                if let oldArtifact {
                    _ = try validatedRegularBinding(
                        descriptor: oldArtifact.descriptor,
                        leaf: oldArtifact.leaf,
                        expected: oldArtifact.snapshot,
                        displayURL: displayURL
                    )
                    // Recheck the committed target and private directory immediately before the
                    // critical old-original unlink. Random 0700 recovery storage prevents normal
                    // Adobe/Finder processes from discovering or replacing this leaf.
                    guard try AdobeXMPSidecarRatingService.snapshotAt(
                        parentFileDescriptor: parentDescriptor,
                        leafName: targetLeaf,
                        displayURL: displayURL
                    ) == committedSnapshot else {
                        return retain(reason: "Committed sidecar changed before old-data cleanup")
                    }
                    try validateDirectory(displayURL: displayURL)
                    let unlinkResult = oldArtifact.leaf.withCString {
                        Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }
                    guard unlinkResult == 0 else {
                        return retain(reason: "Verified old sidecar could not be removed")
                    }
                    var after = stat()
                    guard Darwin.fstat(oldArtifact.descriptor, &after) == 0,
                          after.st_nlink == 0 else {
                        return retain(reason: "Old sidecar removal could not be verified")
                    }
                    originalWasDeleted = true
                    try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                        directoryDescriptor,
                        displayPath: displayURL.deletingLastPathComponent().path
                    )
                    try refreshDirectorySnapshot(displayURL: displayURL)
                    try recordOriginalRemoved(displayURL: displayURL)
                    if testFault == .failAfterOriginalCleanup {
                        return retain(
                            reason: "Intentional test failure after verified old-sidecar unlink"
                        )
                    }
                }

                guard try AdobeXMPSidecarRatingService.snapshotAt(
                    parentFileDescriptor: parentDescriptor,
                    leafName: targetLeaf,
                    displayURL: displayURL
                ) == committedSnapshot else {
                    return retain(reason: "Committed sidecar changed during recovery cleanup")
                }
                try validateDirectory(displayURL: displayURL)
                try validateManifests(displayURL: displayURL)
                // Keep manifest.cleanup.json linked until the older manifests are gone. The
                // inspector prioritizes it because it records that the old original has already
                // been unlinked. Deleting it first could leave sealed/pending state after a crash
                // and falsely advertise a recoverable original backup.
                try unlinkManifest(
                    leaf: "manifest.sealed.json",
                    descriptor: sealedManifestDescriptor,
                    displayURL: displayURL
                )
                sealedManifestSnapshot = nil
                try refreshDirectorySnapshot(displayURL: displayURL)
                if testFault == .failAfterSealedManifestCleanup {
                    return retain(
                        reason: "Intentional test failure after sealed-manifest cleanup"
                    )
                }
                guard try AdobeXMPSidecarRatingService.snapshotAt(
                    parentFileDescriptor: parentDescriptor,
                    leafName: targetLeaf,
                    displayURL: displayURL
                ) == committedSnapshot else {
                    return retain(reason: "Committed sidecar changed after sealed manifest cleanup")
                }
                try validateDirectory(displayURL: displayURL)
                guard let pendingManifestSnapshot else {
                    return retain(reason: "Pending recovery manifest witness is unavailable")
                }
                _ = try validatedRegularBinding(
                    descriptor: pendingManifestDescriptor,
                    leaf: "manifest.pending.json",
                    expected: pendingManifestSnapshot,
                    displayURL: displayURL
                )
                if let cleanupManifestSnapshot {
                    _ = try validatedRegularBinding(
                        descriptor: cleanupManifestDescriptor,
                        leaf: "manifest.cleanup.json",
                        expected: cleanupManifestSnapshot,
                        displayURL: displayURL
                    )
                }
                try unlinkManifest(
                    leaf: "manifest.pending.json",
                    descriptor: pendingManifestDescriptor,
                    displayURL: displayURL
                )
                self.pendingManifestSnapshot = nil
                try refreshDirectorySnapshot(displayURL: displayURL)
                if testFault == .failAfterPendingManifestCleanup {
                    return retain(
                        reason: "Intentional test failure after pending-manifest cleanup"
                    )
                }
                if let cleanupManifestSnapshot {
                    guard try AdobeXMPSidecarRatingService.snapshotAt(
                        parentFileDescriptor: parentDescriptor,
                        leafName: targetLeaf,
                        displayURL: displayURL
                    ) == committedSnapshot else {
                        return retain(reason: "Committed sidecar changed before cleanup-state manifest removal")
                    }
                    try validateDirectory(displayURL: displayURL)
                    _ = try validatedRegularBinding(
                        descriptor: cleanupManifestDescriptor,
                        leaf: "manifest.cleanup.json",
                        expected: cleanupManifestSnapshot,
                        displayURL: displayURL
                    )
                    try unlinkManifest(
                        leaf: "manifest.cleanup.json",
                        descriptor: cleanupManifestDescriptor,
                        displayURL: displayURL
                    )
                    self.cleanupManifestSnapshot = nil
                    try refreshDirectorySnapshot(displayURL: displayURL)
                    if testFault == .failAfterCleanupManifestCleanup {
                        return retain(
                            reason: "Intentional test failure after cleanup-state manifest removal"
                        )
                    }
                }
                guard try AdobeXMPSidecarRatingService.snapshotAt(
                    parentFileDescriptor: parentDescriptor,
                    leafName: targetLeaf,
                    displayURL: displayURL
                ) == committedSnapshot else {
                    return retain(reason: "Committed sidecar changed before recovery-directory removal")
                }
                try validateDirectory(displayURL: displayURL)
                let removeDirectory = directoryLeaf.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                }
                guard removeDirectory == 0 else {
                    return retain(reason: "Empty sidecar recovery directory could not be removed")
                }
                // APFS keeps an open-but-unlinked directory descriptor at link count one, so
                // `st_nlink == 0` is not a valid removal witness for directories. Verify that the
                // exact random leaf is absent from the held parent and that the held directory
                // descriptor still identifies the private directory we removed.
                var directoryAfter = stat()
                var namedAfter = stat()
                let namedLookup = directoryLeaf.withCString {
                    Darwin.fstatat(parentDescriptor, $0, &namedAfter, AT_SYMLINK_NOFOLLOW)
                }
                let namedLookupError = errno
                guard let expectedDirectory = directorySnapshot,
                      Darwin.fstat(directoryDescriptor, &directoryAfter) == 0,
                      MetadataFileSnapshot(directoryAfter).device == expectedDirectory.device,
                      MetadataFileSnapshot(directoryAfter).inode == expectedDirectory.inode,
                      namedLookup != 0,
                      namedLookupError == ENOENT else {
                    return retain(reason: "Recovery-directory removal could not be verified")
                }
                try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                    parentDescriptor,
                    displayPath: displayURL.deletingLastPathComponent().path
                )
                return CleanupOutcome(
                    warning: nil,
                    originalBackupRetained: false,
                    cleanupIncomplete: false,
                    committedSuccessMayReturn: true
                )
            } catch {
                return retain(reason: "Recovery cleanup verification failed: \(error.localizedDescription)")
            }
        }

        func retain(reason: String) -> CleanupOutcome {
            let originalBackupRetained: Bool
            if let oldArtifact, !originalWasDeleted {
                var status = stat()
                originalBackupRetained = Darwin.fstat(oldArtifact.descriptor, &status) == 0
                    && status.st_nlink > 0
            } else {
                originalBackupRetained = false
            }
            let warning: String
            if originalBackupRetained {
                warning = "\(reason); original sidecar recovery data was retained in \(directoryLeaf)"
            } else if oldArtifact != nil {
                warning = "\(reason); old sidecar is no longer linked, but cleanup residue remains in \(directoryLeaf)"
            } else {
                warning = "\(reason); no original sidecar existed, but cleanup residue remains in \(directoryLeaf)"
            }
            return CleanupOutcome(
                warning: warning,
                originalBackupRetained: originalBackupRetained,
                cleanupIncomplete: true,
                committedSuccessMayReturn: oldArtifact == nil || originalWasDeleted
            )
        }

        private func validateParent(displayURL: URL) throws {
            var status = stat()
            guard Darwin.fstat(parentDescriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(status.st_dev) == parentDevice,
                  UInt64(status.st_ino) == parentInode else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
        }

        private func injectCleanupFaultIfRequested(displayURL: URL) throws {
            switch testFault {
            case .replaceRecoveryArtifactBeforeCleanup:
                if let oldArtifact {
                    try replaceLeafWithTestFile(
                        parentDescriptor: directoryDescriptor,
                        leaf: oldArtifact.leaf,
                        displayURL: displayURL
                    )
                }
            case .changeTargetMetadataBeforeCleanup:
                let descriptor = targetLeaf.withCString {
                    Darwin.openat(parentDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw UMISCoreError.posix(
                        operation: "open test target metadata fault",
                        code: errno,
                        path: displayURL.path
                    )
                }
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0,
                      Darwin.fchmod(descriptor, status.st_mode ^ S_IXUSR) == 0 else {
                    throw UMISCoreError.posix(
                        operation: "inject test target metadata fault",
                        code: errno,
                        path: displayURL.path
                    )
                }
            default:
                break
            }
        }

        /// Persists the post-original boundary before any later cleanup. If the process crashes
        /// after the old inode is unlinked, the next scan can distinguish cleanup residue from an
        /// actually retained backup instead of presenting a false restoration claim.
        private func recordOriginalRemoved(displayURL: URL) throws {
            cleanupManifestDescriptor = "manifest.cleanup.json".withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard cleanupManifestDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "create post-original recovery manifest",
                    code: errno,
                    path: displayURL.path
                )
            }
            let cleanup = try manifestData(
                state: "committedOriginalRemoved",
                committed: committedSnapshot,
                artifact: nil,
                includeOriginal: false
            )
            try cleanup.withUnsafeBytes {
                try AdobeXMPSidecarRatingService.writeAll(
                    descriptor: cleanupManifestDescriptor,
                    bytes: $0,
                    displayPath: displayURL.path
                )
            }
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                cleanupManifestDescriptor,
                displayPath: displayURL.path
            )
            cleanupManifestSnapshot = try validatedRegularBinding(
                descriptor: cleanupManifestDescriptor,
                leaf: "manifest.cleanup.json",
                expected: nil,
                displayURL: displayURL
            )
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                directoryDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
            try refreshDirectorySnapshot(displayURL: displayURL)
        }

        private func replaceLeafWithTestFile(
            parentDescriptor: Int32,
            leaf: String,
            displayURL: URL
        ) throws {
            let attackerLeaf = "test-attacker-\(Self.randomHex())"
            let descriptor = attackerLeaf.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "create metadata recovery test replacement",
                    code: errno,
                    path: displayURL.path
                )
            }
            defer { Darwin.close(descriptor) }
            let marker = Data("intentional-test-replacement".utf8)
            try marker.withUnsafeBytes {
                try AdobeXMPSidecarRatingService.writeAll(
                    descriptor: descriptor,
                    bytes: $0,
                    displayPath: displayURL.path
                )
            }
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                descriptor,
                displayPath: displayURL.path
            )
            let renameResult = attackerLeaf.withCString { source in
                leaf.withCString { destination in
                    Darwin.renameat(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination
                    )
                }
            }
            guard renameResult == 0 else {
                throw UMISCoreError.posix(
                    operation: "inject metadata recovery test replacement",
                    code: errno,
                    path: displayURL.path
                )
            }
        }

        private func validateDirectory(displayURL: URL) throws {
            guard let expected = directorySnapshot else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            var descriptorStatus = stat()
            var leafStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &descriptorStatus) == 0,
                  (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
                  (descriptorStatus.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            let lookup = directoryLeaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &leafStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0,
                  (leafStatus.st_mode & S_IFMT) == S_IFDIR,
                  MetadataFileSnapshot(descriptorStatus) == expected,
                  MetadataFileSnapshot(leafStatus) == expected else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
        }

        private func refreshDirectorySnapshot(displayURL: URL) throws {
            var descriptorStatus = stat()
            var leafStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &descriptorStatus) == 0,
                  (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
                  (descriptorStatus.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            let lookup = directoryLeaf.withCString {
                Darwin.fstatat(parentDescriptor, $0, &leafStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0,
                  MetadataFileSnapshot(descriptorStatus) == MetadataFileSnapshot(leafStatus) else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            directorySnapshot = MetadataFileSnapshot(descriptorStatus)
        }

        private func validatedTargetBinding(
            descriptor: Int32,
            expected: MetadataFileSnapshot,
            displayURL: URL
        ) throws -> MetadataFileSnapshot {
            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
                throw UMISCoreError.posix(
                    operation: "fstat committed sidecar",
                    code: errno,
                    path: displayURL.path
                )
            }
            try AdobeXMPSidecarRatingService.requireRegularSingleLink(
                descriptorStatus,
                displayURL: displayURL
            )
            let descriptorSnapshot = MetadataFileSnapshot(descriptorStatus)
            guard descriptorSnapshot == expected,
                  try AdobeXMPSidecarRatingService.snapshotAt(
                    parentFileDescriptor: parentDescriptor,
                    leafName: targetLeaf,
                    displayURL: displayURL
                  ) == expected else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            return descriptorSnapshot
        }

        private func validatedRegularBinding(
            descriptor: Int32,
            leaf: String,
            expected: MetadataFileSnapshot?,
            displayURL: URL
        ) throws -> MetadataFileSnapshot {
            var descriptorStatus = stat()
            var leafStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
                throw UMISCoreError.posix(operation: "fstat recovery entry", code: errno, path: displayURL.path)
            }
            try AdobeXMPSidecarRatingService.requireRegularSingleLink(
                descriptorStatus,
                displayURL: displayURL
            )
            let lookup = leaf.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &leafStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup == 0 else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            try AdobeXMPSidecarRatingService.requireRegularSingleLink(
                leafStatus,
                displayURL: displayURL
            )
            let descriptorSnapshot = MetadataFileSnapshot(descriptorStatus)
            guard descriptorSnapshot == MetadataFileSnapshot(leafStatus),
                  expected == nil || descriptorSnapshot == expected else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            return descriptorSnapshot
        }

        private func validateManifests(displayURL: URL) throws {
            guard let pendingManifestSnapshot, let sealedManifestSnapshot else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            _ = try validatedRegularBinding(
                descriptor: pendingManifestDescriptor,
                leaf: "manifest.pending.json",
                expected: pendingManifestSnapshot,
                displayURL: displayURL
            )
            _ = try validatedRegularBinding(
                descriptor: sealedManifestDescriptor,
                leaf: "manifest.sealed.json",
                expected: sealedManifestSnapshot,
                displayURL: displayURL
            )
            if let cleanupManifestSnapshot {
                _ = try validatedRegularBinding(
                    descriptor: cleanupManifestDescriptor,
                    leaf: "manifest.cleanup.json",
                    expected: cleanupManifestSnapshot,
                    displayURL: displayURL
                )
            }
        }

        private func unlinkManifest(
            leaf: String,
            descriptor: Int32,
            displayURL: URL
        ) throws {
            let result = leaf.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            guard result == 0 else {
                throw UMISCoreError.posix(
                    operation: "unlink recovery manifest",
                    code: errno,
                    path: displayURL.path
                )
            }
            var after = stat()
            guard Darwin.fstat(descriptor, &after) == 0, after.st_nlink == 0 else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            try AdobeXMPSidecarRatingService.synchronizeDescriptor(
                directoryDescriptor,
                displayPath: displayURL.deletingLastPathComponent().path
            )
        }

        private func manifestData(
            state: String,
            committed: MetadataFileSnapshot?,
            artifact: MetadataFileSnapshot?,
            includeOriginal: Bool = true
        ) throws -> Data {
            var object: [String: Any] = [
                "schemaVersion": 1,
                "kind": "sidecarXMP",
                "targetLeaf": targetLeaf,
                "createdUnixSeconds": Int64(Date().timeIntervalSince1970),
                "state": state,
            ]
            if includeOriginal, let originalSnapshot {
                object["original"] = Self.manifestWitness(originalSnapshot)
            }
            if let committed { object["committed"] = Self.manifestWitness(committed) }
            if let artifact {
                object["artifact"] = Self.manifestWitness(artifact)
                if let oldArtifact {
                    object["artifacts"] = [[
                        "role": "original",
                        "leaf": oldArtifact.leaf,
                        "witness": Self.manifestWitness(artifact),
                    ]]
                }
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        private static func manifestWitness(_ snapshot: MetadataFileSnapshot) -> [String: Any] {
            [
                "device": snapshot.device,
                "inode": snapshot.inode,
                "byteSize": snapshot.byteSize,
                "modifiedSeconds": snapshot.modifiedSeconds,
                "modifiedNanoseconds": snapshot.modifiedNanoseconds,
                "changedSeconds": snapshot.changedSeconds,
                "changedNanoseconds": snapshot.changedNanoseconds,
                "mode": snapshot.mode,
                "linkCount": snapshot.linkCount,
            ]
        }

        private static func randomHex() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            bytes.withUnsafeMutableBytes { buffer in
                arc4random_buf(buffer.baseAddress, buffer.count)
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func anchoredSidecar(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL
    ) throws -> AnchoredSidecarResolution {
        try Self.requireValidLeaf(mediaLeafName, displayPath: displayURL.path)
        guard (mediaLeafName as NSString).pathExtension.caseInsensitiveCompare("xmp") != .orderedSame else {
            throw UMISCoreError.invalidPath("An XMP file cannot be its own media sidecar: \(displayURL.path)")
        }
        let replacing = Self.sidecarCandidateLeaf(
            forMediaLeaf: mediaLeafName,
            naming: .replacingMediaExtension
        )
        let appending = Self.sidecarCandidateLeaf(
            forMediaLeaf: mediaLeafName,
            naming: .appendingToMediaFilename
        )
        guard replacing != mediaLeafName, appending != mediaLeafName else {
            throw UMISCoreError.invalidPath("An XMP file cannot be its own media sidecar: \(displayURL.path)")
        }
        let parentDisplayURL = displayURL.deletingLastPathComponent()

        if resolutionPolicy == .strictPreferred {
            let preferred = preferredNaming == .replacingMediaExtension ? replacing : appending
            let existing = try Self.existingAnchoredSidecar(
                parentFileDescriptor: parentFileDescriptor,
                candidateLeaf: preferred,
                parentDisplayURL: parentDisplayURL
            )
            let leaf = existing?.leaf ?? preferred
            return AnchoredSidecarResolution(
                leaf: leaf,
                displayURL: parentDisplayURL.appendingPathComponent(leaf, isDirectory: false),
                snapshot: existing?.snapshot
            )
        }

        let replacingExisting = try Self.existingAnchoredSidecar(
            parentFileDescriptor: parentFileDescriptor,
            candidateLeaf: replacing,
            parentDisplayURL: parentDisplayURL
        )
        let appendingExisting = replacing == appending
            ? replacingExisting
            : try Self.existingAnchoredSidecar(
                parentFileDescriptor: parentFileDescriptor,
                candidateLeaf: appending,
                parentDisplayURL: parentDisplayURL
            )
        if let replacingExisting, let appendingExisting,
           !replacingExisting.snapshot.sameFile(as: appendingExisting.snapshot) {
            throw AssetMetadataError.ambiguousXMPSidecars(
                first: parentDisplayURL.appendingPathComponent(replacingExisting.leaf).path,
                second: parentDisplayURL.appendingPathComponent(appendingExisting.leaf).path
            )
        }
        if let existing = replacingExisting ?? appendingExisting {
            return AnchoredSidecarResolution(
                leaf: existing.leaf,
                displayURL: parentDisplayURL.appendingPathComponent(existing.leaf, isDirectory: false),
                snapshot: existing.snapshot
            )
        }
        let preferred = preferredNaming == .replacingMediaExtension ? replacing : appending
        return AnchoredSidecarResolution(
            leaf: preferred,
            displayURL: parentDisplayURL.appendingPathComponent(preferred, isDirectory: false),
            snapshot: nil
        )
    }

    private static func sidecarCandidateLeaf(
        forMediaLeaf mediaLeaf: String,
        naming: XMPSidecarNaming
    ) -> String {
        switch naming {
        case .replacingMediaExtension:
            return (mediaLeaf as NSString).deletingPathExtension + ".xmp"
        case .appendingToMediaFilename:
            return mediaLeaf + ".xmp"
        }
    }

    private static func existingAnchoredSidecar(
        parentFileDescriptor: Int32,
        candidateLeaf: String,
        parentDisplayURL: URL
    ) throws -> (leaf: String, snapshot: MetadataFileSnapshot)? {
        let stem = (candidateLeaf as NSString).deletingPathExtension
        let extensions = ["xmp", "xmP", "xMp", "xMP", "Xmp", "XmP", "XMp", "XMP"]
        var matches: [(leaf: String, snapshot: MetadataFileSnapshot)] = []
        for pathExtension in extensions {
            let leaf = stem + "." + pathExtension
            let displayURL = parentDisplayURL.appendingPathComponent(leaf, isDirectory: false)
            guard let snapshot = try snapshotAt(
                parentFileDescriptor: parentFileDescriptor,
                leafName: leaf,
                displayURL: displayURL
            ) else { continue }
            if !matches.contains(where: { $0.snapshot.sameFile(as: snapshot) }) {
                matches.append((leaf, snapshot))
            }
        }
        if matches.count > 1 {
            throw AssetMetadataError.ambiguousXMPSidecars(
                first: parentDisplayURL.appendingPathComponent(matches[0].leaf).path,
                second: parentDisplayURL.appendingPathComponent(matches[1].leaf).path
            )
        }
        return matches.first
    }

    private static func requireValidLeaf(_ leaf: String, displayPath: String) throws {
        guard !leaf.isEmpty,
              leaf != ".",
              leaf != "..",
              !leaf.contains("/"),
              !leaf.unicodeScalars.contains(where: { $0.value == 0 }),
              leaf.utf8.count <= Int(NAME_MAX) else {
            throw UMISCoreError.invalidPath("Expected one valid filename component: \(displayPath)")
        }
    }

    private static func openAndValidateMediaCapability(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> Int32 {
        try requireValidLeaf(mediaLeafName, displayPath: displayURL.path)
        var parentStatus = stat()
        guard Darwin.fstat(parentFileDescriptor, &parentStatus) == 0 else {
            throw UMISCoreError.posix(
                operation: "fstat metadata parent capability",
                code: errno,
                path: displayURL.deletingLastPathComponent().path
            )
        }
        guard (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw UMISCoreError.invalidPath("Metadata parent capability is not a directory: \(displayURL.path)")
        }
        let descriptor = mediaLeafName.withCString {
            Darwin.openat(parentFileDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw UMISCoreError.symbolicLinkRejected(displayURL.path) }
            throw UMISCoreError.posix(
                operation: "openat metadata media capability",
                code: errno,
                path: displayURL.path
            )
        }
        do {
            try requireMediaCapability(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                mediaDescriptor: descriptor,
                displayURL: displayURL,
                expectedFingerprint: expectedFingerprint
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func requireMediaCapability(
        parentFileDescriptor: Int32,
        mediaLeafName: String,
        mediaDescriptor: Int32,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws {
        var descriptorStatus = stat()
        guard Darwin.fstat(mediaDescriptor, &descriptorStatus) == 0 else {
            throw UMISCoreError.posix(operation: "fstat metadata media", code: errno, path: displayURL.path)
        }
        try requireRegularSingleLink(descriptorStatus, displayURL: displayURL)
        guard fingerprint(descriptorStatus) == expectedFingerprint else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        guard let leafSnapshot = try snapshotAt(
            parentFileDescriptor: parentFileDescriptor,
            leafName: mediaLeafName,
            displayURL: displayURL
        ), leafSnapshot.sameFile(as: MetadataFileSnapshot(descriptorStatus)),
           fingerprint(leafSnapshot) == expectedFingerprint else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
    }

    private static func snapshotAt(
        parentFileDescriptor: Int32,
        leafName: String,
        displayURL: URL
    ) throws -> MetadataFileSnapshot? {
        try requireValidLeaf(leafName, displayPath: displayURL.path)
        var status = stat()
        let result = leafName.withCString {
            Darwin.fstatat(parentFileDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw UMISCoreError.symbolicLinkRejected(displayURL.path)
            }
            try requireRegularSingleLink(status, displayURL: displayURL)
            return MetadataFileSnapshot(status)
        }
        if errno == ENOENT { return nil }
        throw UMISCoreError.posix(operation: "fstatat metadata", code: errno, path: displayURL.path)
    }

    private static func requireRegularSingleLink(_ status: stat, displayURL: URL) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(displayURL.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(displayURL.path)
        }
    }

    private static func fingerprint(_ status: stat) -> FileFingerprint {
        FileFingerprint(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteSize: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func fingerprint(_ snapshot: MetadataFileSnapshot) -> FileFingerprint {
        FileFingerprint(
            device: snapshot.device,
            inode: snapshot.inode,
            byteSize: snapshot.byteSize,
            modifiedSeconds: snapshot.modifiedSeconds,
            modifiedNanoseconds: snapshot.modifiedNanoseconds
        )
    }

    private static func openAnchoredRegularFile(
        parentFileDescriptor: Int32,
        leafName: String,
        expectedSnapshot: MetadataFileSnapshot,
        displayURL: URL,
        writable: Bool
    ) throws -> Int32 {
        let flags = (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW
        let descriptor = leafName.withCString { Darwin.openat(parentFileDescriptor, $0, flags) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw UMISCoreError.symbolicLinkRejected(displayURL.path) }
            throw UMISCoreError.posix(operation: "openat metadata sidecar", code: errno, path: displayURL.path)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UMISCoreError.posix(operation: "fstat metadata sidecar", code: code, path: displayURL.path)
        }
        do {
            try requireRegularSingleLink(status, displayURL: displayURL)
            guard MetadataFileSnapshot(status) == expectedSnapshot,
                  try snapshotAt(
                    parentFileDescriptor: parentFileDescriptor,
                    leafName: leafName,
                    displayURL: displayURL
                  ) == expectedSnapshot else {
                throw AssetMetadataError.concurrentModification(displayURL.path)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func readAnchoredRegularFile(
        parentFileDescriptor: Int32,
        leafName: String,
        expectedSnapshot: MetadataFileSnapshot,
        displayURL: URL
    ) throws -> LoadedMetadataFile {
        let descriptor = try openAnchoredRegularFile(
            parentFileDescriptor: parentFileDescriptor,
            leafName: leafName,
            expectedSnapshot: expectedSnapshot,
            displayURL: displayURL,
            writable: false
        )
        defer { Darwin.close(descriptor) }
        return try readAnchoredRegularFile(
            descriptor: descriptor,
            parentFileDescriptor: parentFileDescriptor,
            leafName: leafName,
            expectedSnapshot: expectedSnapshot,
            displayURL: displayURL
        )
    }

    private static func readAnchoredRegularFile(
        descriptor: Int32,
        parentFileDescriptor: Int32,
        leafName: String,
        expectedSnapshot: MetadataFileSnapshot,
        displayURL: URL
    ) throws -> LoadedMetadataFile {
        guard expectedSnapshot.byteSize >= 0,
              expectedSnapshot.byteSize <= Int64(Int.max),
              expectedSnapshot.byteSize <= 64 * 1_024 * 1_024 else {
            throw AssetMetadataError.malformedXMP(path: displayURL.path, reason: "sidecar exceeds 64 MiB safety limit")
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw UMISCoreError.posix(operation: "rewind metadata sidecar", code: errno, path: displayURL.path)
        }
        var data = Data()
        data.reserveCapacity(Int(expectedSnapshot.byteSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "read anchored metadata", code: errno, path: displayURL.path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
            guard data.count <= 64 * 1_024 * 1_024 else {
                throw AssetMetadataError.malformedXMP(path: displayURL.path, reason: "sidecar grew beyond 64 MiB")
            }
        }
        var afterStatus = stat()
        guard Darwin.fstat(descriptor, &afterStatus) == 0 else {
            throw UMISCoreError.posix(operation: "fstat anchored metadata after read", code: errno, path: displayURL.path)
        }
        guard MetadataFileSnapshot(afterStatus) == expectedSnapshot,
              Int64(data.count) == expectedSnapshot.byteSize,
              try snapshotAt(
                parentFileDescriptor: parentFileDescriptor,
                leafName: leafName,
                displayURL: displayURL
              ) == expectedSnapshot else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        return LoadedMetadataFile(data: data, snapshot: expectedSnapshot)
    }

    private static func commitAnchoredSidecar(
        _ data: Data,
        parentFileDescriptor: Int32,
        destinationLeaf: String,
        destinationDisplayURL: URL,
        replacing expectedSidecar: MetadataFileSnapshot?,
        existingDescriptor: Int32,
        mediaLeafName: String,
        mediaDescriptor: Int32,
        mediaDisplayURL: URL,
        expectedMediaFingerprint: FileFingerprint,
        testFault: AdobeXMPSidecarRecoveryTestFault?
    ) throws -> AnchoredSidecarCommit {
        try requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: mediaDisplayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        guard try snapshotAt(
            parentFileDescriptor: parentFileDescriptor,
            leafName: destinationLeaf,
            displayURL: destinationDisplayURL
        ) == expectedSidecar else {
            throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
        }

        let recovery = try AnchoredSidecarRecovery(
            parentFileDescriptor: parentFileDescriptor,
            targetLeaf: destinationLeaf,
            originalSnapshot: expectedSidecar,
            testFault: testFault,
            displayURL: destinationDisplayURL
        )
        let replacement = try recovery.makeReplacement(displayURL: destinationDisplayURL)
        let temporaryDescriptor = replacement.descriptor
        let temporaryLeaf = replacement.leaf
        defer { Darwin.close(temporaryDescriptor) }

        if let expectedSidecar {
            guard existingDescriptor >= 0 else {
                throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
            }
            guard Darwin.fchmod(temporaryDescriptor, expectedSidecar.mode & mode_t(0o7777)) == 0 else {
                throw UMISCoreError.posix(
                    operation: "fchmod anchored XMP partial",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
        }
        try data.withUnsafeBytes { bytes in
            try writeAll(
                descriptor: temporaryDescriptor,
                bytes: bytes,
                displayPath: destinationDisplayURL.path
            )
        }
        if expectedSidecar != nil {
            let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)
            guard Darwin.fcopyfile(existingDescriptor, temporaryDescriptor, nil, flags) == 0 else {
                throw UMISCoreError.posix(
                    operation: "fcopyfile anchored XMP ACL/xattrs",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
        }
        try synchronizeDescriptor(temporaryDescriptor, displayPath: destinationDisplayURL.path)
        let temporarySnapshot = try recovery.replacementSnapshot(
            descriptor: temporaryDescriptor,
            leaf: temporaryLeaf,
            displayURL: destinationDisplayURL
        )
        try recovery.injectReplacementFaultIfRequested(
            replacementLeaf: temporaryLeaf,
            displayURL: destinationDisplayURL
        )
        if testFault == .changeExistingMetadataBeforeCommit, existingDescriptor >= 0 {
            var existingStatus = stat()
            guard Darwin.fstat(existingDescriptor, &existingStatus) == 0,
                  Darwin.fchmod(existingDescriptor, existingStatus.st_mode ^ S_IXUSR) == 0 else {
                throw UMISCoreError.posix(
                    operation: "inject existing sidecar metadata fault",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
        }

        try requireMediaCapability(
            parentFileDescriptor: parentFileDescriptor,
            mediaLeafName: mediaLeafName,
            mediaDescriptor: mediaDescriptor,
            displayURL: mediaDisplayURL,
            expectedFingerprint: expectedMediaFingerprint
        )
        guard try snapshotAt(
            parentFileDescriptor: parentFileDescriptor,
            leafName: destinationLeaf,
            displayURL: destinationDisplayURL
        ) == expectedSidecar else {
            throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
        }
        // Bind the private replacement FD to its recovery-directory leaf at the last possible
        // point before the atomic namespace operation.
        guard try recovery.replacementSnapshot(
            descriptor: temporaryDescriptor,
            leaf: temporaryLeaf,
            expected: temporarySnapshot,
            displayURL: destinationDisplayURL
        ) == temporarySnapshot else {
            throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
        }

        if let expectedSidecar {
            let swapResult = temporaryLeaf.withCString { source in
                destinationLeaf.withCString { destination in
                    Darwin.renameatx_np(
                        recovery.replacementDirectoryDescriptor(),
                        source,
                        parentFileDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapResult == 0 else {
                throw UMISCoreError.posix(
                    operation: "renameatx_np anchored XMP swap",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
            do {
            try recovery.injectPostCommitFaultIfRequested(displayURL: destinationDisplayURL)
            try synchronizeDescriptor(
                recovery.replacementDirectoryDescriptor(),
                displayPath: destinationDisplayURL.deletingLastPathComponent().path
            )
            try synchronizeDescriptor(
                parentFileDescriptor,
                displayPath: destinationDisplayURL.deletingLastPathComponent().path
            )

            let oldAtTemporary = try recovery.replacementSnapshot(
                descriptor: existingDescriptor,
                leaf: temporaryLeaf,
                displayURL: destinationDisplayURL
            )
            guard oldAtTemporary.sameObjectAndContentAfterRename(as: expectedSidecar) else {
                throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
            }
            var committedStatus = stat()
            guard Darwin.fstat(temporaryDescriptor, &committedStatus) == 0 else {
                throw UMISCoreError.posix(
                    operation: "fstat committed anchored XMP sidecar",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
            try requireRegularSingleLink(committedStatus, displayURL: destinationDisplayURL)
            let committedSnapshot = MetadataFileSnapshot(committedStatus)
            guard committedSnapshot.sameObjectAndContentAfterRename(as: temporarySnapshot),
                  try snapshotAt(
                    parentFileDescriptor: parentFileDescriptor,
                    leafName: destinationLeaf,
                    displayURL: destinationDisplayURL
                  ) == committedSnapshot else {
                throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
            }
            try recovery.bindOldArtifact(
                leaf: temporaryLeaf,
                descriptor: existingDescriptor,
                displayURL: destinationDisplayURL
            )
            try recovery.seal(
                committedDescriptor: temporaryDescriptor,
                committedSnapshot: committedSnapshot,
                displayURL: destinationDisplayURL
            )
            try requireMediaCapability(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                mediaDescriptor: mediaDescriptor,
                displayURL: mediaDisplayURL,
                expectedFingerprint: expectedMediaFingerprint
            )
            return AnchoredSidecarCommit(
                committedSnapshot: committedSnapshot,
                recovery: recovery
            )
            } catch {
                throw AssetMetadataError.recoveryRetained(
                    path: destinationDisplayURL.path,
                    recoveryDirectoryLeaf: recovery.directoryLeaf,
                    reason: "Post-swap sidecar verification failed: \(String(describing: error))"
                )
            }
        } else {
            let renameResult = temporaryLeaf.withCString { source in
                destinationLeaf.withCString { destination in
                    Darwin.renameatx_np(
                        recovery.replacementDirectoryDescriptor(),
                        source,
                        parentFileDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameResult == 0 else {
                if errno == EEXIST {
                    throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
                }
                throw UMISCoreError.posix(
                    operation: "renameatx_np anchored XMP create",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
            do {
            try recovery.injectPostCommitFaultIfRequested(displayURL: destinationDisplayURL)
            try synchronizeDescriptor(
                recovery.replacementDirectoryDescriptor(),
                displayPath: destinationDisplayURL.deletingLastPathComponent().path
            )
            try synchronizeDescriptor(
                parentFileDescriptor,
                displayPath: destinationDisplayURL.deletingLastPathComponent().path
            )
            var committedStatus = stat()
            guard Darwin.fstat(temporaryDescriptor, &committedStatus) == 0 else {
                throw UMISCoreError.posix(
                    operation: "fstat newly committed XMP sidecar",
                    code: errno,
                    path: destinationDisplayURL.path
                )
            }
            try requireRegularSingleLink(committedStatus, displayURL: destinationDisplayURL)
            let committedSnapshot = MetadataFileSnapshot(committedStatus)
            guard committedSnapshot.sameObjectAndContentAfterRename(as: temporarySnapshot),
                  try snapshotAt(
                    parentFileDescriptor: parentFileDescriptor,
                    leafName: destinationLeaf,
                    displayURL: destinationDisplayURL
                  ) == committedSnapshot else {
                throw AssetMetadataError.concurrentModification(destinationDisplayURL.path)
            }
            try recovery.seal(
                committedDescriptor: temporaryDescriptor,
                committedSnapshot: committedSnapshot,
                displayURL: destinationDisplayURL
            )
            try requireMediaCapability(
                parentFileDescriptor: parentFileDescriptor,
                mediaLeafName: mediaLeafName,
                mediaDescriptor: mediaDescriptor,
                displayURL: mediaDisplayURL,
                expectedFingerprint: expectedMediaFingerprint
            )
            return AnchoredSidecarCommit(
                committedSnapshot: committedSnapshot,
                recovery: recovery
            )
            } catch {
                throw AssetMetadataError.recoveryRetained(
                    path: destinationDisplayURL.path,
                    recoveryDirectoryLeaf: recovery.directoryLeaf,
                    reason: "Post-create sidecar verification failed: \(String(describing: error))"
                )
            }
        }
    }

    private static func writeAll(
        descriptor: Int32,
        bytes: UnsafeRawBufferPointer,
        displayPath: String
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let amount = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if amount < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "write anchored XMP", code: errno, path: displayPath)
            }
            guard amount > 0 else {
                throw UMISCoreError.posix(operation: "write anchored XMP", code: EIO, path: displayPath)
            }
            offset += amount
        }
    }

    private static func synchronizeDescriptor(_ descriptor: Int32, displayPath: String) throws {
        var result = Darwin.fcntl(descriptor, F_FULLFSYNC)
        if result != 0, errno == EINVAL || errno == ENOTSUP {
            repeat {
                result = Darwin.fsync(descriptor)
            } while result != 0 && errno == EINTR
        }
        guard result == 0 else {
            throw UMISCoreError.posix(operation: "full fsync anchored XMP", code: errno, path: displayPath)
        }
    }

    private static func coordinateReading<T>(
        _ url: URL,
        body: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
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
                reason: "coordinator did not execute the read"
            )
        }
        return try result.get()
    }

    private static func coordinateWriting(
        _ url: URL,
        body: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
            coordinatedURL in
            do {
                try body(coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: coordinationError.localizedDescription
            )
        }
        if let operationError { throw operationError }
    }

    private static func sidecarCandidate(for mediaURL: URL, naming: XMPSidecarNaming) -> URL {
        switch naming {
        case .replacingMediaExtension:
            return mediaURL.deletingPathExtension().appendingPathExtension("xmp")
        case .appendingToMediaFilename:
            return URL(fileURLWithPath: mediaURL.path + ".xmp")
        }
    }

    private static func parseXMP(_ data: Data, at url: URL) throws -> XMLDocument {
        // XMP packets do not require a DTD. Refusing one prevents local/network external-entity
        // expansion while parsing metadata from an untrusted card or archive.
        // Removing NUL bytes also exposes ASCII markup in UTF-16/UTF-32 packets to this preflight.
        let markupProbe = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        if markupProbe.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil {
            throw AssetMetadataError.malformedXMP(path: url.path, reason: "DOCTYPE is not permitted")
        }
        do {
            let document = try XMLDocument(data: data, options: [.nodePreserveAll])
            guard try !rdfElements(in: document).isEmpty else {
                throw AssetMetadataError.malformedXMP(
                    path: url.path,
                    reason: "RDF root element is missing"
                )
            }
            return document
        } catch let error as AssetMetadataError {
            throw error
        } catch {
            throw AssetMetadataError.malformedXMP(path: url.path, reason: String(describing: error))
        }
    }

    private static func rating(in document: XMLDocument, at url: URL) throws -> AdobeRating {
        try ratingResult(in: document, at: url).rating
    }

    private static func ratingResult(
        in document: XMLDocument,
        at url: URL
    ) throws -> AdobeXMPSidecarRatingReadResult {
        let nodes = try ratingNodes(in: document)
        guard !nodes.isEmpty else {
            return AdobeXMPSidecarRatingReadResult(rating: .unrated, hasExplicitRating: false)
        }
        var values: Set<AdobeRating> = []
        for node in nodes {
            if let element = node as? XMLElement,
               element.children?.contains(where: { $0 is XMLElement }) == true {
                throw AssetMetadataError.malformedXMP(
                    path: url.path,
                    reason: "xmp:Rating must be a simple Real value"
                )
            }
            let raw = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The XMP schema type is Real, so integral lexical forms such as `3.0` are valid even
            // though UMIS intentionally exposes only the standard discrete rating choices.
            guard let real = Double(raw), real.isFinite,
                  real >= -1, real <= 5,
                  real.rounded(.towardZero) == real,
                  let rating = AdobeRating(rawValue: Int(real)) else {
                throw AssetMetadataError.malformedXMP(
                    path: url.path,
                    reason: "xmp:Rating must be an integral Real equal to -1 or in 0...5"
                )
            }
            values.insert(rating)
        }
        guard values.count == 1, let value = values.first else {
            throw AssetMetadataError.conflictingXMPRatings(path: url.path)
        }
        return AdobeXMPSidecarRatingReadResult(rating: value, hasExplicitRating: true)
    }

    private static func setRating(_ rating: AdobeRating, in document: XMLDocument, at url: URL) throws {
        let existing = try ratingNodes(in: document)
        if !existing.isEmpty {
            for node in existing { node.stringValue = String(rating.rawValue) }
            return
        }

        let description: XMLElement
        if let existingDescription = try descriptionElements(in: document).first {
            description = existingDescription
        } else if let rdf = try rdfElements(in: document).first {
            let created = XMLElement(name: "rdf:Description", uri: rdfNamespace)
            created.addAttribute(
                XMLNode.attribute(withName: "rdf:about", uri: rdfNamespace, stringValue: "") as! XMLNode
            )
            created.addNamespace(XMLNode.namespace(withName: "xmp", stringValue: xmpNamespace) as! XMLNode)
            rdf.addChild(created)
            description = created
        } else {
            throw AssetMetadataError.malformedXMP(path: url.path, reason: "RDF root element is missing")
        }
        if let localXMPBinding = description.namespaces?.first(where: { $0.name == "xmp" }) {
            guard localXMPBinding.stringValue == xmpNamespace else {
                throw AssetMetadataError.malformedXMP(
                    path: url.path,
                    reason: "the xmp namespace prefix is bound to an unexpected URI"
                )
            }
        } else {
            // `addAttribute` does not synthesize an xmlns declaration for an existing element on
            // every Foundation release. Declare the prefix locally so the serialized packet can
            // always be parsed again, even when the original packet had no XMP properties.
            description.addNamespace(
                XMLNode.namespace(withName: "xmp", stringValue: xmpNamespace) as! XMLNode
            )
        }
        let attribute = XMLNode.attribute(
            withName: "xmp:Rating",
            uri: xmpNamespace,
            stringValue: String(rating.rawValue)
        ) as! XMLNode
        description.addAttribute(attribute)
    }

    private static func ratingNodes(in document: XMLDocument) throws -> [XMLNode] {
        // Foundation's XPath bridge has returned false for valid `namespace-uri()` comparisons on
        // multiple macOS releases. Enumerate then compare the resolved namespace in Swift.
        let attributes = try document.nodes(forXPath: "//@*")
        let elements = try document.nodes(forXPath: "//*")
        return (attributes + elements).filter {
            $0.localName == "Rating" && $0.uri == xmpNamespace
        }
    }

    private static func descriptionElements(in document: XMLDocument) throws -> [XMLElement] {
        try document.nodes(forXPath: "//*").compactMap { node in
            guard node.localName == "Description", node.uri == rdfNamespace else { return nil }
            return node as? XMLElement
        }
    }

    private static func rdfElements(in document: XMLDocument) throws -> [XMLElement] {
        try document.nodes(forXPath: "//*").compactMap { node in
            guard node.localName == "RDF", node.uri == rdfNamespace else { return nil }
            return node as? XMLElement
        }
    }

    private static func makeNewXMPDocument() throws -> XMLDocument {
        // Parsing this trusted skeleton ensures Foundation resolves namespace URIs on every node;
        // constructing prefixed XMLElement instances leaves `namespace-uri()` empty until a
        // serialize/reparse cycle on some Foundation releases.
        let packet = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="\(rdfNamespace)">
            <rdf:Description rdf:about="" xmlns:xmp="\(xmpNamespace)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return try XMLDocument(xmlString: packet, options: [.nodePreserveAll])
    }

    private static func atomicWrite(
        _ data: Data,
        to destination: URL,
        replacing expected: MetadataFileSnapshot?
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).umis-\(UUID().uuidString).partial"
        )
        let descriptor = try POSIXFile.openExclusiveWrite(temporary)
        do {
            if let expected {
                guard Darwin.fchmod(descriptor, expected.mode & 0o777) == 0 else {
                    throw UMISCoreError.posix(operation: "fchmod XMP partial", code: errno, path: temporary.path)
                }
            }
            try data.withUnsafeBytes {
                try POSIXFile.writeAll(descriptor: descriptor, bytes: $0, path: temporary.path)
            }
            if expected != nil {
                try copyExtendedMetadata(from: destination, to: temporary)
            }
            try POSIXFile.synchronize(descriptor: descriptor, path: temporary.path)
        } catch {
            Darwin.close(descriptor)
            try? POSIXFile.removeIfExists(temporary)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            let code = errno
            try? POSIXFile.removeIfExists(temporary)
            throw UMISCoreError.posix(operation: "close XMP partial", code: code, path: temporary.path)
        }

        do {
            let current = try currentSnapshotIfPresent(destination)
            guard current == expected else {
                throw AssetMetadataError.concurrentModification(destination.path)
            }
            if expected == nil {
                try POSIXFile.atomicRenameNoReplace(from: temporary, to: destination)
            } else {
                let result: Int32 = temporary.withUnsafeFileSystemRepresentation { sourcePath in
                    destination.withUnsafeFileSystemRepresentation { destinationPath in
                        guard let sourcePath, let destinationPath else { return -1 }
                        return Darwin.rename(sourcePath, destinationPath)
                    }
                }
                guard result == 0 else {
                    throw UMISCoreError.posix(
                        operation: "atomic XMP replace",
                        code: errno,
                        path: destination.path
                    )
                }
            }
            try POSIXFile.synchronizeDirectory(parent)
        } catch {
            try? POSIXFile.removeIfExists(temporary)
            throw error
        }
    }

    /// Atomic replacement creates a new inode. Preserve ACLs and unrelated extended attributes from
    /// an existing sidecar on that new inode before commit; the RDF/XML data itself is never copied.
    private static func copyExtendedMetadata(from source: URL, to destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                let flags = copyfile_flags_t(
                    COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST
                )
                return Darwin.copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        guard result == 0 else {
            throw UMISCoreError.posix(
                operation: "copy XMP ACL/xattrs",
                code: errno,
                path: source.path
            )
        }
    }

    private static func requireRegularFileNoFollow(_ url: URL) throws {
        let descriptor = try POSIXFile.openReadOnlyNoFollow(url)
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw UMISCoreError.posix(operation: "fstat metadata target", code: errno, path: url.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(url.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(url.path)
        }
    }

    private static func readRegularFileNoFollow(_ url: URL) throws -> LoadedMetadataFile {
        let descriptor = try POSIXFile.openReadOnlyNoFollow(url)
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw UMISCoreError.posix(operation: "fstat metadata", code: errno, path: url.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(url.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(url.path)
        }
        let snapshot = MetadataFileSnapshot(status)
        guard snapshot.byteSize >= 0,
              snapshot.byteSize <= Int64(Int.max),
              snapshot.byteSize <= 64 * 1_024 * 1_024 else {
            throw AssetMetadataError.malformedXMP(path: url.path, reason: "sidecar exceeds 64 MiB safety limit")
        }
        var data = Data()
        data.reserveCapacity(Int(snapshot.byteSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "read metadata", code: errno, path: url.path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
            guard data.count <= 64 * 1_024 * 1_024 else {
                throw AssetMetadataError.malformedXMP(path: url.path, reason: "sidecar grew beyond 64 MiB")
            }
        }
        var afterStatus = stat()
        guard Darwin.fstat(descriptor, &afterStatus) == 0 else {
            throw UMISCoreError.posix(operation: "fstat metadata after read", code: errno, path: url.path)
        }
        guard MetadataFileSnapshot(afterStatus) == snapshot,
              Int64(data.count) == snapshot.byteSize else {
            throw AssetMetadataError.concurrentModification(url.path)
        }
        return LoadedMetadataFile(data: data, snapshot: snapshot)
    }

    private static func pathExistsWithoutFollowingSymlink(_ url: URL) throws -> Bool {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        if result == 0 {
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw UMISCoreError.symbolicLinkRejected(url.path)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw UMISCoreError.notRegularFile(url.path)
            }
            guard status.st_nlink == 1 else {
                throw AssetMetadataError.hardLinkRejected(url.path)
            }
            return true
        }
        if errno == ENOENT { return false }
        throw UMISCoreError.posix(operation: "lstat metadata", code: errno, path: url.path)
    }

    /// APFS can be case-sensitive. Probe all eight ASCII-case variants of `.xmp` in constant time;
    /// this avoids an O(asset-count × directory-size) directory scan when a grid has no sidecars.
    private static func existingSidecar(matchingExtensionCaseInsensitively candidate: URL) throws -> URL? {
        let stem = candidate.deletingPathExtension()
        let extensions = ["xmp", "xmP", "xMp", "xMP", "Xmp", "XmP", "XMp", "XMP"]
        var matches: [(url: URL, snapshot: MetadataFileSnapshot)] = []
        for pathExtension in extensions {
            let variant = stem.appendingPathExtension(pathExtension)
            guard let snapshot = try currentSnapshotIfPresent(variant) else { continue }
            if !matches.contains(where: { $0.snapshot.sameFile(as: snapshot) }) {
                matches.append((variant, snapshot))
            }
        }
        if matches.count > 1 {
            throw AssetMetadataError.ambiguousXMPSidecars(
                first: matches[0].url.path,
                second: matches[1].url.path
            )
        }
        return matches.first?.url
    }

    private static func currentSnapshotIfPresent(_ url: URL) throws -> MetadataFileSnapshot? {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        if result == 0 {
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw UMISCoreError.symbolicLinkRejected(url.path)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw UMISCoreError.notRegularFile(url.path)
            }
            guard status.st_nlink == 1 else {
                throw AssetMetadataError.hardLinkRejected(url.path)
            }
            return MetadataFileSnapshot(status)
        }
        if errno == ENOENT { return nil }
        throw UMISCoreError.posix(operation: "lstat metadata before commit", code: errno, path: url.path)
    }
}

private struct MetadataFileSnapshot: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var byteSize: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64
    var mode: mode_t
    var linkCount: UInt64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        byteSize = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        mode = value.st_mode
        linkCount = UInt64(value.st_nlink)
    }
}

private struct LoadedMetadataFile: Sendable {
    var data: Data
    var snapshot: MetadataFileSnapshot
}

/// Finder color-label access using coordinated URL resource values for path reads and the exact
/// `com.apple.FinderInfo` descriptor xattr for capability-bound production mutations.
///
/// Label numbers are indices into the current Mac's `NSWorkspace.fileLabels` and
/// `NSWorkspace.fileLabelColors`; the Core deliberately does not hard-code color names. Number zero
/// clears the color, and `1...7` select one of the Finder label colors. Named Finder tags are not
/// read or written, which preserves all existing custom tag names on macOS 13 and later.
///
/// Reads/writes are coordinated as content-independent metadata operations. The path is checked with
/// `lstat` before and during coordination, and a symlink or inode substitution is rejected.
public struct FinderColorLabelService: Sendable {
    public init() {}

    public func readLabelNumber(
        at url: URL,
        expectedFingerprint: FileFingerprint? = nil
    ) throws -> Int {
        let expected = try Self.boundFingerprint(expectedFingerprint, at: url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Int, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) {
            coordinatedURL in
            result = Result {
                try Self.requireFingerprint(expected, at: coordinatedURL)
                let label = try coordinatedURL.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0
                try Self.requireFingerprint(expected, at: coordinatedURL)
                return label
            }
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
                reason: "coordinator did not execute the label read"
            )
        }
        let label = try result.get()
        try Self.requireFingerprint(expected, at: url)
        return label
    }

    /// Compatibility-test adapter. Production mutation must use the descriptor overload below so
    /// an ancestor/path replacement cannot redirect Finder metadata to another inode.
    func writeLabelNumber(
        _ labelNumber: Int,
        at url: URL,
        expectedFingerprint: FileFingerprint? = nil
    ) throws {
        guard (0 ... 7).contains(labelNumber) else {
            throw AssetMetadataError.invalidFinderLabelNumber(labelNumber)
        }
        let expected = try Self.boundFingerprint(expectedFingerprint, at: url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .contentIndependentMetadataOnly,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try Self.requireFingerprint(expected, at: coordinatedURL)

                var values = URLResourceValues()
                values.labelNumber = labelNumber
                var mutableURL = coordinatedURL
                try mutableURL.setResourceValues(values)

                try Self.requireFingerprint(expected, at: coordinatedURL)
                let persisted = try coordinatedURL.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0
                guard persisted == labelNumber else {
                    throw AssetMetadataError.metadataCoordinationFailed(
                        path: url.path,
                        reason: "Finder label verification returned \(persisted), expected \(labelNumber)"
                    )
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: url.path,
                reason: coordinationError.localizedDescription
            )
        }
        if let operationError { throw operationError }
        try Self.requireFingerprint(expected, at: url)
    }

    /// Writes a Finder label through a borrowed, already-resolved file descriptor capability.
    ///
    /// The caller retains ownership of `fileDescriptor` and must keep it open for this entire call.
    /// This overload is intended for a descriptor obtained by walking a frozen root with
    /// `openat(..., O_NOFOLLOW)`, so ancestor pathname replacement cannot redirect the mutation.
    /// The descriptor target is verified against the scan-time fingerprint before and after the
    /// FinderInfo mutation preserves every byte except its documented three-bit label field, and
    /// leaves named Finder tags in `_kMDItemUserTags` untouched.
    public func writeLabelNumber(
        _ labelNumber: Int,
        atFileDescriptor fileDescriptor: Int32,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws {
        guard (0 ... 7).contains(labelNumber) else {
            throw AssetMetadataError.invalidFinderLabelNumber(labelNumber)
        }
        try Self.requireFingerprint(
            expectedFingerprint,
            atFileDescriptor: fileDescriptor,
            displayURL: displayURL
        )
        let preMutationSnapshot = try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        )

        let finderInfoSize = Darwin.fgetxattr(
            fileDescriptor,
            "com.apple.FinderInfo",
            nil,
            0,
            0,
            0
        )
        var finderInfo: [UInt8]
        if finderInfoSize < 0, errno == ENOATTR {
            finderInfo = [UInt8](repeating: 0, count: 32)
        } else {
            guard finderInfoSize == 32 else {
                throw AssetMetadataError.metadataCoordinationFailed(
                    path: displayURL.path,
                    reason: finderInfoSize < 0
                        ? "fgetxattr FinderInfo failed with errno \(errno)"
                        : "FinderInfo has invalid length \(finderInfoSize); expected 32 bytes"
                )
            }
            finderInfo = [UInt8](repeating: 0, count: 32)
            let received = finderInfo.withUnsafeMutableBytes {
                Darwin.fgetxattr(
                    fileDescriptor,
                    "com.apple.FinderInfo",
                    $0.baseAddress,
                    $0.count,
                    0,
                    0
                )
            }
            guard received == 32 else {
                throw AssetMetadataError.metadataCoordinationFailed(
                    path: displayURL.path,
                    reason: "FinderInfo changed while preparing its label update"
                )
            }
        }
        guard try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        ) == preMutationSnapshot else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        var finderFlags = (UInt16(finderInfo[8]) << 8) | UInt16(finderInfo[9])
        finderFlags = (finderFlags & ~UInt16(0x000E)) | (UInt16(labelNumber) << 1)
        finderInfo[8] = UInt8((finderFlags >> 8) & 0x00FF)
        finderInfo[9] = UInt8(finderFlags & 0x00FF)
        let setResult = finderInfo.withUnsafeBytes {
            Darwin.fsetxattr(
                fileDescriptor,
                "com.apple.FinderInfo",
                $0.baseAddress,
                $0.count,
                0,
                0
            )
        }
        guard setResult == 0 else {
            throw UMISCoreError.posix(
                operation: "fsetxattr Finder label",
                code: errno,
                path: displayURL.path
            )
        }
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw UMISCoreError.posix(
                operation: "fsync Finder label",
                code: errno,
                path: displayURL.path
            )
        }
        let postMutationSnapshot = try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        )

        try Self.requireFingerprint(
            expectedFingerprint,
            atFileDescriptor: fileDescriptor,
            displayURL: displayURL
        )
        let persisted = try readLabelNumber(
            atFileDescriptor: fileDescriptor,
            displayURL: displayURL,
            expectedFingerprint: expectedFingerprint
        )
        guard persisted == labelNumber else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayURL.path,
                reason: "Finder label verification returned \(persisted), expected \(labelNumber)"
            )
        }
        guard try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        ) == postMutationSnapshot else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
    }

    /// Reads a Finder label through the same borrowed file-descriptor capability used by the
    /// descriptor-bound writer. The display URL is diagnostic only.
    public func readLabelNumber(
        atFileDescriptor fileDescriptor: Int32,
        displayURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws -> Int {
        try Self.requireFingerprint(
            expectedFingerprint,
            atFileDescriptor: fileDescriptor,
            displayURL: displayURL
        )
        let before = try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        )
        // Read the FinderInfo extended attribute directly from the exact held descriptor, matching
        // the capability-bound writer above. The 32-byte FinderInfo record stores the color index
        // in the 3-bit label field of its big-endian flags word (bytes 8...9); absence means no
        // color. A reconstructed path or /dev/fd URL is never mutation authority.
        let size = Darwin.fgetxattr(
            fileDescriptor,
            "com.apple.FinderInfo",
            nil,
            0,
            0,
            0
        )
        let label: Int
        if size < 0, errno == ENOATTR {
            label = 0
        } else {
            guard size == 32 else {
                throw AssetMetadataError.metadataCoordinationFailed(
                    path: displayURL.path,
                    reason: size < 0
                        ? "fgetxattr FinderInfo failed with errno \(errno)"
                        : "FinderInfo has invalid length \(size); expected 32 bytes"
                )
            }
            var finderInfo = [UInt8](repeating: 0, count: 32)
            let received = finderInfo.withUnsafeMutableBytes {
                Darwin.fgetxattr(
                    fileDescriptor,
                    "com.apple.FinderInfo",
                    $0.baseAddress,
                    $0.count,
                    0,
                    0
                )
            }
            guard received == size else {
                throw AssetMetadataError.metadataCoordinationFailed(
                    path: displayURL.path,
                    reason: "FinderInfo changed while reading its label field"
                )
            }
            label = try Self.finderLabelNumber(
                fromFinderInfo: Data(finderInfo),
                displayPath: displayURL.path
            )
        }
        try Self.requireFingerprint(
            expectedFingerprint,
            atFileDescriptor: fileDescriptor,
            displayURL: displayURL
        )
        guard try Self.snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        ) == before else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
        return label
    }

    static func finderLabelNumber(fromFinderInfo data: Data, displayPath: String) throws -> Int {
        guard data.count == 32 else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayPath,
                reason: "FinderInfo has invalid length \(data.count); expected 32 bytes"
            )
        }
        let finderFlags = (UInt16(data[data.startIndex + 8]) << 8)
            | UInt16(data[data.startIndex + 9])
        return Int((finderFlags & 0x000E) >> 1)
    }

    private static func boundFingerprint(
        _ expected: FileFingerprint?,
        at url: URL
    ) throws -> FileFingerprint {
        let current = try fingerprintRegularFileNoFollow(url)
        guard expected == nil || expected == current else {
            throw AssetMetadataError.concurrentModification(url.path)
        }
        return expected ?? current
    }

    private static func requireFingerprint(_ expected: FileFingerprint, at url: URL) throws {
        guard try fingerprintRegularFileNoFollow(url) == expected else {
            throw AssetMetadataError.concurrentModification(url.path)
        }
    }

    private static func requireFingerprint(
        _ expected: FileFingerprint,
        atFileDescriptor fileDescriptor: Int32,
        displayURL: URL
    ) throws {
        guard try fingerprintRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        ) == expected else {
            throw AssetMetadataError.concurrentModification(displayURL.path)
        }
    }

    private static func fingerprintRegularFileNoFollow(_ url: URL) throws -> FileFingerprint {
        let snapshot = try snapshotRegularFileNoFollow(url)
        return FileFingerprint(
            device: snapshot.device,
            inode: snapshot.inode,
            byteSize: snapshot.byteSize,
            modifiedSeconds: snapshot.modifiedSeconds,
            modifiedNanoseconds: snapshot.modifiedNanoseconds
        )
    }

    private static func fingerprintRegularFileDescriptor(
        _ fileDescriptor: Int32,
        displayURL: URL
    ) throws -> FileFingerprint {
        let snapshot = try snapshotRegularFileDescriptor(
            fileDescriptor,
            displayURL: displayURL
        )
        return FileFingerprint(
            device: snapshot.device,
            inode: snapshot.inode,
            byteSize: snapshot.byteSize,
            modifiedSeconds: snapshot.modifiedSeconds,
            modifiedNanoseconds: snapshot.modifiedNanoseconds
        )
    }

    private static func snapshotRegularFileDescriptor(
        _ fileDescriptor: Int32,
        displayURL: URL
    ) throws -> MetadataFileSnapshot {
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0 else {
            throw UMISCoreError.posix(
                operation: "fstat Finder label descriptor",
                code: errno,
                path: displayURL.path
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(displayURL.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(displayURL.path)
        }
        return MetadataFileSnapshot(status)
    }

    private static func snapshotRegularFileNoFollow(_ url: URL) throws -> MetadataFileSnapshot {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw UMISCoreError.posix(operation: "lstat Finder label target", code: errno, path: url.path)
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw UMISCoreError.symbolicLinkRejected(url.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(url.path)
        }
        guard status.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(url.path)
        }
        return MetadataFileSnapshot(status)
    }
}

private extension MetadataFileSnapshot {
    func sameFile(as other: MetadataFileSnapshot) -> Bool {
        device == other.device && inode == other.inode
    }

    func sameObjectAndContentAfterRename(as other: MetadataFileSnapshot) -> Bool {
        device == other.device
            && inode == other.inode
            && byteSize == other.byteSize
            && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds
            && mode == other.mode
            && linkCount == other.linkCount
    }
}
