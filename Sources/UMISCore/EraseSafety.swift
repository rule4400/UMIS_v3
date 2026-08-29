import CryptoKit
import Foundation

public enum CardFileSystem: String, Codable, Sendable {
    case exFAT = "ExFAT"
}

public struct CardFormatProfile: Codable, Hashable, Sendable {
    public var version: Int
    public var fileSystem: CardFileSystem
    public var label: String

    public init(version: Int = 1, fileSystem: CardFileSystem = .exFAT, label: String) throws {
        self.version = version
        self.fileSystem = fileSystem
        self.label = try Self.validateLabel(label)
    }

    public static func validateLabel(_ label: String) throws -> String {
        guard (1 ... 11).contains(label.utf8.count), label == label.uppercased() else {
            throw UMISCoreError.unsafeEraseTarget("Card label must be 1-11 uppercase ASCII characters")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard label.unicodeScalars.allSatisfy(allowed.contains), !label.hasPrefix("-") else {
            throw UMISCoreError.unsafeEraseTarget("Card label contains an unsupported character")
        }
        return label
    }
}

public struct FinalVerificationEvidence: Hashable, Sendable {
    public let ingestReceipt: IngestReceipt
    public let requiredSet: RequiredSet
    public let sourceFullHashes: [MediaAssetID: String]
    public let destinationFullHashes: [RequiredDelivery: String]
    public let sourceManifestDigest: String
    public let destinationIdentity: DestinationIdentity
    public let destinationIdentityDigest: String
    public let localJournalDurablyCommitted: Bool
    public let noSourceWorkerIsRunning: Bool
    public let verifiedAt: Date

    init(
        ingestReceipt: IngestReceipt,
        requiredSet: RequiredSet,
        sourceFullHashes: [MediaAssetID: String],
        destinationFullHashes: [RequiredDelivery: String],
        sourceManifestDigest: String,
        destinationIdentity: DestinationIdentity = DestinationIdentity(rootURL: URL(fileURLWithPath: "/")),
        destinationIdentityDigest: String,
        localJournalDurablyCommitted: Bool,
        noSourceWorkerIsRunning: Bool,
        verifiedAt: Date = Date()
    ) {
        self.ingestReceipt = ingestReceipt
        self.requiredSet = requiredSet
        self.sourceFullHashes = sourceFullHashes
        self.destinationFullHashes = destinationFullHashes
        self.sourceManifestDigest = sourceManifestDigest
        self.destinationIdentity = destinationIdentity
        self.destinationIdentityDigest = destinationIdentityDigest
        self.localJournalDurablyCommitted = localJournalDurablyCommitted
        self.noSourceWorkerIsRunning = noSourceWorkerIsRunning
        self.verifiedAt = verifiedAt
    }
}

/// Performs the mandatory fresh, full-file source and destination verification. This is the only
/// public production entry that can create `FinalVerificationEvidence`.
public actor FinalVerificationService {
    private let store: OperationStore
    private let activity: VolumeIOActivityRegistry?
    private let destinationRevalidator: DestinationIdentityRevalidationHandler?

    public init(
        store: OperationStore,
        activity: VolumeIOActivityRegistry? = nil,
        destinationRevalidator: DestinationIdentityRevalidationHandler? = nil
    ) {
        self.store = store
        self.activity = activity
        self.destinationRevalidator = destinationRevalidator
    }

    public func verify(
        runID: IngestRunID,
        currentIdentity: VolumeIdentity,
        cancellation: OperationCancellation? = nil
    ) async throws -> FinalVerificationEvidence {
        let plan = try await store.loadIngestPlan(runID: runID)
        let currentDestination = try await revalidateDestination(plan.destination)
        return try await verify(
            plan: plan,
            currentIdentity: currentIdentity,
            currentDestinationIdentity: currentDestination,
            cancellation: cancellation
        )
    }

    public func verify(
        runID: IngestRunID,
        currentIdentity: VolumeIdentity,
        currentDestinationIdentity: DestinationIdentity,
        cancellation: OperationCancellation? = nil
    ) async throws -> FinalVerificationEvidence {
        let plan = try await store.loadIngestPlan(runID: runID)
        let freshlyResolved = try await revalidateDestination(currentDestinationIdentity)
        guard freshlyResolved == plan.destination else { throw UMISCoreError.identityChanged }
        return try await verify(
            plan: plan,
            currentIdentity: currentIdentity,
            currentDestinationIdentity: freshlyResolved,
            cancellation: cancellation
        )
    }

    private func verify(
        plan: IngestPlan,
        currentIdentity: VolumeIdentity,
        currentDestinationIdentity: DestinationIdentity,
        cancellation: OperationCancellation?
    ) async throws -> FinalVerificationEvidence {
        guard plan.sourceVolume.securityDigest == currentIdentity.securityDigest else {
            throw UMISCoreError.identityChanged
        }
        try VolumeIndependenceValidator.validate(
            source: currentIdentity,
            destination: currentDestinationIdentity
        )
        guard plan.requiredSet.isStructurallyEligibleForErase else {
            throw UMISCoreError.eraseNotEligible("Required Set is empty or inventory review is incomplete")
        }
        if let activity, await activity.isActive(sourceVolumeID: plan.sourceVolume.id) {
            throw UMISCoreError.eraseNotEligible("A source reader is still active")
        }
        guard let receipt = try await store.loadReceipt(runID: plan.runID) else {
            throw UMISCoreError.eraseNotEligible("The ingest operation has no durable receipt")
        }
        guard receipt.requiredSetDigest == (try StableDigest.encode(plan.requiredSet)) else {
            throw UMISCoreError.eraseNotEligible("Required Set no longer matches the durable receipt")
        }
        let receiptAssetIDs = receipt.deliveries.map(\.assetID)
        guard receiptAssetIDs.count == Set(receiptAssetIDs).count,
              Set(receiptAssetIDs) == plan.requiredSet.assetIDs,
              receipt.deliveries.count == plan.requiredSet.assetIDs.count,
              receipt.deliveries.allSatisfy({ $0.destinationID == plan.destination.id }) else {
            throw UMISCoreError.eraseNotEligible("Receipt does not exactly cover every required destination obligation")
        }
        if let sourceRoot = plan.sourceVolume.mountURL {
            let finalInventory = try await MediaScanner().scan(
                root: sourceRoot,
                sourceVolumeID: plan.sourceVolume.id,
                policy: plan.scanPolicy
            )
            guard finalInventory.inventoryDigest == plan.requiredSet.inventoryDigest else {
                throw UMISCoreError.eraseNotEligible("Final source inventory differs from the frozen manifest")
            }
        } else {
            throw UMISCoreError.eraseNotEligible("Source mount is unavailable for final inventory rescan")
        }
        let journalItems = try await store.items(operationID: plan.runID.rawValue)
        guard journalItems.count == plan.items.count,
              journalItems.allSatisfy({ $0.state == .durableCommitted || $0.state == .durableVerifiedExisting }) else {
            throw UMISCoreError.eraseNotEligible("One or more journal items are not durable")
        }
        let receiptByAsset = Dictionary(uniqueKeysWithValues: receipt.deliveries.map { ($0.assetID, $0) })
        var sourceHashes: [MediaAssetID: String] = [:]
        var destinationHashes: [RequiredDelivery: String] = [:]
        for assetID in plan.requiredSet.assetIDs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            try Task.checkCancellation()
            try await cancellation?.check()
            guard let item = plan.items.first(where: { $0.asset.id == assetID }),
                  let deliveryReceipt = receiptByAsset[assetID] else {
                throw UMISCoreError.eraseNotEligible("Required asset is missing from the frozen plan or receipt")
            }
            guard deliveryReceipt.itemID == item.id,
                  deliveryReceipt.finalURL.standardizedFileURL == item.finalURL.standardizedFileURL else {
                throw UMISCoreError.eraseNotEligible(
                    "Receipt path or item identity does not match the frozen delivery plan"
                )
            }
            let source = try await StreamingSHA256.hashFile(
                at: item.sourceURL,
                chunkSize: 1_048_576,
                cancellation: cancellation
            )
            guard source.sha256 == deliveryReceipt.sourceSHA256,
                  source.byteSize == deliveryReceipt.byteSize else {
                throw UMISCoreError.hashMismatch(item.sourceURL.path)
            }
            sourceHashes[assetID] = source.sha256
            let obligations = plan.requiredSet.deliveries.filter { $0.assetID == assetID }
            guard obligations.count == 1 else {
                throw UMISCoreError.eraseNotEligible("Required asset lacks exactly one destination obligation")
            }
            for obligation in obligations {
                guard obligation.destinationID == deliveryReceipt.destinationID else {
                    throw UMISCoreError.eraseNotEligible("Receipt destination does not satisfy Required Delivery Set")
                }
                let destination = try await StreamingSHA256.hashDestinationFile(
                    at: item.finalURL,
                    destination: currentDestinationIdentity,
                    sourceDeviceIdentifier: currentIdentity.volumeDeviceIdentifier,
                    expectedFingerprint: deliveryReceipt.finalFingerprint,
                    chunkSize: 1_048_576,
                    cancellation: cancellation
                )
                guard destination.sha256 == source.sha256,
                      destination.byteSize == source.byteSize else {
                    throw UMISCoreError.hashMismatch(deliveryReceipt.finalURL.path)
                }
                destinationHashes[obligation] = destination.sha256
            }
        }
        return FinalVerificationEvidence(
            ingestReceipt: receipt,
            requiredSet: plan.requiredSet,
            sourceFullHashes: sourceHashes,
            destinationFullHashes: destinationHashes,
            sourceManifestDigest: plan.requiredSet.inventoryDigest,
            destinationIdentity: currentDestinationIdentity,
            destinationIdentityDigest: try StableDigest.encode(currentDestinationIdentity),
            localJournalDurablyCommitted: true,
            noSourceWorkerIsRunning: true,
            verifiedAt: Date()
        )
    }

