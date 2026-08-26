import Foundation

public enum FilenameToken: Codable, Hashable, Sendable {
    case literal(String)
    case location
    case sceneCode
    case sceneName
    case photographer
    case cardNumber
    case capturedDate
    case sequence
    case originalStem
}

public struct RenameRule: Codable, Hashable, Sendable {
    public var version: Int
    public var tokens: [FilenameToken]
    public var separator: String
    public var sequenceWidth: Int
    public var preserveRelativeDirectories: Bool
    /// IANA identifier frozen when a rename plan is created. `nil` on a legacy/project rule means
    /// "freeze TimeZone.current now", never UTC.
    public var timeZoneIdentifier: String?

    public init(
        version: Int = 1,
        tokens: [FilenameToken] = [.sceneCode, .sequence],
        separator: String = "_",
        sequenceWidth: Int = 4,
        preserveRelativeDirectories: Bool = true,
        timeZoneIdentifier: String? = TimeZone.current.identifier
    ) {
        self.version = version
        self.tokens = tokens
        self.separator = separator
        self.sequenceWidth = sequenceWidth
        self.preserveRelativeDirectories = preserveRelativeDirectories
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct RenameContext: Codable, Hashable, Sendable {
    public var location: String?
    public var sceneCode: String?
    public var sceneName: String?
    public var photographer: String?
    public var cardNumber: String?

    public init(
        location: String? = nil,
        sceneCode: String? = nil,
        sceneName: String? = nil,
        photographer: String? = nil,
        cardNumber: String? = nil
    ) {
        self.location = location
        self.sceneCode = sceneCode
        self.sceneName = sceneName
        self.photographer = photographer
        self.cardNumber = cardNumber
    }
}

public struct RenameRequest: Codable, Hashable, Sendable {
    public var asset: MediaAsset
    public var context: RenameContext

    public init(asset: MediaAsset, context: RenameContext = RenameContext()) {
        self.asset = asset
        self.context = context
    }
}

public struct RenamePlanItem: Codable, Hashable, Sendable {
    public var ingestItem: IngestPlanItem
    public var beforeRelativePath: String
    public var afterRelativePath: String
    public var sequenceNumber: Int
    public var companionGroupKey: String

    public init(
        ingestItem: IngestPlanItem,
        beforeRelativePath: String,
        afterRelativePath: String,
        sequenceNumber: Int,
        companionGroupKey: String
    ) {
        self.ingestItem = ingestItem
        self.beforeRelativePath = beforeRelativePath
        self.afterRelativePath = afterRelativePath
        self.sequenceNumber = sequenceNumber
        self.companionGroupKey = companionGroupKey
    }
}

public struct RenamePlan: Codable, Hashable, Sendable {
    public var transactionID: RenameTransactionID
    public var sourceRoot: URL
    public var destinationRoot: URL
    public var sourceVolume: VolumeIdentity
    public var destination: DestinationIdentity
    public var project: Project
    public var sourceInventoryDigest: String
    public var sourceRootFingerprint: FileFingerprint
    public var sourceGroupMembershipDigest: String
    public var scanPolicy: MediaScanPolicy?
    public var rule: RenameRule
    public var items: [RenamePlanItem]
    public var planDigest: String
    public var createdAt: Date

    public init(
        transactionID: RenameTransactionID,
        sourceRoot: URL,
        destinationRoot: URL,
        sourceVolume: VolumeIdentity,
        destination: DestinationIdentity,
        project: Project,
        sourceInventoryDigest: String,
        sourceRootFingerprint: FileFingerprint,
        sourceGroupMembershipDigest: String,
        scanPolicy: MediaScanPolicy? = nil,
        rule: RenameRule,
        items: [RenamePlanItem],
        planDigest: String,
        createdAt: Date = Date()
    ) {
        self.transactionID = transactionID
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceVolume = sourceVolume
        self.destination = destination
        self.project = project
        self.sourceInventoryDigest = sourceInventoryDigest
        self.sourceRootFingerprint = sourceRootFingerprint
        self.sourceGroupMembershipDigest = sourceGroupMembershipDigest
        self.scanPolicy = scanPolicy
        self.rule = rule
        self.items = items
        self.planDigest = planDigest
        self.createdAt = createdAt
    }
}

public struct RenameReceipt: Codable, Hashable, Sendable {
    public var transactionID: RenameTransactionID
    public var planDigest: String
    public var ingestReceipt: IngestReceipt

    public init(transactionID: RenameTransactionID, planDigest: String, ingestReceipt: IngestReceipt) {
        self.transactionID = transactionID
        self.planDigest = planDigest
        self.ingestReceipt = ingestReceipt
    }
}

public struct RenamePlanner: Sendable {
    public init() {}

    public func plan(
        sourceRoot: URL,
        destinationRoot: URL,
        requests: [RenameRequest],
        rule: RenameRule,
        collisionPolicy: DuplicatePolicy = .block,
        project: Project = Project(name: "Folder Rename"),
        sourceVolume: VolumeIdentity? = nil,
        destinationIdentity: DestinationIdentity? = nil,
        scanPolicy: MediaScanPolicy? = nil
    ) async throws -> RenamePlan {
        guard !requests.isEmpty else { throw UMISCoreError.emptyPlan }
        guard (1 ... 12).contains(rule.sequenceWidth) else {
            throw UMISCoreError.invalidPlan("Sequence width must be between 1 and 12")
        }
        var frozenRule = rule
        let frozenTimeZoneIdentifier = rule.timeZoneIdentifier ?? TimeZone.current.identifier
        guard TimeZone(identifier: frozenTimeZoneIdentifier) != nil else {
            throw UMISCoreError.invalidPlan("Rename time zone identifier is invalid")
        }
        frozenRule.timeZoneIdentifier = frozenTimeZoneIdentifier
        let separator = try PathSafety.validateComponent(frozenRule.separator)
        guard separator != "." else { throw UMISCoreError.invalidPath("Dot cannot be the naming separator") }

        let sourceRoot = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        try Self.validateRootRelationship(source: sourceRoot, destination: destinationRoot)

        let sourceVolumeID = requests[0].asset.sourceVolumeID
        guard requests.allSatisfy({ $0.asset.sourceVolumeID == sourceVolumeID }) else {
            throw UMISCoreError.invalidPlan("A rename plan cannot mix source volume identities")
        }
        let frozenScan = try await MediaScanner().scan(
            root: sourceRoot,
            sourceVolumeID: sourceVolumeID,
            policy: scanPolicy
        )
        let frozenAssetByID = Dictionary(uniqueKeysWithValues: frozenScan.assets.map { ($0.id, $0) })
        guard requests.allSatisfy({ request in
            guard let frozen = frozenAssetByID[request.asset.id] else { return false }
            return frozen.relativePath == request.asset.relativePath
                && frozen.fingerprint == request.asset.fingerprint
                && frozen.canonicalURL.standardizedFileURL == request.asset.canonicalURL.standardizedFileURL
        }) else {
            throw UMISCoreError.sourceChanged("Rename selection no longer matches a fresh source-root inventory")
        }
        let sourceRootFingerprint = try FileFingerprint.capture(at: sourceRoot)
        let sourceGroupMembershipDigest = try Self.groupMembershipDigest(frozenScan.assets)
        let resolvedSourceVolume = sourceVolume ?? VolumeIdentity(
            id: sourceVolumeID,
            mountURL: sourceRoot,
            displayName: sourceRoot.lastPathComponent,
            capacityBytes: 0,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isWritable: false,
            isNetwork: false,
            isDiskImage: false,
            identityStrength: .weak
        )
        guard resolvedSourceVolume.id == sourceVolumeID else {
            throw UMISCoreError.invalidPlan("Supplied source identity does not match assets")
        }
        let destination: DestinationIdentity
        if let destinationIdentity {
            destination = destinationIdentity
        } else {
            destination = try DestinationIdentityResolver().resolve(rootURL: destinationRoot)
        }
        guard destination.rootURL.standardizedFileURL == destinationRoot.standardizedFileURL else {
            throw UMISCoreError.invalidPlan("Destination identity root differs from requested destination")
        }

        let requestAssetIDs = requests.map { $0.asset.id }
        guard Set(requestAssetIDs).count == requests.count else {
            throw UMISCoreError.invalidPlan("Rename requests contain duplicate assets")
        }
        let companionLayout = try MediaCompanionGrouping.layout(for: requests.map(\.asset))
        let companionLayoutByAssetID = Dictionary(
            uniqueKeysWithValues: companionLayout.map { ($0.assetID, $0) }
        )
        let requestByAssetID = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.asset.id, $0) }
        )

