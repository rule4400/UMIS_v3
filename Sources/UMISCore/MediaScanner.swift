import Darwin
import Foundation

public enum InventoryClassification: String, Codable, Sendable {
    case requiredByUser
    case requiredCompanion
    case explicitlyExcludedByUser
    /// A recognized media file disabled by the project's category policy. The UI must explicitly
    /// include or exclude it before an erase-grade Required Set can be produced.
    case disabledByPolicyNeedsReview
    /// A recognized media file below a configured excluded folder. It remains visible and reviewable.
    case excludedFolderNeedsReview
    /// A recognized hidden media file. It remains visible and reviewable instead of being silently skipped.
    case hiddenEntryNeedsReview
    case systemMetadataAllowlisted
    case unknown
    case unreadable
    case changedDuringScan
}

/// Immutable scanner policy derived from the versioned project settings. Category IDs, rather than
/// folder/display names, are carried into each MediaAsset so later planning never depends on UI order.
public struct MediaScanPolicy: Codable, Hashable, Sendable {
    public var categoryRules: [ProjectCategory]
    public var sidecarExtensions: Set<String>
    public var includeHiddenFiles: Bool
    public var excludedFolderNames: Set<String>

    public init(
        categoryRules: [ProjectCategory],
        sidecarExtensions: Set<String> = ["xmp", "xml", "thm", "srt", "lrv", "aae"],
        includeHiddenFiles: Bool = false,
        excludedFolderNames: Set<String> = []
    ) {
        self.categoryRules = categoryRules
        self.sidecarExtensions = Self.normalizedExtensions(sidecarExtensions)
        self.includeHiddenFiles = includeHiddenFiles
        self.excludedFolderNames = Set(excludedFolderNames.map(Self.normalizedName))
    }

    public init(projectSettings: ProjectSettings) {
        self.init(
            categoryRules: projectSettings.categories,
            sidecarExtensions: projectSettings.sidecarExtensions,
            includeHiddenFiles: projectSettings.includeHiddenFiles,
            excludedFolderNames: projectSettings.excludedFolderNames
        )
    }

