import CryptoKit
import Darwin
import Foundation

/// UMISCore-neutral witness binding locally persisted scenes to one verified LAN catalog version.
/// UMISNetwork maps `CatalogVersionRef` into this value; Core never depends on network types.
public struct SceneCatalogVersionWitness: Codable, Hashable, Sendable {
    public var projectID: ProjectID
    public var catalogID: UUID
    public var authorityID: UUID
    public var authorityEpoch: UUID
    public var revision: UInt64
    public var payloadDigest: String

    public init(
        projectID: ProjectID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        revision: UInt64,
        payloadDigest: String
    ) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.revision = revision
        self.payloadDigest = payloadDigest.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, catalogID, authorityID, authorityEpoch, revision, payloadDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try values.decode(ProjectID.self, forKey: .projectID)
        catalogID = try values.decode(UUID.self, forKey: .catalogID)
        authorityID = try values.decode(UUID.self, forKey: .authorityID)
        authorityEpoch = try values.decode(UUID.self, forKey: .authorityEpoch)
        revision = try values.decode(UInt64.self, forKey: .revision)
        payloadDigest = try values.decode(String.self, forKey: .payloadDigest).lowercased()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(catalogID, forKey: .catalogID)
        try values.encode(authorityID, forKey: .authorityID)
        try values.encode(authorityEpoch, forKey: .authorityEpoch)
        try values.encode(revision, forKey: .revision)
        try values.encode(payloadDigest.lowercased(), forKey: .payloadDigest)
    }

    /// Upper/lower/mixed-case input is accepted and canonicalized to lowercase. Eligibility still
    /// requires exactly 64 hexadecimal characters that decode to exactly 32 SHA-256 bytes.
    public var decodedPayloadDigest: Data? {
        let bytes = Array(payloadDigest.utf8)
        guard bytes.count == 64 else { return nil }
        var decoded = Data(capacity: 32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = Self.hexNibble(bytes[offset]),
                  let low = Self.hexNibble(bytes[offset + 1]) else { return nil }
            decoded.append((high << 4) | low)
        }
        return decoded.count == 32 ? decoded : nil
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 65 + 10
        case 97 ... 102: byte - 97 + 10
        default: nil
        }
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var id: ProjectID
    public var name: String
    public var schemaVersion: Int
    public var destination: URL?
    public var photographers: [Photographer]
    public var scenes: [Scene]
    public var settings: ProjectSettings
    public var sceneCatalogVersionWitness: SceneCatalogVersionWitness?

    public init(
        id: ProjectID = ProjectID(),
        name: String,
        schemaVersion: Int = 1,
        destination: URL? = nil,
        photographers: [Photographer] = [],
        scenes: [Scene] = [],
        settings: ProjectSettings = ProjectSettings(),
        sceneCatalogVersionWitness: SceneCatalogVersionWitness? = nil
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
        self.destination = destination
        self.photographers = photographers
        self.scenes = scenes
        self.settings = settings
        self.sceneCatalogVersionWitness = sceneCatalogVersionWitness
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, schemaVersion, destination, photographers, scenes, settings, sceneCatalogVersionWitness
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ProjectID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        destination = try values.decodeIfPresent(URL.self, forKey: .destination)
        photographers = try values.decodeIfPresent([Photographer].self, forKey: .photographers) ?? []
        scenes = try values.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
        settings = try values.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        sceneCatalogVersionWitness = try values.decodeIfPresent(
            SceneCatalogVersionWitness.self,
            forKey: .sceneCatalogVersionWitness
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encodeIfPresent(destination, forKey: .destination)
        try values.encode(photographers, forKey: .photographers)
        try values.encode(scenes, forKey: .scenes)
        try values.encode(settings, forKey: .settings)
        try values.encodeIfPresent(sceneCatalogVersionWitness, forKey: .sceneCatalogVersionWitness)
    }
}

public struct Photographer: Codable, Hashable, Sendable {
    public var id: PhotographerID
    public var displayName: String
    public var isArchived: Bool

    public init(id: PhotographerID = PhotographerID(), displayName: String, isArchived: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isArchived = isArchived
    }
}

public struct ProjectCategory: Codable, Hashable, Sendable {
    public var id: ProjectCategoryID
    public var displayName: String
    public var folderName: String
    public var extensions: Set<String>
    public var mediaKind: MediaKind
    public var isEnabled: Bool
    public var sortOrder: Int

    public init(
        id: ProjectCategoryID = ProjectCategoryID(),
        displayName: String,
        folderName: String,
        extensions: Set<String>,
        mediaKind: MediaKind = .other,
        isEnabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.folderName = folderName
        self.extensions = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        self.mediaKind = mediaKind
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, folderName, extensions, mediaKind, isEnabled, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ProjectCategoryID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        folderName = try values.decode(String.self, forKey: .folderName)
        extensions = Set(try values.decode(Set<String>.self, forKey: .extensions).map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })
        mediaKind = try values.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .other
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(folderName, forKey: .folderName)
        try values.encode(extensions, forKey: .extensions)
        try values.encode(mediaKind, forKey: .mediaKind)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(sortOrder, forKey: .sortOrder)
    }
}

public struct ProjectLocation: Codable, Hashable, Sendable {
    public var id: ProjectLocationID
    public var displayName: String
    public var code: String?
    public var isArchived: Bool

    public init(
        id: ProjectLocationID = ProjectLocationID(),
        displayName: String,
        code: String? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.code = code
        self.isArchived = isArchived
    }
}

public struct CardDefinition: Codable, Hashable, Sendable {
    public var id: CardDefinitionID
    public var cardNumber: String
    public var photographerID: PhotographerID?
    public var isActive: Bool

