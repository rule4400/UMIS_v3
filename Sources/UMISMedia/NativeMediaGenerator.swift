@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import CoreImage
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Internal seam used by deterministic scheduler/cache tests. Production always uses
/// `NativeMediaGenerator`; no third-party decoder or subprocess is involved.
protocol MediaGenerating: Sendable {
    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure>

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure>
}

struct NativeMediaGenerator: MediaGenerating {
    private static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcr", "dcs",
        "dng", "drf", "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc",
        "mef", "mos", "mrw", "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn",
        "r3d", "raf", "raw", "rwl", "rw2", "rwz", "sr2", "srf", "srw", "x3f",
    ]
    private static let directImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "jp2", "png", "tif",
        "tiff",
    ]

    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        if Task.isCancelled { return .failure(.init(.cancelled)) }
        let kind = Self.classify(url)
        var failures: [MediaPipelineFailure] = []
        var fallbackCandidate: MediaImage?

        // ImageIO is fastest and can decode embedded RAW previews without expanding the
        // full sensor image. It is deliberately attempted by capability, not extension.
        if kind == .stillImage || kind == .rawImage || kind == .unknown {
            switch Self.imageIOImage(
                url: url,
                pixelSize: pixelSize,
                colorPolicy: colorPolicy,
                expectedImage: kind == .stillImage
                    && Self.directImageExtensions.contains(url.pathExtension.lowercased())
            ) {
            case let .success(image): return .success(image)
            case let .failure(error): failures.append(error)
            }
        }
        if Task.isCancelled { return .failure(.init(.cancelled)) }

        // Movies use AVFoundation before Quick Look so poster time and metadata remain
        // deterministic. Unknown files use Quick Look first because macOS may support a
        // format through an installed system extension.
        if kind == .movie || representation == .moviePoster {
            switch await Self.moviePoster(url: url, pixelSize: pixelSize) {
            case let .success(image): return .success(image)
            case let .failure(error): failures.append(error)
            }
        }
        if Task.isCancelled { return .failure(.init(.cancelled)) }

        switch await Self.quickLookImage(url: url, pixelSize: pixelSize) {
        case let .success(image):
            if image.isFallback {
                fallbackCandidate = image
            } else {
                return .success(image)
            }
        case let .failure(error): failures.append(error)
        }
        if Task.isCancelled { return .failure(.init(.cancelled)) }

        // Core Image is the last real decoder in the chain, mainly for RAW camera
        // formats whose embedded preview is unavailable to ImageIO.
        if kind == .rawImage || kind == .stillImage || kind == .unknown {
            switch Self.coreImage(
                url: url,
                pixelSize: pixelSize,
                colorPolicy: colorPolicy,
                preferRAWDecoder: kind == .rawImage
            ) {
            case let .success(image): return .success(image)
            case let .failure(error): failures.append(error)
            }
        }

        let terminal = Self.preferredFailure(failures, kind: kind)
        if let fallbackCandidate {
            return .success(fallbackCandidate.fallback(reason: terminal.code))
        }
        guard allowGenericFallback else { return .failure(terminal) }
        guard let placeholder = Self.placeholder(pixelSize: pixelSize, reason: terminal.code) else {
            return .failure(terminal)
        }
        return .success(placeholder)
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        if Task.isCancelled { return .failure(.init(.cancelled)) }
        let kind = Self.classify(url)
        if kind == .movie || kind == .audio {
            return await Self.avMetadata(
                url: url,
                classifiedKind: kind,
                assumedTimeZone: assumedTimeZone
            )
        }
        if let metadata = Self.imageMetadata(
            url: url,
            classifiedKind: kind,
            assumedTimeZone: assumedTimeZone
        ) {
            return .success(metadata)
        }
        if kind == .unknown {
            // Unknown may still be an AV format recognized by the current OS.
            let avResult = await Self.avMetadata(
                url: url,
                classifiedKind: .unknown,
                assumedTimeZone: assumedTimeZone
            )
            if case let .success(value) = avResult, value.hasVideo || value.hasAudio {
                return .success(value)
            }
        }
        let capture = MediaCaptureDateExtractor.fileModificationDate(for: url)
        return .success(MediaMetadata(
            kind: kind,
            captureDate: capture?.date,
            captureDateSource: capture?.source,
            captureDateAssumedTimeZoneIdentifier: capture?.assumedTimeZoneIdentifier
        ))
    }

    private static func classify(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return .rawImage }
        guard let type = UTType(filenameExtension: ext) else { return .unknown }
        if type.conforms(to: .image) { return .stillImage }
        if type.conforms(to: .movie) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .movie }
        return .unknown
    }

    private static func imageIOImage(
        url: URL,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        expectedImage: Bool
    ) -> Result<MediaImage, MediaPipelineFailure> {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return .failure(.init(
                expectedImage ? .corrupt : .unsupported,
                diagnostic: "ImageIO source"
            ))
        }
        guard CGImageSourceGetCount(source) > 0 else {
            return .failure(imageIOStatusFailure(
                source,
                expectedImage: expectedImage,
                fallback: expectedImage ? .corrupt : .unsupported
            ))
        }
        let maxPixel = fittedMaximumPixel(source: source, requested: pixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failure(imageIOStatusFailure(
                source,
                expectedImage: expectedImage,
                fallback: expectedImage ? .corrupt : .imageIO
            ))
        }
        guard let fitted = fitIfNeeded(decoded, requested: pixelSize, colorPolicy: colorPolicy) else {
            return .failure(.init(.imageIO, diagnostic: "bounded render"))
        }
        return .success(MediaImage(cgImage: fitted, generationMethod: .imageIO))
    }

    private static func fittedMaximumPixel(source: CGImageSource, requested: MediaPixelSize) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0
        else {
            return requested.maximum
        }
        let orientation = UInt32(number(properties[kCGImagePropertyOrientation]) ?? 1)
        let swapsAxes = orientation >= 5 && orientation <= 8
        let orientedWidth = swapsAxes ? height : width
        let orientedHeight = swapsAxes ? width : height
        let scale = min(
            1,
            min(Double(requested.width) / orientedWidth, Double(requested.height) / orientedHeight)
        )
        return max(1, Int((max(orientedWidth, orientedHeight) * scale).rounded(.down)))
    }

    private static func imageMetadata(
        url: URL,
        classifiedKind: MediaKind,
        assumedTimeZone: TimeZone
    ) -> MediaMetadata? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = number(properties[kCGImagePropertyPixelWidth]).map(Int.init)
        let height = number(properties[kCGImagePropertyPixelHeight]).map(Int.init)
        let orientation = number(properties[kCGImagePropertyOrientation]).map(UInt32.init)
        let dimensions: MediaDimensions?
        if let width, let height {
            if let orientation, orientation >= 5 && orientation <= 8 {
                dimensions = MediaDimensions(width: height, height: width)
            } else {
                dimensions = MediaDimensions(width: width, height: height)
            }
        } else {
            dimensions = nil
        }
        let capture = MediaCaptureDateExtractor.image(
            properties: properties,
            assumedTimeZone: assumedTimeZone
        ) ?? MediaCaptureDateExtractor.fileModificationDate(for: url)
        return MediaMetadata(
            kind: classifiedKind == .rawImage ? .rawImage : .stillImage,
            pixelSize: dimensions,
            orientation: orientation,
            captureDate: capture?.date,
            captureDateSource: capture?.source,
            captureDateAssumedTimeZoneIdentifier: capture?.assumedTimeZoneIdentifier
        )
    }

    private static func imageIOStatusFailure(
        _ source: CGImageSource,
        expectedImage: Bool,
        fallback: MediaFailureCode
    ) -> MediaPipelineFailure {
        switch CGImageSourceGetStatus(source) {
        case .statusUnexpectedEOF, .statusInvalidData, .statusIncomplete:
            return .init(
                expectedImage ? .corrupt : .unsupported,
                diagnostic: "ImageIO invalid data"
            )
        case .statusUnknownType:
            return .init(
                expectedImage ? .corrupt : .unsupported,
                diagnostic: "ImageIO unknown type"
            )
        default:
            return .init(fallback, diagnostic: "ImageIO decode status")
        }
    }

    private static func quickLookImage(
        url: URL,
        pixelSize: MediaPixelSize
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize.width, height: pixelSize.height),
            scale: 1,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        let requestBox = QuickLookRequestBox(request)
        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(requestBox.request)
            }
            if Task.isCancelled { return .failure(.init(.cancelled)) }
            let image = representation.cgImage
            guard let fitted = fitIfNeeded(
                image,
                requested: pixelSize,
                colorPolicy: .sourceManaged
            ) else {
                return .failure(.init(.quickLook, diagnostic: "bounded render"))
            }
            let isLowQualityFallback = representation.type == .lowQualityThumbnail
            return .success(MediaImage(
                cgImage: fitted,
                generationMethod: .quickLook,
                isFallback: isLowQualityFallback,
                fallbackReason: isLowQualityFallback ? .unsupported : nil
            ))
        } catch {
            return .failure(MediaPipelineFailure.classify(error, defaultCode: .quickLook))
        }
    }

    private static func moviePoster(
        url: URL,
        pixelSize: MediaPixelSize
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            let duration = try await asset.load(.duration)
            if Task.isCancelled { return .failure(.init(.cancelled)) }
            let finiteDuration = duration.isNumeric && duration.seconds.isFinite ? max(0, duration.seconds) : 0
            let requestedSeconds = finiteDuration > 0 ? min(finiteDuration, max(0, finiteDuration * 0.05)) : 0
            let requestedTime = CMTime(seconds: requestedSeconds, preferredTimescale: 600)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixelSize.width, height: pixelSize.height)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let generatorBox = ImageGeneratorBox(generator)
            let tuple = try await withTaskCancellationHandler {
                try await generator.image(at: requestedTime)
            } onCancel: {
                generatorBox.generator.cancelAllCGImageGeneration()
            }
            if Task.isCancelled { return .failure(.init(.cancelled)) }
            guard let fitted = fitIfNeeded(
                tuple.image,
                requested: pixelSize,
                colorPolicy: .sourceManaged
            ) else {
                return .failure(.init(.avFoundation, diagnostic: "bounded render"))
            }
            return .success(MediaImage(
                cgImage: fitted,
                generationMethod: .avFoundation,
                requestedTimeSeconds: requestedSeconds,
                actualTimeSeconds: tuple.actualTime.seconds.isFinite ? tuple.actualTime.seconds : nil
            ))
        } catch {
            return .failure(MediaPipelineFailure.classify(error, defaultCode: .avFoundation))
        }
    }

    private static func avMetadata(
        url: URL,
        classifiedKind: MediaKind,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            async let captureValue = avCaptureDate(
                asset: asset,
                url: url,
                assumedTimeZone: assumedTimeZone
            )
            async let durationValue = asset.load(.duration)
            async let playableValue = asset.load(.isPlayable)
            async let protectedValue = asset.load(.hasProtectedContent)
            async let videoTracksValue = asset.loadTracks(withMediaType: .video)
            async let audioTracksValue = asset.loadTracks(withMediaType: .audio)
            let (duration, isPlayable, protected, videoTracks, audioTracks) = try await (
                durationValue,
                playableValue,
                protectedValue,
                videoTracksValue,
                audioTracksValue
            )
            if Task.isCancelled { return .failure(.init(.cancelled)) }

            var dimensions: MediaDimensions?
            var codecs: Set<String> = []
            if let track = videoTracks.first {
                async let naturalSizeValue = track.load(.naturalSize)
                async let transformValue = track.load(.preferredTransform)
                let (naturalSize, transform) = try await (naturalSizeValue, transformValue)
                let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
                dimensions = MediaDimensions(
                    width: Int(abs(transformed.width).rounded()),
                    height: Int(abs(transformed.height).rounded())
                )
            }
            for track in videoTracks + audioTracks {
                let descriptions = try await track.load(.formatDescriptions)
                for description in descriptions {
                    codecs.insert(fourCC(CMFormatDescriptionGetMediaSubType(description)))
                }
            }
            let seconds = duration.isNumeric && duration.seconds.isFinite ? max(0, duration.seconds) : nil
            let kind: MediaKind = !videoTracks.isEmpty
                ? .movie
                : (!audioTracks.isEmpty ? .audio : classifiedKind)
            let capture = await captureValue
            return .success(MediaMetadata(
                kind: kind,
                durationSeconds: seconds,
                pixelSize: dimensions,
                hasVideo: !videoTracks.isEmpty,
                hasAudio: !audioTracks.isEmpty,
                isPlayable: isPlayable,
                hasProtectedContent: protected,
                codecs: codecs.sorted(),
                captureDate: capture?.date,
                captureDateSource: capture?.source,
                captureDateAssumedTimeZoneIdentifier: capture?.assumedTimeZoneIdentifier
            ))
        } catch {
            return .failure(MediaPipelineFailure.classify(error, defaultCode: .avFoundation))
        }
    }

    private static func avCaptureDate(
        asset: AVAsset,
        url: URL,
        assumedTimeZone: TimeZone
    ) async -> MediaCaptureDateResolution? {
        do {
            if let item = try await asset.load(.creationDate) {
                let dateValue = try? await item.load(.dateValue)
                let stringValue = try? await item.load(.stringValue)
                if let embedded = MediaCaptureDateExtractor.quickTime(
                    dateValue: dateValue,
                    stringValue: stringValue,
                    assumedTimeZone: assumedTimeZone
                ) {
                    return embedded
                }
            }
        } catch {
            // Creation metadata is optional. Track metadata remains useful when this
            // individual field is malformed or unsupported by the current OS.
        }
        return MediaCaptureDateExtractor.fileModificationDate(for: url)
    }

    private static func coreImage(
        url: URL,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        preferRAWDecoder: Bool
    ) -> Result<MediaImage, MediaPipelineFailure> {
        let input: CIImage?
        if preferRAWDecoder, let rawFilter = CIRAWFilter(imageURL: url) {
            let nativeSize = rawFilter.nativeSize
            if nativeSize.width > 0, nativeSize.height > 0 {
                let scale = min(
                    1,
                    min(
                        CGFloat(pixelSize.width) / nativeSize.width,
                        CGFloat(pixelSize.height) / nativeSize.height
                    )
                )
                rawFilter.scaleFactor = Float(max(0.001, scale))
            }
            rawFilter.isDraftModeEnabled = true
            rawFilter.extendedDynamicRangeAmount = colorPolicy == .extendedDynamicRange ? 1 : 0
            input = rawFilter.outputImage
        } else {
            input = CIImage(
                contentsOf: url,
                options: [
                    .applyOrientationProperty: true,
                    .cacheImmediately: false,
                ]
            )
        }
        guard let input else {
            return .failure(.init(.unsupportedCamera, diagnostic: "CoreImage source"))
        }
        let extent = input.extent.integral
        guard !extent.isNull, !extent.isInfinite, extent.width > 0, extent.height > 0 else {
            return .failure(.init(.coreImage, diagnostic: "invalid extent"))
        }
        let scale = min(
            1,
            min(CGFloat(pixelSize.width) / extent.width, CGFloat(pixelSize.height) / extent.height)
        )
        let output: CIImage
        if scale < 1 {
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(input, forKey: kCIInputImageKey)
            filter?.setValue(scale, forKey: kCIInputScaleKey)
            filter?.setValue(1, forKey: kCIInputAspectRatioKey)
            guard let filtered = filter?.outputImage else {
                return .failure(.init(.coreImage, diagnostic: "Lanczos filter"))
            }
            output = filtered
        } else {
            output = input
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace: CGColorSpace?
        let format: CIFormat
        switch colorPolicy {
        case .sRGB:
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            format = .RGBA8
        case .extendedDynamicRange:
            colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            format = .RGBAh
        case .sourceManaged:
            colorSpace = nil
            format = .RGBA8
        }
        guard let image = context.createCGImage(
            output,
            from: output.extent,
            format: format,
            colorSpace: colorSpace
        ) else {
            return .failure(.init(.coreImage, diagnostic: "render"))
        }
        guard let fitted = fitIfNeeded(
            image,
            requested: pixelSize,
            colorPolicy: .sourceManaged
        ) else {
            return .failure(.init(.coreImage, diagnostic: "bounded render"))
        }
        return .success(MediaImage(cgImage: fitted, generationMethod: .coreImageRAW))
    }

    private static func fitIfNeeded(
        _ source: CGImage,
        requested: MediaPixelSize,
        colorPolicy: MediaColorPolicy
    ) -> CGImage? {
        let scale = min(
            1,
            min(CGFloat(requested.width) / CGFloat(source.width), CGFloat(requested.height) / CGFloat(source.height))
        )
        let requiresScale = scale < 0.9999
        let requiresColorConversion = colorPolicy == .sRGB
        guard requiresScale || requiresColorConversion else { return source }
        let width = max(1, Int((CGFloat(source.width) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded(.down)))
        let colorSpace = colorPolicy == .sRGB
            ? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
            : (source.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func placeholder(
        pixelSize: MediaPixelSize,
        reason: MediaFailureCode
    ) -> MediaImage? {
        // Keep fallback memory bounded even if a caller accidentally requests a huge
        // preview. It is an explanatory placeholder, not source media.
        let longest = min(512, pixelSize.maximum)
        let ratio = min(
            CGFloat(longest) / CGFloat(pixelSize.width),
            CGFloat(longest) / CGFloat(pixelSize.height)
        )
        let width = max(1, Int(CGFloat(pixelSize.width) * ratio))
        let height = max(1, Int(CGFloat(pixelSize.height) * ratio))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = CGFloat(max(2, min(width, height) / 7))
        context.setStrokeColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1)
        context.setLineWidth(max(1, CGFloat(min(width, height)) / 32))
        context.stroke(CGRect(
            x: inset,
            y: inset,
            width: max(1, CGFloat(width) - inset * 2),
            height: max(1, CGFloat(height) - inset * 2)
        ))
        context.move(to: CGPoint(x: inset, y: inset))
        context.addLine(to: CGPoint(x: CGFloat(width) - inset, y: CGFloat(height) - inset))
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return MediaImage(
            cgImage: image,
            generationMethod: .genericIcon,
            isFallback: true,
            fallbackReason: reason
        )
    }

    private static func preferredFailure(
        _ failures: [MediaPipelineFailure],
        kind: MediaKind
    ) -> MediaPipelineFailure {
        if let cancelled = failures.first(where: { $0.code == .cancelled }) { return cancelled }
        if let permission = failures.first(where: { $0.code == .permissionDenied }) { return permission }
        if let missing = failures.first(where: { $0.code == .fileNotFound }) { return missing }
        if let corrupt = failures.first(where: { $0.code == .corrupt }) { return corrupt }
        if kind == .rawImage { return .init(.unsupportedCamera) }
        return .init(.unsupported)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let scalars = [24, 16, 8, 0].map { shift -> UnicodeScalar in
            let byte = UInt8((value >> FourCharCode(shift)) & 0xff)
            return UnicodeScalar(byte >= 32 && byte <= 126 ? byte : 46)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private final class QuickLookRequestBox: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request

    init(_ request: QLThumbnailGenerator.Request) {
        self.request = request
    }
}

private final class ImageGeneratorBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator

    init(_ generator: AVAssetImageGenerator) {
        self.generator = generator
    }
}
