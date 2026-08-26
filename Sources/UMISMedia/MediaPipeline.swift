import Foundation

public struct MediaQueueDiagnostics: Hashable, Codable, Sendable {
    public let pendingCount: Int
    public let runningCount: Int
    public let subscriberCount: Int
    public let operationStartCount: Int

    public init(
        pendingCount: Int,
        runningCount: Int,
        subscriberCount: Int,
        operationStartCount: Int
    ) {
        self.pendingCount = pendingCount
        self.runningCount = runningCount
        self.subscriberCount = subscriberCount
        self.operationStartCount = operationStartCount
    }
}

public struct MediaPipelineMetrics: Hashable, Codable, Sendable {
    public let imageRequestCount: Int
    public let memoryHitCount: Int
    public let diskHitCount: Int
    public let generatedCount: Int
    public let fallbackCount: Int
    public let failureCount: Int

    public init(
        imageRequestCount: Int,
        memoryHitCount: Int,
        diskHitCount: Int,
        generatedCount: Int,
        fallbackCount: Int,
        failureCount: Int
    ) {
        self.imageRequestCount = imageRequestCount
        self.memoryHitCount = memoryHitCount
        self.diskHitCount = diskHitCount
        self.generatedCount = generatedCount
        self.fallbackCount = fallbackCount
        self.failureCount = failureCount
    }
}

public struct MediaPipelineDiagnostics: Hashable, Codable, Sendable {
    public let cache: MediaCacheStatistics
    public let metrics: MediaPipelineMetrics
    public let thumbnails: MediaQueueDiagnostics
    public let previews: MediaQueueDiagnostics
    public let metadata: MediaQueueDiagnostics

    public init(
        cache: MediaCacheStatistics,
        metrics: MediaPipelineMetrics,
        thumbnails: MediaQueueDiagnostics,
        previews: MediaQueueDiagnostics,
        metadata: MediaQueueDiagnostics
    ) {
        self.cache = cache
        self.metrics = metrics
        self.thumbnails = thumbnails
        self.previews = previews
        self.metadata = metadata
    }
}

public enum MediaMemoryPressureLevel: String, Codable, Sendable {
    case warning
    case critical
}

