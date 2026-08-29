import Darwin
import Foundation

// Darwin exposes `struct flock` to Swift but not the BSD `flock(2)` function because the names
// collide in the importer. Bind that stable libc symbol explicitly for the root-batch lease.
@_silgen_name("flock")
private func umis_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum MetadataRecoveryKind: String, Codable, Hashable, Sendable {
    case embeddedXMP
    case sidecarXMP
    case unknown
}

public struct MetadataRecoveryWitness: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteSize: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let mode: UInt32
    public let linkCount: UInt64
}

public struct MetadataRecoveryRecord: Codable, Hashable, Sendable {
    /// Relative to the frozen archive root; never contains the user's absolute path.
    public let recoveryDirectoryRelativePath: String
    public let recoveryDirectoryLeaf: String
    public let kind: MetadataRecoveryKind
    public let targetLeaf: String?
    public let state: String
    public let original: MetadataRecoveryWitness?
    public let committed: MetadataRecoveryWitness?
    public let artifacts: [MetadataRecoveryWitness]
    public let manifestIsValid: Bool
    public let warning: String

    public var mayContainOriginalBackup: Bool {
        original != nil && (state != "cleanupComplete")
    }
}

public struct MetadataRecoveryScanResult: Sendable {
    public let records: [MetadataRecoveryRecord]
    public let visitedDirectoryCount: Int
    public let wasTruncated: Bool

    public init(records: [MetadataRecoveryRecord], visitedDirectoryCount: Int, wasTruncated: Bool) {
        self.records = records
        self.visitedDirectoryCount = visitedDirectoryCount
        self.wasTruncated = wasTruncated
    }
}

/// A clean, bounded root scan together with an exclusive UMIS recovery-namespace lease.
///
/// The authorization is intentionally a reference capability. Keep it alive only for one
/// top-level metadata batch and pass it to every mutation context in that batch. It owns an
/// advisory lock on the frozen root and authorizes only directory inodes that were reached by the
/// descriptor-relative scan. This lets each asset perform an O(1) identity check instead of
/// re-enumerating a 10,000-entry parent directory, while a missing, truncated, dirty, or invalidated
/// authorization continues to fail closed.
public struct MetadataRecoveryWritePreflight: Sendable {
    public let scanResult: MetadataRecoveryScanResult
    public let authorization: MetadataRecoveryWriteAuthorization?

    public init(
        scanResult: MetadataRecoveryScanResult,
        authorization: MetadataRecoveryWriteAuthorization?
    ) {
        self.scanResult = scanResult
        self.authorization = authorization
    }
}

private struct MetadataRecoveryDirectoryIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

/// Opaque authorization produced only by `MetadataRecoveryInspector.prepareWriteTree`.
///
/// The lock is advisory because macOS does not offer a mandatory directory-namespace lock. UMIS
/// processes cooperate through `flock`; a same-UID malicious process that deliberately creates a
/// private UMIS recovery name remains outside the documented threat model. Filesystem mutations
/// themselves still use descriptor capabilities and full inode witnesses.
public final class MetadataRecoveryWriteAuthorization: @unchecked Sendable, Hashable {
    private let stateLock = NSLock()
    private var lockDescriptor: Int32
    private let rootIdentity: MetadataRecoveryDirectoryIdentity
    private let cleanDirectoryIdentities: Set<MetadataRecoveryDirectoryIdentity>
    private var invalidationReason: String?

    fileprivate init(
        lockDescriptor: Int32,
        rootIdentity: MetadataRecoveryDirectoryIdentity,
        cleanDirectoryIdentities: Set<MetadataRecoveryDirectoryIdentity>
    ) {
        self.lockDescriptor = lockDescriptor
        self.rootIdentity = rootIdentity
        self.cleanDirectoryIdentities = cleanDirectoryIdentities
    }