    public init(
        id: CardDefinitionID = CardDefinitionID(),
        cardNumber: String,
        photographerID: PhotographerID? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.cardNumber = cardNumber
        self.photographerID = photographerID
        self.isActive = isActive
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var locations: [ProjectLocation]
    public var selectedLocationID: ProjectLocationID?
    public var categories: [ProjectCategory]
    public var cardDefinitions: [CardDefinition]
    public var renameRule: RenameRule
    public var sidecarExtensions: Set<String>
    public var includeHiddenFiles: Bool
    public var excludedFolderNames: Set<String>

    public init(
        schemaVersion: Int = 1,
        locations: [ProjectLocation] = [],
        selectedLocationID: ProjectLocationID? = nil,
        categories: [ProjectCategory] = [],
        cardDefinitions: [CardDefinition] = [],
        renameRule: RenameRule = RenameRule(),
        sidecarExtensions: Set<String> = ["xmp", "xml", "thm", "srt", "wav", "lrv", "aae"],
        includeHiddenFiles: Bool = false,
        excludedFolderNames: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.locations = locations
        self.selectedLocationID = selectedLocationID
        self.categories = categories
        self.cardDefinitions = cardDefinitions
        self.renameRule = renameRule
        self.sidecarExtensions = Set(sidecarExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        self.includeHiddenFiles = includeHiddenFiles
        self.excludedFolderNames = Set(excludedFolderNames.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, locations, selectedLocationID, categories, cardDefinitions, renameRule
        case sidecarExtensions, includeHiddenFiles, excludedFolderNames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            locations: try values.decodeIfPresent([ProjectLocation].self, forKey: .locations) ?? [],
            selectedLocationID: try values.decodeIfPresent(ProjectLocationID.self, forKey: .selectedLocationID),
            categories: try values.decodeIfPresent([ProjectCategory].self, forKey: .categories) ?? [],
            cardDefinitions: try values.decodeIfPresent([CardDefinition].self, forKey: .cardDefinitions) ?? [],
            renameRule: try values.decodeIfPresent(RenameRule.self, forKey: .renameRule) ?? RenameRule(),
            sidecarExtensions: try values.decodeIfPresent(Set<String>.self, forKey: .sidecarExtensions)
                ?? ["xmp", "xml", "thm", "srt", "wav", "lrv", "aae"],
            includeHiddenFiles: try values.decodeIfPresent(Bool.self, forKey: .includeHiddenFiles) ?? false,
            excludedFolderNames: try values.decodeIfPresent(Set<String>.self, forKey: .excludedFolderNames) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(locations, forKey: .locations)
        try values.encodeIfPresent(selectedLocationID, forKey: .selectedLocationID)
        try values.encode(categories, forKey: .categories)
        try values.encode(cardDefinitions, forKey: .cardDefinitions)
        try values.encode(renameRule, forKey: .renameRule)
        try values.encode(sidecarExtensions, forKey: .sidecarExtensions)
        try values.encode(includeHiddenFiles, forKey: .includeHiddenFiles)
        try values.encode(excludedFolderNames, forKey: .excludedFolderNames)
    }
}

public struct Scene: Codable, Hashable, Sendable {
    public var id: SceneID
    public var projectID: ProjectID
    public var displayName: String
    public var code: String?
    public var day: Int?
    public var sortOrder: Int
    public var entityVersion: Int
    public var isArchived: Bool

    public init(
        id: SceneID = SceneID(),
        projectID: ProjectID,
        displayName: String,
        code: String? = nil,
        day: Int? = nil,
        sortOrder: Int = 0,
        entityVersion: Int = 1,
        isArchived: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.displayName = displayName
        self.code = code
        self.day = day
        self.sortOrder = sortOrder
        self.entityVersion = entityVersion
        self.isArchived = isArchived
    }
}

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case movie
    case photo
    case rawPhoto
    case audio
    case sidecar
    case other
}

public struct FileFingerprint: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var byteSize: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        byteSize: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.byteSize = byteSize
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    public static func capture(at url: URL, followSymbolicLinks: Bool = false) throws -> FileFingerprint {
        var value = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &value, followSymbolicLinks ? 0 : AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw UMISCoreError.posix(operation: followSymbolicLinks ? "stat" : "lstat", code: errno, path: url.path)
        }
        return FileFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteSize: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

public struct MediaAsset: Codable, Hashable, Sendable {
    public var id: MediaAssetID
    public var sourceVolumeID: SourceVolumeID
    public var relativePath: String
    public var canonicalURL: URL
    public var originalName: String
    public var pathExtension: String
    public var byteSize: Int64
    public var modifiedAt: Date?
    public var capturedAt: Date?
    public var kind: MediaKind
    public var categoryID: ProjectCategoryID?
    public var fingerprint: FileFingerprint

    public init(
        id: MediaAssetID = MediaAssetID(),
        sourceVolumeID: SourceVolumeID,
        relativePath: String,
        canonicalURL: URL,
        originalName: String,
        pathExtension: String,
        byteSize: Int64,
        modifiedAt: Date? = nil,
        capturedAt: Date? = nil,
        kind: MediaKind,
        categoryID: ProjectCategoryID? = nil,
        fingerprint: FileFingerprint
    ) {
        self.id = id
        self.sourceVolumeID = sourceVolumeID
        self.relativePath = relativePath
        self.canonicalURL = canonicalURL
        self.originalName = originalName
        self.pathExtension = pathExtension
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.capturedAt = capturedAt
        self.kind = kind
        self.categoryID = categoryID
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceVolumeID, relativePath, canonicalURL, originalName, pathExtension, byteSize
        case modifiedAt, capturedAt, kind, categoryID, fingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(MediaAssetID.self, forKey: .id)
        sourceVolumeID = try values.decode(SourceVolumeID.self, forKey: .sourceVolumeID)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        canonicalURL = try values.decode(URL.self, forKey: .canonicalURL)
        originalName = try values.decode(String.self, forKey: .originalName)
        pathExtension = try values.decode(String.self, forKey: .pathExtension)
        byteSize = try values.decode(Int64.self, forKey: .byteSize)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt)
        capturedAt = try values.decodeIfPresent(Date.self, forKey: .capturedAt)
        kind = try values.decode(MediaKind.self, forKey: .kind)
        categoryID = try values.decodeIfPresent(ProjectCategoryID.self, forKey: .categoryID)
        fingerprint = try values.decode(FileFingerprint.self, forKey: .fingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sourceVolumeID, forKey: .sourceVolumeID)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(canonicalURL, forKey: .canonicalURL)
        try values.encode(originalName, forKey: .originalName)
        try values.encode(pathExtension, forKey: .pathExtension)
        try values.encode(byteSize, forKey: .byteSize)
        try values.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try values.encodeIfPresent(capturedAt, forKey: .capturedAt)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(categoryID, forKey: .categoryID)
        try values.encode(fingerprint, forKey: .fingerprint)
    }
}

/// Deterministic source grouping for camera companions. No mutable relationship metadata is
/// persisted: a group is always recomputed from the source-relative directory and Unicode-
/// normalized filename stem, so decoded plans cannot silently detach a sidecar from its primary.
public enum MediaCompanionGrouping {
    /// Returns a portable, case/width-insensitive key for a scanner-produced asset. Invalid stored
    /// relative paths return `nil` and are rejected by `IngestPlan.validate()`.
    public static func groupKey(for asset: MediaAsset) -> String? {
        try? validatedGroupKey(relativePath: asset.relativePath)
    }

    /// Expands one UI selection to every primary/companion sharing its deterministic source group.
    /// An unknown asset ID produces an empty set rather than accidentally selecting unrelated data.
    public static func assetIDs(
        sharingGroupWith assetID: MediaAssetID,
        in assets: [MediaAsset]
    ) -> Set<MediaAssetID> {
        guard let selected = assets.first(where: { $0.id == assetID }),
              let selectedKey = groupKey(for: selected) else { return [] }
        return Set(assets.compactMap { asset in
            groupKey(for: asset) == selectedKey ? asset.id : nil
        })
    }