/// macOS-native media facade intended for `NSCollectionView` visible/prefetch tasks.
///
/// Each cell owns the Task returned by its call site and cancels that Task when reused.
/// Identical requests are coalesced, while cancellation removes only that subscriber;
/// the shared decode is cancelled when its final subscriber disappears.
public actor MediaPipeline {
    public nonisolated let configuration: MediaPipelineConfiguration

    private let generator: any MediaGenerating
    private let memoryCache: MediaMemoryCache
    private let diskCache: MediaDiskCache
    private let metadataCache: MediaMetadataMemoryCache
    private let metrics: MediaMetricsStore
    private let thumbnailCoordinator: MediaWorkCoordinator<MediaRequestKey, MediaImage>
    private let previewCoordinator: MediaWorkCoordinator<MediaRequestKey, MediaImage>
    private let metadataCoordinator: MediaWorkCoordinator<String, MediaMetadata>
    private let preCoordinatorEnqueueHook: (@Sendable () async -> Void)?
    private var memoryPressureMonitor: MediaMemoryPressureMonitor?
    private var requestsSuspended = false
    private var admittedSourceReadCount = 0
    private var admissionDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: MediaPipelineConfiguration = .standard()) throws {
        self.configuration = configuration
        generator = NativeMediaGenerator()
        memoryCache = MediaMemoryCache(budgetBytes: configuration.memoryBudgetBytes)
        diskCache = try MediaDiskCache(configuration: configuration)
        metadataCache = MediaMetadataMemoryCache(capacity: 512)
        metrics = MediaMetricsStore()
        thumbnailCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentThumbnails
        )
        previewCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentPreviews
        )
        metadataCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentMetadata
        )
        preCoordinatorEnqueueHook = nil
        memoryPressureMonitor = nil
        memoryPressureMonitor = MediaMemoryPressureMonitor {
            [memoryCache, metadataCache, budget = configuration.memoryBudgetBytes] level in
            Task {
                switch level {
                case .warning:
                    await memoryCache.trim(to: budget / 2)
                case .critical:
                    await memoryCache.removeAll()
                    await metadataCache.removeAll()
                }
            }
        }
    }

    init(
        configuration: MediaPipelineConfiguration,
        generator: any MediaGenerating,
        preCoordinatorEnqueueHook: (@Sendable () async -> Void)? = nil
    ) throws {
        self.configuration = configuration
        self.generator = generator
        memoryCache = MediaMemoryCache(budgetBytes: configuration.memoryBudgetBytes)
        diskCache = try MediaDiskCache(configuration: configuration)
        metadataCache = MediaMetadataMemoryCache(capacity: 512)
        metrics = MediaMetricsStore()
        thumbnailCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentThumbnails
        )
        previewCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentPreviews
        )
        metadataCoordinator = MediaWorkCoordinator(
            maximumConcurrency: configuration.maximumConcurrentMetadata
        )
        self.preCoordinatorEnqueueHook = preCoordinatorEnqueueHook
        memoryPressureMonitor = nil
        memoryPressureMonitor = MediaMemoryPressureMonitor {
            [memoryCache, metadataCache, budget = configuration.memoryBudgetBytes] level in
            Task {
                switch level {
                case .warning:
                    await memoryCache.trim(to: budget / 2)
                case .critical:
                    await memoryCache.removeAll()
                    await metadataCache.removeAll()
                }
            }
        }
    }

    /// Simple collection-view entry point: URL + target pixels + scheduling priority.
    public func thumbnail(
        for url: URL,
        pixelSize: MediaPixelSize,
        priority: MediaRequestPriority = .visible,
        colorPolicy: MediaColorPolicy = .sourceManaged
    ) async throws -> MediaImage {
        try acquireSourceReadAdmission()
        defer { releaseSourceReadAdmission() }
        return try await requestImage(
            for: url,
            representation: .thumbnail,
            pixelSize: pixelSize,
            priority: priority,
            colorPolicy: colorPolicy,
            cacheKind: .thumbnail
        )
    }

    public func moviePoster(
        for url: URL,
        pixelSize: MediaPixelSize,
        priority: MediaRequestPriority = .interactive,
        colorPolicy: MediaColorPolicy = .sourceManaged
    ) async throws -> MediaImage {
        try acquireSourceReadAdmission()
        defer { releaseSourceReadAdmission() }
        return try await requestImage(
            for: url,
            representation: .moviePoster,
            pixelSize: pixelSize,
            priority: priority,
            colorPolicy: colorPolicy,
            cacheKind: .poster
        )
    }

    public func preview(
        for url: URL,
        pixelSize: MediaPixelSize,
        priority: MediaRequestPriority = .interactive,
        colorPolicy: MediaColorPolicy = .sourceManaged
    ) async throws -> MediaPreview {
        try acquireSourceReadAdmission()
        defer { releaseSourceReadAdmission() }
        async let metadataValue = metadata(for: url, priority: priority)
        async let imageValue = requestImage(
            for: url,
            representation: .preview,
            pixelSize: pixelSize,
            priority: priority,
            colorPolicy: colorPolicy,
            cacheKind: .preview
        )
        let (metadata, image) = try await (metadataValue, imageValue)
        let playback = metadata.kind == .movie || metadata.kind == .audio
            ? MediaPlaybackDescriptor(sourceURL: url.standardizedFileURL, metadata: metadata)
            : nil
        return MediaPreview(
            sourceURL: url.standardizedFileURL,
            kind: metadata.kind,
            image: image,
            metadata: metadata,
            playback: playback
        )
    }

    public func metadata(
        for url: URL,
        priority: MediaRequestPriority = .background,
        assumedTimeZone: TimeZone = .current
    ) async throws -> MediaMetadata {
        try acquireSourceReadAdmission()
        defer { releaseSourceReadAdmission() }
        if Task.isCancelled { throw MediaPipelineFailure(.cancelled) }
        let fingerprint = try MediaSourceFingerprint.capture(for: url)
        if let preCoordinatorEnqueueHook {
            await preCoordinatorEnqueueHook()
        }
        let key = StableDigest.sha256([
            "metadata",
            fingerprint.cacheIdentityDigest,
            String(configuration.pipelineVersion),
            assumedTimeZone.identifier,
        ])
        if let cached = await metadataCache.value(for: key) {
            guard !Task.isCancelled else { throw MediaPipelineFailure(.cancelled) }
            return cached
        }

        let generator = self.generator
        let metadataCache = self.metadataCache
        return try await metadataCoordinator.request(key: key, priority: priority) {
            let result = await generator.metadata(
                for: url,
                assumedTimeZone: assumedTimeZone
            )
            guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
            switch result {
            case let .success(value):
                do {
                    let current = try MediaSourceFingerprint.capture(for: url)
                    guard fingerprint.representsSameSource(as: current) else {
                        return .failure(.init(.sourceChanged))
                    }
                } catch {
                    return .failure(MediaPipelineFailure.classify(error))
                }
                await metadataCache.insert(value, for: key)
                return .success(value)
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    /// Resolves metadata for a scan without creating one task per source file.
    /// At most `maximumConcurrentMetadata` child tasks are live, and all native
    /// extraction still passes through the coalescing metadata coordinator.
    public func metadataBatch(
        for urls: [URL],
        priority: MediaRequestPriority = .background,
        assumedTimeZone: TimeZone = .current
    ) async -> [Result<MediaMetadata, MediaPipelineFailure>] {
        guard !urls.isEmpty else { return [] }
        guard acquireSourceReadAdmissionIfAvailable() else {
            return Array(repeating: .failure(.init(.cancelled)), count: urls.count)
        }
        defer { releaseSourceReadAdmission() }
        guard !Task.isCancelled else {
            return Array(repeating: .failure(.init(.cancelled)), count: urls.count)
        }

        var results = Array<Result<MediaMetadata, MediaPipelineFailure>?>(
            repeating: nil,
            count: urls.count
        )
        let maximumInFlight = min(urls.count, configuration.maximumConcurrentMetadata)
        let pipeline = self
        await withTaskGroup(of: (Int, Result<MediaMetadata, MediaPipelineFailure>).self) { group in
            var nextIndex = 0

            func submit(_ index: Int) {
                let url = urls[index]
                group.addTask {
                    do {
                        let value = try await pipeline.metadata(
                            for: url,
                            priority: priority,
                            assumedTimeZone: assumedTimeZone
                        )
                        return (index, .success(value))
                    } catch {
                        return (
                            index,
                            .failure(MediaPipelineFailure.classify(error))
                        )
                    }
                }
            }

            while nextIndex < maximumInFlight {
                submit(nextIndex)
                nextIndex += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if nextIndex < urls.count, !Task.isCancelled {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return results.map { $0 ?? .failure(.init(.cancelled)) }
    }

    /// Cancels pending/running shared work. Normal cell reuse should cancel the caller's
    /// Task instead, preserving work still needed by another visible subscriber.
    public func cancelAll() async {
        await thumbnailCoordinator.cancelAll()
        await previewCoordinator.cancelAll()
        await metadataCoordinator.cancelAll()
    }

    /// Prevents new source reads, cancels all queued work and awaits termination
    /// of work already inside ImageIO, Quick Look or AVFoundation adapters.
    public func suspendAndAwaitQuiescence() async {
        requestsSuspended = true
        async let thumbnails: Void = thumbnailCoordinator.cancelAllAndWait()
        async let previews: Void = previewCoordinator.cancelAllAndWait()
        async let metadata: Void = metadataCoordinator.cancelAllAndWait()
        _ = await (thumbnails, previews, metadata)
        await waitForSourceReadAdmissionsToDrain()
        // A request admitted before suspension can cross its fingerprint/cache awaits and
        // enqueue after the first coordinator snapshot. Draining admissions proves that no
        // such facade request remains; the second pass then proves every coordinator is empty.
        async let finalThumbnails: Void = thumbnailCoordinator.cancelAllAndWait()
        async let finalPreviews: Void = previewCoordinator.cancelAllAndWait()
        async let finalMetadata: Void = metadataCoordinator.cancelAllAndWait()
        _ = await (finalThumbnails, finalPreviews, finalMetadata)
    }

    public func resumeRequests() {
        requestsSuspended = false
    }

    func isSuspendedForTesting() -> Bool {
        requestsSuspended
    }

    private func acquireSourceReadAdmission() throws {
        guard acquireSourceReadAdmissionIfAvailable() else {
            throw MediaPipelineFailure(.cancelled)
        }
    }

    private func acquireSourceReadAdmissionIfAvailable() -> Bool {
        guard !requestsSuspended else { return false }
        admittedSourceReadCount += 1
        return true
    }

    private func releaseSourceReadAdmission() {
        precondition(admittedSourceReadCount > 0)
        admittedSourceReadCount -= 1
        guard admittedSourceReadCount == 0, !admissionDrainWaiters.isEmpty else { return }
        let waiters = admissionDrainWaiters
        admissionDrainWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForSourceReadAdmissionsToDrain() async {
        guard admittedSourceReadCount > 0 else { return }
        await withCheckedContinuation { continuation in
            admissionDrainWaiters.append(continuation)
        }
    }

    public func clearCaches() async throws {
        await cancelAll()
        await memoryCache.removeAll()
        await metadataCache.removeAll()
        try await diskCache.removeAll()
    }

    public func trimMemory(to byteCount: Int) async {
        await memoryCache.trim(to: max(0, byteCount))
    }

    public func handleMemoryPressure(_ level: MediaMemoryPressureLevel) async {
        switch level {
        case .warning:
            await memoryCache.trim(to: configuration.memoryBudgetBytes / 2)
        case .critical:
            await memoryCache.removeAll()
            await metadataCache.removeAll()
        }
    }

    public func cacheStatistics() async -> MediaCacheStatistics {
        let memory = await memoryCache.statistics()
        let disk = await diskCache.statistics()
        return MediaCacheStatistics(
            memoryEntryCount: memory.entryCount,
            memoryCostBytes: memory.costBytes,
            diskEntryCount: disk.entryCount,
            diskCostBytes: disk.costBytes
        )
    }

    /// Stable counters for performance tests and Instruments signpost correlation. No
    /// wall-clock threshold is embedded, so slow CI machines do not cause false failures.
    public func diagnostics() async -> MediaPipelineDiagnostics {
        let cache = await cacheStatistics()
        let metricValues = await metrics.snapshot()
        let thumbnails = await thumbnailCoordinator.snapshot()
        let previews = await previewCoordinator.snapshot()
        let metadata = await metadataCoordinator.snapshot()
        return MediaPipelineDiagnostics(
            cache: cache,
            metrics: metricValues,
            thumbnails: Self.diagnostics(thumbnails),
            previews: Self.diagnostics(previews),
            metadata: Self.diagnostics(metadata)
        )
    }

    public func resetDiagnostics() async {
        await metrics.reset()
        await thumbnailCoordinator.resetStatistics()
        await previewCoordinator.resetStatistics()
        await metadataCoordinator.resetStatistics()
    }

    private func requestImage(
        for url: URL,
        representation: MediaRepresentationKind,
        pixelSize: MediaPixelSize,
        priority: MediaRequestPriority,
        colorPolicy: MediaColorPolicy,
        cacheKind: MediaCacheKind
    ) async throws -> MediaImage {
        if Task.isCancelled { throw MediaPipelineFailure(.cancelled) }
        let fingerprint = try MediaSourceFingerprint.capture(for: url)
        if let preCoordinatorEnqueueHook {
            await preCoordinatorEnqueueHook()
        }
        let key = MediaRequestKey(
            fingerprint: fingerprint,
            representation: representation,
            pixelSize: pixelSize,
            colorPolicy: colorPolicy,
            pipelineVersion: configuration.pipelineVersion
        )
        let identifier = key.stableIdentifier
        await metrics.recordRequest()
        if let cached = await memoryCache.image(for: identifier) {
            guard !Task.isCancelled else { throw MediaPipelineFailure(.cancelled) }
            await metrics.recordMemoryHit()
            guard !Task.isCancelled else { throw MediaPipelineFailure(.cancelled) }
            return cached
        }

        let generator = self.generator
        let memoryCache = self.memoryCache
        let diskCache = self.diskCache
        let metrics = self.metrics
        let allowGenericFallback = configuration.allowGenericFallback
        let coordinator = representation == .thumbnail ? thumbnailCoordinator : previewCoordinator

        return try await coordinator.request(key: key, priority: priority) {
            if Task.isCancelled { return .failure(.init(.cancelled)) }
            if let descriptor = await diskCache.imageDescriptor(for: key, kind: cacheKind) {
                if let cached = MediaDiskCache.decode(descriptor) {
                    guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                    await memoryCache.insert(cached, for: identifier)
                    guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                    await metrics.recordDiskHit()
                    guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                    return .success(cached)
                }
                await diskCache.invalidate(identifier: descriptor.identifier)
            }

            let generated = await generator.generateImage(
                for: url,
                representation: representation,
                pixelSize: pixelSize,
                colorPolicy: colorPolicy,
                allowGenericFallback: allowGenericFallback
            )
            guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
            switch generated {
            case let .failure(error):
                await metrics.recordFailure()
                return .failure(error)
            case let .success(image):
                do {
                    let current = try MediaSourceFingerprint.capture(for: url)
                    guard fingerprint.representsSameSource(as: current) else {
                        await metrics.recordFailure()
                        return .failure(.init(.sourceChanged))
                    }
                } catch {
                    await metrics.recordFailure()
                    return .failure(MediaPipelineFailure.classify(error))
                }
                guard !Task.isCancelled else { return .failure(.init(.cancelled)) }

                if !image.isFallback {
                    do {
                        let encoded = try MediaDiskCache.encode(image)
                        guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                        try await diskCache.store(encoded, for: key, kind: cacheKind)
                    } catch let failure as MediaPipelineFailure where failure.code == .cancelled {
                        return .failure(failure)
                    } catch {
                        // A derived cache is expendable. Serving the valid generated image
                        // is safer than turning a full-disk condition into a media failure.
                    }
                }
                guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                await memoryCache.insert(image, for: identifier)
                guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                await metrics.recordGenerated(fallback: image.isFallback)
                guard !Task.isCancelled else { return .failure(.init(.cancelled)) }
                return .success(image)
            }
        }
    }

    private nonisolated static func diagnostics(
        _ snapshot: MediaWorkCoordinator<MediaRequestKey, MediaImage>.Snapshot
    ) -> MediaQueueDiagnostics {
        MediaQueueDiagnostics(
            pendingCount: snapshot.pendingCount,
            runningCount: snapshot.runningCount,
            subscriberCount: snapshot.subscriberCount,
            operationStartCount: snapshot.operationStartCount
        )
    }

    private nonisolated static func diagnostics(
        _ snapshot: MediaWorkCoordinator<String, MediaMetadata>.Snapshot
    ) -> MediaQueueDiagnostics {
        MediaQueueDiagnostics(
            pendingCount: snapshot.pendingCount,
            runningCount: snapshot.runningCount,
            subscriberCount: snapshot.subscriberCount,
            operationStartCount: snapshot.operationStartCount
        )
    }
}

private actor MediaMetricsStore {
    private var imageRequestCount = 0
    private var memoryHitCount = 0
    private var diskHitCount = 0
    private var generatedCount = 0
    private var fallbackCount = 0
    private var failureCount = 0

    func recordRequest() { imageRequestCount += 1 }
    func recordMemoryHit() { memoryHitCount += 1 }
    func recordDiskHit() { diskHitCount += 1 }
    func recordGenerated(fallback: Bool) {
        generatedCount += 1
        if fallback { fallbackCount += 1 }
    }
    func recordFailure() { failureCount += 1 }

    func snapshot() -> MediaPipelineMetrics {
        MediaPipelineMetrics(
            imageRequestCount: imageRequestCount,
            memoryHitCount: memoryHitCount,
            diskHitCount: diskHitCount,
            generatedCount: generatedCount,
            fallbackCount: fallbackCount,
            failureCount: failureCount
        )
    }

    func reset() {
        imageRequestCount = 0
        memoryHitCount = 0
        diskHitCount = 0
        generatedCount = 0
        fallbackCount = 0
        failureCount = 0
    }
}

private actor MediaMetadataMemoryCache {
    private let capacity: Int
    private var values: [String: MediaMetadata] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(for key: String) -> MediaMetadata? {
        guard let value = values[key] else { return nil }
        order.removeAll(where: { $0 == key })
        order.append(key)
        return value
    }

    func insert(_ value: MediaMetadata, for key: String) {
        guard !Task.isCancelled else { return }
        values[key] = value
        order.removeAll(where: { $0 == key })
        order.append(key)
        while values.count > capacity, let victim = order.first {
            order.removeFirst()
            values.removeValue(forKey: victim)
        }
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
}
