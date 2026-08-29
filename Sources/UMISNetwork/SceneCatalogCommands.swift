import Foundation

public struct SceneDraft: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let sceneID: UUID
    public var dayIndex: Int
    public var dayLabel: String
    public var sceneNumber: String
    public var name: String
    public var sortKey: String

    public init(
        projectID: UUID,
        sceneID: UUID = UUID(),
        dayIndex: Int,
        dayLabel: String,
        sceneNumber: String,
        name: String,
        sortKey: String
    ) {
        self.projectID = projectID
        self.sceneID = sceneID
        self.dayIndex = dayIndex
        self.dayLabel = dayLabel
        self.sceneNumber = sceneNumber
        self.name = name
        self.sortKey = sortKey
    }
}

public struct SceneReplacement: Codable, Hashable, Sendable {
    public let sceneID: UUID
    public var dayIndex: Int
    public var dayLabel: String
    public var sceneNumber: String
    public var name: String
    public var sortKey: String

    public init(
        sceneID: UUID,
        dayIndex: Int,
        dayLabel: String,
        sceneNumber: String,
        name: String,
        sortKey: String
    ) {
        self.sceneID = sceneID
        self.dayIndex = dayIndex
        self.dayLabel = dayLabel
        self.sceneNumber = sceneNumber
        self.name = name
        self.sortKey = sortKey
    }
}

/// Master-side mutations. Deletion is a lifecycle transition to a tombstone;
/// stable scene identifiers are never physically removed by this API.
public enum SceneCatalogMutation: Codable, Hashable, Sendable {
    case create(SceneDraft)
    case replace(SceneReplacement, expectedEntityVersion: UInt64)
    case setLifecycle(sceneID: UUID, lifecycle: SceneLifecycle, expectedEntityVersion: UInt64)
}

public struct SceneCatalogCommand: Codable, Hashable, Sendable {
    public let commandID: UUID
    public let actorDeviceID: UUID
    public let projectID: UUID
    public let catalogID: UUID
    public let baseRevision: UInt64
    public let mutation: SceneCatalogMutation

    public init(
        commandID: UUID = UUID(),
        actorDeviceID: UUID,
        projectID: UUID,
        catalogID: UUID,
        baseRevision: UInt64,
        mutation: SceneCatalogMutation
    ) {
        self.commandID = commandID
        self.actorDeviceID = actorDeviceID
        self.projectID = projectID
        self.catalogID = catalogID
        self.baseRevision = baseRevision
        self.mutation = mutation
    }

    public var payloadDigest: SHA256Value {
        SHA256Value.hash(CanonicalJSON.encode(canonicalValue))
    }

    private var canonicalValue: CanonicalJSONValue {
        .object([
            "actorDeviceID": .string(actorDeviceID.uuidString.lowercased()),
            "baseRevision": .unsigned(baseRevision),
            "catalogID": .string(catalogID.uuidString.lowercased()),
            "commandID": .string(commandID.uuidString.lowercased()),
            "mutation": canonicalMutation,
            "projectID": .string(projectID.uuidString.lowercased()),
        ])
    }

    private var canonicalMutation: CanonicalJSONValue {
        switch mutation {
        case .create(let draft):
            return .object([
                "dayIndex": .integer(Int64(draft.dayIndex)),
                "dayLabel": .string(draft.dayLabel),
                "kind": .string("create"),
                "name": .string(draft.name),
                "projectID": .string(draft.projectID.uuidString.lowercased()),
                "sceneID": .string(draft.sceneID.uuidString.lowercased()),
                "sceneNumber": .string(draft.sceneNumber),
                "sortKey": .string(draft.sortKey),
            ])
        case .replace(let replacement, let expectedEntityVersion):
            return .object([
                "dayIndex": .integer(Int64(replacement.dayIndex)),
                "dayLabel": .string(replacement.dayLabel),
                "expectedEntityVersion": .unsigned(expectedEntityVersion),
                "kind": .string("replace"),
                "name": .string(replacement.name),
                "sceneID": .string(replacement.sceneID.uuidString.lowercased()),
                "sceneNumber": .string(replacement.sceneNumber),
                "sortKey": .string(replacement.sortKey),
            ])
        case .setLifecycle(let sceneID, let lifecycle, let expectedEntityVersion):
            return .object([
                "expectedEntityVersion": .unsigned(expectedEntityVersion),
                "kind": .string("setLifecycle"),
                "lifecycle": .string(lifecycle.rawValue),
                "sceneID": .string(sceneID.uuidString.lowercased()),
            ])
        }
    }
}

