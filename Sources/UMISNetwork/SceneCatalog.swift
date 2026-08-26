import CryptoKit
import Foundation

public enum SceneLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case archived
    case tombstone
}

public struct SceneRecord: Codable, Hashable, Sendable, Identifiable {
    public let projectID: UUID
    public let sceneID: UUID
    public var dayIndex: Int
    public var dayLabel: String
    public var sceneNumber: String
    public var name: String
    public var sortKey: String
    public var entityVersion: UInt64
    public var lifecycle: SceneLifecycle

    public var id: UUID { sceneID }

    public init(
        projectID: UUID,
        sceneID: UUID,
        dayIndex: Int,
        dayLabel: String,
        sceneNumber: String,
        name: String,
        sortKey: String,
        entityVersion: UInt64,
        lifecycle: SceneLifecycle
    ) {
        self.projectID = projectID
        self.sceneID = sceneID
        self.dayIndex = dayIndex
        self.dayLabel = dayLabel
        self.sceneNumber = sceneNumber
        self.name = name
        self.sortKey = sortKey
        self.entityVersion = entityVersion
        self.lifecycle = lifecycle
    }
}

public enum SceneCatalogSchemaLimits {
    public static let maximumSceneCount = 10_000
    public static let maximumDayIndex = Int(Int32.max)
    public static let maximumDayLabelUTF8Bytes = 256
    public static let maximumSceneNumberUTF8Bytes = 128
    public static let maximumNameUTF8Bytes = 1_024
    public static let maximumSortKeyUTF8Bytes = 512
}

public enum SceneCatalogSchemaError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(UInt16)
    case unsupportedSchemaVersion(UInt16)
    case tooManyScenes(actual: Int)
    case sceneProjectMismatch(sceneID: UUID)
    case duplicateSceneID(UUID)
    case invalidDayIndex(sceneID: UUID, value: Int)
    case invalidEntityVersion(sceneID: UUID)
    case stringNotNFC(sceneID: UUID, field: String)
    case stringContainsControlCharacter(sceneID: UUID, field: String)
    case stringTooLong(sceneID: UUID, field: String, actualUTF8Bytes: Int, maximum: Int)
    case emptyRequiredString(sceneID: UUID, field: String)
    case scenesNotCanonicallyOrdered
}

public enum SceneCatalogOrdering {
    public static func areInIncreasingOrder(_ lhs: SceneRecord, _ rhs: SceneRecord) -> Bool {
        if lhs.sortKey != rhs.sortKey {
            return lhs.sortKey.utf8.lexicographicallyPrecedes(rhs.sortKey.utf8)
        }
        return lhs.sceneID.uuidString < rhs.sceneID.uuidString
    }
}

