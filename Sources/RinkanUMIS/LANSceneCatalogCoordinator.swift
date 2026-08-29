import Combine
import Darwin
import Foundation
import UMISNetwork

enum LANSceneCatalogMode: Equatable, Sendable {
  case off
  case master(projectID: UUID)
  case client(projectID: UUID)

  var projectID: UUID? {
    switch self {
    case .off:
      nil
    case .master(let projectID), .client(let projectID):
      projectID
    }
  }
}

enum LANSceneCatalogCoordinatorPhase: Equatable, Sendable {
  case idle
  case configuring
  case ready
  case publishing
  case pairing
  case discovering
  case fetching
  case applying
  case failed
}

enum LANSceneCatalogTransportSecurityMode: String, Sendable {
  /// TLS 1.2 with a pairing-invite PSK plus an Ed25519-signed catalog.
  /// This does not provide the normative CA-issued server/client identities,
  /// mutual TLS, SPKI pinning, or device-certificate revocation model.
  case experimentalTLS12PSK = "experimental-tls12-psk-ed25519"
}

enum LANSceneCatalogCoordinatorError: Error, Equatable, Sendable {
  case notConfigured
  case operationInProgress
  case experimentalTransportOperatorConfirmationRequired
  case masterModeRequired
  case clientModeRequired
  case projectChanged
  case invalidServiceName
  case serviceNameChangeRequiresRepairing
  case inviteServiceNameMismatch
  case noPublishedSnapshot
  case noPairedClients
  case noClientPairing
  case noPendingInvite
  case noReceivedSnapshot
  case applicationCandidateChanged
  case invalidApplicationLease
  case selectedServiceUnavailable
  case selectedServiceNameMismatch
  case projectScopeMismatch
  case credentialMetadataMismatch
  case authorityMetadataMismatch
  case revisionExhausted
  case missingSnapshotForHighWater
  case snapshotStateMismatch
  case sceneEntityVersionExhausted(sceneID: UUID)
  case duplicateSceneID(UUID)
  case invalidSceneDay(sceneID: UUID)
  case invalidSceneNumber(sceneID: UUID)
  case invalidSceneEntityVersion(sceneID: UUID)
  case sceneNumberNotRepresentable(sceneID: UUID)
  case sceneEntityVersionNotRepresentable(sceneID: UUID)
  case metadataCorrupt
  case metadataTooLarge
  case metadataIO(operation: String, code: Int32)
}

/// A safe-to-display view of an invite. The TLS PSK and encoded invite bytes
/// are deliberately absent. Use an explicit export method when the operator
/// chooses to transfer an invite to another Mac.
struct LANSceneCatalogInvitePresentation: Hashable, Sendable {
  let inviteID: UUID
  let projectID: UUID
  let catalogID: UUID
  let authorityID: UUID
  let authorityEpoch: UUID
  let serviceName: String
  let catalogFingerprint: String
  let sas: String
  let expiresAt: CanonicalTimestamp

  fileprivate init(summary: SceneCatalogPairingInviteSummary) {
    inviteID = summary.inviteID
    projectID = summary.projectID
    catalogID = summary.catalogID
    authorityID = summary.authorityID
    authorityEpoch = summary.authorityEpoch
    serviceName = summary.serviceName
    catalogFingerprint = summary.catalogPublicKeyFingerprint.hex
    sas = summary.sas.rawValue
    expiresAt = summary.expiresAt
  }
}

/// Immutable handoff boundary for an explicit project update. The caller must
/// persist `version` atomically with its Project/scene snapshot before treating
/// these scenes as the active ingest configuration.
struct LANSceneCatalogApplicationCandidate: Hashable, Sendable {
  let version: CatalogVersionRef
  let records: [SceneRecord]
  let activeScenes: [AppScene]
}

/// An exclusive, immutable handoff from a verified LAN snapshot to ProjectStore.
///
/// While a lease is active, configuration, fetch, role shutdown, and another
/// application attempt all fail closed. The candidate is copied into the lease
/// so a successful ProjectStore commit can update the UI from the exact bytes it
/// persisted, without a post-commit comparison against a potentially newer LAN
/// revision.
struct LANSceneCatalogApplicationLease: Hashable, Sendable {
  let candidate: LANSceneCatalogApplicationCandidate

  fileprivate let token: UUID
  fileprivate let operationGeneration: UUID
  fileprivate let candidateGeneration: UUID
}

/// App-layer orchestration for the read-only LAN scene catalog.
///
/// This object never starts Bonjour, opens a listener, or fetches from the LAN
/// during initialization or configuration. Those side effects require an
/// explicit `startServer()`, `startDiscovery()`, or `fetchSelectedService()`
/// call. Likewise, received scenes are only exposed to the caller; they are not
/// applied to the project automatically and there is no remote mutation API.
///
/// Intended UI sequence:
/// - Master: configure, publish, issue/export, approve the client SAS, start.
/// - Client: configure, inspect, independently confirm, discover, select, fetch.
/// - Project mutation: explicitly acquire and complete an application lease.
@MainActor
final class LANSceneCatalogCoordinator: ObservableObject {
  let transportSecurityMode: LANSceneCatalogTransportSecurityMode = .experimentalTLS12PSK
  let productionEligible = false

  @Published private(set) var mode: LANSceneCatalogMode = .off
  @Published private(set) var phase: LANSceneCatalogCoordinatorPhase = .idle
  @Published private(set) var statusMessage = "LANシーン共有は停止中です"
  @Published private(set) var experimentalTransportOptIn = false
  @Published private(set) var operationInProgress = false

  @Published private(set) var publishedRevision: UInt64?
  @Published private(set) var publishedVersion: CatalogVersionRef?
  @Published private(set) var publishedCatalogRecords: [SceneRecord] = []
  @Published private(set) var receivedRevision: UInt64?
  @Published private(set) var receivedVersion: CatalogVersionRef?
  @Published private(set) var receivedCatalogRecords: [SceneRecord] = []
  @Published private(set) var receivedActiveScenes: [AppScene] = []

  @Published private(set) var pendingMasterInvite: LANSceneCatalogInvitePresentation?
  @Published private(set) var inspectedClientInvite: LANSceneCatalogInvitePresentation?
  @Published private(set) var pairedClientCount = 0
  @Published private(set) var clientIsPaired = false

  @Published private(set) var serverState: SecureSceneCatalogServerState = .idle
  @Published private(set) var discoveryState: SceneCatalogDiscoveryState = .idle
  @Published private(set) var discoveredServices: [DiscoveredSceneCatalogService] = []
  @Published private(set) var selectedServiceID: String?

  private let baseDirectoryURL: URL
  private let metadataStore: LANSceneCatalogMetadataStore
  private let authorityVault: SceneCatalogAuthorityVault
  private let credentialVault: SceneCatalogCredentialVault
  private let publishedSnapshotBox = LANPublishedSnapshotBox()

  private var projectMetadata: LANSceneCatalogProjectMetadata?
  private var masterIdentity: SceneCatalogSigningIdentity?
  private var masterSnapshotStore: AtomicVerifiedSnapshotStore?
  private var pairingIssuer: SceneCatalogPairingInviteIssuer?
  private var pendingInviteArtifact: SceneCatalogPairingInviteArtifact?

  private var clientSnapshotStore: AtomicVerifiedSnapshotStore?

  private var server: SecureSceneCatalogServer?
  private var serverEventTask: Task<Void, Never>?
  private var discovery: BonjourSceneCatalogDiscovery?
  private var discoveryEventTask: Task<Void, Never>?
  private var selectedService: DiscoveredSceneCatalogService?
  private var operationGeneration = UUID()
  private var receivedCandidateGeneration = UUID()
  private var exclusiveOperation: UUID?
  private var activeApplicationLease: LANSceneCatalogApplicationLease?

  init(baseDirectoryURL: URL? = nil) throws {
    let root = try baseDirectoryURL ?? Self.defaultBaseDirectoryURL()
    self.baseDirectoryURL = root.standardizedFileURL
    self.metadataStore = LANSceneCatalogMetadataStore(baseDirectoryURL: root)
    self.authorityVault = try SceneCatalogAuthorityVault(
      directoryURL: root.appendingPathComponent("Authority", isDirectory: true)
    )
    self.credentialVault = try SceneCatalogCredentialVault()
  }

  deinit {
    serverEventTask?.cancel()
    server?.stop()
    discoveryEventTask?.cancel()
    discovery?.stop()
  }

