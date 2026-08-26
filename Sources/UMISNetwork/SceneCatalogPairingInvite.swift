import CryptoKit
import Foundation
import Security

public enum SceneCatalogPairingRole: String, Sendable {
    case viewer
}

public struct PairingSAS: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.lowercased()
        let groups = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 4,
              groups.allSatisfy({ group in
                  group.count == 4 && group.unicodeScalars.allSatisfy {
                      (48...57).contains($0.value) || (97...102).contains($0.value)
                  }
              }) else {
            throw SceneCatalogPairingInviteError.invalidSAS
        }
        self.rawValue = normalized
    }

    public var description: String { rawValue }

    fileprivate init(digest: SHA256Value) {
        let value = digest.hex.prefix(16)
        self.rawValue = stride(from: 0, to: 16, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 4)
            return String(value[start..<end])
        }.joined(separator: "-")
    }
}

public struct SceneCatalogPairingInviteSummary: Hashable, Sendable {
    public let inviteID: UUID
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let catalogPublicKeyFingerprint: SHA256Value
    public let pskIdentity: UUID
    public let role: SceneCatalogPairingRole
    public let serviceName: String
    public let issuedAt: CanonicalTimestamp
    public let expiresAt: CanonicalTimestamp
    public let sas: PairingSAS
}

/// Ephemeral QR/file payload. `exportedData` contains a PSK and is a secret.
/// Never log it, put it in UserDefaults, attach it to diagnostics, or retain it
/// after pairing. The description is deliberately redacted.
public struct SceneCatalogPairingInviteArtifact: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let qrPrefix = "umis-pairing-v1:"

    public let summary: SceneCatalogPairingInviteSummary
    public let exportedData: Data
    fileprivate let credential: PairedSceneCatalogCredential
    fileprivate let payloadDigest: SHA256Value

    public var description: String {
        "SceneCatalogPairingInviteArtifact(inviteID: \(summary.inviteID), secret: <redacted>)"
    }

    public var debugDescription: String { description }

    public func qrPayload() -> String {
        Self.qrPrefix + exportedData.base64EncodedString()
    }
}

public enum SceneCatalogPairingInviteError: Error, Equatable, Sendable {
    case invalidValidityDuration
    case invalidSAS
    case malformedArtifact
    case artifactTooLarge
    case unsupportedVersion
    case nonCanonicalPayload
    case invalidSignature
    case fingerprintMismatch
    case sasMismatch
    case operatorConfirmationRequired
    case expired
    case issuedInFuture
    case validityWindowTooLong
    case scopeMismatch
    case unknownInvite
    case inviteAlreadyConsumed
    case inviteRevoked
    case randomGenerationFailed(OSStatus)
}

public enum SceneCatalogPairingInviteState: String, Codable, Sendable {
    case issued
    case consumed
    case revoked
}

private struct PairingInviteLedgerRecord: Codable, Hashable, Sendable {
    let inviteID: UUID
    let payloadDigest: SHA256Value
    let expiresAt: CanonicalTimestamp
    var state: SceneCatalogPairingInviteState
}

private struct PairingInviteLedger: Codable, Sendable {
    let schemaVersion: UInt16
    var records: [PairingInviteLedgerRecord]
}

