import CryptoKit
import Darwin
import Foundation

public struct FileHashResult: Codable, Hashable, Sendable {
    public var sha256: String
    public var byteSize: Int64
    public var fingerprintBefore: FileFingerprint
    public var fingerprintAfter: FileFingerprint

    public init(
        sha256: String,
        byteSize: Int64,
        fingerprintBefore: FileFingerprint,
        fingerprintAfter: FileFingerprint
    ) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.fingerprintBefore = fingerprintBefore
        self.fingerprintAfter = fingerprintAfter
    }
}

public actor OperationCancellation {
    private var requested = false

    public init() {}

    public func cancel() { requested = true }
    public func reset() { requested = false }
    public func isCancelled() -> Bool { requested }

    public func check() throws {
        if requested { throw UMISCoreError.cancelled }
    }
}

public enum StreamingSHA256 {
    public static func hashFile(
        at url: URL,
        expectedFingerprint: FileFingerprint? = nil,
        chunkSize: Int = 1_048_576,
        cancellation: OperationCancellation? = nil
    ) async throws -> FileHashResult {
        guard chunkSize > 0 else { throw UMISCoreError.invalidPlan("Hash chunk size must be positive") }
        let descriptor = try POSIXFile.openReadOnlyNoFollow(url)
        defer { Darwin.close(descriptor) }
        return try await hashDescriptor(
            descriptor,
            displayPath: url.path,
            expectedFingerprint: expectedFingerprint,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
    }

    /// Hashes a destination file opened relative to the frozen destination root. Every ancestor is
    /// traversed with `openat(O_NOFOLLOW)`, and every opened node must remain on the frozen device.
    /// This is the only destination hashing entry used by ingest/receipt/erase verification.
    static func hashDestinationFile(
        at url: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?,
        expectedFingerprint: FileFingerprint? = nil,
        chunkSize: Int = 1_048_576,
        cancellation: OperationCancellation? = nil
    ) async throws -> FileHashResult {
        guard chunkSize > 0 else { throw UMISCoreError.invalidPlan("Hash chunk size must be positive") }
        let descriptor = try DestinationPathAccess.openReadOnly(
            url,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        )
        defer { Darwin.close(descriptor) }
        return try await hashDescriptor(
            descriptor,
            displayPath: url.path,
            expectedFingerprint: expectedFingerprint,
            chunkSize: chunkSize,
            cancellation: cancellation
        )
    }

    private static func hashDescriptor(
        _ descriptor: Int32,
        displayPath: String,
        expectedFingerprint: FileFingerprint?,
        chunkSize: Int,
        cancellation: OperationCancellation?
    ) async throws -> FileHashResult {
        let before = try POSIXFile.fingerprint(descriptor: descriptor, path: displayPath)
        guard expectedFingerprint == nil || expectedFingerprint == before else {
            throw UMISCoreError.sourceChanged(displayPath)
        }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            try await cancellation?.check()
            let amount = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "read", code: errno, path: displayPath)
            }
            if amount == 0 { break }
            hasher.update(data: Data(buffer[0 ..< amount]))
            byteCount += Int64(amount)
        }

        let after = try POSIXFile.fingerprint(descriptor: descriptor, path: displayPath)
        guard before == after, byteCount == before.byteSize else {
            throw UMISCoreError.sourceChanged(displayPath)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileHashResult(
            sha256: digest,
            byteSize: byteCount,
            fingerprintBefore: before,
            fingerprintAfter: after
        )
    }
}

/// Descriptor-relative access to files below a frozen destination root. URL-string validation is
/// insufficient for delivery evidence because an attacker or second process can replace an
/// ancestor with a symlink between validation and open/rename. This helper starts at `/`, walks the
/// complete root and relative parent chain with `O_NOFOLLOW`, checks the frozen root inode/device,
/// and performs the final operation relative to the verified parent descriptor.
enum DestinationPathAccess {
    typealias DirectorySynchronizer = @Sendable (_ descriptor: Int32, _ diagnosticPath: String) throws -> Void

