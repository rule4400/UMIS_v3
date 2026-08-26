@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import UMISMedia

enum MediaTestFixture {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UMISMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func image(width: Int, height: Int, seed: UInt8 = 0) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MediaPipelineFailure(.invalidResponse, diagnostic: "test CGContext")
        }
        let base = CGFloat(seed) / 255
        context.setFillColor(red: 0.1 + base * 0.3, green: 0.2, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.6 + base * 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else {
            throw MediaPipelineFailure(.invalidResponse, diagnostic: "test CGImage")
        }
        return image
    }

    static func writeImage(
        _ image: CGImage,
        to url: URL,
        type: UTType = .png,
        orientation: UInt32? = nil,
        exifDateTimeOriginal: String? = nil,
        exifOffsetTimeOriginal: String? = nil,
        tiffDateTime: String? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaPipelineFailure(.cacheIO, diagnostic: "test image destination")
        }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        var exif: [CFString: Any] = [:]
        if let exifDateTimeOriginal {
            exif[kCGImagePropertyExifDateTimeOriginal] = exifDateTimeOriginal
        }
        if let exifOffsetTimeOriginal {
            exif[kCGImagePropertyExifOffsetTimeOriginal] = exifOffsetTimeOriginal
        }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if let tiffDateTime {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFDateTime: tiffDateTime,
            ]
        }
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaPipelineFailure(.cacheIO, diagnostic: "test image finalize")
        }
    }

    static func configuration(
        directory: URL,
        memoryBudgetBytes: Int = 4 * 1_024 * 1_024,
        diskHardLimitBytes: Int64 = 16 * 1_024 * 1_024,
        maximumConcurrentThumbnails: Int = 4,
        maximumConcurrentPreviews: Int = 1,
        allowGenericFallback: Bool = true
    ) -> MediaPipelineConfiguration {
        MediaPipelineConfiguration(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            memoryBudgetBytes: memoryBudgetBytes,
            diskHardLimitBytes: diskHardLimitBytes,
            maximumConcurrentThumbnails: maximumConcurrentThumbnails,
            maximumConcurrentPreviews: maximumConcurrentPreviews,
            maximumConcurrentMetadata: 2,
            pipelineVersion: 7,
            allowGenericFallback: allowGenericFallback
        )
    }

    static func writeMovie(
        to url: URL,
        creationDate: String? = nil
    ) async throws {
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaPipelineFailure(.avFoundation, diagnostic: "test writer input")
        }
        writer.add(input)
        if let creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = creationDate as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [item]
        }
        guard writer.startWriting() else {
            throw writer.error ?? MediaPipelineFailure(.avFoundation, diagnostic: "test writer start")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MediaPipelineFailure(.avFoundation, diagnostic: "test pixel pool")
        }
        let producer = MovieFixtureProducer(
            writer: writer,
            input: input,
            adaptor: adaptor,
            pool: pool,
            height: height
        )
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                producer.start(continuation: continuation)
            }
        } onCancel: {
            producer.cancel()
        }
        try result.get()
    }
}

private final class MovieFixtureProducer: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let height: Int
    private let queue = DispatchQueue(label: "jp.rinkan.umis.tests.movie-writer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, MediaPipelineFailure>, Never>?
    private var frame = 0
    private var isFinished = false

    init(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool,
        height: Int
    ) {
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.pool = pool
        self.height = height
    }

    func start(
        continuation: CheckedContinuation<Result<Void, MediaPipelineFailure>, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        input.requestMediaDataWhenReady(on: queue) { [self] in
            supplyFrames()
        }
    }

    func cancel() {
        writer.cancelWriting()
        complete(.failure(.init(.cancelled)))
    }

    private func supplyFrames() {
        while input.isReadyForMoreMediaData, frame < 10 {
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer
            else {
                writer.cancelWriting()
                complete(.failure(.init(.avFoundation, diagnostic: "test pixel buffer")))
                return
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * height
                memset(base, frame.isMultiple(of: 2) ? 0x35 : 0xa5, byteCount)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: Int64(frame), timescale: 10)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                writer.cancelWriting()
                complete(.failure(
                    writer.error.map { MediaPipelineFailure.classify($0, defaultCode: .avFoundation) }
                        ?? .init(.avFoundation, diagnostic: "test append")
                ))
                return
            }
            frame += 1
        }
        guard frame == 10 else { return }
        input.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                complete(.success(()))
            } else {
                complete(.failure(
                    writer.error.map { MediaPipelineFailure.classify($0, defaultCode: .avFoundation) }
                        ?? .init(.avFoundation, diagnostic: "test finish")
                ))
            }
        }
    }

    private func complete(_ result: Result<Void, MediaPipelineFailure>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }

    func waiterCount() -> Int {
        waiters.count
    }
}