/// Master-side short-lived invite issuer and durable one-time-use ledger.
public actor SceneCatalogPairingInviteIssuer {
    public static let maximumValidity: TimeInterval = 300
    public static let minimumValidity: TimeInterval = 30

    private let projectID: UUID
    private let catalogID: UUID
    private let authorityID: UUID
    private let authorityEpoch: UUID
    private let serviceName: String
    private let signingKey: SceneCatalogSigningKey
    private let ledgerFile: AtomicRecordFile
    private var records: [UUID: PairingInviteLedgerRecord]

    public init(
        directoryURL: URL,
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        serviceName: String,
        signingKey: SceneCatalogSigningKey,
        ledgerFileName: String = "scene-catalog-pairing-invites"
    ) throws {
        guard !serviceName.isEmpty, serviceName.utf8.count <= 63,
              !serviceName.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            throw SecureSceneCatalogTransportError.invalidServiceName
        }
        guard !ledgerFileName.isEmpty, !ledgerFileName.contains("/") else {
            throw DurableStorageError.invalidFileName
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.serviceName = serviceName
        self.signingKey = signingKey
        let file = AtomicRecordFile(url: directoryURL.appendingPathComponent(ledgerFileName))
        let stored = try file.read(PairingInviteLedger.self)
        guard stored?.schemaVersion == nil || stored?.schemaVersion == 1 else {
            throw DurableStorageError.corruptEnvelope
        }
        var indexed: [UUID: PairingInviteLedgerRecord] = [:]
        for record in stored?.records ?? [] {
            guard indexed.updateValue(record, forKey: record.inviteID) == nil else {
                throw DurableStorageError.corruptEnvelope
            }
        }
        self.ledgerFile = file
        self.records = indexed
    }

    public func issue(
        now: Date = Date(),
        validFor: TimeInterval = 120
    ) throws -> SceneCatalogPairingInviteArtifact {
        guard validFor >= Self.minimumValidity,
              validFor <= Self.maximumValidity,
              validFor.isFinite else {
            throw SceneCatalogPairingInviteError.invalidValidityDuration
        }
        let credential = try PairedSceneCatalogCredential.generate(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation
        )
        let artifact = try PairingInviteCodec.make(
            inviteID: UUID(),
            credential: credential,
            role: .viewer,
            serviceName: serviceName,
            issuedAt: CanonicalTimestamp(date: now),
            expiresAt: CanonicalTimestamp(date: now.addingTimeInterval(validFor)),
            signingKey: signingKey
        )
        var next = records
        next[artifact.summary.inviteID] = PairingInviteLedgerRecord(
            inviteID: artifact.summary.inviteID,
            payloadDigest: artifact.payloadDigest,
            expiresAt: artifact.summary.expiresAt,
            state: .issued
        )
        try persist(next)
        return artifact
    }

    /// Master approval boundary. The client-read SAS must be compared on the
    /// master UI; successful durable consumption occurs before the PSK is
    /// returned for listener configuration.
    public func approveAndConsume(
        _ artifact: SceneCatalogPairingInviteArtifact,
        confirmedClientSAS: PairingSAS,
        operatorConfirmed: Bool,
        now: Date = Date()
    ) throws -> PairedSceneCatalogCredential {
        try approveAndConsume(
            summary: artifact.summary,
            credential: artifact.credential,
            payloadDigest: artifact.payloadDigest,
            confirmedClientSAS: confirmedClientSAS,
            operatorConfirmed: operatorConfirmed,
            now: now
        )
    }

    /// Restart-safe variant for a user-selected invite file. The signature and
    /// expiry are revalidated before the durable ledger transition.
    public func approveAndConsume(
        exportedData: Data,
        confirmedClientSAS: PairingSAS,
        operatorConfirmed: Bool,
        now: Date = Date()
    ) throws -> PairedSceneCatalogCredential {
        let decoded = try PairingInviteCodec.decodeAndVerify(exportedData, now: now)
        return try approveAndConsume(
            summary: decoded.summary,
            credential: decoded.credential,
            payloadDigest: decoded.payloadDigest,
            confirmedClientSAS: confirmedClientSAS,
            operatorConfirmed: operatorConfirmed,
            now: now
        )
    }

    private func approveAndConsume(
        summary: SceneCatalogPairingInviteSummary,
        credential: PairedSceneCatalogCredential,
        payloadDigest: SHA256Value,
        confirmedClientSAS: PairingSAS,
        operatorConfirmed: Bool,
        now: Date
    ) throws -> PairedSceneCatalogCredential {
        guard operatorConfirmed else {
            throw SceneCatalogPairingInviteError.operatorConfirmationRequired
        }
        guard confirmedClientSAS == summary.sas else {
            throw SceneCatalogPairingInviteError.sasMismatch
        }
        guard summary.projectID == projectID,
              summary.catalogID == catalogID,
              summary.authorityID == authorityID,
              summary.authorityEpoch == authorityEpoch,
              summary.catalogPublicKeyFingerprint ==
                SHA256Value.hash(signingKey.publicKeyRawRepresentation) else {
            throw SceneCatalogPairingInviteError.scopeMismatch
        }
        guard CanonicalTimestamp(date: now) < summary.expiresAt else {
            throw SceneCatalogPairingInviteError.expired
        }
        guard var record = records[summary.inviteID],
              record.payloadDigest == payloadDigest else {
            throw SceneCatalogPairingInviteError.unknownInvite
        }
        switch record.state {
        case .consumed:
            throw SceneCatalogPairingInviteError.inviteAlreadyConsumed
        case .revoked:
            throw SceneCatalogPairingInviteError.inviteRevoked
        case .issued:
            break
        }
        record.state = .consumed
        var next = records
        next[record.inviteID] = record
        try persist(next)
        return credential
    }

    public func revoke(inviteID: UUID) throws {
        guard var record = records[inviteID] else {
            throw SceneCatalogPairingInviteError.unknownInvite
        }
        if record.state == .consumed {
            throw SceneCatalogPairingInviteError.inviteAlreadyConsumed
        }
        record.state = .revoked
        var next = records
        next[inviteID] = record
        try persist(next)
    }

    public func state(inviteID: UUID) -> SceneCatalogPairingInviteState? {
        records[inviteID]?.state
    }

    private func persist(_ next: [UUID: PairingInviteLedgerRecord]) throws {
        try ledgerFile.write(PairingInviteLedger(
            schemaVersion: 1,
            records: next.values.sorted { $0.inviteID.uuidString < $1.inviteID.uuidString }
        ))
        records = next
    }
}