    deinit {
        stateLock.lock()
        let descriptor = lockDescriptor
        lockDescriptor = -1
        stateLock.unlock()
        if descriptor >= 0 {
            _ = umis_flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    public static func == (
        lhs: MetadataRecoveryWriteAuthorization,
        rhs: MetadataRecoveryWriteAuthorization
    ) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func requireAuthorizedParent(
        _ parentFileDescriptor: Int32,
        displayURL: URL
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lockDescriptor >= 0, invalidationReason == nil else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayURL.path,
                reason: invalidationReason
                    ?? "The metadata recovery write authorization is no longer valid"
            )
        }
        var rootStatus = stat()
        guard Darwin.fstat(lockDescriptor, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              MetadataRecoveryDirectoryIdentity(rootStatus) == rootIdentity else {
            invalidationReason = "The frozen metadata root identity changed"
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayURL.path,
                reason: invalidationReason!
            )
        }
        var parentStatus = stat()
        guard Darwin.fstat(parentFileDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              cleanDirectoryIdentities.contains(MetadataRecoveryDirectoryIdentity(parentStatus)) else {
            invalidationReason =
                "The mutation parent was not part of the clean frozen-root recovery scan"
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayURL.path,
                reason: invalidationReason!
            )
        }
    }

    func invalidate(reason: String) {
        stateLock.lock()
        if invalidationReason == nil { invalidationReason = reason }
        stateLock.unlock()
    }
}

/// Read-only discovery for interrupted XMP recovery transactions.
///
/// The traversal starts from a held directory descriptor, uses openat/O_NOFOLLOW for every child,
/// does not enter symlinks or common macOS package directories, and treats malformed/unknown
/// manifests as records that require manual inspection. It never deletes or repairs anything.
public struct MetadataRecoveryInspector: Sendable {
    public var maximumDirectories: Int
    public var maximumRecords: Int
    public var maximumDepth: Int

    public init(
        maximumDirectories: Int = 100_000,
        maximumRecords: Int = 10_000,
        maximumDepth: Int = 256
    ) {
        self.maximumDirectories = max(1, maximumDirectories)
        self.maximumRecords = max(1, maximumRecords)
        self.maximumDepth = max(1, maximumDepth)
    }

