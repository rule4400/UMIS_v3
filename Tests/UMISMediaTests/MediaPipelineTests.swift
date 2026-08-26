import Foundation
import ImageIO
import XCTest
@testable import UMISMedia

@MainActor
final class MediaPipelineTests: XCTestCase {
    func testRequestKeyIsDeterministicAndIncludesEveryDecodeDimension() {
        let defensiveSize = MediaPixelSize(width: Int.max, height: Int.max)
        XCTAssertLessThanOrEqual(defensiveSize.width, MediaPixelSize.maximumDimension)
        XCTAssertLessThanOrEqual(defensiveSize.height, MediaPixelSize.maximumDimension)
        XCTAssertLessThanOrEqual(
            defensiveSize.width * defensiveSize.height,
            MediaPixelSize.maximumPixelCount
        )
        let fingerprint = MediaSourceFingerprint(
            volumeIdentifier: "volume",
            fileResourceIdentifier: "file",
            normalizedPath: "/fixture/cafe\u{301}.jpg",
            byteSize: 123,
            modificationTimeNanoseconds: 456,
            quickFingerprint: "quick"
        )
        let first = MediaRequestKey(
            fingerprint: fingerprint,
            representation: .thumbnail,
            pixelSize: MediaPixelSize(width: 320, height: 180),
            colorPolicy: .sRGB,
            pipelineVersion: 3
        )
        let same = MediaRequestKey(
            fingerprint: fingerprint,
            representation: .thumbnail,
            pixelSize: MediaPixelSize(width: 320, height: 180),
            colorPolicy: .sRGB,
            pipelineVersion: 3
        )
        let changedSize = MediaRequestKey(
            fingerprint: fingerprint,
            representation: .thumbnail,
            pixelSize: MediaPixelSize(width: 321, height: 180),
            colorPolicy: .sRGB,
            pipelineVersion: 3
        )
        let changedVersion = MediaRequestKey(
            fingerprint: fingerprint,
            representation: .thumbnail,
            pixelSize: MediaPixelSize(width: 320, height: 180),
            colorPolicy: .sRGB,
            pipelineVersion: 4
        )

        XCTAssertEqual(first.stableIdentifier, same.stableIdentifier)
        XCTAssertEqual(first.stableIdentifier.count, 64)
        XCTAssertNotEqual(first.stableIdentifier, changedSize.stableIdentifier)
        XCTAssertNotEqual(first.stableIdentifier, changedVersion.stableIdentifier)
        XCTAssertEqual(fingerprint.normalizedPath, "/fixture/café.jpg")
    }

