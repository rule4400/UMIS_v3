import Foundation
import Security

public struct SceneCatalogCredentialReference: Hashable, Sendable {
    public let projectID: UUID
    public let catalogID: UUID
    public let pskIdentity: UUID

    public init(projectID: UUID, catalogID: UUID, pskIdentity: UUID) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.pskIdentity = pskIdentity
    }
}

public enum SceneCatalogCredentialVaultError: Error, Equatable, Sendable {
    case invalidServiceName
    case itemNotFound
    case malformedCredential
    case keychainStatus(OSStatus)
}

/// Device-only Keychain storage for paired TLS credentials.
///
/// Secrets are stored as `kSecClassGenericPassword`, never synchronized, using
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background LAN sync can
/// resume after the user has unlocked the Mac once. The credential and its
/// binary codec deliberately do not conform to Codable.
public struct SceneCatalogCredentialVault: Sendable {
    public static let defaultService = "jp.rinkan.umis.scene-catalog.psk.v1"
    public let service: String

    public init(service: String = SceneCatalogCredentialVault.defaultService) throws {
        guard !service.isEmpty, service.utf8.count <= 255,
              !service.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            throw SceneCatalogCredentialVaultError.invalidServiceName
        }
        self.service = service
    }

    @discardableResult
    public func save(_ credential: PairedSceneCatalogCredential) throws -> SceneCatalogCredentialReference {
        let reference = SceneCatalogCredentialReference(
            projectID: credential.projectID,
            catalogID: credential.catalogID,
            pskIdentity: credential.pskIdentity
        )
        let data = try CredentialKeychainCodec.encode(credential)
        let query = baseQuery(reference)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Rinkan UMIS Scene Catalog Pairing"
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // A concurrent save won the add race; update only that exact
                // scoped account, never delete/recreate its access controls.
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw SceneCatalogCredentialVaultError.keychainStatus(status)
        }
        return reference
    }

    public func load(_ reference: SceneCatalogCredentialReference) throws -> PairedSceneCatalogCredential {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw SceneCatalogCredentialVaultError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw SceneCatalogCredentialVaultError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let credential = try CredentialKeychainCodec.decode(data)
        guard credential.projectID == reference.projectID,
              credential.catalogID == reference.catalogID,
              credential.pskIdentity == reference.pskIdentity else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        return credential
    }

    public func remove(_ reference: SceneCatalogCredentialReference) throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SceneCatalogCredentialVaultError.keychainStatus(status)
        }
    }

    public func contains(_ reference: SceneCatalogCredentialReference) throws -> Bool {
        var query = baseQuery(reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw SceneCatalogCredentialVaultError.keychainStatus(status)
        }
        return true
    }

    private func baseQuery(_ reference: SceneCatalogCredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(reference),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func account(_ reference: SceneCatalogCredentialReference) -> String {
        [
            reference.projectID.uuidString.lowercased(),
            reference.catalogID.uuidString.lowercased(),
            reference.pskIdentity.uuidString.lowercased(),
        ].joined(separator: ":")
    }
}

private enum CredentialKeychainCodec {
    private static let magic = Data("UMISKC1".utf8)

    static func encode(_ credential: PairedSceneCatalogCredential) throws -> Data {
        guard credential.catalogPublicKeyRawRepresentation.count == 32,
              (32...64).contains(credential.transportPSK.count) else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        var data = magic
        data.appendBigEndian(UInt16(1))
        data.appendUUID(credential.projectID)
        data.appendUUID(credential.catalogID)
        data.appendUUID(credential.authorityID)
        data.appendUUID(credential.authorityEpoch)
        data.appendUUID(credential.pskIdentity)
        data.append(credential.catalogPublicKeyFingerprint.bytes)
        data.appendBigEndian(UInt16(credential.catalogPublicKeyRawRepresentation.count))
        data.append(credential.catalogPublicKeyRawRepresentation)
        data.appendBigEndian(UInt16(credential.transportPSK.count))
        data.append(credential.transportPSK)
        return data
    }

    static func decode(_ data: Data) throws -> PairedSceneCatalogCredential {
        var cursor = KeychainDataCursor(data)
        guard try cursor.read(count: magic.count) == magic,
              try cursor.readUInt16() == 1 else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let projectID = try cursor.readUUID()
        let catalogID = try cursor.readUUID()
        let authorityID = try cursor.readUUID()
        let authorityEpoch = try cursor.readUUID()
        let pskIdentity = try cursor.readUUID()
        let fingerprint: SHA256Value
        do {
            fingerprint = try SHA256Value(bytes: cursor.read(count: SHA256Value.byteCount))
        } catch {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let publicKeyLength = Int(try cursor.readUInt16())
        guard publicKeyLength == 32 else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let publicKey = try cursor.read(count: publicKeyLength)
        let pskLength = Int(try cursor.readUInt16())
        guard (32...64).contains(pskLength) else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let psk = try cursor.read(count: pskLength)
        guard cursor.isAtEnd else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        do {
            return try PairedSceneCatalogCredential(
                projectID: projectID,
                catalogID: catalogID,
                authorityID: authorityID,
                authorityEpoch: authorityEpoch,
                catalogPublicKeyFingerprint: fingerprint,
                catalogPublicKeyRawRepresentation: publicKey,
                pskIdentity: pskIdentity,
                transportPSK: psk
            )
        } catch {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
    }
}

private struct KeychainDataCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SceneCatalogCredentialVaultError.malformedCredential
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readUInt16() throws -> UInt16 {
        try read(count: 2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try read(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