    /// Resolves output ownership for a complete selected asset set. A source stem is shared only
    /// when the set contains exactly one non-sidecar primary and one or more sidecars. Equal-stem
    /// primaries without a sidecar remain independent logical outputs. Invalid sidecar-only and
    /// ambiguous multi-primary companion sets fail before a preview or ingest plan can be shown.
    public static func layout(
        for assets: [MediaAsset]
    ) throws -> [MediaCompanionLayoutMember] {
        guard Set(assets.map(\.id)).count == assets.count else {
            throw UMISCoreError.invalidPlan("Companion layout contains duplicate media asset IDs")
        }
        var membersBySourceGroup: [String: [MediaAsset]] = [:]
        for asset in assets {
            let sourceGroup = try validatedGroupKey(relativePath: asset.relativePath)
            membersBySourceGroup[sourceGroup, default: []].append(asset)
        }

        var resolvedByAssetID: [MediaAssetID: MediaCompanionLayoutMember] = [:]
        for (sourceGroup, members) in membersBySourceGroup {
            let companions = members.filter { $0.kind == .sidecar }
            if companions.isEmpty {
                for member in members {
                    resolvedByAssetID[member.id] = MediaCompanionLayoutMember(
                        assetID: member.id,
                        primaryAssetID: member.id,
                        sourceGroupKey: sourceGroup,
                        logicalOutputGroupKey: sourceGroup + "|" + member.id.rawValue.uuidString,
                        sharesPrimaryOutput: false
                    )
                }
                continue
            }

            let primaries = members.filter { $0.kind != .sidecar }
            guard primaries.count == 1, let primary = primaries.first else {
                throw UMISCoreError.invalidPlan(
                    primaries.isEmpty
                        ? "A sidecar-only group cannot be planned without its primary asset"
                        : "A sidecar group has multiple ambiguous primary assets"
                )
            }
            for member in members {
                resolvedByAssetID[member.id] = MediaCompanionLayoutMember(
                    assetID: member.id,
                    primaryAssetID: primary.id,
                    sourceGroupKey: sourceGroup,
                    logicalOutputGroupKey: sourceGroup,
                    sharesPrimaryOutput: true
                )
            }
        }

        return try assets.map { asset in
            guard let resolved = resolvedByAssetID[asset.id] else {
                throw UMISCoreError.invalidPlan("Companion layout is incomplete")
            }
            return resolved
        }
    }

    fileprivate static func validatedGroupKey(relativePath: String) throws -> String {
        let normalizedPath = relativePath.precomposedStringWithCanonicalMapping
        let components = normalizedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !normalizedPath.isEmpty,
              !normalizedPath.hasPrefix("/"),
              !normalizedPath.hasSuffix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let filename = components.last else {
            throw UMISCoreError.invalidPlan(
                "Media asset has an invalid source-relative path for companion grouping"
            )
        }
        let stem = (filename as NSString).deletingPathExtension
            .precomposedStringWithCanonicalMapping
        guard !stem.isEmpty, stem != ".", stem != ".." else {
            throw UMISCoreError.invalidPlan("Media asset has an empty companion-group stem")
        }
        let directory = components.dropLast().joined(separator: "/")
        let path = directory.isEmpty ? stem : directory + "/" + stem
        return PathSafety.portableCollisionKey(path)
    }
}

public struct MediaCompanionLayoutMember: Hashable, Sendable {
    public var assetID: MediaAssetID
    public var primaryAssetID: MediaAssetID
    public var sourceGroupKey: String
    public var logicalOutputGroupKey: String
    public var sharesPrimaryOutput: Bool

    public init(
        assetID: MediaAssetID,
        primaryAssetID: MediaAssetID,
        sourceGroupKey: String,
        logicalOutputGroupKey: String,
        sharesPrimaryOutput: Bool
    ) {
        self.assetID = assetID
        self.primaryAssetID = primaryAssetID
        self.sourceGroupKey = sourceGroupKey
        self.logicalOutputGroupKey = logicalOutputGroupKey
        self.sharesPrimaryOutput = sharesPrimaryOutput
    }
}

public struct Assignment: Codable, Hashable, Sendable {
    public var id: AssignmentID
    public var assetID: MediaAssetID
    public var sceneID: SceneID
    public var revision: Int

    public init(id: AssignmentID = AssignmentID(), assetID: MediaAssetID, sceneID: SceneID, revision: Int = 1) {
        self.id = id
        self.assetID = assetID
        self.sceneID = sceneID
        self.revision = revision
    }
}

public enum VolumeIdentityStrength: String, Codable, Sendable {
    case strongForCurrentInsertion
    case weak
    case unknown
}

public enum PhysicalMediaClassification: String, Codable, Sendable {
    case secureDigitalCard
    case genericUSBStorage
    case solidStateDrive
    case hardDiskDrive
    case signedHardwareProfile
    case unknown
}

public enum PhysicalMediaEvidenceProvenance: String, Codable, Sendable {
    case diskArbitrationAndIOKit
    case unavailable
}

/// Normalized, security-bound evidence produced by the App's Disk Arbitration/IOKit adapter.
/// Vendor/model strings alone never establish camera-card eligibility.
public struct PhysicalMediaEvidence: Codable, Hashable, Sendable {
    public var classification: PhysicalMediaClassification
    public var provenance: PhysicalMediaEvidenceProvenance
    public var transportProtocol: String?
    public var interconnectLocation: String?
    public var mediaType: String?
    public var vendor: String?
    public var model: String?
    public var registryClassChain: [String]
    /// Reserved boundary for a future product-signed hardware profile verifier. A non-empty value
    /// does not grant eligibility in the current build.
    public var signedHardwareProfileID: String?

    public init(
        classification: PhysicalMediaClassification,
        provenance: PhysicalMediaEvidenceProvenance,
        transportProtocol: String? = nil,
        interconnectLocation: String? = nil,
        mediaType: String? = nil,
        vendor: String? = nil,
        model: String? = nil,
        registryClassChain: [String] = [],
        signedHardwareProfileID: String? = nil
    ) {
        self.classification = classification
        self.provenance = provenance
        self.transportProtocol = transportProtocol
        self.interconnectLocation = interconnectLocation
        self.mediaType = mediaType
        self.vendor = vendor
        self.model = model
        self.registryClassChain = registryClassChain
        self.signedHardwareProfileID = signedHardwareProfileID
    }

    public static let unknown = PhysicalMediaEvidence(
        classification: .unknown,
        provenance: .unavailable
    )

    public var hasTrustedCameraCardProof: Bool {
        guard classification == .secureDigitalCard,
              provenance == .diskArbitrationAndIOKit else { return false }
        let normalizedClasses = registryClassChain.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        }
        // Generic USB mass-storage/card-reader strings are intentionally insufficient. Current
        // eligibility is limited to a native Apple Secure Digital registry class chain; external
        // readers require a future product-signed hardware profile.
        let trustedRegistryClass = normalizedClasses.contains { value in
            value.contains("iosd") || value.contains("applesdxc") || value.contains("sdhost")
        }
        let mediaSignals = [transportProtocol, mediaType]
            .compactMap { $0?.precomposedStringWithCanonicalMapping.lowercased() }
        let secureDigitalSignal = mediaSignals.contains { signal in
            signal.contains("secure digital")
                || signal.contains("sd card")
                || signal.contains("sdxc")
                || signal.contains("sdhc")
        }
        return trustedRegistryClass && secureDigitalSignal
    }
}

public struct VolumeIdentity: Codable, Hashable, Sendable {
    public var id: SourceVolumeID
    public var volumeUUID: UUID?
    public var mediaUUID: UUID?
    public var mediaRegistryEntryID: UInt64?
    public var parentChainDigest: String?
    public var bsdName: String?
    public var wholeDiskBSDName: String?
    public var mountURL: URL?
    public var displayName: String
    public var capacityBytes: Int64
    /// POSIX `st_dev` observed for the mounted volume root during identity resolution.
    public var volumeDeviceIdentifier: UInt64?
    public var physicalMediaEvidence: PhysicalMediaEvidence?
    public var blockSize: Int64?
    public var fileSystem: String?
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isWritable: Bool
    public var isNetwork: Bool
    public var isDiskImage: Bool
    public var partitionCount: Int
    public var arrivalGeneration: UUID
    public var identityStrength: VolumeIdentityStrength