/// Client-side explicit import. `inspect` is not trust acceptance. `confirm`
/// requires a separately observed fingerprint and SAS plus a positive operator
/// action before returning any usable credential.
public enum SceneCatalogPairingInviteImporter {
    public static func inspect(
        exportedData: Data,
        now: Date = Date()
    ) throws -> SceneCatalogPairingInviteSummary {
        try PairingInviteCodec.decodeAndVerify(exportedData, now: now).summary
    }

    public static func inspect(
        qrPayload: String,
        now: Date = Date()
    ) throws -> SceneCatalogPairingInviteSummary {
        try inspect(exportedData: decodeQR(qrPayload), now: now)
    }

    public static func confirm(
        exportedData: Data,
        expectedCatalogFingerprint: SHA256Value,
        expectedSAS: PairingSAS,
        operatorConfirmed: Bool,
        now: Date = Date()
    ) throws -> PairedSceneCatalogCredential {
        guard operatorConfirmed else {
            throw SceneCatalogPairingInviteError.operatorConfirmationRequired
        }
        let decoded = try PairingInviteCodec.decodeAndVerify(exportedData, now: now)
        guard decoded.summary.catalogPublicKeyFingerprint == expectedCatalogFingerprint else {
            throw SceneCatalogPairingInviteError.fingerprintMismatch
        }
        guard decoded.summary.sas == expectedSAS else {
            throw SceneCatalogPairingInviteError.sasMismatch
        }
        return decoded.credential
    }

    public static func confirm(
        qrPayload: String,
        expectedCatalogFingerprint: SHA256Value,
        expectedSAS: PairingSAS,
        operatorConfirmed: Bool,
        now: Date = Date()
    ) throws -> PairedSceneCatalogCredential {
        try confirm(
            exportedData: decodeQR(qrPayload),
            expectedCatalogFingerprint: expectedCatalogFingerprint,
            expectedSAS: expectedSAS,
            operatorConfirmed: operatorConfirmed,
            now: now
        )
    }

    private static func decodeQR(_ value: String) throws -> Data {
        guard value.hasPrefix(SceneCatalogPairingInviteArtifact.qrPrefix),
              let data = Data(base64Encoded: String(
                  value.dropFirst(SceneCatalogPairingInviteArtifact.qrPrefix.count)
              )),
              data.count <= PairingInviteCodec.maximumArtifactBytes else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        return data
    }
}

private struct DecodedPairingInvite {
    let summary: SceneCatalogPairingInviteSummary
    let credential: PairedSceneCatalogCredential
    let payloadDigest: SHA256Value
}

private enum PairingInviteCodec {
    static let maximumArtifactBytes = 32_768
    private static let envelopeMagic = Data("UMISPAIR1".utf8)
    private static let signatureDomain = Data("RINKAN-UMIS-PAIRING-INVITE-V1".utf8)
    private static let sasDomain = Data("RINKAN-UMIS-PAIRING-SAS-V1".utf8)