        var requestsByLogicalGroup: [String: [RenameRequest]] = [:]
        for request in requests {
            guard let layout = companionLayoutByAssetID[request.asset.id] else {
                throw UMISCoreError.invalidPlan("Rename companion layout is incomplete")
            }
            requestsByLogicalGroup[layout.logicalOutputGroupKey, default: []].append(request)
        }
        let logicalGroups = try requestsByLogicalGroup.map { logicalGroup, members in
            guard let firstMember = members.first,
                  let firstLayout = companionLayoutByAssetID[firstMember.asset.id],
                  let primaryRequest = requestByAssetID[firstLayout.primaryAssetID],
                  members.allSatisfy({ member in
                      guard let layout = companionLayoutByAssetID[member.asset.id] else { return false }
                      return layout.logicalOutputGroupKey == logicalGroup
                          && layout.primaryAssetID == primaryRequest.asset.id
                  }) else {
                throw UMISCoreError.invalidPlan("Rename logical companion group is incomplete")
            }
            let sortedMembers = members.sorted { left, right in
                let leftIsPrimary = left.asset.id == primaryRequest.asset.id
                let rightIsPrimary = right.asset.id == primaryRequest.asset.id
                if leftIsPrimary != rightIsPrimary { return leftIsPrimary }
                let leftExtension = PathSafety.portableCollisionKey(left.asset.pathExtension)
                let rightExtension = PathSafety.portableCollisionKey(right.asset.pathExtension)
                if leftExtension != rightExtension { return leftExtension < rightExtension }
                let leftPath = left.asset.relativePath.precomposedStringWithCanonicalMapping
                let rightPath = right.asset.relativePath.precomposedStringWithCanonicalMapping
                if leftPath != rightPath { return leftPath < rightPath }
                return left.asset.id.rawValue.uuidString < right.asset.id.rawValue.uuidString
            }
            return RenameLogicalGroup(
                key: logicalGroup,
                primaryRequest: primaryRequest,
                members: sortedMembers
            )
        }.sorted { left, right in
            let leftDate = left.primaryRequest.asset.capturedAt
                ?? left.primaryRequest.asset.modifiedAt
                ?? .distantPast
            let rightDate = right.primaryRequest.asset.capturedAt
                ?? right.primaryRequest.asset.modifiedAt
                ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            let leftPath = left.primaryRequest.asset.relativePath.precomposedStringWithCanonicalMapping
            let rightPath = right.primaryRequest.asset.relativePath.precomposedStringWithCanonicalMapping
            if leftPath != rightPath { return leftPath < rightPath }
            return left.primaryRequest.asset.id.rawValue.uuidString
                < right.primaryRequest.asset.id.rawValue.uuidString
        }

