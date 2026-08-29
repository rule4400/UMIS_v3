import CoreGraphics
import CryptoKit
import Darwin
import Foundation

/// The pixel dimensions requested from the media pipeline. Values are clamped to a
/// defensive range so a corrupt UI value cannot trigger an unbounded decode.
public struct MediaPixelSize: Hashable, Codable, Sendable {
    public static let maximumDimension = 8_192
    public static let maximumPixelCount = 16_777_216

    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        var safeWidth = min(Self.maximumDimension, max(1, width))
        var safeHeight = min(Self.maximumDimension, max(1, height))
        let pixelCount = safeWidth * safeHeight
        if pixelCount > Self.maximumPixelCount {
            let scale = sqrt(Double(Self.maximumPixelCount) / Double(pixelCount))
            safeWidth = max(1, Int((Double(safeWidth) * scale).rounded(.down)))
            safeHeight = max(1, Int((Double(safeHeight) * scale).rounded(.down)))
        }
        self.width = safeWidth
        self.height = safeHeight
    }

    public var maximum: Int { max(width, height) }
}

public struct MediaDimensions: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// Priority is domain-specific rather than inherited from an arbitrary caller task.
/// The scheduler raises an existing pending request when a more important subscriber
/// asks for the same key.
public enum MediaRequestPriority: Int, CaseIterable, Codable, Sendable, Comparable {
    case background = 0
    case nearVisible = 1
    case visible = 2
    case interactive = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var taskPriority: TaskPriority {
        switch self {
        case .interactive: .high
        case .visible: .userInitiated
        case .nearVisible: .medium
        case .background: .background
        }
    }
}

public enum MediaRepresentationKind: String, Codable, CaseIterable, Sendable {
    case thumbnail
    case preview
    case moviePoster
}

public enum MediaColorPolicy: String, Codable, Sendable {
    /// Preserve the embedded color space and let ColorSync manage display conversion.
    case sourceManaged
    case sRGB
    case extendedDynamicRange
}

public enum MediaKind: String, Codable, Sendable {
    case stillImage
    case rawImage
    case movie
    case audio
    case unknown
}

/// Identifies the authoritative field used to determine when media was captured.
///
/// `captureDateAssumedTimeZoneIdentifier` on ``MediaMetadata`` is non-nil when an
/// EXIF/TIFF wall-clock value did not carry an offset and therefore had to be
/// interpreted in the time zone frozen by the caller at the beginning of a scan.
public enum MediaCaptureDateSource: String, Codable, Sendable {
    case imageIOExifDateTimeOriginal
    case imageIOTIFFDateTime
    case quickTimeCreationDate
    case fileModificationDate
}

public enum MediaGenerationMethod: String, Codable, Sendable {
    case imageIO
    case quickLook
    case avFoundation
    case coreImageRAW
    case genericIcon
}

public enum MediaDeliverySource: String, Codable, Sendable {
    case generated
    case memoryCache
    case diskCache
}

public enum MediaFailureCode: String, Codable, Sendable {
    case fileNotFound
    case notRegularFile
    case permissionDenied
    case unsupported
    case unsupportedCamera
    case corrupt
    case cancelled
    case timeout
    case sourceChanged
    case imageIO
    case quickLook
    case avFoundation
    case coreImage
    case cacheIO
    case invalidResponse
    case unknown
}

/// A stable, privacy-safe error for UI state and tests. `diagnostic` must never contain
/// an absolute path, credential, or filename supplied by the user.
public struct MediaPipelineFailure: Error, Hashable, Codable, Sendable, LocalizedError {
    public let code: MediaFailureCode
    public let diagnostic: String?

    public init(_ code: MediaFailureCode, diagnostic: String? = nil) {
        self.code = code
        self.diagnostic = diagnostic.map { String($0.prefix(240)) }
    }

    public var errorDescription: String? {
        switch code {
        case .fileNotFound: "ファイルが見つかりません。"
        case .notRegularFile: "通常ファイルではありません。"
        case .permissionDenied: "ファイルの読み取り権限がありません。"
        case .unsupported, .unsupportedCamera: "このメディア形式は現在のmacOSで表示できません。"
        case .corrupt: "メディアファイルが破損しています。"
        case .cancelled: "メディア処理をキャンセルしました。"
        case .timeout: "メディア処理がタイムアウトしました。"
        case .sourceChanged: "処理中に元ファイルが変更されました。"
        case .imageIO, .quickLook, .avFoundation, .coreImage: "macOSのメディア処理に失敗しました。"
        case .cacheIO: "メディアキャッシュを読み書きできません。"
        case .invalidResponse: "macOSが不正なメディア結果を返しました。"
        case .unknown: "メディア処理に失敗しました。"
        }
    }

    static func classify(_ error: any Error, defaultCode: MediaFailureCode = .unknown) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return Self(.cancelled) }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return Self(.fileNotFound)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return Self(.permissionDenied)
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOENT): return Self(.fileNotFound)
            case Int(EACCES), Int(EPERM): return Self(.permissionDenied)
            case Int(ELOOP): return Self(.notRegularFile)
            default: break
            }
        }
        return Self(defaultCode, diagnostic: "\(nsError.domain):\(nsError.code)")
    }
}