    public init(
        id: SourceVolumeID = SourceVolumeID(),
        volumeUUID: UUID? = nil,
        mediaUUID: UUID? = nil,
        mediaRegistryEntryID: UInt64? = nil,
        parentChainDigest: String? = nil,
        bsdName: String? = nil,
        wholeDiskBSDName: String? = nil,
        mountURL: URL? = nil,
        displayName: String,
        capacityBytes: Int64,
        volumeDeviceIdentifier: UInt64? = nil,
        physicalMediaEvidence: PhysicalMediaEvidence? = nil,
        blockSize: Int64? = nil,
        fileSystem: String? = nil,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        isWritable: Bool,
        isNetwork: Bool,
        isDiskImage: Bool,
        partitionCount: Int = 1,
        arrivalGeneration: UUID = UUID(),
        identityStrength: VolumeIdentityStrength
    ) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.mediaUUID = mediaUUID
        self.mediaRegistryEntryID = mediaRegistryEntryID
        self.parentChainDigest = parentChainDigest
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.mountURL = mountURL
        self.displayName = displayName
        self.capacityBytes = capacityBytes
        self.volumeDeviceIdentifier = volumeDeviceIdentifier
        self.physicalMediaEvidence = physicalMediaEvidence
        self.blockSize = blockSize
        self.fileSystem = fileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isWritable = isWritable
        self.isNetwork = isNetwork
        self.isDiskImage = isDiskImage
        self.partitionCount = partitionCount
        self.arrivalGeneration = arrivalGeneration
        self.identityStrength = identityStrength
    }

    /// A digest suitable for equality checks and audit correlation; never a user-facing identifier.
    public var securityDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func isSamePhysicalInsertion(as other: VolumeIdentity) -> Bool {
        securityDigest == other.securityDigest
    }

    public var isCameraCardEraseEligible: Bool {
        physicalMediaEvidence?.hasTrustedCameraCardProof == true
            && mediaUUID != nil
            && capacityBytes > 0
    }

    /// Returns the stable, non-reversible key used to carry an unknown destructive outcome across
    /// mount-session IDs and application restarts. `SourceVolumeID`, BSD names, volume UUIDs, and
    /// arrival generations are deliberately excluded because each can change after a remount or
    /// format. Media without a trusted Secure Digital classification and a whole-media UUID is not
    /// eligible for destructive use in this build.
    public func physicalQuarantineKey() throws -> PhysicalMediaQuarantineKey {
        guard physicalMediaEvidence?.hasTrustedCameraCardProof == true,
              let mediaUUID,
              capacityBytes > 0 else {
            throw UMISCoreError.unsafeEraseTarget(
                "A trusted whole-media UUID and Secure Digital hardware proof are required for durable quarantine"
            )
        }
        let material = [
            "UMIS-PHYSICAL-QUARANTINE-v1",
            mediaUUID.uuidString.lowercased(),
            String(capacityBytes),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try PhysicalMediaQuarantineKey(rawValue: digest)
    }
}

/// Opaque SHA-256 correlation key for a physical card. It is safe to persist and does not expose
/// the card's media UUID. There is intentionally no public API for clearing a quarantine by key.
public struct PhysicalMediaQuarantineKey: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }) else {
            throw UMISCoreError.invalidPlan("Physical quarantine key must be a 32-byte SHA-256 digest")
        }
        self.rawValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum DestinationBackingKind: String, Codable, Sendable {
    case physicalDevice
    case networkMount
    case diskImage
    case virtualDevice
    case unknown
}

public enum DestinationBackingEvidenceProvenance: String, Codable, Sendable {
    /// Foundation reports an internal local volume. External destinations require the stronger
    /// Disk Arbitration + diskutil provenance below.
    case foundationInternalVolume
    case diskArbitrationAndDiskutil
    case networkMountLifecycle
    case unknown
}

public struct DestinationBackingEvidence: Codable, Hashable, Sendable {
    public var kind: DestinationBackingKind
    public var provenance: DestinationBackingEvidenceProvenance
    public var backingStoreIdentifier: String?

    public init(
        kind: DestinationBackingKind,
        provenance: DestinationBackingEvidenceProvenance,
        backingStoreIdentifier: String? = nil
    ) {
        self.kind = kind
        self.provenance = provenance
        self.backingStoreIdentifier = backingStoreIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let unknown = DestinationBackingEvidence(
        kind: .unknown,
        provenance: .unknown
    )

    public var hasTrustedLocalPhysicalProof: Bool {
        guard kind == .physicalDevice,
              backingStoreIdentifier?.isEmpty == false else { return false }
        return provenance == .foundationInternalVolume
            || provenance == .diskArbitrationAndDiskutil
    }
}

/// Fresh observation supplied by the app's network-mount lifecycle monitor. Core binds its
/// authority and generation into every network destination identity; inventing/reusing a UUID in
/// `revalidate` is not a freshness proof. A remount must be published as a new generation.
public struct NetworkMountLifecycleWitness: Codable, Hashable, Sendable {
    public var authorityID: UUID
    public var generation: UUID

    public init(authorityID: UUID, generation: UUID) {
        self.authorityID = authorityID
        self.generation = generation
    }
}

public struct DestinationIdentity: Codable, Hashable, Sendable {
    public var id: DestinationID
    public var rootURL: URL
    public var volumeIdentifier: String?
    public var fileSystem: String?
    public var rootFileIdentifier: String?
    /// POSIX `st_dev` for the destination root. This is required for local erase-grade independence proof.
    public var volumeDeviceIdentifier: UInt64?
    public var mountGeneration: UUID
    public var networkMountLifecycleAuthorityID: UUID?
    public var isNetwork: Bool
    public var isWritable: Bool
    public var durabilityProfileID: String?
    /// Erase-grade proof of the destination's actual backing store. Missing legacy values decode as
    /// `.unknown`, preserving copy compatibility while failing card initialization closed.
    public var backingEvidence: DestinationBackingEvidence

    public init(
        id: DestinationID = DestinationID(),
        rootURL: URL,
        volumeIdentifier: String? = nil,
        fileSystem: String? = nil,
        rootFileIdentifier: String? = nil,
        volumeDeviceIdentifier: UInt64? = nil,
        mountGeneration: UUID = UUID(),
        networkMountLifecycleAuthorityID: UUID? = nil,
        isNetwork: Bool = false,
        isWritable: Bool = true,
        durabilityProfileID: String? = nil,
        backingEvidence: DestinationBackingEvidence = .unknown
    ) {
        self.id = id
        self.rootURL = rootURL
        self.volumeIdentifier = volumeIdentifier
        self.fileSystem = fileSystem
        self.rootFileIdentifier = rootFileIdentifier
        self.volumeDeviceIdentifier = volumeDeviceIdentifier
        self.mountGeneration = mountGeneration
        self.networkMountLifecycleAuthorityID = networkMountLifecycleAuthorityID
        self.isNetwork = isNetwork
        self.isWritable = isWritable
        self.durabilityProfileID = durabilityProfileID
        self.backingEvidence = backingEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, rootURL, volumeIdentifier, fileSystem, rootFileIdentifier, volumeDeviceIdentifier, mountGeneration
        case networkMountLifecycleAuthorityID
        case isNetwork, isWritable, durabilityProfileID, backingEvidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(DestinationID.self, forKey: .id)
        rootURL = try values.decode(URL.self, forKey: .rootURL)
        volumeIdentifier = try values.decodeIfPresent(String.self, forKey: .volumeIdentifier)
        fileSystem = try values.decodeIfPresent(String.self, forKey: .fileSystem)
        rootFileIdentifier = try values.decodeIfPresent(String.self, forKey: .rootFileIdentifier)
        volumeDeviceIdentifier = try values.decodeIfPresent(UInt64.self, forKey: .volumeDeviceIdentifier)
        mountGeneration = try values.decodeIfPresent(UUID.self, forKey: .mountGeneration) ?? UUID()
        networkMountLifecycleAuthorityID = try values.decodeIfPresent(
            UUID.self,
            forKey: .networkMountLifecycleAuthorityID
        )
        isNetwork = try values.decodeIfPresent(Bool.self, forKey: .isNetwork) ?? false
        isWritable = try values.decodeIfPresent(Bool.self, forKey: .isWritable) ?? true
        durabilityProfileID = try values.decodeIfPresent(String.self, forKey: .durabilityProfileID)
        backingEvidence = try values.decodeIfPresent(
            DestinationBackingEvidence.self,
            forKey: .backingEvidence
        ) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(rootURL, forKey: .rootURL)
        try values.encodeIfPresent(volumeIdentifier, forKey: .volumeIdentifier)
        try values.encodeIfPresent(fileSystem, forKey: .fileSystem)
        try values.encodeIfPresent(rootFileIdentifier, forKey: .rootFileIdentifier)
        try values.encodeIfPresent(volumeDeviceIdentifier, forKey: .volumeDeviceIdentifier)
        try values.encode(mountGeneration, forKey: .mountGeneration)
        try values.encodeIfPresent(
            networkMountLifecycleAuthorityID,
            forKey: .networkMountLifecycleAuthorityID
        )
        try values.encode(isNetwork, forKey: .isNetwork)
        try values.encode(isWritable, forKey: .isWritable)
        try values.encodeIfPresent(durabilityProfileID, forKey: .durabilityProfileID)
        try values.encode(backingEvidence, forKey: .backingEvidence)
    }