        var nextSequence = 1
        var outputByAssetID: [MediaAssetID: RenameOutputPlacement] = [:]
        var plannedCollisionKeys: Set<String> = []
        var destinationGroupOwner: [String: String] = [:]

        for group in logicalGroups {
            try Task.checkCancellation()
            let logicalGroup = group.key
            let groupRequests = group.members
            let primaryRequest = group.primaryRequest
            let sequence = nextSequence
            let (following, overflow) = nextSequence.addingReportingOverflow(1)
            guard !overflow else {
                throw UMISCoreError.invalidPlan("Rename sequence exceeds the representable limit")
            }
            nextSequence = following

            let primaryRelativeURL = URL(fileURLWithPath: primaryRequest.asset.relativePath)
            let primaryDirectory = primaryRelativeURL.deletingLastPathComponent().relativePath
            var relativeDirectory = ""
            if frozenRule.preserveRelativeDirectories {
                relativeDirectory = primaryDirectory == "." ? "" : primaryDirectory
                for component in relativeDirectory.split(separator: "/") {
                    _ = try PathSafety.validateComponent(String(component))
                }
            }
            let baseStem = try render(
                rule: frozenRule,
                request: primaryRequest,
                sequence: sequence
            )

            func candidates(stem: String) throws -> [RenameOutputPlacement] {
                try groupRequests.map { member in
                    let pathExtension = member.asset.pathExtension
                    let filename = try PathSafety.validateComponent(
                        stem + (pathExtension.isEmpty ? "" : "." + pathExtension)
                    )
                    let relative = relativeDirectory.isEmpty
                        ? filename
                        : relativeDirectory + "/" + filename
                    let destinationURL = destinationRoot.appendingPathComponent(relative)
                    try PathSafety.requireDescendant(destinationURL, of: destinationRoot)
                    return RenameOutputPlacement(
                        assetID: member.asset.id,
                        relativePath: relative,
                        destinationURL: destinationURL,
                        collisionKey: Self.collisionKey(relative),
                        destinationGroupKey: Self.destinationGroupCollisionKey(
                            relativeDirectory: relativeDirectory,
                            stem: stem
                        ),
                        sequence: sequence,
                        logicalGroupKey: logicalGroup
                    )
                }
            }

            func conflicts(_ candidates: [RenameOutputPlacement]) throws -> Bool {
                let candidateKeys = candidates.map(\.collisionKey)
                guard Set(candidateKeys).count == candidateKeys.count else { return true }
                if candidateKeys.contains(where: plannedCollisionKeys.contains) { return true }
                if let groupKey = candidates.first?.destinationGroupKey,
                   let owner = destinationGroupOwner[groupKey], owner != logicalGroup {
                    return true
                }
                for candidate in candidates {
                    if try DestinationPathAccess.regularFileExists(
                        candidate.destinationURL,
                        destination: destination,
                        sourceDeviceIdentifier: resolvedSourceVolume.volumeDeviceIdentifier
                    ) {
                        return true
                    }
                }
                return false
            }

            var groupCandidates = try candidates(stem: baseStem)
            let hasConflict = try conflicts(groupCandidates)
            if hasConflict {
                switch collisionPolicy {
                case .block:
                    throw UMISCoreError.collision(
                        groupCandidates.first?.destinationURL.path ?? destinationRoot.path
                    )
                case .verifyIdentical:
                    let candidateKeys = groupCandidates.map(\.collisionKey)
                    guard Set(candidateKeys).count == candidateKeys.count,
                          !candidateKeys.contains(where: plannedCollisionKeys.contains),
                          groupCandidates.first.map({ candidate in
                              destinationGroupOwner[candidate.destinationGroupKey].map {
                                  $0 == logicalGroup
                              } ?? true
                          }) ?? false else {
                        throw UMISCoreError.collision(
                            "Multiple rename groups resolve to one destination companion group"
                        )
                    }
                    // Existing full paths are accepted only for fresh content verification by
                    // IngestEngine; the complete companion group keeps one shared output stem.
                case .deterministicSuffix:
                    let suffix = "-" + primaryRequest.asset.id.rawValue.uuidString
                        .replacingOccurrences(of: "-", with: "")
                        .prefix(8)
                        .lowercased()
                    groupCandidates = try candidates(stem: baseStem + suffix)
                    guard try !conflicts(groupCandidates) else {
                        throw UMISCoreError.collision(
                            groupCandidates.first?.destinationURL.path ?? destinationRoot.path
                        )
                    }
                }
            }

            for candidate in groupCandidates {
                plannedCollisionKeys.insert(candidate.collisionKey)
                destinationGroupOwner[candidate.destinationGroupKey] = logicalGroup
                outputByAssetID[candidate.assetID] = candidate
            }
        }