public enum SceneCatalogSchemaValidator {
    public static func validate(_ payload: SceneCatalogSnapshotPayload) throws {
        guard payload.protocolVersion == SceneCatalogWireFormat.protocolMajor else {
            throw SceneCatalogSchemaError.unsupportedProtocolVersion(payload.protocolVersion)
        }
        guard payload.schemaVersion == 1 else {
            throw SceneCatalogSchemaError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        guard payload.scenes.count <= SceneCatalogSchemaLimits.maximumSceneCount else {
            throw SceneCatalogSchemaError.tooManyScenes(actual: payload.scenes.count)
        }
        var sceneIDs = Set<UUID>()
        for scene in payload.scenes {
            guard scene.projectID == payload.projectID else {
                throw SceneCatalogSchemaError.sceneProjectMismatch(sceneID: scene.sceneID)
            }
            guard sceneIDs.insert(scene.sceneID).inserted else {
                throw SceneCatalogSchemaError.duplicateSceneID(scene.sceneID)
            }
            guard (0...SceneCatalogSchemaLimits.maximumDayIndex).contains(scene.dayIndex) else {
                throw SceneCatalogSchemaError.invalidDayIndex(
                    sceneID: scene.sceneID,
                    value: scene.dayIndex
                )
            }
            guard scene.entityVersion > 0 && scene.entityVersion < UInt64.max else {
                throw SceneCatalogSchemaError.invalidEntityVersion(sceneID: scene.sceneID)
            }
            try validate(
                scene.dayLabel,
                field: "dayLabel",
                sceneID: scene.sceneID,
                maximumUTF8Bytes: SceneCatalogSchemaLimits.maximumDayLabelUTF8Bytes,
                required: false
            )
            try validate(
                scene.sceneNumber,
                field: "sceneNumber",
                sceneID: scene.sceneID,
                maximumUTF8Bytes: SceneCatalogSchemaLimits.maximumSceneNumberUTF8Bytes,
                required: true
            )
            try validate(
                scene.name,
                field: "name",
                sceneID: scene.sceneID,
                maximumUTF8Bytes: SceneCatalogSchemaLimits.maximumNameUTF8Bytes,
                required: true
            )
            try validate(
                scene.sortKey,
                field: "sortKey",
                sceneID: scene.sceneID,
                maximumUTF8Bytes: SceneCatalogSchemaLimits.maximumSortKeyUTF8Bytes,
                required: true
            )
        }
        guard payload.scenes.elementsEqual(
            payload.scenes.sorted(by: SceneCatalogOrdering.areInIncreasingOrder)
        ) else {
            throw SceneCatalogSchemaError.scenesNotCanonicallyOrdered
        }
    }

    private static func validate(
        _ value: String,
        field: String,
        sceneID: UUID,
        maximumUTF8Bytes: Int,
        required: Bool
    ) throws {
        if required && value.isEmpty {
            throw SceneCatalogSchemaError.emptyRequiredString(sceneID: sceneID, field: field)
        }
        guard Data(value.utf8) == Data(value.precomposedStringWithCanonicalMapping.utf8) else {
            throw SceneCatalogSchemaError.stringNotNFC(sceneID: sceneID, field: field)
        }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw SceneCatalogSchemaError.stringContainsControlCharacter(
                sceneID: sceneID,
                field: field
            )
        }
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw SceneCatalogSchemaError.stringTooLong(
                sceneID: sceneID,
                field: field,
                actualUTF8Bytes: value.utf8.count,
                maximum: maximumUTF8Bytes
            )
        }
    }
}

public struct SceneCatalogSnapshotPayload: Codable, Hashable, Sendable {
    public let protocolVersion: UInt16
    public let schemaVersion: UInt16
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let revision: UInt64
    public let generatedAt: CanonicalTimestamp
    public let scenes: [SceneRecord]

    public init(
        protocolVersion: UInt16 = SceneCatalogWireFormat.protocolMajor,
        schemaVersion: UInt16 = 1,
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        revision: UInt64,
        generatedAt: CanonicalTimestamp,
        scenes: [SceneRecord]
    ) {
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.revision = revision
        self.generatedAt = generatedAt
        self.scenes = scenes
    }

    public func canonicalBytes() -> Data {
        CanonicalJSON.encode(.object([
            "authorityEpoch": .string(authorityEpoch.uuidString.lowercased()),
            "authorityID": .string(authorityID.uuidString.lowercased()),
            "catalogID": .string(catalogID.uuidString.lowercased()),
            "generatedAt": .string(generatedAt.rawValue),
            "projectID": .string(projectID.uuidString.lowercased()),
            "protocolVersion": .unsigned(UInt64(protocolVersion)),
            "revision": .unsigned(revision),
            "scenes": .array(scenes.map(Self.canonicalScene)),
            "schemaVersion": .unsigned(UInt64(schemaVersion)),
        ]))
    }

    private static func canonicalScene(_ scene: SceneRecord) -> CanonicalJSONValue {
        .object([
            "dayIndex": .integer(Int64(scene.dayIndex)),
            "dayLabel": .string(scene.dayLabel),
            "entityVersion": .unsigned(scene.entityVersion),
            "lifecycle": .string(scene.lifecycle.rawValue),
            "name": .string(scene.name),
            "projectID": .string(scene.projectID.uuidString.lowercased()),
            "sceneID": .string(scene.sceneID.uuidString.lowercased()),
            "sceneNumber": .string(scene.sceneNumber),
            "sortKey": .string(scene.sortKey),
        ])
    }
}

