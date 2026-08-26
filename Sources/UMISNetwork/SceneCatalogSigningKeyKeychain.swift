import Foundation
import Security

/// Non-secret identity scope. A new master authority or disaster recovery uses
/// a new authority ID/epoch and therefore a different Keychain account.
public struct SceneCatalogAuthorityScope: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID

    public init(projectID: UUID, catalogID: UUID, authorityID: UUID, authorityEpoch: UUID) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
    }
}

/// Non-secret record suitable for OperationStore/project metadata persistence.
/// It can be backed up; the private signing seed remains device-only Keychain
/// material and is deliberately absent.
public struct SceneCatalogAuthorityMetadata: Codable, Hashable, Sendable {
    public let scope: SceneCatalogAuthorityScope
    public let catalogKeyID: String
    public let catalogPublicKeyRawRepresentation: Data
    public let createdAt: CanonicalTimestamp

    public init(
        scope: SceneCatalogAuthorityScope,
        catalogKeyID: String,
        catalogPublicKeyRawRepresentation: Data,
        createdAt: CanonicalTimestamp
    ) {
        self.scope = scope
        self.catalogKeyID = catalogKeyID
        self.catalogPublicKeyRawRepresentation = catalogPublicKeyRawRepresentation
        self.createdAt = createdAt
    }

    public func makeTrust() throws -> SceneCatalogTrust {
        try SceneCatalogTrust(
            projectID: scope.projectID,
            catalogID: scope.catalogID,
            authorityID: scope.authorityID,
            authorityEpoch: scope.authorityEpoch,
            trustedCatalogKeyID: catalogKeyID,
            publicKeyRawRepresentation: catalogPublicKeyRawRepresentation
        )
    }
}

public struct SceneCatalogSigningIdentity: Sendable {
    public let signingKey: SceneCatalogSigningKey
    public let metadata: SceneCatalogAuthorityMetadata

    public init(signingKey: SceneCatalogSigningKey, metadata: SceneCatalogAuthorityMetadata) {
        self.signingKey = signingKey
        self.metadata = metadata
    }
}

public enum SceneCatalogSigningKeyVaultError: Error, Equatable, Sendable {
    case invalidServiceName
    case itemNotFound
    case malformedKeyMaterial
    case authorityMetadataMismatch
    case signingKeyMissingRequiresExplicitRecovery
    case keychainStatus(OSStatus)
}