        var planned: [RenamePlanItem] = []
        for request in logicalGroups.flatMap(\.members) {
            try Task.checkCancellation()
            try PathSafety.requireDescendant(request.asset.canonicalURL, of: sourceRoot)
            let currentFingerprint = try FileFingerprint.capture(at: request.asset.canonicalURL)
            guard currentFingerprint == request.asset.fingerprint else {
                throw UMISCoreError.sourceChanged(request.asset.canonicalURL.path)
            }
            let content = try await StreamingSHA256.hashFile(
                at: request.asset.canonicalURL,
                expectedFingerprint: currentFingerprint
            )
            guard let output = outputByAssetID[request.asset.id] else {
                throw UMISCoreError.invalidPlan("Rename output layout is incomplete")
            }
            let ingestItem = IngestPlanItem(
                asset: request.asset,
                sourceURL: request.asset.canonicalURL,
                finalURL: output.destinationURL,
                expectedSourceFingerprint: currentFingerprint,
                expectedContentSHA256: content.sha256,
                duplicatePolicy: collisionPolicy
            )
            planned.append(RenamePlanItem(
                ingestItem: ingestItem,
                beforeRelativePath: request.asset.relativePath,
                afterRelativePath: output.relativePath,
                sequenceNumber: output.sequence,
                companionGroupKey: output.logicalGroupKey
            ))
        }