    static func make(
        inviteID: UUID,
        credential: PairedSceneCatalogCredential,
        role: SceneCatalogPairingRole,
        serviceName: String,
        issuedAt: CanonicalTimestamp,
        expiresAt: CanonicalTimestamp,
        signingKey: SceneCatalogSigningKey
    ) throws -> SceneCatalogPairingInviteArtifact {
        let nonce = try randomBytes(count: 32)
        let payload = canonicalPayload(
            inviteID: inviteID,
            credential: credential,
            nonce: nonce,
            role: role,
            serviceName: serviceName,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let digest = SHA256Value.hash(payload)
        let signature = try signingKey.signProtocolBytes(signedBytes(payload, digest: digest))
        let exported = try encodeEnvelope(payload: payload, signature: signature)
        let sas = makeSAS(payloadDigest: digest)
        return SceneCatalogPairingInviteArtifact(
            summary: SceneCatalogPairingInviteSummary(
                inviteID: inviteID,
                projectID: credential.projectID,
                catalogID: credential.catalogID,
                authorityID: credential.authorityID,
                authorityEpoch: credential.authorityEpoch,
                catalogPublicKeyFingerprint: credential.catalogPublicKeyFingerprint,
                pskIdentity: credential.pskIdentity,
                role: role,
                serviceName: serviceName,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                sas: sas
            ),
            exportedData: exported,
            credential: credential,
            payloadDigest: digest
        )
    }

    static func decodeAndVerify(_ artifact: Data, now: Date) throws -> DecodedPairingInvite {
        guard artifact.count <= maximumArtifactBytes else {
            throw SceneCatalogPairingInviteError.artifactTooLarge
        }
        var cursor = PairingDataCursor(artifact)
        guard try cursor.read(count: envelopeMagic.count) == envelopeMagic else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let payloadLength = Int(try cursor.readUInt32())
        guard payloadLength > 0, payloadLength <= maximumArtifactBytes else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let payload = try cursor.read(count: payloadLength)
        let signatureLength = Int(try cursor.readUInt16())
        guard signatureLength == 64 else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let signature = try cursor.read(count: signatureLength)
        guard cursor.isAtEnd else { throw SceneCatalogPairingInviteError.malformedArtifact }

        let fields = try parsePayload(payload)
        let canonical = canonicalPayload(
            inviteID: fields.inviteID,
            credential: fields.credential,
            nonce: fields.nonce,
            role: fields.role,
            serviceName: fields.serviceName,
            issuedAt: fields.issuedAt,
            expiresAt: fields.expiresAt
        )
        guard canonical == payload else {
            throw SceneCatalogPairingInviteError.nonCanonicalPayload
        }
        let digest = SHA256Value.hash(payload)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: fields.credential.catalogPublicKeyRawRepresentation
        )
        guard publicKey.isValidSignature(signature, for: signedBytes(payload, digest: digest)) else {
            throw SceneCatalogPairingInviteError.invalidSignature
        }
        guard let issuedDate = date(fields.issuedAt), let expiryDate = date(fields.expiresAt) else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let validity = expiryDate.timeIntervalSince(issuedDate)
        guard validity > 0,
              validity <= SceneCatalogPairingInviteIssuer.maximumValidity else {
            throw SceneCatalogPairingInviteError.validityWindowTooLong
        }
        guard issuedDate.timeIntervalSince(now) <= 30 else {
            throw SceneCatalogPairingInviteError.issuedInFuture
        }
        guard now < expiryDate else { throw SceneCatalogPairingInviteError.expired }
        return DecodedPairingInvite(
            summary: SceneCatalogPairingInviteSummary(
                inviteID: fields.inviteID,
                projectID: fields.credential.projectID,
                catalogID: fields.credential.catalogID,
                authorityID: fields.credential.authorityID,
                authorityEpoch: fields.credential.authorityEpoch,
                catalogPublicKeyFingerprint: fields.credential.catalogPublicKeyFingerprint,
                pskIdentity: fields.credential.pskIdentity,
                role: fields.role,
                serviceName: fields.serviceName,
                issuedAt: fields.issuedAt,
                expiresAt: fields.expiresAt,
                sas: makeSAS(payloadDigest: digest)
            ),
            credential: fields.credential,
            payloadDigest: digest
        )
    }

    private struct ParsedFields {
        let inviteID: UUID
        let credential: PairedSceneCatalogCredential
        let nonce: Data
        let role: SceneCatalogPairingRole
        let serviceName: String
        let issuedAt: CanonicalTimestamp
        let expiresAt: CanonicalTimestamp
    }