public enum SceneCatalogWireFormat {
    public static let domainSeparator = Data("RINKAN-UMIS-SCENE-CATALOG-V1".utf8)
    public static let protocolMajor: UInt16 = 1
    public static let protocolMinor: UInt16 = 0
    public static let snapshotMessageType: UInt16 = 1
    public static let maximumMessageBytes = 1_048_576
    /// Leaves bounded space for the signed header, signature, and transport
    /// request correlation while keeping the complete frame at or below 1 MiB.
    public static let maximumPayloadBytes = maximumMessageBytes - 512
}

public struct SignedSceneCatalogSnapshot: Codable, Hashable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let messageType: UInt16
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let revision: UInt64
    public let payloadBytes: Data
    public let payloadSHA256: SHA256Value
    public let detachedSignature: Data

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        messageType: UInt16,
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        revision: UInt64,
        payloadBytes: Data,
        payloadSHA256: SHA256Value,
        detachedSignature: Data
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.messageType = messageType
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.revision = revision
        self.payloadBytes = payloadBytes
        self.payloadSHA256 = payloadSHA256
        self.detachedSignature = detachedSignature
    }

    /// Normative bytes covered by the Ed25519 detached signature.
    public func signedBytes() throws -> Data {
        guard payloadBytes.count <= SceneCatalogWireFormat.maximumPayloadBytes else {
            throw SceneCatalogVerificationError.payloadTooLarge(actual: payloadBytes.count)
        }
        guard let payloadLength = UInt32(exactly: payloadBytes.count) else {
            throw SceneCatalogVerificationError.payloadTooLarge(actual: payloadBytes.count)
        }
        var result = SceneCatalogWireFormat.domainSeparator
        result.appendBigEndian(protocolMajor)
        result.appendBigEndian(protocolMinor)
        result.appendBigEndian(messageType)
        result.appendUUID(projectID)
        result.appendUUID(catalogID)
        result.appendUUID(authorityID)
        result.appendUUID(authorityEpoch)
        result.appendBigEndian(revision)
        result.appendBigEndian(payloadLength)
        result.append(payloadSHA256.bytes)
        result.append(payloadBytes)
        return result
    }
}

public struct SceneCatalogSigningKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let privateKeyBytes: Data
    private let publicKeyBytes: Data
    public let keyID: String

    public init(rawRepresentation: Data, keyID: String? = nil) throws {
        guard rawRepresentation.count == 32 else {
            throw UMISNetworkValidationError.invalidPrivateKeyLength(actual: rawRepresentation.count)
        }
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        let publicBytes = privateKey.publicKey.rawRepresentation
        let derivedKeyID = SHA256Value.hash(publicBytes).hex
        if let keyID, keyID.lowercased() != derivedKeyID {
            throw UMISNetworkValidationError.catalogKeyIDMismatch
        }
        self.privateKeyBytes = rawRepresentation
        self.publicKeyBytes = publicBytes
        self.keyID = derivedKeyID
    }

    public static func generate() -> Self {
        let key = Curve25519.Signing.PrivateKey()
        return Self(
            privateKeyBytes: key.rawRepresentation,
            publicKeyBytes: key.publicKey.rawRepresentation
        )
    }

    public var publicKeyRawRepresentation: Data {
        publicKeyBytes
    }

    public var description: String {
        "SceneCatalogSigningKey(keyID: \(keyID), privateKey: <redacted>)"
    }

    public var debugDescription: String { description }

    public func sign(_ payload: SceneCatalogSnapshotPayload) throws -> SignedSceneCatalogSnapshot {
        try SceneCatalogSchemaValidator.validate(payload)
        let payloadBytes = payload.canonicalBytes()
        guard payloadBytes.count <= SceneCatalogWireFormat.maximumPayloadBytes else {
            throw SceneCatalogVerificationError.payloadTooLarge(actual: payloadBytes.count)
        }
        let digest = SHA256Value.hash(payloadBytes)
        let unsigned = SignedSceneCatalogSnapshot(
            protocolMajor: SceneCatalogWireFormat.protocolMajor,
            protocolMinor: SceneCatalogWireFormat.protocolMinor,
            messageType: SceneCatalogWireFormat.snapshotMessageType,
            projectID: payload.projectID,
            catalogID: payload.catalogID,
            authorityID: payload.authorityID,
            authorityEpoch: payload.authorityEpoch,
            revision: payload.revision,
            payloadBytes: payloadBytes,
            payloadSHA256: digest,
            detachedSignature: Data()
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let signature = try privateKey.signature(for: unsigned.signedBytes())
        return SignedSceneCatalogSnapshot(
            protocolMajor: unsigned.protocolMajor,
            protocolMinor: unsigned.protocolMinor,
            messageType: unsigned.messageType,
            projectID: unsigned.projectID,
            catalogID: unsigned.catalogID,
            authorityID: unsigned.authorityID,
            authorityEpoch: unsigned.authorityEpoch,
            revision: unsigned.revision,
            payloadBytes: unsigned.payloadBytes,
            payloadSHA256: unsigned.payloadSHA256,
            detachedSignature: signature
        )
    }

    func signProtocolBytes(_ bytes: Data) throws -> Data {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        return try privateKey.signature(for: bytes)
    }

    var keychainPrivateKeyRawRepresentation: Data { privateKeyBytes }

    private init(privateKeyBytes: Data, publicKeyBytes: Data) {
        precondition(privateKeyBytes.count == 32 && publicKeyBytes.count == 32)
        self.privateKeyBytes = privateKeyBytes
        self.publicKeyBytes = publicKeyBytes
        self.keyID = SHA256Value.hash(publicKeyBytes).hex
    }
}