        let previewRequiredSet = try frozenScan.validatedRequiredSet(
            selectedAssetIDs: Set(planned.map { $0.ingestItem.asset.id }),
            destinationID: destination.id
        )
        let previewIngestPlan = IngestPlan(
            runID: IngestRunID(),
            project: project,
            sourceVolume: resolvedSourceVolume,
            destination: destination,
            requiredSet: previewRequiredSet,
            scanPolicy: scanPolicy,
            items: planned.map(\.ingestItem)
        )
        try previewIngestPlan.validate()

        let digestMaterial = RenamePlanDigestMaterial(
            sourceRoot: sourceRoot.path,
            destinationRoot: destinationRoot.path,
            sourceIdentityDigest: resolvedSourceVolume.securityDigest,
            destinationIdentityDigest: try StableDigest.encode(destination),
            projectID: project.id,
            sourceInventoryDigest: frozenScan.inventoryDigest,
            sourceRootFingerprint: sourceRootFingerprint,
            sourceGroupMembershipDigest: sourceGroupMembershipDigest,
            scanPolicy: scanPolicy,
            rule: frozenRule,
            items: planned
        )
        let planDigest = try StableDigest.encode(digestMaterial)
        return RenamePlan(
            transactionID: RenameTransactionID(),
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourceVolume: resolvedSourceVolume,
            destination: destination,
            project: project,
            sourceInventoryDigest: frozenScan.inventoryDigest,
            sourceRootFingerprint: sourceRootFingerprint,
            sourceGroupMembershipDigest: sourceGroupMembershipDigest,
            scanPolicy: scanPolicy,
            rule: frozenRule,
            items: planned,
            planDigest: planDigest
        )
    }

    private func render(rule: RenameRule, request: RenameRequest, sequence: Int) throws -> String {
        var values: [String] = []
        for token in rule.tokens {
            let value: String
            switch token {
            case let .literal(literal): value = literal
            case .location: value = request.context.location ?? ""
            case .sceneCode: value = request.context.sceneCode ?? ""
            case .sceneName: value = request.context.sceneName ?? ""
            case .photographer: value = request.context.photographer ?? ""
            case .cardNumber: value = request.context.cardNumber ?? ""
            case .capturedDate:
                guard let date = request.asset.capturedAt ?? request.asset.modifiedAt else { value = ""; break }
                guard let identifier = rule.timeZoneIdentifier,
                      let timeZone = TimeZone(identifier: identifier) else {
                    throw UMISCoreError.invalidPlan("Rename plan lacks a frozen valid time zone")
                }
                value = Self.dateFormatter(timeZone: timeZone).string(from: date)
            case .sequence: value = String(format: "%0*d", rule.sequenceWidth, sequence)
            case .originalStem: value = request.asset.canonicalURL.deletingPathExtension().lastPathComponent
            }
            if !value.isEmpty { values.append(try PathSafety.validateComponent(value)) }
        }
        guard !values.isEmpty else { throw UMISCoreError.invalidPlan("Naming rule produced an empty filename") }
        return try PathSafety.validateComponent(values.joined(separator: rule.separator))
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }

    private static func collisionKey(_ path: String) -> String {
        PathSafety.portableCollisionKey(path)
    }

    private static func destinationGroupCollisionKey(
        relativeDirectory: String,
        stem: String
    ) -> String {
        let path = relativeDirectory.isEmpty ? stem : relativeDirectory + "/" + stem
        return PathSafety.portableCollisionKey(path)
    }

    fileprivate static func groupMembershipDigest(_ assets: [MediaAsset]) throws -> String {
        let members = assets.map { asset -> String in
            let relativeURL = URL(fileURLWithPath: asset.relativePath)
            let directory = relativeURL.deletingLastPathComponent().relativePath
            let stem = relativeURL.deletingPathExtension().lastPathComponent
            let group = (directory + "/" + stem)
                .precomposedStringWithCanonicalMapping
                .lowercased()
            return [
                group,
                asset.id.rawValue.uuidString,
                asset.relativePath.precomposedStringWithCanonicalMapping,
                asset.kind.rawValue,
                String(asset.byteSize),
            ].joined(separator: "|")
        }.sorted()
        return try StableDigest.encode(members)
    }

    private static func validateRootRelationship(source: URL, destination: URL) throws {
        let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !destinationPath.hasPrefix(sourcePath),
              !sourcePath.hasPrefix(destinationPath)
        else {
            throw UMISCoreError.invalidPath("Source and destination must be disjoint roots")
        }
    }
}