public enum SceneCatalogConflictReason: String, Codable, Sendable {
    case wrongProjectOrCatalog
    case staleBaseRevision
    case sceneAlreadyExists
    case sceneNotFound
    case staleEntityVersion
    case commandIDPayloadMismatch
}

public struct SceneCatalogConflict: Codable, Hashable, Sendable {
    public let reason: SceneCatalogConflictReason
    public let currentRevision: UInt64
    public let sceneID: UUID?
    public let expectedEntityVersion: UInt64?
    public let currentEntityVersion: UInt64?

    public init(
        reason: SceneCatalogConflictReason,
        currentRevision: UInt64,
        sceneID: UUID? = nil,
        expectedEntityVersion: UInt64? = nil,
        currentEntityVersion: UInt64? = nil
    ) {
        self.reason = reason
        self.currentRevision = currentRevision
        self.sceneID = sceneID
        self.expectedEntityVersion = expectedEntityVersion
        self.currentEntityVersion = currentEntityVersion
    }
}

public enum SceneCatalogCommandResult: Hashable, Sendable {
    case applied(SignedSceneCatalogSnapshot)
    case duplicate(CatalogVersionRef)
    case conflict(SceneCatalogConflict)
}

public enum SceneCatalogMasterError: Error, Equatable, Sendable {
    case duplicateInitialSceneID(UUID)
    case initialSceneProjectMismatch(UUID)
    case revisionOverflow
}