/// Project-scoped authority lifecycle guard around the device-only signing-key
/// Keychain item.
///
/// `loadOrCreate(projectID:)` is intended for the project's first authority
/// initialization. It persists a non-secret metadata witness before returning.
/// On later launches that witness makes a missing Keychain key a hard failure;
/// the vault never silently substitutes a new key/epoch for an existing
/// authority. Persist the returned metadata in the project database as a second
/// witness and pass it as `expectedMetadata` whenever that record exists.
public actor SceneCatalogAuthorityVault {
    private let metadataDirectoryURL: URL
    private let signingKeyVault: SceneCatalogSigningKeyVault

    public init(
        directoryURL: URL,
        keychainService: String = SceneCatalogSigningKeyVault.defaultService
    ) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        self.metadataDirectoryURL = directoryURL
        self.signingKeyVault = try SceneCatalogSigningKeyVault(service: keychainService)
    }

    /// Loads an established project authority. Missing private key material is
    /// never repaired here; recovery must explicitly create a new authority
    /// epoch and re-pair every client.
    public func load(
        projectID: UUID,
        expectedMetadata: SceneCatalogAuthorityMetadata? = nil
    ) throws -> SceneCatalogSigningIdentity {
        let fileMetadata: SceneCatalogAuthorityMetadata? = try metadataFile(
            projectID: projectID
        ).read(SceneCatalogAuthorityMetadata.self)
        guard let witness = expectedMetadata ?? fileMetadata else {
            throw SceneCatalogSigningKeyVaultError.itemNotFound
        }
        try Self.validateMetadata(witness, projectID: projectID)
        if let expectedMetadata, let fileMetadata, expectedMetadata != fileMetadata {
            throw SceneCatalogSigningKeyVaultError.authorityMetadataMismatch
        }

        let identity: SceneCatalogSigningIdentity
        do {
            identity = try signingKeyVault.load(projectID: projectID)
        } catch SceneCatalogSigningKeyVaultError.itemNotFound {
            throw SceneCatalogSigningKeyVaultError.signingKeyMissingRequiresExplicitRecovery
        }
        try Self.validate(identity: identity, expectedMetadata: witness, projectID: projectID)

        // Repair only a missing non-secret local witness after an independently
        // persisted project-database witness has authenticated the identity.
        if fileMetadata == nil {
            try metadataFile(projectID: projectID).write(witness)
        }
        return identity
    }

    /// Loads the same authority across normal restarts, or creates the first
    /// authority only when neither a project witness nor a Keychain item exists.
    /// Supplying `expectedMetadata` turns the call into a fail-closed existing-
    /// project load and prevents creation after local Application Support loss.
    public func loadOrCreate(
        projectID: UUID,
        expectedMetadata: SceneCatalogAuthorityMetadata? = nil,
        now: Date = Date()
    ) throws -> SceneCatalogSigningIdentity {
        let file = metadataFile(projectID: projectID)
        let fileMetadata: SceneCatalogAuthorityMetadata? = try file.read(
            SceneCatalogAuthorityMetadata.self
        )

        if expectedMetadata != nil || fileMetadata != nil {
            return try load(projectID: projectID, expectedMetadata: expectedMetadata)
        }

        // Crash recovery: Keychain insertion may have completed before its
        // public metadata witness was fsynced. Reuse that key; never replace it.
        let identity: SceneCatalogSigningIdentity
        do {
            identity = try signingKeyVault.load(projectID: projectID)
        } catch SceneCatalogSigningKeyVaultError.itemNotFound {
            identity = try signingKeyVault.loadOrCreate(projectID: projectID, now: now)
        }
        try Self.validateMetadata(identity.metadata, projectID: projectID)
        try file.write(identity.metadata)
        return identity
    }

    /// Public, backup-safe identity record. It never contains the private seed.
    public func metadata(projectID: UUID) throws -> SceneCatalogAuthorityMetadata? {
        try metadataFile(projectID: projectID).read(SceneCatalogAuthorityMetadata.self)
    }

    static func validate(
        identity: SceneCatalogSigningIdentity,
        expectedMetadata: SceneCatalogAuthorityMetadata,
        projectID: UUID
    ) throws {
        try validateMetadata(expectedMetadata, projectID: projectID)
        guard identity.metadata == expectedMetadata,
              identity.signingKey.keyID == expectedMetadata.catalogKeyID,
              identity.signingKey.publicKeyRawRepresentation ==
                expectedMetadata.catalogPublicKeyRawRepresentation else {
            throw SceneCatalogSigningKeyVaultError.authorityMetadataMismatch
        }
    }

    private static func validateMetadata(
        _ metadata: SceneCatalogAuthorityMetadata,
        projectID: UUID
    ) throws {
        guard metadata.scope.projectID == projectID,
              metadata.catalogPublicKeyRawRepresentation.count == 32,
              metadata.catalogKeyID == SHA256Value.hash(
                metadata.catalogPublicKeyRawRepresentation
              ).hex else {
            throw SceneCatalogSigningKeyVaultError.authorityMetadataMismatch
        }
    }

    private func metadataFile(projectID: UUID) -> AtomicRecordFile {
        AtomicRecordFile(url: metadataDirectoryURL.appendingPathComponent(
            "authority-\(projectID.uuidString.lowercased()).metadata"
        ))
    }
}