public struct SceneCatalogTrust: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let trustedCatalogKeyID: String
    public let publicKeyRawRepresentation: Data

    public init(
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        trustedCatalogKeyID: String,
        publicKeyRawRepresentation: Data
    ) throws {
        guard publicKeyRawRepresentation.count == 32 else {
            throw UMISNetworkValidationError.invalidPublicKeyLength(actual: publicKeyRawRepresentation.count)
        }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRawRepresentation)
        guard trustedCatalogKeyID.lowercased() == SHA256Value.hash(publicKeyRawRepresentation).hex else {
            throw UMISNetworkValidationError.catalogKeyIDMismatch
        }
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.trustedCatalogKeyID = SHA256Value.hash(publicKeyRawRepresentation).hex
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
    }
}

public struct CatalogVersionRef: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let revision: UInt64
    public let payloadDigest: SHA256Value

    public init(
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        revision: UInt64,
        payloadDigest: SHA256Value
    ) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.revision = revision
        self.payloadDigest = payloadDigest
    }
}

public struct VerifiedSceneCatalogSnapshot: Sendable, Hashable {
    public let payload: SceneCatalogSnapshotPayload
    public let envelope: SignedSceneCatalogSnapshot
    public let version: CatalogVersionRef

    fileprivate init(payload: SceneCatalogSnapshotPayload, envelope: SignedSceneCatalogSnapshot) {
        self.payload = payload
        self.envelope = envelope
        self.version = CatalogVersionRef(
            projectID: envelope.projectID,
            catalogID: envelope.catalogID,
            authorityID: envelope.authorityID,
            authorityEpoch: envelope.authorityEpoch,
            revision: envelope.revision,
            payloadDigest: envelope.payloadSHA256
        )
    }
}

public enum SceneCatalogVerificationError: Error, Equatable, Sendable {
    case unsupportedProtocol(major: UInt16, minor: UInt16)
    case unexpectedMessageType(UInt16)
    case payloadTooLarge(actual: Int)
    case payloadDigestMismatch
    case invalidSignature
    case malformedPayload
    case nonCanonicalPayload
    case schemaVersionUnsupported(UInt16)
    case envelopePayloadMismatch(field: String)
    case sceneProjectMismatch(sceneID: UUID)
    case duplicateSceneID(UUID)
    case invalidSceneSchema
    case untrustedProjectOrCatalog
    case untrustedAuthority
    case untrustedAuthorityEpoch
}