/// Single-writer scene catalog state machine.
///
/// This actor defines deterministic conflict and idempotency behavior. Production
/// integration should persist its accepted command receipts in the same local
/// transaction as the scene/revision update; no client write endpoint is exposed.
public actor SceneCatalogMaster {
    private struct Receipt: Sendable {
        let commandDigest: SHA256Value
        let version: CatalogVersionRef
    }

    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID

    private let signingKey: SceneCatalogSigningKey
    private let timestampProvider: @Sendable () -> CanonicalTimestamp
    private var revision: UInt64
    private var scenes: [UUID: SceneRecord]
    private var receipts: [UUID: Receipt] = [:]
    private var latestSnapshot: SignedSceneCatalogSnapshot

    public init(
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        signingKey: SceneCatalogSigningKey,
        initialRevision: UInt64 = 0,
        initialScenes: [SceneRecord] = [],
        timestampProvider: @escaping @Sendable () -> CanonicalTimestamp = { .now }
    ) throws {
        var indexed: [UUID: SceneRecord] = [:]
        for scene in initialScenes {
            guard scene.projectID == projectID else {
                throw SceneCatalogMasterError.initialSceneProjectMismatch(scene.sceneID)
            }
            guard indexed.updateValue(scene, forKey: scene.sceneID) == nil else {
                throw SceneCatalogMasterError.duplicateInitialSceneID(scene.sceneID)
            }
        }
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.signingKey = signingKey
        self.timestampProvider = timestampProvider
        self.revision = initialRevision
        self.scenes = indexed
        self.latestSnapshot = try signingKey.sign(SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: initialRevision,
            generatedAt: timestampProvider(),
            scenes: Self.orderedScenes(indexed)
        ))
    }

    public func currentRevision() -> UInt64 { revision }
    public func currentSignedSnapshot() -> SignedSceneCatalogSnapshot { latestSnapshot }

    public func apply(_ command: SceneCatalogCommand) throws -> SceneCatalogCommandResult {
        let commandDigest = command.payloadDigest
        if let receipt = receipts[command.commandID] {
            guard receipt.commandDigest == commandDigest else {
                return .conflict(SceneCatalogConflict(
                    reason: .commandIDPayloadMismatch,
                    currentRevision: revision
                ))
            }
            return .duplicate(receipt.version)
        }
        guard command.projectID == projectID, command.catalogID == catalogID else {
            return .conflict(SceneCatalogConflict(
                reason: .wrongProjectOrCatalog,
                currentRevision: revision
            ))
        }
        guard command.baseRevision == revision else {
            return .conflict(SceneCatalogConflict(
                reason: .staleBaseRevision,
                currentRevision: revision
            ))
        }

        var nextScenes = scenes
        switch command.mutation {
        case .create(let draft):
            guard draft.projectID == projectID else {
                return .conflict(SceneCatalogConflict(
                    reason: .wrongProjectOrCatalog,
                    currentRevision: revision,
                    sceneID: draft.sceneID
                ))
            }
            guard nextScenes[draft.sceneID] == nil else {
                return .conflict(SceneCatalogConflict(
                    reason: .sceneAlreadyExists,
                    currentRevision: revision,
                    sceneID: draft.sceneID,
                    currentEntityVersion: nextScenes[draft.sceneID]?.entityVersion
                ))
            }
            nextScenes[draft.sceneID] = SceneRecord(
                projectID: projectID,
                sceneID: draft.sceneID,
                dayIndex: draft.dayIndex,
                dayLabel: draft.dayLabel,
                sceneNumber: draft.sceneNumber,
                name: draft.name,
                sortKey: draft.sortKey,
                entityVersion: 1,
                lifecycle: .active
            )
        case .replace(let replacement, let expectedEntityVersion):
            guard let existing = nextScenes[replacement.sceneID] else {
                return .conflict(SceneCatalogConflict(
                    reason: .sceneNotFound,
                    currentRevision: revision,
                    sceneID: replacement.sceneID,
                    expectedEntityVersion: expectedEntityVersion
                ))
            }
            guard existing.entityVersion == expectedEntityVersion else {
                return .conflict(SceneCatalogConflict(
                    reason: .staleEntityVersion,
                    currentRevision: revision,
                    sceneID: replacement.sceneID,
                    expectedEntityVersion: expectedEntityVersion,
                    currentEntityVersion: existing.entityVersion
                ))
            }
            nextScenes[replacement.sceneID] = SceneRecord(
                projectID: projectID,
                sceneID: replacement.sceneID,
                dayIndex: replacement.dayIndex,
                dayLabel: replacement.dayLabel,
                sceneNumber: replacement.sceneNumber,
                name: replacement.name,
                sortKey: replacement.sortKey,
                entityVersion: existing.entityVersion + 1,
                lifecycle: existing.lifecycle
            )
        case .setLifecycle(let sceneID, let lifecycle, let expectedEntityVersion):
            guard var existing = nextScenes[sceneID] else {
                return .conflict(SceneCatalogConflict(
                    reason: .sceneNotFound,
                    currentRevision: revision,
                    sceneID: sceneID,
                    expectedEntityVersion: expectedEntityVersion
                ))
            }
            guard existing.entityVersion == expectedEntityVersion else {
                return .conflict(SceneCatalogConflict(
                    reason: .staleEntityVersion,
                    currentRevision: revision,
                    sceneID: sceneID,
                    expectedEntityVersion: expectedEntityVersion,
                    currentEntityVersion: existing.entityVersion
                ))
            }
            existing.lifecycle = lifecycle
            existing.entityVersion += 1
            nextScenes[sceneID] = existing
        }

        guard revision < UInt64.max else { throw SceneCatalogMasterError.revisionOverflow }
        let nextRevision = revision + 1
        let snapshot = try signingKey.sign(SceneCatalogSnapshotPayload(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: nextRevision,
            generatedAt: timestampProvider(),
            scenes: Self.orderedScenes(nextScenes)
        ))
        scenes = nextScenes
        revision = nextRevision
        latestSnapshot = snapshot
        let version = CatalogVersionRef(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: nextRevision,
            payloadDigest: snapshot.payloadSHA256
        )
        receipts[command.commandID] = Receipt(
            commandDigest: commandDigest,
            version: version
        )
        return .applied(snapshot)
    }

    private static func orderedScenes(_ scenes: [UUID: SceneRecord]) -> [SceneRecord] {
        scenes.values.sorted(by: SceneCatalogOrdering.areInIncreasingOrder)
    }
}

/// Read-only client facade. Discovery is intentionally independent: finding a
/// Bonjour service never changes this client's trust or accepted catalog.
public actor SceneCatalogClient {
    private let store: AtomicVerifiedSnapshotStore

    public init(store: AtomicVerifiedSnapshotStore) {
        self.store = store
    }

    public func receive(_ snapshot: SignedSceneCatalogSnapshot) async throws -> SnapshotAcceptance {
        try await store.accept(snapshot)
    }

    public func currentSnapshot() async -> VerifiedSceneCatalogSnapshot? {
        await store.currentSnapshot()
    }

    public func highWaterMark() async -> CatalogHighWaterMark? {
        await store.highWaterMark()
    }
}