actor AsyncCompletionFlag {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func value() -> Bool {
        isComplete
    }
}

struct TestGeneratorStatistics: Sendable, Equatable {
    let invocationCount: Int
    let activeCount: Int
    let maximumActiveCount: Int
    let cancellationCount: Int
    let startOrder: [String]
}

actor CountingMediaGenerator: MediaGenerating {
    private let resultImage: MediaImage
    private let gate: TestGate?
    private var invocationCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var cancellationCount = 0
    private var startOrder: [String] = []

    init(image: CGImage, gate: TestGate? = nil) {
        resultImage = MediaImage(cgImage: image, generationMethod: .imageIO)
        self.gate = gate
    }

    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        invocationCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startOrder.append(url.lastPathComponent)
        defer { activeCount -= 1 }
        if let gate { await gate.wait() }
        await Task.yield()
        if Task.isCancelled {
            cancellationCount += 1
            return .failure(.init(.cancelled))
        }
        return .success(resultImage)
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        .success(MediaMetadata(kind: .stillImage, pixelSize: resultImage.pixelSize))
    }

    func statistics() -> TestGeneratorStatistics {
        TestGeneratorStatistics(
            invocationCount: invocationCount,
            activeCount: activeCount,
            maximumActiveCount: maximumActiveCount,
            cancellationCount: cancellationCount,
            startOrder: startOrder
        )
    }
}

actor CancellationMediaGenerator: MediaGenerating {
    private let resultImage: MediaImage
    private var invocationCount = 0
    private var activeCount = 0
    private var cancellationCount = 0

    init(image: CGImage) {
        resultImage = MediaImage(cgImage: image, generationMethod: .imageIO)
    }

    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        invocationCount += 1
        activeCount += 1
        defer { activeCount -= 1 }
        do {
            try await Task.sleep(for: .seconds(3_600))
            return .success(resultImage)
        } catch {
            cancellationCount += 1
            return .failure(.init(.cancelled))
        }
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        .success(MediaMetadata(kind: .stillImage))
    }

    func statistics() -> TestGeneratorStatistics {
        TestGeneratorStatistics(
            invocationCount: invocationCount,
            activeCount: activeCount,
            maximumActiveCount: activeCount,
            cancellationCount: cancellationCount,
            startOrder: []
        )
    }
}

actor UnsupportedMediaGenerator: MediaGenerating {
    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        .failure(.init(.unsupported))
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        .success(MediaMetadata(kind: .unknown))
    }
}

struct MetadataGeneratorStatistics: Sendable, Equatable {
    let invocationCount: Int
    let activeCount: Int
    let maximumActiveCount: Int
}

actor CountingMetadataGenerator: MediaGenerating {
    private let resultImage: MediaImage
    private let gate: TestGate
    private var invocationCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0

    init(image: CGImage, gate: TestGate) {
        resultImage = MediaImage(cgImage: image, generationMethod: .imageIO)
        self.gate = gate
    }

    func generateImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        colorPolicy: MediaColorPolicy,
        allowGenericFallback: Bool
    ) async -> Result<MediaImage, MediaPipelineFailure> {
        .success(resultImage)
    }

    func metadata(
        for url: URL,
        assumedTimeZone: TimeZone
    ) async -> Result<MediaMetadata, MediaPipelineFailure> {
        invocationCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        await gate.wait()
        if Task.isCancelled { return .failure(.init(.cancelled)) }
        return .success(MediaMetadata(
            kind: .stillImage,
            captureDate: Date(timeIntervalSince1970: TimeInterval(url.lastPathComponent.count)),
            captureDateSource: .fileModificationDate
        ))
    }

    func statistics() -> MetadataGeneratorStatistics {
        MetadataGeneratorStatistics(
            invocationCount: invocationCount,
            activeCount: activeCount,
            maximumActiveCount: maximumActiveCount
        )
    }
}