    private static func parsePayload(_ payload: Data) throws -> ParsedFields {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        guard let object = raw as? [String: Any], object.count == 18,
              let version = object["inviteVersion"] as? NSNumber,
              version.uint16Value == 1,
              let inviteID = uuid(object, "inviteID"),
              let projectID = uuid(object, "projectID"),
              let catalogID = uuid(object, "catalogID"),
              let authorityID = uuid(object, "authorityID"),
              let authorityEpoch = uuid(object, "authorityEpoch"),
              let pskIdentity = uuid(object, "pskIdentity"),
              let fingerprintText = object["catalogPublicKeyFingerprint"] as? String,
              let fingerprint = try? SHA256Value(hex: fingerprintText),
              let publicKey = base64(object, "catalogPublicKey"),
              let psk = base64(object, "transportPSK"),
              let nonce = base64(object, "nonce"), nonce.count == 32,
              let roleText = object["role"] as? String,
              let role = SceneCatalogPairingRole(rawValue: roleText), role == .viewer,
              let serviceName = object["serviceName"] as? String,
              let issuedText = object["issuedAt"] as? String,
              let issuedAt = try? CanonicalTimestamp(issuedText),
              let expiresText = object["expiresAt"] as? String,
              let expiresAt = try? CanonicalTimestamp(expiresText),
              object["nonceBinding"] as? String == "invite-and-sas-v1",
              object["transportSecurity"] as? String == "tls12-psk",
              object["catalogSignatureAlgorithm"] as? String == "ed25519" else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let credential = try PairedSceneCatalogCredential(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            catalogPublicKeyFingerprint: fingerprint,
            catalogPublicKeyRawRepresentation: publicKey,
            pskIdentity: pskIdentity,
            transportPSK: psk
        )
        return ParsedFields(
            inviteID: inviteID,
            credential: credential,
            nonce: nonce,
            role: role,
            serviceName: serviceName,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    private static func canonicalPayload(
        inviteID: UUID,
        credential: PairedSceneCatalogCredential,
        nonce: Data,
        role: SceneCatalogPairingRole,
        serviceName: String,
        issuedAt: CanonicalTimestamp,
        expiresAt: CanonicalTimestamp
    ) -> Data {
        CanonicalJSON.encode(.object([
            "authorityEpoch": .string(credential.authorityEpoch.uuidString.lowercased()),
            "authorityID": .string(credential.authorityID.uuidString.lowercased()),
            "catalogID": .string(credential.catalogID.uuidString.lowercased()),
            "catalogPublicKey": .string(
                credential.catalogPublicKeyRawRepresentation.base64EncodedString()
            ),
            "catalogPublicKeyFingerprint": .string(
                credential.catalogPublicKeyFingerprint.hex
            ),
            "catalogSignatureAlgorithm": .string("ed25519"),
            "expiresAt": .string(expiresAt.rawValue),
            "inviteID": .string(inviteID.uuidString.lowercased()),
            "inviteVersion": .unsigned(1),
            "issuedAt": .string(issuedAt.rawValue),
            "nonce": .string(nonce.base64EncodedString()),
            "nonceBinding": .string("invite-and-sas-v1"),
            "projectID": .string(credential.projectID.uuidString.lowercased()),
            "pskIdentity": .string(credential.pskIdentity.uuidString.lowercased()),
            "role": .string(role.rawValue),
            "serviceName": .string(serviceName),
            "transportPSK": .string(credential.transportPSK.base64EncodedString()),
            "transportSecurity": .string("tls12-psk"),
        ]))
    }

    private static func signedBytes(_ payload: Data, digest: SHA256Value) -> Data {
        var result = signatureDomain
        result.appendBigEndian(UInt32(payload.count))
        result.append(digest.bytes)
        result.append(payload)
        return result
    }

    private static func makeSAS(payloadDigest: SHA256Value) -> PairingSAS {
        var input = sasDomain
        input.append(payloadDigest.bytes)
        return PairingSAS(digest: .hash(input))
    }

    private static func encodeEnvelope(payload: Data, signature: Data) throws -> Data {
        guard let payloadLength = UInt32(exactly: payload.count), signature.count == 64 else {
            throw SceneCatalogPairingInviteError.artifactTooLarge
        }
        var result = envelopeMagic
        result.appendBigEndian(payloadLength)
        result.append(payload)
        result.appendBigEndian(UInt16(signature.count))
        result.append(signature)
        guard result.count <= maximumArtifactBytes else {
            throw SceneCatalogPairingInviteError.artifactTooLarge
        }
        return result
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw SceneCatalogPairingInviteError.randomGenerationFailed(status)
        }
        return bytes
    }

    private static func uuid(_ object: [String: Any], _ key: String) -> UUID? {
        guard let string = object[key] as? String,
              string == string.lowercased() else { return nil }
        return UUID(uuidString: string)
    }

    private static func base64(_ object: [String: Any], _ key: String) -> Data? {
        guard let value = object[key] as? String,
              let decoded = Data(base64Encoded: value),
              decoded.base64EncodedString() == value else { return nil }
        return decoded
    }

    private static func date(_ timestamp: CanonicalTimestamp) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp.rawValue)
    }
}

private struct PairingDataCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SceneCatalogPairingInviteError.malformedArtifact
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readUInt16() throws -> UInt16 {
        try read(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try read(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