private struct RenameOutputPlacement {
    var assetID: MediaAssetID
    var relativePath: String
    var destinationURL: URL
    var collisionKey: String
    var destinationGroupKey: String
    var sequence: Int
    var logicalGroupKey: String
}

private struct RenameLogicalGroup {
    var key: String
    var primaryRequest: RenameRequest
    var members: [RenameRequest]
}

public actor CopyAndRenameEngine {
    private let ingestEngine: IngestEngine
    private let store: OperationStore

    public init(
        store: OperationStore,
        chunkSize: Int = 1_048_576,
        destinationRevalidator: DestinationIdentityRevalidationHandler? = nil
    ) {
        self.store = store
        ingestEngine = IngestEngine(
            store: store,
            chunkSize: chunkSize,
            destinationRevalidator: destinationRevalidator
        )
    }

    init(store: OperationStore, chunkSize: Int, testingHooks: CopyTestingHooks) {
        self.store = store
        ingestEngine = IngestEngine(store: store, chunkSize: chunkSize, testingHooks: testingHooks)
    }

    public func execute(
        plan: RenamePlan,
        cancellation: OperationCancellation? = nil,
        progress: IngestProgressHandler? = nil
    ) async throws -> RenameReceipt {
        let currentDigest = try StableDigest.encode(RenamePlanDigestMaterial(
            sourceRoot: plan.sourceRoot.path,
            destinationRoot: plan.destinationRoot.path,
            sourceIdentityDigest: plan.sourceVolume.securityDigest,
            destinationIdentityDigest: try StableDigest.encode(plan.destination),
            projectID: plan.project.id,
            sourceInventoryDigest: plan.sourceInventoryDigest,
            sourceRootFingerprint: plan.sourceRootFingerprint,
            sourceGroupMembershipDigest: plan.sourceGroupMembershipDigest,
            scanPolicy: plan.scanPolicy,
            rule: plan.rule,
            items: plan.items
        ))
        guard currentDigest == plan.planDigest else {
            throw UMISCoreError.invalidPlan("Rename preview was modified after it was frozen")
        }
        guard try FileFingerprint.capture(at: plan.sourceRoot) == plan.sourceRootFingerprint else {
            throw UMISCoreError.sourceChanged("Source root changed after rename preview")
        }
        let freshScan = try await MediaScanner().scan(
            root: plan.sourceRoot,
            sourceVolumeID: plan.sourceVolume.id,
            policy: plan.scanPolicy
        )
        guard freshScan.inventoryDigest == plan.sourceInventoryDigest,
              try RenamePlanner.groupMembershipDigest(freshScan.assets) == plan.sourceGroupMembershipDigest else {
            throw UMISCoreError.sourceChanged(
                "Source inventory or companion-group membership changed after rename preview"
            )
        }
        let freshAssetByID = Dictionary(uniqueKeysWithValues: freshScan.assets.map { ($0.id, $0) })
        guard plan.items.allSatisfy({ item in
            guard let fresh = freshAssetByID[item.ingestItem.asset.id] else { return false }
            return fresh.fingerprint == item.ingestItem.expectedSourceFingerprint
                && fresh.relativePath == item.beforeRelativePath
        }) else {
            throw UMISCoreError.sourceChanged("A planned rename source changed after preview")
        }
        let assetIDs = Set(plan.items.map { $0.ingestItem.asset.id })
        let requiredSet = try freshScan.validatedRequiredSet(
            selectedAssetIDs: assetIDs,
            destinationID: plan.destination.id
        )
        let ingestPlan = IngestPlan(
            runID: IngestRunID(rawValue: plan.transactionID.rawValue),
            project: plan.project,
            sourceVolume: plan.sourceVolume,
            destination: plan.destination,
            requiredSet: requiredSet,
            scanPolicy: plan.scanPolicy,
            createdAt: plan.createdAt,
            items: plan.items.map(\.ingestItem)
        )
        do {
            let receipt = try await ingestEngine.execute(
                plan: ingestPlan,
                operationKind: .copyAndRename,
                cancellation: cancellation,
                progress: progress
            )
            return RenameReceipt(transactionID: plan.transactionID, planDigest: plan.planDigest, ingestReceipt: receipt)
        } catch {
            do {
                try await rollbackNewlyCommittedFiles(operationID: plan.transactionID.rawValue)
            } catch let rollbackError {
                try? await store.setOperationStatus(.recoveryRequired, id: plan.transactionID.rawValue)
                try? await store.appendAudit(
                    operationID: plan.transactionID.rawValue,
                    event: "rename.rollbackRecoveryRequired",
                    payload: Data(String(describing: rollbackError).utf8)
                )
                throw UMISCoreError.backendFailure(
                    "Copy-and-rename failed and safe rollback requires review: \(rollbackError)"
                )
            }
            throw error
        }
    }

    private func rollbackNewlyCommittedFiles(operationID: UUID) async throws {
        let plan = try await store.loadIngestPlan(runID: IngestRunID(rawValue: operationID))
        let records = try await store.items(operationID: operationID)
        for var record in records.reversed() {
            try validateOperationOwnedPartial(record, operationID: operationID)
            let sourceDevice = plan.sourceVolume.volumeDeviceIdentifier
            let finalExists = try DestinationPathAccess.regularFileExists(
                record.finalURL,
                destination: plan.destination,
                sourceDeviceIdentifier: sourceDevice
            )
            let partialExists = try DestinationPathAccess.regularFileExists(
                record.partialURL,
                destination: plan.destination,
                sourceDeviceIdentifier: sourceDevice
            )

            // A receipt may have been durably encoded even if a later audit/journal status write
            // failed and left a conservative `.failed` state. Receipt semantics, not the display
            // state string, prove whether this transaction created the final.
            if record.state != .durableCommitted,
               let receipt = record.receipt,
               receipt.state == .durableCommitted {
                guard finalExists else {
                    throw UMISCoreError.journalMissing(
                        "Committed rename receipt exists but its final file is missing"
                    )
                }
                let currentFingerprint = try DestinationPathAccess.fingerprint(
                    receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                guard currentFingerprint == receipt.finalFingerprint else {
                    throw UMISCoreError.sourceChanged(receipt.finalURL.path)
                }
                try await proveJournalContent(
                    record,
                    at: receipt.finalURL,
                    plan: plan,
                    expectedHash: receipt.destinationSHA256
                )
                try DestinationPathAccess.removeIfExists(
                    receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                try DestinationPathAccess.synchronizeParent(
                    of: receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                record.state = .rolledBack
                record.receipt = nil
                record.error = "Rolled back after another rename-plan item failed"
                record.updatedAt = Date()
                try await store.updateItem(record)
                continue
            }

            switch record.state {
            case .durableCommitted:
                guard let receipt = record.receipt, finalExists else {
                    throw UMISCoreError.journalMissing(
                        "Durable rename commit is missing its receipt or final file: \(record.itemID.rawValue.uuidString)"
                    )
                }
                let currentFingerprint = try DestinationPathAccess.fingerprint(
                    receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                guard currentFingerprint == receipt.finalFingerprint else {
                    throw UMISCoreError.sourceChanged(receipt.finalURL.path)
                }
                try await proveJournalContent(
                    record,
                    at: receipt.finalURL,
                    plan: plan,
                    expectedHash: receipt.destinationSHA256
                )
                try DestinationPathAccess.removeIfExists(
                    receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                try DestinationPathAccess.synchronizeParent(
                    of: receipt.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )

            case .atomicCommitted:
                guard finalExists, !partialExists else {
                    throw UMISCoreError.journalMissing(
                        "Atomic rename state cannot be reconciled without destructive ambiguity"
                    )
                }
                try await proveJournalContent(record, at: record.finalURL, plan: plan)
                try DestinationPathAccess.removeIfExists(
                    record.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )
                try DestinationPathAccess.synchronizeParent(
                    of: record.finalURL,
                    destination: plan.destination,
                    sourceDeviceIdentifier: sourceDevice
                )

            case .atomicCommitIntent, .destinationHashed:
                if finalExists, partialExists {
                    // The no-replace rename did not consume our partial; the final may belong to
                    // another writer and must be preserved. Only the operation-owned partial is removed.
                    try await proveJournalContent(record, at: record.partialURL, plan: plan)
                    try DestinationPathAccess.removeIfExists(
                        record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                    try DestinationPathAccess.synchronizeParent(
                        of: record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                } else if finalExists {
                    // The partial disappeared after durable intent, which is proof that rename may
                    // have committed. A full journal-bound hash is mandatory before deletion.
                    try await proveJournalContent(record, at: record.finalURL, plan: plan)
                    try DestinationPathAccess.removeIfExists(
                        record.finalURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                    try DestinationPathAccess.synchronizeParent(
                        of: record.finalURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                } else if partialExists {
                    try await proveJournalContent(record, at: record.partialURL, plan: plan)
                    try DestinationPathAccess.removeIfExists(
                        record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                    try DestinationPathAccess.synchronizeParent(
                        of: record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                }

            case .durableVerifiedExisting:
                // This path existed before the transaction and was only verified; never delete it.
                break

            case .planned, .copying, .partialWritten, .sourceHashed, .conflict, .cancelled, .failed, .rolledBack:
                // A final in these states has no durable proof of operation ownership and is preserved.
                if partialExists {
                    try DestinationPathAccess.removeIfExists(
                        record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                    try DestinationPathAccess.synchronizeParent(
                        of: record.partialURL,
                        destination: plan.destination,
                        sourceDeviceIdentifier: sourceDevice
                    )
                }
            }

            record.state = .rolledBack
            record.receipt = nil
            record.error = "Rolled back after another rename-plan item failed"
            record.updatedAt = Date()
            try await store.updateItem(record)
        }
        try await store.setOperationStatus(.rolledBack, id: operationID)
        try await store.appendAudit(operationID: operationID, event: "rename.rollbackCompleted")
    }

    private func validateOperationOwnedPartial(_ record: JournalItemRecord, operationID: UUID) throws {
        let itemName = record.itemID.rawValue.uuidString + ".partial"
        guard record.partialURL.lastPathComponent == itemName,
              record.partialURL.deletingLastPathComponent().lastPathComponent == operationID.uuidString,
              record.partialURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".umis-partial"
        else {
            throw UMISCoreError.invalidPath("Journal partial path is outside the operation-owned namespace")
        }
    }

    private func proveJournalContent(
        _ record: JournalItemRecord,
        at url: URL,
        plan: IngestPlan,
        expectedHash: String? = nil
    ) async throws {
        guard let journalHash = expectedHash ?? record.destinationSHA256,
              let sourceHash = record.sourceSHA256,
              journalHash == sourceHash,
              record.bytesCopied >= 0 else {
            throw UMISCoreError.journalMissing("Rollback lacks a complete hash-bound commit intent")
        }
        let current = try await StreamingSHA256.hashDestinationFile(
            at: url,
            destination: plan.destination,
            sourceDeviceIdentifier: plan.sourceVolume.volumeDeviceIdentifier
        )
        guard current.sha256 == journalHash, current.byteSize == record.bytesCopied else {
            throw UMISCoreError.hashMismatch(url.path)
        }
    }
}

private struct RenamePlanDigestMaterial: Codable, Hashable, Sendable {
    var sourceRoot: String
    var destinationRoot: String
    var sourceIdentityDigest: String
    var destinationIdentityDigest: String
    var projectID: ProjectID
    var sourceInventoryDigest: String
    var sourceRootFingerprint: FileFingerprint
    var sourceGroupMembershipDigest: String
    var scanPolicy: MediaScanPolicy?
    var rule: RenameRule
    var items: [RenamePlanItem]
}
