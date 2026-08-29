import CoreGraphics
import UMISMedia

/// Converts point-space presentation bounds into bounded media-pipeline requests. Keeping this
/// policy independent from AppKit/SwiftUI lets collection prefetches and visible cells share the
/// exact same cache key, including on a 1x display.
enum MediaRequestSizingPolicy {
    static let maximumBackingScaleFactor: CGFloat = 2
    static let maximumPreviewPixelSize = MediaPixelSize(width: 1_920, height: 1_080)

    /// The image view inside a 174-point collection tile is 152 x 83 points after the card and
    /// image-container insets. These values intentionally describe the rendered thumbnail rather
    /// than the full card, so decoding does not include pixels the UI cannot display.
    static let assetTileThumbnailPointSize = CGSize(width: 152, height: 83)

    static func assetTileThumbnailPixelSize(
        pointSize: CGSize = assetTileThumbnailPointSize,
        backingScaleFactor: CGFloat
    ) -> MediaPixelSize {
        pixelSize(
            pointSize: pointSize,
            backingScaleFactor: backingScaleFactor,
            maximum: MediaPixelSize(
                width: MediaPixelSize.maximumDimension,
                height: MediaPixelSize.maximumDimension
            ),
            quantum: 1
        )
    }

    /// Preview dimensions are rounded up into modest buckets so live window resizing does not
    /// generate a distinct disk-cache entry for every point. The old 1920 x 1080 request remains
    /// the hard quality ceiling; smaller windows and 1x displays now request only what they show.
    static func previewPixelSize(
        viewportPointSize: CGSize,
        backingScaleFactor: CGFloat
    ) -> MediaPixelSize {
        pixelSize(
            pointSize: viewportPointSize,
            backingScaleFactor: backingScaleFactor,
            maximum: maximumPreviewPixelSize,
            quantum: 64
        )
    }

    private static func pixelSize(
        pointSize: CGSize,
        backingScaleFactor: CGFloat,
        maximum: MediaPixelSize,
        quantum: Int
    ) -> MediaPixelSize {
        let scale = normalizedBackingScaleFactor(backingScaleFactor)
        return MediaPixelSize(
            width: pixelDimension(
                points: pointSize.width,
                scale: scale,
                maximum: maximum.width,
                quantum: quantum
            ),
            height: pixelDimension(
                points: pointSize.height,
                scale: scale,
                maximum: maximum.height,
                quantum: quantum
            )
        )
    }

    private static func normalizedBackingScaleFactor(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(maximumBackingScaleFactor, max(1, scale))
    }

    private static func pixelDimension(
        points: CGFloat,
        scale: CGFloat,
        maximum: Int,
        quantum: Int
    ) -> Int {
        let safePoints = points.isFinite ? max(1, points) : 1
        let boundedPixels = min(CGFloat(maximum), ceil(safePoints * scale))
        let integerPixels = max(1, Int(boundedPixels))
        let bucket = max(1, quantum)
        let roundedPixels = ((integerPixels + bucket - 1) / bucket) * bucket
        return min(maximum, roundedPixels)
    }
}
