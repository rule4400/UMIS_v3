import Foundation
import XCTest
@testable import UMISMedia

@MainActor
final class MediaCacheTests: XCTestCase {
    func testDiskQuotaUsesDeterministicLRUAndHonorsRecentAccess() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = MediaPipelineConfiguration(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            memoryBudgetBytes: 1_024,
            diskHardLimitBytes: 100,
            maximumConcurrentThumbnails: 1,
            maximumConcurrentPreviews: 1,
            maximumConcurrentMetadata: 1,
            pipelineVersion: 1
        )
        let cache = try MediaDiskCache(configuration: configuration)
        try await cache.storeDataForTesting(Data(repeating: 1, count: 40), identifier: "a", kind: .thumbnail)
        try await cache.storeDataForTesting(Data(repeating: 2, count: 40), identifier: "b", kind: .thumbnail)
        await cache.touchForTesting(identifier: "a")
        try await cache.storeDataForTesting(Data(repeating: 3, count: 40), identifier: "c", kind: .thumbnail)
        let containsA = await cache.contains(identifier: "a")
        let containsB = await cache.contains(identifier: "b")
        let containsC = await cache.contains(identifier: "c")
        let statistics = await cache.statistics()

        XCTAssertTrue(containsA)
        XCTAssertFalse(containsB)
        XCTAssertTrue(containsC)
        XCTAssertEqual(statistics.entryCount, 2)
        XCTAssertEqual(statistics.costBytes, 80)
        XCTAssertLessThanOrEqual(statistics.costBytes, configuration.diskHardLimitBytes)
    }

    func testSQLiteIndexPersistsLRUAcrossRecreationWithoutJSONManifest() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = MediaPipelineConfiguration(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            memoryBudgetBytes: 1_024,
            diskHardLimitBytes: 100,
            maximumConcurrentThumbnails: 1,
            maximumConcurrentPreviews: 1,
            maximumConcurrentMetadata: 1,
            pipelineVersion: 1
        )
        do {
            let cache = try MediaDiskCache(configuration: configuration)
            try await cache.storeDataForTesting(
                Data(repeating: 1, count: 40),
                identifier: "a",
                kind: .thumbnail
            )
            try await cache.storeDataForTesting(
                Data(repeating: 2, count: 40),
                identifier: "b",
                kind: .thumbnail
            )
            await cache.touchForTesting(identifier: "a")
            try await cache.flush()
        }

        let sqliteIndex = configuration.cacheDirectory.appendingPathComponent("index.sqlite3")
        let legacyJSON = configuration.cacheDirectory.appendingPathComponent("index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteIndex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyJSON.path))

        let restored = try MediaDiskCache(configuration: configuration)
        try await restored.storeDataForTesting(
            Data(repeating: 3, count: 40),
            identifier: "c",
            kind: .thumbnail
        )
        let containsA = await restored.contains(identifier: "a")
        let containsB = await restored.contains(identifier: "b")
        let containsC = await restored.contains(identifier: "c")
        XCTAssertTrue(containsA)
        XCTAssertFalse(containsB)
        XCTAssertTrue(containsC)
    }

    func testCorruptSQLiteIndexIsQuarantinedAndRebuilt() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = MediaPipelineConfiguration(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            memoryBudgetBytes: 1_024,
            diskHardLimitBytes: 1_024,
            pipelineVersion: 1
        )
        try FileManager.default.createDirectory(
            at: configuration.cacheDirectory,
            withIntermediateDirectories: true
        )
        let sqliteIndex = configuration.cacheDirectory.appendingPathComponent("index.sqlite3")
        try Data("not a sqlite database".utf8).write(to: sqliteIndex)

        let cache = try MediaDiskCache(configuration: configuration)
        try await cache.storeDataForTesting(
            Data(repeating: 1, count: 16),
            identifier: "usable-after-rebuild",
            kind: .thumbnail
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: configuration.cacheDirectory.path
        )
        let containsEntry = await cache.contains(identifier: "usable-after-rebuild")
        XCTAssertTrue(containsEntry)
        XCTAssertTrue(names.contains("index.sqlite3"))
        XCTAssertTrue(names.contains { $0.hasPrefix("index.corrupt.") })
    }

    func testMemoryCacheTracksDecodedCostAndEvictsLeastRecentlyUsed() async throws {
        let first = MediaImage(
            cgImage: try MediaTestFixture.image(width: 16, height: 16, seed: 1),
            generationMethod: .imageIO
        )
        let second = MediaImage(
            cgImage: try MediaTestFixture.image(width: 16, height: 16, seed: 2),
            generationMethod: .imageIO
        )
        let third = MediaImage(
            cgImage: try MediaTestFixture.image(width: 16, height: 16, seed: 3),
            generationMethod: .imageIO
        )
        let budget = first.decodedCostBytes + second.decodedCostBytes
        let cache = MediaMemoryCache(budgetBytes: budget)
        await cache.insert(first, for: "a")
        await cache.insert(second, for: "b")
        _ = await cache.image(for: "a")
        await cache.insert(third, for: "c")
        let a = await cache.image(for: "a")
        let b = await cache.image(for: "b")
        let c = await cache.image(for: "c")
        let statistics = await cache.statistics()

        XCTAssertNotNil(a)
        XCTAssertNil(b)
        XCTAssertNotNil(c)
        XCTAssertEqual(statistics.entryCount, 2)
        XCTAssertLessThanOrEqual(statistics.costBytes, budget)
        XCTAssertEqual(statistics.costBytes, first.decodedCostBytes + third.decodedCostBytes)
    }

    func testStartupRemovesHiddenPartialAndOrphanFiles() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = MediaPipelineConfiguration(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            memoryBudgetBytes: 1_024,
            diskHardLimitBytes: 1_024,
            pipelineVersion: 1
        )
        _ = try MediaDiskCache(configuration: configuration)
        let thumbnailDirectory = configuration.cacheDirectory
            .appendingPathComponent(MediaCacheKind.thumbnail.rawValue, isDirectory: true)
        let partial = thumbnailDirectory.appendingPathComponent(".fixture.partial.abandoned")
        let orphan = thumbnailDirectory.appendingPathComponent("orphan.png")
        try Data([1]).write(to: partial)
        try Data([2]).write(to: orphan)

        _ = try MediaDiskCache(configuration: configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCriticalMemoryPressurePurgesDecodedImagesButKeepsRebuildableDiskEntry() async throws {
        let directory = try MediaTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pressure.png")
        try MediaTestFixture.writeImage(
            MediaTestFixture.image(width: 128, height: 64),
            to: source
        )
        let pipeline = try MediaPipeline(configuration: MediaTestFixture.configuration(directory: directory))
        _ = try await pipeline.thumbnail(
            for: source,
            pixelSize: MediaPixelSize(width: 64, height: 64)
        )
        let before = await pipeline.cacheStatistics()
        XCTAssertEqual(before.memoryEntryCount, 1)
        XCTAssertEqual(before.diskEntryCount, 1)

        await pipeline.handleMemoryPressure(.critical)
        let after = await pipeline.cacheStatistics()
        XCTAssertEqual(after.memoryEntryCount, 0)
        XCTAssertEqual(after.memoryCostBytes, 0)
        XCTAssertEqual(after.diskEntryCount, 1)
    }
}