    private func revalidateDestination(
        _ expected: DestinationIdentity
    ) async throws -> DestinationIdentity {
        if let destinationRevalidator {
            return try await destinationRevalidator(expected)
        }
        return try DestinationIdentityResolver().revalidate(expected)
    }
}

public struct EraseAuthorizationToken: Sendable, Hashable {
    public let nonce: UUID
    public let runID: IngestRunID
    public let sourceVolumeID: SourceVolumeID
    public let issuedAt: Date
    public let expiresAt: Date
    public let cardIdentityDigest: String
    public let arrivalGeneration: UUID
    public let sourceManifestDigest: String
    public let requiredDeliveryDigest: String
    public let verificationReceiptDigest: String
    public let destinationIdentityDigest: String
    public let formatProfileDigest: String
    /// A compatibility token issued before a retained media claim uses the legacy marker. Only an
    /// internally minted token whose value matches a live `PreparedCardEraseTarget` can cross the
    /// destructive backend boundary.
    public let destructiveHandleDigest: String
    fileprivate let authenticator: Data

    fileprivate init(
        nonce: UUID,
        runID: IngestRunID,
        sourceVolumeID: SourceVolumeID,
        issuedAt: Date,
        expiresAt: Date,
        cardIdentityDigest: String,
        arrivalGeneration: UUID,
        sourceManifestDigest: String,
        requiredDeliveryDigest: String,
        verificationReceiptDigest: String,
        destinationIdentityDigest: String,
        formatProfileDigest: String,
        destructiveHandleDigest: String,
        authenticator: Data
    ) {
        self.nonce = nonce
        self.runID = runID
        self.sourceVolumeID = sourceVolumeID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.cardIdentityDigest = cardIdentityDigest
        self.arrivalGeneration = arrivalGeneration
        self.sourceManifestDigest = sourceManifestDigest
        self.requiredDeliveryDigest = requiredDeliveryDigest
        self.verificationReceiptDigest = verificationReceiptDigest
        self.destinationIdentityDigest = destinationIdentityDigest
        self.formatProfileDigest = formatProfileDigest
        self.destructiveHandleDigest = destructiveHandleDigest
        self.authenticator = authenticator
    }
}

