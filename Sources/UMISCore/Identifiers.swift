import CryptoKit
import Foundation

/// Domain identifiers are deliberately independent from display names and array order.
public protocol UMISIdentifier: RawRepresentable, Hashable, Codable, Sendable
where RawValue == UUID {
    init(rawValue: UUID)
}

public extension UMISIdentifier {
    init() { self.init(rawValue: UUID()) }
}

public struct ProjectID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SceneID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct MediaAssetID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct AssignmentID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SourceVolumeID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct IngestRunID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct IngestItemID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct DestinationID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct RenameTransactionID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct PhotographerID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ProjectCategoryID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ProjectLocationID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct CardDefinitionID: UMISIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

public extension MediaAssetID {
    /// UUIDv5-shaped identifier derived from a mount-session scoped file identity.
    /// It remains stable across rescans of an unchanged entry without turning a path or name into identity.
    static func deterministic(stableKey: String) -> MediaAssetID {
        var bytes = Array(SHA256.hash(data: Data(stableKey.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return MediaAssetID(rawValue: uuid)
    }
}

public extension PhotographerID {
    static func deterministic(stableKey: String) -> PhotographerID {
        PhotographerID(rawValue: StableUUID.make(stableKey: stableKey))
    }
}

public extension ProjectID {
    static func deterministic(stableKey: String) -> ProjectID {
        ProjectID(rawValue: StableUUID.make(stableKey: stableKey))
    }
}

enum StableUUID {
    static func make(stableKey: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(stableKey.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