/// A CGImage plus value metadata. CGImage is an immutable Core Foundation object once
/// created; the wrapper is therefore safe to pass between actors without exposing a
/// mutable drawing context.
public struct MediaImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: MediaDimensions
    public let bytesPerRow: Int
    public let generationMethod: MediaGenerationMethod
    public let deliverySource: MediaDeliverySource
    public let isFallback: Bool
    public let fallbackReason: MediaFailureCode?
    public let requestedTimeSeconds: Double?
    public let actualTimeSeconds: Double?

    public init(
        cgImage: CGImage,
        generationMethod: MediaGenerationMethod,
        deliverySource: MediaDeliverySource = .generated,
        isFallback: Bool = false,
        fallbackReason: MediaFailureCode? = nil,
        requestedTimeSeconds: Double? = nil,
        actualTimeSeconds: Double? = nil
    ) {
        self.cgImage = cgImage
        self.pixelSize = MediaDimensions(width: cgImage.width, height: cgImage.height)
        self.bytesPerRow = cgImage.bytesPerRow
        self.generationMethod = generationMethod
        self.deliverySource = deliverySource
        self.isFallback = isFallback
        self.fallbackReason = fallbackReason
        self.requestedTimeSeconds = requestedTimeSeconds
        self.actualTimeSeconds = actualTimeSeconds
    }

    public var decodedCostBytes: Int {
        let (cost, overflow) = bytesPerRow.multipliedReportingOverflow(by: pixelSize.height)
        return overflow ? Int.max : max(1, cost)
    }

    func delivered(from source: MediaDeliverySource) -> Self {
        Self(
            cgImage: cgImage,
            generationMethod: generationMethod,
            deliverySource: source,
            isFallback: isFallback,
            fallbackReason: fallbackReason,
            requestedTimeSeconds: requestedTimeSeconds,
            actualTimeSeconds: actualTimeSeconds
        )
    }

    func fallback(reason: MediaFailureCode) -> Self {
        Self(
            cgImage: cgImage,
            generationMethod: generationMethod,
            deliverySource: deliverySource,
            isFallback: true,
            fallbackReason: reason,
            requestedTimeSeconds: requestedTimeSeconds,
            actualTimeSeconds: actualTimeSeconds
        )
    }
}

public struct MediaMetadata: Hashable, Codable, Sendable {
    public let kind: MediaKind
    public let durationSeconds: Double?
    public let pixelSize: MediaDimensions?
    public let orientation: UInt32?
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let isPlayable: Bool
    public let hasProtectedContent: Bool
    public let codecs: [String]
    public let captureDate: Date?
    public let captureDateSource: MediaCaptureDateSource?
    public let captureDateAssumedTimeZoneIdentifier: String?

    public init(
        kind: MediaKind,
        durationSeconds: Double? = nil,
        pixelSize: MediaDimensions? = nil,
        orientation: UInt32? = nil,
        hasVideo: Bool = false,
        hasAudio: Bool = false,
        isPlayable: Bool = false,
        hasProtectedContent: Bool = false,
        codecs: [String] = [],
        captureDate: Date? = nil,
        captureDateSource: MediaCaptureDateSource? = nil,
        captureDateAssumedTimeZoneIdentifier: String? = nil
    ) {
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.isPlayable = isPlayable
        self.hasProtectedContent = hasProtectedContent
        self.codecs = codecs
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.captureDateAssumedTimeZoneIdentifier = captureDateAssumedTimeZoneIdentifier
    }
}

public struct MediaPlaybackDescriptor: Hashable, Codable, Sendable {
    public let sourceURL: URL
    public let durationSeconds: Double?
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let isPlayable: Bool
    public let hasProtectedContent: Bool

    public init(sourceURL: URL, metadata: MediaMetadata) {
        self.sourceURL = sourceURL
        self.durationSeconds = metadata.durationSeconds
        self.hasVideo = metadata.hasVideo
        self.hasAudio = metadata.hasAudio
        self.isPlayable = metadata.isPlayable
        self.hasProtectedContent = metadata.hasProtectedContent
    }
}

/// UI-independent preview state. The application creates/reuses AVPlayer itself from
/// `playback`; the media module never sends a non-Sendable player across actor bounds.
public struct MediaPreview: Sendable {
    public let sourceURL: URL
    public let kind: MediaKind
    public let image: MediaImage
    public let metadata: MediaMetadata
    public let playback: MediaPlaybackDescriptor?

    public init(
        sourceURL: URL,
        kind: MediaKind,
        image: MediaImage,
        metadata: MediaMetadata,
        playback: MediaPlaybackDescriptor?
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.image = image
        self.metadata = metadata
        self.playback = playback
    }
}