    public func validate() throws {
        var ownerByExtension: [String: ProjectCategoryID] = [:]
        for category in categoryRules {
            guard !category.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UMISCoreError.invalidPlan("Media scan category has an empty display name")
            }
            for ext in Self.normalizedExtensions(category.extensions) {
                if let existing = ownerByExtension[ext], existing != category.id {
                    throw UMISCoreError.invalidPlan("Extension .\(ext) is assigned to multiple media categories")
                }
                ownerByExtension[ext] = category.id
            }
        }
    }

    fileprivate func category(forPathExtension pathExtension: String) -> ProjectCategory? {
        let ext = Self.normalizedExtension(pathExtension)
        return categoryRules
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .first { Self.normalizedExtensions($0.extensions).contains(ext) }
    }

    fileprivate func containsExcludedFolder(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").dropLast().map { Self.normalizedName(String($0)) }
        return components.contains { excludedFolderNames.contains($0) }
    }

    fileprivate func containsHiddenComponent(relativePath: String) -> Bool {
        guard !includeHiddenFiles else { return false }
        return relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    fileprivate static func normalizedExtension(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    fileprivate static func normalizedExtensions(_ values: Set<String>) -> Set<String> {
        Set(values.map(normalizedExtension).filter { !$0.isEmpty })
    }

    fileprivate static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}

public enum InventoryEntryType: String, Codable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct SystemMetadataAllowlistRule: Codable, Hashable, Sendable {
    public var exactRelativePath: String
    public var expectedType: InventoryEntryType
    public var maximumByteSize: Int64

    public init(
        exactRelativePath: String,
        expectedType: InventoryEntryType = .regularFile,
        maximumByteSize: Int64
    ) {
        self.exactRelativePath = exactRelativePath
        self.expectedType = expectedType
        self.maximumByteSize = maximumByteSize
    }
}

public struct InventoryEntry: Codable, Hashable, Sendable {
    public var relativePath: String
    public var type: InventoryEntryType
    public var classification: InventoryClassification
    public var byteSize: Int64
    public var fingerprint: FileFingerprint?
    public var mediaAssetID: MediaAssetID?

    public init(
        relativePath: String,
        type: InventoryEntryType,
        classification: InventoryClassification,
        byteSize: Int64,
        fingerprint: FileFingerprint?,
        mediaAssetID: MediaAssetID?
    ) {
        self.relativePath = relativePath
        self.type = type
        self.classification = classification
        self.byteSize = byteSize
        self.fingerprint = fingerprint
        self.mediaAssetID = mediaAssetID
    }
}

public struct ScanIssue: Codable, Hashable, Sendable {
    public var relativePath: String
    public var message: String

    public init(relativePath: String, message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct ScanResult: Codable, Hashable, Sendable {
    public var root: URL
    public var sourceVolumeID: SourceVolumeID
    public var assets: [MediaAsset]
    public var inventory: [InventoryEntry]
    public var issues: [ScanIssue]
    public var inventoryDigest: String

    public init(
        root: URL,
        sourceVolumeID: SourceVolumeID,
        assets: [MediaAsset],
        inventory: [InventoryEntry],
        issues: [ScanIssue],
        inventoryDigest: String
    ) {
        self.root = root
        self.sourceVolumeID = sourceVolumeID
        self.assets = assets
        self.inventory = inventory
        self.issues = issues
        self.inventoryDigest = inventoryDigest
    }

    public func makeRequiredSet(
        selectedAssetIDs: Set<MediaAssetID>? = nil,
        destinationID: DestinationID,
        explicitlyExcludedAssetIDs: Set<MediaAssetID> = [],
        explicitExclusions: [ExplicitExclusionEvidence] = [],
        explicitDirectoryExclusions: [ExplicitDirectoryExclusionEvidence] = [],
        exclusionsReviewed: Bool = true,
        systemMetadataAllowlistDigest: String = MediaScanner.systemMetadataAllowlistDigest
    ) -> RequiredSet {
        let knownIDs = Set(assets.map(\.id))
        let reviewCandidateIDs = Set(inventory.compactMap { entry -> MediaAssetID? in
            switch entry.classification {
            case .disabledByPolicyNeedsReview, .excludedFolderNeedsReview, .hiddenEntryNeedsReview:
                return entry.mediaAssetID
            default:
                return nil
            }
        })
        // Policy-disabled/hidden/excluded-folder media is never silently copied or excluded. The caller
        // must put each candidate in either an explicit selected set or the explicit exclusion set.
        let selected = selectedAssetIDs ?? knownIDs.subtracting(reviewCandidateIDs)
        let validExcluded = explicitlyExcludedAssetIDs.intersection(knownIDs)
        let required = selected.intersection(knownIDs).subtracting(validExcluded)
        let unreviewedIDs = knownIDs.subtracting(selected).subtracting(validExcluded)
        let emptyDirectories = emptyUserDirectoryPathsRequiringReview
        let reviewedDirectoryPaths = Set(explicitDirectoryExclusions.map(\.relativePath))
            .intersection(emptyDirectories)
        let unresolvedDirectories = emptyDirectories.subtracting(reviewedDirectoryPaths)
        let deliveries = Set(required.map { RequiredDelivery(assetID: $0, destinationID: destinationID) })
        return RequiredSet(
            assetIDs: required,
            deliveries: deliveries,
            explicitlyExcludedAssetIDs: validExcluded,
            explicitExclusions: explicitExclusions,
            explicitDirectoryExclusions: explicitDirectoryExclusions,
            unresolvedDirectoryEntryCount: unresolvedDirectories.count,
            exclusionsReviewed: exclusionsReviewed && unreviewedIDs.isEmpty && unresolvedDirectories.isEmpty,
            unknownEntryCount: inventory.filter { $0.classification == .unknown }.count + unreviewedIDs.count,
            unreadableEntryCount: inventory.filter { $0.classification == .unreadable }.count + issues.count,
            changedEntryCount: inventory.filter { $0.classification == .changedDuringScan }.count,
            inventoryDigest: inventoryDigest,
            systemMetadataAllowlistDigest: systemMetadataAllowlistDigest
        )
    }

    public func validatedRequiredSet(
        selectedAssetIDs: Set<MediaAssetID>? = nil,
        destinationID: DestinationID,
        explicitlyExcludedAssetIDs: Set<MediaAssetID> = [],
        explicitExclusions: [ExplicitExclusionEvidence] = [],
        explicitDirectoryExclusions: [ExplicitDirectoryExclusionEvidence] = [],
        exclusionsReviewed: Bool = true,
        systemMetadataAllowlistDigest: String = MediaScanner.systemMetadataAllowlistDigest
    ) throws -> RequiredSet {
        let known = Set(assets.map(\.id))
        if let selectedAssetIDs, !selectedAssetIDs.isSubset(of: known) {
            throw UMISCoreError.invalidPlan("Selected asset set contains an asset outside this scan")
        }
        guard explicitlyExcludedAssetIDs.isSubset(of: known) else {
            throw UMISCoreError.invalidPlan("Excluded asset set contains an asset outside this scan")
        }
        if let selectedAssetIDs, !selectedAssetIDs.isDisjoint(with: explicitlyExcludedAssetIDs) {
            throw UMISCoreError.invalidPlan("An asset cannot be both selected and explicitly excluded")
        }
        let evidenceIDs = explicitExclusions.map(\.assetID)
        if !explicitExclusions.isEmpty {
            guard evidenceIDs.count == Set(evidenceIDs).count,
                  Set(evidenceIDs) == explicitlyExcludedAssetIDs else {
                throw UMISCoreError.invalidPlan("Every explicit exclusion requires exactly one audit evidence record")
            }
        }
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for evidence in explicitExclusions {
            guard evidence.isComplete,
                  let asset = assetByID[evidence.assetID],
                  evidence.relativePath == asset.relativePath,
                  evidence.byteSize == asset.byteSize else {
                throw UMISCoreError.invalidPlan("Explicit exclusion evidence does not match the scanned asset")
            }
        }
        let directoryPaths = explicitDirectoryExclusions.map(\.relativePath)
        guard directoryPaths.count == Set(directoryPaths).count,
              explicitDirectoryExclusions.allSatisfy(\.isComplete),
              Set(directoryPaths).isSubset(of: emptyUserDirectoryPathsRequiringReview) else {
            throw UMISCoreError.invalidPlan(
                "Empty-directory exclusion evidence does not match this frozen source inventory"
            )
        }
        return makeRequiredSet(
            selectedAssetIDs: selectedAssetIDs,
            destinationID: destinationID,
            explicitlyExcludedAssetIDs: explicitlyExcludedAssetIDs,
            explicitExclusions: explicitExclusions,
            explicitDirectoryExclusions: explicitDirectoryExclusions,
            exclusionsReviewed: exclusionsReviewed,
            systemMetadataAllowlistDigest: systemMetadataAllowlistDigest
        )
    }

    public func makeExplicitExclusionEvidence(
        assetID: MediaAssetID,
        reason: String,
        operatorIdentifier: String,
        confirmedAt: Date = Date()
    ) throws -> ExplicitExclusionEvidence {
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            throw UMISCoreError.invalidPlan("Cannot exclude an asset outside this scan")
        }
        return try ExplicitExclusionEvidence(
            assetID: asset.id,
            relativePath: asset.relativePath,
            byteSize: asset.byteSize,
            reason: reason,
            operatorIdentifier: operatorIdentifier,
            operatorConfirmedAt: confirmedAt
        )
    }

    public func makeEmptyDirectoryExclusionEvidence(
        relativePath: String,
        reason: String,
        operatorIdentifier: String,
        confirmedAt: Date = Date()
    ) throws -> ExplicitDirectoryExclusionEvidence {
        let path = relativePath.precomposedStringWithCanonicalMapping
        guard emptyUserDirectoryPathsRequiringReview.contains(path) else {
            throw UMISCoreError.invalidPlan("Directory is not an empty user directory in this scan")
        }
        return try ExplicitDirectoryExclusionEvidence(
            relativePath: path,
            reason: reason,
            operatorIdentifier: operatorIdentifier,
            operatorConfirmedAt: confirmedAt
        )
    }

    /// Leaf directories without any inventoried child have no file asset/delivery and therefore
    /// require an explicit operator decision before erase. Non-empty directories are represented
    /// by their descendant file obligations and the frozen inventory digest.
    public var emptyUserDirectoryPathsRequiringReview: Set<String> {
        let directories = inventory.filter {
            $0.type == .directory && $0.classification == .requiredByUser
        }.map(\.relativePath)
        return Set(directories.filter { directory in
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            return !inventory.contains { entry in
                entry.relativePath.hasPrefix(prefix) && entry.relativePath != directory
            }
        })
    }
}

public struct MediaScanner: Sendable {
    public static let systemMetadataAllowlistVersion = 2
    public static let systemMetadataAllowlistRules: [SystemMetadataAllowlistRule] = [
        SystemMetadataAllowlistRule(exactRelativePath: ".DS_Store", maximumByteSize: 1_048_576),
        SystemMetadataAllowlistRule(exactRelativePath: ".VolumeIcon.icns", maximumByteSize: 8_388_608),
    ]
    /// Compatibility view for UI display only. Classification uses the complete typed rules above.
    public static let systemMetadataAllowlist = Set(systemMetadataAllowlistRules.map(\.exactRelativePath))
    public static let systemMetadataAllowlistDigest: String = {
        let material = systemMetadataAllowlistRules.sorted { $0.exactRelativePath < $1.exactRelativePath }
        return (try? StableDigest.encode([String(systemMetadataAllowlistVersion), (try? StableDigest.encode(material)) ?? ""])) ?? ""
    }()

    public init() {}

    public static func matchesSystemMetadataAllowlist(
        relativePath: String,
        entryType: InventoryEntryType,
        byteSize: Int64,
        isMountedVolumeRoot: Bool
    ) -> Bool {
        guard isMountedVolumeRoot, byteSize >= 0 else { return false }
        return systemMetadataAllowlistRules.contains {
            $0.exactRelativePath == relativePath
                && $0.expectedType == entryType
                && byteSize <= $0.maximumByteSize
        }
    }

    public func scan(
        root: URL,
        sourceVolumeID: SourceVolumeID = SourceVolumeID(),
        policy: MediaScanPolicy? = nil
    ) async throws -> ScanResult {
        try Task.checkCancellation()
        try policy?.validate()
        let requestedRoot = root.standardizedFileURL
        var requestedStat = stat()
        let requestedStatus: Int32 = requestedRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &requestedStat)
        }
        guard requestedStatus == 0 else {
            throw UMISCoreError.posix(operation: "lstat scan root", code: errno, path: requestedRoot.path)
        }
        guard (requestedStat.st_mode & S_IFMT) != S_IFLNK else {
            throw UMISCoreError.symbolicLinkRejected(requestedRoot.path)
        }
        // Foundation can spell the same macOS temporary directory as `/var/...` for the root and
        // `/private/var/...` for enumerated descendants. POSIX realpath gives one stable spelling so
        // nested relative paths (and therefore deterministic asset IDs) cannot collapse to basenames.
        let root = try Self.canonicalExistingURL(requestedRoot)
        let rootIsMountedVolumeRoot = Self.isMountedVolumeRoot(root)
        let rootFingerprint = try FileFingerprint.capture(at: root)
        var rootStat = stat()
        let rootStatus: Int32 = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &rootStat)
        }
        guard rootStatus == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw UMISCoreError.invalidPath("Scan root is not a directory: \(root.path)")
        }
        _ = rootFingerprint

        var pending = [root]
        var assets: [MediaAsset] = []
        var inventory: [InventoryEntry] = []
        var issues: [ScanIssue] = []
        var directorySnapshots: [URL: FileFingerprint] = [:]
        let fileManager = FileManager.default

        while let directory = pending.popLast() {
            try Task.checkCancellation()
            directorySnapshots[directory] = try FileFingerprint.capture(at: directory)
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isPackageKey],
                    options: []
                ).sorted { $0.lastPathComponent.precomposedStringWithCanonicalMapping < $1.lastPathComponent.precomposedStringWithCanonicalMapping }
            } catch {
                let relative = Self.relativePath(of: directory, root: root)
                issues.append(ScanIssue(relativePath: relative, message: String(describing: error)))
                inventory.append(InventoryEntry(
                    relativePath: relative,
                    type: .directory,
                    classification: .unreadable,
                    byteSize: 0,
                    fingerprint: nil,
                    mediaAssetID: nil
                ))
                continue
            }

            for child in children {
                try Task.checkCancellation()
                let relative = Self.relativePath(of: child, root: root)
                var info = stat()
                let status: Int32 = child.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.lstat(path, &info)
                }
                guard status == 0 else {
                    issues.append(ScanIssue(relativePath: relative, message: "lstat failed with errno \(errno)"))
                    inventory.append(InventoryEntry(
                        relativePath: relative,
                        type: .other,
                        classification: .unreadable,
                        byteSize: 0,
                        fingerprint: nil,
                        mediaAssetID: nil
                    ))
                    continue
                }

                let mode = info.st_mode & S_IFMT
                if mode == S_IFLNK {
                    inventory.append(InventoryEntry(
                        relativePath: relative,
                        type: .symbolicLink,
                        classification: .unknown,
                        byteSize: Int64(info.st_size),
                        fingerprint: nil,
                        mediaAssetID: nil
                    ))
                    continue
                }

                if mode == S_IFDIR {
                    let isPackage = (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
                    inventory.append(InventoryEntry(
                        relativePath: relative,
                        type: .directory,
                        classification: isPackage ? .unknown : .requiredByUser,
                        byteSize: 0,
                        fingerprint: nil,
                        mediaAssetID: nil
                    ))
                    if !isPackage { pending.append(child) }
                    continue
                }

                guard mode == S_IFREG else {
                    inventory.append(InventoryEntry(
                        relativePath: relative,
                        type: .other,
                        classification: .unknown,
                        byteSize: Int64(info.st_size),
                        fingerprint: nil,
                        mediaAssetID: nil
                    ))
                    continue
                }

                let fingerprint = FileFingerprint(
                    device: UInt64(info.st_dev),
                    inode: UInt64(info.st_ino),
                    byteSize: Int64(info.st_size),
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
                )
                let classified = Self.classify(
                    pathExtension: child.pathExtension,
                    relativePath: relative,
                    byteSize: fingerprint.byteSize,
                    allowRootSystemMetadata: rootIsMountedVolumeRoot,
                    policy: policy
                )
                let kind = classified.kind
                let classification = classified.inventoryClassification

                var assetID: MediaAssetID?
                if classified.shouldCreateAsset {
                    let id = Self.assetID(sourceVolumeID: sourceVolumeID, relativePath: relative, fingerprint: fingerprint)
                    assetID = id
                    assets.append(MediaAsset(
                        id: id,
                        sourceVolumeID: sourceVolumeID,
                        relativePath: relative,
                        canonicalURL: child.standardizedFileURL,
                        originalName: child.lastPathComponent,
                        pathExtension: child.pathExtension,
                        byteSize: Int64(info.st_size),
                        modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                        kind: kind,
                        categoryID: classified.categoryID,
                        fingerprint: fingerprint
                    ))
                }
                inventory.append(InventoryEntry(
                    relativePath: relative,
                    type: .regularFile,
                    classification: classification,
                    byteSize: Int64(info.st_size),
                    fingerprint: fingerprint,
                    mediaAssetID: assetID
                ))
            }
        }

        var changedAssetIDs: Set<MediaAssetID> = []
        for asset in assets {
            do {
                if try FileFingerprint.capture(at: asset.canonicalURL) != asset.fingerprint {
                    changedAssetIDs.insert(asset.id)
                }
            } catch {
                changedAssetIDs.insert(asset.id)
            }
        }
        if !changedAssetIDs.isEmpty {
            assets.removeAll { changedAssetIDs.contains($0.id) }
            for index in inventory.indices where inventory[index].mediaAssetID.map(changedAssetIDs.contains) == true {
                inventory[index].classification = .changedDuringScan
                inventory[index].mediaAssetID = nil
                issues.append(ScanIssue(
                    relativePath: inventory[index].relativePath,
                    message: "Entry changed before the scan completed"
                ))
            }
        }
        for (directory, before) in directorySnapshots {
            do {
                guard try FileFingerprint.capture(at: directory) == before else {
                    let relative = Self.relativePath(of: directory, root: root)
                    inventory.append(InventoryEntry(
                        relativePath: relative,
                        type: .directory,
                        classification: .changedDuringScan,
                        byteSize: 0,
                        fingerprint: before,
                        mediaAssetID: nil
                    ))
                    issues.append(ScanIssue(relativePath: relative, message: "Directory contents changed during scan"))
                    continue
                }
            } catch {
                let relative = Self.relativePath(of: directory, root: root)
                inventory.append(InventoryEntry(
                    relativePath: relative,
                    type: .directory,
                    classification: .changedDuringScan,
                    byteSize: 0,
                    fingerprint: before,
                    mediaAssetID: nil
                ))
                issues.append(ScanIssue(relativePath: relative, message: "Directory disappeared during scan"))
            }
        }

        assets.sort { $0.relativePath.precomposedStringWithCanonicalMapping < $1.relativePath.precomposedStringWithCanonicalMapping }
        inventory.sort { $0.relativePath.precomposedStringWithCanonicalMapping < $1.relativePath.precomposedStringWithCanonicalMapping }
        issues.sort { $0.relativePath < $1.relativePath }
        let digestInput = inventory.map {
            "\($0.relativePath)|\($0.type.rawValue)|\($0.classification.rawValue)|\($0.byteSize)|\($0.fingerprint?.device ?? 0)|\($0.fingerprint?.inode ?? 0)|\($0.fingerprint?.modifiedSeconds ?? 0)|\($0.fingerprint?.modifiedNanoseconds ?? 0)"
        }
        let digest = try StableDigest.encode(digestInput)
        return ScanResult(
            root: root,
            sourceVolumeID: sourceVolumeID,
            assets: assets,
            inventory: inventory,
            issues: issues,
            inventoryDigest: digest
        )
    }

    /// Finder drag-and-drop scanner. It scans only the supplied files/folders, deduplicates overlapping
    /// selections by canonical path, never follows a selected symlink, and preserves unknown/error entries.
    public func scan(
        items: [URL],
        sourceVolumeID: SourceVolumeID = SourceVolumeID(),
        policy: MediaScanPolicy? = nil
    ) async throws -> ScanResult {
        guard !items.isEmpty else { throw UMISCoreError.emptyPlan }
        try policy?.validate()
        let uniqueInputs = Dictionary(grouping: items, by: { $0.standardizedFileURL.path })
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        let commonRoot = Self.commonAncestor(of: uniqueInputs.map {
            Self.isDirectoryNoFollow($0) ? $0.deletingLastPathComponent() : $0.deletingLastPathComponent()
        })
        var assets: [MediaAsset] = []
        var inventory: [InventoryEntry] = []
        var issues: [ScanIssue] = []
        var seenCanonicalPaths: Set<String> = []

        for input in uniqueInputs {
            try Task.checkCancellation()
            var value = stat()
            let result: Int32 = input.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &value)
            }
            let relativeInput = Self.relativePath(of: input.standardizedFileURL, root: commonRoot)
            guard result == 0 else {
                issues.append(ScanIssue(relativePath: relativeInput, message: "lstat failed with errno \(errno)"))
                inventory.append(InventoryEntry(
                    relativePath: relativeInput,
                    type: .other,
                    classification: .unreadable,
                    byteSize: 0,
                    fingerprint: nil,
                    mediaAssetID: nil
                ))
                continue
            }
            let mode = value.st_mode & S_IFMT
            if mode == S_IFLNK {
                inventory.append(InventoryEntry(
                    relativePath: relativeInput,
                    type: .symbolicLink,
                    classification: .unknown,
                    byteSize: Int64(value.st_size),
                    fingerprint: nil,
                    mediaAssetID: nil
                ))
                continue
            }
            if mode == S_IFDIR {
                let childResult = try await scan(root: input, sourceVolumeID: sourceVolumeID, policy: policy)
                let prefix = relativeInput.isEmpty ? "" : relativeInput + "/"
                for entry in childResult.inventory {
                    let relative = prefix + entry.relativePath
                    let canonicalPath = input.appendingPathComponent(entry.relativePath).standardizedFileURL.path
                    guard seenCanonicalPaths.insert(canonicalPath).inserted else { continue }
                    var rebased = entry
                    rebased.relativePath = relative
                    if let fingerprint = rebased.fingerprint, rebased.mediaAssetID != nil {
                        rebased.mediaAssetID = Self.assetID(
                            sourceVolumeID: sourceVolumeID,
                            relativePath: relative,
                            fingerprint: fingerprint
                        )
                    }
                    inventory.append(rebased)
                }
                for asset in childResult.assets {
                    let canonicalPath = asset.canonicalURL.standardizedFileURL.path
                    guard seenCanonicalPaths.contains(canonicalPath) else { continue }
                    let relative = prefix + asset.relativePath
                    var rebased = asset
                    rebased.relativePath = relative
                    rebased.id = Self.assetID(
                        sourceVolumeID: sourceVolumeID,
                        relativePath: relative,
                        fingerprint: asset.fingerprint
                    )
                    assets.append(rebased)
                }
                issues.append(contentsOf: childResult.issues.map {
                    ScanIssue(relativePath: prefix + $0.relativePath, message: $0.message)
                })
                continue
            }
            guard mode == S_IFREG else {
                inventory.append(InventoryEntry(
                    relativePath: relativeInput,
                    type: .other,
                    classification: .unknown,
                    byteSize: Int64(value.st_size),
                    fingerprint: nil,
                    mediaAssetID: nil
                ))
                continue
            }
            let canonical = input.standardizedFileURL
            guard seenCanonicalPaths.insert(canonical.path).inserted else { continue }
            let fingerprint = FileFingerprint(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                byteSize: Int64(value.st_size),
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
            )
            let classified = Self.classify(
                pathExtension: canonical.pathExtension,
                relativePath: relativeInput,
                byteSize: fingerprint.byteSize,
                allowRootSystemMetadata: false,
                policy: policy
            )
            let kind = classified.kind
            let classification = classified.inventoryClassification
            var mediaAssetID: MediaAssetID?
            if classified.shouldCreateAsset {
                let id = Self.assetID(sourceVolumeID: sourceVolumeID, relativePath: relativeInput, fingerprint: fingerprint)
                mediaAssetID = id
                assets.append(MediaAsset(
                    id: id,
                    sourceVolumeID: sourceVolumeID,
                    relativePath: relativeInput,
                    canonicalURL: canonical,
                    originalName: canonical.lastPathComponent,
                    pathExtension: canonical.pathExtension,
                    byteSize: fingerprint.byteSize,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(fingerprint.modifiedSeconds)),
                    kind: kind,
                    categoryID: classified.categoryID,
                    fingerprint: fingerprint
                ))
            }
            inventory.append(InventoryEntry(
                relativePath: relativeInput,
                type: .regularFile,
                classification: classification,
                byteSize: fingerprint.byteSize,
                fingerprint: fingerprint,
                mediaAssetID: mediaAssetID
            ))
        }

        assets = Dictionary(grouping: assets, by: \.canonicalURL).compactMap(\.value.first)
            .sorted { $0.relativePath < $1.relativePath }
        inventory.sort { $0.relativePath < $1.relativePath }
        issues.sort { $0.relativePath < $1.relativePath }
        let digest = try StableDigest.encode(inventory)
        return ScanResult(
            root: commonRoot,
            sourceVolumeID: sourceVolumeID,
            assets: assets,
            inventory: inventory,
            issues: issues,
            inventoryDigest: digest
        )
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootPath.count)).precomposedStringWithCanonicalMapping
    }

    private static func canonicalExistingURL(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved: Bool = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.realpath(path, &buffer) != nil
        }
        guard resolved else {
            throw UMISCoreError.posix(operation: "realpath scan root", code: errno, path: url.path)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    private static func isMountedVolumeRoot(_ url: URL) -> Bool {
        guard let volumeRoot = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
              let canonicalMount = try? canonicalExistingURL(volumeRoot) else {
            return false
        }
        return canonicalMount.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private struct ClassifiedFile {
        var kind: MediaKind
        var categoryID: ProjectCategoryID?
        var inventoryClassification: InventoryClassification
        var shouldCreateAsset: Bool
    }

    private static func classify(
        pathExtension: String,
        relativePath: String,
        byteSize: Int64,
        allowRootSystemMetadata: Bool,
        policy: MediaScanPolicy?
    ) -> ClassifiedFile {
        if matchesSystemMetadataAllowlist(
            relativePath: relativePath,
            entryType: .regularFile,
            byteSize: byteSize,
            isMountedVolumeRoot: allowRootSystemMetadata
        ) {
            return ClassifiedFile(
                kind: .other,
                categoryID: nil,
                inventoryClassification: .systemMetadataAllowlisted,
                shouldCreateAsset: false
            )
        }

        let kind: MediaKind
        let categoryID: ProjectCategoryID?
        let isEnabled: Bool
        let isRecognized: Bool
        if let policy {
            if let category = policy.category(forPathExtension: pathExtension) {
                kind = category.mediaKind
                categoryID = category.id
                isEnabled = category.isEnabled
                isRecognized = true
            } else if policy.sidecarExtensions.contains(MediaScanPolicy.normalizedExtension(pathExtension)) {
                kind = .sidecar
                categoryID = nil
                isEnabled = true
                isRecognized = true
            } else {
                kind = .other
                categoryID = nil
                isEnabled = false
                isRecognized = false
            }
        } else {
            kind = defaultMediaKind(pathExtension: pathExtension)
            categoryID = nil
            isEnabled = true
            isRecognized = kind != .other
        }

        guard isRecognized else {
            return ClassifiedFile(
                kind: .other,
                categoryID: nil,
                inventoryClassification: .unknown,
                shouldCreateAsset: false
            )
        }
        let classification: InventoryClassification
        if let policy, policy.containsHiddenComponent(relativePath: relativePath) {
            classification = .hiddenEntryNeedsReview
        } else if let policy, policy.containsExcludedFolder(relativePath: relativePath) {
            classification = .excludedFolderNeedsReview
        } else if !isEnabled {
            classification = .disabledByPolicyNeedsReview
        } else if kind == .sidecar {
            classification = .requiredCompanion
        } else {
            classification = .requiredByUser
        }
        return ClassifiedFile(
            kind: kind,
            categoryID: categoryID,
            inventoryClassification: classification,
            shouldCreateAsset: true
        )
    }

    private static func defaultMediaKind(pathExtension: String) -> MediaKind {
        let ext = pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts"].contains(ext) { return .movie }
        if ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp"].contains(ext) { return .photo }
        if ["cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "dng"].contains(ext) { return .rawPhoto }
        if ["wav", "aif", "aiff", "m4a", "mp3", "flac", "bwf"].contains(ext) { return .audio }
        if ["xmp", "xml", "thm", "srt", "lrv", "aae"].contains(ext) { return .sidecar }
        return .other
    }

    private static func assetID(
        sourceVolumeID: SourceVolumeID,
        relativePath: String,
        fingerprint: FileFingerprint
    ) -> MediaAssetID {
        let stableKey = [
            sourceVolumeID.rawValue.uuidString,
            relativePath.precomposedStringWithCanonicalMapping,
            String(fingerprint.device),
            String(fingerprint.inode),
            String(fingerprint.byteSize),
            String(fingerprint.modifiedSeconds),
            String(fingerprint.modifiedNanoseconds),
        ].joined(separator: "|")
        return MediaAssetID.deterministic(stableKey: stableKey)
    }

    private static func isDirectoryNoFollow(_ url: URL) -> Bool {
        var value = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &value)
        }
        return result == 0 && (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func commonAncestor(of urls: [URL]) -> URL {
        guard var components = urls.first?.standardizedFileURL.pathComponents else {
            return URL(fileURLWithPath: "/")
        }
        for url in urls.dropFirst() {
            let candidate = url.standardizedFileURL.pathComponents
            var common = 0
            while common < min(components.count, candidate.count), components[common] == candidate[common] {
                common += 1
            }
            components = Array(components.prefix(common))
        }
        return components.reduce(URL(fileURLWithPath: "/")) { partial, component in
            component == "/" ? partial : partial.appendingPathComponent(component, isDirectory: true)
        }
    }
}