/// Device-only Keychain vault for the master Catalog authority key.
///
/// There is intentionally no private-key export or Codable API. Rotation and
/// recovery create a new authority scope/key; they do not copy this seed to a
/// different machine.
public struct SceneCatalogSigningKeyVault: Sendable {
    public static let defaultService = "jp.rinkan.umis.scene-catalog.signing.v1"
    public let service: String

    public init(service: String = SceneCatalogSigningKeyVault.defaultService) throws {
        guard !service.isEmpty, service.utf8.count <= 255,
              !service.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            throw SceneCatalogSigningKeyVaultError.invalidServiceName
        }
        self.service = service
    }

    public func load(_ scope: SceneCatalogAuthorityScope) throws -> SceneCatalogSigningIdentity {
        guard let identity = try loadIfPresent(scope) else {
            throw SceneCatalogSigningKeyVaultError.itemNotFound
        }
        return identity
    }

    fileprivate func load(projectID: UUID) throws -> SceneCatalogSigningIdentity {
        guard let identity = try loadProjectIdentityIfPresent(projectID: projectID) else {
            throw SceneCatalogSigningKeyVaultError.itemNotFound
        }
        return identity
    }

    /// Project creation convenience. All authority identifiers and the key are
    /// adopted in one device-only Keychain item and returned as public metadata.
    fileprivate func loadOrCreate(
        projectID: UUID,
        now: Date = Date()
    ) throws -> SceneCatalogSigningIdentity {
        if let existing = try loadProjectIdentityIfPresent(projectID: projectID) {
            return existing
        }
        let scope = SceneCatalogAuthorityScope(
            projectID: projectID,
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID()
        )
        let key = SceneCatalogSigningKey.generate()
        let createdAt = CanonicalTimestamp(date: now)
        let value = try SigningKeyKeychainCodec.encode(
            scope: scope,
            signingKey: key,
            createdAt: createdAt
        )
        var add = projectQuery(projectID: projectID)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Rinkan UMIS Project Catalog Authority"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let winner = try loadProjectIdentityIfPresent(projectID: projectID) else {
                throw SceneCatalogSigningKeyVaultError.itemNotFound
            }
            return winner
        }
        guard status == errSecSuccess else {
            throw SceneCatalogSigningKeyVaultError.keychainStatus(status)
        }
        return Self.identity(scope: scope, signingKey: key, createdAt: createdAt)
    }

    /// Atomically adopts the first key created for this scope. If another task
    /// wins the Keychain add race, the winner is loaded rather than overwritten.
    public func loadOrCreate(
        _ scope: SceneCatalogAuthorityScope,
        now: Date = Date()
    ) throws -> SceneCatalogSigningIdentity {
        if let existing = try loadIfPresent(scope) { return existing }

        let key = SceneCatalogSigningKey.generate()
        let createdAt = CanonicalTimestamp(date: now)
        let value = try SigningKeyKeychainCodec.encode(
            scope: scope,
            signingKey: key,
            createdAt: createdAt
        )
        var add = baseQuery(scope)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Rinkan UMIS Catalog Authority Signing Key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let winner = try loadIfPresent(scope) else {
                throw SceneCatalogSigningKeyVaultError.itemNotFound
            }
            return winner
        }
        guard status == errSecSuccess else {
            throw SceneCatalogSigningKeyVaultError.keychainStatus(status)
        }
        return Self.identity(scope: scope, signingKey: key, createdAt: createdAt)
    }

    private func loadIfPresent(
        _ scope: SceneCatalogAuthorityScope
    ) throws -> SceneCatalogSigningIdentity? {
        var query = baseQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SceneCatalogSigningKeyVaultError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        let decoded = try SigningKeyKeychainCodec.decode(data, expectedScope: scope)
        return Self.identity(
            scope: scope,
            signingKey: decoded.signingKey,
            createdAt: decoded.createdAt
        )
    }

    private func loadProjectIdentityIfPresent(
        projectID: UUID
    ) throws -> SceneCatalogSigningIdentity? {
        var query = projectQuery(projectID: projectID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SceneCatalogSigningKeyVaultError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        let decoded = try SigningKeyKeychainCodec.decode(
            data,
            expectedProjectID: projectID
        )
        return Self.identity(
            scope: decoded.scope,
            signingKey: decoded.signingKey,
            createdAt: decoded.createdAt
        )
    }

    private static func identity(
        scope: SceneCatalogAuthorityScope,
        signingKey: SceneCatalogSigningKey,
        createdAt: CanonicalTimestamp
    ) -> SceneCatalogSigningIdentity {
        SceneCatalogSigningIdentity(
            signingKey: signingKey,
            metadata: SceneCatalogAuthorityMetadata(
                scope: scope,
                catalogKeyID: signingKey.keyID,
                catalogPublicKeyRawRepresentation: signingKey.publicKeyRawRepresentation,
                createdAt: createdAt
            )
        )
    }

    private func baseQuery(_ scope: SceneCatalogAuthorityScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(scope),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func projectQuery(projectID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".project-root",
            kSecAttrAccount as String: projectID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func account(_ scope: SceneCatalogAuthorityScope) -> String {
        [
            scope.projectID.uuidString.lowercased(),
            scope.catalogID.uuidString.lowercased(),
            scope.authorityID.uuidString.lowercased(),
            scope.authorityEpoch.uuidString.lowercased(),
        ].joined(separator: ":")
    }
}

struct DecodedSigningKeyMaterial {
    let scope: SceneCatalogAuthorityScope
    let signingKey: SceneCatalogSigningKey
    let createdAt: CanonicalTimestamp
}

enum SigningKeyKeychainCodec {
    private static let magic = Data("UMISSK1".utf8)

    static func encode(
        scope: SceneCatalogAuthorityScope,
        signingKey: SceneCatalogSigningKey,
        createdAt: CanonicalTimestamp
    ) throws -> Data {
        let seed = signingKey.keychainPrivateKeyRawRepresentation
        guard seed.count == 32 else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        var result = magic
        result.appendBigEndian(UInt16(1))
        result.appendUUID(scope.projectID)
        result.appendUUID(scope.catalogID)
        result.appendUUID(scope.authorityID)
        result.appendUUID(scope.authorityEpoch)
        result.append(contentsOf: createdAt.rawValue.utf8)
        result.appendBigEndian(UInt16(seed.count))
        result.append(seed)
        return result
    }

    static func decode(
        _ data: Data,
        expectedScope: SceneCatalogAuthorityScope
    ) throws -> DecodedSigningKeyMaterial {
        let decoded = try decodePayload(data)
        guard decoded.scope == expectedScope else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        return decoded
    }

    static func decode(
        _ data: Data,
        expectedProjectID: UUID
    ) throws -> DecodedSigningKeyMaterial {
        let decoded = try decodePayload(data)
        guard decoded.scope.projectID == expectedProjectID else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        return decoded
    }

    private static func decodePayload(_ data: Data) throws -> DecodedSigningKeyMaterial {
        var cursor = SigningKeyDataCursor(data)
        guard try cursor.read(count: magic.count) == magic,
              try cursor.readUInt16() == 1 else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        let storedScope = SceneCatalogAuthorityScope(
            projectID: try cursor.readUUID(),
            catalogID: try cursor.readUUID(),
            authorityID: try cursor.readUUID(),
            authorityEpoch: try cursor.readUUID()
        )
        guard let timestampText = String(data: try cursor.read(count: 20), encoding: .utf8),
              let createdAt = try? CanonicalTimestamp(timestampText),
              try cursor.readUInt16() == 32 else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        let seed = try cursor.read(count: 32)
        guard cursor.isAtEnd else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
        do {
            return DecodedSigningKeyMaterial(
                scope: storedScope,
                signingKey: try SceneCatalogSigningKey(rawRepresentation: seed),
                createdAt: createdAt
            )
        } catch {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
        }
    }
}

private struct SigningKeyDataCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SceneCatalogSigningKeyVaultError.malformedKeyMaterial
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