public struct CardEraseResult: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case outcomeUnknown
        case postFormatValidationFailed
    }

    public var outcome: Outcome
    public var beforeIdentity: VolumeIdentity
    public var afterIdentity: VolumeIdentity?
    public var postFormatProbeSucceeded: Bool
    public var completedAt: Date

    public init(
        outcome: Outcome,
        beforeIdentity: VolumeIdentity,
        afterIdentity: VolumeIdentity?,
        postFormatProbeSucceeded: Bool,
        completedAt: Date = Date()
    ) {
        self.outcome = outcome
        self.beforeIdentity = beforeIdentity
        self.afterIdentity = afterIdentity
        self.postFormatProbeSucceeded = postFormatProbeSucceeded
        self.completedAt = completedAt
    }
}

/// Unforgeable outside UMISCore. It is created only after `EraseGate` atomically consumes a valid nonce.
public struct ConsumedEraseCapability: Sendable {
    public let nonce: UUID
    public let expectedIdentityDigest: String
    public let preparedHandleID: UUID
    public let destructiveHandleDigest: String
}

/// An opaque reference to a retained, exclusively claimed physical-media object. The identity is
/// the final fresh DA/IOKit observation made after the claim (and, for erase, after unmount). The
/// backend must keep the underlying OS object retained until it executes or abandons this handle.
public struct PreparedCardEraseTarget: Sendable, Hashable {
    public let handleID: UUID
    public let authorizedIdentity: VolumeIdentity
    public let freshlyRevalidatedIdentity: VolumeIdentity
    public let claimEvidenceDigest: String
    public let preparedAt: Date
    public let expiresAt: Date
    public let authorizationBindingDigest: String

    public init(
        handleID: UUID = UUID(),
        authorizedIdentity: VolumeIdentity,
        freshlyRevalidatedIdentity: VolumeIdentity,
        claimEvidenceDigest: String,
        preparedAt: Date = Date(),
        expiresAt: Date
    ) throws {
        let normalizedEvidence = claimEvidenceDigest.lowercased()
        guard normalizedEvidence.utf8.count == 64,
              normalizedEvidence.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }),
              expiresAt > preparedAt else {
            throw UMISCoreError.invalidPlan("Invalid retained-media claim evidence or lifetime")
        }
        self.handleID = handleID
        self.authorizedIdentity = authorizedIdentity
        self.freshlyRevalidatedIdentity = freshlyRevalidatedIdentity
        self.claimEvidenceDigest = normalizedEvidence
        self.preparedAt = preparedAt
        self.expiresAt = expiresAt
        authorizationBindingDigest = try StableDigest.encode(PreparedTargetBindingFields(
            handleID: handleID,
            authorizedIdentityDigest: authorizedIdentity.securityDigest,
            freshlyRevalidatedIdentityDigest: freshlyRevalidatedIdentity.securityDigest,
            claimEvidenceDigest: normalizedEvidence,
            preparedAt: preparedAt,
            expiresAt: expiresAt
        ))
    }
}

public protocol CardEraseBackend: Sendable {
    /// Must return a fresh observation, not a cached UI model.
    func currentIdentity(expectedSourceID: SourceVolumeID) async throws -> VolumeIdentity
    /// Must retain/claim the physical media, unmount while that claim remains held, and return only
    /// after a fresh DA/IOKit/topology observation proves the same insertion. Implementations that
    /// cannot retain such an OS object must fail closed before invoking an unmount helper.
    func prepareDestructiveTarget(
        expectedIdentity: VolumeIdentity,
        timeout: TimeInterval
    ) async throws -> PreparedCardEraseTarget
    /// Executes against the already retained handle. The handle and capability are both one-shot.
    func erase(
        preparedTarget: PreparedCardEraseTarget,
        profile: CardFormatProfile,
        authorization: ConsumedEraseCapability
    ) async throws -> CardEraseResult
    /// Releases a prepared claim that did not enter the destructive call. This must be idempotent.
    func abandonPreparedTarget(_ preparedTarget: PreparedCardEraseTarget) async
}

