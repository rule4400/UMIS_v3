import Foundation

public enum MediaCacheKind: String, CaseIterable, Codable, Sendable {
    case thumbnail
    case preview
    case poster
    case scrub
    case proxy
    case waveform
    case metadata
}

public struct MediaPipelineConfiguration: Sendable {
    public var cacheDirectory: URL
    public var memoryBudgetBytes: Int
    public var diskHardLimitBytes: Int64
    public var diskSoftLimits: [MediaCacheKind: Int64]
    public var maximumConcurrentThumbnails: Int
    public var maximumConcurrentPreviews: Int
    public var maximumConcurrentMetadata: Int
    public var pipelineVersion: Int
    public var allowGenericFallback: Bool

    public init(
        cacheDirectory: URL,
        memoryBudgetBytes: Int = 128 * 1_024 * 1_024,
        diskHardLimitBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        diskSoftLimits: [MediaCacheKind: Int64] = [:],
        maximumConcurrentThumbnails: Int = 4,
        maximumConcurrentPreviews: Int = 1,
        maximumConcurrentMetadata: Int = 4,
        // v2 adds native capture-date metadata to cached metadata representations.
        pipelineVersion: Int = 2,
        allowGenericFallback: Bool = true
    ) {
        self.cacheDirectory = cacheDirectory
        self.memoryBudgetBytes = max(1, memoryBudgetBytes)
        self.diskHardLimitBytes = max(1, diskHardLimitBytes)
        self.diskSoftLimits = diskSoftLimits
        self.maximumConcurrentThumbnails = min(16, max(1, maximumConcurrentThumbnails))
        self.maximumConcurrentPreviews = min(4, max(1, maximumConcurrentPreviews))
        self.maximumConcurrentMetadata = min(16, max(1, maximumConcurrentMetadata))
        self.pipelineVersion = max(1, pipelineVersion)
        self.allowGenericFallback = allowGenericFallback
    }

    public static func standard(bundleIdentifier: String = "jp.rinkan.umis") -> Self {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        let gib: Int64 = 1_024 * 1_024 * 1_024
        return Self(
            cacheDirectory: root,
            diskHardLimitBytes: 2 * gib,
            diskSoftLimits: [
                .thumbnail: 512 * 1_024 * 1_024,
                .preview: 512 * 1_024 * 1_024,
                .poster: 256 * 1_024 * 1_024,
                .scrub: 256 * 1_024 * 1_024,
            ]
        )
    }
}

public struct MediaCacheStatistics: Hashable, Codable, Sendable {
    public let memoryEntryCount: Int
    public let memoryCostBytes: Int
    public let diskEntryCount: Int
    public let diskCostBytes: Int64

    public init(
        memoryEntryCount: Int,
        memoryCostBytes: Int,
        diskEntryCount: Int,
        diskCostBytes: Int64
    ) {
        self.memoryEntryCount = memoryEntryCount
        self.memoryCostBytes = memoryCostBytes
        self.diskEntryCount = diskEntryCount
        self.diskCostBytes = diskCostBytes
    }
}
