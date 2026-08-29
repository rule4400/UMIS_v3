import Foundation

public enum CanonicalIngestEventType: String, Codable, CaseIterable, Sendable {
    case cardDetected
    case assignmentResolved
    case ingestPlanned
    case ingestStarted
    case ingestVerified
    case ingestFailed
    case ingestCancelled
    case eraseStarted
    case eraseSucceeded
    case eraseFailed
    case cardReadyForReuse
}

public enum IngestVerificationAlgorithm: String, Codable, Sendable {
    case sha256
    case sha256Manifest
}

public enum IngestVerificationResult: String, Codable, Sendable {
    case verified
    case failed
    case cancelled
    case notApplicable
}

public enum IngestEventPrivacyProfile: String, Codable, Sendable {
    /// Excludes paths, filenames, media, per-file hashes, hardware serials,
    /// local account/network identifiers, and every erase authorization value.
    case minimalV1
}

public enum CanonicalIngestEventError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case invalidJobSequence
    case duplicateSceneID(RemoteSceneID)
    case scenesNotCanonicallyOrdered
    case catalogProjectMismatch
}

/// Privacy-minimized, deterministic integration event.
///
/// Its schema has no property capable of carrying an absolute/relative path,
/// filename list, per-file digest, hardware serial, or erase authorization.
public struct CanonicalIngestEvent: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion: UInt16 = 1

    public let eventID: UUID
    public let eventSchemaVersion: UInt16
    public let jobID: UUID
    public let jobSequence: UInt64
    public let projectID: UUID
    public let cardNo: CardNo
    public let cardBindingID: UUID
    public let photographerID: RemotePhotographerID?
    public let sceneIDs: [RemoteSceneID]
    public let catalogVersion: CatalogVersionRef?
    public let eventType: CanonicalIngestEventType
    public let fileCount: UInt64?
    public let totalBytes: UInt64?
    public let verificationAlgorithm: IngestVerificationAlgorithm?
    public let verificationResult: IngestVerificationResult?
    public let manifestDigest: SHA256Value?
    public let occurredAtUTC: CanonicalTimestamp
    public let privacyProfile: IngestEventPrivacyProfile

    public var id: UUID { eventID }

    public init(
        eventID: UUID = UUID(),
        eventSchemaVersion: UInt16 = CanonicalIngestEvent.currentSchemaVersion,
        jobID: UUID,
        jobSequence: UInt64,
        projectID: UUID,
        cardNo: CardNo,
        cardBindingID: UUID,
        photographerID: RemotePhotographerID?,
        sceneIDs: [RemoteSceneID],
        catalogVersion: CatalogVersionRef?,
        eventType: CanonicalIngestEventType,
        fileCount: UInt64? = nil,
        totalBytes: UInt64? = nil,
        verificationAlgorithm: IngestVerificationAlgorithm? = nil,
        verificationResult: IngestVerificationResult? = nil,
        manifestDigest: SHA256Value? = nil,
        occurredAtUTC: CanonicalTimestamp,
        privacyProfile: IngestEventPrivacyProfile = .minimalV1
    ) throws {
        let orderedSceneIDs = sceneIDs.sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        self.eventID = eventID
        self.eventSchemaVersion = eventSchemaVersion
        self.jobID = jobID
        self.jobSequence = jobSequence
        self.projectID = projectID
        self.cardNo = cardNo
        self.cardBindingID = cardBindingID
        self.photographerID = photographerID
        self.sceneIDs = orderedSceneIDs
        self.catalogVersion = catalogVersion
        self.eventType = eventType
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.verificationAlgorithm = verificationAlgorithm
        self.verificationResult = verificationResult
        self.manifestDigest = manifestDigest
        self.occurredAtUTC = occurredAtUTC
        self.privacyProfile = privacyProfile
        try validate()
    }

    public func validate() throws {
        guard eventSchemaVersion == Self.currentSchemaVersion else {
            throw CanonicalIngestEventError.unsupportedSchemaVersion(eventSchemaVersion)
        }
        guard jobSequence > 0 else { throw CanonicalIngestEventError.invalidJobSequence }
        guard Set(sceneIDs).count == sceneIDs.count else {
            var seen = Set<RemoteSceneID>()
            for sceneID in sceneIDs where !seen.insert(sceneID).inserted {
                throw CanonicalIngestEventError.duplicateSceneID(sceneID)
            }
            preconditionFailure("duplicate count invariant")
        }
        guard sceneIDs == sceneIDs.sorted(by: {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }) else {
            throw CanonicalIngestEventError.scenesNotCanonicallyOrdered
        }
        if let catalogVersion, catalogVersion.projectID != projectID {
            throw CanonicalIngestEventError.catalogProjectMismatch
        }
    }

    public func canonicalBytes() throws -> Data {
        try validate()
        return CanonicalJSON.encode(.object([
            "cardBindingID": .string(cardBindingID.uuidString.lowercased()),
            "cardNo": .string(cardNo.rawValue),
            "catalogVersionRef": canonicalCatalogVersion,
            "eventID": .string(eventID.uuidString.lowercased()),
            "eventSchemaVersion": .unsigned(UInt64(eventSchemaVersion)),
            "eventType": .string(eventType.rawValue),
            "fileCount": fileCount.map(CanonicalJSONValue.unsigned) ?? .null,
            "jobID": .string(jobID.uuidString.lowercased()),
            "jobSequence": .unsigned(jobSequence),
            "manifestDigest": manifestDigest.map { .string($0.hex) } ?? .null,
            "occurredAtUTC": .string(occurredAtUTC.rawValue),
            "photographerID": photographerID.map { .string($0.rawValue) } ?? .null,
            "privacyProfile": .string(privacyProfile.rawValue),
            "projectID": .string(projectID.uuidString.lowercased()),
            "sceneIDs": .array(sceneIDs.map { .string($0.rawValue) }),
            "totalBytes": totalBytes.map(CanonicalJSONValue.unsigned) ?? .null,
            "verificationAlgorithm": verificationAlgorithm.map { .string($0.rawValue) } ?? .null,
            "verificationResult": verificationResult.map { .string($0.rawValue) } ?? .null,
        ]))
    }

    public func payloadDigest() throws -> SHA256Value {
        SHA256Value.hash(try canonicalBytes())
    }

    private var canonicalCatalogVersion: CanonicalJSONValue {
        guard let catalogVersion else { return .null }
        return .object([
            "authorityEpoch": .string(catalogVersion.authorityEpoch.uuidString.lowercased()),
            "authorityID": .string(catalogVersion.authorityID.uuidString.lowercased()),
            "catalogID": .string(catalogVersion.catalogID.uuidString.lowercased()),
            "payloadDigest": .string(catalogVersion.payloadDigest.hex),
            "projectID": .string(catalogVersion.projectID.uuidString.lowercased()),
            "revision": .unsigned(catalogVersion.revision),
        ])
    }
}