public actor EraseGate {
    private enum NonceState {
        case issued
        case consuming
        case consumed
    }
    private static let legacyUnpreparedHandleDigest = String(repeating: "0", count: 64)

    private let secret: SymmetricKey
    private let store: OperationStore?
    private let activity: VolumeIOActivityRegistry?
    private let destinationRevalidator: DestinationIdentityRevalidationHandler?
    private let tokenLifetime: TimeInterval
    private let finalVerificationFreshness: TimeInterval
    private var nonces: [UUID: NonceState] = [:]

    public init(
        store: OperationStore? = nil,
        activity: VolumeIOActivityRegistry? = nil,
        destinationRevalidator: DestinationIdentityRevalidationHandler? = nil,
        tokenLifetime: TimeInterval = 120,
        finalVerificationFreshness: TimeInterval = 60
    ) {
        secret = SymmetricKey(size: .bits256)
        self.store = store
        self.activity = activity
        self.destinationRevalidator = destinationRevalidator
        self.tokenLifetime = tokenLifetime
        self.finalVerificationFreshness = finalVerificationFreshness
    }

    public func issue(
        evidence: FinalVerificationEvidence,
        profile: CardFormatProfile,
        currentIdentity: VolumeIdentity,
        currentDestinationIdentity: DestinationIdentity? = nil,
        now: Date = Date()
    ) async throws -> EraseAuthorizationToken {
        try validateTarget(currentIdentity)
        try VolumeIndependenceValidator.validate(
            source: currentIdentity,
            destination: evidence.destinationIdentity
        )
        try validateEvidence(evidence, identity: currentIdentity, now: now)
        guard let store else {
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        // Re-run every source/destination full hash at the destructive confirmation boundary.
        if evidence.destinationIdentity.isNetwork, currentDestinationIdentity == nil {
            throw UMISCoreError.eraseNotEligible(
                "A fresh destination mount-generation observation is required for network storage"
            )
        }
        let verifier = FinalVerificationService(
            store: store,
            activity: activity,
            destinationRevalidator: destinationRevalidator
        )
        let refreshed: FinalVerificationEvidence
        if let currentDestinationIdentity {
            refreshed = try await verifier.verify(
                runID: evidence.ingestReceipt.runID,
                currentIdentity: currentIdentity,
                currentDestinationIdentity: currentDestinationIdentity
            )
        } else {
            refreshed = try await verifier.verify(
                runID: evidence.ingestReceipt.runID,
                currentIdentity: currentIdentity
            )
        }
        guard try verificationDigest(refreshed) == verificationDigest(evidence) else {
            throw UMISCoreError.eraseNotEligible("Verification evidence changed before authorization")
        }
        // Timestamp only after the potentially long full verification. Using the method-entry
        // timestamp can produce an already-expired authorization on large cards.
        return try await mintToken(
            evidence: refreshed,
            profile: profile,
            identity: currentIdentity,
            destructiveHandleDigest: Self.legacyUnpreparedHandleDigest,
            issuedAt: Date()
        )
    }

    /// Production destructive entry point. Call this only after the user has confirmed the final
    /// dialog. It performs one fresh full verification and immediately consumes an internal token
    /// in the same actor-serialized action; no token is exposed across a UI confirmation window.
    public func eraseAfterUserConfirmation(
        runID: IngestRunID,
        profile: CardFormatProfile,
        currentIdentity: VolumeIdentity,
        currentDestinationIdentity: DestinationIdentity? = nil,
        backend: any CardEraseBackend
    ) async throws -> CardEraseResult {
        guard let activity else {
            throw UMISCoreError.eraseNotEligible(
                "Confirmed erase requires a VolumeIOActivityRegistry for quiesce and timeout quarantine"
            )
        }
        guard let store else {
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        return try await activity.withQuiescedVolume(
            identity: currentIdentity,
            durableStore: store
        ) {
            try await self.performConfirmedErase(
                runID: runID,
                profile: profile,
                currentIdentity: currentIdentity,
                currentDestinationIdentity: currentDestinationIdentity,
                backend: backend
            )
        }
    }

    private func performConfirmedErase(
        runID: IngestRunID,
        profile: CardFormatProfile,
        currentIdentity: VolumeIdentity,
        currentDestinationIdentity: DestinationIdentity?,
        backend: any CardEraseBackend
    ) async throws -> CardEraseResult {
        guard let store else {
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        if let activity, await activity.isActive(sourceVolumeID: currentIdentity.id) {
            throw UMISCoreError.eraseNotEligible("A source reader is still active")
        }
        let observedBeforeVerification = try await backend.currentIdentity(expectedSourceID: currentIdentity.id)
        guard observedBeforeVerification.securityDigest == currentIdentity.securityDigest else {
            throw UMISCoreError.identityChanged
        }
        try validateTarget(observedBeforeVerification)
        let verifier = FinalVerificationService(
            store: store,
            activity: activity,
            destinationRevalidator: destinationRevalidator
        )
        let refreshed: FinalVerificationEvidence
        if let currentDestinationIdentity {
            refreshed = try await verifier.verify(
                runID: runID,
                currentIdentity: observedBeforeVerification,
                currentDestinationIdentity: currentDestinationIdentity
            )
        } else {
            let plan = try await store.loadIngestPlan(runID: runID)
            guard !plan.destination.isNetwork else {
                throw UMISCoreError.eraseNotEligible(
                    "A fresh app-observed destination mount generation is required for network storage"
                )
            }
            refreshed = try await verifier.verify(runID: runID, currentIdentity: observedBeforeVerification)
        }
        try validateEvidence(refreshed, identity: observedBeforeVerification, now: Date())
        return try await prepareAndExecute(
            profile: profile,
            backend: backend,
            verifiedEvidence: refreshed,
            authorizedIdentity: observedBeforeVerification
        )
    }

    private func mintToken(
        evidence: FinalVerificationEvidence,
        profile: CardFormatProfile,
        identity: VolumeIdentity,
        destructiveHandleDigest: String,
        issuedAt: Date
    ) async throws -> EraseAuthorizationToken {
        guard let store else {
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        let nonce = UUID()
        let canonicalDeliveries = evidence.requiredSet.deliveries.sorted {
            let left = $0.assetID.rawValue.uuidString + "|" + $0.destinationID.rawValue.uuidString
            let right = $1.assetID.rawValue.uuidString + "|" + $1.destinationID.rawValue.uuidString
            return left < right
        }
        let requiredDeliveryDigest = try StableDigest.encode(canonicalDeliveries)
        let receiptDigest = try StableDigest.encode(evidence.ingestReceipt)
        let profileDigest = try StableDigest.encode(profile)
        let expires = issuedAt.addingTimeInterval(tokenLifetime)
        let fields = TokenFields(
            nonce: nonce,
            runID: evidence.ingestReceipt.runID,
            sourceVolumeID: identity.id,
            issuedAt: issuedAt,
            expiresAt: expires,
            cardIdentityDigest: identity.securityDigest,
            arrivalGeneration: identity.arrivalGeneration,
            sourceManifestDigest: evidence.sourceManifestDigest,
            requiredDeliveryDigest: requiredDeliveryDigest,
            verificationReceiptDigest: receiptDigest,
            destinationIdentityDigest: evidence.destinationIdentityDigest,
            formatProfileDigest: profileDigest,
            destructiveHandleDigest: destructiveHandleDigest
        )
        let mac = Data(HMAC<SHA256>.authenticationCode(for: try StableJSON.encode(fields), using: secret))
        let token = EraseAuthorizationToken(
            nonce: nonce,
            runID: fields.runID,
            sourceVolumeID: fields.sourceVolumeID,
            issuedAt: issuedAt,
            expiresAt: expires,
            cardIdentityDigest: fields.cardIdentityDigest,
            arrivalGeneration: fields.arrivalGeneration,
            sourceManifestDigest: fields.sourceManifestDigest,
            requiredDeliveryDigest: fields.requiredDeliveryDigest,
            verificationReceiptDigest: fields.verificationReceiptDigest,
            destinationIdentityDigest: fields.destinationIdentityDigest,
            formatProfileDigest: fields.formatProfileDigest,
            destructiveHandleDigest: fields.destructiveHandleDigest,
            authenticator: mac
        )
        nonces[nonce] = .issued
        try await store.appendAudit(
            operationID: token.runID.rawValue,
            event: "erase.tokenIssued",
            payload: Data(token.nonce.uuidString.utf8)
        )
        return token
    }

    public func consume(
        token: EraseAuthorizationToken,
        profile: CardFormatProfile,
        backend: any CardEraseBackend,
        now: Date = Date()
    ) async throws -> CardEraseResult {
        try claim(token: token, profile: profile, now: now)
        guard let store else {
            nonces[token.nonce] = .consumed
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        do {
            guard token.destructiveHandleDigest == Self.legacyUnpreparedHandleDigest else {
                throw UMISCoreError.invalidToken
            }
            let observedBeforeVerification = try await backend.currentIdentity(
                expectedSourceID: token.sourceVolumeID
            )
            guard observedBeforeVerification.securityDigest == token.cardIdentityDigest,
                  observedBeforeVerification.arrivalGeneration == token.arrivalGeneration else {
                throw UMISCoreError.identityChanged
            }
            try validateTarget(observedBeforeVerification)
            let plan = try await store.loadIngestPlan(runID: token.runID)
            guard !plan.destination.isNetwork else {
                throw UMISCoreError.eraseNotEligible(
                    "Legacy token consumption cannot establish a fresh network mount generation; use eraseAfterUserConfirmation"
                )
            }
            // A token held open across a UI confirmation never authorizes stale data: re-read the
            // complete source, complete destination, manifest, and durable journal at consumption.
            let refreshed = try await FinalVerificationService(
                store: store,
                activity: activity,
                destinationRevalidator: destinationRevalidator
            ).verify(
                runID: token.runID,
                currentIdentity: observedBeforeVerification
            )
            try validateTokenBindings(token, evidence: refreshed)
            try validateEvidence(refreshed, identity: observedBeforeVerification, now: Date())
            // The compatibility token is only a replay-protected confirmation ticket. It is never
            // handed to a backend. The destructive token is minted below, after a retained claim.
            nonces[token.nonce] = .consumed
            try await store.appendAudit(
                operationID: token.runID.rawValue,
                event: "erase.compatibilityConfirmationConsumed",
                payload: Data(token.nonce.uuidString.utf8)
            )
            return try await prepareAndExecute(
                profile: profile,
                backend: backend,
                verifiedEvidence: refreshed,
                authorizedIdentity: observedBeforeVerification
            )
        } catch {
            nonces[token.nonce] = .consumed
            throw error
        }
    }

    private func prepareAndExecute(
        profile: CardFormatProfile,
        backend: any CardEraseBackend,
        verifiedEvidence: FinalVerificationEvidence,
        authorizedIdentity: VolumeIdentity
    ) async throws -> CardEraseResult {
        let prepared = try await backend.prepareDestructiveTarget(
            expectedIdentity: authorizedIdentity,
            timeout: 15
        )
        do {
            try validatePreparedTarget(prepared, expectedIdentity: authorizedIdentity, now: Date())
            try await store?.appendAudit(
                operationID: verifiedEvidence.ingestReceipt.runID.rawValue,
                event: "erase.targetPrepared",
                payload: Data(prepared.handleID.uuidString.utf8)
            )
            let token = try await mintToken(
                evidence: verifiedEvidence,
                profile: profile,
                identity: authorizedIdentity,
                destructiveHandleDigest: prepared.authorizationBindingDigest,
                issuedAt: Date()
            )
            try claim(token: token, profile: profile, now: Date())
            return try await executePreparedToken(
                token: token,
                profile: profile,
                backend: backend,
                verifiedEvidence: verifiedEvidence,
                preparedTarget: prepared
            )
        } catch {
            await backend.abandonPreparedTarget(prepared)
            throw error
        }
    }

    private func claim(
        token: EraseAuthorizationToken,
        profile: CardFormatProfile,
        now: Date
    ) throws {
        guard let state = nonces[token.nonce] else { throw UMISCoreError.invalidToken }
        guard state == .issued else { throw UMISCoreError.reusedToken }
        guard now <= token.expiresAt else {
            nonces[token.nonce] = .consumed
            throw UMISCoreError.expiredToken
        }
        guard token.formatProfileDigest == (try StableDigest.encode(profile)) else {
            nonces[token.nonce] = .consumed
            throw UMISCoreError.invalidToken
        }
        let fields = TokenFields(token: token)
        let expectedMAC = HMAC<SHA256>.authenticationCode(for: try StableJSON.encode(fields), using: secret)
        guard Data(expectedMAC) == token.authenticator else {
            nonces[token.nonce] = .consumed
            throw UMISCoreError.invalidToken
        }
        // Reserve before any await. Actor reentrancy cannot admit a concurrent replay while full
        // verification or backend identity observation is in progress.
        nonces[token.nonce] = .consuming
    }

    private func executePreparedToken(
        token: EraseAuthorizationToken,
        profile: CardFormatProfile,
        backend: any CardEraseBackend,
        verifiedEvidence: FinalVerificationEvidence,
        preparedTarget: PreparedCardEraseTarget
    ) async throws -> CardEraseResult {
        let evidenceIdentityDigest = verifiedEvidence.ingestReceipt.sourceIdentityDigest
        guard evidenceIdentityDigest == token.cardIdentityDigest else {
            throw UMISCoreError.identityChanged
        }
        try validateTokenBindings(token, evidence: verifiedEvidence)
        let validationTime = Date()
        if let activity, await activity.isActive(sourceVolumeID: token.sourceVolumeID) {
            throw UMISCoreError.eraseNotEligible("A source reader became active at the destructive boundary")
        }
        try validatePreparedTarget(
            preparedTarget,
            expectedIdentity: preparedTarget.authorizedIdentity,
            now: validationTime
        )
        let observed = preparedTarget.authorizedIdentity
        guard observed.securityDigest == token.cardIdentityDigest,
              observed.arrivalGeneration == token.arrivalGeneration,
              token.destructiveHandleDigest == preparedTarget.authorizationBindingDigest else {
            throw UMISCoreError.identityChanged
        }
        try validateEvidence(verifiedEvidence, identity: observed, now: validationTime)

        // The retained claim and post-unmount revalidation already exist. Consumption is now the
        // immediately preceding gate action before the one-shot backend call.
        nonces[token.nonce] = .consumed
        try await store?.appendAudit(
            operationID: token.runID.rawValue,
            event: "erase.tokenConsumed",
            payload: Data(token.nonce.uuidString.utf8)
        )
        guard let store else {
            throw UMISCoreError.eraseNotEligible("EraseGate requires a durable OperationStore authority")
        }
        let pendingReason = "Authorized erase backend started; completion has not yet been proven"
        if let activity {
            try await activity.quarantinePhysicalMedia(
                identity: observed,
                operationID: token.runID.rawValue,
                reason: pendingReason,
                durableStore: store
            )
        } else {
            _ = try await store.recordDestructiveQuarantine(
                identity: observed,
                operationID: token.runID.rawValue,
                reason: pendingReason
            )
        }
        do {
            let capability = ConsumedEraseCapability(
                nonce: token.nonce,
                expectedIdentityDigest: observed.securityDigest,
                preparedHandleID: preparedTarget.handleID,
                destructiveHandleDigest: preparedTarget.authorizationBindingDigest
            )
            let result = try await backend.erase(
                preparedTarget: preparedTarget,
                profile: profile,
                authorization: capability
            )
            guard result.beforeIdentity.securityDigest == observed.securityDigest else {
                throw UMISCoreError.identityChanged
            }
            if result.outcome == .completed {
                guard result.postFormatProbeSucceeded, result.afterIdentity != nil else {
                    throw UMISCoreError.backendFailure(
                        "Backend reported completion without post-format identity and write/read proof"
                    )
                }
            }
            switch result.outcome {
            case .completed:
                if let activity {
                    try await activity.resolvePhysicalQuarantineAfterKnownCompletion(
                        identity: observed,
                        operationID: token.runID.rawValue,
                        durableStore: store
                    )
                } else {
                    try await store.resolveDestructiveQuarantineAfterKnownCompletion(
                        identity: observed,
                        operationID: token.runID.rawValue
                    )
                }
            case .outcomeUnknown:
                let reason = "Card erase helper timed out; physical outcome is unknown"
                if let activity {
                    try await activity.quarantinePhysicalMedia(
                        identity: observed,
                        operationID: token.runID.rawValue,
                        reason: reason,
                        durableStore: store
                    )
                } else {
                    _ = try await store.recordDestructiveQuarantine(
                        identity: observed,
                        operationID: token.runID.rawValue,
                        reason: reason
                    )
                }
            case .postFormatValidationFailed:
                let reason = "Card format returned but post-format identity/write-read proof failed"
                if let activity {
                    try await activity.quarantinePhysicalMedia(
                        identity: observed,
                        operationID: token.runID.rawValue,
                        reason: reason,
                        durableStore: store
                    )
                } else {
                    _ = try await store.recordDestructiveQuarantine(
                        identity: observed,
                        operationID: token.runID.rawValue,
                        reason: reason
                    )
                }
            }
            try await store.appendAudit(
                operationID: token.runID.rawValue,
                event: "erase.\(result.outcome.rawValue)",
                payload: try StableJSON.encode(result)
            )
            return result
        } catch {
            try? await store.appendAudit(
                operationID: token.runID.rawValue,
                event: "erase.failed",
                payload: Data(String(describing: error).utf8)
            )
            throw error
        }
    }

    private func validateTokenBindings(
        _ token: EraseAuthorizationToken,
        evidence: FinalVerificationEvidence
    ) throws {
        let canonicalDeliveries = evidence.requiredSet.deliveries.sorted {
            let left = $0.assetID.rawValue.uuidString + "|" + $0.destinationID.rawValue.uuidString
            let right = $1.assetID.rawValue.uuidString + "|" + $1.destinationID.rawValue.uuidString
            return left < right
        }
        guard evidence.ingestReceipt.runID == token.runID,
              evidence.sourceManifestDigest == token.sourceManifestDigest,
              try StableDigest.encode(canonicalDeliveries) == token.requiredDeliveryDigest,
              try StableDigest.encode(evidence.ingestReceipt) == token.verificationReceiptDigest,
              evidence.destinationIdentityDigest == token.destinationIdentityDigest else {
            throw UMISCoreError.eraseNotEligible("Authorization token no longer matches fresh verification evidence")
        }
    }

    private func validatePreparedTarget(
        _ prepared: PreparedCardEraseTarget,
        expectedIdentity: VolumeIdentity,
        now: Date
    ) throws {
        guard prepared.authorizedIdentity.securityDigest == expectedIdentity.securityDigest,
              prepared.authorizedIdentity.arrivalGeneration == expectedIdentity.arrivalGeneration,
              prepared.freshlyRevalidatedIdentity.matchesSameEraseTarget(as: expectedIdentity),
              now >= prepared.preparedAt,
              now <= prepared.expiresAt else {
            throw UMISCoreError.identityChanged
        }
        try validateTarget(prepared.authorizedIdentity)
        try validateTarget(prepared.freshlyRevalidatedIdentity)
    }

    public func invalidateAll() { nonces.removeAll(keepingCapacity: false) }

    private func validateEvidence(
        _ evidence: FinalVerificationEvidence,
        identity: VolumeIdentity,
        now: Date
    ) throws {
        guard evidence.requiredSet.isStructurallyEligibleForErase else {
            throw UMISCoreError.eraseNotEligible("Required Set is empty, incomplete, unreviewed, or contains scan errors")
        }
        guard evidence.localJournalDurablyCommitted else {
            throw UMISCoreError.eraseNotEligible("Operation journal is not durably committed")
        }
        guard evidence.noSourceWorkerIsRunning else {
            throw UMISCoreError.eraseNotEligible("A source reader is still active")
        }
        guard now.timeIntervalSince(evidence.verifiedAt) >= 0,
              now.timeIntervalSince(evidence.verifiedAt) <= finalVerificationFreshness else {
            throw UMISCoreError.eraseNotEligible("Final full verification is stale")
        }
        guard evidence.ingestReceipt.sourceIdentityDigest == identity.securityDigest else {
            throw UMISCoreError.identityChanged
        }
        guard evidence.destinationIdentity.hasEraseGradeIdentity,
              evidence.destinationIdentityDigest == (try StableDigest.encode(evidence.destinationIdentity)) else {
            throw UMISCoreError.eraseNotEligible("Destination identity evidence is incomplete or inconsistent")
        }
        guard evidence.ingestReceipt.requiredSetDigest == (try StableDigest.encode(evidence.requiredSet)) else {
            throw UMISCoreError.eraseNotEligible("Receipt is not bound to the verified Required Set")
        }
        let groupedReceipts = Dictionary(grouping: evidence.ingestReceipt.deliveries) {
            RequiredDelivery(assetID: $0.assetID, destinationID: $0.destinationID)
        }
        guard !groupedReceipts.isEmpty,
              Set(groupedReceipts.keys) == evidence.requiredSet.deliveries,
              groupedReceipts.values.allSatisfy({ $0.count == 1 }),
              evidence.ingestReceipt.deliveries.count == evidence.requiredSet.assetIDs.count else {
            throw UMISCoreError.eraseNotEligible("Receipt does not exactly cover the Required Delivery Set")
        }
        for delivery in evidence.requiredSet.deliveries {
            guard let receipt = groupedReceipts[delivery]?.first else {
                throw UMISCoreError.eraseNotEligible("Missing required delivery receipt")
            }
            guard receipt.state == .durableCommitted || receipt.state == .durableVerifiedExisting else {
                throw UMISCoreError.eraseNotEligible("Delivery is not durable")
            }
            guard evidence.sourceFullHashes[delivery.assetID] == receipt.sourceSHA256,
                  evidence.destinationFullHashes[delivery] == receipt.sourceSHA256 else {
                throw UMISCoreError.hashMismatch(receipt.finalURL.path)
            }
        }
        guard Set(evidence.sourceFullHashes.keys) == evidence.requiredSet.assetIDs else {
            throw UMISCoreError.eraseNotEligible("Final source full-hash set differs from Required Asset Set")
        }
        guard Set(evidence.destinationFullHashes.keys) == evidence.requiredSet.deliveries else {
            throw UMISCoreError.eraseNotEligible("Final destination full-hash set differs from Required Delivery Set")
        }
    }

    private func verificationDigest(_ evidence: FinalVerificationEvidence) throws -> String {
        let sourceHashes = evidence.sourceFullHashes
            .map { ($0.key.rawValue.uuidString, $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
        let destinationHashes = evidence.destinationFullHashes
            .map { ("\($0.key.assetID.rawValue.uuidString)|\($0.key.destinationID.rawValue.uuidString)", $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
        return try StableDigest.encode([
            try StableDigest.encode(evidence.ingestReceipt),
            try StableDigest.encode(evidence.requiredSet),
            evidence.sourceManifestDigest,
            try StableDigest.encode(evidence.destinationIdentity),
            evidence.destinationIdentityDigest,
            sourceHashes.joined(separator: "|"),
            destinationHashes.joined(separator: "|"),
        ])
    }

    private func validateTarget(_ identity: VolumeIdentity) throws {
        guard identity.identityStrength == .strongForCurrentInsertion else {
            throw UMISCoreError.unsafeEraseTarget("Media identity is not strong for this insertion")
        }
        guard identity.isCameraCardEraseEligible else {
            throw UMISCoreError.unsafeEraseTarget(
                "Physical media evidence does not prove an eligible Secure Digital camera card"
            )
        }
        guard !identity.isInternal else { throw UMISCoreError.unsafeEraseTarget("Internal media is never eligible") }
        guard identity.isRemovable, identity.isWritable else {
            throw UMISCoreError.unsafeEraseTarget("Media must be removable and writable")
        }
        guard !identity.isNetwork, !identity.isDiskImage else {
            throw UMISCoreError.unsafeEraseTarget("Network volumes and disk images are never eligible")
        }
        guard identity.partitionCount == 1 else {
            throw UMISCoreError.unsafeEraseTarget("Only a single leaf volume is supported")
        }
        guard let leaf = identity.bsdName,
              leaf.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              let whole = identity.wholeDiskBSDName,
              whole.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              leaf != whole else {
            throw UMISCoreError.unsafeEraseTarget("A validated leaf and whole-disk mapping is required")
        }
    }
}

private struct TokenFields: Codable, Hashable, Sendable {
    var nonce: UUID
    var runID: IngestRunID
    var sourceVolumeID: SourceVolumeID
    var issuedAt: Date
    var expiresAt: Date
    var cardIdentityDigest: String
    var arrivalGeneration: UUID
    var sourceManifestDigest: String
    var requiredDeliveryDigest: String
    var verificationReceiptDigest: String
    var destinationIdentityDigest: String
    var formatProfileDigest: String
    var destructiveHandleDigest: String

    init(
        nonce: UUID,
        runID: IngestRunID,
        sourceVolumeID: SourceVolumeID,
        issuedAt: Date,
        expiresAt: Date,
        cardIdentityDigest: String,
        arrivalGeneration: UUID,
        sourceManifestDigest: String,
        requiredDeliveryDigest: String,
        verificationReceiptDigest: String,
        destinationIdentityDigest: String,
        formatProfileDigest: String,
        destructiveHandleDigest: String
    ) {
        self.nonce = nonce
        self.runID = runID
        self.sourceVolumeID = sourceVolumeID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.cardIdentityDigest = cardIdentityDigest
        self.arrivalGeneration = arrivalGeneration
        self.sourceManifestDigest = sourceManifestDigest
        self.requiredDeliveryDigest = requiredDeliveryDigest
        self.verificationReceiptDigest = verificationReceiptDigest
        self.destinationIdentityDigest = destinationIdentityDigest
        self.formatProfileDigest = formatProfileDigest
        self.destructiveHandleDigest = destructiveHandleDigest
    }

    init(token: EraseAuthorizationToken) {
        self.init(
            nonce: token.nonce,
            runID: token.runID,
            sourceVolumeID: token.sourceVolumeID,
            issuedAt: token.issuedAt,
            expiresAt: token.expiresAt,
            cardIdentityDigest: token.cardIdentityDigest,
            arrivalGeneration: token.arrivalGeneration,
            sourceManifestDigest: token.sourceManifestDigest,
            requiredDeliveryDigest: token.requiredDeliveryDigest,
            verificationReceiptDigest: token.verificationReceiptDigest,
            destinationIdentityDigest: token.destinationIdentityDigest,
            formatProfileDigest: token.formatProfileDigest,
            destructiveHandleDigest: token.destructiveHandleDigest
        )
    }
}

private struct PreparedTargetBindingFields: Codable, Hashable, Sendable {
    var handleID: UUID
    var authorizedIdentityDigest: String
    var freshlyRevalidatedIdentityDigest: String
    var claimEvidenceDigest: String
    var preparedAt: Date
    var expiresAt: Date
}

public actor SimulatedCardEraseBackend: CardEraseBackend {
    private var identity: VolumeIdentity
    private var requestedIdentityAfterLookup: VolumeIdentity?
    private var requestedIdentityAfterPreparation: VolumeIdentity?
    private var preparedTargets: [UUID: PreparedCardEraseTarget] = [:]
    private var usedHandleIDs: Set<UUID> = []
    private var requests: [(VolumeIdentity, CardFormatProfile)] = []

    public init(identity: VolumeIdentity) {
        self.identity = identity
    }

    public func changeIdentity(to identity: VolumeIdentity) {
        self.identity = identity
    }

    public func changeIdentityAfterNextLookup(to identity: VolumeIdentity) {
        requestedIdentityAfterLookup = identity
    }

    public func changeIdentityAfterPreparation(to identity: VolumeIdentity) {
        requestedIdentityAfterPreparation = identity
    }

    public func currentIdentity(expectedSourceID: SourceVolumeID) async throws -> VolumeIdentity {
        let current = identity
        if let next = requestedIdentityAfterLookup {
            identity = next
            requestedIdentityAfterLookup = nil
        }
        _ = expectedSourceID
        return current
    }

    public func prepareDestructiveTarget(
        expectedIdentity: VolumeIdentity,
        timeout: TimeInterval
    ) async throws -> PreparedCardEraseTarget {
        guard timeout > 0 else {
            throw UMISCoreError.backendFailure("Simulated retained-media claim timed out")
        }
        guard identity.matchesSameEraseTarget(as: expectedIdentity) else {
            throw UMISCoreError.identityChanged
        }
        let evidence = CryptoKit.SHA256.hash(data: Data(
            "SIMULATED-RETAINED-CLAIM|\(UUID().uuidString)".utf8
        )).map { String(format: "%02x", $0) }.joined()
        let prepared = try PreparedCardEraseTarget(
            authorizedIdentity: expectedIdentity,
            freshlyRevalidatedIdentity: identity,
            claimEvidenceDigest: evidence,
            expiresAt: Date().addingTimeInterval(min(timeout, 30))
        )
        preparedTargets[prepared.handleID] = prepared
        if let next = requestedIdentityAfterPreparation {
            identity = next
            requestedIdentityAfterPreparation = nil
        }
        return prepared
    }

    public func erase(
        preparedTarget: PreparedCardEraseTarget,
        profile: CardFormatProfile,
        authorization: ConsumedEraseCapability
    ) async throws -> CardEraseResult {
        guard !usedHandleIDs.contains(preparedTarget.handleID),
              let active = preparedTargets.removeValue(forKey: preparedTarget.handleID) else {
            throw UMISCoreError.reusedToken
        }
        usedHandleIDs.insert(preparedTarget.handleID)
        let expectedIdentity = active.authorizedIdentity
        guard active == preparedTarget,
              authorization.expectedIdentityDigest == expectedIdentity.securityDigest,
              authorization.preparedHandleID == preparedTarget.handleID,
              authorization.destructiveHandleDigest == preparedTarget.authorizationBindingDigest else {
            throw UMISCoreError.invalidToken
        }
        guard identity.matchesSameEraseTarget(as: preparedTarget.freshlyRevalidatedIdentity) else {
            throw UMISCoreError.identityChanged
        }
        guard !identity.isInternal, identity.isRemovable else {
            throw UMISCoreError.unsafeEraseTarget("Simulation rejected an unsafe target")
        }
        requests.append((expectedIdentity, profile))
        var after = identity
        after.volumeUUID = UUID()
        after.fileSystem = profile.fileSystem.rawValue
        return CardEraseResult(
            outcome: .completed,
            beforeIdentity: expectedIdentity,
            afterIdentity: after,
            postFormatProbeSucceeded: true
        )
    }

    public func abandonPreparedTarget(_ preparedTarget: PreparedCardEraseTarget) async {
        preparedTargets.removeValue(forKey: preparedTarget.handleID)
    }

    public func invocationCount() -> Int { requests.count }
}