  static func defaultBaseDirectoryURL() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      applicationSupport
      .appendingPathComponent("jp.rinkan.umis", isDirectory: true)
      .appendingPathComponent("LANSceneCatalog", isDirectory: true)
  }

  /// Runtime-only opt-in for the current experimental transport. This choice
  /// is intentionally not persisted and must be reconfirmed after every role
  /// configuration/application launch. Production eligibility remains false.
  func setExperimentalTransportOptIn(
    _ enabled: Bool,
    operatorConfirmed: Bool
  ) throws {
    try ensureNoExclusiveOperation()
    guard mode != .off else {
      throw LANSceneCatalogCoordinatorError.notConfigured
    }
    if enabled {
      guard operatorConfirmed else {
        throw LANSceneCatalogCoordinatorError
          .experimentalTransportOperatorConfirmationRequired
      }
      experimentalTransportOptIn = true
      statusMessage =
        "実験的TLS-PSK共有をこの起動中だけ有効化しました（production非対応）"
    } else {
      stopServer()
      stopDiscovery()
      clearVolatileSecrets()
      experimentalTransportOptIn = false
      statusMessage = "実験的LANトランスポートを無効化しました"
    }
  }

  /// Establishes the local Mac as the project authority without opening a
  /// network listener. An existing public metadata witness is always passed
  /// to the device-only authority vault; missing or replaced key material is
  /// therefore a hard failure instead of silently creating a new authority.
  func configureMaster(projectID: UUID, serviceName: String) async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    phase = .configuring
    experimentalTransportOptIn = false
    statusMessage = "マスター設定を検証しています"
    tearDownNetworkRuntime()
    clearVolatileSecrets()
    let generation = operationGeneration

    do {
      try Self.validateServiceName(serviceName)
      var metadata =
        try await metadataStore.load(projectID: projectID)
        ?? LANSceneCatalogProjectMetadata.empty(projectID: projectID)
      try metadata.validate(projectID: projectID)
      if let established = metadata.master,
        established.serviceName != serviceName,
        !established.pairedClients.isEmpty
      {
        throw LANSceneCatalogCoordinatorError.serviceNameChangeRequiresRepairing
      }

      let expectedAuthority = metadata.master?.authority
      let identity: SceneCatalogSigningIdentity
      if let expectedAuthority {
        identity = try await authorityVault.load(
          projectID: projectID,
          expectedMetadata: expectedAuthority
        )
      } else {
        identity = try await authorityVault.loadOrCreate(projectID: projectID)
      }
      try Self.validateAuthority(identity, projectID: projectID)

      let previousPairings = metadata.master?.pairedClients ?? []
      for pairing in previousPairings {
        let credential = try await loadCredential(pairing.reference)
        try Self.validate(
          credential: credential,
          witness: pairing,
          expectedProjectID: projectID,
          expectedAuthority: identity.metadata
        )
      }

      let masterConfiguration = LANSceneCatalogMasterMetadata(
        authority: identity.metadata,
        serviceName: serviceName,
        pairedClients: previousPairings
      )
      metadata.master = masterConfiguration
      metadata.updatedAt = .now
      try await metadataStore.save(metadata)

      let trust = try identity.metadata.makeTrust()
      let snapshotStore = try AtomicVerifiedSnapshotStore(
        directoryURL: masterSnapshotDirectory(
          projectID: projectID,
          authority: identity.metadata
        ),
        trust: trust
      )
      let current = await snapshotStore.currentSnapshot()
      // A durable catalog snapshot is not automatically network-active after configuration.
      // ProjectStore and the catalog store are separate durability domains. Requiring an explicit
      // publish operation on every launch prevents a snapshot that was staged before an App/project
      // save failure or crash from becoming externally visible merely by restarting the server.
      await publishedSnapshotBox.replace(with: nil)

      let issuer = try SceneCatalogPairingInviteIssuer(
        directoryURL: projectDirectory(projectID)
          .appendingPathComponent("MasterPairing", isDirectory: true),
        projectID: projectID,
        catalogID: identity.metadata.scope.catalogID,
        authorityID: identity.metadata.scope.authorityID,
        authorityEpoch: identity.metadata.scope.authorityEpoch,
        serviceName: serviceName,
        signingKey: identity.signingKey
      )

      guard generation == operationGeneration else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      projectMetadata = metadata
      masterIdentity = identity
      masterSnapshotStore = snapshotStore
      pairingIssuer = issuer
      clientSnapshotStore = nil
      mode = .master(projectID: projectID)
      pairedClientCount = previousPairings.count
      clientIsPaired = false
      publishedRevision = nil
      publishedVersion = nil
      publishedCatalogRecords = []
      replaceReceivedSnapshot(version: nil, records: [], activeScenes: [])
      phase = .ready
      statusMessage = current == nil
        ? "マスター設定完了。最初の署名スナップショットを作成してください"
        : "マスター設定完了。安全のため前回revisionは自動公開しません。再署名・保存が必要です"
    } catch {
      if generation == operationGeneration {
        failClosedAfterConfigurationError(error)
      }
      throw error
    }
  }

  /// Configures client-side trust from an existing Keychain reference. This
  /// does not start Bonjour and does not perform a network request.
  func configureClient(projectID: UUID) async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    phase = .configuring
    experimentalTransportOptIn = false
    statusMessage = "クライアント設定を検証しています"
    tearDownNetworkRuntime()
    clearVolatileSecrets()
    let generation = operationGeneration

    do {
      let metadata =
        try await metadataStore.load(projectID: projectID)
        ?? LANSceneCatalogProjectMetadata.empty(projectID: projectID)
      try metadata.validate(projectID: projectID)

      var loadedCredential: PairedSceneCatalogCredential?
      var loadedStore: AtomicVerifiedSnapshotStore?
      var loadedSnapshot: VerifiedSceneCatalogSnapshot?
      if let pairing = metadata.client?.pairing {
        let credential = try await loadCredential(pairing.reference)
        try Self.validate(
          credential: credential,
          witness: pairing,
          expectedProjectID: projectID,
          expectedAuthority: nil
        )
        let store = try AtomicVerifiedSnapshotStore(
          directoryURL: clientSnapshotDirectory(
            projectID: projectID,
            witness: pairing
          ),
          trust: credential.catalogTrust
        )
        let snapshot = await store.currentSnapshot()
        if let snapshot {
          _ = try Self.appScenes(from: snapshot.payload)
        }
        loadedCredential = credential
        loadedStore = store
        loadedSnapshot = snapshot
      }

      guard generation == operationGeneration else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      projectMetadata = metadata
      masterIdentity = nil
      masterSnapshotStore = nil
      pairingIssuer = nil
      clientSnapshotStore = loadedStore
      mode = .client(projectID: projectID)
      pairedClientCount = 0
      clientIsPaired = loadedCredential != nil
      publishedRevision = nil
      publishedVersion = nil
      publishedCatalogRecords = []
      if let loadedSnapshot {
        replaceReceivedSnapshot(
          version: loadedSnapshot.version,
          records: loadedSnapshot.payload.scenes,
          activeScenes: try Self.appScenes(from: loadedSnapshot.payload)
        )
      } else {
        replaceReceivedSnapshot(version: nil, records: [], activeScenes: [])
      }
      phase = .ready
      statusMessage =
        loadedCredential == nil
        ? "クライアント設定完了。マスターの招待を読み込んでください"
        : "クライアント設定完了。Bonjour検索は手動で開始できます"
    } catch {
      if generation == operationGeneration {
        failClosedAfterConfigurationError(error)
      }
      throw error
    }
  }

  /// Stops LAN sharing only when no configuration, fetch, pairing, publish, or
  /// application lease is active. A `false` result means nothing was changed.
  @discardableResult
  func setOff() -> Bool {
    guard exclusiveOperation == nil else { return false }
    performSetOff()
    return true
  }

  /// Throwing UI/API variant of `setOff()` so a rejected stop request cannot
  /// be mistaken for a completed role transition.
  func setOffIfIdle() throws {
    try ensureNoExclusiveOperation()
    performSetOff()
  }

  private func performSetOff() {
    activeApplicationLease = nil
    operationGeneration = UUID()
    tearDownNetworkRuntime()
    clearVolatileSecrets()
    projectMetadata = nil
    masterIdentity = nil
    masterSnapshotStore = nil
    pairingIssuer = nil
    clientSnapshotStore = nil
    mode = .off
    experimentalTransportOptIn = false
    phase = .idle
    publishedRevision = nil
    publishedVersion = nil
    publishedCatalogRecords = []
    replaceReceivedSnapshot(version: nil, records: [], activeScenes: [])
    pairedClientCount = 0
    clientIsPaired = false
    statusMessage = "LANシーン共有は停止中です"
  }

  /// Creates and atomically stores the next signed *full* snapshot. The next
  /// revision is derived only from the durable high-water checkpoint, never
  /// from UI state. This method does not mutate connected clients.
  @discardableResult
  func publishReadOnlySnapshot(
    scenes: [AppScene],
    generatedAt: Date = Date()
  ) async throws -> UInt64 {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    guard case .master(let projectID) = mode,
      let identity = masterIdentity,
      let store = masterSnapshotStore
    else {
      throw LANSceneCatalogCoordinatorError.masterModeRequired
    }
    phase = .publishing
    statusMessage = "署名スナップショットを作成しています"
    let generation = operationGeneration

    do {
      let refreshedIdentity = try await validateDurableMasterIdentity(
        projectID: projectID,
        expectedIdentity: identity
      )
      let highWater = await store.highWaterMark()
      let previousSnapshot = await store.currentSnapshot()
      if highWater != nil, previousSnapshot == nil {
        throw LANSceneCatalogCoordinatorError.missingSnapshotForHighWater
      }
      if let highWater, let previousSnapshot,
        highWater.highestRevision != previousSnapshot.version.revision
          || highWater.acceptedPayloadDigest != previousSnapshot.version.payloadDigest
      {
        throw LANSceneCatalogCoordinatorError.snapshotStateMismatch
      }
      let highestRevision = highWater?.highestRevision ?? 0
      guard highestRevision < UInt64.max else {
        throw LANSceneCatalogCoordinatorError.revisionExhausted
      }
      let revision = highestRevision + 1
      let records = try Self.sceneRecords(
        from: scenes,
        projectID: projectID,
        previousRecords: previousSnapshot?.payload.scenes ?? []
      )
      let scope = identity.metadata.scope
      let payload = SceneCatalogSnapshotPayload(
        projectID: projectID,
        catalogID: scope.catalogID,
        authorityID: scope.authorityID,
        authorityEpoch: scope.authorityEpoch,
        revision: revision,
        generatedAt: CanonicalTimestamp(date: generatedAt),
        scenes: records
      )
      let signed = try refreshedIdentity.signingKey.sign(payload)
      let verified = try SceneCatalogVerifier.verify(
        signed,
        trust: refreshedIdentity.metadata.makeTrust()
      )
      _ = try await store.accept(signed)
      guard generation == operationGeneration,
        mode == .master(projectID: projectID)
      else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      await publishedSnapshotBox.replace(with: signed)
      masterIdentity = refreshedIdentity
      publishedRevision = revision
      publishedVersion = verified.version
      publishedCatalogRecords = verified.payload.scenes
      phase = .ready
      statusMessage = "署名済み全量スナップショット revision \(revision) を公開しました"
      return revision
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  /// Issues a short-lived one-time pairing invite. Only its redacted display
  /// fields become observable. The PSK-bearing artifact remains private and
  /// is never written by this coordinator.
  @discardableResult
  func issuePairingInvite(validFor: TimeInterval = 120) async throws
    -> LANSceneCatalogInvitePresentation
  {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .master(let projectID) = mode,
      let issuer = pairingIssuer,
      let identity = masterIdentity,
      let master = projectMetadata?.master
    else {
      throw LANSceneCatalogCoordinatorError.masterModeRequired
    }
    phase = .pairing
    statusMessage = "ペアリング招待を発行しています"
    let generation = operationGeneration
    do {
      _ = try await validateDurableMasterIdentity(
        projectID: projectID,
        expectedIdentity: identity,
        expectedMaster: master
      )
      let artifact = try await issuer.issue(validFor: validFor)
      guard generation == operationGeneration, case .master = mode else {
        try? await issuer.revoke(inviteID: artifact.summary.inviteID)
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      let presentation = LANSceneCatalogInvitePresentation(summary: artifact.summary)
      pendingInviteArtifact = artifact
      pendingMasterInvite = presentation
      phase = .ready
      statusMessage = "招待を発行しました。指紋とSASを別経路で照合してください"
      return presentation
    } catch {
      clearPendingMasterInvite()
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  /// Returns the secret invite bytes only after an explicit export action.
  /// The caller must use a protected temporary file/QR flow and erase its own
  /// copy after pairing; these bytes must never enter logs or UserDefaults.
  func exportPendingPairingInviteData() throws -> Data {
    try ensureExperimentalTransportOptIn()
    guard let artifact = pendingInviteArtifact else {
      throw LANSceneCatalogCoordinatorError.noPendingInvite
    }
    return artifact.exportedData
  }

  /// Same security boundary as `exportPendingPairingInviteData()` for a QR UI.
  func exportPendingPairingInviteQRPayload() throws -> String {
    try ensureExperimentalTransportOptIn()
    guard let artifact = pendingInviteArtifact else {
      throw LANSceneCatalogCoordinatorError.noPendingInvite
    }
    return artifact.qrPayload()
  }

  /// Master-side approval of the currently issued invite. `typedClientSAS`
  /// must be independently read from the client, and the UI must require a
  /// separate positive operator action before setting `operatorConfirmed`.
  func approvePendingPairingInvite(
    typedClientSAS: String,
    operatorConfirmed: Bool
  ) async throws {
    guard let artifact = pendingInviteArtifact else {
      throw LANSceneCatalogCoordinatorError.noPendingInvite
    }
    try await approvePairingInvite(
      artifact: artifact,
      exportedData: nil,
      typedClientSAS: typedClientSAS,
      operatorConfirmed: operatorConfirmed
    )
  }

  /// Restart-safe master approval for a user-selected invite file. The bytes
  /// are verified and consumed by the durable one-time ledger but are never
  /// retained or persisted by this coordinator.
  func approvePairingInvite(
    exportedData: Data,
    typedClientSAS: String,
    operatorConfirmed: Bool
  ) async throws {
    try await approvePairingInvite(
      artifact: nil,
      exportedData: exportedData,
      typedClientSAS: typedClientSAS,
      operatorConfirmed: operatorConfirmed
    )
  }

  func revokePendingPairingInvite() async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    guard let artifact = pendingInviteArtifact, let issuer = pairingIssuer else {
      throw LANSceneCatalogCoordinatorError.noPendingInvite
    }
    let generation = operationGeneration
    do {
      try await issuer.revoke(inviteID: artifact.summary.inviteID)
      guard generation == operationGeneration else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      clearPendingMasterInvite()
      statusMessage = "ペアリング招待を失効しました"
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  /// Starts the read-only TLS-PSK listener. At least one approved Keychain
  /// credential and a previously published signed snapshot are mandatory.
  func startServer() async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .master(let projectID) = mode,
      let identity = masterIdentity,
      let metadata = projectMetadata,
      let master = metadata.master
    else {
      throw LANSceneCatalogCoordinatorError.masterModeRequired
    }
    let generation = operationGeneration
    guard await publishedSnapshotBox.hasSnapshot else {
      throw LANSceneCatalogCoordinatorError.noPublishedSnapshot
    }
    guard !master.pairedClients.isEmpty else {
      throw LANSceneCatalogCoordinatorError.noPairedClients
    }
    do {
      let refreshedIdentity = try await validateDurableMasterIdentity(
        projectID: projectID,
        expectedIdentity: identity,
        expectedMaster: master
      )
      var credentials: [PairedSceneCatalogCredential] = []
      credentials.reserveCapacity(master.pairedClients.count)
      for witness in master.pairedClients {
        let credential = try await loadCredential(witness.reference)
        try Self.validate(
          credential: credential,
          witness: witness,
          expectedProjectID: projectID,
          expectedAuthority: refreshedIdentity.metadata
        )
        credentials.append(credential)
      }
      guard generation == operationGeneration,
        mode == .master(projectID: projectID)
      else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }

      stopServer()
      let box = publishedSnapshotBox
      let authorityVault = authorityVault
      let metadataStore = metadataStore
      let expectedMetadata = refreshedIdentity.metadata
      let expectedMaster = master
      let newServer = try SecureSceneCatalogServer(
        serviceName: master.serviceName,
        pairedClients: credentials,
        snapshotProvider: {
          let durable = try await metadataStore.load(projectID: projectID)
          guard durable?.master == expectedMaster,
            expectedMaster.authority == expectedMetadata
          else {
            throw LANSceneCatalogCoordinatorError.authorityMetadataMismatch
          }
          _ = try await authorityVault.load(
            projectID: projectID,
            expectedMetadata: expectedMetadata
          )
          return try await box.requiredSnapshot()
        }
      )
      server = newServer
      masterIdentity = refreshedIdentity
      serverEventTask = Task { [weak self, newServer] in
        for await event in newServer.events() {
          guard !Task.isCancelled else { break }
          self?.handleServerEvent(event)
        }
      }
      try newServer.start()
      statusMessage = "読み取り専用LANカタログを開始しています"
    } catch {
      stopServer()
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  func stopServer() {
    serverEventTask?.cancel()
    serverEventTask = nil
    server?.stop()
    server = nil
    serverState = .stopped
    if case .master = mode {
      phase = .ready
      statusMessage = "LANカタログサーバーを停止しました"
    }
  }

  /// Signature inspection is not trust acceptance. No invite bytes are kept.
  @discardableResult
  func inspectClientPairingInvite(
    exportedData: Data,
    now: Date = Date()
  ) throws -> LANSceneCatalogInvitePresentation {
    try ensureExperimentalTransportOptIn()
    guard case .client(let projectID) = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    do {
      let summary = try SceneCatalogPairingInviteImporter.inspect(
        exportedData: exportedData,
        now: now
      )
      guard summary.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.projectScopeMismatch
      }
      let presentation = LANSceneCatalogInvitePresentation(summary: summary)
      inspectedClientInvite = presentation
      statusMessage = "招待を検証しました。表示された指紋とSASを別経路で確認してください"
      return presentation
    } catch {
      inspectedClientInvite = nil
      markFailure(error)
      throw error
    }
  }

  @discardableResult
  func inspectClientPairingInvite(
    qrPayload: String,
    now: Date = Date()
  ) throws -> LANSceneCatalogInvitePresentation {
    try ensureExperimentalTransportOptIn()
    guard case .client(let projectID) = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    do {
      let summary = try SceneCatalogPairingInviteImporter.inspect(
        qrPayload: qrPayload,
        now: now
      )
      guard summary.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.projectScopeMismatch
      }
      let presentation = LANSceneCatalogInvitePresentation(summary: summary)
      inspectedClientInvite = presentation
      statusMessage = "招待を検証しました。表示された指紋とSASを別経路で確認してください"
      return presentation
    } catch {
      inspectedClientInvite = nil
      markFailure(error)
      throw error
    }
  }

  /// Client trust acceptance requires independently typed values and an
  /// explicit operator confirmation. The secret credential is written only
  /// to the device-only Keychain; local JSON contains a non-secret witness.
  func confirmClientPairing(
    exportedData: Data,
    typedCatalogFingerprint: String,
    typedSAS: String,
    operatorConfirmed: Bool,
    now: Date = Date()
  ) async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .client(let projectID) = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    phase = .pairing
    let generation = operationGeneration
    do {
      let fingerprint = try SHA256Value(
        hex: Self.normalizedFingerprint(typedCatalogFingerprint)
      )
      let sas = try PairingSAS(rawValue: Self.normalizedSAS(typedSAS))
      let summary = try SceneCatalogPairingInviteImporter.inspect(
        exportedData: exportedData,
        now: now
      )
      guard summary.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.projectScopeMismatch
      }
      let credential = try SceneCatalogPairingInviteImporter.confirm(
        exportedData: exportedData,
        expectedCatalogFingerprint: fingerprint,
        expectedSAS: sas,
        operatorConfirmed: operatorConfirmed,
        now: now
      )
      try await adoptClientCredential(
        credential,
        summary: summary,
        projectID: projectID,
        now: now
      )
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  func confirmClientPairing(
    qrPayload: String,
    typedCatalogFingerprint: String,
    typedSAS: String,
    operatorConfirmed: Bool,
    now: Date = Date()
  ) async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .client(let projectID) = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    phase = .pairing
    let generation = operationGeneration
    do {
      let fingerprint = try SHA256Value(
        hex: Self.normalizedFingerprint(typedCatalogFingerprint)
      )
      let sas = try PairingSAS(rawValue: Self.normalizedSAS(typedSAS))
      let summary = try SceneCatalogPairingInviteImporter.inspect(
        qrPayload: qrPayload,
        now: now
      )
      guard summary.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.projectScopeMismatch
      }
      let credential = try SceneCatalogPairingInviteImporter.confirm(
        qrPayload: qrPayload,
        expectedCatalogFingerprint: fingerprint,
        expectedSAS: sas,
        operatorConfirmed: operatorConfirmed,
        now: now
      )
      try await adoptClientCredential(
        credential,
        summary: summary,
        projectID: projectID,
        now: now
      )
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  func startDiscovery() throws {
    try ensureNoExclusiveOperation()
    try ensureExperimentalTransportOptIn()
    guard case .client = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    guard clientIsPaired else {
      throw LANSceneCatalogCoordinatorError.noClientPairing
    }
    stopDiscovery()
    let newDiscovery = BonjourSceneCatalogDiscovery()
    discovery = newDiscovery
    discoveryEventTask = Task { [weak self, newDiscovery] in
      for await event in newDiscovery.events() {
        guard !Task.isCancelled else { break }
        self?.handleDiscoveryEvent(event)
      }
    }
    phase = .discovering
    statusMessage = "Bonjourでマスターを検索しています"
    newDiscovery.start()
  }

  func stopDiscovery() {
    discoveryEventTask?.cancel()
    discoveryEventTask = nil
    discovery?.stop()
    discovery = nil
    discoveryState = .stopped
    discoveredServices = []
    selectedService = nil
    selectedServiceID = nil
    if case .client = mode {
      phase = .ready
      statusMessage = "Bonjour検索を停止しました"
    }
  }

  /// Bonjour results are untrusted hints. Selection is restricted to the
  /// service name signed into the accepted pairing invite; TLS-PSK and
  /// Ed25519 checks still run during fetch.
  func selectDiscoveredService(id: String?) throws {
    try ensureNoExclusiveOperation()
    try ensureExperimentalTransportOptIn()
    guard case .client = mode else {
      throw LANSceneCatalogCoordinatorError.clientModeRequired
    }
    guard let id else {
      selectedService = nil
      selectedServiceID = nil
      return
    }
    guard let service = discoveredServices.first(where: { $0.id == id }) else {
      throw LANSceneCatalogCoordinatorError.selectedServiceUnavailable
    }
    guard let expectedName = projectMetadata?.client?.pairing?.serviceName,
      service.name == expectedName
    else {
      throw LANSceneCatalogCoordinatorError.selectedServiceNameMismatch
    }
    selectedService = service
    selectedServiceID = service.id
  }

  /// Fetches one signed full snapshot, validates AppScene representability,
  /// then atomically advances the anti-rollback store. A failed validation or
  /// trust check leaves the currently exposed scenes unchanged.
  @discardableResult
  func fetchSelectedService(timeout: TimeInterval = 10) async throws -> SnapshotAcceptance {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .client(let projectID) = mode,
      let metadata = projectMetadata,
      let pairing = metadata.client?.pairing,
      let store = clientSnapshotStore,
      let service = selectedService
    else {
      throw LANSceneCatalogCoordinatorError.selectedServiceUnavailable
    }
    guard service.name == pairing.serviceName else {
      throw LANSceneCatalogCoordinatorError.selectedServiceNameMismatch
    }

    phase = .fetching
    statusMessage = "署名済み全量スナップショットを取得しています"
    let generation = operationGeneration
    do {
      // Re-read the exact Keychain account for every fetch. A missing or
      // replaced secret fails closed even if an older in-memory value exists.
      let durableMetadata = try await metadataStore.load(projectID: projectID)
      guard durableMetadata?.client?.pairing == pairing else {
        throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
      }
      let credential = try await loadCredential(pairing.reference)
      try Self.validate(
        credential: credential,
        witness: pairing,
        expectedProjectID: projectID,
        expectedAuthority: nil
      )
      let envelope = try await SecureSceneCatalogClient().fetchFullSnapshot(
        from: service,
        credential: credential,
        timeout: timeout
      )
      let verified = try SceneCatalogVerifier.verify(
        envelope,
        trust: credential.catalogTrust
      )
      let appScenes = try Self.appScenes(from: verified.payload)
      let acceptance = try await store.accept(envelope)

      guard generation == operationGeneration,
        mode == .client(projectID: projectID)
      else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }
      replaceReceivedSnapshot(
        version: verified.version,
        records: verified.payload.scenes,
        activeScenes: appScenes
      )
      phase = .ready
      statusMessage = "revision \(verified.version.revision) を検証・保存しました。適用は未実行です"
      return acceptance
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  /// Returns a display/preview copy and performs no mutation. Persistence code
  /// must acquire a `LANSceneCatalogApplicationLease` so the exact signed
  /// catalog version remains frozen until ProjectStore commits or rolls back.
  func receivedScenesForExplicitApplication() -> [AppScene] {
    receivedActiveScenes
  }

  /// Compatibility inspection boundary. It fails while another exclusive LAN
  /// operation is active and must not be used as a persistence lease.
  func receivedSnapshotForExplicitApplication() throws
    -> LANSceneCatalogApplicationCandidate
  {
    try ensureNoExclusiveOperation()
    return try currentApplicationCandidate()
  }

  /// UI preflight only. The caller must still call
  /// `beginReceivedSnapshotApplication(expectedVersion:)` synchronously before
  /// starting persistence because state can change after this method returns.
  func canBeginReceivedSnapshotApplication(expectedVersion: CatalogVersionRef) -> Bool {
    guard exclusiveOperation == nil,
      case .client(let projectID) = mode,
      projectID == expectedVersion.projectID,
      receivedVersion == expectedVersion
    else {
      return false
    }
    return true
  }

  /// Atomically freezes the exact candidate selected by the UI and excludes
  /// fetch/configuration/shutdown until completion or cancellation.
  func beginReceivedSnapshotApplication(
    expectedVersion: CatalogVersionRef
  ) throws -> LANSceneCatalogApplicationLease {
    let operation = try beginExclusiveOperation()
    do {
      guard case .client(let projectID) = mode else {
        throw LANSceneCatalogCoordinatorError.clientModeRequired
      }
      guard projectID == expectedVersion.projectID else {
        throw LANSceneCatalogCoordinatorError.projectScopeMismatch
      }
      let candidate = try currentApplicationCandidate()
      guard candidate.version == expectedVersion else {
        throw LANSceneCatalogCoordinatorError.applicationCandidateChanged
      }
      let lease = LANSceneCatalogApplicationLease(
        candidate: candidate,
        token: operation,
        operationGeneration: operationGeneration,
        candidateGeneration: receivedCandidateGeneration
      )
      activeApplicationLease = lease
      phase = .applying
      statusMessage =
        "LAN revision \(candidate.version.revision) の適用候補を固定しました"
      return lease
    } catch {
      finishExclusiveOperation(operation)
      throw error
    }
  }

  /// Completes a successful ProjectStore commit. The supplied closure runs on
  /// the MainActor before the lease is released and receives the lease's frozen
  /// candidate. It deliberately does not compare against `receivedVersion`
  /// after persistence; doing so could leave disk and UI on different snapshots.
  func completeReceivedSnapshotApplication(
    _ lease: LANSceneCatalogApplicationLease,
    applyingPersistedCandidate apply: (LANSceneCatalogApplicationCandidate) -> Void
  ) throws {
    try validateActiveApplicationLease(lease)
    apply(lease.candidate)
    activeApplicationLease = nil
    finishExclusiveOperation(lease.token)
    if case .client = mode {
      phase = .ready
      statusMessage =
        "LAN revision \(lease.candidate.version.revision) を保存済み設定へ反映しました"
    }
  }

  /// Releases a lease only after persistence has failed or was cancelled before
  /// commit. A mismatched/stale lease cannot release another operation.
  func cancelReceivedSnapshotApplication(
    _ lease: LANSceneCatalogApplicationLease
  ) throws {
    try validateActiveApplicationLease(lease)
    activeApplicationLease = nil
    finishExclusiveOperation(lease.token)
    if case .client = mode {
      phase = .ready
      statusMessage =
        "LAN revision \(lease.candidate.version.revision) の適用を中止しました"
    }
  }

  /// Includes archived/tombstone rows and their per-entity versions so a
  /// project persistence layer can audit deletion history before explicitly
  /// applying the active projection.
  func receivedCatalogRecordsForInspection() -> [SceneRecord] {
    receivedCatalogRecords
  }

  /// Installs a structurally valid in-memory candidate without touching the
  /// network, metadata store, or Keychain. This internal-only seam is used by
  /// the app target's `@testable` lease tests and has no production UI path.
  @discardableResult
  func installReceivedSnapshotForTesting(
    projectID: UUID,
    revision: UInt64,
    marker: String
  ) throws -> CatalogVersionRef {
    try ensureNoExclusiveOperation()
    let previousScope = receivedVersion.flatMap { version in
      version.projectID == projectID ? version : nil
    }
    let sceneID = UUID()
    let version = CatalogVersionRef(
      projectID: projectID,
      catalogID: previousScope?.catalogID ?? UUID(),
      authorityID: previousScope?.authorityID ?? UUID(),
      authorityEpoch: previousScope?.authorityEpoch ?? UUID(),
      revision: revision,
      payloadDigest: SHA256Value.hash(Data("\(revision):\(marker)".utf8))
    )
    let sceneNumber = Int(exactly: revision) ?? Int.max
    let scene = AppScene(
      id: sceneID,
      day: 1,
      number: sceneNumber,
      name: marker,
      entityVersion: 1
    )
    let record = SceneRecord(
      projectID: projectID,
      sceneID: sceneID,
      dayIndex: 1,
      dayLabel: "1日目",
      sceneNumber: scene.code,
      name: marker,
      sortKey: "0000000000-0000000000-0-\(sceneID.uuidString.lowercased())",
      entityVersion: 1,
      lifecycle: .active
    )
    mode = .client(projectID: projectID)
    replaceReceivedSnapshot(version: version, records: [record], activeScenes: [scene])
    phase = .ready
    statusMessage = "debug test candidate revision \(revision)"
    return version
  }

  func beginFetchExclusionForTesting() throws -> UUID {
    let token = try beginExclusiveOperation()
    phase = .fetching
    return token
  }

  func finishFetchExclusionForTesting(_ token: UUID) throws {
    guard exclusiveOperation == token, activeApplicationLease == nil else {
      throw LANSceneCatalogCoordinatorError.invalidApplicationLease
    }
    finishExclusiveOperation(token)
    phase = .ready
  }

  private func approvePairingInvite(
    artifact: SceneCatalogPairingInviteArtifact?,
    exportedData: Data?,
    typedClientSAS: String,
    operatorConfirmed: Bool
  ) async throws {
    let operation = try beginExclusiveOperation()
    defer { finishExclusiveOperation(operation) }
    try ensureExperimentalTransportOptIn()
    guard case .master(let projectID) = mode,
      let issuer = pairingIssuer,
      var metadata = projectMetadata,
      var master = metadata.master,
      let identity = masterIdentity
    else {
      throw LANSceneCatalogCoordinatorError.masterModeRequired
    }
    phase = .pairing
    let generation = operationGeneration
    do {
      let refreshedIdentity = try await validateDurableMasterIdentity(
        projectID: projectID,
        expectedIdentity: identity,
        expectedMaster: master
      )
      guard let durableMetadata = try await metadataStore.load(projectID: projectID),
        durableMetadata.master == master
      else {
        throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
      }
      metadata = durableMetadata
      if let artifact {
        guard artifact.summary.serviceName == master.serviceName else {
          throw LANSceneCatalogCoordinatorError.inviteServiceNameMismatch
        }
      } else if let exportedData {
        let summary = try SceneCatalogPairingInviteImporter.inspect(
          exportedData: exportedData
        )
        guard summary.serviceName == master.serviceName else {
          throw LANSceneCatalogCoordinatorError.inviteServiceNameMismatch
        }
      }
      let sas = try PairingSAS(rawValue: Self.normalizedSAS(typedClientSAS))
      let credential: PairedSceneCatalogCredential
      if let artifact {
        credential = try await issuer.approveAndConsume(
          artifact,
          confirmedClientSAS: sas,
          operatorConfirmed: operatorConfirmed
        )
      } else if let exportedData {
        credential = try await issuer.approveAndConsume(
          exportedData: exportedData,
          confirmedClientSAS: sas,
          operatorConfirmed: operatorConfirmed
        )
      } else {
        throw LANSceneCatalogCoordinatorError.noPendingInvite
      }

      // Once the durable issuer ledger has consumed an invite it cannot
      // safely be retried, even if a later persistence step fails.
      clearPendingMasterInvite()
      try Self.validate(
        credential: credential,
        projectID: projectID,
        expectedAuthority: refreshedIdentity.metadata
      )
      let reference = try await saveCredential(credential)
      let referenceAlreadyPersisted = master.pairedClients.contains {
        $0.reference == reference
      }
      let witness = LANSceneCatalogPairingWitness(
        reference: reference,
        authorityID: credential.authorityID,
        authorityEpoch: credential.authorityEpoch,
        catalogFingerprint: credential.catalogPublicKeyFingerprint,
        serviceName: master.serviceName,
        pairedAt: .now
      )
      master.pairedClients.removeAll { $0.reference == witness.reference }
      master.pairedClients.append(witness)
      master.pairedClients.sort(by: {
        $0.reference.pskIdentity.uuidString < $1.reference.pskIdentity.uuidString
      })
      metadata.master = master
      metadata.updatedAt = .now
      do {
        try await metadataStore.save(metadata)
      } catch {
        if !referenceAlreadyPersisted {
          try? await removeCredential(reference)
        }
        throw error
      }

      guard generation == operationGeneration,
        mode == .master(projectID: projectID)
      else {
        throw LANSceneCatalogCoordinatorError.projectChanged
      }

      projectMetadata = metadata
      masterIdentity = refreshedIdentity
      pairedClientCount = master.pairedClients.count
      // Listener credentials are immutable; stop instead of pretending
      // the newly paired client was added transactionally to a live server.
      if server != nil { stopServer() }
      phase = .ready
      statusMessage = "クライアントを承認しました。サーバー開始時に新しい認証情報を使用します"
    } catch {
      if generation == operationGeneration { markFailure(error) }
      throw error
    }
  }

  private func adoptClientCredential(
    _ credential: PairedSceneCatalogCredential,
    summary: SceneCatalogPairingInviteSummary,
    projectID: UUID,
    now: Date
  ) async throws {
    let generation = operationGeneration
    try Self.validate(credential: credential, projectID: projectID, expectedAuthority: nil)
    guard credential.catalogID == summary.catalogID,
      credential.authorityID == summary.authorityID,
      credential.authorityEpoch == summary.authorityEpoch,
      credential.pskIdentity == summary.pskIdentity,
      credential.catalogPublicKeyFingerprint == summary.catalogPublicKeyFingerprint
    else {
      throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
    }

    let durableMetadata = try await metadataStore.load(projectID: projectID)
    if durableMetadata == nil,
      projectMetadata?.master != nil || projectMetadata?.client != nil
    {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }
    var metadata =
      durableMetadata ?? LANSceneCatalogProjectMetadata.empty(projectID: projectID)
    try metadata.validate(projectID: projectID)
    let previousReference = metadata.client?.pairing?.reference
    let reference = try await saveCredential(credential)
    let shouldRemoveNewCredentialOnFailure = previousReference != reference
    let witness = LANSceneCatalogPairingWitness(
      reference: reference,
      authorityID: credential.authorityID,
      authorityEpoch: credential.authorityEpoch,
      catalogFingerprint: credential.catalogPublicKeyFingerprint,
      serviceName: summary.serviceName,
      pairedAt: CanonicalTimestamp(date: now)
    )
    let store: AtomicVerifiedSnapshotStore
    do {
      store = try AtomicVerifiedSnapshotStore(
        directoryURL: clientSnapshotDirectory(projectID: projectID, witness: witness),
        trust: credential.catalogTrust
      )
    } catch {
      if shouldRemoveNewCredentialOnFailure {
        try? await removeCredential(reference)
      }
      throw error
    }

    metadata.client = LANSceneCatalogClientMetadata(pairing: witness)
    metadata.updatedAt = .now
    do {
      try await metadataStore.save(metadata)
    } catch {
      if shouldRemoveNewCredentialOnFailure {
        try? await removeCredential(reference)
      }
      throw error
    }
    if let previousReference, previousReference != reference {
      try? await removeCredential(previousReference)
    }

    let current = await store.currentSnapshot()
    guard generation == operationGeneration,
      mode == .client(projectID: projectID)
    else {
      throw LANSceneCatalogCoordinatorError.projectChanged
    }
    projectMetadata = metadata
    clientSnapshotStore = store
    clientIsPaired = true
    inspectedClientInvite = nil
    replaceReceivedSnapshot(
      version: current?.version,
      records: current?.payload.scenes ?? [],
      activeScenes: try current.map { try Self.appScenes(from: $0.payload) } ?? []
    )
    phase = .ready
    statusMessage = "マスターとのペアリングをKeychainに保存しました"
  }

  private func handleServerEvent(_ event: SecureSceneCatalogServerEvent) {
    switch event {
    case .stateChanged(let state):
      serverState = state
      switch state {
      case .idle:
        statusMessage = "LANカタログサーバーは待機中です"
      case .preparing:
        statusMessage = "LANカタログサーバーを開始しています"
      case .ready:
        phase = .ready
        statusMessage = "読み取り専用LANカタログを公開中です"
      case .waiting:
        statusMessage = "LANカタログサーバーはネットワークを待機中です"
      case .failed:
        phase = .failed
        statusMessage = "LANカタログサーバーを開始できませんでした"
      case .stopped:
        phase = .ready
        statusMessage = "LANカタログサーバーを停止しました"
      }
    case .snapshotServed(_, let revision):
      statusMessage = "署名済みrevision \(revision)をクライアントへ送信しました"
    case .requestRejected:
      statusMessage = "信頼条件を満たさないLAN要求を拒否しました"
    }
  }

  private func handleDiscoveryEvent(_ event: SceneCatalogDiscoveryEvent) {
    switch event {
    case .stateChanged(let state):
      discoveryState = state
      guard activeApplicationLease == nil else { return }
      switch state {
      case .idle:
        statusMessage = "Bonjour検索は待機中です"
      case .preparing:
        statusMessage = "Bonjour検索を開始しています"
      case .ready:
        phase = .discovering
        statusMessage = "LAN内のペアリング済みマスターを検索中です"
      case .permissionDenied:
        phase = .failed
        statusMessage = "ローカルネットワーク権限がないため検索できません"
      case .waiting:
        statusMessage = "Bonjour検索はネットワークを待機中です"
      case .failed:
        phase = .failed
        statusMessage = "Bonjour検索に失敗しました"
      case .stopped:
        phase = .ready
        statusMessage = "Bonjour検索を停止しました"
      }
    case .serviceFound(let service):
      guard !discoveredServices.contains(where: { $0.id == service.id }) else { return }
      discoveredServices.append(service)
      discoveredServices.sort(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      )
    case .serviceLost(let service):
      discoveredServices.removeAll { $0.id == service.id }
      if selectedServiceID == service.id {
        selectedService = nil
        selectedServiceID = nil
      }
    }
  }

  private func tearDownNetworkRuntime() {
    operationGeneration = UUID()
    serverEventTask?.cancel()
    serverEventTask = nil
    server?.stop()
    server = nil
    serverState = .idle
    discoveryEventTask?.cancel()
    discoveryEventTask = nil
    discovery?.stop()
    discovery = nil
    discoveryState = .idle
    discoveredServices = []
    selectedService = nil
    selectedServiceID = nil
  }

  private func clearVolatileSecrets() {
    clearPendingMasterInvite()
    inspectedClientInvite = nil
  }

  private func clearPendingMasterInvite() {
    pendingInviteArtifact = nil
    pendingMasterInvite = nil
  }

  private func currentApplicationCandidate() throws
    -> LANSceneCatalogApplicationCandidate
  {
    guard let receivedVersion else {
      throw LANSceneCatalogCoordinatorError.noReceivedSnapshot
    }
    return LANSceneCatalogApplicationCandidate(
      version: receivedVersion,
      records: receivedCatalogRecords,
      activeScenes: receivedActiveScenes
    )
  }

  private func replaceReceivedSnapshot(
    version: CatalogVersionRef?,
    records: [SceneRecord],
    activeScenes: [AppScene]
  ) {
    receivedCandidateGeneration = UUID()
    receivedRevision = version?.revision
    receivedVersion = version
    receivedCatalogRecords = records
    receivedActiveScenes = activeScenes
  }

  /// Validates only ownership of the still-active lease. It intentionally does
  /// not perform a post-persistence CAS against the mutable received candidate.
  private func validateActiveApplicationLease(
    _ lease: LANSceneCatalogApplicationLease
  ) throws {
    guard activeApplicationLease == lease,
      exclusiveOperation == lease.token
    else {
      throw LANSceneCatalogCoordinatorError.invalidApplicationLease
    }
  }

  private func beginExclusiveOperation() throws -> UUID {
    guard exclusiveOperation == nil else {
      throw LANSceneCatalogCoordinatorError.operationInProgress
    }
    let token = UUID()
    exclusiveOperation = token
    operationInProgress = true
    return token
  }

  private func finishExclusiveOperation(_ token: UUID) {
    guard exclusiveOperation == token else { return }
    exclusiveOperation = nil
    operationInProgress = false
  }

  private func ensureNoExclusiveOperation() throws {
    guard exclusiveOperation == nil else {
      throw LANSceneCatalogCoordinatorError.operationInProgress
    }
  }

  private func ensureExperimentalTransportOptIn() throws {
    guard experimentalTransportOptIn else {
      throw LANSceneCatalogCoordinatorError
        .experimentalTransportOperatorConfirmationRequired
    }
  }

  private func failClosedAfterConfigurationError(_ error: Error) {
    tearDownNetworkRuntime()
    clearVolatileSecrets()
    projectMetadata = nil
    masterIdentity = nil
    masterSnapshotStore = nil
    pairingIssuer = nil
    clientSnapshotStore = nil
    mode = .off
    experimentalTransportOptIn = false
    publishedRevision = nil
    publishedVersion = nil
    publishedCatalogRecords = []
    replaceReceivedSnapshot(version: nil, records: [], activeScenes: [])
    pairedClientCount = 0
    clientIsPaired = false
    markFailure(error)
  }

  private func markFailure(_ error: Error) {
    phase = .failed
    statusMessage = Self.safeMessage(for: error)
  }

  private func validateDurableMasterIdentity(
    projectID: UUID,
    expectedIdentity: SceneCatalogSigningIdentity,
    expectedMaster: LANSceneCatalogMasterMetadata? = nil
  ) async throws -> SceneCatalogSigningIdentity {
    let durable = try await metadataStore.load(projectID: projectID)
    guard let storedMaster = durable?.master,
      storedMaster.authority == expectedIdentity.metadata
    else {
      throw LANSceneCatalogCoordinatorError.authorityMetadataMismatch
    }
    if let expectedMaster, storedMaster != expectedMaster {
      throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
    }
    let refreshed = try await authorityVault.load(
      projectID: projectID,
      expectedMetadata: expectedIdentity.metadata
    )
    try Self.validateAuthority(refreshed, projectID: projectID)
    return refreshed
  }

  private func projectDirectory(_ projectID: UUID) -> URL {
    baseDirectoryURL
      .appendingPathComponent("Projects", isDirectory: true)
      .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
  }

  private func masterSnapshotDirectory(
    projectID: UUID,
    authority: SceneCatalogAuthorityMetadata
  ) -> URL {
    projectDirectory(projectID)
      .appendingPathComponent("MasterSnapshots", isDirectory: true)
      .appendingPathComponent(authority.scope.catalogID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(
        authority.scope.authorityID.uuidString.lowercased(), isDirectory: true
      )
      .appendingPathComponent(
        authority.scope.authorityEpoch.uuidString.lowercased(), isDirectory: true)
  }

  private func clientSnapshotDirectory(
    projectID: UUID,
    witness: LANSceneCatalogPairingWitness
  ) -> URL {
    projectDirectory(projectID)
      .appendingPathComponent("ClientSnapshots", isDirectory: true)
      .appendingPathComponent(
        witness.reference.catalogID.uuidString.lowercased(), isDirectory: true
      )
      .appendingPathComponent(witness.authorityID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(witness.authorityEpoch.uuidString.lowercased(), isDirectory: true)
  }

  private func loadCredential(
    _ storedReference: LANSceneCatalogCredentialReference
  ) async throws -> PairedSceneCatalogCredential {
    let vault = credentialVault
    let reference = storedReference.networkReference
    return try await Task.detached(priority: .utility) {
      try vault.load(reference)
    }.value
  }

  private func saveCredential(
    _ credential: PairedSceneCatalogCredential
  ) async throws -> LANSceneCatalogCredentialReference {
    let vault = credentialVault
    let reference = try await Task.detached(priority: .utility) {
      try vault.save(credential)
    }.value
    return LANSceneCatalogCredentialReference(reference)
  }

  private func removeCredential(
    _ storedReference: LANSceneCatalogCredentialReference
  ) async throws {
    let vault = credentialVault
    let reference = storedReference.networkReference
    try await Task.detached(priority: .utility) {
      try vault.remove(reference)
    }.value
  }

  nonisolated fileprivate static func validateServiceName(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 63,
      !value.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control
      })
    else {
      throw LANSceneCatalogCoordinatorError.invalidServiceName
    }
  }

  private static func validateAuthority(
    _ identity: SceneCatalogSigningIdentity,
    projectID: UUID
  ) throws {
    guard identity.metadata.scope.projectID == projectID,
      identity.signingKey.keyID == identity.metadata.catalogKeyID,
      identity.signingKey.publicKeyRawRepresentation
        == identity.metadata.catalogPublicKeyRawRepresentation
    else {
      throw LANSceneCatalogCoordinatorError.authorityMetadataMismatch
    }
  }

  private static func validate(
    credential: PairedSceneCatalogCredential,
    projectID: UUID,
    expectedAuthority: SceneCatalogAuthorityMetadata?
  ) throws {
    guard credential.projectID == projectID else {
      throw LANSceneCatalogCoordinatorError.projectScopeMismatch
    }
    if let expectedAuthority {
      let scope = expectedAuthority.scope
      guard credential.catalogID == scope.catalogID,
        credential.authorityID == scope.authorityID,
        credential.authorityEpoch == scope.authorityEpoch,
        credential.catalogPublicKeyFingerprint.hex == expectedAuthority.catalogKeyID,
        credential.catalogPublicKeyRawRepresentation
          == expectedAuthority.catalogPublicKeyRawRepresentation
      else {
        throw LANSceneCatalogCoordinatorError.authorityMetadataMismatch
      }
    }
  }

  private static func validate(
    credential: PairedSceneCatalogCredential,
    witness: LANSceneCatalogPairingWitness,
    expectedProjectID: UUID,
    expectedAuthority: SceneCatalogAuthorityMetadata?
  ) throws {
    try validate(
      credential: credential,
      projectID: expectedProjectID,
      expectedAuthority: expectedAuthority
    )
    guard credential.projectID == witness.reference.projectID,
      credential.catalogID == witness.reference.catalogID,
      credential.pskIdentity == witness.reference.pskIdentity,
      credential.authorityID == witness.authorityID,
      credential.authorityEpoch == witness.authorityEpoch,
      credential.catalogPublicKeyFingerprint == witness.catalogFingerprint
    else {
      throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
    }
  }

  private static func sceneRecords(
    from scenes: [AppScene],
    projectID: UUID,
    previousRecords: [SceneRecord]
  ) throws -> [SceneRecord] {
    var previousByID: [UUID: SceneRecord] = [:]
    previousByID.reserveCapacity(previousRecords.count)
    for previous in previousRecords {
      guard previous.projectID == projectID,
        previousByID.updateValue(previous, forKey: previous.sceneID) == nil
      else {
        throw LANSceneCatalogCoordinatorError.snapshotStateMismatch
      }
    }

    var identifiers = Set<UUID>()
    var records: [SceneRecord] = []
    records.reserveCapacity(max(scenes.count, previousRecords.count))
    for (index, scene) in scenes.enumerated() {
      guard identifiers.insert(scene.id).inserted else {
        throw LANSceneCatalogCoordinatorError.duplicateSceneID(scene.id)
      }
      guard scene.day >= 0,
        scene.day <= SceneCatalogSchemaLimits.maximumDayIndex
      else {
        throw LANSceneCatalogCoordinatorError.invalidSceneDay(sceneID: scene.id)
      }
      guard scene.number >= 0 else {
        throw LANSceneCatalogCoordinatorError.invalidSceneNumber(sceneID: scene.id)
      }
      guard scene.entityVersion > 0,
        let callerEntityVersion = UInt64(exactly: scene.entityVersion),
        callerEntityVersion < UInt64.max
      else {
        throw LANSceneCatalogCoordinatorError.invalidSceneEntityVersion(sceneID: scene.id)
      }
      let normalizedName = scene.name.precomposedStringWithCanonicalMapping
      let normalizedCode = scene.code.precomposedStringWithCanonicalMapping
      let candidate = SceneRecord(
        projectID: projectID,
        sceneID: scene.id,
        dayIndex: scene.day,
        dayLabel: scene.day == 0 ? "" : "\(scene.day)日目",
        sceneNumber: normalizedCode,
        name: normalizedName,
        sortKey: makeSortKey(
          index: index,
          sceneNumber: scene.number,
          hasCodeOverride: scene.codeOverride != nil,
          sceneID: scene.id
        ),
        entityVersion: callerEntityVersion,
        lifecycle: .active
      )
      let entityVersion: UInt64
      if let previous = previousByID[scene.id] {
        if sameSceneEntity(candidate, previous) {
          entityVersion = max(callerEntityVersion, previous.entityVersion)
        } else {
          entityVersion = max(callerEntityVersion, try nextEntityVersion(after: previous))
        }
      } else {
        entityVersion = callerEntityVersion
      }
      records.append(
        SceneRecord(
          projectID: candidate.projectID,
          sceneID: candidate.sceneID,
          dayIndex: candidate.dayIndex,
          dayLabel: candidate.dayLabel,
          sceneNumber: candidate.sceneNumber,
          name: candidate.name,
          sortKey: candidate.sortKey,
          entityVersion: entityVersion,
          lifecycle: candidate.lifecycle
        ))
    }

    for previous in previousRecords where !identifiers.contains(previous.sceneID) {
      guard previous.lifecycle != .tombstone else {
        records.append(previous)
        continue
      }
      records.append(
        SceneRecord(
          projectID: previous.projectID,
          sceneID: previous.sceneID,
          dayIndex: previous.dayIndex,
          dayLabel: previous.dayLabel,
          sceneNumber: previous.sceneNumber,
          name: previous.name,
          sortKey: previous.sortKey,
          entityVersion: try nextEntityVersion(after: previous),
          lifecycle: .tombstone
        ))
    }
    return records.sorted(by: SceneCatalogOrdering.areInIncreasingOrder)
  }

  private static func sameSceneEntity(_ candidate: SceneRecord, _ previous: SceneRecord) -> Bool {
    previous.projectID == candidate.projectID
      && previous.sceneID == candidate.sceneID
      && previous.dayIndex == candidate.dayIndex
      && previous.dayLabel == candidate.dayLabel
      && previous.sceneNumber == candidate.sceneNumber
      && previous.name == candidate.name
      && previous.sortKey == candidate.sortKey
      && previous.lifecycle == .active
  }

  private static func makeSortKey(
    index: Int,
    sceneNumber: Int,
    hasCodeOverride: Bool,
    sceneID: UUID
  ) -> String {
    String(
      format: "%010lld-%010lld-%d-%@",
      Int64(index),
      Int64(sceneNumber),
      hasCodeOverride ? 1 : 0,
      sceneID.uuidString.lowercased()
    )
  }

  private static func nextEntityVersion(after previous: SceneRecord) throws -> UInt64 {
    guard previous.entityVersion < UInt64.max - 1 else {
      throw LANSceneCatalogCoordinatorError.sceneEntityVersionExhausted(
        sceneID: previous.sceneID
      )
    }
    return previous.entityVersion + 1
  }

  private static func appScenes(from payload: SceneCatalogSnapshotPayload) throws -> [AppScene] {
    var identifiers = Set<UUID>()
    var result: [AppScene] = []
    result.reserveCapacity(payload.scenes.count)
    for record in payload.scenes where record.lifecycle == .active {
      guard identifiers.insert(record.sceneID).inserted else {
        throw LANSceneCatalogCoordinatorError.duplicateSceneID(record.sceneID)
      }
      guard record.dayIndex >= 0 else {
        throw LANSceneCatalogCoordinatorError.invalidSceneDay(sceneID: record.sceneID)
      }
      let sortMetadata = coordinatorSortMetadata(
        from: record.sortKey,
        expectedSceneID: record.sceneID
      )
      let legacyNumber = Int(record.sceneNumber).flatMap { $0 >= 0 ? $0 : nil }
      let number =
        sortMetadata?.sceneNumber
        ?? legacyNumber
        ?? numberEncodedInDefaultCode(record.sceneNumber, day: record.dayIndex)
        ?? 0
      guard number >= 0 else {
        throw LANSceneCatalogCoordinatorError.sceneNumberNotRepresentable(
          sceneID: record.sceneID
        )
      }
      guard let entityVersion = Int(exactly: record.entityVersion), entityVersion > 0 else {
        throw LANSceneCatalogCoordinatorError.sceneEntityVersionNotRepresentable(
          sceneID: record.sceneID
        )
      }
      let defaultCode = defaultSceneCode(day: record.dayIndex, number: number)
      let codeOverride: String?
      if sortMetadata?.hasCodeOverride == true {
        codeOverride = record.sceneNumber
      } else if legacyNumber != nil || record.sceneNumber == defaultCode {
        codeOverride = nil
      } else {
        // External schema-v1 publishers do not have an override marker. Keep
        // their exact code rather than silently replacing it with a local code.
        codeOverride = record.sceneNumber
      }
      result.append(
        AppScene(
          id: record.sceneID,
          day: record.dayIndex,
          number: number,
          name: record.name,
          codeOverride: codeOverride,
          entityVersion: entityVersion
        ))
    }
    return result
  }

  private struct CoordinatorSortMetadata {
    let sceneNumber: Int
    let hasCodeOverride: Bool
  }

  private static func coordinatorSortMetadata(
    from sortKey: String,
    expectedSceneID: UUID
  ) -> CoordinatorSortMetadata? {
    let fields = sortKey.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
    guard fields.count == 4,
      Int64(fields[0]) != nil,
      let sceneNumber = Int(fields[1]),
      sceneNumber >= 0,
      fields[2] == "0" || fields[2] == "1",
      UUID(uuidString: String(fields[3])) == expectedSceneID
    else {
      return nil
    }
    return CoordinatorSortMetadata(
      sceneNumber: sceneNumber,
      hasCodeOverride: fields[2] == "1"
    )
  }

  private static func numberEncodedInDefaultCode(_ code: String, day: Int) -> Int? {
    guard day > 0 else { return code == "OTHER" ? 0 : nil }
    let prefix = "D\(day)"
    guard code.hasPrefix(prefix) else { return nil }
    let suffix = code.dropFirst(prefix.count)
    guard !suffix.isEmpty,
      suffix.allSatisfy({ $0.isNumber }),
      let number = Int(suffix),
      number >= 0
    else {
      return nil
    }
    return number
  }

  private static func defaultSceneCode(day: Int, number: Int) -> String {
    day == 0 ? "OTHER" : "D\(day)\(String(format: "%02d", number))"
  }

  private static func normalizedFingerprint(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "")
      .lowercased()
  }

  private static func normalizedSAS(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func safeMessage(for error: Error) -> String {
    switch error {
    case SceneCatalogSigningKeyVaultError.signingKeyMissingRequiresExplicitRecovery:
      "署名鍵が見つかりません。自動再生成せず、権限移行または全クライアント再ペアリングが必要です"
    case SceneCatalogSigningKeyVaultError.authorityMetadataMismatch,
      LANSceneCatalogCoordinatorError.authorityMetadataMismatch:
      "公開メタデータと端末内の署名鍵が一致しないため停止しました"
    case SceneCatalogCredentialVaultError.itemNotFound:
      "ペアリング認証情報がKeychainにないため停止しました"
    case SceneCatalogCredentialVaultError.malformedCredential,
      LANSceneCatalogCoordinatorError.credentialMetadataMismatch:
      "ペアリング参照とKeychain認証情報が一致しないため停止しました"
    case SceneCatalogAcceptanceError.revisionRollback:
      "古いrevisionを拒否しました"
    case SceneCatalogAcceptanceError.splitBrain:
      "同じrevisionの異なるカタログを拒否しました"
    case SceneCatalogPairingInviteError.operatorConfirmationRequired:
      "オペレーターの明示確認が必要です"
    case SceneCatalogPairingInviteError.fingerprintMismatch:
      "入力した公開鍵指紋が招待と一致しません"
    case SceneCatalogPairingInviteError.sasMismatch:
      "入力したSASが招待と一致しません"
    case SceneCatalogPairingInviteError.expired:
      "ペアリング招待の有効期限が切れています"
    case LANSceneCatalogCoordinatorError.noPublishedSnapshot:
      "署名済みスナップショットを先に公開してください"
    case LANSceneCatalogCoordinatorError.operationInProgress:
      "別のLANシーン共有処理が完了するまでお待ちください"
    case LANSceneCatalogCoordinatorError.experimentalTransportOperatorConfirmationRequired:
      "現行LAN方式は実験的TLS-PSKです。production用途ではなく、起動ごとの明示確認が必要です"
    case LANSceneCatalogCoordinatorError.noPairedClients:
      "承認済みクライアントがありません"
    case LANSceneCatalogCoordinatorError.noReceivedSnapshot:
      "明示適用できる検証済みスナップショットがありません"
    case LANSceneCatalogCoordinatorError.applicationCandidateChanged:
      "適用対象のrevisionが変更されたため、内容を再確認してください"
    case LANSceneCatalogCoordinatorError.invalidApplicationLease:
      "LANシーン適用の排他状態が一致しないため停止しました"
    case LANSceneCatalogCoordinatorError.selectedServiceUnavailable:
      "選択したマスターが現在見つかりません"
    case LANSceneCatalogCoordinatorError.selectedServiceNameMismatch:
      "選択したBonjourサービス名がペアリング情報と一致しません"
    case LANSceneCatalogCoordinatorError.serviceNameChangeRequiresRepairing:
      "ペアリング済み端末があるためBonjour名を変更できません。再ペアリング手順が必要です"
    case LANSceneCatalogCoordinatorError.inviteServiceNameMismatch:
      "招待のBonjour名が現在のマスター設定と一致しないため拒否しました"
    case LANSceneCatalogCoordinatorError.projectScopeMismatch,
      LANSceneCatalogCoordinatorError.projectChanged:
      "プロジェクトの識別情報が一致しないため処理を中止しました"
    case LANSceneCatalogCoordinatorError.metadataCorrupt,
      LANSceneCatalogCoordinatorError.metadataTooLarge:
      "LAN共有メタデータが破損しているため安全に読み込めません"
    case LANSceneCatalogCoordinatorError.missingSnapshotForHighWater:
      "revision履歴は残っていますが直前の署名スナップショットがないため公開を停止しました"
    case LANSceneCatalogCoordinatorError.snapshotStateMismatch:
      "署名スナップショットとrevision履歴が一致しないため公開を停止しました"
    case LANSceneCatalogCoordinatorError.sceneEntityVersionExhausted:
      "シーンの変更世代が上限に達したため公開を停止しました"
    default:
      "LANシーン共有の安全検証に失敗しました"
    }
  }
}

private actor LANPublishedSnapshotBox {
  private var snapshot: SignedSceneCatalogSnapshot?

  var hasSnapshot: Bool { snapshot != nil }

  func replace(with snapshot: SignedSceneCatalogSnapshot?) {
    self.snapshot = snapshot
  }

  func requiredSnapshot() throws -> SignedSceneCatalogSnapshot {
    guard let snapshot else {
      throw LANSceneCatalogCoordinatorError.noPublishedSnapshot
    }
    return snapshot
  }
}

private struct LANSceneCatalogCredentialReference: Codable, Hashable, Sendable {
  let projectID: UUID
  let catalogID: UUID
  let pskIdentity: UUID

  init(_ reference: SceneCatalogCredentialReference) {
    projectID = reference.projectID
    catalogID = reference.catalogID
    pskIdentity = reference.pskIdentity
  }

  var networkReference: SceneCatalogCredentialReference {
    SceneCatalogCredentialReference(
      projectID: projectID,
      catalogID: catalogID,
      pskIdentity: pskIdentity
    )
  }
}

private struct LANSceneCatalogPairingWitness: Codable, Hashable, Sendable {
  let reference: LANSceneCatalogCredentialReference
  let authorityID: UUID
  let authorityEpoch: UUID
  let catalogFingerprint: SHA256Value
  let serviceName: String
  let pairedAt: CanonicalTimestamp
}

private struct LANSceneCatalogMasterMetadata: Codable, Hashable, Sendable {
  let authority: SceneCatalogAuthorityMetadata
  var serviceName: String
  var pairedClients: [LANSceneCatalogPairingWitness]
}

private struct LANSceneCatalogClientMetadata: Codable, Hashable, Sendable {
  var pairing: LANSceneCatalogPairingWitness?
}

private struct LANSceneCatalogProjectMetadata: Codable, Hashable, Sendable {
  let schemaVersion: UInt16
  let projectID: UUID
  var master: LANSceneCatalogMasterMetadata?
  var client: LANSceneCatalogClientMetadata?
  var updatedAt: CanonicalTimestamp

  static func empty(projectID: UUID) -> Self {
    Self(
      schemaVersion: 1,
      projectID: projectID,
      master: nil,
      client: nil,
      updatedAt: .now
    )
  }

  func validate(projectID expectedProjectID: UUID) throws {
    guard schemaVersion == 1, projectID == expectedProjectID else {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }
    if let master {
      guard master.authority.scope.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.authorityMetadataMismatch
      }
      try LANSceneCatalogCoordinator.validateServiceName(master.serviceName)
      var references = Set<LANSceneCatalogCredentialReference>()
      for pairing in master.pairedClients {
        guard pairing.reference.projectID == projectID,
          pairing.reference.catalogID == master.authority.scope.catalogID,
          pairing.authorityID == master.authority.scope.authorityID,
          pairing.authorityEpoch == master.authority.scope.authorityEpoch,
          pairing.catalogFingerprint.hex == master.authority.catalogKeyID,
          references.insert(pairing.reference).inserted
        else {
          throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
        }
        try LANSceneCatalogCoordinator.validateServiceName(pairing.serviceName)
      }
    }
    if let pairing = client?.pairing {
      guard pairing.reference.projectID == projectID else {
        throw LANSceneCatalogCoordinatorError.credentialMetadataMismatch
      }
      try LANSceneCatalogCoordinator.validateServiceName(pairing.serviceName)
    }
  }
}

private struct LANSceneCatalogMetadataEnvelope: Codable, Sendable {
  let storageVersion: UInt16
  let payload: Data
  let payloadSHA256: SHA256Value
}

/// Small, non-secret, checksummed metadata store. Writes use a same-directory
/// temporary file, fsync, atomic rename, and directory fsync. Secret pairing
/// bytes and signing keys have no Codable path into this store.
private actor LANSceneCatalogMetadataStore {
  private static let maximumFileBytes = 2 * 1_024 * 1_024
  private let baseDirectoryURL: URL

  init(baseDirectoryURL: URL) {
    self.baseDirectoryURL = baseDirectoryURL.standardizedFileURL
  }

  func load(projectID: UUID) throws -> LANSceneCatalogProjectMetadata? {
    let url = metadataURL(projectID: projectID)
    guard let encoded = try Self.readDataWithoutFollowingSymlinks(at: url) else { return nil }
    guard encoded.count <= Self.maximumFileBytes else {
      throw LANSceneCatalogCoordinatorError.metadataTooLarge
    }
    let envelope: LANSceneCatalogMetadataEnvelope
    do {
      envelope = try JSONDecoder().decode(LANSceneCatalogMetadataEnvelope.self, from: encoded)
    } catch {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }
    guard envelope.storageVersion == 1,
      envelope.payload.count <= Self.maximumFileBytes,
      SHA256Value.hash(envelope.payload) == envelope.payloadSHA256
    else {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }
    let metadata: LANSceneCatalogProjectMetadata
    do {
      metadata = try JSONDecoder().decode(
        LANSceneCatalogProjectMetadata.self,
        from: envelope.payload
      )
    } catch {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }
    try metadata.validate(projectID: projectID)
    return metadata
  }

  func save(_ metadata: LANSceneCatalogProjectMetadata) throws {
    try metadata.validate(projectID: metadata.projectID)
    let directory = projectDirectory(metadata.projectID)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )

    let payloadEncoder = JSONEncoder()
    payloadEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try payloadEncoder.encode(metadata)
    guard payload.count <= Self.maximumFileBytes else {
      throw LANSceneCatalogCoordinatorError.metadataTooLarge
    }
    let envelope = LANSceneCatalogMetadataEnvelope(
      storageVersion: 1,
      payload: payload,
      payloadSHA256: .hash(payload)
    )
    let envelopeEncoder = JSONEncoder()
    envelopeEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try envelopeEncoder.encode(envelope)
    guard encoded.count <= Self.maximumFileBytes else {
      throw LANSceneCatalogCoordinatorError.metadataTooLarge
    }
    try Self.atomicWrite(encoded, to: metadataURL(projectID: metadata.projectID))
  }

  private func projectDirectory(_ projectID: UUID) -> URL {
    baseDirectoryURL
      .appendingPathComponent("Projects", isDirectory: true)
      .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
  }

  private func metadataURL(projectID: UUID) -> URL {
    projectDirectory(projectID).appendingPathComponent("lan-catalog.metadata", isDirectory: false)
  }

  private static func readDataWithoutFollowingSymlinks(at url: URL) throws -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "open", code: errno)
    }
    defer { _ = Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "fstat", code: errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0,
      metadata.st_size <= off_t(maximumFileBytes)
    else {
      throw LANSceneCatalogCoordinatorError.metadataCorrupt
    }

    var data = Data()
    data.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw LANSceneCatalogCoordinatorError.metadataIO(operation: "read", code: errno)
      }
      guard data.count <= maximumFileBytes - count else {
        throw LANSceneCatalogCoordinatorError.metadataTooLarge
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  private static func atomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
      isDirectory: false
    )
    var temporaryExists = false
    defer {
      if temporaryExists {
        try? FileManager.default.removeItem(at: temporary)
      }
    }
    do {
      try data.write(to: temporary, options: [.withoutOverwriting])
      temporaryExists = true
    } catch {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "create", code: errno)
    }
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporary.path
      )
    } catch {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "chmod", code: errno)
    }

    let descriptor = Darwin.open(temporary.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "open", code: errno)
    }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "fsync", code: errno)
    }
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(operation: "rename", code: errno)
    }
    temporaryExists = false

    let directoryDescriptor = Darwin.open(
      destination.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(
        operation: "open directory",
        code: errno
      )
    }
    defer { _ = Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw LANSceneCatalogCoordinatorError.metadataIO(
        operation: "fsync directory",
        code: errno
      )
    }
  }
}
