import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor MediaDiskCache {
    struct Statistics: Sendable, Equatable {
        let entryCount: Int
        let costBytes: Int64
    }

    struct ImageDescriptor: Sendable {
        let identifier: String
        let fileURL: URL
        let byteSize: Int64
        let generationMethod: MediaGenerationMethod
        let isFallback: Bool
        let fallbackReason: MediaFailureCode?
        let requestedTimeSeconds: Double?
        let actualTimeSeconds: Double?
    }

    struct EncodedImage: Sendable {
        let data: Data
        let generationMethod: MediaGenerationMethod
        let isFallback: Bool
        let fallbackReason: MediaFailureCode?
        let requestedTimeSeconds: Double?
        let actualTimeSeconds: Double?
    }

    private struct Entry: Sendable {
        let key: String
        let kind: MediaCacheKind
        let filename: String
        let byteSize: Int64
        let createdAt: Date
        var lastAccessAt: Date
        var lastAccessSequence: UInt64
        let fingerprintDigest: String
        let pipelineVersion: Int
        let generationMethod: MediaGenerationMethod
        let isFallback: Bool
        let fallbackReason: MediaFailureCode?
        let requestedTimeSeconds: Double?
        let actualTimeSeconds: Double?

        init(record: MediaCacheIndexRecord) {
            key = record.key
            kind = record.kind
            filename = record.filename
            byteSize = record.byteSize
            createdAt = record.createdAt
            lastAccessAt = record.lastAccessAt
            lastAccessSequence = record.lastAccessSequence
            fingerprintDigest = record.fingerprintDigest
            pipelineVersion = record.pipelineVersion
            generationMethod = record.generationMethod
            isFallback = record.isFallback
            fallbackReason = record.fallbackReason
            requestedTimeSeconds = record.requestedTimeSeconds
            actualTimeSeconds = record.actualTimeSeconds
        }

        init(
            key: String,
            kind: MediaCacheKind,
            filename: String,
            byteSize: Int64,
            createdAt: Date,
            lastAccessAt: Date,
            lastAccessSequence: UInt64,
            fingerprintDigest: String,
            pipelineVersion: Int,
            generationMethod: MediaGenerationMethod,
            isFallback: Bool,
            fallbackReason: MediaFailureCode?,
            requestedTimeSeconds: Double?,
            actualTimeSeconds: Double?
        ) {
            self.key = key
            self.kind = kind
            self.filename = filename
            self.byteSize = byteSize
            self.createdAt = createdAt
            self.lastAccessAt = lastAccessAt
            self.lastAccessSequence = lastAccessSequence
            self.fingerprintDigest = fingerprintDigest
            self.pipelineVersion = pipelineVersion
            self.generationMethod = generationMethod
            self.isFallback = isFallback
            self.fallbackReason = fallbackReason
            self.requestedTimeSeconds = requestedTimeSeconds
            self.actualTimeSeconds = actualTimeSeconds
        }

        var indexRecord: MediaCacheIndexRecord {
            MediaCacheIndexRecord(
                key: key,
                kind: kind,
                filename: filename,
                byteSize: byteSize,
                createdAt: createdAt,
                lastAccessAt: lastAccessAt,
                lastAccessSequence: lastAccessSequence,
                fingerprintDigest: fingerprintDigest,
                pipelineVersion: pipelineVersion,
                generationMethod: generationMethod,
                isFallback: isFallback,
                fallbackReason: fallbackReason,
                requestedTimeSeconds: requestedTimeSeconds,
                actualTimeSeconds: actualTimeSeconds
            )
        }
    }

    private let rootURL: URL
    private let hardLimitBytes: Int64
    private let softLimits: [MediaCacheKind: Int64]
    private let pipelineVersion: Int
    private let database: MediaCacheIndexDatabase
    private var entries: [String: Entry]
    private var totalBytes: Int64
    private var nextAccessSequence: UInt64
    private var dirtyAccessCount = 0
    private var lastIndexFlush = Date()
    private var dirtyKeys: Set<String> = []
    private var deletedKeys: Set<String> = []

    init(configuration: MediaPipelineConfiguration) throws {
        rootURL = configuration.cacheDirectory.standardizedFileURL
        hardLimitBytes = configuration.diskHardLimitBytes
        softLimits = configuration.diskSoftLimits
        pipelineVersion = configuration.pipelineVersion

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for kind in MediaCacheKind.allCases {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(kind.rawValue, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let openedIndex = try Self.openDatabaseAndLoad(rootURL: rootURL)
        database = openedIndex.database
        let loaded = Self.loadIndex(
            records: openedIndex.records,
            rootURL: rootURL,
            pipelineVersion: pipelineVersion
        )
        Self.removePartialsAndOrphans(rootURL: rootURL, entries: loaded.entries)
        let quotaAdjusted = Self.evictLoadedEntriesToQuota(
            loaded,
            rootURL: rootURL,
            hardLimitBytes: hardLimitBytes,
            softLimits: softLimits
        )
        entries = quotaAdjusted.entries
        totalBytes = quotaAdjusted.totalBytes
        nextAccessSequence = quotaAdjusted.entries.values.map(\.lastAccessSequence).max() ?? 0
        do {
            try database.replaceAll(with: entries.values.map(\.indexRecord))
        } catch {
            throw Self.cacheFailure(error)
        }
        dirtyKeys.removeAll(keepingCapacity: false)
        deletedKeys.removeAll(keepingCapacity: false)
        try? fileManager.removeItem(at: rootURL.appendingPathComponent("index.json"))
    }

    func imageDescriptor(
        for key: MediaRequestKey,
        kind: MediaCacheKind
    ) -> ImageDescriptor? {
        let identifier = key.stableIdentifier
        guard var entry = entries[identifier],
              entry.kind == kind,
              entry.pipelineVersion == pipelineVersion,
              entry.fingerprintDigest == key.fingerprintDigest
        else {
            return nil
        }
        let fileURL = fileURL(for: entry)
        guard isContained(fileURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size == entry.byteSize
        else {
            removeEntry(identifier)
            try? persistIndex()
            return nil
        }

        entry.lastAccessAt = Date()
        advanceAccessSequence()
        entry.lastAccessSequence = nextAccessSequence
        entries[identifier] = entry
        dirtyKeys.insert(identifier)
        deletedKeys.remove(identifier)
        dirtyAccessCount += 1
        flushAccessesIfNeeded()
        return ImageDescriptor(
            identifier: identifier,
            fileURL: fileURL,
            byteSize: entry.byteSize,
            generationMethod: entry.generationMethod,
            isFallback: entry.isFallback,
            fallbackReason: entry.fallbackReason,
            requestedTimeSeconds: entry.requestedTimeSeconds,
            actualTimeSeconds: entry.actualTimeSeconds
        )
    }

    nonisolated static func decode(_ descriptor: ImageDescriptor) -> MediaImage? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: descriptor.fileURL.path
        ),
        let size = (attributes[.size] as? NSNumber)?.int64Value,
        size == descriptor.byteSize,
        let source = CGImageSourceCreateWithURL(
            descriptor.fileURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        CGImageSourceGetCount(source) > 0,
        let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
        else { return nil }
        return MediaImage(
            cgImage: image,
            generationMethod: descriptor.generationMethod,
            deliverySource: .diskCache,
            isFallback: descriptor.isFallback,
            fallbackReason: descriptor.fallbackReason,
            requestedTimeSeconds: descriptor.requestedTimeSeconds,
            actualTimeSeconds: descriptor.actualTimeSeconds
        )
    }

    nonisolated static func encode(_ image: MediaImage) throws -> EncodedImage {
        EncodedImage(
            data: try pngData(for: image.cgImage),
            generationMethod: image.generationMethod,
            isFallback: image.isFallback,
            fallbackReason: image.fallbackReason,
            requestedTimeSeconds: image.requestedTimeSeconds,
            actualTimeSeconds: image.actualTimeSeconds
        )
    }

    func store(
        _ image: EncodedImage,
        for key: MediaRequestKey,
        kind: MediaCacheKind
    ) throws {
        guard !image.isFallback else { return }
        try storeData(
            image.data,
            keyIdentifier: key.stableIdentifier,
            fingerprintDigest: key.fingerprintDigest,
            kind: kind,
            generationMethod: image.generationMethod,
            isFallback: image.isFallback,
            fallbackReason: image.fallbackReason,
            requestedTimeSeconds: image.requestedTimeSeconds,
            actualTimeSeconds: image.actualTimeSeconds,
            fileExtension: "png"
        )
    }

    /// Internal raw-data entry point is useful for deterministic quota tests. Production
    /// image paths always call `store(_:for:kind:)`, which validates by encoding a CGImage.
    func storeDataForTesting(
        _ data: Data,
        identifier: String,
        kind: MediaCacheKind,
        fingerprintDigest: String = "test"
    ) throws {
        try storeData(
            data,
            keyIdentifier: identifier,
            fingerprintDigest: fingerprintDigest,
            kind: kind,
            generationMethod: .imageIO,
            isFallback: false,
            fallbackReason: nil,
            requestedTimeSeconds: nil,
            actualTimeSeconds: nil,
            fileExtension: "bin"
        )
    }

    func contains(identifier: String) -> Bool {
        entries[identifier] != nil
    }

    func invalidate(identifier: String) {
        removeEntry(identifier)
        try? persistIndex()
    }

    func touchForTesting(identifier: String) {
        guard var entry = entries[identifier] else { return }
        advanceAccessSequence()
        entry.lastAccessAt = Date()
        entry.lastAccessSequence = nextAccessSequence
        entries[identifier] = entry
        dirtyKeys.insert(identifier)
        deletedKeys.remove(identifier)
        dirtyAccessCount += 1
        flushAccessesIfNeeded()
    }

    func removeAll() throws {
        let fileManager = FileManager.default
        var firstFailure: (any Error)?
        for kind in MediaCacheKind.allCases {
            let directory = rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for file in files {
                do {
                    try fileManager.removeItem(at: file)
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
        }
        if let rootFiles = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for file in rootFiles where file.lastPathComponent.hasPrefix("index.corrupt.") {
                do {
                    try fileManager.removeItem(at: file)
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
        }
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
        dirtyAccessCount = 0
        dirtyKeys.removeAll(keepingCapacity: false)
        deletedKeys.removeAll(keepingCapacity: false)
        do {
            try database.removeAll()
            lastIndexFlush = Date()
        } catch {
            throw Self.cacheFailure(error)
        }
        if let firstFailure {
            throw MediaPipelineFailure.classify(firstFailure, defaultCode: .cacheIO)
        }
    }

    func flush() throws {
        try persistIndex()
    }

    func statistics() -> Statistics {
        Statistics(entryCount: entries.count, costBytes: totalBytes)
    }

    private func storeData(
        _ data: Data,
        keyIdentifier: String,
        fingerprintDigest: String,
        kind: MediaCacheKind,
        generationMethod: MediaGenerationMethod,
        isFallback: Bool,
        fallbackReason: MediaFailureCode?,
        requestedTimeSeconds: Double?,
        actualTimeSeconds: Double?,
        fileExtension: String
    ) throws {
        if Task.isCancelled { throw MediaPipelineFailure(.cancelled) }
        let byteSize = Int64(data.count)
        guard byteSize > 0, byteSize <= hardLimitBytes else { return }

        let filename = "\(keyIdentifier).\(fileExtension)"
        let directory = rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
        let finalURL = directory.appendingPathComponent(filename, isDirectory: false)
        guard isContained(finalURL) else {
            throw MediaPipelineFailure(.cacheIO, diagnostic: "cache containment")
        }
        let temporaryURL = directory.appendingPathComponent(
            ".\(keyIdentifier).partial.\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            if Task.isCancelled { throw MediaPipelineFailure(.cancelled) }
            let renameResult: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                finalURL.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return -1 }
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            Self.synchronizeDirectory(directory)
        } catch {
            throw MediaPipelineFailure.classify(error, defaultCode: .cacheIO)
        }

        if let old = entries[keyIdentifier] {
            totalBytes = max(0, totalBytes - old.byteSize)
            let oldURL = fileURL(for: old)
            if oldURL != finalURL { try? FileManager.default.removeItem(at: oldURL) }
        }
        let now = Date()
        advanceAccessSequence()
        entries[keyIdentifier] = Entry(
            key: keyIdentifier,
            kind: kind,
            filename: filename,
            byteSize: byteSize,
            createdAt: now,
            lastAccessAt: now,
            lastAccessSequence: nextAccessSequence,
            fingerprintDigest: fingerprintDigest,
            pipelineVersion: pipelineVersion,
            generationMethod: generationMethod,
            isFallback: isFallback,
            fallbackReason: fallbackReason,
            requestedTimeSeconds: requestedTimeSeconds,
            actualTimeSeconds: actualTimeSeconds
        )
        dirtyKeys.insert(keyIdentifier)
        deletedKeys.remove(keyIdentifier)
        totalBytes += byteSize
        evictToQuota(protecting: keyIdentifier)
        do {
            try persistIndex()
        } catch {
            removeEntry(keyIdentifier)
            try? persistIndex()
            throw error
        }
    }

    private func evictToQuota(protecting protectedKey: String) {
        while totalBytes > hardLimitBytes {
            let usageByKind = Dictionary(grouping: entries.values, by: \.kind)
                .mapValues { $0.reduce(Int64(0)) { $0 + $1.byteSize } }
            let overSoftKinds = Set<MediaCacheKind>(usageByKind.compactMap { kind, usage in
                guard let soft = softLimits[kind], usage > soft else { return nil }
                return kind
            })
            let candidates = entries.values.filter { $0.key != protectedKey }
            let victim = candidates
                .filter { overSoftKinds.isEmpty || overSoftKinds.contains($0.kind) }
                .min(by: Self.isOlder)
                ?? candidates.min(by: Self.isOlder)
            guard let victim else {
                // The protected entry alone exceeds the cap; do not keep it.
                removeEntry(protectedKey)
                return
            }
            removeEntry(victim.key)
        }
    }

    private func removeEntry(_ key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes = max(0, totalBytes - removed.byteSize)
        dirtyKeys.remove(key)
        deletedKeys.insert(key)
        try? FileManager.default.removeItem(at: fileURL(for: removed))
    }

    private func advanceAccessSequence() {
        if nextAccessSequence >= UInt64(Int64.max) {
            var sequence: UInt64 = 0
            for value in entries.values.sorted(by: Self.isOlder) {
                sequence += 1
                var entry = value
                entry.lastAccessSequence = sequence
                entries[entry.key] = entry
                dirtyKeys.insert(entry.key)
                deletedKeys.remove(entry.key)
            }
            nextAccessSequence = sequence
        }
        nextAccessSequence += 1
    }

    private static func isOlder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.lastAccessSequence == rhs.lastAccessSequence {
            return lhs.key < rhs.key
        }
        return lhs.lastAccessSequence < rhs.lastAccessSequence
    }

    private func fileURL(for entry: Entry) -> URL {
        rootURL
            .appendingPathComponent(entry.kind.rawValue, isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: false)
    }

    private func isContained(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    private func flushAccessesIfNeeded() {
        guard dirtyAccessCount >= 32 || Date().timeIntervalSince(lastIndexFlush) >= 5 else { return }
        try? persistIndex()
    }

    private func persistIndex() throws {
        let upserts = dirtyKeys.compactMap { entries[$0]?.indexRecord }
        do {
            try database.apply(upserts: upserts, deletions: deletedKeys)
            dirtyKeys.removeAll(keepingCapacity: true)
            deletedKeys.removeAll(keepingCapacity: true)
            dirtyAccessCount = 0
            lastIndexFlush = Date()
        } catch {
            throw Self.cacheFailure(error)
        }
    }

    private static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaPipelineFailure(.cacheIO, diagnostic: "PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaPipelineFailure(.cacheIO, diagnostic: "PNG finalize")
        }
        return data as Data
    }

    private static func synchronizeDirectory(_ directory: URL) {
        let descriptor: Int32 = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }

    private static func loadIndex(
        records: [MediaCacheIndexRecord],
        rootURL: URL,
        pipelineVersion: Int
    ) -> (entries: [String: Entry], totalBytes: Int64) {
        let rootPath = rootURL.standardizedFileURL.path
        var valid: [String: Entry] = [:]
        var total: Int64 = 0
        for record in records where record.pipelineVersion == pipelineVersion {
            guard !record.key.isEmpty,
                  !record.fingerprintDigest.isEmpty,
                  record.byteSize > 0,
                  record.createdAt.timeIntervalSince1970.isFinite,
                  record.lastAccessAt.timeIntervalSince1970.isFinite,
                  !record.isFallback,
                  record.requestedTimeSeconds?.isFinite != false,
                  record.actualTimeSeconds?.isFinite != false,
                  !record.filename.isEmpty,
                  record.filename != ".",
                  record.filename != "..",
                  !record.filename.contains("/"),
                  record.filename == URL(fileURLWithPath: record.filename).lastPathComponent,
                  record.kind.rawValue == URL(fileURLWithPath: record.kind.rawValue).lastPathComponent
            else { continue }
            let fileURL = rootURL
                .appendingPathComponent(record.kind.rawValue, isDirectory: true)
                .appendingPathComponent(record.filename, isDirectory: false)
                .standardizedFileURL
            guard fileURL.path.hasPrefix(rootPath + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size == record.byteSize
            else { continue }
            let (newTotal, overflow) = total.addingReportingOverflow(record.byteSize)
            guard !overflow else { continue }
            valid[record.key] = Entry(record: record)
            total = newTotal
        }
        return (valid, total)
    }

    private static func openDatabaseAndLoad(
        rootURL: URL
    ) throws -> (database: MediaCacheIndexDatabase, records: [MediaCacheIndexRecord]) {
        let indexURL = rootURL.appendingPathComponent("index.sqlite3", isDirectory: false)
        do {
            let database = try MediaCacheIndexDatabase(url: indexURL)
            return (database, try database.loadAll())
        } catch let failure as MediaCacheIndexDatabaseFailure
            where failure.canRebuildDerivedIndex {
            do {
                try quarantineDatabase(at: indexURL)
                let database = try MediaCacheIndexDatabase(url: indexURL)
                return (database, try database.loadAll())
            } catch {
                throw cacheFailure(error)
            }
        } catch {
            throw cacheFailure(error)
        }
    }

    private static func quarantineDatabase(at indexURL: URL) throws {
        let fileManager = FileManager.default
        let suffix = UUID().uuidString
        var firstFailure: (any Error)?
        for sidecar in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: indexURL.path + sidecar)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = indexURL.deletingLastPathComponent().appendingPathComponent(
                "index.corrupt.\(suffix).sqlite3\(sidecar)",
                isDirectory: false
            )
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private static func cacheFailure(_ error: any Error) -> MediaPipelineFailure {
        if let failure = error as? MediaCacheIndexDatabaseFailure {
            return failure.pipelineFailure
        }
        return MediaPipelineFailure.classify(error, defaultCode: .cacheIO)
    }

    private static func removePartialsAndOrphans(rootURL: URL, entries: [String: Entry]) {
        let referenced = Set(entries.values.map { "\($0.kind.rawValue)/\($0.filename)" })
        for kind in MediaCacheKind.allCases {
            let directory = rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for file in files {
                let relative = "\(kind.rawValue)/\(file.lastPathComponent)"
                if file.lastPathComponent.contains(".partial.") || !referenced.contains(relative) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private static func evictLoadedEntriesToQuota(
        _ loaded: (entries: [String: Entry], totalBytes: Int64),
        rootURL: URL,
        hardLimitBytes: Int64,
        softLimits: [MediaCacheKind: Int64]
    ) -> (entries: [String: Entry], totalBytes: Int64) {
        var entries = loaded.entries
        var totalBytes = loaded.totalBytes
        while totalBytes > hardLimitBytes, !entries.isEmpty {
            let usageByKind = Dictionary(grouping: entries.values, by: \.kind)
                .mapValues { $0.reduce(Int64(0)) { $0 + $1.byteSize } }
            let overSoftKinds = Set<MediaCacheKind>(usageByKind.compactMap { kind, usage in
                guard let softLimit = softLimits[kind], usage > softLimit else { return nil }
                return kind
            })
            let victim = entries.values
                .filter { overSoftKinds.isEmpty || overSoftKinds.contains($0.kind) }
                .min(by: isOlder)
                ?? entries.values.min(by: isOlder)
            guard let victim else { break }
            entries.removeValue(forKey: victim.key)
            totalBytes = max(0, totalBytes - victim.byteSize)
            let fileURL = rootURL
                .appendingPathComponent(victim.kind.rawValue, isDirectory: true)
                .appendingPathComponent(victim.filename, isDirectory: false)
            try? FileManager.default.removeItem(at: fileURL)
        }
        return (entries, totalBytes)
    }
}