    func testSourceMutationChangesFingerprintAndCacheKey() throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 64).write(to: url)
        let before = try MediaSourceFingerprint.capture(for: url, includeQuickFingerprint: true)
        try Data(repeating: 2, count: 65).write(to: url, options: .atomic)
        let after = try MediaSourceFingerprint.capture(for: url, includeQuickFingerprint: true)

        XCTAssertFalse(before.representsSameSource(as: after))
        XCTAssertNotEqual(before.cacheIdentityDigest, after.cacheIdentityDigest)
    }

    func testFingerprintRejectsSymbolicLinkInsteadOfFollowingIt() throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("link.bin")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try MediaSourceFingerprint.capture(for: link)) { error in
            XCTAssertEqual((error as? MediaPipelineFailure)?.code, .notRegularFile)
        }
    }

    func testNativeImageIODownsamplesAppliesOrientationAndUsesMemoryCache() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("oriented.jpg")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 800, height: 400),
            to: source,
            type: .jpeg,
            orientation: 6
        )
        let pipeline = try MediaPipeline(configuration: MediaTestFixture.configuration(directory: directory))

        let first = try await pipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 120, height: 120),
            priority: .visible
        )
        let second = try await pipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 120, height: 120),
            priority: .visible
        )
        let metadata = try await pipeline.metadata(for: source)
        let diagnostics = await pipeline.diagnostics()

        XCTAssertLessThanOrEqual(first.pixelSize.width, 120)
        XCTAssertLessThanOrEqual(first.pixelSize.height, 120)
        XCTAssertGreaterThan(first.pixelSize.height, first.pixelSize.width)
        XCTAssertEqual(first.generationMethod, .imageIO)
        XCTAssertEqual(first.deliverySource, .generated)
        XCTAssertEqual(second.deliverySource, .memoryCache)
        XCTAssertEqual(metadata.kind, .stillImage)
        XCTAssertEqual(metadata.orientation, 6)
        XCTAssertEqual(metadata.pixelSize, MediaDimensions(width: 400, height: 800))
        XCTAssertEqual(diagnostics.metrics.generatedCount, 1)
        XCTAssertEqual(diagnostics.metrics.memoryHitCount, 1)
        XCTAssertGreaterThan(diagnostics.cache.memoryCostBytes, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.cache.memoryCostBytes,
            pipeline.configuration.memoryBudgetBytes
        )
    }

    func testDiskCacheSurvivesPipelineRecreation() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("still.png")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 640, height: 360),
            to: source
        )
        let configuration = MediaTestFixture.configuration(directory: directory)
        let firstPipeline = try MediaPipeline(configuration: configuration)
        let generated = try await firstPipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 160, height: 90)
        )
        XCTAssertEqual(generated.deliverySource, .generated)

        let secondPipeline = try MediaPipeline(configuration: configuration)
        let restored = try await secondPipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 160, height: 90)
        )
        let diagnostics = await secondPipeline.diagnostics()
        XCTAssertEqual(restored.deliverySource, .diskCache)
        XCTAssertEqual(diagnostics.metrics.diskHitCount, 1)
        XCTAssertEqual(diagnostics.metrics.generatedCount, 0)
    }

    func testPipelineVersionInvalidatesDiskRepresentation() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("versioned.png")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 320, height: 180),
            to: source
        )
        var firstConfiguration = MediaTestFixture.configuration(directory: directory)
        firstConfiguration.pipelineVersion = 11
        let firstPipeline = try MediaPipeline(configuration: firstConfiguration)
        _ = try await firstPipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 80, height: 80)
        )

        var nextConfiguration = firstConfiguration
        nextConfiguration.pipelineVersion = 12
        let nextPipeline = try MediaPipeline(configuration: nextConfiguration)
        let regenerated = try await nextPipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 80, height: 80)
        )
        let diagnostics = await nextPipeline.diagnostics()

        XCTAssertEqual(regenerated.deliverySource, .generated)
        XCTAssertEqual(diagnostics.metrics.diskHitCount, 0)
        XCTAssertEqual(diagnostics.metrics.generatedCount, 1)
    }

    func testGeneratedH264MovieProvidesPosterDurationAndPlaybackDescriptor() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.mov")
        do {
            try await MediaTestFixture.writeMovie(to: source)
        } catch {
            throw XCTSkip("H.264 encoder is unavailable on this test host: \(error)")
        }
        let pipeline = try MediaPipeline(configuration: MediaTestFixture.configuration(directory: directory))

        let metadata = try await pipeline.metadata(for: source, priority: .interactive)
        let poster = try await pipeline.moviePoster(
            for: source,
            pixelSize: MediaPixelSize(width: 120, height: 120)
        )
        let preview = try await pipeline.preview(
            for: source,
            pixelSize: MediaPixelSize(width: 120, height: 120)
        )

        XCTAssertEqual(metadata.kind, .movie)
        XCTAssertTrue(metadata.hasVideo)
        XCTAssertTrue(metadata.isPlayable)
        XCTAssertNotNil(metadata.durationSeconds)
        XCTAssertGreaterThan(metadata.durationSeconds ?? 0, 0.5)
        XCTAssertLessThan(metadata.durationSeconds ?? 2, 1.5)
        XCTAssertEqual(metadata.pixelSize, MediaDimensions(width: 160, height: 90))
        XCTAssertTrue(metadata.codecs.contains("avc1"))
        XCTAssertEqual(poster.generationMethod, .avFoundation)
        XCTAssertLessThanOrEqual(poster.pixelSize.width, 120)
        XCTAssertLessThanOrEqual(poster.pixelSize.height, 120)
        XCTAssertNotNil(poster.actualTimeSeconds)
        XCTAssertEqual(preview.kind, .movie)
        XCTAssertNotNil(preview.playback)
        XCTAssertEqual(preview.playback?.sourceURL, source.standardizedFileURL)
    }

    func testNativeHEICUsesBoundedImageIODecodeWhenCodecIsAvailable() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.heic")
        do {
            try MediaTestFixture.writeImage(
                MediaTestFixture.image(width: 1024, height: 512),
                to: source,
                type: .heic
            )
        } catch {
            throw XCTSkip("HEIC encoder is unavailable on this test host: \(error)")
        }
        let pipeline = try MediaPipeline(configuration: MediaTestFixture.configuration(directory: directory))
        let image = try await pipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 128, height: 128)
        )

        XCTAssertEqual(image.generationMethod, .imageIO)
        XCTAssertEqual(image.pixelSize, MediaDimensions(width: 128, height: 64))
        XCTAssertLessThan(image.decodedCostBytes, 128 * 128 * 8)
    }

    func testNativeUnknownFileReturnsSafeFallbackInsteadOfCrashing() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.umis-unknown")
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: source)
        let generator = NativeMediaGenerator()
        let result = await generator.generateImage(
            for: source,
            representation: .thumbnail,
            pixelSize: MediaPixelSize(width: 64, height: 48),
            colorPolicy: .sourceManaged,
            allowGenericFallback: true
        )

        switch result {
        case let .success(image):
            XCTAssertGreaterThan(image.pixelSize.width, 0)
            XCTAssertGreaterThan(image.pixelSize.height, 0)
            XCTAssertLessThanOrEqual(image.pixelSize.width, 64)
            XCTAssertLessThanOrEqual(image.pixelSize.height, 48)
            if image.generationMethod == .genericIcon {
                XCTAssertTrue(image.isFallback)
                XCTAssertEqual(image.fallbackReason, .unsupported)
            }
        case let .failure(error):
            XCTFail("generic fallback should make unknown input safe: \(error)")
        }
    }

    func testCorruptKnownImageIsMarkedAsFallbackWithCorruptReason() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("corrupt.jpg")
        try Data([0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 3]).write(to: source)
        let pipeline = try MediaPipeline(configuration: MediaTestFixture.configuration(directory: directory))
        let image = try await pipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 64, height: 64)
        )

        XCTAssertTrue(image.isFallback)
        XCTAssertEqual(image.fallbackReason, .corrupt)
        XCTAssertGreaterThan(image.pixelSize.width, 0)
        let diagnostics = await pipeline.diagnostics()
        XCTAssertEqual(diagnostics.metrics.fallbackCount, 1)
        XCTAssertEqual(diagnostics.cache.diskEntryCount, 0)
    }

    func testSourceChangedDuringDecodeIsNotCommittedToEitherCache() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changing.bin")
        try Data(repeating: 1, count: 32).write(to: source)
        let gate = TestGate()
        let generator = CountingMediaGenerator(
            image: try MediaTestFixture.image(width: 16, height: 16),
            gate: gate
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory),
            generator: generator
        )
        let task = Task {
            try await pipeline.thumbnail(
                for: source,
                pixelSize: MediaPixelSize(width: 32, height: 32)
            )
        }
        let decodeStarted = await eventually { await generator.statistics().activeCount == 1 }
        XCTAssertTrue(decodeStarted)
        try Data(repeating: 2, count: 33).write(to: source, options: .atomic)
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("mutated source must not be committed")
        } catch let failure as MediaPipelineFailure {
            XCTAssertEqual(failure.code, .sourceChanged)
        }
        let cache = await pipeline.cacheStatistics()
        XCTAssertEqual(cache.memoryEntryCount, 0)
        XCTAssertEqual(cache.diskEntryCount, 0)
    }

    func testSuspendWaitsForRequestAdmittedBeforeCoordinatorEnqueue() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("admission-race.bin")
        try Data(repeating: 7, count: 64).write(to: source)
        let enqueueGate = TestGate()
        let generator = CountingMediaGenerator(
            image: try MediaTestFixture.image(width: 16, height: 16)
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory),
            generator: generator,
            preCoordinatorEnqueueHook: {
                await enqueueGate.wait()
            }
        )

        let request = Task {
            try await pipeline.thumbnail(
                for: source,
                pixelSize: MediaPixelSize(width: 32, height: 32)
            )
        }
        let reachedPreEnqueueGap = await eventually {
            await enqueueGate.waiterCount() == 1
        }
        XCTAssertTrue(reachedPreEnqueueGap)

        let suspensionCompleted = AsyncCompletionFlag()
        let suspension = Task {
            await pipeline.suspendAndAwaitQuiescence()
            await suspensionCompleted.markComplete()
        }
        let suspensionStarted = await eventually {
            await pipeline.isSuspendedForTesting()
        }
        XCTAssertTrue(suspensionStarted)
        let returnedWhileFacadeRequestWasBlocked = await eventually(attempts: 500) {
            await suspensionCompleted.value()
        }
        XCTAssertFalse(returnedWhileFacadeRequestWasBlocked)

        await enqueueGate.open()
        await suspension.value
        let completedAfterAdmissionDrained = await suspensionCompleted.value()
        XCTAssertTrue(completedAfterAdmissionDrained)
        _ = try? await request.value
        let statistics = await generator.statistics()
        XCTAssertEqual(statistics.activeCount, 0)

        do {
            _ = try await pipeline.thumbnail(
                for: source,
                pixelSize: MediaPixelSize(width: 32, height: 32)
            )
            XCTFail("suspended pipeline must reject new source reads")
        } catch let failure as MediaPipelineFailure {
            XCTAssertEqual(failure.code, .cancelled)
        }
        await pipeline.resumeRequests()
    }

    func testTwoHundredRequestsAreBoundedCoalescedAndThenMemoryHits() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var sources: [URL] = []
        for index in 0..<20 {
            let url = directory.appendingPathComponent("source-\(index).bin")
            try Data(repeating: UInt8(index), count: index + 16).write(to: url)
            sources.append(url)
        }
        let gate = TestGate()
        let generator = CountingMediaGenerator(
            image: try MediaTestFixture.image(width: 32, height: 24),
            gate: gate
        )
        let configuration = MediaTestFixture.configuration(
            directory: directory,
            memoryBudgetBytes: 1 * 1_024 * 1_024,
            maximumConcurrentThumbnails: 4
        )
        let pipeline = try MediaPipeline(configuration: configuration, generator: generator)
        let size = MediaPixelSize(width: 64, height: 64)
        let capturedSources = try sources.map { try MediaSourceFingerprint.capture(for: $0) }
        XCTAssertEqual(Set(capturedSources.map(\.normalizedPath)).count, 20)
        XCTAssertEqual(Set(capturedSources.map(\.byteSize)).count, 20)
        let sourceIdentities = capturedSources.map(\.cacheIdentityDigest)
        XCTAssertEqual(Set(sourceIdentities).count, 20)

        let firstPass = (0..<200).map { index in
            Task { try await pipeline.thumbnail(for: sources[index % sources.count], pixelSize: size) }
        }
        let allSubscribed = await eventually {
            let value = await pipeline.diagnostics()
            return value.thumbnails.subscriberCount == 200
        }
        XCTAssertTrue(allSubscribed)
        await gate.open()
        for task in firstPass { _ = try await task.value }

        let generatorStats = await generator.statistics()
        let firstDiagnostics = await pipeline.diagnostics()
        XCTAssertEqual(generatorStats.invocationCount, 20)
        XCTAssertLessThanOrEqual(generatorStats.maximumActiveCount, 4)
        XCTAssertEqual(firstDiagnostics.thumbnails.operationStartCount, 20)
        XCTAssertEqual(firstDiagnostics.metrics.imageRequestCount, 200)
        XCTAssertEqual(firstDiagnostics.metrics.generatedCount, 20)
        XCTAssertEqual(firstDiagnostics.cache.memoryEntryCount, 20)
        XCTAssertGreaterThan(firstDiagnostics.cache.memoryCostBytes, 0)
        XCTAssertLessThanOrEqual(firstDiagnostics.cache.memoryCostBytes, configuration.memoryBudgetBytes)

        await pipeline.resetDiagnostics()
        for index in 0..<200 {
            _ = try await pipeline.thumbnail(for: sources[index % sources.count], pixelSize: size)
        }
        let secondGeneratorStats = await generator.statistics()
        let secondDiagnostics = await pipeline.diagnostics()
        XCTAssertEqual(secondGeneratorStats.invocationCount, 20)
        XCTAssertEqual(secondDiagnostics.thumbnails.operationStartCount, 0)
        XCTAssertEqual(secondDiagnostics.metrics.imageRequestCount, 200)
        XCTAssertEqual(secondDiagnostics.metrics.memoryHitCount, 200)
        XCTAssertEqual(secondDiagnostics.metrics.generatedCount, 0)
    }

    func testInteractivePendingRequestOvertakesBackgroundPrefetch() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["active.bin", "prefetch.bin", "visible.bin"].map {
            directory.appendingPathComponent($0)
        }
        for (index, url) in urls.enumerated() {
            try Data(repeating: UInt8(index), count: 32 + index).write(to: url)
        }
        let gate = TestGate()
        let generator = CountingMediaGenerator(
            image: try MediaTestFixture.image(width: 16, height: 16),
            gate: gate
        )
        let configuration = MediaTestFixture.configuration(
            directory: directory,
            maximumConcurrentThumbnails: 1
        )
        let pipeline = try MediaPipeline(configuration: configuration, generator: generator)
        let size = MediaPixelSize(width: 32, height: 32)

        let active = Task {
            try await pipeline.thumbnail(for: urls[0], pixelSize: size, priority: .background)
        }
        let activeStarted = await eventually { await generator.statistics().activeCount == 1 }
        XCTAssertTrue(activeStarted)
        let prefetch = Task {
            try await pipeline.thumbnail(for: urls[1], pixelSize: size, priority: .background)
        }
        let visible = Task {
            try await pipeline.thumbnail(for: urls[2], pixelSize: size, priority: .interactive)
        }
        let allQueued = await eventually {
            await pipeline.diagnostics().thumbnails.subscriberCount == 3
        }
        XCTAssertTrue(allQueued)
        await gate.open()
        _ = try await active.value
        _ = try await prefetch.value
        _ = try await visible.value

        let order = await generator.statistics().startOrder
        XCTAssertEqual(order, ["active.bin", "visible.bin", "prefetch.bin"])
    }

    func testCancellationIsPerSubscriberAndLastSubscriberCancelsDecode() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 32).write(to: source)
        let generator = CancellationMediaGenerator(
            image: try MediaTestFixture.image(width: 16, height: 16)
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory),
            generator: generator
        )
        let size = MediaPixelSize(width: 32, height: 32)
        let first = Task { try await pipeline.thumbnail(for: source, pixelSize: size) }
        let second = Task { try await pipeline.thumbnail(for: source, pixelSize: size) }
        let bothSubscribed = await eventually {
            await pipeline.diagnostics().thumbnails.subscriberCount == 2
        }
        XCTAssertTrue(bothSubscribed)

        first.cancel()
        await assertCancelled(first)
        let afterFirstCancellation = await generator.statistics()
        XCTAssertEqual(afterFirstCancellation.cancellationCount, 0)

        second.cancel()
        await assertCancelled(second)
        let decodeCancelled = await eventually { await generator.statistics().cancellationCount == 1 }
        XCTAssertTrue(decodeCancelled)
        let diagnostics = await pipeline.diagnostics()
        XCTAssertEqual(diagnostics.cache.memoryEntryCount, 0)
        XCTAssertEqual(diagnostics.cache.diskEntryCount, 0)
        XCTAssertEqual(diagnostics.thumbnails.operationStartCount, 1)
    }

    func testEXIFDateTimeOriginalRespectsExplicitOffsetAndPrecedesTIFF() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:26 10:20:30",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFDateTime: "2020:01:02 03:04:05",
            ],
        ]
        let resolution = try XCTUnwrap(MediaCaptureDateExtractor.image(
            properties: properties,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        ))

        XCTAssertEqual(
            resolution.date,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T01:20:30Z"))
        )
        XCTAssertEqual(resolution.source, .imageIOExifDateTimeOriginal)
        XCTAssertNil(resolution.assumedTimeZoneIdentifier)
    }

    func testOffsetlessEXIFUsesFrozenScanTimeZone() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:26 10:20:30",
            ],
        ]
        let resolution = try XCTUnwrap(MediaCaptureDateExtractor.image(
            properties: properties,
            assumedTimeZone: tokyo
        ))

        XCTAssertEqual(
            resolution.date,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T01:20:30Z"))
        )
        XCTAssertEqual(resolution.source, .imageIOExifDateTimeOriginal)
        XCTAssertEqual(resolution.assumedTimeZoneIdentifier, "Asia/Tokyo")
    }

    func testMalformedEXIFOffsetFallsBackToValidTIFFWallClock() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:26 10:20:30",
                kCGImagePropertyExifOffsetTimeOriginal: "+99:99",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFDateTime: "2025:02:03 04:05:06",
            ],
        ]
        let resolution = try XCTUnwrap(MediaCaptureDateExtractor.image(
            properties: properties,
            assumedTimeZone: utc
        ))

        XCTAssertEqual(
            resolution.date,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-03T04:05:06Z"))
        )
        XCTAssertEqual(resolution.source, .imageIOTIFFDateTime)
        XCTAssertEqual(resolution.assumedTimeZoneIdentifier, "GMT")
    }

    func testQuickTimeStringUsesOffsetOrFrozenTimeZoneDeterministically() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let absolute = try XCTUnwrap(MediaCaptureDateExtractor.quickTime(
            dateValue: nil,
            stringValue: "2026-08-26T10:20:30-07:00",
            assumedTimeZone: tokyo
        ))
        XCTAssertEqual(
            absolute.date,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T17:20:30Z"))
        )
        XCTAssertNil(absolute.assumedTimeZoneIdentifier)

        let wallClock = try XCTUnwrap(MediaCaptureDateExtractor.quickTime(
            dateValue: try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2001-01-01T00:00:00Z")
            ),
            stringValue: "2026-08-26T10:20:30.125",
            assumedTimeZone: tokyo
        ))
        XCTAssertEqual(
            wallClock.date,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T01:20:30Z"))
        )
        XCTAssertEqual(wallClock.assumedTimeZoneIdentifier, "Asia/Tokyo")
    }

    func testNativeImageMetadataUsesEXIFAndFallsBackToModificationDate() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let embeddedSource = directory.appendingPathComponent("capture.jpg")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 32, height: 24),
            to: embeddedSource,
            type: .jpeg,
            exifDateTimeOriginal: "2026:08:26 10:20:30",
            exifOffsetTimeOriginal: "+09:00"
        )
        let fallbackSource = directory.appendingPathComponent("fallback.png")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 32, height: 24),
            to: fallbackSource
        )
        let expectedModificationDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2024-03-04T05:06:07Z")
        )
        try FileManager.default.setAttributes(
            [.modificationDate: expectedModificationDate],
            ofItemAtPath: fallbackSource.path
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory)
        )
        let embedded = try await pipeline.metadata(
            for: embeddedSource,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        let fallback = try await pipeline.metadata(
            for: fallbackSource,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        )

        XCTAssertEqual(
            embedded.captureDate,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T01:20:30Z"))
        )
        XCTAssertEqual(embedded.captureDateSource, .imageIOExifDateTimeOriginal)
        XCTAssertNil(embedded.captureDateAssumedTimeZoneIdentifier)
        XCTAssertEqual(fallback.captureDateSource, .fileModificationDate)
        XCTAssertEqual(
            try XCTUnwrap(fallback.captureDate).timeIntervalSince1970,
            expectedModificationDate.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testOffsetlessMetadataCacheIsPartitionedByFrozenTimeZone() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("wall-clock.jpg")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 32, height: 24),
            to: source,
            type: .jpeg,
            exifDateTimeOriginal: "2026:08:26 10:20:30"
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory)
        )
        let utc = try await pipeline.metadata(
            for: source,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        let tokyo = try await pipeline.metadata(
            for: source,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        )

        XCTAssertEqual(
            try XCTUnwrap(utc.captureDate).timeIntervalSince1970
                - (try XCTUnwrap(tokyo.captureDate).timeIntervalSince1970),
            9 * 60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(utc.captureDateAssumedTimeZoneIdentifier, "GMT")
        XCTAssertEqual(tokyo.captureDateAssumedTimeZoneIdentifier, "Asia/Tokyo")
        let diagnostics = await pipeline.diagnostics()
        XCTAssertEqual(diagnostics.metadata.operationStartCount, 2)
    }

    func testGeneratedMovieExposesQuickTimeCreationDate() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("dated.mov")
        do {
            try await MediaTestFixture.writeMovie(
                to: source,
                creationDate: "2026-08-26T10:20:30+09:00"
            )
        } catch {
            throw XCTSkip("H.264/QuickTime metadata writer is unavailable on this test host: \(error)")
        }
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory)
        )
        let metadata = try await pipeline.metadata(
            for: source,
            assumedTimeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )

        XCTAssertEqual(metadata.captureDateSource, .quickTimeCreationDate)
        XCTAssertEqual(
            metadata.captureDate,
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T01:20:30Z"))
        )
        XCTAssertNil(metadata.captureDateAssumedTimeZoneIdentifier)
    }

    func testMetadataBatchKeepsTaskAndNativeWorkConcurrencyBounded() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<24).map { index -> URL in
            let url = directory.appendingPathComponent("metadata-\(index).bin")
            try Data(repeating: UInt8(index), count: index + 1).write(to: url)
            return url
        }
        let gate = TestGate()
        let generator = CountingMetadataGenerator(
            image: try MediaTestFixture.image(width: 8, height: 8),
            gate: gate
        )
        var configuration = MediaTestFixture.configuration(directory: directory)
        configuration.maximumConcurrentMetadata = 3
        let pipeline = try MediaPipeline(configuration: configuration, generator: generator)
        let task = Task {
            await pipeline.metadataBatch(
                for: urls,
                priority: .background,
                assumedTimeZone: .gmt
            )
        }
        await generator.waitUntilInvocationCount(3)
        let blockedStatistics = await generator.statistics()
        XCTAssertEqual(blockedStatistics.activeCount, 3)
        XCTAssertEqual(blockedStatistics.maximumActiveCount, 3)
        await gate.open()
        let results = await task.value

        XCTAssertEqual(results.count, urls.count)
        XCTAssertTrue(results.allSatisfy {
            if case .success = $0 { return true }
            return false
        })
        let statistics = await generator.statistics()
        XCTAssertEqual(statistics.invocationCount, urls.count)
        XCTAssertLessThanOrEqual(statistics.maximumActiveCount, 3)
        let diagnostics = await pipeline.diagnostics()
        XCTAssertEqual(diagnostics.metadata.operationStartCount, urls.count)
    }

    func testSourceChangedDuringMetadataExtractionIsNotCached() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changing-metadata.bin")
        try Data(repeating: 1, count: 16).write(to: source)
        let gate = TestGate()
        let generator = CountingMetadataGenerator(
            image: try MediaTestFixture.image(width: 8, height: 8),
            gate: gate
        )
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(directory: directory),
            generator: generator
        )
        let first = Task {
            try await pipeline.metadata(for: source, assumedTimeZone: .gmt)
        }
        await generator.waitUntilInvocationCount(1)
        let startedStatistics = await generator.statistics()
        XCTAssertEqual(startedStatistics.activeCount, 1)
        try Data(repeating: 2, count: 17).write(to: source, options: .atomic)
        await gate.open()

        do {
            _ = try await first.value
            XCTFail("metadata from a changed source must not be cached")
        } catch let failure as MediaPipelineFailure {
            XCTAssertEqual(failure.code, .sourceChanged)
        }
        _ = try await pipeline.metadata(for: source, assumedTimeZone: .gmt)
        let statistics = await generator.statistics()
        XCTAssertEqual(statistics.invocationCount, 2)
        let diagnostics = await pipeline.diagnostics()
        XCTAssertEqual(diagnostics.metadata.operationStartCount, 2)
    }

    func testUnsupportedInputFailsWithStableTypedError() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("unknown.zzz")
        try Data([0, 1, 2, 3]).write(to: source)
        let pipeline = try MediaPipeline(
            configuration: MediaTestFixture.configuration(
                directory: directory,
                allowGenericFallback: false
            ),
            generator: UnsupportedMediaGenerator()
        )

        do {
            _ = try await pipeline.thumbnail(
                for: source,
                pixelSize: MediaPixelSize(width: 64, height: 64)
            )
            XCTFail("unsupported generator must fail")
        } catch let failure as MediaPipelineFailure {
            XCTAssertEqual(failure.code, .unsupported)
            XCTAssertFalse(failure.localizedDescription.isEmpty)
        } catch {
            XCTFail("unexpected error type: \(type(of: error))")
        }
    }

    private func eventually(
        attempts: Int = 20_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func assertCancelled(_ task: Task<MediaImage, any Error>) async {
        do {
            _ = try await task.value
            XCTFail("task should be cancelled")
        } catch let failure as MediaPipelineFailure {
            XCTAssertEqual(failure.code, .cancelled)
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