    public var hasCopyGradeIdentity: Bool {
        let baseIdentity = volumeIdentifier?.isEmpty == false
            && fileSystem?.isEmpty == false
            && rootFileIdentifier?.isEmpty == false
            && volumeDeviceIdentifier != nil
            && isWritable
        guard baseIdentity else { return false }
        if isNetwork {
            return networkMountLifecycleAuthorityID != nil
                && backingEvidence.kind == .networkMount
                && backingEvidence.provenance == .networkMountLifecycle
                && backingEvidence.backingStoreIdentifier?.isEmpty == false
        }
        return true
    }

    public var hasEraseGradeIdentity: Bool {
        guard hasCopyGradeIdentity else { return false }
        if isNetwork {
            return backingEvidence.kind == .networkMount
                && backingEvidence.provenance == .networkMountLifecycle
                && backingEvidence.backingStoreIdentifier?.isEmpty == false
                && DestinationDurabilityProfileRegistry.isApprovedForErase(durabilityProfileID)
        }
        return backingEvidence.hasTrustedLocalPhysicalProof
    }
}

public struct RequiredDelivery: Codable, Hashable, Sendable {
    public var assetID: MediaAssetID
    public var destinationID: DestinationID

    public init(assetID: MediaAssetID, destinationID: DestinationID) {
        self.assetID = assetID
        self.destinationID = destinationID
    }
}

public struct ExplicitExclusionEvidence: Codable, Hashable, Sendable {
    public var assetID: MediaAssetID
    public var relativePath: String
    public var byteSize: Int64
    public var reason: String
    public var operatorIdentifier: String
    public var operatorConfirmedAt: Date

    public init(
        assetID: MediaAssetID,
        relativePath: String,
        byteSize: Int64,
        reason: String,
        operatorIdentifier: String,
        operatorConfirmedAt: Date = Date()
    ) throws {
        let normalizedPath = relativePath.precomposedStringWithCanonicalMapping
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOperator = operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty, !normalizedPath.hasPrefix("/"), byteSize >= 0,
              !normalizedReason.isEmpty, normalizedReason.count <= 1_000,
              !normalizedOperator.isEmpty, normalizedOperator.count <= 256,
              operatorConfirmedAt.timeIntervalSince1970 > 0 else {
            throw UMISCoreError.invalidPlan("Explicit exclusion evidence is incomplete")
        }
        self.assetID = assetID
        self.relativePath = normalizedPath
        self.byteSize = byteSize
        self.reason = normalizedReason
        self.operatorIdentifier = normalizedOperator
        self.operatorConfirmedAt = operatorConfirmedAt
    }

    public var isComplete: Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && byteSize >= 0
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && operatorConfirmedAt.timeIntervalSince1970 > 0
    }
}

/// Operator decision for an empty source directory that has no file delivery obligation. Empty
/// directory structure is never silently discarded before card initialization.
public struct ExplicitDirectoryExclusionEvidence: Codable, Hashable, Sendable {
    public var relativePath: String
    public var reason: String
    public var operatorIdentifier: String
    public var operatorConfirmedAt: Date

    public init(
        relativePath: String,
        reason: String,
        operatorIdentifier: String,
        operatorConfirmedAt: Date = Date()
    ) throws {
        let path = relativePath.precomposedStringWithCanonicalMapping
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let operatorIdentifier = operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !reason.isEmpty, reason.count <= 1_000,
              !operatorIdentifier.isEmpty, operatorIdentifier.count <= 256,
              operatorConfirmedAt.timeIntervalSince1970 > 0 else {
            throw UMISCoreError.invalidPlan("Empty-directory exclusion evidence is incomplete")
        }
        self.relativePath = path
        self.reason = reason
        self.operatorIdentifier = operatorIdentifier
        self.operatorConfirmedAt = operatorConfirmedAt
    }

    public var isComplete: Bool {
        !relativePath.isEmpty
            && !relativePath.hasPrefix("/")
            && !relativePath.hasSuffix("/")
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && operatorConfirmedAt.timeIntervalSince1970 > 0
    }
}

public struct RequiredSet: Codable, Hashable, Sendable {
    public var assetIDs: Set<MediaAssetID>
    public var deliveries: Set<RequiredDelivery>
    public var explicitlyExcludedAssetIDs: Set<MediaAssetID>
    public var explicitExclusions: [ExplicitExclusionEvidence]
    public var explicitDirectoryExclusions: [ExplicitDirectoryExclusionEvidence]
    public var unresolvedDirectoryEntryCount: Int
    public var exclusionsReviewed: Bool
    public var unknownEntryCount: Int
    public var unreadableEntryCount: Int
    public var changedEntryCount: Int
    public var inventoryDigest: String
    public var systemMetadataAllowlistDigest: String

    public init(
        assetIDs: Set<MediaAssetID>,
        deliveries: Set<RequiredDelivery>,
        explicitlyExcludedAssetIDs: Set<MediaAssetID> = [],
        explicitExclusions: [ExplicitExclusionEvidence] = [],
        explicitDirectoryExclusions: [ExplicitDirectoryExclusionEvidence] = [],
        unresolvedDirectoryEntryCount: Int = 0,
        exclusionsReviewed: Bool = true,
        unknownEntryCount: Int = 0,
        unreadableEntryCount: Int = 0,
        changedEntryCount: Int = 0,
        inventoryDigest: String,
        systemMetadataAllowlistDigest: String
    ) {
        self.assetIDs = assetIDs
        self.deliveries = deliveries
        self.explicitlyExcludedAssetIDs = explicitlyExcludedAssetIDs
        self.explicitExclusions = explicitExclusions
        self.explicitDirectoryExclusions = explicitDirectoryExclusions
        self.unresolvedDirectoryEntryCount = unresolvedDirectoryEntryCount
        self.exclusionsReviewed = exclusionsReviewed
        self.unknownEntryCount = unknownEntryCount
        self.unreadableEntryCount = unreadableEntryCount
        self.changedEntryCount = changedEntryCount
        self.inventoryDigest = inventoryDigest
        self.systemMetadataAllowlistDigest = systemMetadataAllowlistDigest
    }