public struct MediaSourceFingerprint: Hashable, Codable, Sendable {
    public let volumeIdentifier: String?
    public let fileResourceIdentifier: String?
    public let normalizedPath: String
    public let byteSize: Int64
    public let modificationTimeNanoseconds: Int64
    public let quickFingerprint: String?
    public let verifiedSHA256: String?

    public init(
        volumeIdentifier: String?,
        fileResourceIdentifier: String?,
        normalizedPath: String,
        byteSize: Int64,
        modificationTimeNanoseconds: Int64,
        quickFingerprint: String? = nil,
        verifiedSHA256: String? = nil
    ) {
        self.volumeIdentifier = volumeIdentifier
        self.fileResourceIdentifier = fileResourceIdentifier
        self.normalizedPath = normalizedPath.precomposedStringWithCanonicalMapping
        self.byteSize = byteSize
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.quickFingerprint = quickFingerprint
        self.verifiedSHA256 = verifiedSHA256
    }

    public var cacheIdentityDigest: String {
        StableDigest.sha256([
            verifiedSHA256 ?? "",
            volumeIdentifier ?? "",
            fileResourceIdentifier ?? "",
            normalizedPath,
            String(byteSize),
            String(modificationTimeNanoseconds),
            quickFingerprint ?? "",
        ])
    }

    public func representsSameSource(as other: Self) -> Bool {
        volumeIdentifier == other.volumeIdentifier
            && fileResourceIdentifier == other.fileResourceIdentifier
            && normalizedPath == other.normalizedPath
            && byteSize == other.byteSize
            && modificationTimeNanoseconds == other.modificationTimeNanoseconds
            && verifiedSHA256 == other.verifiedSHA256
            && (quickFingerprint == nil || other.quickFingerprint == nil || quickFingerprint == other.quickFingerprint)
    }

    public static func capture(
        for url: URL,
        includeQuickFingerprint: Bool = false,
        verifiedSHA256: String? = nil
    ) throws -> Self {
        guard url.isFileURL else { throw MediaPipelineFailure(.unsupported, diagnostic: "non-file URL") }
        let standardized = url.standardizedFileURL
        var status = Darwin.stat()
        let result: Int32 = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw MediaPipelineFailure.classify(
                NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw MediaPipelineFailure(.notRegularFile)
        }
        let descriptor: Int32 = standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MediaPipelineFailure.classify(
                NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            )
        }
        _ = Darwin.close(descriptor)
        let normalizedPath = standardized.path.precomposedStringWithCanonicalMapping
        let seconds = Int64(status.st_mtimespec.tv_sec)
        let nanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let (secondComponent, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else {
            throw MediaPipelineFailure(.invalidResponse, diagnostic: "mtime overflow")
        }
        let (modificationNanoseconds, additionOverflow) = secondComponent.addingReportingOverflow(nanoseconds)
        guard !additionOverflow else {
            throw MediaPipelineFailure(.invalidResponse, diagnostic: "mtime addition overflow")
        }
        let byteSize = Int64(status.st_size)
        let quick = includeQuickFingerprint
            ? try quickDigest(url: standardized, byteSize: byteSize)
            : nil
        return Self(
            volumeIdentifier: String(status.st_dev),
            fileResourceIdentifier: String(status.st_ino),
            normalizedPath: normalizedPath,
            byteSize: byteSize,
            modificationTimeNanoseconds: modificationNanoseconds,
            quickFingerprint: quick,
            verifiedSHA256: verifiedSHA256
        )
    }

    private static func quickDigest(url: URL, byteSize: Int64) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw MediaPipelineFailure.classify(error)
        }
        defer { try? handle.close() }
        let blockSize = 64 * 1_024
        do {
            let first = try handle.read(upToCount: blockSize) ?? Data()
            let tailOffset = UInt64(max(0, byteSize - Int64(blockSize)))
            try handle.seek(toOffset: tailOffset)
            let last = try handle.read(upToCount: blockSize) ?? Data()
            var hasher = SHA256()
            hasher.update(data: first)
            hasher.update(data: Data(String(byteSize).utf8))
            hasher.update(data: last)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw MediaPipelineFailure.classify(error)
        }
    }
}

public struct MediaRequestKey: Hashable, Codable, Sendable {
    public let fingerprintDigest: String
    public let representation: MediaRepresentationKind
    public let pixelSize: MediaPixelSize
    public let colorPolicy: MediaColorPolicy
    public let pipelineVersion: Int

    public init(
        fingerprint: MediaSourceFingerprint,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy = .sourceManaged,
        pipelineVersion: Int
    ) {
        self.fingerprintDigest = fingerprint.cacheIdentityDigest
        self.representation = representation
        self.pixelSize = pixelSize
        self.colorPolicy = colorPolicy
        self.pipelineVersion = pipelineVersion
    }

    public var stableIdentifier: String {
        StableDigest.sha256([
            fingerprintDigest,
            representation.rawValue,
            String(pixelSize.width),
            String(pixelSize.height),
            colorPolicy.rawValue,
            String(pipelineVersion),
        ])
    }
}

enum StableDigest {
    static func sha256(_ fields: [String]) -> String {
        var bytes = Data()
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
