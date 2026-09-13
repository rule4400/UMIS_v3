import AppKit
import Combine
import Foundation
import SwiftUI
import UMISCore
import UMISMedia
import UMISNetwork
import UniformTypeIdentifiers

enum AppSourceScanScope: Equatable, Sendable {
    case root(URL)
    case items([URL])

    static func normalizedRoot(_ url: URL) -> Self {
        .root(url.standardizedFileURL.resolvingSymlinksInPath())
    }

    static func normalizedItems(_ urls: [URL]) -> Self {
        let unique = Dictionary(grouping: urls.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        return .items(unique)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var mediaPipeline: MediaPipeline?
    @Published var route: WorkspaceRoute = .ingest
    @Published var sourceURL: URL?
    @Published var destinationURL: URL? {
        didSet { if oldValue != destinationURL { markProjectMetadataDirty() } }
    }
    @Published var renameSourceURL: URL?
    @Published var renameDestinationURL: URL?
    @Published var assets: [AppAsset] = [] {
        didSet { rebuildIngestAssetProjection(sourceChanged: true) }
    }
    @Published var selectedAssetIDs: Set<UUID> = [] {
        didSet {
            guard oldValue != selectedAssetIDs else { return }
            ingestCollectionSelectionRevision &+= 1
        }
    }
    @Published var ingestAssetSearchText = "" {
        didSet {
            guard oldValue != ingestAssetSearchText else { return }
            rebuildIngestAssetProjection(sourceChanged: false)
        }
    }
    @Published var ingestAssetCategoryFilter: AssetCategory? {
        didSet {
            guard oldValue != ingestAssetCategoryFilter else { return }
            rebuildIngestAssetProjection(sourceChanged: false)
        }
    }
    @Published var reviewSourceURL: URL?
    @Published var reviewAssets: [AppAsset] = [] {
        didSet { rebuildReviewAssetProjection(sourceChanged: true) }
    }
    @Published var reviewSelectedAssetIDs: Set<UUID> = [] {
        didSet {
            guard oldValue != reviewSelectedAssetIDs else { return }
            reviewCollectionSelectionRevision &+= 1
        }
    }
    @Published var reviewAssetSearchText = "" {
        didSet {
            guard oldValue != reviewAssetSearchText else { return }
            rebuildReviewAssetProjection(sourceChanged: false)
        }
    }
    @Published var reviewAssetCategoryFilter: AssetCategory? {
        didSet {
            guard oldValue != reviewAssetCategoryFilter else { return }
            rebuildReviewAssetProjection(sourceChanged: false)
        }
    }
    @Published var reviewRatings: [UUID: AdobeRating] = [:] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewRatingLoadedAssetIDs: Set<UUID> = [] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewRatingExplicitAssetIDs: Set<UUID> = [] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewRatingErrors: [UUID: String] = [:] {
        didSet {
            rebuildReviewMetadataErrorProjection()
            bumpReviewCollectionMetadataRevision()
        }
    }
    @Published var reviewLabelNumbers: [UUID: Int] = [:] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewLabelLoadedAssetIDs: Set<UUID> = [] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewLabelErrors: [UUID: String] = [:] {
        didSet {
            rebuildReviewMetadataErrorProjection()
            bumpReviewCollectionMetadataRevision()
        }
    }
    @Published var reviewMetadataWarnings: [UUID: String] = [:] {
        didSet { bumpReviewCollectionMetadataRevision() }
    }
    @Published var reviewMetadataRecoveryRecords: [MetadataRecoveryRecord] = []
    @Published var reviewMetadataRecoveryScanWasTruncated = false
    @Published var reviewMetadataRecoveryScanError: String?
    @Published var reviewUnsupportedRegularFileCount = 0
    @Published var reviewUnsupportedRegularFileSamples: [String] = []
    @Published var reviewScanIssueCount = 0
    @Published var reviewScanIssueSamples: [String] = []
    @Published var reviewIsScanning = false
    @Published var reviewMetadataIsLoading = false {
        didSet {
            guard oldValue != reviewMetadataIsLoading else { return }
            bumpReviewCollectionMetadataRevision()
        }
    }
    @Published var reviewMetadataIsWriting = false
    @Published var reviewSourceIsReadOnly: Bool?
    @Published var reviewSourceIsLocal = false
    @Published var reviewSourceIsEjectable = true
    @Published var reviewSourceIsInternal = false
    @Published var ingestThumbnailReloadGeneration = UUID()
    @Published var reviewThumbnailReloadGeneration = UUID() {
        didSet {
            guard oldValue != reviewThumbnailReloadGeneration else { return }
            bumpReviewCollectionMetadataRevision()
        }
    }
    @Published var reviewStatusMessage = "評価するアーカイブを選択してください"
    @Published private(set) var policyReviewAssetIDs: Set<UUID> = []
    @Published private(set) var explicitlyExcludedAssetIDs: Set<UUID> = [] {
        didSet {
            ingestIncludedAssetIDs = ingestAllAssetIDs.subtracting(explicitlyExcludedAssetIDs)
            rebuildIngestExclusionProjections()
            rebuildAssignedIncludedAssetCount()
            bumpIngestCollectionMetadataRevision()
        }
    }
    @Published var showAssetExclusionConfirmation = false
    @Published private(set) var emptyDirectoryReviewPaths: [String] = []
    @Published var showEmptyDirectoryExclusionConfirmation = false
    @Published var sceneAssignments: [UUID: UUID] = [:] {
        didSet {
            rebuildSceneAssignmentCounts()
            bumpIngestCollectionMetadataRevision()
        }
    }
    @Published var scenes: [AppScene] {
        didSet {
            sceneNamesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0.name) })
            bumpIngestCollectionMetadataRevision()
            synchronizeSceneDaySelection()
        }
    }
    @Published var selectedSceneDay = 0
    @Published var selectedSceneID: UUID? {
        didSet {
            invalidatePreparedRenamePreviewIfNeeded()
            synchronizeSceneDaySelection()
        }
    }
    @Published var projectName = "新規プロジェクト" {
        didSet {
            guard oldValue != projectName else { return }
            invalidatePreparedRenamePreviewIfNeeded()
            markProjectMetadataDirty()
        }
    }
    @Published var photographer = "" {
        didSet {
            guard oldValue != photographer else { return }
            invalidatePreparedRenamePreviewIfNeeded()
            markProjectMetadataDirty()
        }
    }
    @Published var cardNumber = "" {
        didSet {
            guard oldValue != cardNumber else { return }
            invalidatePreparedRenamePreviewIfNeeded()
            markProjectMetadataDirty()
        }
    }
    @Published var locationName = "" {
        didSet {
            guard oldValue != locationName else { return }
            invalidatePreparedRenamePreviewIfNeeded()
            markProjectMetadataDirty()
        }
    }
    @Published var showCaptureConfigurationSheet = false
    @Published private(set) var captureConfigurationError: String?
    @Published var showProjectLocationSheet = false
    @Published private(set) var projectLocationError: String?
    @Published private(set) var projectDestinationStatus = "保存先はプロジェクトごとに保持されます"
    @Published var phase: WorkspacePhase = .idle
    @Published var scanErrors: [String] = []
    @Published var activity: [ActivityRecord] = []
    @Published private(set) var operationHistory: [OperationSummary] = []
    @Published var historyStatusMessage = "操作ジャーナルを読み込んでいます"
    @Published var statusMessage = "ソースを選択してください"
    @Published var showInspector = true
    @Published var cardInitializationEnabled = AppModel.destructiveRuntimeFeatureEnabled(
        ProcessInfo.processInfo.environment["UMIS_ENABLE_CARD_ERASE"],
        boundaryAvailable: DiskutilCardEraseBackend.isBundledProductionBoundaryAvailable
    )
    let cardEraseRuntimeUnlocked = AppModel.destructiveRuntimeFeatureEnabled(
        ProcessInfo.processInfo.environment["UMIS_ENABLE_CARD_ERASE"],
        boundaryAvailable: DiskutilCardEraseBackend.isBundledProductionBoundaryAvailable
    )
    let safeEjectRuntimeUnlocked = AppModel.destructiveRuntimeFeatureEnabled(
        ProcessInfo.processInfo.environment["UMIS_ENABLE_SAFE_EJECT"],
        boundaryAvailable: SafeEjectService.isBundledProductionBoundaryAvailable
    )
    @Published var sdManagementEnabled = false
    @Published var lanCatalogEnabled = false
    @Published private(set) var lanSceneCatalog: LANSceneCatalogCoordinator?
    @Published private(set) var lanOperationInProgress = false
    @Published private(set) var lanStatusMessage = "LANシーン共有は停止中です"
    @Published var mediaCacheSummary = "初期化中"
    @Published private(set) var mediaCacheStatusMessage = "派生キャッシュは原本へ影響せず、必要時に再生成できます"
    @Published var previewAsset: AppAsset?
    @Published private(set) var latestVerifiedReceipt: IngestReceipt?
    @Published var renamePreviewRows: [RenamePreviewRow] = []
    @Published var renameStatusMessage = "入力と出力フォルダを選択してください"
    @Published var renameIsBusy = false
    @Published var renameTemplate = "{location}_{scene}_{date}_{photographer}_{card}_{original}" {
        didSet {
            guard oldValue != renameTemplate else { return }
            invalidatePreparedRenamePreviewIfNeeded()
            markProjectMetadataDirty()
        }
    }
    @Published private(set) var excludedFolderNamesDraft = ""
    @Published private(set) var activeSourceIdentity: VolumeIdentity?
    @Published var showCardEraseConfirmation = false
    @Published private(set) var pendingCardDisplayName = ""
    @Published private(set) var pendingCardCapacityBytes: Int64 = 0
    @Published private(set) var pendingCardFormatLabel = ""
    @Published private(set) var pendingCardIdentitySummary = ""
    @Published private(set) var pendingFinalVerificationAt: Date?
    @Published private(set) var pendingRequiredAssetCount = 0
    @Published private(set) var pendingVerifiedDeliveryCount = 0
    @Published var cardInitializationStatus = "検証済み取り込み後に利用できます"
    @Published var availableProjects: [Project] = []
    @Published private(set) var selectedStoredProjectID: UUID?
    @Published var projectPersistenceStatus = "未保存"
    @Published private(set) var projectOperationInFlight = false
    @Published private(set) var lastDeletedProjectID: UUID?
    @Published private(set) var destructiveOutcomeQuarantined = false
    @Published private(set) var mediaAccessQuiescenceLatched = false
    @Published private(set) var mediaReadIsolationFailed = false
    @Published private(set) var captureDateMetadataIsLoading = false
    @Published private(set) var mediaCacheOperationInFlight = false
    @Published private(set) var auditExportInFlight = false

    private(set) var ingestBrowserProjection: AssetBrowserProjection = .empty
    private(set) var reviewBrowserProjection: AssetBrowserProjection = .empty
    private(set) var ingestAllAssetIDs: Set<UUID> = []
    private(set) var ingestIncludedAssetIDs: Set<UUID> = []
    private(set) var reviewAllAssetIDs: Set<UUID> = []
    private(set) var ingestAssetTotalBytes: Int64 = 0
    private(set) var reviewAssetTotalBytes: Int64 = 0
    private(set) var ingestCollectionMetadataRevision: UInt64 = 0
    private(set) var reviewCollectionMetadataRevision: UInt64 = 0
    /// Lets the AppKit bridge skip an O(selectionCount) reconciliation for unrelated
    /// `ObservableObject` publications such as per-item ingest progress.
    private(set) var ingestCollectionSelectionRevision: UInt64 = 0
    private(set) var reviewCollectionSelectionRevision: UInt64 = 0
    private(set) var sceneNamesByID: [UUID: String] = [:]
    private(set) var sceneAssignmentCountsBySceneID: [UUID: Int] = [:]
    private(set) var assignedIncludedAssetCount = 0
    private(set) var explicitExclusionAssetsProjection: [AppAsset] = []
    private(set) var explicitExclusionTotalBytesProjection: Int64 = 0
    private(set) var pendingExclusionAssetsProjection: [AppAsset] = []
    private(set) var pendingExclusionTotalBytesProjection: Int64 = 0
    private(set) var reviewMetadataErrorIDsProjection: Set<UUID> = []
    private(set) var reviewMetadataErrorsProjection: [UUID: String] = [:]

    private var scanTask: Task<Void, Never>?
    /// Tracks every scanner that has not actually unwound yet. `scanTask` is only the cancellation
    /// handle for the newest scanner and can be replaced or cleared before an older Task exits.
    @Published private var activeIngestScanTaskIDs: Set<UUID> = []
    @Published private var cancellingIngestScanGeneration: UUID?
    var reviewScanTask: Task<Void, Never>?
    var reviewMetadataTask: Task<Void, Never>?
    var reviewScanGeneration = UUID()
    var reviewMetadataAttempt = UUID()
    var reviewMetadataWriteAttempt = UUID()
    var reviewSourceVolumeID = SourceVolumeID()
    var reviewSourceRootPath: String?
    var reviewSourceRootDevice: UInt64?
    var reviewSourceRootInode: UInt64?
    var reviewSourceVolumeUUID: String?
    private var scanGeneration = UUID()
    private var captureDateEnrichmentTask: Task<ScanResult?, Never>?
    private var captureDateEnrichmentAttempt = UUID()
    private var captureDateEnrichmentTaskGeneration: UUID?
    private var captureDateEnrichmentTaskTimeZoneIdentifier: String?
    private var mediaCacheSummaryGeneration = UUID()
    private var captureDateEnrichmentGeneration: UUID?
    private var captureDateEnrichmentTimeZoneIdentifier: String?
    private var projectOperationGeneration = UUID()
    private var ingestIntentGeneration = UUID()
    private var operationTask: Task<Void, Never>?
    private var operationCancellation: OperationCancellation?
    private var operationStore: OperationStore?
    private var projectStore: ProjectStore?
    private var coreScanResult: ScanResult?
    private var activeSourceScanScope: AppSourceScanScope?
    private var activeSourceVolumeID: SourceVolumeID?
    private var activeSourceRootPath: String?
    /// Strong identity used only to correlate Disk Arbitration disappearance events while a
    /// physical-card scan is not yet allowed to publish `activeSourceIdentity`.
    private var inFlightStrongScanIdentity: VolumeIdentity?
    private var inFlightStrongScanGeneration: UUID?
    private var operationCompletedItemIDs: Set<IngestItemID> = []
    private var preparedRenamePlan: RenamePlan?
    private var preparedRenameIntent: RenameUIIntent?
    private var latestVerifiedPlan: IngestPlan?
    private var latestVerifiedIntentGeneration: UUID?
    private var explicitExclusionEvidenceByAssetID: [UUID: ExplicitExclusionEvidence] = [:]
    private var emptyDirectoryExclusionEvidenceByPath: [String: ExplicitDirectoryExclusionEvidence] = [:]
    private var pendingExclusionAssetIDs: Set<UUID> = [] {
        didSet { rebuildIngestExclusionProjections() }
    }
    private var appliedSceneCatalogVersion: CatalogVersionRef?
    private var projectID = ProjectID()
    private var projectPhotographers: [Photographer] = []
    private var projectSettings = ProjectSettings()
    private var selectedProjectPhotographerID: PhotographerID?
    private var selectedProjectCardID: CardDefinitionID?
    private var projectHasUnsavedChanges = true
    private let volumeRegistry = VolumeIdentityRegistry()
    private let volumeActivity = VolumeIOActivityRegistry()
    private let destinationIdentityProvider = DestinationIdentityProvider()
    private var cardVolumeMonitor: CardVolumeMonitor?
    private var cardAppearanceRegistrationGenerations: [SourceVolumeID: UUID] = [:]
    private var deferredCardScanGeneration: UUID?
    @Published private(set) var connectedCardCandidates: [VolumeIdentity] = []
    @Published private(set) var cardAutoSelectionStatus = "認識できるSDカードを接続すると、自動で読み込み対象にします"
    var cardAutoSelectionMainWindowIsKey = false {
        didSet {
            if oldValue != cardAutoSelectionMainWindowIsKey { scheduleAutomaticCardSelection() }
        }
    }
    var cardAutoSelectionInteractionBlocked = false {
        didSet {
            if oldValue != cardAutoSelectionInteractionBlocked { scheduleAutomaticCardSelection() }
        }
    }
    private var registeredCardCandidates: [SourceVolumeID: VolumeIdentity] = [:]
    private var rejectedAutomaticCardIDs: Set<SourceVolumeID> = []
    private var automaticCardSelectionTask: Task<Void, Never>?
    private var automaticCardSelectionGeneration = UUID()
    private var automaticallySelectedCard: CardInsertionIdentity?
    private var eraseGate: EraseGate?
    private var pendingEraseRunID: IngestRunID?
    private var pendingEraseProfile: CardFormatProfile?
    private var ejectObservedDisappearance = false
    private var activePreviewPlaybackIDs: Set<UUID> = []
    private var mediaReadIsolationGeneration: UUID?
    private var mediaReadIsolationTask: Task<Bool, Never>?
    private var applicationInstanceLock: ApplicationInstanceLock?
    private var lanOperationObservation: AnyCancellable?
    private var lanStatusObservation: AnyCancellable?

    init(initializeServices: Bool = true) {
        mediaPipeline = nil
        let other = AppScene(id: UUID(), day: 0, number: 0, name: "その他")
        var initialScenes = [other]
        for day in 1 ... 4 {
            initialScenes.append(AppScene(id: UUID(), day: day, number: 1, name: "シーン1"))
        }
        scenes = initialScenes
        sceneNamesByID = Dictionary(uniqueKeysWithValues: initialScenes.map { ($0.id, $0.name) })
        selectedSceneID = other.id
        projectSettings = ProjectSettings(
            categories: Self.defaultProjectCategories(),
            renameRule: Self.defaultRenameRule
        )
        // Layout/state tests must not open the user's journals, acquire the app lock,
        // monitor physical cards, or initialize LAN services. No service means all
        // existing operation admission gates remain fail-closed.
        guard initializeServices else { return }
        lanSceneCatalog = try? LANSceneCatalogCoordinator()
        if let lanSceneCatalog {
            lanOperationInProgress = lanSceneCatalog.operationInProgress
            lanStatusMessage = lanSceneCatalog.statusMessage
            lanOperationObservation = lanSceneCatalog.$operationInProgress
                .removeDuplicates()
                .sink { [weak self] in self?.lanOperationInProgress = $0 }
            lanStatusObservation = lanSceneCatalog.$statusMessage
                .removeDuplicates()
                .sink { [weak self] in self?.lanStatusMessage = $0 }
        }

        let applicationSupportRoot: URL
        do {
            applicationSupportRoot = try ProjectStore.applicationSupportRoot()
            applicationInstanceLock = try ApplicationInstanceLock(
                applicationSupportRoot: applicationSupportRoot
            )
        } catch {
            statusMessage = "安全な単一起動を確立できないため、すべてのメディア操作を無効化しました: \(error.localizedDescription)"
            historyStatusMessage = "永続操作ジャーナルを開始していません"
            projectPersistenceStatus = "Application Supportまたは単一起動ロックを利用できません"
            cardInitializationEnabled = false
            cardInitializationStatus = "永続安全基盤を確立できないため初期化は無効です"
            return
        }

        Task { [weak self, applicationSupportRoot] in
            let services = await Task.detached(priority: .utility) { () -> (MediaPipeline?, OperationStore?, ProjectStore?) in
                let pipeline = try? MediaPipeline(configuration: .standard())
                let databaseURL = applicationSupportRoot
                    .appendingPathComponent("Operations", isDirectory: true)
                    .appendingPathComponent("operations.sqlite", isDirectory: false)
                let store = try? OperationStore(databaseURL: databaseURL)
                let projects = try? ProjectStore(rootURL: applicationSupportRoot)
                return (pipeline, store, projects)
            }.value
            guard let self else { return }
            mediaPipeline = services.0
            operationStore = services.1
            projectStore = services.2
            eraseGate = EraseGate(
                store: services.1,
                activity: volumeActivity,
                destinationRevalidator: destinationIdentityProvider.makeRevalidationHandler()
            )
            if services.0 == nil {
                statusMessage = "メディアキャッシュを初期化できませんでした。汎用アイコンで表示します"
                mediaCacheSummary = "利用不可"
            } else {
                refreshMediaCacheSummary()
            }
            if services.1 == nil {
                statusMessage = "操作ジャーナルを初期化できませんでした。コピー機能は安全のため無効です"
                historyStatusMessage = "操作ジャーナルを利用できません"
            } else {
                startCardVolumeMonitorIfReady()
                refreshOperationHistory()
            }
            if services.2 == nil {
                projectPersistenceStatus = "プロジェクト保存を初期化できません"
            } else {
                refreshStoredProjects()
            }
        }
    }

    private func rebuildIngestAssetProjection(sourceChanged: Bool) {
        if sourceChanged {
            ingestAllAssetIDs = Set(assets.map(\.id))
            ingestIncludedAssetIDs = ingestAllAssetIDs.subtracting(explicitlyExcludedAssetIDs)
            ingestAssetTotalBytes = assets.reduce(0) { $0 + $1.byteCount }
            rebuildIngestExclusionProjections()
            rebuildAssignedIncludedAssetCount()
        }
        let revision = ingestBrowserProjection.revision &+ 1
        ingestBrowserProjection = AssetBrowserProjection.make(
            assets: assets,
            searchText: ingestAssetSearchText,
            category: ingestAssetCategoryFilter,
            revision: revision
        )
        let visibleSelection = selectedAssetIDs.intersection(ingestBrowserProjection.visibleAssetIDs)
        if visibleSelection != selectedAssetIDs {
            selectedAssetIDs = visibleSelection
        }
    }

    /// Confirmation sheets and the card-initialization summary can be re-evaluated frequently
    /// while the operator types. Materialize their sorted rows and byte totals only when the
    /// underlying asset inventory or exclusion IDs actually change.
    private func rebuildIngestExclusionProjections() {
        var explicitAssets: [AppAsset] = []
        var pendingAssets: [AppAsset] = []
        explicitAssets.reserveCapacity(explicitlyExcludedAssetIDs.count)
        pendingAssets.reserveCapacity(pendingExclusionAssetIDs.count)

        var explicitBytes: Int64 = 0
        var pendingBytes: Int64 = 0
        for asset in assets {
            if explicitlyExcludedAssetIDs.contains(asset.id) {
                explicitAssets.append(asset)
                explicitBytes = Self.saturatingByteCountSum(explicitBytes, asset.byteCount)
            }
            if pendingExclusionAssetIDs.contains(asset.id) {
                pendingAssets.append(asset)
                pendingBytes = Self.saturatingByteCountSum(pendingBytes, asset.byteCount)
            }
        }
        explicitAssets.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        pendingAssets.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        explicitExclusionAssetsProjection = explicitAssets
        explicitExclusionTotalBytesProjection = explicitBytes
        pendingExclusionAssetsProjection = pendingAssets
        pendingExclusionTotalBytesProjection = pendingBytes
    }

    private func rebuildSceneAssignmentCounts() {
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(min(sceneAssignments.count, scenes.count))
        for sceneID in sceneAssignments.values {
            let current = counts[sceneID, default: 0]
            counts[sceneID] = current == Int.max ? Int.max : current + 1
        }
        sceneAssignmentCountsBySceneID = counts
        rebuildAssignedIncludedAssetCount()
    }

    private func rebuildAssignedIncludedAssetCount() {
        assignedIncludedAssetCount = sceneAssignments.keys.reduce(into: 0) { count, assetID in
            guard ingestIncludedAssetIDs.contains(assetID), count < Int.max else { return }
            count += 1
        }
    }

    nonisolated private static func saturatingByteCountSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow {
            return rhs >= 0 ? Int64.max : Int64.min
        }
        return sum
    }

    private func rebuildReviewAssetProjection(sourceChanged: Bool) {
        if sourceChanged {
            reviewAllAssetIDs = Set(reviewAssets.map(\.id))
            reviewAssetTotalBytes = reviewAssets.reduce(0) { $0 + $1.byteCount }
        }
        let revision = reviewBrowserProjection.revision &+ 1
        reviewBrowserProjection = AssetBrowserProjection.make(
            assets: reviewAssets,
            searchText: reviewAssetSearchText,
            category: reviewAssetCategoryFilter,
            revision: revision
        )
        let visibleSelection = reviewSelectedAssetIDs.intersection(reviewBrowserProjection.visibleAssetIDs)
        if visibleSelection != reviewSelectedAssetIDs {
            reviewSelectedAssetIDs = visibleSelection
        }
    }

    private func bumpIngestCollectionMetadataRevision() {
        ingestCollectionMetadataRevision &+= 1
    }

    private func bumpReviewCollectionMetadataRevision() {
        reviewCollectionMetadataRevision &+= 1
    }

    private func rebuildReviewMetadataErrorProjection() {
        reviewMetadataErrorIDsProjection = Set(reviewRatingErrors.keys).union(reviewLabelErrors.keys)
        var combined: [UUID: String] = [:]
        combined.reserveCapacity(reviewMetadataErrorIDsProjection.count)
        for assetID in reviewMetadataErrorIDsProjection {
            var messages: [String] = []
            if let ratingError = reviewRatingErrors[assetID] {
                messages.append("Adobe XMP: \(ratingError)")
            }
            if let labelError = reviewLabelErrors[assetID] {
                messages.append("Finderカラー: \(labelError)")
            }
            combined[assetID] = messages.joined(separator: "\n")
        }
        reviewMetadataErrorsProjection = combined
    }

    var includedAssetIDs: Set<UUID> {
        ingestIncludedAssetIDs
    }
    var includedAssetCount: Int { includedAssetIDs.count }
    var explicitExclusionAssets: [AppAsset] {
        explicitExclusionAssetsProjection
    }
    var explicitExclusionTotalBytes: Int64 {
        explicitExclusionTotalBytesProjection
    }
    var unreviewedEmptyDirectoryCount: Int {
        emptyDirectoryReviewPaths.filter { emptyDirectoryExclusionEvidenceByPath[$0] == nil }.count
    }
    var reviewedEmptyDirectoryCount: Int {
        emptyDirectoryReviewPaths.count - unreviewedEmptyDirectoryCount
    }
    var canStartExclusiveOperation: Bool {
        !showCaptureConfigurationSheet && !showProjectLocationSheet && canStartExclusiveOperationOutsideProjectSheets
    }
    private var canStartExclusiveOperationOutsideProjectSheets: Bool {
        applicationInstanceLock != nil
            && operationStore != nil
            && !destructiveOutcomeQuarantined
            && !phase.isBusy
            && activeIngestScanTaskIDs.isEmpty
            && !renameIsBusy
            && !projectOperationInFlight
            && !reviewIsScanning
            && !reviewMetadataIsLoading
            && !reviewMetadataIsWriting
            && !mediaCacheOperationInFlight
            && !auditExportInFlight
            && !mediaAccessQuiescenceLatched
            && !lanOperationInProgress
            && operationTask == nil
            && reviewScanTask == nil
            && reviewMetadataTask == nil
            && deferredCardScanGeneration == nil
    }
    /// Source selection is normally governed by the shared exclusive-operation gate. The sole
    /// exception is a fresh ingest scan that can resolve an unexpected-removal isolation. No
    /// other operation may use this narrower recovery admission.
    var canStartIngestSourceScan: Bool {
        !showCaptureConfigurationSheet && !showProjectLocationSheet && Self.ingestSourceScanAdmissionAllowed(
            canStartExclusiveOperation: canStartExclusiveOperation,
            applicationReady: applicationInstanceLock != nil && operationStore != nil,
            phase: phase,
            ingestScanAdmissionMustWait: ingestScanAdmissionMustWait,
            hasIngestScanTask: !activeIngestScanTaskIDs.isEmpty,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            hasMediaReadIsolationGeneration: mediaReadIsolationGeneration != nil,
            hasMediaReadIsolationTask: mediaReadIsolationTask != nil,
            mediaReadIsolationFailed: mediaReadIsolationFailed,
            destructiveOutcomeQuarantined: destructiveOutcomeQuarantined,
            hasDeferredCardScan: deferredCardScanGeneration != nil
        )
    }
    var ingestScanBoundaryIsBusy: Bool {
        !activeIngestScanTaskIDs.isEmpty
    }
    var ingestScanBoundaryIsRetiring: Bool {
        !mediaReadIsolationFailed && Self.ingestScanBoundaryRetirementIsVisible(
            hasActiveIngestScanTask: !activeIngestScanTaskIDs.isEmpty,
            phase: phase
        )
    }

    nonisolated static func ingestScanBoundaryRetirementIsVisible(
        hasActiveIngestScanTask: Bool,
        phase: WorkspacePhase
    ) -> Bool {
        hasActiveIngestScanTask && !phase.isBusy
    }
    var canPresentMediaPreview: Bool {
        !showCaptureConfigurationSheet
            && !showProjectLocationSheet
            && !mediaCacheOperationInFlight
            && !mediaAccessQuiescenceLatched
            && !destructiveOutcomeQuarantined
            && !phase.isBusy
            && !renameIsBusy
            && !reviewMetadataIsWriting
            && operationTask == nil
    }
    var canClearMediaCaches: Bool {
        Self.mediaCacheClearAdmissionAllowed(
            canStartExclusiveOperation: canStartExclusiveOperation,
            captureDateMetadataIsLoading: captureDateMetadataIsLoading,
            hasCaptureDateEnrichmentTask: captureDateEnrichmentTask != nil,
            hasMediaReadIsolationGeneration: mediaReadIsolationGeneration != nil,
            hasMediaReadIsolationTask: mediaReadIsolationTask != nil,
            hasMediaPipeline: mediaPipeline != nil
        )
    }

    nonisolated static func mediaCacheClearAdmissionAllowed(
        canStartExclusiveOperation: Bool,
        captureDateMetadataIsLoading: Bool,
        hasCaptureDateEnrichmentTask: Bool,
        hasMediaReadIsolationGeneration: Bool,
        hasMediaReadIsolationTask: Bool,
        hasMediaPipeline: Bool
    ) -> Bool {
        canStartExclusiveOperation
            && !captureDateMetadataIsLoading
            && !hasCaptureDateEnrichmentTask
            && !hasMediaReadIsolationGeneration
            && !hasMediaReadIsolationTask
            && hasMediaPipeline
    }

    /// One admission policy is shared by manual scans and asynchronous card re-appearance. A
    /// monitor callback must never clear the current ingest UI before discovering that another
    /// workspace already owns the filesystem/media boundary.
    private var ingestScanAdmissionMustWait: Bool {
        showCaptureConfigurationSheet || showProjectLocationSheet || Self.ingestScanAdmissionMustWait(
            phase: phase,
            renameIsBusy: renameIsBusy,
            projectOperationInFlight: projectOperationInFlight,
            hasOperationTask: operationTask != nil,
            reviewIsScanning: reviewIsScanning,
            reviewMetadataIsLoading: reviewMetadataIsLoading,
            reviewMetadataIsWriting: reviewMetadataIsWriting,
            hasReviewScanTask: reviewScanTask != nil,
            hasReviewMetadataTask: reviewMetadataTask != nil,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            hasMediaReadIsolationGeneration: mediaReadIsolationGeneration != nil,
            hasMediaReadIsolationTask: mediaReadIsolationTask != nil,
            mediaReadIsolationFailed: mediaReadIsolationFailed,
            lanOperationInProgress: lanOperationInProgress,
            auditExportInFlight: auditExportInFlight,
            mediaCacheOperationInFlight: mediaCacheOperationInFlight,
            destructiveOutcomeQuarantined: destructiveOutcomeQuarantined
        )
    }

    nonisolated static func ingestScanAdmissionMustWait(
        phase: WorkspacePhase,
        renameIsBusy: Bool = false,
        projectOperationInFlight: Bool = false,
        hasOperationTask: Bool = false,
        reviewIsScanning: Bool = false,
        reviewMetadataIsLoading: Bool = false,
        reviewMetadataIsWriting: Bool = false,
        hasReviewScanTask: Bool = false,
        hasReviewMetadataTask: Bool = false,
        mediaAccessQuiescenceLatched: Bool = false,
        hasMediaReadIsolationGeneration: Bool = false,
        hasMediaReadIsolationTask: Bool = false,
        mediaReadIsolationFailed: Bool = false,
        lanOperationInProgress: Bool = false,
        auditExportInFlight: Bool = false,
        mediaCacheOperationInFlight: Bool = false,
        destructiveOutcomeQuarantined: Bool = false
    ) -> Bool {
        renameIsBusy
            || projectOperationInFlight
            || hasOperationTask
            || reviewIsScanning
            || reviewMetadataIsLoading
            || reviewMetadataIsWriting
            || hasReviewScanTask
            || hasReviewMetadataTask
            || (mediaAccessQuiescenceLatched
                && !(hasMediaReadIsolationGeneration && hasMediaReadIsolationTask))
            || mediaReadIsolationFailed
            || lanOperationInProgress
            || auditExportInFlight
            || mediaCacheOperationInFlight
            || destructiveOutcomeQuarantined
            || (phase.isBusy && phase != .scanning)
    }

    nonisolated static func ingestSourceScanAdmissionAllowed(
        canStartExclusiveOperation: Bool,
        applicationReady: Bool,
        phase: WorkspacePhase,
        ingestScanAdmissionMustWait: Bool,
        hasIngestScanTask: Bool,
        mediaAccessQuiescenceLatched: Bool,
        hasMediaReadIsolationGeneration: Bool,
        hasMediaReadIsolationTask: Bool,
        mediaReadIsolationFailed: Bool,
        destructiveOutcomeQuarantined: Bool,
        hasDeferredCardScan: Bool
    ) -> Bool {
        guard applicationReady,
              !phase.isBusy,
              !ingestScanAdmissionMustWait,
              !hasIngestScanTask,
              !mediaReadIsolationFailed,
              !destructiveOutcomeQuarantined,
              !hasDeferredCardScan
        else { return false }

        let hasAnyIsolationState = mediaAccessQuiescenceLatched
            || hasMediaReadIsolationGeneration
            || hasMediaReadIsolationTask
        if hasAnyIsolationState {
            return mediaAccessQuiescenceLatched
                && hasMediaReadIsolationGeneration
                && hasMediaReadIsolationTask
        }
        return canStartExclusiveOperation
    }

    var canExecutePreparedRename: Bool {
        guard canStartExclusiveOperation,
              preparedRenamePlan != nil,
              let preparedRenameIntent,
              let current = currentRenameIntent()
        else { return false }
        return preparedRenameIntent == current
    }
    var currentProjectIdentifier: UUID { projectID.rawValue }
    var canRecoverLastDeletedProject: Bool {
        lastDeletedProjectID != nil && canStartExclusiveOperation
    }
    var canDeleteCurrentStoredProject: Bool {
        Self.projectDeletionAdmissionAllowed(
            canStartExclusiveOperation: canStartExclusiveOperation,
            hasSelectedProject: selectedStoredProjectID != nil,
            hasProjectStore: projectStore != nil,
            selectedProjectMatchesCurrentIdentity: selectedStoredProjectID == projectID.rawValue
        )
    }
    nonisolated static func projectDeletionAdmissionAllowed(
        canStartExclusiveOperation: Bool,
        hasSelectedProject: Bool,
        hasProjectStore: Bool,
        selectedProjectMatchesCurrentIdentity: Bool = true
    ) -> Bool {
        canStartExclusiveOperation && hasSelectedProject && hasProjectStore && selectedProjectMatchesCurrentIdentity
    }
    var pendingExclusionAssets: [AppAsset] {
        pendingExclusionAssetsProjection
    }
    var pendingExclusionTotalBytes: Int64 {
        pendingExclusionTotalBytesProjection
    }
    var assignedCount: Int {
        assignedIncludedAssetCount
    }
    func assignmentCount(for sceneID: UUID) -> Int {
        sceneAssignmentCountsBySceneID[sceneID, default: 0]
    }
    var unassignedCount: Int { max(includedAssetCount - assignedCount, 0) }
    var totalBytes: Int64 { ingestAssetTotalBytes }
    var canPrepareCardInitialization: Bool {
        guard let scan = coreScanResult,
              let receipt = latestVerifiedReceipt,
              let plan = latestVerifiedPlan,
              let verifiedIntentGeneration = latestVerifiedIntentGeneration,
              verifiedIntentGeneration == ingestIntentGeneration,
              receipt.runID == plan.runID,
              scan.sourceVolumeID == plan.sourceVolume.id,
              destinationURL?.standardizedFileURL.resolvingSymlinksInPath()
                == plan.destination.rootURL.standardizedFileURL.resolvingSymlinksInPath(),
              plan.scanPolicy == MediaScanPolicy(projectSettings: projectSettings)
        else { return false }
        let excluded = Set(explicitlyExcludedAssetIDs.map(MediaAssetID.init(rawValue:)))
        let exclusionEvidence = explicitlyExcludedAssetIDs.compactMap {
            explicitExclusionEvidenceByAssetID[$0]
        }
        let directoryEvidence = currentEmptyDirectoryExclusionEvidence
        guard exclusionEvidence.count == explicitlyExcludedAssetIDs.count else { return false }
        guard directoryEvidence.count == emptyDirectoryReviewPaths.count else { return false }
        guard let requiredSet = try? scan.validatedRequiredSet(
            selectedAssetIDs: Set(scan.assets.map(\.id)).subtracting(excluded),
            destinationID: plan.destination.id,
            explicitlyExcludedAssetIDs: excluded,
            explicitExclusions: exclusionEvidence,
            explicitDirectoryExclusions: directoryEvidence,
            exclusionsReviewed: true
        ),
        requiredSet == plan.requiredSet,
        receipt.requiredSetDigest == (try? StableDigest.encode(plan.requiredSet))
        else { return false }
        guard cardInitializationEnabled,
              cardEraseRuntimeUnlocked,
              let identity = activeSourceIdentity,
              identity.identityStrength == .strongForCurrentInsertion,
              Self.scanScopeCoversCompleteCard(
                  activeSourceScanScope,
                  identity: identity
              ),
              identity.securityDigest == plan.sourceVolume.securityDigest,
              identity.isRemovable,
              !identity.isInternal,
              requiredSet.isStructurallyEligibleForErase,
              operationStore != nil,
              eraseGate != nil
        else { return false }
        return canStartExclusiveOperation
    }
    var canEjectActiveSource: Bool {
        guard let identity = activeSourceIdentity else { return false }
        return safeEjectRuntimeUnlocked
            && canStartExclusiveOperation
            && !mediaAccessQuiescenceLatched
            && mediaReadIsolationGeneration == nil
            && identity.identityStrength == .strongForCurrentInsertion
            && identity.isRemovable
            && !identity.isInternal
            && identity.isEjectable
    }
    var cardEraseAvailabilityMessage: String {
        if !DiskutilCardEraseBackend.isBundledProductionBoundaryAvailable {
            return "製品認定済みのretained media claim／handle-bound formatterが未搭載のため、このbuildではカード初期化を実行できません。"
        }
        if !cardEraseRuntimeUnlocked {
            return "カード初期化は通常起動では無効です。認定済み実機試験でのみ開発用flagを使用します。"
        }
        return "初期化には最終全再読検証と利用者確認が必要です。自動実行されません。"
    }
    var safeEjectAvailabilityMessage: String? {
        guard !safeEjectRuntimeUnlocked else { return nil }
        if !SafeEjectService.isBundledProductionBoundaryAvailable {
            return "製品認定済みのretained DADisk claim／native eject境界が未搭載のため、このbuildでは安全な取り出しを実行できません。"
        }
        return "安全な取り出しは通常起動では無効です。認定済み実機試験でのみ開発用flagを使用します。"
    }
    var canCancelCurrentOperation: Bool {
        if phase == .scanning, cancellingIngestScanGeneration != nil { return false }
        return phase != .erasingCard
            && phase != .ejectingCard
            && (phase.isBusy || renameIsBusy)
    }
    var configuredCategories: [ProjectCategory] {
        projectSettings.categories.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }
    var currentMediaScanPolicy: MediaScanPolicy {
        MediaScanPolicy(projectSettings: projectSettings)
    }
    var visibleIngestAssetIDs: Set<UUID> {
        ingestBrowserProjection.visibleAssetIDs
    }
    var visibleSelectedIngestAssetIDs: Set<UUID> {
        Self.visibleSelection(selectedAssetIDs, within: visibleIngestAssetIDs)
    }
    nonisolated static func visibleSelection(
        _ selectedIDs: Set<UUID>,
        within visibleIDs: Set<UUID>
    ) -> Set<UUID> {
        selectedIDs.intersection(visibleIDs)
    }
    var includesHiddenFiles: Bool { projectSettings.includeHiddenFiles }
    var excludedFolderNamesText: String {
        excludedFolderNamesDraft
    }

    func chooseSource() {
        guard canStartIngestSourceScan else { return }
        guard let url = chooseDirectory(prompt: "撮影カードまたは素材フォルダを選択") else { return }
        guard canStartIngestSourceScan else {
            statusMessage = "別の処理が開始されたため、ソース選択を適用しませんでした"
            return
        }
        automaticallySelectedCard = nil
        sourceURL = url
        scan(url: url)
    }

    @discardableResult
    func acceptDroppedURLs(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty, canStartIngestSourceScan else { return false }
        automaticallySelectedCard = nil
        if fileURLs.count == 1,
           (try? fileURLs[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            sourceURL = fileURLs[0]
        } else {
            sourceURL = fileURLs[0].deletingLastPathComponent()
        }
        scan(items: fileURLs)
        return true
    }

    func chooseDestination() {
        guard canStartExclusiveOperation else { return }
        guard let selectedURL = chooseDirectory(prompt: "保存先フォルダを選択") else { return }
        guard canStartExclusiveOperation else {
            statusMessage = "別の処理が開始されたため、保存先選択を適用しませんでした"
            return
        }
        setProjectDestination(selectedURL)
    }

    /// Persist only this field of an existing project. Choosing a folder must not implicitly
    /// save unrelated edits to scenes, project name, or capture configuration.
    func setProjectDestination(_ selectedURL: URL) {
        guard canStartExclusiveOperation else { return }
        let hadOtherUnsavedChanges = projectHasUnsavedChanges
        destinationURL = selectedURL
        guard let id = selectedStoredProjectID, let projectStore else {
            projectDestinationStatus = "この保存先を保持するにはプロジェクトを保存してください"
            return
        }
        guard id == projectID.rawValue else {
            projectDestinationStatus = "保存対象のプロジェクトが一致しません。プロジェクトを再度保存してください"
            return
        }
        let expectedProjectID = projectID
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectDestinationStatus = "保存先をプロジェクトへ保存中…"
        Task { [weak self] in
            guard let self else { return }
            defer { projectOperationInFlight = false }
            do {
                let loaded = try await projectStore.load(id: ProjectID(rawValue: id))
                let updated = ProjectConfigurationEditing.replacingDestination(of: loaded.project, with: selectedURL)
                try await projectStore.save(updated)
                guard projectID == expectedProjectID else { return }
                let otherChangesRemain = hadOtherUnsavedChanges || projectOperationGeneration != generation
                projectHasUnsavedChanges = otherChangesRemain
                projectDestinationStatus = "保存先をプロジェクトに保存しました"
                projectPersistenceStatus = otherChangesRemain ? "保存先は保存済み・その他に未保存の変更" : "保存済み"
                refreshStoredProjects()
            } catch {
                guard projectID == expectedProjectID else { return }
                projectDestinationStatus = "保存先の保持に失敗しました。プロジェクトを再度保存してください"
                projectPersistenceStatus = "保存先の保存失敗・未保存"
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    var availableProjectLocations: [ProjectLocation] {
        projectSettings.locations.filter { !$0.isArchived }
    }
    var selectedProjectLocationID: UUID? {
        projectSettings.locations.first {
            $0.id == projectSettings.selectedLocationID && !$0.isArchived && $0.displayName == locationName
        }?.id.rawValue
    }
    var availableProjectPhotographers: [Photographer] {
        projectPhotographers.filter { !$0.isArchived }
    }
    var availableProjectCards: [CardDefinition] {
        projectSettings.cardDefinitions.filter(\.isActive)
    }

    func selectProjectLocation(id: UUID?) {
        guard canStartExclusiveOperation else { return }
        guard let id else {
            projectSettings.selectedLocationID = nil
            locationName = ""
            markProjectMetadataDirty()
            return
        }
        guard let entry = availableProjectLocations.first(where: { $0.id.rawValue == id }) else { return }
        projectSettings.selectedLocationID = entry.id
        locationName = entry.displayName
        markProjectMetadataDirty()
    }

    func beginAddProjectLocation() {
        guard canStartExclusiveOperation else { return }
        projectLocationError = nil
        showProjectLocationSheet = true
    }

    @discardableResult
    func addProjectLocation(named name: String) -> Bool {
        guard !showCaptureConfigurationSheet, canStartExclusiveOperationOutsideProjectSheets else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            projectLocationError = "会場名を入力してください"
            return false
        }
        var settings = projectSettings
        do {
            try ProjectConfigurationEditing.reconcileLocation(name: normalized, settings: &settings)
            projectSettings = settings
            locationName = normalized
            markProjectMetadataDirty()
            projectLocationError = nil
            showProjectLocationSheet = false
            return true
        } catch {
            projectLocationError = userFacingMessage(for: error)
            return false
        }
    }

    func makeCaptureConfigurationDraft() -> CaptureConfigurationDraft {
        let selectedPhotographer = availableProjectPhotographers.first {
            $0.id == selectedProjectPhotographerID && $0.displayName == photographer
        }
        let selectedCard = availableProjectCards.first {
            $0.id == selectedProjectCardID && $0.cardNumber == cardNumber
        }
        return CaptureConfigurationDraft(
            projectID: projectID.rawValue,
            selectedPhotographerID: selectedPhotographer?.id.rawValue,
            selectedCardID: selectedCard?.id.rawValue,
            newPhotographerName: selectedPhotographer == nil ? photographer : "",
            newCardNumber: selectedCard == nil ? cardNumber : ""
        )
    }

    func beginCaptureConfiguration() {
        guard canStartExclusiveOperation else { return }
        captureConfigurationError = nil
        showCaptureConfigurationSheet = true
    }

    @discardableResult
    func applyCaptureConfiguration(_ draft: CaptureConfigurationDraft) -> Bool {
        guard !showProjectLocationSheet, canStartExclusiveOperationOutsideProjectSheets,
              draft.projectID == projectID.rawValue else { return false }
        do {
            let resolved = try ProjectConfigurationEditing.resolve(
                draft, photographers: projectPhotographers, cards: projectSettings.cardDefinitions
            )
            // Resolution validates everything first. No partial changes survive a failure.
            projectPhotographers = resolved.photographers
            projectSettings.cardDefinitions = resolved.cards
            selectedProjectPhotographerID = resolved.photographerID
            selectedProjectCardID = resolved.cardID
            photographer = resolved.photographerName
            cardNumber = resolved.cardNumber
            markProjectMetadataDirty()
            captureConfigurationError = nil
            showCaptureConfigurationSheet = false
            statusMessage = "撮影者・カードNoを設定しました。登録内容はプロジェクトの保存で保持されます"
            return true
        } catch {
            captureConfigurationError = userFacingMessage(for: error)
            return false
        }
    }

    func createNewProject() {
        guard canStartExclusiveOperation else { return }
        let rescanScope = activeSourceScanScope
        resetToNewProjectState()
        restartScanAfterProjectTransition(rescanScope)
    }

    func resetToNewProjectState() {
        lanSceneCatalog?.setOff()
        lanCatalogEnabled = false
        projectOperationGeneration = UUID()
        projectID = ProjectID()
        selectedStoredProjectID = nil
        projectName = "新規プロジェクト"
        destinationURL = nil
        photographer = ""
        cardNumber = ""
        locationName = ""
        projectPhotographers = []
        selectedProjectPhotographerID = nil
        selectedProjectCardID = nil
        showCaptureConfigurationSheet = false
        showProjectLocationSheet = false
        captureConfigurationError = nil
        projectLocationError = nil
        projectDestinationStatus = "新規プロジェクトの保存先を選択してください"
        projectSettings = ProjectSettings(
            categories: Self.defaultProjectCategories(),
            renameRule: Self.defaultRenameRule
        )
        excludedFolderNamesDraft = ""
        renameTemplate = Self.template(from: projectSettings.renameRule)
        scenes = Self.defaultScenes()
        selectedSceneID = scenes.first?.id
        clearScanDerivedStateForProjectTransition()
        appliedSceneCatalogVersion = nil
        projectPersistenceStatus = "新規・未保存"
    }

    func saveCurrentProject() {
        guard canStartExclusiveOperation,
              let projectStore
        else { return }
        do {
            let project = try makePersistedProject()
            let generation = UUID()
            projectOperationGeneration = generation
            projectOperationInFlight = true
            projectPersistenceStatus = "保存中…"
            Task { [weak self] in
                guard let self else { return }
                defer { projectOperationInFlight = false }
                do {
                    try await projectStore.save(project)
                    guard projectOperationGeneration == generation else {
                        projectPersistenceStatus = "保存中に変更あり・未保存"
                        return
                    }
                    selectedStoredProjectID = project.id.rawValue
                    projectHasUnsavedChanges = false
                    projectDestinationStatus = "保存先をプロジェクトに保存しました"
                    projectPersistenceStatus = "保存済み"
                    statusMessage = "プロジェクト設定をatomic保存しました"
                    refreshStoredProjects()
                } catch {
                    guard projectOperationGeneration == generation else { return }
                    projectPersistenceStatus = "保存失敗"
                    statusMessage = userFacingMessage(for: error)
                }
            }
        } catch {
            projectPersistenceStatus = "保存失敗"
            statusMessage = userFacingMessage(for: error)
        }
    }

    func loadStoredProject(id: UUID?) {
        // The picker must not publish the requested ID before loading succeeds. A failed or
        // rejected load keeps the displayed project and deletion target bound to the same ID.
        // Choosing the explicit "new / unselected" row is the same action as the New button.
        guard let id else {
            createNewProject()
            return
        }
        guard canStartExclusiveOperation,
              let projectStore
        else { return }
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "読込中…"
        Task { [weak self] in
            guard let self else { return }
            var rescanScope: AppSourceScanScope?
            var transitionApplied = false
            defer {
                projectOperationInFlight = false
                if transitionApplied {
                    restartScanAfterProjectTransition(rescanScope)
                }
            }
            do {
                let result = try await projectStore.load(id: ProjectID(rawValue: id))
                guard projectOperationGeneration == generation, !phase.isBusy else { return }
                guard result.project.id.rawValue == id else {
                    throw UMISCoreError.invalidPlan("読み込んだプロジェクトのIDが選択対象と一致しません")
                }
                rescanScope = activeSourceScanScope
                applyStoredProject(result.project)
                transitionApplied = true
                selectedStoredProjectID = result.project.id.rawValue
                projectPersistenceStatus = result.source == .main ? "読込済み" : "バックアップから復旧読込"
                projectHasUnsavedChanges = false
                statusMessage = result.source == .main
                    ? "プロジェクトを読み込みました"
                    : "mainが無効だったため既知正常バックアップを読み込みました"
            } catch {
                guard projectOperationGeneration == generation else { return }
                projectPersistenceStatus = "読込失敗"
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    func deleteCurrentStoredProject() {
        guard canDeleteCurrentStoredProject,
              let id = selectedStoredProjectID,
              id == projectID.rawValue,
              let projectStore
        else { return }
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "削除中…"
        Task { [weak self] in
            guard let self else { return }
            var rescanScope: AppSourceScanScope?
            var transitionApplied = false
            defer {
                projectOperationInFlight = false
                if transitionApplied {
                    restartScanAfterProjectTransition(rescanScope)
                }
            }
            do {
                _ = try await projectStore.delete(id: ProjectID(rawValue: id))
                guard projectOperationGeneration == generation else { return }
                lastDeletedProjectID = id
                rescanScope = activeSourceScanScope
                resetToNewProjectState()
                transitionApplied = true
                projectPersistenceStatus = "削除済み（アプリ内Trashから復旧可能）"
                statusMessage = "プロジェクトを復旧可能なTrashへ移動しました"
                refreshStoredProjects()
            } catch {
                guard projectOperationGeneration == generation else { return }
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    func recoverLastDeletedProject() {
        guard canRecoverLastDeletedProject,
              let id = lastDeletedProjectID,
              let projectStore
        else { return }
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "Trashから復旧中…"
        Task { [weak self] in
            guard let self else { return }
            var rescanScope: AppSourceScanScope?
            var transitionApplied = false
            defer {
                projectOperationInFlight = false
                if transitionApplied {
                    restartScanAfterProjectTransition(rescanScope)
                }
            }
            do {
                let projectID = ProjectID(rawValue: id)
                try await projectStore.recover(id: projectID)
                let loaded = try await projectStore.load(id: projectID)
                guard projectOperationGeneration == generation, !phase.isBusy else { return }
                rescanScope = activeSourceScanScope
                applyStoredProject(loaded.project)
                transitionApplied = true
                selectedStoredProjectID = id
                lastDeletedProjectID = nil
                projectPersistenceStatus = "Trashから復旧済み"
                statusMessage = "直前に削除したプロジェクトを復旧しました"
                refreshStoredProjects()
            } catch {
                guard projectOperationGeneration == generation else { return }
                projectPersistenceStatus = "復旧失敗"
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    func importLegacyProject() {
        guard canStartExclusiveOperation, let projectStore else { return }
        let panel = NSOpenPanel()
        panel.title = "旧Python/Flet版のプロジェクトJSONを読み取り専用で移行"
        panel.prompt = "移行"
        panel.allowedContentTypes = [.json, .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let mainURL = panel.url else { return }
        guard canStartExclusiveOperation else {
            statusMessage = "別の処理が開始されたため、旧プロジェクト移行を開始しませんでした"
            return
        }

        let adjacentCandidates = [
            mainURL.appendingPathExtension("bak"),
            mainURL.deletingPathExtension().appendingPathExtension("bak"),
        ]
        let backupURL = adjacentCandidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "旧プロジェクトを検証中…"
        Task { [weak self] in
            guard let self else { return }
            var rescanScope: AppSourceScanScope?
            var transitionApplied = false
            defer {
                projectOperationInFlight = false
                if transitionApplied {
                    restartScanAfterProjectTransition(rescanScope)
                }
            }
            do {
                let imported = try await Task.detached(priority: .utility) {
                    try LegacyImporter().importProject(mainURL: mainURL, backupURL: backupURL)
                }.value
                let current = try await projectStore.listWithDiagnostics()
                guard !current.projects.contains(where: { $0.id == imported.project.id }) else {
                    throw UMISCoreError.collision(
                        "同じ旧プロジェクトはすでに移行済みです（\(imported.project.id.rawValue)）"
                    )
                }
                try await projectStore.save(imported.project)
                guard projectOperationGeneration == generation, !phase.isBusy else { return }
                rescanScope = activeSourceScanScope
                applyStoredProject(imported.project)
                transitionApplied = true
                selectedStoredProjectID = imported.project.id.rawValue
                projectPersistenceStatus = imported.source == .main
                    ? "旧プロジェクト移行済み"
                    : "旧バックアップから移行済み"
                statusMessage = imported.diagnostics.isEmpty
                    ? "旧プロジェクトを原本非変更で移行しました"
                    : "旧プロジェクトを原本非変更で移行しました（診断\(imported.diagnostics.count)件）"
                refreshStoredProjects()
            } catch {
                guard projectOperationGeneration == generation else { return }
                projectPersistenceStatus = "旧プロジェクト移行失敗"
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    func chooseRenameSource() {
        guard canStartExclusiveOperation else { return }
        guard let selectedURL = chooseDirectory(prompt: "リネームする既存フォルダを選択") else { return }
        guard canStartExclusiveOperation else {
            renameStatusMessage = "別の処理が開始されたため、入力フォルダ選択を適用しませんでした"
            return
        }
        renameSourceURL = selectedURL
        preparedRenamePlan = nil
        preparedRenameIntent = nil
        renamePreviewRows = []
    }

    func chooseRenameDestination() {
        guard canStartExclusiveOperation else { return }
        guard let selectedURL = chooseDirectory(prompt: "リネーム済みコピーの保存先を選択") else { return }
        guard canStartExclusiveOperation else {
            renameStatusMessage = "別の処理が開始されたため、出力フォルダ選択を適用しませんでした"
            return
        }
        renameDestinationURL = selectedURL
        preparedRenamePlan = nil
        preparedRenameIntent = nil
        renamePreviewRows = []
    }

    func prepareRenamePlan(template: String) {
        guard canStartExclusiveOperation else { return }
        guard let sourceRoot = renameSourceURL, let destinationRoot = renameDestinationURL else {
            renameStatusMessage = "入力と出力フォルダを選択してください"
            return
        }
        guard let store = operationStore else {
            renameStatusMessage = "操作ジャーナルを利用できません"
            return
        }
        _ = store
        guard let intent = currentRenameIntent() else {
            renameStatusMessage = "入力、出力、命名条件を確定してください"
            return
        }
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        let rule: RenameRule
        do {
            rule = try Self.renameRule(
                from: template,
                timeZoneIdentifier: captureDateTimeZone.identifier
            )
        } catch {
            renameStatusMessage = userFacingMessage(for: error)
            return
        }
        let selectedScene = selectedSceneID.flatMap { id in scenes.first { $0.id == id } }
        let context = RenameContext(
            location: locationName.nilIfBlank,
            sceneCode: selectedScene.map(Self.sceneCode),
            sceneName: selectedScene?.name,
            photographer: photographer.nilIfBlank,
            cardNumber: cardNumber.nilIfBlank
        )
        let scanPolicy = MediaScanPolicy(projectSettings: projectSettings)
        let scanMediaPipeline = mediaPipeline
        let renameSourceIdentity = cardVolumeMonitor?.identity(containing: sourceRoot)
        let renameOperationStore = operationStore
        let renameDestinationIdentityProvider = destinationIdentityProvider
        let frozenProject = Project(id: projectID, name: projectName.nilIfBlank ?? "Folder Rename")
        renameIsBusy = true
        renameStatusMessage = "全ファイル名・衝突・内容fingerprintを検査しています"
        preparedRenamePlan = nil
        preparedRenameIntent = nil
        renamePreviewRows = []
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let volumeID = renameSourceIdentity?.id ?? SourceVolumeID()
                let operation: @Sendable () async throws -> (ScanResult, RenamePlan) = {
                    let scanned = try await MediaScanner().scan(
                        root: sourceRoot,
                        sourceVolumeID: volumeID,
                        policy: scanPolicy
                    )
                    let scan = try await Self.enrichingCaptureDates(
                        in: scanned,
                        mediaPipeline: scanMediaPipeline,
                        assumedTimeZone: captureDateTimeZone
                    )
                    let requests = scan.assets.map { RenameRequest(asset: $0, context: context) }
                    let destinationIdentity = try await renameDestinationIdentityProvider.resolve(
                        rootURL: destinationRoot
                    )
                    let plan = try await RenamePlanner().plan(
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot,
                        requests: requests,
                        rule: rule,
                        collisionPolicy: .block,
                        project: frozenProject,
                        sourceVolume: renameSourceIdentity,
                        destinationIdentity: destinationIdentity,
                        scanPolicy: scanPolicy
                    )
                    return (scan, plan)
                }
                let (scan, plan): (ScanResult, RenamePlan)
                if let renameSourceIdentity {
                    guard let renameOperationStore else {
                        throw UMISCoreError.eraseNotEligible(
                            "Durable operation storage is required before reading a physical card"
                        )
                    }
                    (scan, plan) = try await volumeActivity.withActivity(
                        identity: renameSourceIdentity,
                        durableStore: renameOperationStore,
                        operation: operation
                    )
                } else {
                    (scan, plan) = try await volumeActivity.withActivity(
                        sourceVolumeID: volumeID,
                        operation: operation
                    )
                }
                try Task.checkCancellation()
                guard currentRenameIntent() == intent else {
                    throw UMISCoreError.invalidPlan("プレビュー作成中に命名条件が変わりました。再作成してください")
                }
                preparedRenamePlan = plan
                preparedRenameIntent = intent
                renamePreviewRows = plan.items.map {
                    RenamePreviewRow(
                        id: $0.ingestItem.id.rawValue,
                        before: $0.beforeRelativePath,
                        after: $0.afterRelativePath,
                        byteCount: $0.ingestItem.asset.byteSize
                    )
                }
                let ignored = scan.inventory.filter { $0.classification == .unknown }.count
                renameStatusMessage = ignored == 0
                    ? "\(plan.items.count)件の計画を確定しました。内容を確認して実行してください"
                    : "\(plan.items.count)件を計画しました（未対応項目\(ignored)件は元フォルダに残ります）"
            } catch is CancellationError {
                renameStatusMessage = "計画作成を中止しました"
            } catch {
                renameStatusMessage = userFacingMessage(for: error)
            }
            renameIsBusy = false
            operationTask = nil
        }
    }

    func executePreparedRename() {
        guard canStartExclusiveOperation,
              let plan = preparedRenamePlan,
              let preparedRenameIntent,
              currentRenameIntent() == preparedRenameIntent,
              let store = operationStore
        else {
            self.preparedRenamePlan = nil
            self.preparedRenameIntent = nil
            renamePreviewRows = []
            renameStatusMessage = "入力条件がプレビュー後に変わりました。計画を再作成してください"
            return
        }
        renameIsBusy = true
        renameStatusMessage = "検証付きCopy and Renameを実行しています"
        let cancellation = OperationCancellation()
        operationCancellation = cancellation
        let startedAt = Date()
        let destinationRevalidator = destinationIdentityProvider.makeRevalidationHandler()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await volumeActivity.withActivity(
                    sourceVolumeID: plan.sourceVolume.id
                ) {
                    try await CopyAndRenameEngine(
                        store: store,
                        destinationRevalidator: destinationRevalidator
                    ).execute(
                        plan: plan,
                        cancellation: cancellation
                    ) { [weak self] progress in
                        await MainActor.run {
                            guard let self else { return }
                            self.renameStatusMessage = "コピー・検証中 \(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
                        }
                    }
                }
                try Task.checkCancellation()
                renameStatusMessage = "\(receipt.ingestReceipt.deliveries.count)件のCopy and RenameとSHA-256検証が完了しました"
                preparedRenamePlan = nil
                self.preparedRenameIntent = nil
                renamePreviewRows = []
                activity.insert(
                    ActivityRecord(
                        id: receipt.transactionID.rawValue,
                        startedAt: startedAt,
                        title: "フォルダCopy and Rename",
                        detail: plan.destinationRoot.path,
                        state: .verified,
                        itemCount: receipt.ingestReceipt.deliveries.count,
                        totalBytes: receipt.ingestReceipt.deliveries.reduce(0) { $0 + $1.byteSize }
                    ),
                    at: 0
                )
            } catch is CancellationError {
                renameStatusMessage = "処理を中止しました。rollback／recovery状態を履歴で確認してください"
            } catch let error as UMISCoreError where error == .cancelled {
                renameStatusMessage = "処理を中止しました。rollback／recovery状態を履歴で確認してください"
            } catch {
                renameStatusMessage = userFacingMessage(for: error)
            }
            renameIsBusy = false
            operationCancellation = nil
            refreshOperationHistory()
            operationTask = nil
        }
    }

    func rescan() {
        guard canStartIngestSourceScan, let sourceURL else { return }
        scan(url: sourceURL)
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        let cancelledIngestScan = phase == .scanning && scanTask != nil
        if cancelledIngestScan {
            cancellingIngestScanGeneration = scanGeneration
        }
        scanTask?.cancel()
        operationTask?.cancel()
        if let operationCancellation {
            Task { await operationCancellation.cancel() }
        }
        if operationTask == nil, !cancelledIngestScan {
            phase = assets.isEmpty ? .idle : .ready
        }
        if cancelledIngestScan {
            statusMessage = "スキャンの中止を要求しました。ファイルと媒体の読取境界が閉じるまで待っています"
        } else {
            statusMessage = "中止を要求しました。現在のファイル境界で安全に停止します"
        }
    }

    func selectAll() {
        selectedAssetIDs = visibleIngestAssetIDs
    }

    func clearSelection() {
        selectedAssetIDs.removeAll()
    }

    func toggleSelection(_ assetID: UUID) {
        if selectedAssetIDs.contains(assetID) {
            selectedAssetIDs.remove(assetID)
        } else if visibleIngestAssetIDs.contains(assetID) {
            selectedAssetIDs.insert(assetID)
        }
    }

    func presentPreview(_ asset: AppAsset) {
        guard canPresentMediaPreview else { return }
        previewAsset = asset
    }

    @discardableResult
    func previewPlaybackDidStart(assetID: UUID) -> UUID? {
        guard canPresentMediaPreview else { return nil }
        let token = UUID()
        activePreviewPlaybackIDs.insert(token)
        _ = assetID
        return token
    }

    /// A preview calls this only after it has synchronously paused and detached its player item,
    /// cancelled asset loading, and released every strong AVFoundation reference it owns. Keeping
    /// those objects as arguments here would itself retain them past the quiescence acknowledgement.
    func previewPlaybackObjectsDidRelease(token: UUID?) async {
        // Let detach/cancellation work already enqueued by AVFoundation drain before the token can
        // satisfy the mutation/eject quiescence boundary. Object lifetime is not inferred from this
        // delay: the caller has already released its strong references before entering this method.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        if let token {
            activePreviewPlaybackIDs.remove(token)
        }
    }

    /// Establishes the same media-read boundary used before eject/erase. Review metadata writes can
    /// rewrite an entire JPEG, TIFF, PSD, or movie, so no thumbnail decoder or preview player may
    /// retain a read against the old inode while Adobe commits the safe update.
    func beginReviewMediaMutationQuiescence() {
        mediaAccessQuiescenceLatched = true
        previewAsset = nil
    }

    func suspendMediaReadsForReviewMutation() async throws {
        try await waitForPreviewPlaybackQuiescence()
        await mediaPipeline?.suspendAndAwaitQuiescence()
        try await waitForPreviewPlaybackQuiescence()
        try Task.checkCancellation()
    }

    /// A card-removal isolation may begin while an archive write is in flight. In that case the
    /// pipeline must remain suspended; this method never clears a newer isolation boundary.
    func finishReviewMediaMutationQuiescence() async {
        guard mediaReadIsolationGeneration == nil,
              !destructiveOutcomeQuarantined else { return }
        await mediaPipeline?.resumeRequests()
        if mediaReadIsolationGeneration == nil, !destructiveOutcomeQuarantined {
            mediaAccessQuiescenceLatched = false
            // Quiescence cancels visible and prefetched decode work. Reconfigure review cells so
            // any thumbnail that had not reached the cache is requested again after the write.
            reviewThumbnailReloadGeneration = UUID()
        } else {
            await mediaPipeline?.suspendAndAwaitQuiescence()
        }
    }

    func assignSelectionToCurrentScene() {
        guard canInteractWithScenePanel, selectedSceneIsVisible else { return }
        guard let selectedSceneID, let scan = coreScanResult else { return }
        let groupedSelection = Self.expandedCompanionAssetIDs(
            visibleSelectedIngestAssetIDs,
            assets: scan.assets
        )
        let assignable = groupedSelection.intersection(includedAssetIDs)
        applySceneAssignmentBatch(assignable, sceneID: selectedSceneID)
        selectedAssetIDs.removeAll()
        invalidateVerifiedIngestIntent()
        statusMessage = "\(assignedCount)件をシーンへ割り当て済み"
    }

    func removeAssignmentsForSelection() {
        guard canStartExclusiveOperation, let scan = coreScanResult else { return }
        let groupedSelection = Self.expandedCompanionAssetIDs(
            visibleSelectedIngestAssetIDs,
            assets: scan.assets
        )
        applySceneAssignmentBatch(groupedSelection, sceneID: nil)
        invalidateVerifiedIngestIntent()
    }

    /// Applies an arbitrarily large selection through one `@Published` dictionary assignment.
    /// Keeping the mutations on a local copy avoids one publication and metadata revision per ID.
    func applySceneAssignmentBatch(_ assetIDs: Set<UUID>, sceneID: UUID?) {
        guard !assetIDs.isEmpty else { return }
        var updatedAssignments = sceneAssignments
        var changed = false
        if let sceneID {
            let (requestedCapacity, capacityOverflow) = updatedAssignments.count
                .addingReportingOverflow(assetIDs.count)
            if !capacityOverflow {
                updatedAssignments.reserveCapacity(requestedCapacity)
            }
            for assetID in assetIDs where updatedAssignments[assetID] != sceneID {
                updatedAssignments[assetID] = sceneID
                changed = true
            }
        } else {
            for assetID in assetIDs where updatedAssignments.removeValue(forKey: assetID) != nil {
                changed = true
            }
        }
        guard changed else { return }
        sceneAssignments = updatedAssignments
    }

    func excludeSelectionFromIngest() {
        guard !phase.isBusy, !renameIsBusy else { return }
        // Exclusion is intentionally asset-specific and audited. This lets an operator resolve an
        // ambiguous same-stem multi-primary group by excluding only the confirmed extra primary.
        // Any unsafe remainder (for example sidecars without a primary) still fails plan validation.
        let valid = visibleSelectedIngestAssetIDs
        guard !valid.isEmpty else { return }
        pendingExclusionAssetIDs = valid
        showAssetExclusionConfirmation = true
    }

    func confirmPendingAssetExclusion(reason: String, operatorIdentifier: String) {
        guard !phase.isBusy,
              !renameIsBusy,
              showAssetExclusionConfirmation,
              !pendingExclusionAssetIDs.isEmpty,
              let scan = coreScanResult
        else { return }
        do {
            let evidence = try Self.makeExplicitExclusionEvidenceBatch(
                assets: scan.assets,
                assetIDs: pendingExclusionAssetIDs,
                reason: reason,
                operatorIdentifier: operatorIdentifier,
                confirmedAt: Date()
            )
            commitExplicitAssetExclusionEvidence(evidence)
            selectedAssetIDs.removeAll()
            pendingExclusionAssetIDs.removeAll()
            showAssetExclusionConfirmation = false
            invalidateVerifiedIngestIntent()
            statusMessage = "\(evidence.count)件を理由・担当者・確認時刻付きで明示除外しました"
        } catch {
            statusMessage = userFacingMessage(for: error)
        }
    }

    /// Indexes a frozen scan once before creating evidence. Calling
    /// `ScanResult.makeExplicitExclusionEvidence` once per selected ID would linearly search the
    /// complete scan each time and turn a large confirmation into O(assetCount²).
    nonisolated static func makeExplicitExclusionEvidenceBatch(
        assets: [MediaAsset],
        assetIDs: Set<UUID>,
        reason: String,
        operatorIdentifier: String,
        confirmedAt: Date
    ) throws -> [ExplicitExclusionEvidence] {
        var assetsByID: [UUID: MediaAsset] = [:]
        assetsByID.reserveCapacity(assets.count)
        for asset in assets {
            guard assetsByID.updateValue(asset, forKey: asset.id.rawValue) == nil else {
                throw UMISCoreError.invalidPlan("Scan contains duplicate media asset IDs")
            }
        }

        var evidence: [ExplicitExclusionEvidence] = []
        evidence.reserveCapacity(assetIDs.count)
        for assetID in assetIDs {
            guard let asset = assetsByID[assetID] else {
                throw UMISCoreError.invalidPlan("Cannot exclude an asset outside this scan")
            }
            evidence.append(try ExplicitExclusionEvidence(
                assetID: asset.id,
                relativePath: asset.relativePath,
                byteSize: asset.byteSize,
                reason: reason,
                operatorIdentifier: operatorIdentifier,
                operatorConfirmedAt: confirmedAt
            ))
        }
        return evidence
    }

    /// Commits validated exclusion evidence with at most one publication for the exclusion set and
    /// one for scene assignments, independent of the number of excluded assets.
    func commitExplicitAssetExclusionEvidence(_ evidence: [ExplicitExclusionEvidence]) {
        guard !evidence.isEmpty else { return }
        var updatedEvidence = explicitExclusionEvidenceByAssetID
        var updatedExcludedIDs = explicitlyExcludedAssetIDs
        var updatedAssignments = sceneAssignments
        let (evidenceCapacity, evidenceCapacityOverflow) = updatedEvidence.count
            .addingReportingOverflow(evidence.count)
        if !evidenceCapacityOverflow {
            updatedEvidence.reserveCapacity(evidenceCapacity)
        }
        let (excludedCapacity, excludedCapacityOverflow) = updatedExcludedIDs.count
            .addingReportingOverflow(evidence.count)
        if !excludedCapacityOverflow {
            updatedExcludedIDs.reserveCapacity(excludedCapacity)
        }
        var exclusionsChanged = false
        var assignmentsChanged = false

        for record in evidence {
            let assetID = record.assetID.rawValue
            updatedEvidence[assetID] = record
            exclusionsChanged = updatedExcludedIDs.insert(assetID).inserted || exclusionsChanged
            assignmentsChanged = updatedAssignments.removeValue(forKey: assetID) != nil
                || assignmentsChanged
        }

        // Evidence must be available before an exclusion becomes observable. This maintains the
        // audited-exclusion invariant even for synchronous Published subscribers.
        explicitExclusionEvidenceByAssetID = updatedEvidence
        if assignmentsChanged {
            sceneAssignments = updatedAssignments
        }
        if exclusionsChanged {
            explicitlyExcludedAssetIDs = updatedExcludedIDs
        }
    }

    func cancelPendingAssetExclusion() {
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
    }

    func reviewEmptyDirectoryExclusions() {
        guard !phase.isBusy,
              !renameIsBusy,
              !emptyDirectoryReviewPaths.isEmpty
        else { return }
        showEmptyDirectoryExclusionConfirmation = true
    }

    func confirmEmptyDirectoryExclusions(reason: String, operatorIdentifier: String) {
        guard !phase.isBusy,
              !renameIsBusy,
              showEmptyDirectoryExclusionConfirmation,
              !emptyDirectoryReviewPaths.isEmpty,
              let scan = coreScanResult
        else { return }
        do {
            let evidence = try emptyDirectoryReviewPaths.map { path in
                try scan.makeEmptyDirectoryExclusionEvidence(
                    relativePath: path,
                    reason: reason,
                    operatorIdentifier: operatorIdentifier
                )
            }
            emptyDirectoryExclusionEvidenceByPath = Dictionary(
                uniqueKeysWithValues: evidence.map { ($0.relativePath, $0) }
            )
            showEmptyDirectoryExclusionConfirmation = false
            invalidateVerifiedIngestIntent()
            statusMessage = "\(evidence.count)件の空フォルダを再作成対象外として理由・担当者・確認時刻付きで記録しました"
        } catch {
            statusMessage = userFacingMessage(for: error)
        }
    }

    func cancelEmptyDirectoryExclusionConfirmation() {
        showEmptyDirectoryExclusionConfirmation = false
    }

    func includeSelectionInIngest() {
        guard !phase.isBusy, !renameIsBusy else { return }
        let restored = visibleSelectedIngestAssetIDs.intersection(explicitlyExcludedAssetIDs)
        guard !restored.isEmpty else { return }
        explicitlyExcludedAssetIDs.subtract(restored)
        for id in restored { explicitExclusionEvidenceByAssetID.removeValue(forKey: id) }
        selectedAssetIDs.removeAll()
        invalidateVerifiedIngestIntent()
        statusMessage = "\(restored.count)件を取り込み対象に戻しました。シーンを割り当ててください"
    }

    func restoreAllExcludedAssets() {
        guard !phase.isBusy, !renameIsBusy else { return }
        guard !explicitlyExcludedAssetIDs.isEmpty else { return }
        let count = explicitlyExcludedAssetIDs.count
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        invalidateVerifiedIngestIntent()
        statusMessage = "除外していた\(count)件を取り込み対象に戻しました"
    }

    func assignedScene(for assetID: UUID) -> AppScene? {
        guard let sceneID = sceneAssignments[assetID] else { return nil }
        return scenes.first { $0.id == sceneID }
    }

    func addScene(day: Int) {
        guard !phase.isBusy, !renameIsBusy else { return }
        let highest = scenes.filter { $0.day == day }.map(\.number).max() ?? 0
        let (next, overflow) = highest.addingReportingOverflow(1)
        guard !overflow, next <= Int(Int32.max) else {
            statusMessage = "シーン番号が上限に達したため追加できません"
            return
        }
        let scene = AppScene(id: UUID(), day: day, number: next, name: "シーン\(next)")
        scenes.append(scene)
        selectedSceneID = scene.id
        markLocalSceneMutation()
    }

    func updateSceneName(id: UUID, name: String) {
        guard !phase.isBusy,
              !renameIsBusy,
              let index = scenes.firstIndex(where: { $0.id == id }),
              scenes[index].name != name
        else { return }
        guard let nextVersion = Self.incrementedSceneEntityVersion(
            scenes[index].entityVersion
        ) else {
            statusMessage = "シーンの更新世代が上限に達したため変更できません"
            return
        }
        scenes[index].name = name
        scenes[index].entityVersion = nextVersion
        markLocalSceneMutation()
    }

    func removeScene(_ scene: AppScene) {
        guard !phase.isBusy, !renameIsBusy else { return }
        guard scene.day != 0 else { return }
        let hasAssignments = sceneAssignments.values.contains(scene.id)
        guard !hasAssignments else {
            statusMessage = "割り当て済みのシーンは削除できません"
            return
        }
        var proposedScenes = scenes
        proposedScenes.removeAll { $0.id == scene.id }
        do {
            proposedScenes = try Self.renumberedScenes(proposedScenes, day: scene.day)
        } catch {
            statusMessage = userFacingMessage(for: error)
            return
        }
        scenes = proposedScenes
        if selectedSceneID == scene.id { selectedSceneID = scenes.first?.id }
        markLocalSceneMutation()
    }

    func moveScene(_ scene: AppScene, offset: Int) {
        guard !phase.isBusy,
              !renameIsBusy,
              offset != 0,
              let sourceIndex = scenes.firstIndex(where: { $0.id == scene.id })
        else { return }
        let sameDayIndices = scenes.indices.filter { scenes[$0].day == scene.day }
        guard let position = sameDayIndices.firstIndex(of: sourceIndex) else { return }
        let destinationPosition = position + offset
        guard sameDayIndices.indices.contains(destinationPosition) else { return }
        var proposedScenes = scenes
        proposedScenes.swapAt(sourceIndex, sameDayIndices[destinationPosition])
        do {
            scenes = try Self.renumberedScenes(proposedScenes, day: scene.day)
        } catch {
            statusMessage = userFacingMessage(for: error)
            return
        }
        markLocalSceneMutation()
    }

    func resolveLocalCardConfiguration() {
        let normalized = cardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let definition = projectSettings.cardDefinitions.first(where: {
                  $0.isActive && $0.cardNumber == normalized
              })
        else { return }
        selectedProjectCardID = definition.id
        let match = definition.photographerID.flatMap { photographerID in
            projectPhotographers.first { $0.id == photographerID && !$0.isArchived }
        }
        selectedProjectPhotographerID = match?.id
        photographer = match?.displayName ?? ""
        statusMessage = match == nil
            ? "このカードには撮影者が登録されていません。撮影情報から選択してください"
            : "カードNoのプロジェクト設定から撮影者を選択しました"
    }

    func applyReceivedLANSceneCatalog(expectedVersion: CatalogVersionRef) {
        guard !showCaptureConfigurationSheet, !showProjectLocationSheet,
              !phase.isBusy,
              !renameIsBusy,
              !projectOperationInFlight,
              let coordinator = lanSceneCatalog,
              let projectStore
        else { return }
        let lease: LANSceneCatalogApplicationLease
        do {
            lease = try coordinator.beginReceivedSnapshotApplication(
                expectedVersion: expectedVersion
            )
        } catch {
            statusMessage = "LANシーンを適用できません: \(userFacingMessage(for: error))"
            return
        }

        let candidate = lease.candidate
        let project: Project
        do {
            guard candidate.version.projectID == projectID.rawValue,
                  !candidate.activeScenes.isEmpty else {
                throw LANSceneCatalogCoordinatorError.projectScopeMismatch
            }
            project = try makePersistedProject(
                sceneOverride: candidate.activeScenes,
                sceneCatalogVersionOverride: candidate.version
            )
        } catch {
            try? coordinator.cancelReceivedSnapshotApplication(lease)
            statusMessage = "LANシーンを適用できません: \(userFacingMessage(for: error))"
            return
        }

        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "LAN revision \(candidate.version.revision) をatomic保存中…"
        Task { @MainActor [weak self, coordinator] in
            guard let self else {
                try? coordinator.cancelReceivedSnapshotApplication(lease)
                return
            }
            var leaseRequiresCancellation = true
            defer {
                if leaseRequiresCancellation {
                    try? coordinator.cancelReceivedSnapshotApplication(lease)
                }
                projectOperationInFlight = false
            }
            do {
                try await projectStore.save(project)
                // ProjectStore has committed the exact lease candidate. Do not
                // compare it with the mutable received revision after commit:
                // the lease excludes fetch/config/shutdown, and the UI must now
                // reflect the same candidate that is already durable on disk.
                try coordinator.completeReceivedSnapshotApplication(
                    lease,
                    applyingPersistedCandidate: { persistedCandidate in
                        scenes = persistedCandidate.activeScenes
                        // The scene observer retains the selected UUID and its current day
                        // when the shared catalog still contains it; removals clear selection.
                        sceneAssignments.removeAll()
                        invalidateVerifiedIngestIntent()
                        appliedSceneCatalogVersion = persistedCandidate.version
                    }
                )
                leaseRequiresCancellation = false
                selectedStoredProjectID = project.id.rawValue
                projectPersistenceStatus =
                    "LAN revision \(candidate.version.revision) 保存済み"
                statusMessage = "署名済みLANシーンとrevision証跡をatomic適用しました"
                refreshStoredProjects()
            } catch {
                guard projectOperationGeneration == generation else { return }
                projectPersistenceStatus = "LANシーン適用失敗（既存設定を維持）"
                statusMessage = "LANシーンを保存できません: \(userFacingMessage(for: error))"
            }
        }
    }

    func publishCurrentLANSceneCatalog() {
        guard canStartExclusiveOperation,
              !projectOperationInFlight,
              let coordinator = lanSceneCatalog,
              let projectStore,
              case .master(let configuredProjectID) = coordinator.mode,
              configuredProjectID == projectID.rawValue
        else { return }
        let frozenScenes = scenes
        // The catalog and ProjectStore cannot commit in one filesystem transaction. Stop the
        // listener before staging the next revision so no client can observe it until the project
        // witness has also been saved. Restart remains an explicit operator action after success.
        coordinator.stopServer()
        let generation = UUID()
        projectOperationGeneration = generation
        projectOperationInFlight = true
        projectPersistenceStatus = "署名snapshotを作成中…"
        Task { [weak self] in
            guard let self else { return }
            defer { projectOperationInFlight = false }
            do {
                _ = try await coordinator.publishReadOnlySnapshot(scenes: frozenScenes)
                guard let version = coordinator.publishedVersion else {
                    throw LANSceneCatalogCoordinatorError.noPublishedSnapshot
                }
                guard projectOperationGeneration == generation,
                      scenes == frozenScenes,
                      projectID.rawValue == version.projectID
                else {
                    throw LANSceneCatalogCoordinatorError.projectChanged
                }
                let project = try makePersistedProject(
                    sceneOverride: frozenScenes,
                    sceneCatalogVersionOverride: version
                )
                try await projectStore.save(project)
                guard projectOperationGeneration == generation,
                      scenes == frozenScenes,
                      coordinator.publishedVersion == version
                else {
                    throw LANSceneCatalogCoordinatorError.projectChanged
                }
                appliedSceneCatalogVersion = version
                selectedStoredProjectID = project.id.rawValue
                projectPersistenceStatus = "LAN revision \(version.revision) 署名・保存済み"
                statusMessage = "署名snapshotとrevision証跡を保存しました。確認後にサーバーを手動再開してください"
                refreshStoredProjects()
            } catch {
                // Fail closed: a staged catalog revision must not remain serviceable after the
                // corresponding Project witness failed to persist.
                coordinator.setOff()
                lanCatalogEnabled = false
                guard projectOperationGeneration == generation else { return }
                projectPersistenceStatus = "LAN公開失敗"
                statusMessage = "LANシーンの保存に失敗したため共有を停止しました: \(error.localizedDescription)"
            }
        }
    }

    func setCategoryEnabled(id: UUID, isEnabled: Bool) {
        guard canStartExclusiveOperation,
              let index = projectSettings.categories.firstIndex(where: { $0.id.rawValue == id })
        else { return }
        objectWillChange.send()
        projectSettings.categories[index].isEnabled = isEnabled
        markProjectSettingsDirty()
    }

    func setCategoryFolderName(id: UUID, folderName: String) {
        guard canStartExclusiveOperation,
              let index = projectSettings.categories.firstIndex(where: { $0.id.rawValue == id })
        else { return }
        objectWillChange.send()
        projectSettings.categories[index].folderName = folderName
        markProjectSettingsDirty()
    }

    func setIncludesHiddenFiles(_ include: Bool) {
        guard canStartExclusiveOperation else { return }
        objectWillChange.send()
        projectSettings.includeHiddenFiles = include
        markProjectSettingsDirty()
    }

    func setExcludedFolderNames(_ text: String) {
        guard canStartExclusiveOperation else { return }
        excludedFolderNamesDraft = text
        let names = text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        objectWillChange.send()
        projectSettings.excludedFolderNames = Set(names.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
        markProjectSettingsDirty()
    }

    func ejectActiveSource() {
        guard canEjectActiveSource,
              canStartExclusiveOperation,
              let identity = activeSourceIdentity,
              let store = operationStore
        else { return }
        ejectObservedDisappearance = false
        mediaAccessQuiescenceLatched = true
        previewAsset = nil
        phase = .ejectingCard
        statusMessage = "メディア処理を停止し、同一物理カードを再照合して取り出します"
        let startedAt = Date()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitForPreviewPlaybackQuiescence()
                await mediaPipeline?.suspendAndAwaitQuiescence()
                try await waitForPreviewPlaybackQuiescence()
                try await SafeEjectService(
                    registry: volumeRegistry,
                    activity: volumeActivity,
                    store: store
                ).eject(expectedIdentity: identity)
                clearSourceAfterRemoval()
                phase = .idle
                statusMessage = "\(identity.displayName)を安全に取り出しました"
                activity.insert(
                    ActivityRecord(
                        id: UUID(),
                        startedAt: startedAt,
                        title: "カード取り出し",
                        detail: identity.displayName,
                        state: .completed,
                        itemCount: 0,
                        totalBytes: identity.capacityBytes
                    ),
                    at: 0
                )
            } catch {
                if ejectObservedDisappearance {
                    clearSourceAfterRemoval()
                    phase = .idle
                    statusMessage = "カードの取り外しを検出しました"
                } else {
                    phase = .failed(userFacingMessage(for: error))
                    statusMessage = "取り出しに失敗しました。カード情報は保持しています"
                }
            }
            await mediaPipeline?.resumeRequests()
            mediaAccessQuiescenceLatched = false
            reviewThumbnailReloadGeneration = UUID()
            ejectObservedDisappearance = false
            operationTask = nil
        }
    }

    func beginVerifiedIngest() {
        guard canStartExclusiveOperation else { return }
        projectOperationGeneration = UUID()
        guard includedAssetCount > 0 else {
            phase = .failed("取り込み対象がありません")
            return
        }
        guard let destinationURL else {
            phase = .failed("保存先を選択してください")
            return
        }
        guard unassignedCount == 0 else {
            phase = .failed("未割り当て素材が\(unassignedCount)件あります")
            return
        }

        guard let scanResult = coreScanResult else {
            phase = .failed("安全な全体スキャンが完了していません。フォルダ単位で再スキャンしてください")
            return
        }
        guard let planningScanScope = activeSourceScanScope else {
            phase = .failed("元のスキャン範囲を復元できません。ソースを再スキャンしてください")
            return
        }
        guard let store = operationStore else {
            phase = .failed("操作ジャーナルを利用できません")
            return
        }

        let planningScanGeneration = scanGeneration
        let planningScanPolicy = MediaScanPolicy(projectSettings: projectSettings)
        let planningStrongIdentity = activeSourceIdentity.flatMap { identity in
            identity.identityStrength == .strongForCurrentInsertion ? identity : nil
        }
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        invalidateVerifiedIngestIntent()
        let frozenIntentGeneration = ingestIntentGeneration
        phase = .planning
        pendingEraseRunID = nil
        pendingEraseProfile = nil
        showCardEraseConfirmation = false
        cardInitializationStatus = "取り込みと検証を実行中です"
        statusMessage = "出力名・衝突・Required Setを事前検査しています"
        let cancellation = OperationCancellation()
        operationCancellation = cancellation
        let startedAt = Date()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let captureDateFrozenScan = try await captureDateFrozenScanForPlanning(
                    from: scanResult,
                    generation: planningScanGeneration,
                    assumedTimeZone: captureDateTimeZone
                )
                statusMessage = "計画確定直前に元の走査範囲を全件再検査しています"
                let frozenScan = try await freshInventoryFrozenScanForPlanning(
                    baseline: captureDateFrozenScan,
                    scope: planningScanScope,
                    generation: planningScanGeneration,
                    policy: planningScanPolicy,
                    strongSourceIdentity: planningStrongIdentity,
                    durableStore: store
                )
                let plan = try await makeIngestPlan(
                    scanResult: frozenScan,
                    destinationRoot: destinationURL
                )
                let engine = IngestEngine(
                    store: store,
                    destinationRevalidator: destinationIdentityProvider.makeRevalidationHandler()
                )
                operationCompletedItemIDs.removeAll()
                phase = .copying(completed: 0, total: plan.items.count)
                statusMessage = "一時ファイルへコピーし、項目ごとにSHA-256を検証しています"
                let receipt = try await volumeActivity.withActivity(
                    sourceVolumeID: plan.sourceVolume.id
                ) {
                    try await engine.execute(
                        plan: plan,
                        cancellation: cancellation
                    ) { [weak self] progress in
                        guard progress.completedBytes == progress.totalBytes else { return }
                        await MainActor.run {
                            guard let self else { return }
                            self.operationCompletedItemIDs.insert(progress.itemID)
                            self.phase = .copying(
                                completed: self.operationCompletedItemIDs.count,
                                total: plan.items.count
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                guard ingestIntentGeneration == frozenIntentGeneration else {
                    throw UMISCoreError.sourceChanged(
                        "取り込み中にプロジェクトまたは割り当て条件が変更されました"
                    )
                }
                latestVerifiedPlan = plan
                latestVerifiedReceipt = receipt
                latestVerifiedIntentGeneration = frozenIntentGeneration
                phase = .completed
                let unknown = plan.requiredSet.unknownEntryCount
                statusMessage = unknown == 0
                    ? "全\(receipt.deliveries.count)件のコピーと再読検証が完了しました"
                    : "コピー検証は完了しましたが、未分類\(unknown)件があるためカード初期化は禁止されています"
                cardInitializationStatus = canPrepareCardInitialization
                    ? "最終全再読検証を実行するとカード初期化を選択できます"
                    : "強い物理媒体IDまたは完全なRequired Setを満たさないため初期化できません"
                activity.insert(
                    ActivityRecord(
                        id: receipt.runID.rawValue,
                        startedAt: startedAt,
                        title: "検証付き取り込み",
                        detail: destinationURL.path,
                        state: .verified,
                        itemCount: receipt.deliveries.count,
                        totalBytes: receipt.deliveries.reduce(0) { $0 + $1.byteSize }
                    ),
                    at: 0
                )
            } catch is CancellationError {
                recordOperationCancellation(startedAt: startedAt)
            } catch let error as UMISCoreError where error == .cancelled {
                recordOperationCancellation(startedAt: startedAt)
            } catch {
                phase = .failed(userFacingMessage(for: error))
                statusMessage = "取り込みを完了できませんでした。コピー済み項目はジャーナルから再開できます"
                activity.insert(
                    ActivityRecord(
                        id: UUID(),
                        startedAt: startedAt,
                        title: "取り込み失敗",
                        detail: userFacingMessage(for: error),
                        state: .failed,
                        itemCount: 0,
                        totalBytes: 0
                    ),
                    at: 0
                )
            }
            operationCancellation = nil
            refreshOperationHistory()
            operationTask = nil
        }
    }

    func refreshMediaCacheSummary() {
        let measurementGeneration = UUID()
        mediaCacheSummaryGeneration = measurementGeneration
        guard let mediaPipeline else {
            mediaCacheSummary = "利用不可"
            return
        }
        Task { [weak self] in
            let statistics = await mediaPipeline.cacheStatistics()
            guard let self else { return }
            let memory = ByteCountFormatter.string(
                fromByteCount: Int64(statistics.memoryCostBytes),
                countStyle: .memory
            )
            let disk = ByteCountFormatter.string(
                fromByteCount: statistics.diskCostBytes,
                countStyle: .file
            )
            guard Self.acceptsMediaCacheSummary(
                measurementGeneration: measurementGeneration,
                currentGeneration: mediaCacheSummaryGeneration
            ) else { return }
            mediaCacheSummary = "メモリ \(memory) ／ ディスク \(disk)"
        }
    }

    nonisolated static func acceptsMediaCacheSummary(
        measurementGeneration: UUID,
        currentGeneration: UUID
    ) -> Bool {
        measurementGeneration == currentGeneration
    }

    func clearMediaCaches() {
        guard canClearMediaCaches, let mediaPipeline else { return }
        let expectedMediaReadIsolationGeneration = mediaReadIsolationGeneration
        // Reject a slower pre-clear usage measurement if it returns after the clear result.
        mediaCacheSummaryGeneration = UUID()
        // A cache clear cancels the in-flight preview representation. Closing the shared preview
        // prevents that expected cancellation from being presented as a media decoding error.
        previewAsset = nil
        mediaCacheOperationInFlight = true
        let startedMessage = "メディアキャッシュを消去しています（表示中のプレビューは閉じました）"
        statusMessage = startedMessage
        mediaCacheStatusMessage = startedMessage
        Task { [weak self] in
            guard let self else { return }
            defer { mediaCacheOperationInFlight = false }
            let clearFailure: String?
            do {
                try await mediaPipeline.suspendAndClearCaches()
                clearFailure = nil
            } catch {
                clearFailure = userFacingMessage(for: error)
            }
            let resumed = await resumeMediaReadsAfterCacheClearIfSafe(
                expectedIsolationGeneration: expectedMediaReadIsolationGeneration,
                pipeline: mediaPipeline
            )
            let resultMessage: String
            if let clearFailure {
                resultMessage = resumed
                    ? "キャッシュ消去に失敗: \(clearFailure)"
                    : "キャッシュ消去に失敗し、ソース状態も変化したためメディア読取を隔離したままにします: \(clearFailure)"
            } else {
                resultMessage = resumed
                    ? "メディアキャッシュを消去しました"
                    : "メディアキャッシュを消去しましたが、ソース状態が変化したため読取を隔離したままにします"
            }
            statusMessage = resultMessage
            mediaCacheStatusMessage = resultMessage
            refreshMediaCacheSummary()
            if resumed {
                // Quiescence cancels visible and prefetched work. Re-request only the viewport and
                // near-visible items through the collection update policy after the pipeline resumes.
                ingestThumbnailReloadGeneration = UUID()
                reviewThumbnailReloadGeneration = UUID()
            }
        }
    }

    private func resumeMediaReadsAfterCacheClearIfSafe(
        expectedIsolationGeneration: UUID?,
        pipeline: MediaPipeline
    ) async -> Bool {
        guard Self.permitsMediaReadResumeAfterCacheClear(
            expectedIsolationGeneration: expectedIsolationGeneration,
            currentIsolationGeneration: mediaReadIsolationGeneration,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            destructiveOutcomeQuarantined: destructiveOutcomeQuarantined
        ) else { return false }

        await pipeline.resumeRequests()
        guard Self.permitsMediaReadResumeAfterCacheClear(
            expectedIsolationGeneration: expectedIsolationGeneration,
            currentIsolationGeneration: mediaReadIsolationGeneration,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            destructiveOutcomeQuarantined: destructiveOutcomeQuarantined
        ) else {
            // A card removal or destructive-result quarantine raced the actor hop above. Fail
            // closed again; the newest isolation generation exclusively owns the next resume.
            await pipeline.suspendAndAwaitQuiescence()
            return false
        }
        return true
    }

    nonisolated static func permitsMediaReadResumeAfterCacheClear(
        expectedIsolationGeneration: UUID?,
        currentIsolationGeneration: UUID?,
        mediaAccessQuiescenceLatched: Bool,
        destructiveOutcomeQuarantined: Bool
    ) -> Bool {
        expectedIsolationGeneration == nil
            && currentIsolationGeneration == nil
            && !mediaAccessQuiescenceLatched
            && !destructiveOutcomeQuarantined
    }

    func refreshOperationHistory() {
        guard let operationStore else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                operationHistory = try await operationStore.operations(limit: 500)
                historyStatusMessage = operationHistory.isEmpty
                    ? "永続操作履歴はまだありません"
                    : "最新\(operationHistory.count)件をSQLiteジャーナルから表示"
            } catch {
                historyStatusMessage = "操作履歴の読み込みに失敗: \(userFacingMessage(for: error))"
            }
        }
    }

    func canResumeOperation(_ summary: OperationSummary) -> Bool {
        guard summary.kind == .ingest else { return false }
        return switch summary.status {
        case .planned, .running, .cancelled, .failed: true
        case .completed, .rolledBack, .recoveryRequired: false
        }
    }

    func resumeOperation(_ summary: OperationSummary) {
        guard canStartExclusiveOperation,
              canResumeOperation(summary),
              let operationStore
        else { return }
        projectOperationGeneration = UUID()
        invalidateVerifiedIngestIntent()
        let frozenIntentGeneration = ingestIntentGeneration
        let planningScanGeneration = scanGeneration
        guard let planningScanScope = activeSourceScanScope else {
            phase = .failed("元のスキャン範囲を復元できないため、ソースの再スキャンが必要です")
            return
        }
        let planningScanPolicy = MediaScanPolicy(projectSettings: projectSettings)
        let planningStrongIdentity = activeSourceIdentity.flatMap { identity in
            identity.identityStrength == .strongForCurrentInsertion ? identity : nil
        }
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        let cancellation = OperationCancellation()
        operationCancellation = cancellation
        phase = .planning
        statusMessage = "保存済みの凍結計画と既存receiptを再検証しています"
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await operationStore.loadIngestPlan(
                    runID: IngestRunID(rawValue: summary.id)
                )
                guard plan.project.id == projectID else {
                    throw UMISCoreError.invalidPlan(
                        "この履歴は現在のプロジェクトに属していません。対象プロジェクトを読み込んでください"
                    )
                }
                let currentSourceIdentity: VolumeIdentity?
                if plan.sourceVolume.identityStrength == .strongForCurrentInsertion {
                    guard let activeSourceIdentity,
                          activeSourceIdentity.securityDigest == plan.sourceVolume.securityDigest else {
                        throw UMISCoreError.identityChanged
                    }
                    currentSourceIdentity = activeSourceIdentity
                } else {
                    currentSourceIdentity = nil
                }
                let currentDestinationIdentity = try await destinationIdentityProvider
                    .revalidate(plan.destination)
                guard let currentScan = coreScanResult else {
                    throw UMISCoreError.invalidPlan(
                        "現在のカード全体スキャンと割り当てを先に復元してください"
                    )
                }
                let captureDateFrozenScan = try await captureDateFrozenScanForPlanning(
                    from: currentScan,
                    generation: planningScanGeneration,
                    assumedTimeZone: captureDateTimeZone
                )
                let frozenCurrentScan = try await freshInventoryFrozenScanForPlanning(
                    baseline: captureDateFrozenScan,
                    scope: planningScanScope,
                    generation: planningScanGeneration,
                    policy: planningScanPolicy,
                    strongSourceIdentity: planningStrongIdentity,
                    durableStore: operationStore
                )
                let currentIntentPlan = try await makeIngestPlan(
                    scanResult: frozenCurrentScan,
                    destinationRoot: currentDestinationIdentity.rootURL,
                    destinationIdentity: currentDestinationIdentity
                )
                guard try Self.ingestIntentDigest(currentIntentPlan)
                    == Self.ingestIntentDigest(plan)
                else {
                    throw UMISCoreError.invalidPlan(
                        "履歴の保存先・シーン・命名・除外条件が現在の指定と一致しません。旧計画は自動採用しません"
                    )
                }
                operationCompletedItemIDs.removeAll()
                phase = .copying(completed: 0, total: plan.items.count)
                let receipt = try await volumeActivity.withActivity(
                    sourceVolumeID: plan.sourceVolume.id
                ) {
                    try await IngestEngine(
                        store: operationStore,
                        destinationRevalidator: destinationIdentityProvider.makeRevalidationHandler()
                    ).resume(
                        runID: plan.runID,
                        currentSourceIdentity: currentSourceIdentity,
                        currentDestinationIdentity: currentDestinationIdentity,
                        cancellation: cancellation
                    ) { [weak self] progress in
                        guard progress.completedBytes == progress.totalBytes else { return }
                        await MainActor.run {
                            guard let self else { return }
                            self.operationCompletedItemIDs.insert(progress.itemID)
                            self.phase = .copying(
                                completed: self.operationCompletedItemIDs.count,
                                total: plan.items.count
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                guard ingestIntentGeneration == frozenIntentGeneration else {
                    throw UMISCoreError.sourceChanged(
                        "再開中にプロジェクトまたは割り当て条件が変更されました"
                    )
                }
                latestVerifiedPlan = plan
                latestVerifiedReceipt = receipt
                latestVerifiedIntentGeneration = frozenIntentGeneration
                phase = .completed
                statusMessage = "中断された取り込みを再検証し、\(receipt.deliveries.count)件の完了を確定しました"
                activity.insert(
                    ActivityRecord(
                        id: receipt.runID.rawValue,
                        startedAt: summary.createdAt,
                        title: "取り込み再開",
                        detail: plan.destination.rootURL.path,
                        state: .verified,
                        itemCount: receipt.deliveries.count,
                        totalBytes: receipt.deliveries.reduce(0) { $0 + $1.byteSize }
                    ),
                    at: 0
                )
            } catch is CancellationError {
                recordOperationCancellation(startedAt: summary.createdAt)
            } catch let error as UMISCoreError where error == .cancelled {
                recordOperationCancellation(startedAt: summary.createdAt)
            } catch {
                phase = .failed(userFacingMessage(for: error))
                statusMessage = "再開前検証または再開処理に失敗しました。不一致は上書きしません"
            }
            operationCancellation = nil
            refreshOperationHistory()
            operationTask = nil
        }
    }

    func exportActivityReport() {
        guard canStartExclusiveOperation,
              !activity.isEmpty || !operationHistory.isEmpty
        else { return }
        let panel = NSSavePanel()
        panel.title = "操作履歴を書き出す"
        panel.nameFieldStringValue = "RinkanUMIS-audit-\(Self.filenameDateFormatter(timeZone: .current).string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard canStartExclusiveOperation else {
            let message = "別の処理が開始されたため、操作履歴の書き出しを開始しませんでした"
            statusMessage = message
            historyStatusMessage = message
            return
        }
        let sessionActivity = activity
        guard let operationStore else { return }
        auditExportInFlight = true
        historyStatusMessage = "匿名化監査レポートを書き出しています"
        Task { [weak self] in
            guard let self else { return }
            defer { auditExportInFlight = false }
            do {
                let auditVerification = try await operationStore.verifyAuditChain()
                guard auditVerification.isTrusted else {
                    throw UMISCoreError.invalidPlan(
                        "Audit chain verification failed: \(auditVerification.status.rawValue)"
                    )
                }
                let operations = try await operationStore.operations(limit: 10_000)
                let auditEvents = try await operationStore.auditExport(
                    limit: 100_000,
                    includeSensitivePayload: false
                )
                let report = try AppAuditReport(
                    generatedAt: Date(),
                    auditChainVerification: auditVerification,
                    operations: operations,
                    auditEvents: auditEvents,
                    sessionActivity: sessionActivity
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: url, options: [.atomic])
                let message = "hash chain付き操作履歴を、payload・パス・生のエラー詳細を匿名化して書き出しました"
                statusMessage = message
                historyStatusMessage = message
            } catch {
                let message = "操作履歴の書き出しに失敗: \(userFacingMessage(for: error))"
                statusMessage = message
                historyStatusMessage = message
            }
        }
    }

    func prepareCardInitialization() {
        guard canPrepareCardInitialization,
              canStartExclusiveOperation,
              let receipt = latestVerifiedReceipt,
              let identity = activeSourceIdentity,
              let store = operationStore
        else {
            cardInitializationStatus = "初期化条件を満たしていません"
            return
        }

        let cancellation = OperationCancellation()
        operationCancellation = cancellation
        let verificationMediaIsolationGeneration = mediaReadIsolationGeneration
        mediaAccessQuiescenceLatched = true
        previewAsset = nil
        phase = .verifying(completed: 0, total: receipt.deliveries.count)
        statusMessage = "初期化許可のためコピー元と保存先を全件再読しています"
        cardInitializationStatus = "最終SHA-256再検証中。カードを抜かないでください"
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitForPreviewPlaybackQuiescence()
                await mediaPipeline?.suspendAndAwaitQuiescence()
                try await waitForPreviewPlaybackQuiescence()
                let current = try await volumeRegistry.current(sourceVolumeID: identity.id)
                let plan = try await store.loadIngestPlan(runID: receipt.runID)
                let currentDestination = try await destinationIdentityProvider.revalidate(plan.destination)
                let evidence = try await FinalVerificationService(
                    store: store,
                    activity: volumeActivity,
                    destinationRevalidator: destinationIdentityProvider.makeRevalidationHandler()
                ).verify(
                    runID: receipt.runID,
                    currentIdentity: current,
                    currentDestinationIdentity: currentDestination,
                    cancellation: cancellation
                )
                let profile = try CardFormatProfile(label: Self.defaultCardLabel(
                    cardNumber: cardNumber,
                    displayName: current.displayName
                ))
                try Task.checkCancellation()
                pendingEraseRunID = receipt.runID
                pendingEraseProfile = profile
                pendingCardDisplayName = current.displayName
                pendingCardCapacityBytes = current.capacityBytes
                pendingCardFormatLabel = profile.label
                pendingCardIdentitySummary = [
                    current.volumeUUID?.uuidString,
                    current.bsdName,
                    current.physicalMediaEvidence?.transportProtocol,
                    current.physicalMediaEvidence?.model,
                ].compactMap { $0 }.joined(separator: " / ")
                pendingFinalVerificationAt = evidence.verifiedAt
                pendingRequiredAssetCount = evidence.requiredSet.assetIDs.count
                pendingVerifiedDeliveryCount = evidence.ingestReceipt.deliveries.count
                phase = .completed
                statusMessage = "事前全再読検証が完了しました。対象を確認してください"
                cardInitializationStatus = "実行時にもう一度全件検証してから初期化します"
                showCardEraseConfirmation = true
            } catch is CancellationError {
                phase = .completed
                cardInitializationStatus = "最終検証を中止しました。初期化許可はありません"
            } catch let error as UMISCoreError where error == .cancelled {
                phase = .completed
                cardInitializationStatus = "最終検証を中止しました。初期化許可はありません"
            } catch {
                phase = .failed(userFacingMessage(for: error))
                cardInitializationStatus = "最終検証に失敗したため初期化は禁止されています"
            }
            if mediaReadIsolationGeneration == verificationMediaIsolationGeneration {
                await mediaPipeline?.resumeRequests()
                mediaAccessQuiescenceLatched = false
                reviewThumbnailReloadGeneration = UUID()
            }
            operationCancellation = nil
            operationTask = nil
        }
    }

    func cancelPendingCardInitialization() {
        showCardEraseConfirmation = false
        pendingEraseRunID = nil
        pendingEraseProfile = nil
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        cardInitializationStatus = "初期化を取り消しました。再度、最終全再読検証が必要です"
        if let eraseGate {
            Task { await eraseGate.invalidateAll() }
        }
    }

    func confirmCardInitialization() {
        guard showCardEraseConfirmation else { return }
        guard canPrepareCardInitialization,
              canStartExclusiveOperation,
              let runID = pendingEraseRunID,
              let profile = pendingEraseProfile,
              let eraseGate,
              let identity = activeSourceIdentity,
              let store = operationStore,
              let verifiedPlan = latestVerifiedPlan,
              let verifiedReceipt = latestVerifiedReceipt,
              verifiedPlan.runID == runID,
              verifiedReceipt.runID == runID,
              let confirmedDestinationURL = destinationURL,
              let expectedIntentDigest = try? Self.ingestIntentDigest(verifiedPlan)
        else {
            cancelPendingCardInitialization()
            statusMessage = "確認画面の表示後に取り込み条件が変わったため、初期化を失効しました"
            return
        }

        showCardEraseConfirmation = false
        pendingEraseRunID = nil
        pendingEraseProfile = nil
        // An erase attempt is itself a media mutation boundary. Even if the destructive backend
        // later reports an unknown outcome, the prior receipt can never authorize
        // a second attempt without a new scan, ingest and final verification.
        invalidateVerifiedIngestIntent()
        mediaAccessQuiescenceLatched = true
        previewAsset = nil
        phase = .erasingCard
        statusMessage = "同一物理カードを再照合して初期化しています"
        cardInitializationStatus = "初期化中。完了または結果不明の表示までカードを抜かないでください"
        let startedAt = Date()
        operationTask = Task { [weak self] in
            guard let self else { return }
            var mayResumeMediaReads = true
            do {
                try await waitForPreviewPlaybackQuiescence()
                await mediaPipeline?.suspendAndAwaitQuiescence()
                try await waitForPreviewPlaybackQuiescence()
                let current = try await volumeRegistry.current(sourceVolumeID: identity.id)
                let plan = try await store.loadIngestPlan(runID: runID)
                guard try Self.ingestIntentDigest(plan) == expectedIntentDigest,
                      confirmedDestinationURL.standardizedFileURL.resolvingSymlinksInPath()
                        == plan.destination.rootURL.standardizedFileURL.resolvingSymlinksInPath()
                else {
                    throw UMISCoreError.eraseNotEligible(
                        "確認済みの取り込み計画または保存先が変更されました"
                    )
                }
                let currentDestination = try await destinationIdentityProvider.revalidate(plan.destination)
                let result = try await eraseGate.eraseAfterUserConfirmation(
                    runID: runID,
                    profile: profile,
                    currentIdentity: current,
                    currentDestinationIdentity: currentDestination,
                    backend: DiskutilCardEraseBackend(registry: volumeRegistry)
                )
                switch result.outcome {
                case .completed:
                    clearSourceAfterRemoval()
                    phase = .completed
                    statusMessage = "カード初期化と書込・再読probeが完了しました"
                    cardInitializationStatus = "初期化完了（\(profile.fileSystem.rawValue) / \(profile.label)）"
                    activity.insert(
                        ActivityRecord(
                            id: UUID(),
                            startedAt: startedAt,
                            title: "カード初期化",
                            detail: "\(result.beforeIdentity.displayName) → \(profile.label)",
                            state: .completed,
                            itemCount: 0,
                            totalBytes: result.beforeIdentity.capacityBytes
                        ),
                        at: 0
                    )
                case .outcomeUnknown:
                    destructiveOutcomeQuarantined = true
                    mayResumeMediaReads = false
                    phase = .failed("diskutilがtimeoutし、初期化結果を安全に確定できません")
                    statusMessage = "全メディア操作をこの起動中は隔離しました。再実行せずDisk Utilityで状態を確認してください"
                    cardInitializationStatus = "結果不明：アプリ内の読取・取出・初期化を隔離済み"
                case .postFormatValidationFailed:
                    destructiveOutcomeQuarantined = true
                    mayResumeMediaReads = false
                    phase = .failed("初期化後の形式・同一媒体・書込probeを確認できません")
                    statusMessage = "カードを使用せず、Disk Utilityで確認してください。この起動中のメディア操作は隔離しました"
                    cardInitializationStatus = "初期化後検証失敗：読取・取出・初期化を隔離済み"
                }
            } catch {
                if await volumeActivity.isQuarantined(sourceVolumeID: identity.id) {
                    destructiveOutcomeQuarantined = true
                    mayResumeMediaReads = false
                    phase = .failed("初期化backend開始後の結果を安全に確定できません")
                    statusMessage = "物理カードの結果不明検疫が永続記録されました。読取を再開せず、Disk Utilityで状態を確認してください"
                    cardInitializationStatus = "結果不明：アプリ内の読取・取出・初期化を永続検疫済み"
                } else {
                    phase = .failed(userFacingMessage(for: error))
                    statusMessage = "カード初期化は完了していません。自動再試行しません"
                    cardInitializationStatus = "初期化前検査または中止。再検証なしの再試行は禁止です"
                }
            }
            if mayResumeMediaReads {
                await mediaPipeline?.resumeRequests()
                mediaAccessQuiescenceLatched = false
                reviewThumbnailReloadGeneration = UUID()
            }
            operationTask = nil
        }
    }

    private func scan(url: URL) {
        guard !ingestScanAdmissionMustWait else { return }
        scanTask?.cancel()
        invalidateCaptureDateEnrichment()
        let generation = UUID()
        let effectiveRoot: URL
        let resolvedSourceVolumeID: SourceVolumeID
        let strongSourceIdentity: VolumeIdentity?
        if let identity = cardVolumeMonitor?.identity(containing: url),
           let mountURL = identity.mountURL {
            // An erase-eligible card scan must inventory the complete mounted volume.
            // Scanning a selected subfolder would leave unobserved source data behind.
            effectiveRoot = mountURL.standardizedFileURL.resolvingSymlinksInPath()
            sourceURL = effectiveRoot
            // Do not expose a strong card identity until the durable destructive-outcome
            // quarantine has been checked. The activity overload below performs that check
            // before the first directory entry or media byte is read.
            activeSourceIdentity = nil
            inFlightStrongScanIdentity = identity
            inFlightStrongScanGeneration = generation
            activeSourceVolumeID = identity.id
            activeSourceRootPath = effectiveRoot.path
            resolvedSourceVolumeID = identity.id
            strongSourceIdentity = identity
        } else {
            effectiveRoot = url.standardizedFileURL.resolvingSymlinksInPath()
            sourceURL = effectiveRoot
            activeSourceIdentity = nil
            inFlightStrongScanIdentity = nil
            inFlightStrongScanGeneration = nil
            resolvedSourceVolumeID = sourceVolumeID(for: effectiveRoot)
            strongSourceIdentity = nil
        }
        scanGeneration = generation
        activeSourceScanScope = .normalizedRoot(effectiveRoot)
        assets = []
        selectedAssetIDs.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        sceneAssignments.removeAll()
        scanErrors = []
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        showCardEraseConfirmation = false
        phase = .scanning
        statusMessage = "素材をスキャンしています"
        let scanPolicy = MediaScanPolicy(projectSettings: projectSettings)
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        let scanMediaPipeline = mediaPipeline
        let scanOperationStore = operationStore
        let requiredMediaReadIsolationGeneration = mediaReadIsolationGeneration
        let requiredMediaReadIsolationTask = mediaReadIsolationTask
        let taskID = UUID()
        cancellingIngestScanGeneration = nil
        activeIngestScanTaskIDs.insert(taskID)
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanGeneration == generation {
                    scanTask = nil
                    if cancellingIngestScanGeneration == generation {
                        cancellingIngestScanGeneration = nil
                        if mediaReadIsolationFailed {
                            // Preserve the stronger restart-required message from the isolation task.
                            phase = .failed("メディア読取停止を確認できません")
                        } else if mediaAccessQuiescenceLatched,
                                  mediaReadIsolationGeneration != nil,
                                  mediaReadIsolationTask != nil {
                            phase = assets.isEmpty ? .idle : .ready
                            statusMessage = "スキャンを安全に中止しました。メディア読取は隔離中です。再スキャンまたはカード再挿入が必要です"
                        } else {
                            phase = assets.isEmpty ? .idle : .ready
                            statusMessage = "スキャンを安全に中止しました"
                        }
                    }
                }
                activeIngestScanTaskIDs.remove(taskID)
            }
            do {
                try await awaitMediaReadIsolationBeforeFreshScan(
                    generation: requiredMediaReadIsolationGeneration,
                    task: requiredMediaReadIsolationTask
                )
                let operation: @Sendable () async throws -> ScanResult = {
                    try await MediaScanner().scan(
                        root: effectiveRoot,
                        sourceVolumeID: resolvedSourceVolumeID,
                        policy: scanPolicy
                    )
                }
                let result: ScanResult
                if let strongSourceIdentity {
                    guard let scanOperationStore else {
                        throw UMISCoreError.eraseNotEligible(
                            "Durable operation storage is required before reading a physical card"
                        )
                    }
                    result = try await volumeActivity.withActivity(
                        identity: strongSourceIdentity,
                        durableStore: scanOperationStore,
                        operation: operation
                    )
                } else {
                    result = try await volumeActivity.withActivity(
                        sourceVolumeID: resolvedSourceVolumeID,
                        operation: operation
                    )
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                try await resumeMediaReadsAfterFreshScanIfNeeded(
                    scan: result,
                    expectedSourceVolumeID: resolvedSourceVolumeID,
                    scanGeneration: generation,
                    isolationGeneration: requiredMediaReadIsolationGeneration,
                    expectedStrongIdentity: strongSourceIdentity,
                    scanScope: .normalizedRoot(effectiveRoot)
                )
                guard !Task.isCancelled, scanGeneration == generation else { return }
                if let strongSourceIdentity {
                    try await requireCurrentStrongScanIdentityOrIsolate(
                        strongSourceIdentity,
                        scan: result,
                        scope: .normalizedRoot(effectiveRoot),
                        expectedScanGeneration: generation
                    )
                    try Task.checkCancellation()
                    guard scanGeneration == generation else { return }
                    let current = strongSourceIdentity.mountURL.flatMap {
                        cardVolumeMonitor?.identity(containing: $0)
                    }
                    guard Self.permitsStrongScanPublication(
                        expected: strongSourceIdentity,
                        inFlight: inFlightStrongScanIdentity,
                        current: current,
                        scan: result,
                        scope: .normalizedRoot(effectiveRoot),
                        expectedScanGeneration: generation,
                        inFlightScanGeneration: inFlightStrongScanGeneration,
                        currentScanGeneration: scanGeneration
                    ) else {
                        guard await isolateMediaAfterStrongScanIdentityFailure(
                            expected: strongSourceIdentity,
                            expectedScanGeneration: generation
                        ) else { throw CancellationError() }
                        throw UMISCoreError.identityChanged
                    }
                }
                coreScanResult = result
                if let strongSourceIdentity {
                    activeSourceIdentity = strongSourceIdentity
                    inFlightStrongScanIdentity = nil
                    inFlightStrongScanGeneration = nil
                    activeSourceVolumeID = strongSourceIdentity.id
                    activeSourceRootPath = effectiveRoot.path
                } else if activeSourceIdentity?.id != result.sourceVolumeID
                    || activeSourceIdentity?.identityStrength != .strongForCurrentInsertion {
                    activeSourceIdentity = Self.weakSourceIdentity(for: result)
                }
                assets = result.assets.map(AppAsset.init(coreAsset:))
                policyReviewAssetIDs = Self.policyReviewIDs(in: result)
                scanErrors = result.issues.map { "\($0.relativePath): \($0.message)" }
                let unknownCount = result.inventory.filter { $0.classification == .unknown }.count
                if unknownCount > 0 {
                    scanErrors.append("未分類のファイルまたは項目が\(unknownCount)件あります。確認するまでカード初期化できません")
                }
                adoptDirectoryReviewState(from: result)
                phase = Self.phaseAfterBasicInventory(result)
                if result.assets.isEmpty {
                    captureDateEnrichmentGeneration = generation
                    captureDateEnrichmentTimeZoneIdentifier = captureDateTimeZone.identifier
                    statusMessage = "対応素材が見つかりませんでした"
                } else {
                    statusMessage = "\(result.assets.count)件の基本インベントリを表示しました。撮影日時をバックグラウンドで解析中です"
                    startProgressiveCaptureDateEnrichment(
                        scan: result,
                        generation: generation,
                        assumedTimeZone: captureDateTimeZone,
                        mediaPipeline: scanMediaPipeline,
                        strongSourceIdentity: strongSourceIdentity,
                        durableStore: scanOperationStore,
                        completedStatus: "\(result.assets.count)件の撮影日時解析が完了しました"
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard scanGeneration == generation, !Task.isCancelled else { return }
                coreScanResult = nil
                activeSourceScanScope = nil
                if Self.preservesRestartRequiredIsolationFailure(
                    requiredIsolationGeneration: requiredMediaReadIsolationGeneration,
                    currentIsolationGeneration: mediaReadIsolationGeneration,
                    mediaReadIsolationFailed: mediaReadIsolationFailed
                ) {
                    phase = .failed("メディア読取停止を確認できません")
                    return
                }
                phase = .failed(userFacingMessage(for: error))
                statusMessage = "素材フォルダを安全に走査できませんでした"
            }
        }
    }

    private func scan(items: [URL]) {
        if items.count == 1,
           (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            scan(url: items[0])
            return
        }
        guard !phase.isBusy, !ingestScanAdmissionMustWait else { return }
        let itemScope = AppSourceScanScope.normalizedItems(items)
        guard case let .items(scopedItems) = itemScope, !scopedItems.isEmpty else { return }
        let cardIdentities = scopedItems.compactMap { cardVolumeMonitor?.identity(containing: $0) }
        let droppedStrongIdentity: VolumeIdentity?
        if let first = cardIdentities.first {
            guard cardIdentities.count == items.count,
                  cardIdentities.allSatisfy({ $0.securityDigest == first.securityDigest })
            else {
                phase = .failed("複数の物理媒体または通常フォルダとカードを混在させたドロップは安全に処理できません")
                statusMessage = "カード素材は同一カード内だけを選択するか、カード全体を選択してください"
                return
            }
            droppedStrongIdentity = first
        } else {
            droppedStrongIdentity = nil
        }
        scanTask?.cancel()
        invalidateCaptureDateEnrichment()
        let generation = UUID()
        scanGeneration = generation
        activeSourceScanScope = itemScope
        activeSourceIdentity = nil
        inFlightStrongScanIdentity = droppedStrongIdentity
        inFlightStrongScanGeneration = droppedStrongIdentity == nil ? nil : generation
        activeSourceVolumeID = droppedStrongIdentity?.id
        activeSourceRootPath = nil
        assets = []
        selectedAssetIDs.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        sceneAssignments.removeAll()
        scanErrors = []
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        showCardEraseConfirmation = false
        phase = .scanning
        statusMessage = "ドロップされた素材をスキャンしています"
        coreScanResult = nil
        let droppedVolumeID = droppedStrongIdentity?.id ?? SourceVolumeID()
        let scanPolicy = MediaScanPolicy(projectSettings: projectSettings)
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        let scanMediaPipeline = mediaPipeline
        let scanOperationStore = operationStore
        let requiredMediaReadIsolationGeneration = mediaReadIsolationGeneration
        let requiredMediaReadIsolationTask = mediaReadIsolationTask
        let taskID = UUID()
        cancellingIngestScanGeneration = nil
        activeIngestScanTaskIDs.insert(taskID)
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanGeneration == generation {
                    scanTask = nil
                    if cancellingIngestScanGeneration == generation {
                        cancellingIngestScanGeneration = nil
                        if mediaReadIsolationFailed {
                            // Preserve the stronger restart-required message from the isolation task.
                            phase = .failed("メディア読取停止を確認できません")
                        } else if mediaAccessQuiescenceLatched,
                                  mediaReadIsolationGeneration != nil,
                                  mediaReadIsolationTask != nil {
                            phase = assets.isEmpty ? .idle : .ready
                            statusMessage = "スキャンを安全に中止しました。メディア読取は隔離中です。再スキャンまたはカード再挿入が必要です"
                        } else {
                            phase = assets.isEmpty ? .idle : .ready
                            statusMessage = "スキャンを安全に中止しました"
                        }
                    }
                }
                activeIngestScanTaskIDs.remove(taskID)
            }
            do {
                try await awaitMediaReadIsolationBeforeFreshScan(
                    generation: requiredMediaReadIsolationGeneration,
                    task: requiredMediaReadIsolationTask
                )
                let operation: @Sendable () async throws -> ScanResult = {
                    try await MediaScanner().scan(
                        items: scopedItems,
                        sourceVolumeID: droppedVolumeID,
                        policy: scanPolicy
                    )
                }
                let snapshot: ScanResult
                if let droppedStrongIdentity {
                    guard let scanOperationStore else {
                        throw UMISCoreError.eraseNotEligible(
                            "Durable operation storage is required before reading a physical card"
                        )
                    }
                    snapshot = try await volumeActivity.withActivity(
                        identity: droppedStrongIdentity,
                        durableStore: scanOperationStore,
                        operation: operation
                    )
                } else {
                    snapshot = try await volumeActivity.withActivity(
                        sourceVolumeID: droppedVolumeID,
                        operation: operation
                    )
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                try await resumeMediaReadsAfterFreshScanIfNeeded(
                    scan: snapshot,
                    expectedSourceVolumeID: droppedVolumeID,
                    scanGeneration: generation,
                    isolationGeneration: requiredMediaReadIsolationGeneration,
                    expectedStrongIdentity: droppedStrongIdentity,
                    scanScope: itemScope
                )
                guard !Task.isCancelled, scanGeneration == generation else { return }
                if let droppedStrongIdentity {
                    try await requireCurrentStrongScanIdentityOrIsolate(
                        droppedStrongIdentity,
                        scan: snapshot,
                        scope: itemScope,
                        expectedScanGeneration: generation
                    )
                    try Task.checkCancellation()
                    guard scanGeneration == generation else { return }
                    let current = droppedStrongIdentity.mountURL.flatMap {
                        cardVolumeMonitor?.identity(containing: $0)
                    }
                    guard Self.permitsStrongScanPublication(
                        expected: droppedStrongIdentity,
                        inFlight: inFlightStrongScanIdentity,
                        current: current,
                        scan: snapshot,
                        scope: itemScope,
                        expectedScanGeneration: generation,
                        inFlightScanGeneration: inFlightStrongScanGeneration,
                        currentScanGeneration: scanGeneration
                    ) else {
                        guard await isolateMediaAfterStrongScanIdentityFailure(
                            expected: droppedStrongIdentity,
                            expectedScanGeneration: generation
                        ) else { throw CancellationError() }
                        throw UMISCoreError.identityChanged
                    }
                }
                sourceURL = snapshot.root
                coreScanResult = snapshot
                activeSourceVolumeID = droppedVolumeID
                activeSourceRootPath = snapshot.root.standardizedFileURL.path
                activeSourceIdentity = Self.sourceIdentityAfterItemsScan(
                    strongIdentity: droppedStrongIdentity,
                    scan: snapshot
                )
                inFlightStrongScanIdentity = nil
                inFlightStrongScanGeneration = nil
                assets = snapshot.assets.map(AppAsset.init(coreAsset:))
                policyReviewAssetIDs = Self.policyReviewIDs(in: snapshot)
                scanErrors = snapshot.issues.map { "\($0.relativePath): \($0.message)" }
                let unknownCount = snapshot.inventory.filter { $0.classification == .unknown }.count
                if unknownCount > 0 {
                    scanErrors.append("未分類の項目が\(unknownCount)件あります（ドロップ選択はカード初期化対象外です）")
                }
                adoptDirectoryReviewState(from: snapshot)
                phase = Self.phaseAfterBasicInventory(snapshot)
                if snapshot.assets.isEmpty {
                    captureDateEnrichmentGeneration = generation
                    captureDateEnrichmentTimeZoneIdentifier = captureDateTimeZone.identifier
                    statusMessage = "対応素材が見つかりませんでした"
                } else {
                    statusMessage = "ドロップされた\(snapshot.assets.count)件の基本インベントリを表示しました。撮影日時をバックグラウンドで解析中です"
                    startProgressiveCaptureDateEnrichment(
                        scan: snapshot,
                        generation: generation,
                        assumedTimeZone: captureDateTimeZone,
                        mediaPipeline: scanMediaPipeline,
                        strongSourceIdentity: droppedStrongIdentity,
                        durableStore: scanOperationStore,
                        completedStatus: "ドロップされた\(snapshot.assets.count)件の撮影日時解析が完了しました（カード初期化対象外）"
                    )
                }
            } catch {
                guard scanGeneration == generation, !Task.isCancelled else { return }
                coreScanResult = nil
                activeSourceScanScope = nil
                activeSourceIdentity = nil
                activeSourceVolumeID = nil
                activeSourceRootPath = nil
                assets = []
                scanErrors = [userFacingMessage(for: error)]
                if Self.preservesRestartRequiredIsolationFailure(
                    requiredIsolationGeneration: requiredMediaReadIsolationGeneration,
                    currentIsolationGeneration: mediaReadIsolationGeneration,
                    mediaReadIsolationFailed: mediaReadIsolationFailed
                ) {
                    phase = .failed("メディア読取停止を確認できません")
                    return
                }
                phase = .failed(userFacingMessage(for: error))
            }
        }
    }

    nonisolated static func preservesRestartRequiredIsolationFailure(
        requiredIsolationGeneration: UUID?,
        currentIsolationGeneration: UUID?,
        mediaReadIsolationFailed: Bool
    ) -> Bool {
        mediaReadIsolationFailed
            && requiredIsolationGeneration != nil
            && requiredIsolationGeneration == currentIsolationGeneration
    }

    private func awaitMediaReadIsolationBeforeFreshScan(
        generation: UUID?,
        task: Task<Bool, Never>?
    ) async throws {
        guard let generation else {
            guard !mediaAccessQuiescenceLatched else {
                throw UMISCoreError.eraseNotEligible(
                    "旧カードのメディア読取検疫を確認できないため、新しいスキャンを開始できません"
                )
            }
            return
        }
        guard mediaAccessQuiescenceLatched,
              mediaReadIsolationGeneration == generation,
              let task,
              await task.value
        else {
            throw UMISCoreError.eraseNotEligible(
                "旧カードの再生・メディア読取停止を確定できないため、再スキャンを中止しました"
            )
        }
        try Task.checkCancellation()
        guard mediaReadIsolationGeneration == generation,
              mediaAccessQuiescenceLatched
        else {
            throw UMISCoreError.sourceChanged("メディア読取検疫世代が変更されました")
        }
    }

    private func resumeMediaReadsAfterFreshScanIfNeeded(
        scan: ScanResult,
        expectedSourceVolumeID: SourceVolumeID,
        scanGeneration: UUID,
        isolationGeneration: UUID?,
        expectedStrongIdentity: VolumeIdentity?,
        scanScope: AppSourceScanScope
    ) async throws {
        if let expectedStrongIdentity {
            try await requireCurrentStrongScanIdentityOrIsolate(
                expectedStrongIdentity,
                scan: scan,
                scope: scanScope,
                expectedScanGeneration: scanGeneration
            )
        }
        guard let isolationGeneration else { return }
        guard Self.permitsMediaReadResumeAfterFreshScan(
            scan: scan,
            expectedSourceVolumeID: expectedSourceVolumeID,
            scanGeneration: scanGeneration,
            currentScanGeneration: self.scanGeneration,
            isolationGeneration: isolationGeneration,
            currentIsolationGeneration: mediaReadIsolationGeneration
        ), mediaAccessQuiescenceLatched
        else {
            throw UMISCoreError.sourceChanged("新しいソースのフルスキャン世代が一致しません")
        }
        await mediaPipeline?.resumeRequests()
        if let expectedStrongIdentity {
            do {
                try await revalidateCurrentStrongScanIdentity(
                    expectedStrongIdentity,
                    scan: scan,
                    scope: scanScope,
                    expectedScanGeneration: scanGeneration
                )
            } catch is CancellationError {
                let suspensionToken = await mediaPipeline?.suspendAndAwaitQuiescence()
                await restoreMediaReadsAfterObsoleteStrongScanSuspensionIfSafe(
                    token: suspensionToken,
                    obsoleteScanGeneration: scanGeneration,
                    pipeline: mediaPipeline
                )
                throw CancellationError()
            } catch {
                // The current card can disappear while the pipeline actor is resuming. Return
                // to a quiescent state before starting a fresh isolation generation.
                let suspensionToken = await mediaPipeline?.suspendAndAwaitQuiescence()
                guard await isolateMediaAfterStrongScanIdentityFailure(
                    expected: expectedStrongIdentity,
                    expectedScanGeneration: scanGeneration
                ) else {
                    await restoreMediaReadsAfterObsoleteStrongScanSuspensionIfSafe(
                        token: suspensionToken,
                        obsoleteScanGeneration: scanGeneration,
                        pipeline: mediaPipeline
                    )
                    throw CancellationError()
                }
                throw error
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // Cancellation after the actor hop must not leave a formerly isolated pipeline live.
            let suspensionToken = await mediaPipeline?.suspendAndAwaitQuiescence()
            await restoreMediaReadsAfterObsoleteStrongScanSuspensionIfSafe(
                token: suspensionToken,
                obsoleteScanGeneration: scanGeneration,
                pipeline: mediaPipeline
            )
            throw error
        }
        guard Self.permitsMediaReadResumeAfterFreshScan(
            scan: scan,
            expectedSourceVolumeID: expectedSourceVolumeID,
            scanGeneration: scanGeneration,
            currentScanGeneration: self.scanGeneration,
            isolationGeneration: isolationGeneration,
            currentIsolationGeneration: mediaReadIsolationGeneration
        ), mediaAccessQuiescenceLatched
        else {
            // A removal or rescan raced the resume await. Return the pipeline to a
            // fail-closed state; the newest isolation generation owns the next resume.
            let suspensionToken = await mediaPipeline?.suspendAndAwaitQuiescence()
            await restoreMediaReadsAfterObsoleteStrongScanSuspensionIfSafe(
                token: suspensionToken,
                obsoleteScanGeneration: scanGeneration,
                pipeline: mediaPipeline
            )
            throw UMISCoreError.sourceChanged("メディア読取再開中にソース世代が変更されました")
        }
        mediaAccessQuiescenceLatched = false
        reviewThumbnailReloadGeneration = UUID()
        mediaReadIsolationGeneration = nil
        mediaReadIsolationTask = nil
        mediaReadIsolationFailed = false
    }

    private func restoreMediaReadsAfterObsoleteStrongScanSuspensionIfSafe(
        token: MediaPipelineSuspensionToken?,
        obsoleteScanGeneration: UUID,
        pipeline: MediaPipeline?
    ) async {
        guard let token, let pipeline,
              Self.permitsObsoleteStrongScanSuspensionRollback(
                obsoleteScanGeneration: obsoleteScanGeneration,
                currentScanGeneration: scanGeneration,
                hasMediaReadIsolationGeneration: mediaReadIsolationGeneration != nil,
                hasMediaReadIsolationTask: mediaReadIsolationTask != nil,
                mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
                destructiveOutcomeQuarantined: destructiveOutcomeQuarantined,
                mediaCacheOperationInFlight: mediaCacheOperationInFlight,
                reviewMetadataIsWriting: reviewMetadataIsWriting
              )
        else { return }

        guard await pipeline.resumeRequests(ifCurrentSuspension: token) else { return }
        guard Self.permitsObsoleteStrongScanSuspensionRollback(
            obsoleteScanGeneration: obsoleteScanGeneration,
            currentScanGeneration: scanGeneration,
            hasMediaReadIsolationGeneration: mediaReadIsolationGeneration != nil,
            hasMediaReadIsolationTask: mediaReadIsolationTask != nil,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            destructiveOutcomeQuarantined: destructiveOutcomeQuarantined,
            mediaCacheOperationInFlight: mediaCacheOperationInFlight,
            reviewMetadataIsWriting: reviewMetadataIsWriting
        ) else {
            await pipeline.suspendAndAwaitQuiescence()
            return
        }
        ingestThumbnailReloadGeneration = UUID()
        reviewThumbnailReloadGeneration = UUID()
    }

    nonisolated static func permitsObsoleteStrongScanSuspensionRollback(
        obsoleteScanGeneration: UUID,
        currentScanGeneration: UUID,
        hasMediaReadIsolationGeneration: Bool,
        hasMediaReadIsolationTask: Bool,
        mediaAccessQuiescenceLatched: Bool,
        destructiveOutcomeQuarantined: Bool,
        mediaCacheOperationInFlight: Bool,
        reviewMetadataIsWriting: Bool
    ) -> Bool {
        obsoleteScanGeneration != currentScanGeneration
            && !hasMediaReadIsolationGeneration
            && !hasMediaReadIsolationTask
            && !mediaAccessQuiescenceLatched
            && !destructiveOutcomeQuarantined
            && !mediaCacheOperationInFlight
            && !reviewMetadataIsWriting
    }

    private func requireCurrentStrongScanIdentityOrIsolate(
        _ expected: VolumeIdentity,
        scan: ScanResult,
        scope: AppSourceScanScope,
        expectedScanGeneration: UUID
    ) async throws {
        do {
            try await revalidateCurrentStrongScanIdentity(
                expected,
                scan: scan,
                scope: scope,
                expectedScanGeneration: expectedScanGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard await isolateMediaAfterStrongScanIdentityFailure(
                expected: expected,
                expectedScanGeneration: expectedScanGeneration
            ) else { throw CancellationError() }
            throw error
        }
    }

    /// Revalidates both current Disk Arbitration state and the actor registry. The monitor check
    /// catches the narrow window before the asynchronous disappearance callback reaches MainActor;
    /// the registry check independently rejects a stale or replaced insertion session.
    private func revalidateCurrentStrongScanIdentity(
        _ expected: VolumeIdentity,
        scan: ScanResult,
        scope: AppSourceScanScope,
        expectedScanGeneration: UUID
    ) async throws {
        guard let mountURL = expected.mountURL else { throw UMISCoreError.identityChanged }
        let monitorBeforeRegistry = cardVolumeMonitor?.identity(containing: mountURL)
        guard Self.permitsStrongScanPublication(
            expected: expected,
            inFlight: inFlightStrongScanIdentity,
            current: monitorBeforeRegistry,
            scan: scan,
            scope: scope,
            expectedScanGeneration: expectedScanGeneration,
            inFlightScanGeneration: inFlightStrongScanGeneration,
            currentScanGeneration: scanGeneration
        ) else { throw UMISCoreError.identityChanged }

        let registered = try await volumeRegistry.current(sourceVolumeID: expected.id)
        guard Self.permitsStrongScanPublication(
            expected: expected,
            inFlight: inFlightStrongScanIdentity,
            current: registered,
            scan: scan,
            scope: scope,
            expectedScanGeneration: expectedScanGeneration,
            inFlightScanGeneration: inFlightStrongScanGeneration,
            currentScanGeneration: scanGeneration
        ) else { throw UMISCoreError.identityChanged }

        let monitorAfterRegistry = cardVolumeMonitor?.identity(containing: mountURL)
        guard Self.permitsStrongScanPublication(
            expected: expected,
            inFlight: inFlightStrongScanIdentity,
            current: monitorAfterRegistry,
            scan: scan,
            scope: scope,
            expectedScanGeneration: expectedScanGeneration,
            inFlightScanGeneration: inFlightStrongScanGeneration,
            currentScanGeneration: scanGeneration
        ) else { throw UMISCoreError.identityChanged }
    }

    /// Converts any ambiguity after a physical-card scan into a new read isolation generation.
    /// This helper also invalidates every destructive capability derived from the unpublished scan.
    private func isolateMediaAfterStrongScanIdentityFailure(
        expected: VolumeIdentity,
        expectedScanGeneration: UUID
    ) async -> Bool {
        guard Self.ownsInFlightStrongScan(
            expected: expected,
            expectedScanGeneration: expectedScanGeneration,
            inFlight: inFlightStrongScanIdentity,
            inFlightScanGeneration: inFlightStrongScanGeneration,
            currentScanGeneration: scanGeneration
        ) else { return false }

        let failedSourceID = expected.id
        let failureStateGeneration = UUID()
        mediaAccessQuiescenceLatched = true
        previewAsset = nil
        scanGeneration = failureStateGeneration
        scanTask?.cancel()
        scanTask = nil
        invalidateCaptureDateEnrichment()
        assets = []
        selectedAssetIDs.removeAll()
        sceneAssignments.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        scanErrors = []
        coreScanResult = nil
        activeSourceScanScope = nil
        activeSourceIdentity = nil
        inFlightStrongScanIdentity = nil
        inFlightStrongScanGeneration = nil
        activeSourceVolumeID = nil
        activeSourceRootPath = nil
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        operationTask?.cancel()
        if let operationCancellation { Task { await operationCancellation.cancel() } }
        if let eraseGate { Task { await eraseGate.invalidateAll() } }
        cardAppearanceRegistrationGenerations.removeValue(forKey: failedSourceID)

        // Replace any old isolation generation before the first await. A newly appearing card
        // can then wait on this exact generation, but it can never reuse the completed old one.
        beginUnexpectedRemovalMediaIsolation()
        let replacementIsolationGeneration = mediaReadIsolationGeneration
        let replacementIsolationTask = mediaReadIsolationTask

        // Suspend immediately in case the identity changed during `resumeRequests()`.
        await mediaPipeline?.suspendAndAwaitQuiescence()
        let isolationSucceeded = if let replacementIsolationTask {
            await replacementIsolationTask.value
        } else {
            false
        }
        if !isolationSucceeded {
            guard Self.ownsStrongScanIsolationFailureState(
                failureStateGeneration: failureStateGeneration,
                currentScanGeneration: scanGeneration,
                replacementIsolationGeneration: replacementIsolationGeneration,
                currentIsolationGeneration: mediaReadIsolationGeneration,
                mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched
            ) else { return true }
            // Preserve the isolation task's more actionable restart-required status; only close
            // the stale `.scanning` phase that belonged to this failed generation.
            phase = .failed("メディア読取停止を確認できません")
            return true
        }
        guard Self.commitsStrongScanIsolationFailure(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: scanGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: mediaReadIsolationGeneration,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched,
            isolationSucceeded: isolationSucceeded
        ) else { return true }
        phase = .failed("カードの挿入IDがスキャン中に変化しました")
        statusMessage = "カードを再挿入し、フルスキャンと取り込み検証をやり直してください"
        cardInitializationStatus = "スキャン中の媒体変更を検出したため初期化許可を失効しました"
        return true
    }

    nonisolated static func ownsInFlightStrongScan(
        expected: VolumeIdentity,
        expectedScanGeneration: UUID,
        inFlight: VolumeIdentity?,
        inFlightScanGeneration: UUID?,
        currentScanGeneration: UUID
    ) -> Bool {
        guard let inFlight else { return false }
        return inFlight.id == expected.id
            && inFlight.arrivalGeneration == expected.arrivalGeneration
            && inFlight.securityDigest == expected.securityDigest
            && inFlightScanGeneration == expectedScanGeneration
            && currentScanGeneration == expectedScanGeneration
    }

    nonisolated static func commitsStrongScanIsolationFailure(
        failureStateGeneration: UUID,
        currentScanGeneration: UUID,
        replacementIsolationGeneration: UUID?,
        currentIsolationGeneration: UUID?,
        mediaAccessQuiescenceLatched: Bool,
        isolationSucceeded: Bool
    ) -> Bool {
        ownsStrongScanIsolationFailureState(
            failureStateGeneration: failureStateGeneration,
            currentScanGeneration: currentScanGeneration,
            replacementIsolationGeneration: replacementIsolationGeneration,
            currentIsolationGeneration: currentIsolationGeneration,
            mediaAccessQuiescenceLatched: mediaAccessQuiescenceLatched
        ) && isolationSucceeded
    }

    nonisolated static func ownsStrongScanIsolationFailureState(
        failureStateGeneration: UUID,
        currentScanGeneration: UUID,
        replacementIsolationGeneration: UUID?,
        currentIsolationGeneration: UUID?,
        mediaAccessQuiescenceLatched: Bool
    ) -> Bool {
        failureStateGeneration == currentScanGeneration
            && replacementIsolationGeneration != nil
            && replacementIsolationGeneration == currentIsolationGeneration
            && mediaAccessQuiescenceLatched
    }

    nonisolated static func cardDisappearanceMatches(
        sourceID: SourceVolumeID,
        arrivalGeneration: UUID,
        active: VolumeIdentity?,
        inFlight: VolumeIdentity?
    ) -> Bool {
        [active, inFlight].compactMap { $0 }.contains {
            $0.id == sourceID && $0.arrivalGeneration == arrivalGeneration
        }
    }

    nonisolated static func permitsStrongScanPublication(
        expected: VolumeIdentity,
        inFlight: VolumeIdentity?,
        current: VolumeIdentity?,
        scan: ScanResult,
        scope: AppSourceScanScope,
        expectedScanGeneration: UUID,
        inFlightScanGeneration: UUID?,
        currentScanGeneration: UUID
    ) -> Bool {
        guard expected.identityStrength == .strongForCurrentInsertion,
              let expectedMountURL = expected.mountURL,
              let current,
              ownsInFlightStrongScan(
                expected: expected,
                expectedScanGeneration: expectedScanGeneration,
                inFlight: inFlight,
                inFlightScanGeneration: inFlightScanGeneration,
                currentScanGeneration: currentScanGeneration
              ),
              current.identityStrength == .strongForCurrentInsertion,
              current.id == expected.id,
              current.arrivalGeneration == expected.arrivalGeneration,
              current.securityDigest == expected.securityDigest,
              scan.sourceVolumeID == expected.id
        else { return false }

        let expectedMountPath = expectedMountURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard current.mountURL?.standardizedFileURL.resolvingSymlinksInPath().path
                == expectedMountPath
        else { return false }

        switch scope {
        case let .root(root):
            return root.standardizedFileURL.resolvingSymlinksInPath().path == expectedMountPath
                && scan.root.standardizedFileURL.resolvingSymlinksInPath().path == expectedMountPath
        case let .items(items):
            return !items.isEmpty
                && items.allSatisfy { isURL($0, containedBy: expectedMountURL) }
                && isURL(scan.root, containedBy: expectedMountURL)
        }
    }

    nonisolated static func permitsMediaReadResumeAfterFreshScan(
        scan: ScanResult,
        expectedSourceVolumeID: SourceVolumeID,
        scanGeneration: UUID,
        currentScanGeneration: UUID,
        isolationGeneration: UUID,
        currentIsolationGeneration: UUID?
    ) -> Bool {
        scan.sourceVolumeID == expectedSourceVolumeID
            && scanGeneration == currentScanGeneration
            && isolationGeneration == currentIsolationGeneration
    }

    /// Publishes the scanner's stable-ID inventory immediately, then performs bounded
    /// native metadata extraction without keeping the workspace in `.scanning`.
    /// Planning may await this exact task, but it never trusts its result without one
    /// final source-fingerprint pass at the plan-freeze boundary.
    private func startProgressiveCaptureDateEnrichment(
        scan: ScanResult,
        generation: UUID,
        assumedTimeZone: TimeZone,
        mediaPipeline: MediaPipeline?,
        strongSourceIdentity: VolumeIdentity?,
        durableStore: OperationStore?,
        completedStatus: String
    ) {
        invalidateCaptureDateEnrichment()
        let attempt = UUID()
        let timeZoneIdentifier = assumedTimeZone.identifier
        captureDateEnrichmentAttempt = attempt
        captureDateEnrichmentTaskGeneration = generation
        captureDateEnrichmentTaskTimeZoneIdentifier = timeZoneIdentifier
        captureDateMetadataIsLoading = true
        captureDateEnrichmentTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let enriched = try await captureDatesWithVolumeActivity(
                    in: scan,
                    mediaPipeline: mediaPipeline,
                    assumedTimeZone: assumedTimeZone,
                    strongSourceIdentity: strongSourceIdentity,
                    durableStore: durableStore
                )
                try Task.checkCancellation()
                guard Self.acceptsLateCaptureDateEnrichment(
                    baseline: scan,
                    taskGeneration: generation,
                    currentGeneration: scanGeneration,
                    taskAttempt: attempt,
                    currentAttempt: captureDateEnrichmentAttempt,
                    currentScan: coreScanResult
                )
                else { return nil }
                coreScanResult = enriched
                assets = enriched.assets.map(AppAsset.init(coreAsset:))
                captureDateEnrichmentGeneration = generation
                captureDateEnrichmentTimeZoneIdentifier = timeZoneIdentifier
                captureDateMetadataIsLoading = false
                captureDateEnrichmentTask = nil
                captureDateEnrichmentTaskGeneration = nil
                captureDateEnrichmentTaskTimeZoneIdentifier = nil
                if phase == .ready, operationTask == nil {
                    statusMessage = completedStatus
                }
                return enriched
            } catch is CancellationError {
                guard captureDateEnrichmentAttempt == attempt else { return nil }
                captureDateMetadataIsLoading = false
                captureDateEnrichmentTask = nil
                captureDateEnrichmentTaskGeneration = nil
                captureDateEnrichmentTaskTimeZoneIdentifier = nil
                if phase == .ready, operationTask == nil {
                    statusMessage = "撮影日時のバックグラウンド解析を中断しました。取り込み開始時に再確定します"
                }
                return nil
            } catch {
                guard scanGeneration == generation,
                      captureDateEnrichmentAttempt == attempt
                else { return nil }
                captureDateMetadataIsLoading = false
                captureDateEnrichmentTask = nil
                captureDateEnrichmentTaskGeneration = nil
                captureDateEnrichmentTaskTimeZoneIdentifier = nil
                captureDateEnrichmentGeneration = nil
                captureDateEnrichmentTimeZoneIdentifier = nil
                // If no foreground operation has claimed this result, fail closed: a
                // fingerprint or quarantine error means the progressive inventory can
                // remain visible for diagnosis but cannot become an ingest plan.
                if phase == .ready, operationTask == nil {
                    coreScanResult = nil
                    let message = userFacingMessage(for: error)
                    scanErrors.append("撮影日時確定中にソース整合性エラー: \(message)")
                    phase = .failed(message)
                    statusMessage = "基本一覧は保持していますが、取り込み前に再スキャンが必要です"
                }
                return nil
            }
        }
    }

    /// Returns one capture-date-complete snapshot for an ingest-plan boundary.
    /// A completed progressive result is reused after revalidating every asset. If
    /// it is absent, cancelled, or tied to another timezone, extraction is rerun
    /// under the same volume activity/quarantine controls before planning continues.
    private func captureDateFrozenScanForPlanning(
        from scanned: ScanResult,
        generation: UUID,
        assumedTimeZone: TimeZone
    ) async throws -> ScanResult {
        let timeZoneIdentifier = assumedTimeZone.identifier
        guard scanGeneration == generation,
              let currentScan = coreScanResult,
              Self.representsSameInventory(currentScan, scanned)
        else {
            throw UMISCoreError.sourceChanged("計画作成前にスキャン対象が変更されました")
        }

        if captureDateEnrichmentTaskGeneration == generation,
           captureDateEnrichmentTaskTimeZoneIdentifier == timeZoneIdentifier,
           let pendingTask = captureDateEnrichmentTask {
            _ = await pendingTask.value
            try Task.checkCancellation()
        }

        guard scanGeneration == generation else {
            throw UMISCoreError.sourceChanged("計画作成前に再スキャンまたはカード抜去が発生しました")
        }
        if captureDateEnrichmentGeneration == generation,
           captureDateEnrichmentTimeZoneIdentifier == timeZoneIdentifier,
           let enriched = coreScanResult,
           Self.representsSameInventory(enriched, scanned) {
            try await Self.validateSourceFingerprints(in: enriched)
            try Task.checkCancellation()
            guard scanGeneration == generation else {
                throw UMISCoreError.sourceChanged("計画確定中にスキャン世代が変更されました")
            }
            return enriched
        }

        let obsoleteTask = captureDateEnrichmentTask
        invalidateCaptureDateEnrichment()
        if let obsoleteTask {
            _ = await obsoleteTask.value
            try Task.checkCancellation()
        }
        guard scanGeneration == generation else {
            throw UMISCoreError.sourceChanged("撮影日時確定中にスキャン世代が変更されました")
        }

        let strongIdentity = activeSourceIdentity.flatMap { identity in
            identity.id == scanned.sourceVolumeID
                && identity.identityStrength == .strongForCurrentInsertion ? identity : nil
        }
        let enriched = try await captureDatesWithVolumeActivity(
            in: scanned,
            mediaPipeline: mediaPipeline,
            assumedTimeZone: assumedTimeZone,
            strongSourceIdentity: strongIdentity,
            durableStore: operationStore
        )
        // The enrichment pass verifies before and after native extraction. This last
        // pass closes the await-to-plan gap before filenames and plan items are frozen.
        try await Self.validateSourceFingerprints(in: enriched)
        try Task.checkCancellation()
        guard scanGeneration == generation,
              let latestScan = coreScanResult,
              Self.representsSameInventory(latestScan, scanned)
        else {
            throw UMISCoreError.sourceChanged("撮影日時確定中にソースが変更されました")
        }
        coreScanResult = enriched
        assets = enriched.assets.map(AppAsset.init(coreAsset:))
        captureDateEnrichmentGeneration = generation
        captureDateEnrichmentTimeZoneIdentifier = timeZoneIdentifier
        return enriched
    }

    private func captureDatesWithVolumeActivity(
        in scan: ScanResult,
        mediaPipeline: MediaPipeline?,
        assumedTimeZone: TimeZone,
        strongSourceIdentity: VolumeIdentity?,
        durableStore: OperationStore?
    ) async throws -> ScanResult {
        let operation: @Sendable () async throws -> ScanResult = {
            try await Self.enrichingCaptureDates(
                in: scan,
                mediaPipeline: mediaPipeline,
                assumedTimeZone: assumedTimeZone
            )
        }
        if let strongSourceIdentity {
            guard let durableStore else {
                throw UMISCoreError.eraseNotEligible(
                    "Durable operation storage is required before reading a physical card"
                )
            }
            return try await volumeActivity.withActivity(
                identity: strongSourceIdentity,
                durableStore: durableStore,
                operation: operation
            )
        }
        return try await volumeActivity.withActivity(
            sourceVolumeID: scan.sourceVolumeID,
            operation: operation
        )
    }

    /// Repeats the complete original scan scope immediately before an ingest plan is frozen.
    /// This catches additions that per-asset fingerprint checks cannot see (new sidecars, unknown
    /// files, and empty directories). Finder item scans intentionally repeat only the exact item
    /// set; they never expand to the common ancestor directory.
    private func freshInventoryFrozenScanForPlanning(
        baseline: ScanResult,
        scope: AppSourceScanScope,
        generation: UUID,
        policy: MediaScanPolicy,
        strongSourceIdentity: VolumeIdentity?,
        durableStore: OperationStore?
    ) async throws -> ScanResult {
        guard scanGeneration == generation,
              activeSourceScanScope == scope,
              let currentScan = coreScanResult,
              Self.representsSameInventory(currentScan, baseline)
        else {
            throw UMISCoreError.sourceChanged("計画直前の再走査前にソース範囲が変更されました")
        }
        if let strongSourceIdentity {
            guard strongSourceIdentity.id == baseline.sourceVolumeID,
                  strongSourceIdentity.identityStrength == .strongForCurrentInsertion,
                  let durableStore else {
                throw UMISCoreError.eraseNotEligible(
                    "物理カードの再走査に必要な強いidentityと永続ジャーナルがありません"
                )
            }
            let operation: @Sendable () async throws -> ScanResult = {
                try await Self.scanInventory(
                    scope: scope,
                    sourceVolumeID: baseline.sourceVolumeID,
                    policy: policy
                )
            }
            let fresh = try await volumeActivity.withActivity(
                identity: strongSourceIdentity,
                durableStore: durableStore,
                operation: operation
            )
            return try finishFreshInventoryPlanFreeze(
                baseline: baseline,
                fresh: fresh,
                scope: scope,
                generation: generation
            )
        }

        let operation: @Sendable () async throws -> ScanResult = {
            try await Self.scanInventory(
                scope: scope,
                sourceVolumeID: baseline.sourceVolumeID,
                policy: policy
            )
        }
        let fresh = try await volumeActivity.withActivity(
            sourceVolumeID: baseline.sourceVolumeID,
            operation: operation
        )
        return try finishFreshInventoryPlanFreeze(
            baseline: baseline,
            fresh: fresh,
            scope: scope,
            generation: generation
        )
    }

    private func finishFreshInventoryPlanFreeze(
        baseline: ScanResult,
        fresh: ScanResult,
        scope: AppSourceScanScope,
        generation: UUID
    ) throws -> ScanResult {
        try Task.checkCancellation()
        guard scanGeneration == generation,
              activeSourceScanScope == scope,
              Self.isExactPlanFreezeInventoryMatch(baseline: baseline, fresh: fresh)
        else {
            throw UMISCoreError.sourceChanged(
                "計画直前の全件再走査で、新規ファイル・空フォルダ・未分類項目または素材変更を検出しました"
            )
        }
        // Native capture dates belong to `baseline`; the fresh scanner intentionally reads only
        // inventory metadata. Exact equality apart from capturedAt proves they describe one source.
        return baseline
    }

    nonisolated static func scanInventory(
        scope: AppSourceScanScope,
        sourceVolumeID: SourceVolumeID,
        policy: MediaScanPolicy
    ) async throws -> ScanResult {
        switch scope {
        case let .root(root):
            try await MediaScanner().scan(
                root: root,
                sourceVolumeID: sourceVolumeID,
                policy: policy
            )
        case let .items(items):
            try await MediaScanner().scan(
                items: items,
                sourceVolumeID: sourceVolumeID,
                policy: policy
            )
        }
    }

    nonisolated static func isExactPlanFreezeInventoryMatch(
        baseline: ScanResult,
        fresh: ScanResult
    ) -> Bool {
        baseline.sourceVolumeID == fresh.sourceVolumeID
            && baseline.root.standardizedFileURL.path == fresh.root.standardizedFileURL.path
            && baseline.inventoryDigest == fresh.inventoryDigest
            && baseline.inventory == fresh.inventory
            && baseline.issues == fresh.issues
            && assetsMatchIgnoringCaptureDate(baseline.assets, fresh.assets)
    }

    private nonisolated static func assetsMatchIgnoringCaptureDate(
        _ baseline: [MediaAsset],
        _ fresh: [MediaAsset]
    ) -> Bool {
        guard baseline.count == fresh.count else { return false }
        return zip(baseline, fresh).allSatisfy { left, right in
            var left = left
            var right = right
            left.capturedAt = nil
            right.capturedAt = nil
            return left == right
        }
    }

    private func invalidateCaptureDateEnrichment() {
        captureDateEnrichmentAttempt = UUID()
        captureDateEnrichmentTask?.cancel()
        captureDateEnrichmentTask = nil
        captureDateEnrichmentTaskGeneration = nil
        captureDateEnrichmentTaskTimeZoneIdentifier = nil
        captureDateEnrichmentGeneration = nil
        captureDateEnrichmentTimeZoneIdentifier = nil
        captureDateMetadataIsLoading = false
    }

    nonisolated static func phaseAfterBasicInventory(_ scan: ScanResult) -> WorkspacePhase {
        scan.assets.isEmpty ? .idle : .ready
    }

    nonisolated static func acceptsLateCaptureDateEnrichment(
        baseline: ScanResult,
        taskGeneration: UUID,
        currentGeneration: UUID,
        taskAttempt: UUID,
        currentAttempt: UUID,
        currentScan: ScanResult?
    ) -> Bool {
        guard taskGeneration == currentGeneration,
              taskAttempt == currentAttempt,
              let currentScan
        else { return false }
        return representsSameInventory(currentScan, baseline)
    }

    nonisolated static func permitsCaptureDatePlanFreeze(
        completedGeneration: UUID?,
        completedTimeZoneIdentifier: String?,
        currentGeneration: UUID,
        expectedTimeZoneIdentifier: String,
        currentScan: ScanResult?,
        proposedScan: ScanResult
    ) -> Bool {
        completedGeneration == currentGeneration
            && completedTimeZoneIdentifier == expectedTimeZoneIdentifier
            && currentScan == proposedScan
    }

    nonisolated static func representsSameInventory(
        _ lhs: ScanResult,
        _ rhs: ScanResult
    ) -> Bool {
        lhs.sourceVolumeID == rhs.sourceVolumeID
            && lhs.root.standardizedFileURL.path == rhs.root.standardizedFileURL.path
            && lhs.inventoryDigest == rhs.inventoryDigest
            && lhs.assets.map(\.id) == rhs.assets.map(\.id)
            && lhs.assets.map(\.fingerprint) == rhs.assets.map(\.fingerprint)
    }

    /// UI mutations expand only true companion groups. Equal-stem primaries without a sidecar
    /// remain independent (for example, separately recorded MOV and WAV files).
    nonisolated static func expandedCompanionAssetIDs(
        _ selectedIDs: Set<UUID>,
        assets: [MediaAsset]
    ) -> Set<UUID> {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id.rawValue, $0) })
        var membersByKey: [String: [MediaAsset]] = [:]
        for asset in assets {
            guard let key = MediaCompanionGrouping.groupKey(for: asset) else { continue }
            membersByKey[key, default: []].append(asset)
        }
        var expanded: Set<UUID> = []
        for selectedID in selectedIDs {
            guard let selected = assetsByID[selectedID] else { continue }
            guard let key = MediaCompanionGrouping.groupKey(for: selected),
                  let members = membersByKey[key],
                  members.contains(where: { $0.kind == .sidecar }) else {
                expanded.insert(selectedID)
                continue
            }
            expanded.formUnion(members.map { $0.id.rawValue })
        }
        return expanded
    }

    /// Produces one deterministic logical sequence per primary/companion group. The returned order
    /// matches the scanner order so filenames are stable across UI selection order changes.
    nonisolated static func companionPlanningLayout(
        assets: [MediaAsset],
        sceneAssignments: [UUID: UUID]
    ) throws -> [CompanionPlanningPlacement] {
        let companionLayout = try MediaCompanionGrouping.layout(for: assets)
        let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var sequenceByLogicalGroup: [String: Int] = [:]
        var nextSequence = 1
        func reserveSequence() throws -> Int {
            let sequence = nextSequence
            let (following, overflow) = nextSequence.addingReportingOverflow(1)
            guard !overflow else {
                throw UMISCoreError.invalidPlan("取り込み連番が表現上限を超えました")
            }
            nextSequence = following
            return sequence
        }

        return try companionLayout.map { layout in
            guard let asset = assetByID[layout.assetID],
                  assetByID[layout.primaryAssetID] != nil,
                  let primarySceneID = sceneAssignments[layout.primaryAssetID.rawValue],
                  sceneAssignments[asset.id.rawValue] == primarySceneID else {
                throw UMISCoreError.invalidPlan(
                    "primaryと付随ファイルのシーン割り当てが一致していません"
                )
            }
            let sequence: Int
            if let existing = sequenceByLogicalGroup[layout.logicalOutputGroupKey] {
                sequence = existing
            } else {
                sequence = try reserveSequence()
                sequenceByLogicalGroup[layout.logicalOutputGroupKey] = sequence
            }
            return CompanionPlanningPlacement(
                assetID: layout.assetID,
                primaryAssetID: layout.primaryAssetID,
                sceneID: primarySceneID,
                sequence: sequence
            )
        }
    }

    nonisolated static func validateSourceFingerprints(in scan: ScanResult) async throws {
        for asset in scan.assets {
            try Task.checkCancellation()
            guard try FileFingerprint.capture(at: asset.canonicalURL) == asset.fingerprint else {
                throw UMISCoreError.sourceChanged(asset.canonicalURL.path)
            }
        }
    }

    /// Freezes native capture dates into the same `MediaAsset` values later used by
    /// rename requests and ingest plans. Offsetless camera wall clocks use one time
    /// zone snapshot for the complete scan; only unavailable metadata falls back to
    /// the scanner's modification date. Every asset is fingerprinted both before and
    /// after metadata extraction, including the no-pipeline fallback path.
    nonisolated static func enrichingCaptureDates(
        in scan: ScanResult,
        mediaPipeline: MediaPipeline?,
        assumedTimeZone: TimeZone
    ) async throws -> ScanResult {
        var enriched = scan
        guard !enriched.assets.isEmpty else { return enriched }

        for asset in enriched.assets {
            try Task.checkCancellation()
            guard try FileFingerprint.capture(at: asset.canonicalURL) == asset.fingerprint else {
                throw UMISCoreError.sourceChanged(asset.canonicalURL.path)
            }
        }

        if let mediaPipeline {
            let metadataResults = await mediaPipeline.metadataBatch(
                for: enriched.assets.map(\.canonicalURL),
                priority: .background,
                assumedTimeZone: assumedTimeZone
            )
            try Task.checkCancellation()
            guard metadataResults.count == enriched.assets.count else {
                throw UMISCoreError.invalidPlan("Metadata result count does not match the frozen scan")
            }

            for index in enriched.assets.indices {
                var asset = enriched.assets[index]
                switch metadataResults[index] {
                case let .success(metadata):
                    asset.capturedAt = metadata.captureDate ?? asset.capturedAt ?? asset.modifiedAt
                case let .failure(failure):
                    if failure.code == .sourceChanged {
                        throw UMISCoreError.sourceChanged(asset.canonicalURL.path)
                    }
                    if failure.code == .cancelled {
                        // Coordinator cancellation can be initiated by cache clear, review
                        // mutation, card isolation, or another pipeline owner without cancelling
                        // this parent Task. It is never evidence that metadata was unavailable;
                        // treating it as mtime fallback could freeze incorrect filenames/sequence.
                        throw CancellationError()
                    }
                    asset.capturedAt = asset.capturedAt ?? asset.modifiedAt
                }
                enriched.assets[index] = asset
            }
        } else {
            enriched.assets = enriched.assets.map { asset in
                var asset = asset
                asset.capturedAt = asset.capturedAt ?? asset.modifiedAt
                return asset
            }
        }

        for asset in enriched.assets {
            try Task.checkCancellation()
            guard try FileFingerprint.capture(at: asset.canonicalURL) == asset.fingerprint else {
                throw UMISCoreError.sourceChanged(asset.canonicalURL.path)
            }
        }
        return enriched
    }

    private func sourceVolumeID(for root: URL) -> SourceVolumeID {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let identity = cardVolumeMonitor?.identity(containing: root) {
            activeSourceIdentity = identity
            activeSourceRootPath = path
            activeSourceVolumeID = identity.id
            return identity.id
        }
        if activeSourceRootPath != path || activeSourceVolumeID == nil {
            activeSourceRootPath = path
            activeSourceVolumeID = SourceVolumeID()
        }
        return activeSourceVolumeID ?? SourceVolumeID()
    }

    private func makeIngestPlan(
        scanResult: ScanResult,
        destinationRoot: URL,
        destinationIdentity: DestinationIdentity? = nil
    ) async throws -> IngestPlan {
        let captureDateTimeZone = Self.renameTimeZone(for: projectSettings.renameRule)
        guard Self.permitsCaptureDatePlanFreeze(
            completedGeneration: captureDateEnrichmentGeneration,
            completedTimeZoneIdentifier: captureDateEnrichmentTimeZoneIdentifier,
            currentGeneration: scanGeneration,
            expectedTimeZoneIdentifier: captureDateTimeZone.identifier,
            currentScan: coreScanResult,
            proposedScan: scanResult
        )
        else {
            throw UMISCoreError.invalidPlan(
                "全素材の撮影日時とソースfingerprintを確定する前に取り込み計画は作成できません"
            )
        }
        let destination: DestinationIdentity
        if let destinationIdentity {
            guard destinationIdentity.rootURL.standardizedFileURL.resolvingSymlinksInPath()
                == destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
            else {
                throw UMISCoreError.invalidPlan("保存先identityと現在の保存先フォルダが一致しません")
            }
            destination = try await destinationIdentityProvider.revalidate(destinationIdentity)
        } else {
            destination = try await destinationIdentityProvider.resolve(rootURL: destinationRoot)
        }
        let excludedCoreIDs = Set(explicitlyExcludedAssetIDs.map(MediaAssetID.init(rawValue:)))
        let exclusionEvidence = explicitlyExcludedAssetIDs.compactMap {
            explicitExclusionEvidenceByAssetID[$0]
        }
        let directoryEvidence = currentEmptyDirectoryExclusionEvidence
        let includedCoreIDs = Set(scanResult.assets.map(\.id)).subtracting(excludedCoreIDs)
        let requiredSet = try scanResult.validatedRequiredSet(
            selectedAssetIDs: includedCoreIDs,
            destinationID: destination.id,
            explicitlyExcludedAssetIDs: excludedCoreIDs,
            explicitExclusions: exclusionEvidence,
            explicitDirectoryExclusions: directoryEvidence,
            exclusionsReviewed: true
        )
        var project = try makePersistedProject()
        project.name = try PathSafety.validateComponent(project.name)
        project.destination = destinationRoot
        let sourceIdentity = activeSourceIdentity ?? Self.weakSourceIdentity(for: scanResult)
        if sourceIdentity.identityStrength == .strongForCurrentInsertion,
           let firstSourceDevice = scanResult.assets.first?.fingerprint.device,
           let destinationDevice = try? FileFingerprint.capture(at: destinationRoot).device,
           firstSourceDevice == destinationDevice {
            throw UMISCoreError.invalidPlan(
                "コピー元カードと同一ファイルシステムを保存先にできません。初期化時にコピーも消失するためです"
            )
        }
        let coreAssets = Dictionary(uniqueKeysWithValues: scanResult.assets.map { ($0.id.rawValue, $0) })
        let appScenes = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let includedAssets = scanResult.assets.filter { includedCoreIDs.contains($0.id) }
        let companionLayout = try Self.companionPlanningLayout(
            assets: includedAssets,
            sceneAssignments: sceneAssignments
        )
        let placementByAssetID = Dictionary(
            uniqueKeysWithValues: companionLayout.map { ($0.assetID.rawValue, $0) }
        )
        let items: [IngestPlanItem] = try includedAssets.map { asset in
            guard let placement = placementByAssetID[asset.id.rawValue],
                  let primary = coreAssets[placement.primaryAssetID.rawValue],
                  let appScene = appScenes[placement.sceneID]
            else {
                throw UMISCoreError.invalidPlan(
                    "素材の安定ID、primaryまたはシーン割り当てが見つかりません"
                )
            }
            let scene = Scene(
                id: SceneID(rawValue: appScene.id),
                projectID: projectID,
                displayName: appScene.name,
                code: Self.sceneCode(appScene),
                day: appScene.day == 0 ? nil : appScene.day,
                sortOrder: appScene.number,
                entityVersion: appScene.entityVersion
            )
            let categoryFolder = try PathSafety.validateComponent(categoryFolder(for: primary))
            let sceneFolder = try PathSafety.validateComponent(Self.sceneFolder(appScene))
            let outputStem = try makeIngestStem(
                asset: primary,
                scene: appScene,
                sequence: placement.sequence
            )
            let filename = try makeIngestFilename(
                stem: outputStem,
                pathExtension: asset.pathExtension
            )
            let finalURL = destinationRoot
                .appendingPathComponent(categoryFolder, isDirectory: true)
                .appendingPathComponent(sceneFolder, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
            return IngestPlanItem(
                asset: asset,
                scene: scene,
                sourceURL: asset.canonicalURL,
                finalURL: finalURL,
                expectedSourceFingerprint: asset.fingerprint,
                duplicatePolicy: .verifyIdentical
            )
        }
        let plan = IngestPlan(
            project: project,
            sourceVolume: sourceIdentity,
            destination: destination,
            requiredSet: requiredSet,
            scanPolicy: MediaScanPolicy(projectSettings: projectSettings),
            items: items
        )
        try plan.validate()
        return plan
    }

    private static func ingestIntentDigest(_ plan: IngestPlan) throws -> String {
        let normalizedItems = plan.items.sorted {
            $0.asset.id.rawValue.uuidString < $1.asset.id.rawValue.uuidString
        }.map { item in
            IngestPlanItem(
                id: IngestItemID(rawValue: item.asset.id.rawValue),
                asset: item.asset,
                scene: item.scene,
                sourceURL: item.sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
                finalURL: item.finalURL.standardizedFileURL.resolvingSymlinksInPath(),
                expectedSourceFingerprint: item.expectedSourceFingerprint,
                expectedContentSHA256: item.expectedContentSHA256,
                duplicatePolicy: item.duplicatePolicy
            )
        }
        return try StableDigest.encode(IngestPlanIntentMaterial(
            project: plan.project,
            sourceVolume: plan.sourceVolume,
            destination: plan.destination,
            requiredSet: plan.requiredSet,
            scanPolicy: plan.scanPolicy,
            items: normalizedItems
        ))
    }

    private func makeIngestStem(asset: MediaAsset, scene: AppScene, sequence: Int) throws -> String {
        let date = asset.capturedAt ?? asset.modifiedAt ?? Date()
        let originalStem = asset.canonicalURL.deletingPathExtension().lastPathComponent
        let rule = projectSettings.renameRule
        let renameTimeZone = Self.renameTimeZone(for: rule)
        let components = try rule.tokens.compactMap { token -> String? in
            let value: String
            switch token {
            case let .literal(literal): value = literal
            case .location: value = locationName
            case .sceneCode: value = Self.sceneCode(scene)
            case .sceneName: value = scene.name
            case .photographer: value = photographer
            case .cardNumber: value = cardNumber
            case .capturedDate: value = Self.filenameDateFormatter(timeZone: renameTimeZone)
                .string(from: date)
            case .sequence: value = String(format: "%0*d", rule.sequenceWidth, sequence)
            case .originalStem: value = originalStem
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try PathSafety.validateComponent(trimmed)
        }
        guard !components.isEmpty else { throw UMISCoreError.invalidPlan("出力ファイル名が空です") }
        let separator = try PathSafety.validateComponent(rule.separator)
        return try PathSafety.validateComponent(components.joined(separator: separator))
    }

    private func makeIngestFilename(stem: String, pathExtension: String) throws -> String {
        let stem = try PathSafety.validateComponent(stem)
        guard !pathExtension.isEmpty else { return stem }
        let pathExtension = try PathSafety.validateComponent(pathExtension)
        return try PathSafety.validateComponent("\(stem).\(pathExtension)")
    }

    private func categoryFolder(for asset: MediaAsset) -> String {
        if let categoryID = asset.categoryID,
           let category = projectSettings.categories.first(where: { $0.id == categoryID }) {
            return category.folderName
        }
        if let category = projectSettings.categories
            .filter(\.isEnabled)
            .sorted(by: { $0.sortOrder < $1.sortOrder })
            .first(where: { $0.mediaKind == asset.kind }) {
            return category.folderName
        }
        return Self.categoryFolder(asset.kind)
    }

    private func recordOperationCancellation(startedAt: Date) {
        phase = assets.isEmpty ? .idle : .ready
        statusMessage = "取り込みを中止しました。完了済み項目とpartialは再開用に保持されています"
        activity.insert(
            ActivityRecord(
                id: UUID(),
                startedAt: startedAt,
                title: "取り込み中止",
                detail: "中止状態と処理済み項目をジャーナルへ記録",
                state: .cancelled,
                itemCount: 0,
                totalBytes: 0
            ),
            at: 0
        )
    }

    private func userFacingMessage(for error: Error) -> String {
        if let coreError = error as? UMISCoreError {
            switch coreError {
            case .collision:
                return "保存先に内容未確認の同名ファイルがあります。上書きは行いません"
            case .hashMismatch:
                return "コピー元と保存先のSHA-256が一致しません"
            case .sourceChanged:
                return "走査後にコピー元が変更されました。再スキャンしてください"
            case .symbolicLinkRejected:
                return "安全のためシンボリックリンクは取り込みません"
            case .cancelled:
                return "操作を中止しました"
            default:
                return coreError.description
            }
        }
        return error.localizedDescription
    }

    nonisolated static func sourceIdentityAfterItemsScan(
        strongIdentity: VolumeIdentity?,
        scan: ScanResult
    ) -> VolumeIdentity {
        if let strongIdentity,
           strongIdentity.id == scan.sourceVolumeID,
           strongIdentity.identityStrength == .strongForCurrentInsertion {
            return strongIdentity
        }
        return weakSourceIdentity(for: scan)
    }

    nonisolated static func scanScopeCoversCompleteCard(
        _ scope: AppSourceScanScope?,
        identity: VolumeIdentity
    ) -> Bool {
        guard identity.identityStrength == .strongForCurrentInsertion,
              let mountURL = identity.mountURL,
              case let .root(scannedRoot) = scope else { return false }
        return scannedRoot.standardizedFileURL.resolvingSymlinksInPath()
            == mountURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private nonisolated static func weakSourceIdentity(for scan: ScanResult) -> VolumeIdentity {
        VolumeIdentity(
            id: scan.sourceVolumeID,
            mountURL: scan.root,
            displayName: scan.root.lastPathComponent,
            capacityBytes: 0,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            isWritable: false,
            isNetwork: false,
            isDiskImage: false,
            identityStrength: .weak
        )
    }

    nonisolated static func destructiveRuntimeFeatureEnabled(
        _ environmentValue: String?,
        boundaryAvailable: Bool
    ) -> Bool {
        boundaryAvailable && environmentValue == "1"
    }

    private static func categoryFolder(_ kind: UMISCore.MediaKind) -> String {
        switch kind {
        case .movie: "動画"
        case .photo: "写真"
        case .rawPhoto: "RAW"
        case .audio: "音声"
        case .sidecar: "付随ファイル"
        case .other: "その他"
        }
    }

    private static func policyReviewIDs(in scan: ScanResult) -> Set<UUID> {
        Set(scan.inventory.compactMap { entry -> UUID? in
            switch entry.classification {
            case .disabledByPolicyNeedsReview, .excludedFolderNeedsReview, .hiddenEntryNeedsReview:
                entry.mediaAssetID?.rawValue
            default:
                nil
            }
        })
    }

    private static func sceneCode(_ scene: AppScene) -> String {
        scene.code
    }

    private static func sceneFolder(_ scene: AppScene) -> String {
        scene.day == 0 ? scene.name : "\(sceneCode(scene))_\(scene.name)"
    }

    private static func renameTimeZone(for rule: RenameRule) -> TimeZone {
        guard let identifier = rule.timeZoneIdentifier else { return .current }
        // ProjectStore and RenamePlanner reject invalid explicit identifiers. Keep this helper
        // total for a new unsaved project while preserving the frozen project policy.
        return TimeZone(identifier: identifier) ?? .current
    }

    private static func filenameDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }

    private func handleCardVolumeEvent(_ event: CardVolumeMonitorEvent) {
        switch event {
        case .inventoryChanged:
            scheduleAutomaticCardSelection()
        case let .appeared(identity):
            if phase == .erasingCard || phase == .ejectingCard { return }
            guard let store = operationStore else {
                rejectUnregisteredCardIfSelected(
                    identity,
                    message: "永続操作ジャーナルが無いためカードを安全に受け入れられません"
                )
                return
            }
            let registrationGeneration = UUID()
            cardAppearanceRegistrationGenerations[identity.id] = registrationGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await volumeActivity.registerAppearance(
                        identity: identity,
                        durableStore: store
                    )
                    try Task.checkCancellation()
                    guard cardAppearanceRegistrationGenerations[identity.id] == registrationGeneration,
                          let mountURL = identity.mountURL,
                          cardVolumeMonitor?.identity(containing: mountURL)?
                          .securityDigest == identity.securityDigest
                    else { return }
                    cardAppearanceRegistrationGenerations.removeValue(forKey: identity.id)
                    registeredCardCandidates[identity.id] = identity
                    rejectedAutomaticCardIDs.remove(identity.id)
                    updateConnectedCardCandidates()
                    acceptRegisteredCardAppearance(identity)
                    scheduleAutomaticCardSelection()
                } catch is CancellationError {
                    if cardAppearanceRegistrationGenerations[identity.id] == registrationGeneration {
                        cardAppearanceRegistrationGenerations.removeValue(forKey: identity.id)
                    }
                    scheduleAutomaticCardSelection()
                } catch {
                    guard cardAppearanceRegistrationGenerations[identity.id] == registrationGeneration else { return }
                    cardAppearanceRegistrationGenerations.removeValue(forKey: identity.id)
                    registeredCardCandidates.removeValue(forKey: identity.id)
                    rejectedAutomaticCardIDs.insert(identity.id)
                    updateConnectedCardCandidates()
                    rejectUnregisteredCardIfSelected(
                        identity,
                        message: "未解決の初期化結果または物理カード照合エラーのため、このカードは隔離されました: \(userFacingMessage(for: error))"
                    )
                    scheduleAutomaticCardSelection()
                }
            }

        case let .disappeared(sourceID, arrivalGeneration):
            cardAppearanceRegistrationGenerations.removeValue(forKey: sourceID)
            rejectedAutomaticCardIDs.remove(sourceID)
            if registeredCardCandidates[sourceID]?.arrivalGeneration == arrivalGeneration {
                registeredCardCandidates.removeValue(forKey: sourceID)
                updateConnectedCardCandidates()
            }
            let removedAutomaticSource = automaticallySelectedCard == CardInsertionIdentity(
                sourceID: sourceID, arrivalGeneration: arrivalGeneration
            )
            if removedAutomaticSource { automaticallySelectedCard = nil }
            scheduleAutomaticCardSelection()
            deferredCardScanGeneration = nil
            guard Self.cardDisappearanceMatches(
                sourceID: sourceID,
                arrivalGeneration: arrivalGeneration,
                active: activeSourceIdentity,
                inFlight: inFlightStrongScanIdentity
            ) else { return }
            if phase == .erasingCard {
                statusMessage = "初期化に伴う一時的なアンマウントを検出しました"
                return
            }
            if phase == .ejectingCard {
                ejectObservedDisappearance = true
                return
            }
            mediaAccessQuiescenceLatched = true
            previewAsset = nil
            scanGeneration = UUID()
            scanTask?.cancel()
            scanTask = nil
            invalidateCaptureDateEnrichment()
            assets = []
            selectedAssetIDs.removeAll()
            sceneAssignments.removeAll()
            policyReviewAssetIDs.removeAll()
            explicitlyExcludedAssetIDs.removeAll()
            explicitExclusionEvidenceByAssetID.removeAll()
            pendingExclusionAssetIDs.removeAll()
            showAssetExclusionConfirmation = false
            resetEmptyDirectoryReviewState()
            scanErrors = []
            coreScanResult = nil
            activeSourceScanScope = nil
            beginUnexpectedRemovalMediaIsolation()
            activeSourceIdentity = nil
            inFlightStrongScanIdentity = nil
            inFlightStrongScanGeneration = nil
            activeSourceVolumeID = nil
            activeSourceRootPath = nil
            invalidateVerifiedIngestIntent()
            pendingCardIdentitySummary = ""
            pendingFinalVerificationAt = nil
            pendingRequiredAssetCount = 0
            pendingVerifiedDeliveryCount = 0
            operationTask?.cancel()
            if let operationCancellation { Task { await operationCancellation.cancel() } }
            if let eraseGate { Task { await eraseGate.invalidateAll() } }
            phase = .failed("コピー元カードが取り外されました")
            statusMessage = "カードの挿入世代が変わったため、再スキャンと再検証が必要です"
            cardInitializationStatus = "抜去を検出したため初期化許可を失効しました"
            if removedAutomaticSource {
                // Only clear our own automatic choice. A manually chosen source remains sticky.
                sourceURL = nil
                scheduleAutomaticCardSelection()
            }
        }
    }

    private func startCardVolumeMonitorIfReady() {
        guard cardVolumeMonitor == nil,
              operationStore != nil,
              applicationInstanceLock != nil
        else { return }
        do {
            let monitor = try CardVolumeMonitor(registry: volumeRegistry) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleCardVolumeEvent(event)
                }
            }
            cardVolumeMonitor = monitor
            monitor.start()
        } catch {
            cardInitializationStatus = "カード監視を開始できないため初期化は無効です"
            statusMessage = "カード監視を開始できませんでした: \(error.localizedDescription)"
        }
    }

    private var cardSourceInteractionAllowsScan: Bool {
        CardAutoSelectionInteractionState(
            route: route,
            mainWindowIsKey: cardAutoSelectionMainWindowIsKey,
            explicitInteractionBlocked: cardAutoSelectionInteractionBlocked,
            captureConfigurationVisible: showCaptureConfigurationSheet,
            projectLocationVisible: showProjectLocationSheet,
            previewVisible: previewAsset != nil,
            eraseConfirmationVisible: showCardEraseConfirmation,
            assetExclusionConfirmationVisible: showAssetExclusionConfirmation,
            emptyDirectoryConfirmationVisible: showEmptyDirectoryExclusionConfirmation,
            nativeModalVisible: NSApplication.shared.modalWindow != nil,
            attachedSheetVisible: NSApplication.shared.keyWindow?.attachedSheet != nil
        ).allowsSelection
    }

    private func updateConnectedCardCandidates() {
        let candidates = CardAutoSelectionPolicy.eligibleCandidates(Array(registeredCardCandidates.values))
        if candidates != connectedCardCandidates { connectedCardCandidates = candidates }
    }

    private func scheduleAutomaticCardSelection() {
        guard cardVolumeMonitor != nil else { return }
        automaticCardSelectionTask?.cancel()
        let generation = UUID()
        automaticCardSelectionGeneration = generation
        automaticCardSelectionTask = Task { [weak self] in
            // Coalesce initial volume callbacks and wait for all identity/quarantine lookups.
            // No filesystem work is performed by this timer on the main actor.
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            while !Task.isCancelled {
                guard let self, automaticCardSelectionGeneration == generation else { return }
                let recognizedCards = cardVolumeMonitor?.currentIdentities ?? []
                let knownDispositionIDs = Set(registeredCardCandidates.keys).union(rejectedAutomaticCardIDs)
                let decision = CardAutoSelectionPolicy.decision(
                    candidates: connectedCardCandidates,
                    hasExistingSource: sourceURL != nil,
                    detectionInProgress: cardVolumeMonitor?.hasPendingObservations == true
                        || !cardAppearanceRegistrationGenerations.isEmpty
                        || recognizedCards.contains { !knownDispositionIDs.contains($0.id) },
                    interactionAllowsSelection: cardSourceInteractionAllowsScan
                        && canStartIngestSourceScan,
                    recognizedCardCount: recognizedCards.count
                )
                switch decision {
                case .select(let sourceID, let arrivalGeneration):
                    selectConnectedCard(sourceID: sourceID, arrivalGeneration: arrivalGeneration, automatic: true)
                    return
                case .waitForDetection:
                    setCardAutoSelectionStatus("接続中のSDカードを安全に照合しています")
                case .waitForInteraction:
                    setCardAutoSelectionStatus("SDカードを検出しました。取り込み画面で操作が完了すると自動で読み込みます")
                case .requireChoice:
                    setCardAutoSelectionStatus("複数のSDカードを検出しました。読み込むカードを選択してください")
                    return
                case .preserveExistingSource:
                    setCardAutoSelectionStatus(automaticallySelectedCard == nil
                        ? "選択済みの読み込み元を維持しています。別のSDカードへ自動変更しません"
                        : "接続中のSDカードを自動選択しました")
                    return
                case .noCandidate:
                    setCardAutoSelectionStatus("SDカードを自動検出できない場合は「選択…」から指定してください")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func setCardAutoSelectionStatus(_ message: String) {
        if cardAutoSelectionStatus != message { cardAutoSelectionStatus = message }
    }

    func selectConnectedCard(sourceID: SourceVolumeID, arrivalGeneration: UUID) {
        selectConnectedCard(sourceID: sourceID, arrivalGeneration: arrivalGeneration, automatic: false)
    }

    private func selectConnectedCard(sourceID: SourceVolumeID, arrivalGeneration: UUID, automatic: Bool) {
        guard (!automatic || sourceURL == nil),
              cardSourceInteractionAllowsScan,
              canStartIngestSourceScan,
              let identity = registeredCardCandidates[sourceID],
              identity.arrivalGeneration == arrivalGeneration,
              CardAutoSelectionPolicy.isEligible(identity),
              let mountURL = identity.mountURL,
              cardVolumeMonitor?.identity(containing: mountURL)?.securityDigest == identity.securityDigest
        else { return }
        automaticallySelectedCard = automatic ? CardInsertionIdentity(
            sourceID: identity.id, arrivalGeneration: identity.arrivalGeneration
        ) : nil
        sourceURL = mountURL
        setCardAutoSelectionStatus(automatic ? "接続中のSDカードを自動選択しました" : "指定したSDカードを読み込みます")
        scan(url: mountURL)
    }

    private func acceptRegisteredCardAppearance(_ identity: VolumeIdentity) {
        guard let sourceURL, Self.isURL(sourceURL, containedBy: identity.mountURL) else { return }
        guard Self.permitsNewMediaIsolationAttempt(
            mediaReadIsolationFailed: mediaReadIsolationFailed
        ) else {
            retainRestartRequiredIsolationState(rejecting: identity)
            return
        }
        let previousVolumeID = activeSourceVolumeID
        let previousRootPath = activeSourceRootPath
        let canonicalRoot = identity.mountURL?.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRootPath = canonicalRoot?.path
        let identityChanged = previousVolumeID != identity.id
            || previousRootPath != canonicalRootPath
            || coreScanResult?.sourceVolumeID != identity.id
            || coreScanResult?.root.standardizedFileURL.resolvingSymlinksInPath().path != canonicalRootPath
        activeSourceIdentity = identity
        activeSourceVolumeID = identity.id
        activeSourceRootPath = canonicalRootPath
        cardInitializationStatus = "リムーバブルカードを強い物理IDと永続隔離ストアで照合しました"
        guard identityChanged, let canonicalRoot else { return }
        let mustDeferScan = ingestScanAdmissionMustWait || !cardSourceInteractionAllowsScan
        if mustDeferScan {
            let deferredGeneration = UUID()
            deferredCardScanGeneration = deferredGeneration
            statusMessage = "実行中の安全停止が完了した後に、登録済みカードをフルスキャンします"
            Task { [weak self] in
                guard let self else { return }
                while ingestScanAdmissionMustWait || !cardSourceInteractionAllowsScan {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard deferredCardScanGeneration == deferredGeneration else { return }
                    guard Self.permitsNewMediaIsolationAttempt(
                        mediaReadIsolationFailed: mediaReadIsolationFailed
                    ) else {
                        retainRestartRequiredIsolationState(rejecting: identity)
                        return
                    }
                }
                guard deferredCardScanGeneration == deferredGeneration,
                      !ingestScanAdmissionMustWait,
                      cardSourceInteractionAllowsScan,
                      self.sourceURL.map({ Self.isURL($0, containedBy: identity.mountURL) }) == true,
                      cardVolumeMonitor?.identity(containing: canonicalRoot)?.securityDigest
                      == identity.securityDigest
                else { return }
                deferredCardScanGeneration = nil
                scanTask?.cancel()
                self.sourceURL = canonicalRoot
                scan(url: canonicalRoot)
            }
        } else if !ingestScanAdmissionMustWait && cardSourceInteractionAllowsScan {
            deferredCardScanGeneration = nil
            scanTask?.cancel()
            self.sourceURL = canonicalRoot
            scan(url: canonicalRoot)
        }
    }

    private func rejectUnregisteredCardIfSelected(_ identity: VolumeIdentity, message: String) {
        guard let sourceURL, Self.isURL(sourceURL, containedBy: identity.mountURL) else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        invalidateCaptureDateEnrichment()
        assets = []
        selectedAssetIDs.removeAll()
        sceneAssignments.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        scanErrors = []
        coreScanResult = nil
        activeSourceScanScope = nil
        activeSourceIdentity = nil
        inFlightStrongScanIdentity = nil
        inFlightStrongScanGeneration = nil
        activeSourceVolumeID = nil
        activeSourceRootPath = nil
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        phase = .failed(message)
        statusMessage = message
        cardInitializationStatus = "隔離中のカードは読取・取込・取出・初期化できません"
    }

    nonisolated private static func isURL(_ url: URL, containedBy mountURL: URL?) -> Bool {
        guard let mountURL else { return false }
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let mount = mountURL.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == mount || candidate.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
    }

    private static func defaultCardLabel(cardNumber: String, displayName: String) -> String {
        let candidate = cardNumber.nilIfBlank ?? displayName
        let uppercase = candidate.uppercased()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let filtered = uppercase.unicodeScalars.filter(allowed.contains)
        let label = String(String.UnicodeScalarView(filtered)).prefix(11)
        return label.isEmpty ? "UMIS_CARD" : String(label)
    }

    private func refreshStoredProjects() {
        guard let projectStore else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await projectStore.listWithDiagnostics()
                availableProjects = result.projects
                let errors = result.diagnostics.filter { $0.severity == .error }.count
                let warnings = result.diagnostics.filter { $0.severity == .warning }.count
                if errors > 0 {
                    projectPersistenceStatus = "\(errors)件の破損プロジェクトを安全にスキップ"
                    statusMessage = "有効なプロジェクトだけを表示しています。破損ファイルは変更していません"
                } else if warnings > 0 {
                    projectPersistenceStatus = "\(warnings)件をバックアップから一覧表示"
                }
            } catch {
                projectPersistenceStatus = "一覧取得失敗"
                statusMessage = userFacingMessage(for: error)
            }
        }
    }

    func makePersistedProject(
        sceneOverride: [AppScene]? = nil,
        sceneCatalogVersionOverride: CatalogVersionRef? = nil
    ) throws -> Project {
        let normalizedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw UMISCoreError.invalidPlan("プロジェクト名を入力してください")
        }

        var photographers = projectPhotographers
        var activePhotographerID: PhotographerID?
        if let displayName = photographer.nilIfBlank {
            let mappedID = cardNumber.nilIfBlank.flatMap { number in
                projectSettings.cardDefinitions.first(where: {
                    $0.isActive && $0.cardNumber == number
                })?.photographerID
            }
            if let selectedID = selectedProjectPhotographerID,
               let index = photographers.firstIndex(where: {
                   $0.id == selectedID && !$0.isArchived && $0.displayName == displayName
               }) {
                activePhotographerID = photographers[index].id
            } else if let mappedID,
               let index = photographers.firstIndex(where: {
                   $0.id == mappedID && !$0.isArchived && $0.displayName == displayName
               }) {
                activePhotographerID = photographers[index].id
            } else if let index = photographers.firstIndex(where: {
                !$0.isArchived && $0.displayName == displayName
            }) {
                activePhotographerID = photographers[index].id
            } else {
                let entry = Photographer(displayName: displayName)
                photographers.append(entry)
                activePhotographerID = entry.id
            }
        }

        var settings = projectSettings
        if settings.categories.isEmpty {
            settings.categories = Self.defaultProjectCategories()
        }
        settings.renameRule = try Self.renameRule(
            from: renameTemplate,
            timeZoneIdentifier: Self.renameTimeZone(for: projectSettings.renameRule).identifier
        )
        try ProjectConfigurationEditing.reconcileLocation(name: locationName, settings: &settings)
        if let number = cardNumber.nilIfBlank {
            if let index = settings.cardDefinitions.firstIndex(where: { $0.cardNumber == number }) {
                settings.cardDefinitions[index].photographerID = activePhotographerID
                settings.cardDefinitions[index].isActive = true
            } else {
                settings.cardDefinitions.append(CardDefinition(
                    cardNumber: number,
                    photographerID: activePhotographerID
                ))
            }
        }

        let persistedScenes = sceneOverride ?? scenes
        let coreScenes = persistedScenes.map { scene in
            Scene(
                id: SceneID(rawValue: scene.id),
                projectID: projectID,
                displayName: scene.name,
                code: scene.code,
                day: scene.day == 0 ? nil : scene.day,
                sortOrder: scene.number,
                entityVersion: scene.entityVersion
            )
        }
        projectPhotographers = photographers
        projectSettings = settings
        selectedProjectPhotographerID = activePhotographerID
        selectedProjectCardID = settings.cardDefinitions.first { $0.cardNumber == cardNumber.nilIfBlank }?.id
        return Project(
            id: projectID,
            name: normalizedName,
            destination: destinationURL,
            photographers: photographers,
            scenes: coreScenes,
            settings: settings,
            sceneCatalogVersionWitness: Self.sceneCatalogWitness(
                from: sceneCatalogVersionOverride ?? appliedSceneCatalogVersion
            )
        )
    }

    func applyStoredProject(_ project: Project) {
        lanSceneCatalog?.setOff()
        lanCatalogEnabled = false
        projectID = project.id
        selectedStoredProjectID = project.id.rawValue
        projectName = project.name
        destinationURL = project.destination
        projectPhotographers = project.photographers
        projectSettings = project.settings
        appliedSceneCatalogVersion = Self.catalogVersion(from: project.sceneCatalogVersionWitness)
        excludedFolderNamesDraft = project.settings.excludedFolderNames.sorted().joined(separator: ", ")

        let activeCard = project.settings.cardDefinitions.first { $0.isActive }
        let activePhotographer: Photographer?
        if let activeCard {
            // An existing card with no usable mapping explicitly means "unspecified". Never
            // assign an unrelated first photographer merely because the mapping is absent.
            activePhotographer = activeCard.photographerID.flatMap { photographerID in
                project.photographers.first { $0.id == photographerID && !$0.isArchived }
            }
        } else {
            activePhotographer = project.photographers.first { !$0.isArchived }
        }
        photographer = activePhotographer?.displayName ?? ""
        selectedProjectPhotographerID = activePhotographer?.id
        selectedProjectCardID = activeCard?.id
        if let locationID = project.settings.selectedLocationID {
            locationName = project.settings.locations.first { $0.id == locationID }?.displayName ?? ""
        } else {
            locationName = ""
        }
        cardNumber = activeCard?.cardNumber ?? ""
        renameTemplate = Self.template(from: project.settings.renameRule)

        let restoredScenes = project.scenes
            .filter { !$0.isArchived }
            .sorted {
                if ($0.day ?? 0) != ($1.day ?? 0) { return ($0.day ?? 0) < ($1.day ?? 0) }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .map {
                AppScene(
                    id: $0.id.rawValue,
                    day: $0.day ?? 0,
                    number: max(0, $0.sortOrder),
                    name: $0.displayName,
                    codeOverride: $0.code,
                    entityVersion: $0.entityVersion
                )
            }
        scenes = restoredScenes.isEmpty ? Self.defaultScenes() : restoredScenes
        selectedSceneID = scenes.first?.id
        clearScanDerivedStateForProjectTransition()
        projectHasUnsavedChanges = false
        projectDestinationStatus = project.destination == nil
            ? "このプロジェクトには保存先が登録されていません"
            : "プロジェクトに保存された保存先を復元しました"
    }

    private static func defaultScenes() -> [AppScene] {
        var values = [AppScene(id: UUID(), day: 0, number: 0, name: "その他")]
        for day in 1 ... 4 {
            values.append(AppScene(id: UUID(), day: day, number: 1, name: "シーン1"))
        }
        return values
    }

    private static func sceneCatalogWitness(
        from version: CatalogVersionRef?
    ) -> SceneCatalogVersionWitness? {
        guard let version else { return nil }
        return SceneCatalogVersionWitness(
            projectID: ProjectID(rawValue: version.projectID),
            catalogID: version.catalogID,
            authorityID: version.authorityID,
            authorityEpoch: version.authorityEpoch,
            revision: version.revision,
            payloadDigest: version.payloadDigest.hex
        )
    }

    private static func catalogVersion(
        from witness: SceneCatalogVersionWitness?
    ) -> CatalogVersionRef? {
        guard let witness,
              let digest = try? SHA256Value(hex: witness.payloadDigest)
        else { return nil }
        return CatalogVersionRef(
            projectID: witness.projectID.rawValue,
            catalogID: witness.catalogID,
            authorityID: witness.authorityID,
            authorityEpoch: witness.authorityEpoch,
            revision: witness.revision,
            payloadDigest: digest
        )
    }

    private static func defaultProjectCategories() -> [ProjectCategory] {
        [
            ProjectCategory(
                displayName: "動画",
                folderName: "動画",
                extensions: ["mp4", "mov", "mxf", "avi", "mkv", "mts", "m2ts"],
                mediaKind: .movie,
                sortOrder: 0
            ),
            ProjectCategory(
                displayName: "写真",
                folderName: "写真",
                extensions: ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"],
                mediaKind: .photo,
                sortOrder: 1
            ),
            ProjectCategory(
                displayName: "RAW",
                folderName: "RAW",
                extensions: ["arw", "cr2", "cr3", "nef", "raf", "orf", "dng", "rw2"],
                mediaKind: .rawPhoto,
                sortOrder: 2
            ),
            ProjectCategory(
                displayName: "音声",
                folderName: "音声",
                extensions: ["wav", "aif", "aiff", "mp3", "aac", "m4a", "flac", "bwf"],
                mediaKind: .audio,
                sortOrder: 3
            ),
        ]
    }

    static func renameRule(
        from template: String,
        timeZoneIdentifier: String
    ) throws -> RenameRule {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw UMISCoreError.invalidPlan("リネームのタイムゾーン識別子が不正です")
        }
        let values = template.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard !values.isEmpty else { throw UMISCoreError.invalidPlan("命名テンプレートが空です") }
        let tokens: [FilenameToken] = try values.map { value in
            switch value {
            case "{location}": .location
            case "{scene}": .sceneCode
            case "{sceneName}": .sceneName
            case "{date}": .capturedDate
            case "{photographer}": .photographer
            case "{card}": .cardNumber
            case "{sequence}": .sequence
            case "{original}": .originalStem
            default: .literal(try PathSafety.validateComponent(value))
            }
        }
        return RenameRule(
            tokens: tokens,
            separator: "_",
            sequenceWidth: 4,
            preserveRelativeDirectories: true,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private static let defaultRenameRule = RenameRule(
        tokens: [
            .location,
            .sceneCode,
            .capturedDate,
            .photographer,
            .cardNumber,
            .originalStem,
        ],
        separator: "_",
        sequenceWidth: 4,
        preserveRelativeDirectories: true
    )

    private static func template(from rule: RenameRule) -> String {
        rule.tokens.map { token in
            switch token {
            case let .literal(value): value
            case .location: "{location}"
            case .sceneCode: "{scene}"
            case .sceneName: "{sceneName}"
            case .photographer: "{photographer}"
            case .cardNumber: "{card}"
            case .capturedDate: "{date}"
            case .sequence: "{sequence}"
            case .originalStem: "{original}"
            }
        }.joined(separator: rule.separator)
    }

    nonisolated static func incrementedSceneEntityVersion(_ current: Int) -> Int? {
        guard current > 0 else { return nil }
        let (next, overflow) = current.addingReportingOverflow(1)
        // ProjectStore accepts only 1 ..< Int.max, leaving one fail-closed sentinel value.
        guard !overflow, next < Int.max else { return nil }
        return next
    }

    nonisolated static func renumberedScenes(
        _ input: [AppScene],
        day: Int
    ) throws -> [AppScene] {
        var result = input
        var nextNumber = 1
        for index in result.indices where result[index].day == day {
            let desiredNumber: Int
            if day == 0 {
                desiredNumber = 0
            } else {
                guard nextNumber <= Int(Int32.max) else {
                    throw UMISCoreError.invalidPlan("シーン番号が保存可能な上限を超えました")
                }
                desiredNumber = nextNumber
                let (following, overflow) = nextNumber.addingReportingOverflow(1)
                guard !overflow else {
                    throw UMISCoreError.invalidPlan("シーン番号が表現上限を超えました")
                }
                nextNumber = following
            }
            if desiredNumber != result[index].number {
                guard let nextVersion = incrementedSceneEntityVersion(
                    result[index].entityVersion
                ) else {
                    throw UMISCoreError.invalidPlan(
                        "シーンの更新世代が上限に達したため並べ替えできません"
                    )
                }
                result[index].number = desiredNumber
                result[index].codeOverride = nil
                result[index].entityVersion = nextVersion
            }
        }
        return result
    }

    private func clearScanDerivedStateForProjectTransition() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        invalidateCaptureDateEnrichment()
        activeSourceScanScope = nil
        coreScanResult = nil
        assets = []
        selectedAssetIDs.removeAll()
        previewAsset = nil
        sceneAssignments.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        scanErrors = []
        operationCompletedItemIDs.removeAll()
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        showCardEraseConfirmation = false
        cardInitializationStatus = "プロジェクト変更後のソース再走査が必要です"
        phase = .idle
    }

    private func restartScanAfterProjectTransition(_ scope: AppSourceScanScope?) {
        guard !projectOperationInFlight else {
            statusMessage = "プロジェクト処理の完了後にソースを再スキャンしてください"
            return
        }
        guard let scope else {
            statusMessage = sourceURL == nil
                ? "プロジェクトを切り替えました。ソースを選択してください"
                : "プロジェクトを切り替えました。元の走査範囲が不明なため、ソースを明示的に再スキャンしてください"
            return
        }
        switch scope {
        case let .root(root):
            scan(url: root)
        case let .items(items):
            scan(items: items)
        }
    }

    private func clearSourceAfterRemoval() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        invalidateCaptureDateEnrichment()
        sourceURL = nil
        activeSourceScanScope = nil
        assets = []
        selectedAssetIDs.removeAll()
        sceneAssignments.removeAll()
        policyReviewAssetIDs.removeAll()
        explicitlyExcludedAssetIDs.removeAll()
        explicitExclusionEvidenceByAssetID.removeAll()
        pendingExclusionAssetIDs.removeAll()
        showAssetExclusionConfirmation = false
        resetEmptyDirectoryReviewState()
        scanErrors = []
        coreScanResult = nil
        deferredCardScanGeneration = nil
        if let activeSourceVolumeID {
            cardAppearanceRegistrationGenerations.removeValue(forKey: activeSourceVolumeID)
        }
        activeSourceIdentity = nil
        inFlightStrongScanIdentity = nil
        inFlightStrongScanGeneration = nil
        activeSourceVolumeID = nil
        activeSourceRootPath = nil
        invalidateVerifiedIngestIntent()
        pendingCardIdentitySummary = ""
        pendingFinalVerificationAt = nil
        pendingRequiredAssetCount = 0
        pendingVerifiedDeliveryCount = 0
        showCardEraseConfirmation = false
        cardInitializationStatus = "カードを検出していません"
    }

    private func beginUnexpectedRemovalMediaIsolation() {
        guard Self.permitsNewMediaIsolationAttempt(
            mediaReadIsolationFailed: mediaReadIsolationFailed
        ) else {
            retainRestartRequiredIsolationState(rejecting: nil)
            return
        }
        mediaReadIsolationTask?.cancel()
        let generation = UUID()
        mediaReadIsolationGeneration = generation
        mediaReadIsolationTask = Task { [weak self] in
            guard let self else { return false }
            do {
                try await waitForPreviewPlaybackQuiescence()
                await mediaPipeline?.suspendAndAwaitQuiescence()
                try await waitForPreviewPlaybackQuiescence()
                try Task.checkCancellation()
                guard mediaReadIsolationGeneration == generation,
                      mediaAccessQuiescenceLatched
                else { return false }
                mediaReadIsolationFailed = false
                return true
            } catch {
                guard mediaReadIsolationGeneration == generation else { return false }
                mediaReadIsolationFailed = true
                statusMessage = "旧カードの再生・メディア読取停止を確認できません。アプリを再起動してください"
                cardInitializationStatus = "メディア読取を検疫中（再開禁止）"
                return false
            }
        }
    }

    nonisolated static func permitsNewMediaIsolationAttempt(
        mediaReadIsolationFailed: Bool
    ) -> Bool {
        !mediaReadIsolationFailed
    }

    private func retainRestartRequiredIsolationState(rejecting identity: VolumeIdentity?) {
        deferredCardScanGeneration = nil
        if let identity {
            if activeSourceIdentity?.securityDigest == identity.securityDigest {
                activeSourceIdentity = nil
            }
            if activeSourceVolumeID == identity.id {
                activeSourceVolumeID = nil
                activeSourceRootPath = nil
            }
        }
        statusMessage = "旧カードの再生・メディア読取停止を確認できません。アプリを再起動してください"
        cardInitializationStatus = "メディア読取の再起動必須検疫中（この起動中は再開禁止）"
    }

    private func waitForPreviewPlaybackQuiescence() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !activePreviewPlaybackIDs.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw UMISCoreError.eraseNotEligible(
                    "動画・音声プレビューの停止を確認できません。プレビューを閉じて再実行してください"
                )
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func currentRenameIntent() -> RenameUIIntent? {
        guard let source = renameSourceURL?.standardizedFileURL.resolvingSymlinksInPath(),
              let destination = renameDestinationURL?.standardizedFileURL.resolvingSymlinksInPath()
        else { return nil }
        let selectedScene = selectedSceneID.flatMap { id in scenes.first { $0.id == id } }
        return RenameUIIntent(
            sourcePath: source.path,
            destinationPath: destination.path,
            template: renameTemplate,
            projectID: projectID.rawValue,
            projectName: projectName,
            location: locationName,
            photographer: photographer,
            cardNumber: cardNumber,
            sceneID: selectedScene?.id,
            sceneCode: selectedScene?.code,
            sceneName: selectedScene?.name,
            scanPolicyDigest: (try? StableDigest.encode(MediaScanPolicy(projectSettings: projectSettings))) ?? "invalid"
        )
    }

    private func invalidatePreparedRenamePreviewIfNeeded() {
        guard preparedRenamePlan != nil || !renamePreviewRows.isEmpty else { return }
        preparedRenamePlan = nil
        preparedRenameIntent = nil
        renamePreviewRows = []
        renameStatusMessage = "命名条件が変更されました。計画を再作成してください"
    }

    private var currentEmptyDirectoryExclusionEvidence: [ExplicitDirectoryExclusionEvidence] {
        emptyDirectoryReviewPaths.compactMap { emptyDirectoryExclusionEvidenceByPath[$0] }
    }

    private func resetEmptyDirectoryReviewState() {
        emptyDirectoryReviewPaths = []
        emptyDirectoryExclusionEvidenceByPath.removeAll()
        showEmptyDirectoryExclusionConfirmation = false
    }

    private func adoptDirectoryReviewState(from scan: ScanResult) {
        emptyDirectoryReviewPaths = scan.emptyUserDirectoryPathsRequiringReview.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        emptyDirectoryExclusionEvidenceByPath.removeAll()
        showEmptyDirectoryExclusionConfirmation = false
        if !emptyDirectoryReviewPaths.isEmpty {
            scanErrors.append(
                "空フォルダが\(emptyDirectoryReviewPaths.count)件あります。取り込み前に、保存先へ再作成しない判断を明示確認してください"
            )
        }
    }

    private func markProjectSettingsDirty() {
        markProjectMetadataDirty()
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        invalidateCaptureDateEnrichment()
        coreScanResult = nil
        if sourceURL != nil {
            statusMessage = "走査設定が変更されました。取り込み前に再スキャンしてください"
        }
    }

    private func markProjectMetadataDirty() {
        projectHasUnsavedChanges = true
        projectOperationGeneration = UUID()
        projectPersistenceStatus = "未保存の設定変更"
        invalidateVerifiedIngestIntent()
    }

    private func invalidateVerifiedIngestIntent() {
        ingestIntentGeneration = UUID()
        latestVerifiedIntentGeneration = nil
        latestVerifiedReceipt = nil
        latestVerifiedPlan = nil
        pendingEraseRunID = nil
        pendingEraseProfile = nil
        showCardEraseConfirmation = false
    }

    private func markLocalSceneMutation() {
        appliedSceneCatalogVersion = nil
        markProjectMetadataDirty()
    }

    private func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct CompanionPlanningPlacement: Equatable, Sendable {
    let assetID: MediaAssetID
    let primaryAssetID: MediaAssetID
    let sceneID: UUID
    let sequence: Int
}

private struct RenameUIIntent: Hashable, Sendable {
    let sourcePath: String
    let destinationPath: String
    let template: String
    let projectID: UUID
    let projectName: String
    let location: String
    let photographer: String
    let cardNumber: String
    let sceneID: UUID?
    let sceneCode: String?
    let sceneName: String?
    let scanPolicyDigest: String
}

private struct IngestPlanIntentMaterial: Codable, Hashable, Sendable {
    let project: Project
    let sourceVolume: VolumeIdentity
    let destination: DestinationIdentity
    let requiredSet: RequiredSet
    let scanPolicy: MediaScanPolicy?
    let items: [IngestPlanItem]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