    public func scanTree(
        rootFileDescriptor: Int32,
        displayRootURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> MetadataRecoveryScanResult {
        try scanTreeImpl(
            rootFileDescriptor: rootFileDescriptor,
            displayRootURL: displayRootURL,
            isCancelled: isCancelled,
            directoryCollector: nil
        )
    }

    /// Scans once for a metadata-write batch and, only when the complete tree is clean, returns an
    /// authorization that replaces every per-asset full-directory recovery enumeration.
    ///
    /// A non-nil authorization owns a non-blocking exclusive UMIS lock on the frozen root until it
    /// is released. Dirty or truncated scans deliberately return `nil` authorization so the caller
    /// can surface all discovered records without gaining mutation authority.
    public func prepareWriteTree(
        rootFileDescriptor: Int32,
        displayRootURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> MetadataRecoveryWritePreflight {
        let lockDescriptor = Darwin.openat(
            rootFileDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard lockDescriptor >= 0 else {
            throw UMISCoreError.posix(
                operation: "open metadata-recovery batch lock root",
                code: errno,
                path: displayRootURL.path
            )
        }
        var ownsLockDescriptor = true
        defer {
            if ownsLockDescriptor {
                _ = umis_flock(lockDescriptor, LOCK_UN)
                Darwin.close(lockDescriptor)
            }
        }
        guard umis_flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: displayRootURL.path,
                reason: "Another UMIS metadata batch already holds the frozen-root recovery lock"
            )
        }
        var rootStatus = stat()
        guard Darwin.fstat(lockDescriptor, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw UMISCoreError.posix(
                operation: "fstat metadata-recovery batch root",
                code: errno,
                path: displayRootURL.path
            )
        }
        var directories = Set<MetadataRecoveryDirectoryIdentity>()
        let result = try scanTreeImpl(
            rootFileDescriptor: lockDescriptor,
            displayRootURL: displayRootURL,
            isCancelled: isCancelled
        ) { identity in
            directories.insert(identity)
        }
        guard result.records.isEmpty, !result.wasTruncated else {
            return MetadataRecoveryWritePreflight(scanResult: result, authorization: nil)
        }
        let authorization = MetadataRecoveryWriteAuthorization(
            lockDescriptor: lockDescriptor,
            rootIdentity: MetadataRecoveryDirectoryIdentity(rootStatus),
            cleanDirectoryIdentities: directories
        )
        ownsLockDescriptor = false
        return MetadataRecoveryWritePreflight(
            scanResult: result,
            authorization: authorization
        )
    }

    private func scanTreeImpl(
        rootFileDescriptor: Int32,
        displayRootURL: URL,
        isCancelled: @Sendable () -> Bool,
        directoryCollector: ((MetadataRecoveryDirectoryIdentity) -> Void)?
    ) throws -> MetadataRecoveryScanResult {
        let rootDescriptor = Darwin.fcntl(rootFileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard rootDescriptor >= 0 else {
            throw UMISCoreError.posix(
                operation: "duplicate metadata-recovery root",
                code: errno,
                path: displayRootURL.path
            )
        }
        var records: [MetadataRecoveryRecord] = []
        var visited = 0
        var truncated = false

        // Depth-first recursion intentionally opens at most O(maximumDepth) directory descriptors.
        // A stack of already-open sibling FDs would allow a wide archive to exhaust the process
        // descriptor limit, and thrown errors could otherwise strand every pending descriptor.
        func visit(
            descriptor: Int32,
            relativePath: String,
            depth: Int
        ) throws {
            defer { Darwin.close(descriptor) }
            guard !truncated else { return }
            if isCancelled() {
                truncated = true
                return
            }
            guard visited < maximumDirectories, records.count < maximumRecords else {
                truncated = true
                return
            }
            visited += 1
            if let directoryCollector {
                var directoryStatus = stat()
                guard Darwin.fstat(descriptor, &directoryStatus) == 0,
                      (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
                    throw UMISCoreError.posix(
                        operation: "fstat metadata-recovery scan directory",
                        code: errno,
                        path: displayRootURL.appendingPathComponent(relativePath).path
                    )
                }
                directoryCollector(MetadataRecoveryDirectoryIdentity(directoryStatus))
            }
            // `dup` would share the directory stream offset with the caller's capability. Open
            // `.` relative to the held directory instead so enumeration has an independent open
            // file description and repeated scans cannot silently start at end-of-directory.
            let listingDescriptor = Darwin.openat(
                descriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard listingDescriptor >= 0 else {
                throw UMISCoreError.posix(
                    operation: "duplicate directory for recovery scan",
                    code: errno,
                    path: displayRootURL.appendingPathComponent(relativePath).path
                )
            }
            guard let directory = Darwin.fdopendir(listingDescriptor) else {
                let code = errno
                Darwin.close(listingDescriptor)
                throw UMISCoreError.posix(
                    operation: "fdopendir metadata-recovery scan",
                    code: code,
                    path: displayRootURL.appendingPathComponent(relativePath).path
                )
            }
            defer { Darwin.closedir(directory) }

            while let entry = Darwin.readdir(directory) {
                if isCancelled() {
                    truncated = true
                    break
                }
                let name = Self.entryName(entry)
                guard name != ".", name != ".." else { continue }
                var status = stat()
                let lookup = name.withCString {
                    Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                if lookup != 0 {
                    if errno == ENOENT { continue }
                    throw UMISCoreError.posix(
                        operation: "fstatat metadata-recovery scan",
                        code: errno,
                        path: displayRootURL
                            .appendingPathComponent(relativePath)
                            .appendingPathComponent(name)
                            .path
                    )
                }
                guard (status.st_mode & S_IFMT) == S_IFDIR else { continue }
                let childRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                if name.hasPrefix(Self.recoveryDirectoryPrefix) {
                    let recoveryDescriptor = name.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                    guard recoveryDescriptor >= 0 else {
                        records.append(Self.brokenRecord(
                            relativePath: childRelative,
                            leaf: name,
                            reason: "Recovery directory could not be opened without following links"
                        ))
                        continue
                    }
                    let record = Self.inspectRecoveryDirectory(
                        recoveryDescriptor,
                        relativePath: childRelative,
                        leaf: name
                    )
                    Darwin.close(recoveryDescriptor)
                    records.append(record)
                    if records.count >= maximumRecords {
                        truncated = true
                        break
                    }
                    continue
                }
                guard depth < maximumDepth, !Self.isPackageDirectory(name) else {
                    if depth >= maximumDepth { truncated = true }
                    continue
                }
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if child >= 0 {
                    try visit(
                        descriptor: child,
                        relativePath: childRelative,
                        depth: depth + 1
                    )
                    if truncated { break }
                } else if errno != ENOENT && errno != EACCES && errno != EPERM {
                    throw UMISCoreError.posix(
                        operation: "openat metadata-recovery child",
                        code: errno,
                        path: displayRootURL.appendingPathComponent(childRelative).path
                    )
                }
            }
        }

        try visit(descriptor: rootDescriptor, relativePath: "", depth: 0)
        return MetadataRecoveryScanResult(
            records: records,
            visitedDirectoryCount: visited,
            wasTruncated: truncated
        )
    }

    private static let recoveryDirectoryPrefix = ".umis-xmp-recovery-"
    private static let skippedPackageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "imovielibrary", "fcpbundle",
    ]

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func isPackageDirectory(_ name: String) -> Bool {
        skippedPackageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func inspectRecoveryDirectory(
        _ descriptor: Int32,
        relativePath: String,
        leaf: String
    ) -> MetadataRecoveryRecord {
        do {
            if let cleanup = try readManifest(
                descriptor,
                leaf: "manifest.cleanup.json"
            ) {
                return try parseManifest(cleanup, relativePath: relativePath, leaf: leaf)
            }
            if let sealed = try readManifest(
                descriptor,
                leaf: "manifest.sealed.json"
            ) {
                return try parseManifest(sealed, relativePath: relativePath, leaf: leaf)
            }
            if let legacySealed = try readManifest(descriptor, leaf: "manifest.json") {
                return try parseManifest(legacySealed, relativePath: relativePath, leaf: leaf)
            }
            if let pending = try readManifest(
                descriptor,
                leaf: "manifest.pending.json"
            ) {
                return try parseManifest(pending, relativePath: relativePath, leaf: leaf)
            }
            return brokenRecord(
                relativePath: relativePath,
                leaf: leaf,
                reason: "No recognized recovery manifest is present"
            )
        } catch {
            return brokenRecord(
                relativePath: relativePath,
                leaf: leaf,
                reason: "Recovery manifest is malformed or changed while reading: \(String(describing: error))"
            )
        }
    }

    private static func readManifest(_ parent: Int32, leaf: String) throws -> Data? {
        let descriptor = leaf.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw UMISCoreError.posix(operation: "open recovery manifest", code: errno, path: leaf)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 64 * 1_024 else {
            throw UMISCoreError.invalidPath("Invalid recovery manifest: \(leaf)")
        }
        var named = stat()
        let lookup = leaf.withCString {
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard lookup == 0,
              before.st_dev == named.st_dev,
              before.st_ino == named.st_ino,
              before.st_size == named.st_size,
              before.st_mtimespec.tv_sec == named.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == named.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == named.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == named.st_ctimespec.tv_nsec else {
            throw UMISCoreError.invalidPath("Recovery manifest binding changed: \(leaf)")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "read recovery manifest", code: errno, path: leaf)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
            guard data.count <= 64 * 1_024 else {
                throw UMISCoreError.invalidPath("Recovery manifest exceeded size limit: \(leaf)")
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(before.st_size) else {
            throw UMISCoreError.invalidPath("Recovery manifest changed while reading: \(leaf)")
        }
        return data
    }

    private static func parseManifest(
        _ data: Data,
        relativePath: String,
        leaf: String
    ) throws -> MetadataRecoveryRecord {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue == 1,
              let rawKind = object["kind"] as? String,
              let targetLeaf = object["targetLeaf"] as? String,
              !targetLeaf.isEmpty,
              !targetLeaf.contains("/"),
              let state = object["state"] as? String else {
            throw UMISCoreError.invalidPath("Recovery manifest schema is unknown")
        }
        let kind = MetadataRecoveryKind(rawValue: rawKind) ?? .unknown
        let original = try parseWitness(object["original"])
        let committed = try parseWitness(object["committed"])
        var artifacts: [MetadataRecoveryWitness] = []
        if let rawArtifacts = object["artifacts"] as? [[String: Any]] {
            for rawArtifact in rawArtifacts {
                if let witness = try parseWitness(rawArtifact["witness"]) {
                    artifacts.append(witness)
                }
            }
        } else if let artifact = try parseWitness(object["artifact"]) {
            artifacts = [artifact]
        }
        return MetadataRecoveryRecord(
            recoveryDirectoryRelativePath: relativePath,
            recoveryDirectoryLeaf: leaf,
            kind: kind,
            targetLeaf: targetLeaf,
            state: state,
            original: original,
            committed: committed,
            artifacts: artifacts,
            manifestIsValid: kind != .unknown,
            warning: kind == .unknown
                ? "Unknown recovery kind; do not delete automatically"
                : "Interrupted metadata recovery requires explicit inspection; it was not deleted"
        )
    }

    private static func parseWitness(_ raw: Any?) throws -> MetadataRecoveryWitness? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any],
              let device = object["device"] as? NSNumber,
              let inode = object["inode"] as? NSNumber,
              let byteSize = object["byteSize"] as? NSNumber,
              let modifiedSeconds = object["modifiedSeconds"] as? NSNumber,
              let modifiedNanoseconds = object["modifiedNanoseconds"] as? NSNumber,
              let changedSeconds = object["changedSeconds"] as? NSNumber,
              let changedNanoseconds = object["changedNanoseconds"] as? NSNumber,
              let mode = object["mode"] as? NSNumber,
              let linkCount = object["linkCount"] as? NSNumber else {
            throw UMISCoreError.invalidPath("Recovery witness is incomplete")
        }
        return MetadataRecoveryWitness(
            device: device.uint64Value,
            inode: inode.uint64Value,
            byteSize: byteSize.int64Value,
            modifiedSeconds: modifiedSeconds.int64Value,
            modifiedNanoseconds: modifiedNanoseconds.int64Value,
            changedSeconds: changedSeconds.int64Value,
            changedNanoseconds: changedNanoseconds.int64Value,
            mode: mode.uint32Value,
            linkCount: linkCount.uint64Value
        )
    }

    private static func brokenRecord(
        relativePath: String,
        leaf: String,
        reason: String
    ) -> MetadataRecoveryRecord {
        MetadataRecoveryRecord(
            recoveryDirectoryRelativePath: relativePath,
            recoveryDirectoryLeaf: leaf,
            kind: .unknown,
            targetLeaf: nil,
            state: "unknownOrBroken",
            original: nil,
            committed: nil,
            artifacts: [],
            manifestIsValid: false,
            warning: "\(reason). Never delete this directory automatically."
        )
    }
}

/// Cheap direct-parent guard used on every metadata mutation boundary. A recovery entry is never
/// auto-deleted or followed: its mere presence blocks a later write until the root-level inspector
/// has surfaced it for explicit operator action.
enum MetadataRecoveryWriteGuard {
    private static let prefix = ".umis-xmp-recovery-"
    private final class Metrics: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private static let metrics = Metrics()

    static func resetEnumerationCountForTesting() { metrics.reset() }
    static var enumerationCountForTesting: Int { metrics.value() }

    static func requireNoPendingRecovery(
        parentFileDescriptor: Int32,
        displayURL: URL
    ) throws {
        metrics.increment()
        let listingDescriptor = Darwin.openat(
            parentFileDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard listingDescriptor >= 0 else {
            throw UMISCoreError.posix(
                operation: "duplicate metadata-recovery write guard",
                code: errno,
                path: displayURL.deletingLastPathComponent().path
            )
        }
        guard let directory = Darwin.fdopendir(listingDescriptor) else {
            let code = errno
            Darwin.close(listingDescriptor)
            throw UMISCoreError.posix(
                operation: "fdopendir metadata-recovery write guard",
                code: code,
                path: displayURL.deletingLastPathComponent().path
            )
        }
        defer { Darwin.closedir(directory) }
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name.hasPrefix(prefix) else { continue }
            throw AssetMetadataError.recoveryRetained(
                path: displayURL.path,
                recoveryDirectoryLeaf: name,
                reason: "An unresolved metadata recovery entry blocks further writes in this directory"
            )
        }
    }
}