    private enum CodingKeys: String, CodingKey {
        case assetIDs, deliveries, explicitlyExcludedAssetIDs, explicitExclusions
        case explicitDirectoryExclusions, unresolvedDirectoryEntryCount, exclusionsReviewed
        case unknownEntryCount, unreadableEntryCount, changedEntryCount
        case inventoryDigest, systemMetadataAllowlistDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assetIDs = Set(try values.decode([MediaAssetID].self, forKey: .assetIDs))
        deliveries = Set(try values.decode([RequiredDelivery].self, forKey: .deliveries))
        explicitlyExcludedAssetIDs = Set(
            try values.decodeIfPresent([MediaAssetID].self, forKey: .explicitlyExcludedAssetIDs) ?? []
        )
        explicitExclusions = try values.decodeIfPresent(
            [ExplicitExclusionEvidence].self,
            forKey: .explicitExclusions
        ) ?? []
        explicitDirectoryExclusions = try values.decodeIfPresent(
            [ExplicitDirectoryExclusionEvidence].self,
            forKey: .explicitDirectoryExclusions
        ) ?? []
        // Stored pre-directory-audit Required Sets cannot authorize erase until rescanned/reviewed.
        unresolvedDirectoryEntryCount = try values.decodeIfPresent(
            Int.self,
            forKey: .unresolvedDirectoryEntryCount
        ) ?? 1
        exclusionsReviewed = try values.decodeIfPresent(Bool.self, forKey: .exclusionsReviewed) ?? false
        unknownEntryCount = try values.decodeIfPresent(Int.self, forKey: .unknownEntryCount) ?? 0
        unreadableEntryCount = try values.decodeIfPresent(Int.self, forKey: .unreadableEntryCount) ?? 0
        changedEntryCount = try values.decodeIfPresent(Int.self, forKey: .changedEntryCount) ?? 0
        inventoryDigest = try values.decode(String.self, forKey: .inventoryDigest)
        systemMetadataAllowlistDigest = try values.decode(String.self, forKey: .systemMetadataAllowlistDigest)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(assetIDs.sorted(by: Self.assetOrder), forKey: .assetIDs)
        try values.encode(deliveries.sorted(by: Self.deliveryOrder), forKey: .deliveries)
        try values.encode(explicitlyExcludedAssetIDs.sorted(by: Self.assetOrder), forKey: .explicitlyExcludedAssetIDs)
        try values.encode(
            explicitExclusions.sorted { $0.assetID.rawValue.uuidString < $1.assetID.rawValue.uuidString },
            forKey: .explicitExclusions
        )
        try values.encode(
            explicitDirectoryExclusions.sorted { $0.relativePath < $1.relativePath },
            forKey: .explicitDirectoryExclusions
        )
        try values.encode(unresolvedDirectoryEntryCount, forKey: .unresolvedDirectoryEntryCount)
        try values.encode(exclusionsReviewed, forKey: .exclusionsReviewed)
        try values.encode(unknownEntryCount, forKey: .unknownEntryCount)
        try values.encode(unreadableEntryCount, forKey: .unreadableEntryCount)
        try values.encode(changedEntryCount, forKey: .changedEntryCount)
        try values.encode(inventoryDigest, forKey: .inventoryDigest)
        try values.encode(systemMetadataAllowlistDigest, forKey: .systemMetadataAllowlistDigest)
    }

    private static func assetOrder(_ lhs: MediaAssetID, _ rhs: MediaAssetID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }

    private static func deliveryOrder(_ lhs: RequiredDelivery, _ rhs: RequiredDelivery) -> Bool {
        let left = lhs.assetID.rawValue.uuidString + "|" + lhs.destinationID.rawValue.uuidString
        let right = rhs.assetID.rawValue.uuidString + "|" + rhs.destinationID.rawValue.uuidString
        return left < right
    }

    public var isStructurallyEligibleForErase: Bool {
        !assetIDs.isEmpty
            && !deliveries.isEmpty
            && Set(deliveries.map(\.assetID)) == assetIDs
            && deliveries.count == assetIDs.count
            && hasAuditedExplicitExclusions
            && unresolvedDirectoryEntryCount == 0
            && hasAuditedDirectoryExclusions
            && unknownEntryCount == 0
            && unreadableEntryCount == 0
            && changedEntryCount == 0
            && exclusionsReviewed
    }

    public var hasAuditedExplicitExclusions: Bool {
        let evidenceIDs = explicitExclusions.map(\.assetID)
        return Set(evidenceIDs) == explicitlyExcludedAssetIDs
            && evidenceIDs.count == explicitlyExcludedAssetIDs.count
            && explicitExclusions.allSatisfy(\.isComplete)
    }

    public var hasAuditedDirectoryExclusions: Bool {
        let paths = explicitDirectoryExclusions.map(\.relativePath)
        return paths.count == Set(paths).count
            && explicitDirectoryExclusions.allSatisfy(\.isComplete)
    }
}

public enum DuplicatePolicy: String, Codable, Sendable {
    /// Any existing destination is a blocking collision.
    case block
    /// An existing destination may satisfy an obligation only after a fresh full-file verification.
    case verifyIdentical
    /// The planner produces a deterministic suffixed name. The copy engine still never replaces files.
    case deterministicSuffix
}

public struct IngestPlanItem: Codable, Hashable, Sendable {
    public var id: IngestItemID
    public var asset: MediaAsset
    public var scene: Scene?
    public var sourceURL: URL
    public var finalURL: URL
    public var expectedSourceFingerprint: FileFingerprint
    public var expectedContentSHA256: String?
    public var duplicatePolicy: DuplicatePolicy

    public init(
        id: IngestItemID = IngestItemID(),
        asset: MediaAsset,
        scene: Scene? = nil,
        sourceURL: URL,
        finalURL: URL,
        expectedSourceFingerprint: FileFingerprint,
        expectedContentSHA256: String? = nil,
        duplicatePolicy: DuplicatePolicy = .block
    ) {
        self.id = id
        self.asset = asset
        self.scene = scene
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.expectedSourceFingerprint = expectedSourceFingerprint
        self.expectedContentSHA256 = expectedContentSHA256
        self.duplicatePolicy = duplicatePolicy
    }
}

public struct IngestPlan: Codable, Hashable, Sendable {
    public var runID: IngestRunID
    public var project: Project
    public var sourceVolume: VolumeIdentity
    public var destination: DestinationIdentity
    public var requiredSet: RequiredSet
    /// Frozen scanner policy used to produce `requiredSet.inventoryDigest`. Final erase verification
    /// must rescan with exactly this policy; `nil` preserves the built-in compatibility classifier.
    public var scanPolicy: MediaScanPolicy?
    public var createdAt: Date
    public var items: [IngestPlanItem]