    static func prepareParent(
        for fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?,
        directorySynchronizer: DirectorySynchronizer? = nil
    ) throws {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: true,
            directorySynchronizer: directorySynchronizer
        ) { _, _ in () }
    }

    static func openReadOnly(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws -> Int32 {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { parent, leaf in
            let descriptor = leaf.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                try throwPathOpenError(operation: "openat destination", fileURL: fileURL)
            }
            do {
                try requireRegularFileAndDevice(
                    descriptor,
                    expectedDevice: destination.volumeDeviceIdentifier,
                    path: fileURL.path
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
    }

    static func openExclusiveWrite(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws -> Int32 {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: true
        ) { parent, leaf in
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
                )
            }
            guard descriptor >= 0 else {
                try throwPathOpenError(operation: "openat exclusive destination", fileURL: fileURL)
            }
            do {
                try requireRegularFileAndDevice(
                    descriptor,
                    expectedDevice: destination.volumeDeviceIdentifier,
                    path: fileURL.path
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
    }

    static func openAppendWrite(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws -> Int32 {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { parent, leaf in
            let descriptor = leaf.withCString {
                Darwin.openat(parent, $0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                try throwPathOpenError(operation: "openat partial for resume", fileURL: fileURL)
            }
            do {
                try requireRegularFileAndDevice(
                    descriptor,
                    expectedDevice: destination.volumeDeviceIdentifier,
                    path: fileURL.path
                )
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
    }

    static func fingerprint(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws -> FileFingerprint {
        let descriptor = try openReadOnly(
            fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        )
        defer { Darwin.close(descriptor) }
        return try POSIXFile.fingerprint(descriptor: descriptor, path: fileURL.path)
    }

    static func regularFileExists(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws -> Bool {
        do {
            return try withVerifiedParent(
                for: fileURL,
                destination: destination,
                sourceDeviceIdentifier: sourceDeviceIdentifier,
                createDirectories: false
            ) { parent, leaf in
                var value = stat()
                let result = leaf.withCString {
                    Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
                }
                if result != 0, errno == ENOENT { return false }
                guard result == 0 else {
                    try throwPathOpenError(operation: "fstatat destination", fileURL: fileURL)
                }
                guard (value.st_mode & S_IFMT) == S_IFREG else {
                    if (value.st_mode & S_IFMT) == S_IFLNK {
                        throw UMISCoreError.symbolicLinkRejected(fileURL.path)
                    }
                    throw UMISCoreError.notRegularFile(fileURL.path)
                }
                try requireExpectedDevice(value, destination: destination, path: fileURL.path)
                return true
            }
        } catch let UMISCoreError.posix(_, code, _) where code == ENOENT {
            return false
        }
    }

    static func truncateAndSynchronize(
        _ fileURL: URL,
        byteSize: Int64,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws {
        guard byteSize >= 0 else { throw UMISCoreError.invalidPlan("Negative truncate offset") }
        let descriptor = try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { parent, leaf in
            let result = leaf.withCString {
                Darwin.openat(parent, $0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard result >= 0 else {
                try throwPathOpenError(operation: "openat partial for truncate", fileURL: fileURL)
            }
            return result
        }
        defer { Darwin.close(descriptor) }
        try requireRegularFileAndDevice(
            descriptor,
            expectedDevice: destination.volumeDeviceIdentifier,
            path: fileURL.path
        )
        guard Darwin.ftruncate(descriptor, off_t(byteSize)) == 0 else {
            throw UMISCoreError.posix(operation: "truncate partial", code: errno, path: fileURL.path)
        }
        try POSIXFile.synchronize(descriptor: descriptor, path: fileURL.path)
    }

    static func atomicRenameNoReplace(
        from sourceURL: URL,
        to destinationURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws {
        try withVerifiedParent(
            for: sourceURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { sourceParent, sourceLeaf in
            try withVerifiedParent(
                for: destinationURL,
                destination: destination,
                sourceDeviceIdentifier: sourceDeviceIdentifier,
                createDirectories: true
            ) { destinationParent, destinationLeaf in
                let result = sourceLeaf.withCString { sourceName -> Int32 in
                    destinationLeaf.withCString { destinationName -> Int32 in
                        Darwin.renameatx_np(
                            sourceParent,
                            sourceName,
                            destinationParent,
                            destinationName,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else {
                    if errno == EEXIST { throw UMISCoreError.collision(destinationURL.path) }
                    throw UMISCoreError.posix(
                        operation: "renameatx_np verified destination",
                        code: errno,
                        path: destinationURL.path
                    )
                }
            }
        }
    }

    static func synchronizeParent(
        of fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { parent, _ in
            try POSIXFile.synchronize(descriptor: parent, path: fileURL.deletingLastPathComponent().path)
        }
    }

    static func removeIfExists(
        _ fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws {
        try withVerifiedParent(
            for: fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier,
            createDirectories: false
        ) { parent, leaf in
            var value = stat()
            let statResult = leaf.withCString {
                Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
            }
            if statResult != 0, errno == ENOENT { return }
            guard statResult == 0 else {
                try throwPathOpenError(operation: "fstatat before unlink", fileURL: fileURL)
            }
            guard (value.st_mode & S_IFMT) == S_IFREG else {
                if (value.st_mode & S_IFMT) == S_IFLNK {
                    throw UMISCoreError.symbolicLinkRejected(fileURL.path)
                }
                throw UMISCoreError.notRegularFile(fileURL.path)
            }
            try requireExpectedDevice(value, destination: destination, path: fileURL.path)
            let result = leaf.withCString { Darwin.unlinkat(parent, $0, 0) }
            guard result == 0 || errno == ENOENT else {
                throw UMISCoreError.posix(operation: "unlinkat destination", code: errno, path: fileURL.path)
            }
        }
    }

    /// Reopens the complete path after commit and proves that the URL still resolves through only
    /// real directories to the exact committed fingerprint on the frozen destination device.
    static func verifyCommittedFile(
        _ fileURL: URL,
        expectedFingerprint: FileFingerprint,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?
    ) throws {
        let current = try fingerprint(
            fileURL,
            destination: destination,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        )
        guard current == expectedFingerprint else { throw UMISCoreError.identityChanged }
    }

    private static func withVerifiedParent<T>(
        for fileURL: URL,
        destination: DestinationIdentity,
        sourceDeviceIdentifier: UInt64?,
        createDirectories: Bool,
        directorySynchronizer: DirectorySynchronizer? = nil,
        operation: (Int32, String) throws -> T
    ) throws -> T {
        guard let expectedDevice = destination.volumeDeviceIdentifier,
              destination.rootFileIdentifier?.isEmpty == false else {
            throw UMISCoreError.identityChanged
        }
        if let sourceDeviceIdentifier, sourceDeviceIdentifier == expectedDevice {
            throw UMISCoreError.eraseNotEligible("Source and destination resolve to the same POSIX device")
        }
        let components = try relativeComponents(of: fileURL, destination: destination)
        guard let leaf = components.last else {
            throw UMISCoreError.invalidPath("Destination file path is empty")
        }
        var directoryDescriptor = try openVerifiedRoot(destination)
        defer { Darwin.close(directoryDescriptor) }
        for component in components.dropLast() {
            let next = try openDirectory(
                component,
                relativeTo: directoryDescriptor,
                expectedDevice: expectedDevice,
                createIfMissing: createDirectories,
                displayPath: fileURL.path,
                directorySynchronizer: directorySynchronizer
            )
            Darwin.close(directoryDescriptor)
            directoryDescriptor = next
        }
        return try operation(directoryDescriptor, leaf)
    }

    private static func openVerifiedRoot(_ destination: DestinationIdentity) throws -> Int32 {
        let rootPath = destination.rootURL.standardizedFileURL.path
        guard rootPath.hasPrefix("/") else { throw UMISCoreError.invalidPath("Destination root must be absolute") }
        // macOS has trusted system aliases such as /var -> /private/var. Opening the frozen root in
        // one operation permits those ancestors, while O_NOFOLLOW rejects replacement of the root
        // itself and the inode/device digest below proves it is still the exact selected directory.
        let descriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw UMISCoreError.symbolicLinkRejected(rootPath)
            }
            throw UMISCoreError.posix(operation: "open destination root", code: errno, path: rootPath)
        }
        do {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0 else {
                throw UMISCoreError.posix(operation: "fstat destination root", code: errno, path: rootPath)
            }
            try requireExpectedDevice(value, destination: destination, path: rootPath)
            let rootIdentifier = try StableDigest.encode([
                String(UInt64(value.st_dev)),
                String(UInt64(value.st_ino)),
            ])
            guard rootIdentifier == destination.rootFileIdentifier else {
                throw UMISCoreError.identityChanged
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openDirectory(
        _ component: String,
        relativeTo parent: Int32,
        expectedDevice: UInt64?,
        createIfMissing: Bool,
        displayPath: String,
        directorySynchronizer: DirectorySynchronizer?
    ) throws -> Int32 {
        func attemptOpen() -> Int32 {
            component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
        }
        var descriptor = attemptOpen()
        var created = false
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let mkdirResult = component.withCString {
                Darwin.mkdirat(parent, $0, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
            }
            guard mkdirResult == 0 || errno == EEXIST else {
                throw UMISCoreError.posix(operation: "mkdirat destination", code: errno, path: displayPath)
            }
            created = mkdirResult == 0
            descriptor = attemptOpen()
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw UMISCoreError.symbolicLinkRejected(displayPath)
            }
            throw UMISCoreError.posix(operation: "openat destination directory", code: errno, path: displayPath)
        }
        do {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0 else {
                throw UMISCoreError.posix(operation: "fstat destination directory", code: errno, path: displayPath)
            }
            guard (value.st_mode & S_IFMT) == S_IFDIR else {
                throw UMISCoreError.invalidPath("Destination ancestor is not a directory: \(displayPath)")
            }
            if let expectedDevice, UInt64(value.st_dev) != expectedDevice {
                throw UMISCoreError.identityChanged
            }
            if created {
                let synchronize = directorySynchronizer ?? { descriptor, path in
                    try POSIXFile.synchronize(descriptor: descriptor, path: path)
                }
                // Durability order for a newly created directory is child metadata first, then the
                // entry in its parent. Returning before both fsync calls would permit SQLite to
                // publish a receipt for a path whose ancestor disappears after power loss.
                try synchronize(descriptor, "\(displayPath) [new directory \(component)]")
                try synchronize(parent, "\(displayPath) [parent entry for \(component)]")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func relativeComponents(
        of fileURL: URL,
        destination: DestinationIdentity
    ) throws -> [String] {
        let rootPath = destination.rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix), filePath != rootPath else {
            throw UMISCoreError.invalidPath("Path escapes its frozen destination root: \(fileURL.path)")
        }
        let rawComponents = String(filePath.dropFirst(prefix.count))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !rawComponents.isEmpty, rawComponents.allSatisfy({ !$0.isEmpty }) else {
            throw UMISCoreError.invalidPath("Destination contains an empty path component")
        }
        if rawComponents.first == ".umis-partial" {
            guard rawComponents.count == 3,
                  UUID(uuidString: rawComponents[1]) != nil,
                  rawComponents[2].hasSuffix(".partial"),
                  UUID(uuidString: String(rawComponents[2].dropLast(".partial".count))) != nil else {
                throw UMISCoreError.invalidPath("Invalid operation-owned partial namespace")
            }
            _ = try PathSafety.validateComponent(rawComponents[1])
            _ = try PathSafety.validateComponent(rawComponents[2])
            return rawComponents
        }
        return try rawComponents.map(PathSafety.validateComponent)
    }

    private static func requireRegularFileAndDevice(
        _ descriptor: Int32,
        expectedDevice: UInt64?,
        path: String
    ) throws {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw UMISCoreError.posix(operation: "fstat destination file", code: errno, path: path)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(path)
        }
        if let expectedDevice, UInt64(value.st_dev) != expectedDevice {
            throw UMISCoreError.identityChanged
        }
    }

    private static func requireExpectedDevice(
        _ value: stat,
        destination: DestinationIdentity,
        path: String
    ) throws {
        guard let expectedDevice = destination.volumeDeviceIdentifier,
              UInt64(value.st_dev) == expectedDevice else {
            throw UMISCoreError.identityChanged
        }
        _ = path
    }

    private static func throwPathOpenError(operation: String, fileURL: URL) throws -> Never {
        let code = errno
        if code == ELOOP || code == ENOTDIR {
            throw UMISCoreError.symbolicLinkRejected(fileURL.path)
        }
        throw UMISCoreError.posix(operation: operation, code: code, path: fileURL.path)
    }
}

enum POSIXFile {
    static func openReadOnlyNoFollow(_ url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw UMISCoreError.symbolicLinkRejected(url.path) }
            throw UMISCoreError.posix(operation: "open", code: errno, path: url.path)
        }
        let fingerprint = try fingerprint(descriptor: descriptor, path: url.path)
        guard fingerprint.byteSize >= 0 else {
            Darwin.close(descriptor)
            throw UMISCoreError.notRegularFile(url.path)
        }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UMISCoreError.posix(operation: "fstat", code: code, path: url.path)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw UMISCoreError.notRegularFile(url.path)
        }
        return descriptor
    }

    static func openExclusiveWrite(_ url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            )
        }
        guard descriptor >= 0 else {
            throw UMISCoreError.posix(operation: "open destination", code: errno, path: url.path)
        }
        return descriptor
    }

    static func openAppendWrite(_ url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw UMISCoreError.posix(operation: "open partial for resume", code: errno, path: url.path)
        }
        return descriptor
    }

    static func fingerprint(descriptor: Int32, path: String) throws -> FileFingerprint {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw UMISCoreError.posix(operation: "fstat", code: errno, path: path)
        }
        return FileFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteSize: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    static func synchronize(descriptor: Int32, path: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw UMISCoreError.posix(operation: "fsync", code: errno, path: path)
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            throw UMISCoreError.posix(operation: "open parent directory", code: errno, path: url.path)
        }
        defer { Darwin.close(descriptor) }
        try synchronize(descriptor: descriptor, path: url.path)
    }

    static func truncateAndSynchronize(_ url: URL, byteSize: Int64) throws {
        guard byteSize >= 0 else { throw UMISCoreError.invalidPlan("Negative truncate offset") }
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw UMISCoreError.posix(operation: "open partial for truncate", code: errno, path: url.path)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, off_t(byteSize)) == 0 else {
            throw UMISCoreError.posix(operation: "truncate partial", code: errno, path: url.path)
        }
        try synchronize(descriptor: descriptor, path: url.path)
    }

    static func writeAll(descriptor: Int32, bytes: UnsafeRawBufferPointer, path: String) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw UMISCoreError.posix(operation: "write", code: errno, path: path)
            }
            if result == 0 {
                throw UMISCoreError.posix(operation: "write made no progress", code: EIO, path: path)
            }
            offset += result
        }
    }

    static func atomicRenameNoReplace(from source: URL, to destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return -1 }
                return Darwin.renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw UMISCoreError.collision(destination.path) }
            throw UMISCoreError.posix(operation: "renameatx_np(RENAME_EXCL)", code: errno, path: destination.path)
        }
    }

    static func removeIfExists(_ url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.unlink(path)
        }
        if result != 0, errno != ENOENT {
            throw UMISCoreError.posix(operation: "unlink", code: errno, path: url.path)
        }
    }
}