public enum SceneCatalogVerifier {
    public static func verify(
        _ snapshot: SignedSceneCatalogSnapshot,
        trust: SceneCatalogTrust
    ) throws -> VerifiedSceneCatalogSnapshot {
        guard snapshot.protocolMajor == SceneCatalogWireFormat.protocolMajor,
              snapshot.protocolMinor == SceneCatalogWireFormat.protocolMinor else {
            throw SceneCatalogVerificationError.unsupportedProtocol(
                major: snapshot.protocolMajor,
                minor: snapshot.protocolMinor
            )
        }
        guard snapshot.messageType == SceneCatalogWireFormat.snapshotMessageType else {
            throw SceneCatalogVerificationError.unexpectedMessageType(snapshot.messageType)
        }
        guard snapshot.payloadBytes.count <= SceneCatalogWireFormat.maximumPayloadBytes else {
            throw SceneCatalogVerificationError.payloadTooLarge(actual: snapshot.payloadBytes.count)
        }
        guard snapshot.projectID == trust.projectID, snapshot.catalogID == trust.catalogID else {
            throw SceneCatalogVerificationError.untrustedProjectOrCatalog
        }
        guard snapshot.authorityID == trust.authorityID else {
            throw SceneCatalogVerificationError.untrustedAuthority
        }
        guard snapshot.authorityEpoch == trust.authorityEpoch else {
            throw SceneCatalogVerificationError.untrustedAuthorityEpoch
        }
        guard trust.trustedCatalogKeyID.lowercased() ==
                SHA256Value.hash(trust.publicKeyRawRepresentation).hex else {
            throw SceneCatalogVerificationError.invalidSignature
        }
        guard SHA256Value.hash(snapshot.payloadBytes) == snapshot.payloadSHA256 else {
            throw SceneCatalogVerificationError.payloadDigestMismatch
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: trust.publicKeyRawRepresentation
            )
        } catch {
            throw SceneCatalogVerificationError.invalidSignature
        }
        guard publicKey.isValidSignature(snapshot.detachedSignature, for: try snapshot.signedBytes()) else {
            throw SceneCatalogVerificationError.invalidSignature
        }

        let payload: SceneCatalogSnapshotPayload
        do {
            payload = try JSONDecoder().decode(
                SceneCatalogSnapshotPayload.self,
                from: snapshot.payloadBytes
            )
        } catch {
            throw SceneCatalogVerificationError.malformedPayload
        }
        guard payload.canonicalBytes() == snapshot.payloadBytes else {
            throw SceneCatalogVerificationError.nonCanonicalPayload
        }
        guard payload.schemaVersion == 1 else {
            throw SceneCatalogVerificationError.schemaVersionUnsupported(payload.schemaVersion)
        }
        let comparisons: [(Bool, String)] = [
            (payload.protocolVersion == snapshot.protocolMajor, "protocolVersion"),
            (payload.projectID == snapshot.projectID, "projectID"),
            (payload.catalogID == snapshot.catalogID, "catalogID"),
            (payload.authorityID == snapshot.authorityID, "authorityID"),
            (payload.authorityEpoch == snapshot.authorityEpoch, "authorityEpoch"),
            (payload.revision == snapshot.revision, "revision"),
        ]
        if let mismatch = comparisons.first(where: { !$0.0 }) {
            throw SceneCatalogVerificationError.envelopePayloadMismatch(field: mismatch.1)
        }
        var sceneIDs = Set<UUID>()
        for scene in payload.scenes {
            guard scene.projectID == payload.projectID else {
                throw SceneCatalogVerificationError.sceneProjectMismatch(sceneID: scene.sceneID)
            }
            guard sceneIDs.insert(scene.sceneID).inserted else {
                throw SceneCatalogVerificationError.duplicateSceneID(scene.sceneID)
            }
        }
        do {
            try SceneCatalogSchemaValidator.validate(payload)
        } catch {
            throw SceneCatalogVerificationError.invalidSceneSchema
        }
        return VerifiedSceneCatalogSnapshot(payload: payload, envelope: snapshot)
    }
}