    public init(
        runID: IngestRunID = IngestRunID(),
        project: Project,
        sourceVolume: VolumeIdentity,
        destination: DestinationIdentity,
        requiredSet: RequiredSet,
        scanPolicy: MediaScanPolicy? = nil,
        createdAt: Date = Date(),
        items: [IngestPlanItem]
    ) {
        self.runID = runID
        self.project = project
        self.sourceVolume = sourceVolume
        self.destination = destination
        self.requiredSet = requiredSet
        self.scanPolicy = scanPolicy
        self.createdAt = createdAt
        self.items = items
    }

    public func validate() throws {
        try scanPolicy?.validate()
        if sourceVolume.identityStrength == .strongForCurrentInsertion {
            try VolumeIndependenceValidator.validate(
                source: sourceVolume,
                destination: destination,
                assurance: .copyGrade
            )
        }
        guard !items.isEmpty else { throw UMISCoreError.emptyPlan }
        guard requiredSet.isStructurallyEligibleForErase || !requiredSet.assetIDs.isEmpty else {
            throw UMISCoreError.emptyRequiredSet
        }
        let itemAssetIDs = Set(items.map(\.asset.id))
        guard itemAssetIDs.count == items.count else {
            throw UMISCoreError.invalidPlan("Frozen plan contains duplicate asset obligations")
        }
        guard requiredSet.assetIDs == itemAssetIDs else {
            throw UMISCoreError.invalidPlan("Frozen plan items must exactly cover the Required Asset Set")
        }
        let deliveryAssetIDs = Set(requiredSet.deliveries.map(\.assetID))
        guard deliveryAssetIDs == requiredSet.assetIDs,
              requiredSet.deliveries.count == requiredSet.assetIDs.count else {
            throw UMISCoreError.invalidPlan("Every required asset must have exactly one delivery obligation")
        }
        guard requiredSet.deliveries.allSatisfy({ $0.destinationID == destination.id }) else {
            throw UMISCoreError.invalidPlan("Required delivery is bound to a different destination")
        }
        guard requiredSet.explicitlyExcludedAssetIDs.isDisjoint(with: requiredSet.assetIDs) else {
            throw UMISCoreError.invalidPlan("An excluded asset cannot remain in the Required Asset Set")
        }
        let itemIDs = items.map(\.id)
        guard Set(itemIDs).count == itemIDs.count else {
            throw UMISCoreError.invalidPlan("Duplicate ingest item ID")
        }
        let normalizedDestinations = try items.map {
            try PathSafety.validateRelativeDestination($0.finalURL, under: destination.rootURL)
        }
        let destinationCollisionKeys = normalizedDestinations.map(PathSafety.portableCollisionKey)
        guard Set(destinationCollisionKeys).count == destinationCollisionKeys.count else {
            throw UMISCoreError.collision("The frozen plan contains colliding destination paths")
        }
        try validateCompanionIntegrity(destinationRelativePaths: normalizedDestinations)
        for item in items {
            try PathSafety.requireDescendant(item.finalURL, of: destination.rootURL)
        }
    }

    private func validateCompanionIntegrity(
        destinationRelativePaths: [String]
    ) throws {
        var membersBySourceGroup: [String: [CompanionPlanMember]] = [:]
        for (item, destinationRelativePath) in zip(items, destinationRelativePaths) {
            guard item.asset.sourceVolumeID == sourceVolume.id,
                  item.sourceURL.standardizedFileURL == item.asset.canonicalURL.standardizedFileURL,
                  item.expectedSourceFingerprint == item.asset.fingerprint else {
                throw UMISCoreError.invalidPlan(
                    "Ingest item is not bound to its frozen companion asset and source identity"
                )
            }

            let sourcePath = item.asset.relativePath.precomposedStringWithCanonicalMapping
            let sourceComponents = sourcePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let sourceFilename = sourceComponents.last,
                  sourceFilename.precomposedStringWithCanonicalMapping
                    == item.asset.originalName.precomposedStringWithCanonicalMapping else {
                throw UMISCoreError.invalidPlan(
                    "Media asset filename does not match its source-relative path"
                )
            }
            let sourceExtension = (sourceFilename as NSString).pathExtension
            guard PathSafety.portableCollisionKey(sourceExtension)
                == PathSafety.portableCollisionKey(item.asset.pathExtension) else {
                throw UMISCoreError.invalidPlan(
                    "Media asset extension does not match its source-relative path"
                )
            }
            try validateCompanionClassification(item.asset, sourceExtension: sourceExtension)

            let destinationComponents = destinationRelativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let destinationFilename = destinationComponents.last else {
                throw UMISCoreError.invalidPlan("Companion destination filename is missing")
            }
            let destinationStem = (destinationFilename as NSString).deletingPathExtension
                .precomposedStringWithCanonicalMapping
            let destinationExtension = (destinationFilename as NSString).pathExtension
            guard !destinationStem.isEmpty,
                  PathSafety.portableCollisionKey(destinationExtension)
                    == PathSafety.portableCollisionKey(item.asset.pathExtension) else {
                throw UMISCoreError.invalidPlan(
                    "A companion delivery must preserve its source file extension"
                )
            }
            let destinationParent = destinationComponents.dropLast()
                .joined(separator: "/")
                .precomposedStringWithCanonicalMapping
            let destinationGroupPath = destinationParent.isEmpty
                ? destinationStem
                : destinationParent + "/" + destinationStem
            let member = CompanionPlanMember(
                item: item,
                sourceGroupKey: try MediaCompanionGrouping.validatedGroupKey(
                    relativePath: item.asset.relativePath
                ),
                destinationParent: destinationParent,
                destinationStem: destinationStem,
                destinationGroupKey: PathSafety.portableCollisionKey(destinationGroupPath)
            )
            membersBySourceGroup[member.sourceGroupKey, default: []].append(member)
        }

        // Destination group ownership is stricter than full-path collision detection: two source
        // groups may use different extensions yet still merge into one ambiguous companion set.
        let layout = try MediaCompanionGrouping.layout(for: items.map(\.asset))
        let layoutByAssetID = Dictionary(
            uniqueKeysWithValues: layout.map { ($0.assetID, $0) }
        )
        var destinationOwner: [String: String] = [:]
        func registerDestination(_ member: CompanionPlanMember, owner: String) throws {
            if let existing = destinationOwner[member.destinationGroupKey], existing != owner {
                throw UMISCoreError.collision(
                    "Multiple source groups resolve to one destination companion group"
                )
            }
            destinationOwner[member.destinationGroupKey] = owner
        }

        for members in membersBySourceGroup.values {
            guard let first = members.first,
                  let firstLayout = layoutByAssetID[first.item.asset.id] else {
                throw UMISCoreError.invalidPlan("Companion layout is missing a plan member")
            }
            if !firstLayout.sharesPrimaryOutput {
                for member in members {
                    guard let memberLayout = layoutByAssetID[member.item.asset.id] else {
                        throw UMISCoreError.invalidPlan("Companion layout is incomplete")
                    }
                    try registerDestination(member, owner: memberLayout.logicalOutputGroupKey)
                }
                continue
            }
            guard let primary = members.first(where: {
                $0.item.asset.id == firstLayout.primaryAssetID
            }) else {
                throw UMISCoreError.invalidPlan("Companion layout primary is missing")
            }
            guard members.allSatisfy({ member in
                member.item.scene == primary.item.scene
                    && member.destinationParent == primary.destinationParent
                    && member.destinationStem == primary.destinationStem
                    && member.destinationGroupKey == primary.destinationGroupKey
            }) else {
                throw UMISCoreError.invalidPlan(
                    "Every companion must share its primary scene, sequence, output stem, and final parent"
                )
            }
            try registerDestination(primary, owner: firstLayout.logicalOutputGroupKey)
        }
    }

    private func validateCompanionClassification(
        _ asset: MediaAsset,
        sourceExtension: String
    ) throws {
        let normalizedExtension = sourceExtension.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let expectedKind: MediaKind?
        if let scanPolicy {
            let category = scanPolicy.categoryRules
                .sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                }
                .first { category in
                    category.extensions.contains { candidate in
                        candidate.precomposedStringWithCanonicalMapping
                            .lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            == normalizedExtension
                    }
                }
            if let category {
                expectedKind = category.mediaKind
            } else if scanPolicy.sidecarExtensions.contains(normalizedExtension) {
                expectedKind = .sidecar
            } else {
                expectedKind = nil
            }
        } else if ["xmp", "xml", "thm", "srt", "lrv", "aae"].contains(normalizedExtension) {
            expectedKind = .sidecar
        } else {
            expectedKind = nil
        }
        guard expectedKind == nil || expectedKind == asset.kind else {
            throw UMISCoreError.invalidPlan(
                "Media asset kind does not match the frozen scan policy classification"
            )
        }
    }
}

private struct CompanionPlanMember {
    var item: IngestPlanItem
    var sourceGroupKey: String
    var destinationParent: String
    var destinationStem: String
    var destinationGroupKey: String
}

public enum DeliveryState: String, Codable, Sendable {
    case durableCommitted
    case durableVerifiedExisting
}

public struct DeliveryReceipt: Codable, Hashable, Sendable {
    public var itemID: IngestItemID
    public var assetID: MediaAssetID
    public var destinationID: DestinationID
    public var finalURL: URL
    public var byteSize: Int64
    public var sourceSHA256: String
    public var destinationSHA256: String
    public var finalFingerprint: FileFingerprint
    public var state: DeliveryState
    public var committedAt: Date

    public init(
        itemID: IngestItemID,
        assetID: MediaAssetID,
        destinationID: DestinationID,
        finalURL: URL,
        byteSize: Int64,
        sourceSHA256: String,
        destinationSHA256: String,
        finalFingerprint: FileFingerprint,
        state: DeliveryState,
        committedAt: Date = Date()
    ) {
        self.itemID = itemID
        self.assetID = assetID
        self.destinationID = destinationID
        self.finalURL = finalURL
        self.byteSize = byteSize
        self.sourceSHA256 = sourceSHA256
        self.destinationSHA256 = destinationSHA256
        self.finalFingerprint = finalFingerprint
        self.state = state
        self.committedAt = committedAt
    }
}

public struct IngestReceipt: Codable, Hashable, Sendable {
    public var runID: IngestRunID
    public var sourceIdentityDigest: String
    public var requiredSetDigest: String
    public var deliveries: [DeliveryReceipt]
    public var completedAt: Date

    public init(
        runID: IngestRunID,
        sourceIdentityDigest: String,
        requiredSetDigest: String,
        deliveries: [DeliveryReceipt],
        completedAt: Date = Date()
    ) {
        self.runID = runID
        self.sourceIdentityDigest = sourceIdentityDigest
        self.requiredSetDigest = requiredSetDigest
        self.deliveries = deliveries
        self.completedAt = completedAt
    }
}

public enum UMISCoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case posix(operation: String, code: Int32, path: String)
    case sqlite(code: Int32, message: String)
    case notRegularFile(String)
    case symbolicLinkRejected(String)
    case sourceChanged(String)
    case hashMismatch(String)
    case collision(String)
    case invalidPath(String)
    case invalidPlan(String)
    case emptyPlan
    case emptyRequiredSet
    case cancelled
    case journalMissing(String)
    case eraseNotEligible(String)
    case invalidToken
    case expiredToken
    case reusedToken
    case identityChanged
    case unsafeEraseTarget(String)
    case backendFailure(String)

    public var description: String {
        switch self {
        case let .posix(operation, code, path): "\(operation) failed (errno \(code)): \(path)"
        case let .sqlite(code, message): "SQLite error \(code): \(message)"
        case let .notRegularFile(path): "Not a regular file: \(path)"
        case let .symbolicLinkRejected(path): "Symbolic link rejected: \(path)"
        case let .sourceChanged(path): "Source changed: \(path)"
        case let .hashMismatch(path): "SHA-256 mismatch: \(path)"
        case let .collision(path): "Destination collision: \(path)"
        case let .invalidPath(message): "Invalid path: \(message)"
        case let .invalidPlan(message): "Invalid plan: \(message)"
        case .emptyPlan: "The plan has no items"
        case .emptyRequiredSet: "The Required Set is empty"
        case .cancelled: "Operation cancelled"
        case let .journalMissing(id): "Journal entry not found: \(id)"
        case let .eraseNotEligible(reason): "Erase is not eligible: \(reason)"
        case .invalidToken: "Erase token is invalid"
        case .expiredToken: "Erase token has expired"
        case .reusedToken: "Erase token has already been consumed"
        case .identityChanged: "Physical media identity changed"
        case let .unsafeEraseTarget(reason): "Unsafe erase target: \(reason)"
        case let .backendFailure(reason): "Erase backend failed: \(reason)"
        }
    }
}

public enum PathSafety {
    private static let windowsReservedBaseNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CLOCK$"]
        for index in 1 ... 9 {
            names.insert("COM\(index)")
            names.insert("LPT\(index)")
        }
        return names
    }()

    public static func requireDescendant(_ candidate: URL, of root: URL) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix), candidatePath != rootPath else {
            throw UMISCoreError.invalidPath("Path escapes its declared root: \(candidate.path)")
        }
    }

    public static func validateComponent(_ component: String) throws -> String {
        let normalized = component.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, normalized != ".", normalized != ".." else {
            throw UMISCoreError.invalidPath("Empty or reserved component")
        }
        guard !normalized.hasPrefix(".") else {
            throw UMISCoreError.invalidPath("Dot-prefixed names are reserved for system/application metadata")
        }
        guard normalized == normalized.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw UMISCoreError.invalidPath("Leading or trailing whitespace")
        }
        guard !normalized.hasSuffix("."), !normalized.hasSuffix(" ") else {
            throw UMISCoreError.invalidPath("Trailing dot or space is not portable")
        }
        guard normalized.utf8.count <= 255 else {
            throw UMISCoreError.invalidPath("Path component exceeds 255 UTF-8 bytes")
        }
        let portableForbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
        guard !normalized.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0) || portableForbidden.contains($0)
        }) else {
            throw UMISCoreError.invalidPath("Windows/NAS separator, reserved punctuation, NUL, or control character")
        }
        let baseName = normalized.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? normalized
        let reservedKey = baseName.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).uppercased()
        guard !windowsReservedBaseNames.contains(reservedKey) else {
            throw UMISCoreError.invalidPath("Windows reserved device name: \(baseName)")
        }
        return normalized
    }

    /// Validates every component below a destination root and returns the NFC relative spelling.
    @discardableResult
    public static func validateRelativeDestination(_ candidate: URL, under root: URL) throws -> String {
        try requireDescendant(candidate, of: root)
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relative = String(candidatePath.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
            throw UMISCoreError.invalidPath("Destination contains an empty path component")
        }
        return try components.map { try validateComponent(String($0)) }.joined(separator: "/")
    }

    /// NFC + locale-independent case/width folding used for fail-closed SMB/APFS collision checks.
    public static func portableCollisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}

public enum StableDigest {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
