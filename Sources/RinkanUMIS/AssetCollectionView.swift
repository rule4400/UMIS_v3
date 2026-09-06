import AppKit
import SwiftUI
import UMISCore
import UMISMedia

enum ReviewRatingBadgeTone: Equatable {
    case secondary
    case rejected
    case rated
}

/// Keeps the compact tile badge and VoiceOver description in one testable state machine. XMP
/// without an explicit `xmp:Rating` property is deliberately different from the explicit value 0.
struct ReviewRatingBadgePresentation: Equatable {
    let text: String
    let accessibilityDescription: String
    let tone: ReviewRatingBadgeTone

    static func make(
        rating: AdobeRating,
        isLoaded: Bool,
        isExplicit: Bool,
        isLoading: Bool
    ) -> Self {
        guard isLoaded else {
            return Self(
                text: isLoading ? "…" : "未取得",
                accessibilityDescription: isLoading
                    ? "Adobe XMP評価を読み込み中"
                    : "Adobe XMP評価を取得できません",
                tone: .secondary
            )
        }
        guard isExplicit else {
            return Self(
                text: "未設定",
                accessibilityDescription: "Adobe XMP評価は未設定",
                tone: .secondary
            )
        }
        return switch rating {
        case .rejected:
            Self(text: "×", accessibilityDescription: "Adobe XMP除外評価", tone: .rejected)
        case .unrated:
            Self(text: "0", accessibilityDescription: "Adobe XMP評価0（明示設定）", tone: .secondary)
        default:
            Self(
                text: "\(rating.rawValue)★",
                accessibilityDescription: "Adobe XMP評価 \(rating.rawValue)つ星",
                tone: .rated
            )
        }
    }
}

enum AssetCollectionKeyboardPolicy {
    static func opensPreview(forKeyCode keyCode: UInt16) -> Bool {
        // ANSI Return and Space. Selection movement remains AppKit's native behavior.
        keyCode == 36 || keyCode == 49
    }
}

/// Pure update routing for the AppKit bridge. Revisions are supplied by the SwiftUI model so an
/// unrelated selection update never has to prove that several potentially large value collections
/// are unchanged.
struct AssetCollectionUpdateState: Equatable {
    let contentRevision: UInt64
    let metadataRevision: UInt64
    let selectionRevision: UInt64
    let thumbnailReloadGeneration: UUID?
    let hasMediaPipeline: Bool
}

struct AssetCollectionUpdateDecision: Equatable {
    let rebuildContent: Bool
    let refreshVisibleMetadata: Bool
    let refreshVisibleThumbnails: Bool
    let refreshNearVisibleThumbnails: Bool
    let applySelection: Bool
}

enum AssetCollectionUpdatePolicy {
    static func decision(
        previous: AssetCollectionUpdateState?,
        incoming: AssetCollectionUpdateState
    ) -> AssetCollectionUpdateDecision {
        guard let previous else {
            // Initial cell creation reads both content and metadata. A separate thumbnail refresh
            // would immediately repeat the visible requests started by cell configuration.
            return AssetCollectionUpdateDecision(
                rebuildContent: true,
                refreshVisibleMetadata: true,
                refreshVisibleThumbnails: false,
                refreshNearVisibleThumbnails: false,
                applySelection: true
            )
        }

        let rebuildContent = previous.contentRevision != incoming.contentRevision
        let refreshVisibleMetadata = previous.metadataRevision != incoming.metadataRevision
        let thumbnailSourceChanged = previous.thumbnailReloadGeneration
            != incoming.thumbnailReloadGeneration
        let pipelineBecameAvailable = !previous.hasMediaPipeline && incoming.hasMediaPipeline
        let refreshThumbnails = !rebuildContent
            && (thumbnailSourceChanged || pipelineBecameAvailable)
        return AssetCollectionUpdateDecision(
            rebuildContent: rebuildContent,
            refreshVisibleMetadata: refreshVisibleMetadata,
            refreshVisibleThumbnails: refreshThumbnails,
            refreshNearVisibleThumbnails: refreshThumbnails,
            // Applying AppKit selection walks every requested and selected identifier. Keep that
            // work off unrelated AppModel publications; a content rebuild restores selection from
            // the latest parent value after its diffable snapshot has finished applying.
            applySelection: rebuildContent
                || previous.selectionRevision != incoming.selectionRevision
        )
    }
}

struct AssetCollectionSelectionDelta: Equatable {
    let select: Set<UUID>
    let deselect: Set<UUID>

    var isEmpty: Bool { select.isEmpty && deselect.isEmpty }
}

enum AssetCollectionSelectionPolicy {
    /// AppKit's actual selection is authoritative here: applying a diffable snapshot is allowed to
    /// clear it even when the requested SwiftUI selection did not change.
    static func delta(
        requestedAvailableIDs: Set<UUID>,
        actualSelectedIDs: Set<UUID>
    ) -> AssetCollectionSelectionDelta {
        AssetCollectionSelectionDelta(
            select: requestedAvailableIDs.subtracting(actualSelectedIDs),
            deselect: actualSelectedIDs.subtracting(requestedAvailableIDs)
        )
    }

    /// VoiceOver selection starts from AppKit's actual collection state, just like mouse selection.
    /// The opened asset is not implicitly made the sole selection, so multi-selection remains usable.
    static func toggling(_ identifier: UUID, in actualSelectedIDs: Set<UUID>) -> Set<UUID> {
        var result = actualSelectedIDs
        if result.remove(identifier) == nil {
            result.insert(identifier)
        }
        return result
    }
}

/// `NSCollectionViewFlowLayout` treats inter-item spacing as a minimum and may justify a row by
/// making the gaps wider. UMIS keeps every tile exactly one physical display pixel apart and leaves
/// any remainder at the trailing edge so dense visual comparison stays predictable.
@MainActor
final class ExactGapCollectionViewFlowLayout: NSCollectionViewFlowLayout {
    func updateBackingScaleFactor(_ scale: CGFloat) {
        let onePhysicalPixel = 1 / max(scale, 1)
        guard minimumInteritemSpacing != onePhysicalPixel
                || minimumLineSpacing != onePhysicalPixel else { return }
        minimumInteritemSpacing = onePhysicalPixel
        minimumLineSpacing = onePhysicalPixel
        sectionInset = NSEdgeInsets(
            top: onePhysicalPixel,
            left: onePhysicalPixel,
            bottom: onePhysicalPixel,
            right: onePhysicalPixel
        )
        invalidateLayout()
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForItem(at: indexPath)?.copy()
            as? NSCollectionViewLayoutAttributes else { return nil }
        let column = indexPath.item % itemCountPerRow
        attributes.frame.origin.x = sectionInset.left
            + CGFloat(column) * (itemSize.width + minimumInteritemSpacing)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        super.layoutAttributesForElements(in: rect).map { original in
            guard original.representedElementCategory == .item,
                  let indexPath = original.indexPath,
                  let exact = layoutAttributesForItem(at: indexPath)
            else { return original }
            return exact
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return super.shouldInvalidateLayout(forBoundsChange: newBounds) }
        return collectionView.bounds.size != newBounds.size
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    private var itemCountPerRow: Int {
        guard let collectionView else { return 1 }
        let availableWidth = max(
            0,
            collectionView.bounds.width - sectionInset.left - sectionInset.right
        )
        let stride = itemSize.width + minimumInteritemSpacing
        guard stride > 0 else { return 1 }
        return max(1, Int((availableWidth + minimumInteritemSpacing) / stride))
    }
}

@MainActor
private final class PixelAwareCollectionView: NSCollectionView {
    weak var exactGapLayout: ExactGapCollectionViewFlowLayout?
    var openSelectionHandler: (() -> Void)?
    var backingScaleFactorDidChange: ((CGFloat) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshPhysicalPixelSpacing()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshPhysicalPixelSpacing()
    }

    override func keyDown(with event: NSEvent) {
        if AssetCollectionKeyboardPolicy.opensPreview(forKeyCode: event.keyCode) {
            openSelectionHandler?()
            return
        }
        super.keyDown(with: event)
    }

    private func refreshPhysicalPixelSpacing() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        exactGapLayout?.updateBackingScaleFactor(scale)
        backingScaleFactorDidChange?(scale)
    }
}

@MainActor
final class AccessibleAssetCardView: NSView {
    var pressHandler: (() -> Void)?
    var interactionsAreEnabled = true

    override func accessibilityPerformPress() -> Bool {
        guard interactionsAreEnabled, let pressHandler else { return false }
        pressHandler()
        return true
    }
}

struct AssetCollectionView: NSViewRepresentable {
    @Environment(\.isEnabled) private var interactionsAreEnabled

    let assets: [AppAsset]
    /// Must change whenever `assets` or other non-metadata tile content changes.
    let contentRevision: UInt64
    /// Must change whenever `selectedIDs` changes. A dedicated revision avoids repeatedly walking
    /// a potentially very large selection when an unrelated `@Published` AppModel value updates.
    let selectionRevision: UInt64
    let selectedIDs: Set<UUID>
    let excludedIDs: Set<UUID>
    let mediaPipeline: MediaPipeline?
    /// Asset-to-scene IDs and the scene catalog stay unexpanded. Resolving the visible tile's name
    /// in the coordinator avoids rebuilding an O(assetCount) presentation dictionary per body.
    let sceneAssignments: [UUID: UUID]
    let sceneNamesByID: [UUID: String]
    let ratings: [UUID: AdobeRating]
    let ratingLoadedIDs: Set<UUID>
    let ratingExplicitIDs: Set<UUID>
    let labelNumbers: [UUID: Int]
    let labelLoadedIDs: Set<UUID>
    let metadataErrorIDs: Set<UUID>
    let metadataErrors: [UUID: String]
    let metadataWarnings: [UUID: String]
    /// Must change whenever any scene, exclusion, rating, Finder label, or metadata status changes.
    let metadataRevision: UInt64
    let thumbnailReloadGeneration: UUID?
    let metadataIsLoading: Bool
    let isReviewContext: Bool
    let onSelectionChange: (Set<UUID>) -> Void
    let onOpen: (AppAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let initialBackingScaleFactor = NSScreen.main?.backingScaleFactor ?? 2
        let layout = ExactGapCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 174, height: 154)
        layout.updateBackingScaleFactor(initialBackingScaleFactor)

        let collectionView = PixelAwareCollectionView()
        collectionView.exactGapLayout = layout
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = interactionsAreEnabled
        collectionView.setAccessibilityEnabled(interactionsAreEnabled)
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.openSelectionHandler = { [weak coordinator = context.coordinator] in
            coordinator?.openSelectedItem()
        }
        collectionView.backingScaleFactorDidChange = {
            [weak coordinator = context.coordinator] scale in
            coordinator?.updateThumbnailBackingScaleFactor(scale)
        }
        collectionView.register(
            AssetCollectionItem.self,
            forItemWithIdentifier: AssetCollectionItem.reuseIdentifier
        )

        context.coordinator.attach(to: collectionView)
        context.coordinator.updateThumbnailBackingScaleFactor(initialBackingScaleFactor)
        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.openDoubleClickedItem(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(
            assets: assets,
            contentRevision: contentRevision,
            selectionRevision: selectionRevision,
            selectedIDs: selectedIDs,
            interactionsAreEnabled: interactionsAreEnabled,
            sceneAssignments: sceneAssignments,
            sceneNamesByID: sceneNamesByID,
            excludedIDs: excludedIDs,
            ratings: ratings,
            ratingLoadedIDs: ratingLoadedIDs,
            ratingExplicitIDs: ratingExplicitIDs,
            labelNumbers: labelNumbers,
            labelLoadedIDs: labelLoadedIDs,
            metadataErrorIDs: metadataErrorIDs,
            metadataErrors: metadataErrors,
            metadataWarnings: metadataWarnings,
            metadataRevision: metadataRevision,
            thumbnailReloadGeneration: thumbnailReloadGeneration,
            metadataIsLoading: metadataIsLoading
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        enum Section: Hashable { case main }

        private struct PrefetchRequest {
            let token: UUID
            let task: Task<Void, Never>
        }

        var parent: AssetCollectionView
        private weak var collectionView: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Section, UUID>?
        private var assetsByID: [UUID: AppAsset] = [:]
        private var sceneAssignments: [UUID: UUID] = [:]
        private var sceneNamesByID: [UUID: String] = [:]
        private var excludedIDs: Set<UUID> = []
        private var ratings: [UUID: AdobeRating] = [:]
        private var ratingLoadedIDs: Set<UUID> = []
        private var ratingExplicitIDs: Set<UUID> = []
        private var labelNumbers: [UUID: Int] = [:]
        private var labelLoadedIDs: Set<UUID> = []
        private var metadataErrorIDs: Set<UUID> = []
        private var metadataErrors: [UUID: String] = [:]
        private var metadataWarnings: [UUID: String] = [:]
        private var applyingSelection = false
        private var appliedSelectionIDs: Set<UUID> = []
        private var prefetchTasks: [UUID: PrefetchRequest] = [:]
        private var currentAssetIDs: [UUID] = []
        private var metadataIsLoading = false
        private var interactionsAreEnabled = true
        private var updateState: AssetCollectionUpdateState?
        private var hasAppliedContentSnapshot = false
        private var contentApplySequence: UInt64 = 0
        private var applyingContentSnapshotSequence: UInt64?
        private var thumbnailPixelSize = MediaRequestSizingPolicy.assetTileThumbnailPixelSize(
            backingScaleFactor: 2
        )

        init(parent: AssetCollectionView) {
            self.parent = parent
        }

        func attach(to collectionView: NSCollectionView) {
            self.collectionView = collectionView
            dataSource = NSCollectionViewDiffableDataSource<Section, UUID>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, identifier in
                guard let self,
                      let asset = assetsByID[identifier],
                      let item = collectionView.makeItem(
                        withIdentifier: AssetCollectionItem.reuseIdentifier,
                        for: indexPath
                      ) as? AssetCollectionItem
                else {
                    return nil
                }
                configure(item, for: asset, identifier: identifier)
                return item
            }
        }

        func updateThumbnailBackingScaleFactor(_ scale: CGFloat) {
            let nextPixelSize = MediaRequestSizingPolicy.assetTileThumbnailPixelSize(
                backingScaleFactor: scale
            )
            guard nextPixelSize != thumbnailPixelSize else { return }
            thumbnailPixelSize = nextPixelSize
            cancelAllPrefetchTasks()
            reconfigureVisibleItems()
            refreshNearVisiblePrefetch()
        }

        func update(
            assets: [AppAsset],
            contentRevision: UInt64,
            selectionRevision: UInt64,
            selectedIDs: Set<UUID>,
            interactionsAreEnabled: Bool,
            sceneAssignments: [UUID: UUID],
            sceneNamesByID: [UUID: String],
            excludedIDs: Set<UUID>,
            ratings: [UUID: AdobeRating],
            ratingLoadedIDs: Set<UUID>,
            ratingExplicitIDs: Set<UUID>,
            labelNumbers: [UUID: Int],
            labelLoadedIDs: Set<UUID>,
            metadataErrorIDs: Set<UUID>,
            metadataErrors: [UUID: String],
            metadataWarnings: [UUID: String],
            metadataRevision: UInt64,
            thumbnailReloadGeneration: UUID?,
            metadataIsLoading: Bool
        ) {
            updateInteractionState(interactionsAreEnabled)
            let incomingState = AssetCollectionUpdateState(
                contentRevision: contentRevision,
                metadataRevision: metadataRevision,
                selectionRevision: selectionRevision,
                thumbnailReloadGeneration: thumbnailReloadGeneration,
                hasMediaPipeline: parent.mediaPipeline != nil
            )
            let decision = AssetCollectionUpdatePolicy.decision(
                previous: updateState,
                incoming: incomingState
            )
            updateState = incomingState

            if decision.refreshVisibleMetadata {
                updateMetadataState(
                    sceneAssignments: sceneAssignments,
                    sceneNamesByID: sceneNamesByID,
                    excludedIDs: excludedIDs,
                    ratings: ratings,
                    ratingLoadedIDs: ratingLoadedIDs,
                    ratingExplicitIDs: ratingExplicitIDs,
                    labelNumbers: labelNumbers,
                    labelLoadedIDs: labelLoadedIDs,
                    metadataErrorIDs: metadataErrorIDs,
                    metadataErrors: metadataErrors,
                    metadataWarnings: metadataWarnings,
                    metadataIsLoading: metadataIsLoading
                )
            }

            if decision.rebuildContent {
                rebuildContent(assets: assets)
                return
            }

            if decision.refreshVisibleThumbnails {
                cancelAllPrefetchTasks()
                reconfigureVisibleItems()
            } else if decision.refreshVisibleMetadata {
                refreshVisibleMetadata()
            }
            if decision.refreshNearVisibleThumbnails {
                refreshNearVisiblePrefetch()
            }
            if decision.applySelection {
                applySelection(selectedIDs)
            }
        }

        private func updateMetadataState(
            sceneAssignments: [UUID: UUID],
            sceneNamesByID: [UUID: String],
            excludedIDs: Set<UUID>,
            ratings: [UUID: AdobeRating],
            ratingLoadedIDs: Set<UUID>,
            ratingExplicitIDs: Set<UUID>,
            labelNumbers: [UUID: Int],
            labelLoadedIDs: Set<UUID>,
            metadataErrorIDs: Set<UUID>,
            metadataErrors: [UUID: String],
            metadataWarnings: [UUID: String],
            metadataIsLoading: Bool
        ) {
            self.sceneAssignments = sceneAssignments
            self.sceneNamesByID = sceneNamesByID
            self.excludedIDs = excludedIDs
            self.ratings = ratings
            self.ratingLoadedIDs = ratingLoadedIDs
            self.ratingExplicitIDs = ratingExplicitIDs
            self.labelNumbers = labelNumbers
            self.labelLoadedIDs = labelLoadedIDs
            self.metadataErrorIDs = metadataErrorIDs
            self.metadataErrors = metadataErrors
            self.metadataWarnings = metadataWarnings
            self.metadataIsLoading = metadataIsLoading
        }

        private func rebuildContent(assets: [AppAsset]) {
            var nextIDs: [UUID] = []
            var nextAssetsByID: [UUID: AppAsset] = [:]
            nextIDs.reserveCapacity(assets.count)
            nextAssetsByID.reserveCapacity(assets.count)
            for asset in assets {
                nextIDs.append(asset.id)
                nextAssetsByID[asset.id] = asset
            }
            assetsByID = nextAssetsByID

            let removedPrefetchIDs = prefetchTasks.keys.filter { nextAssetsByID[$0] == nil }
            for identifier in removedPrefetchIDs {
                prefetchTasks.removeValue(forKey: identifier)?.task.cancel()
            }
            appliedSelectionIDs = Set(appliedSelectionIDs.filter { nextAssetsByID[$0] != nil })

            let requiresSnapshot = !hasAppliedContentSnapshot || nextIDs != currentAssetIDs
            currentAssetIDs = nextIDs
            guard requiresSnapshot else {
                reconfigureVisibleItems()
                refreshNearVisiblePrefetch()
                applySelection(parent.selectedIDs)
                return
            }

            hasAppliedContentSnapshot = true
            contentApplySequence &+= 1
            let applySequence = contentApplySequence
            var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
            snapshot.appendSections([.main])
            snapshot.appendItems(nextIDs, toSection: .main)
            guard let dataSource else { return }
            applyingContentSnapshotSequence = applySequence
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, contentApplySequence == applySequence else { return }
                applyingContentSnapshotSequence = nil
                reconfigureVisibleItems()
                refreshNearVisiblePrefetch()
                applySelection(parent.selectedIDs)
            }
        }

        private func configure(
            _ item: AssetCollectionItem,
            for asset: AppAsset,
            identifier: UUID
        ) {
            item.configure(
                asset: asset,
                sceneName: sceneName(for: identifier),
                isExcluded: excludedIDs.contains(identifier),
                rating: ratings[identifier] ?? .unrated,
                ratingIsLoaded: ratingLoadedIDs.contains(identifier),
                ratingIsExplicit: ratingExplicitIDs.contains(identifier),
                labelNumber: labelNumbers[identifier] ?? 0,
                labelIsLoaded: labelLoadedIDs.contains(identifier),
                hasMetadataError: metadataErrorIDs.contains(identifier),
                metadataErrorMessage: metadataErrors[identifier],
                metadataWarningMessage: metadataWarnings[identifier],
                metadataIsLoading: metadataIsLoading,
                isReviewContext: parent.isReviewContext,
                mediaPipeline: parent.mediaPipeline,
                thumbnailPixelSize: thumbnailPixelSize,
                interactionsAreEnabled: interactionsAreEnabled,
                onToggleSelection: { [weak self] in
                    self?.toggleSelectionFromAccessibility(identifier: identifier) ?? false
                },
                onOpen: { [weak self] asset in self?.parent.onOpen(asset) }
            )
        }

        private func toggleSelectionFromAccessibility(identifier: UUID) -> Bool {
            guard interactionsAreEnabled,
                  applyingContentSnapshotSequence == nil,
                  assetsByID[identifier] != nil,
                  let collectionView,
                  let dataSource,
                  dataSource.indexPath(for: identifier) != nil else { return false }
            let actualSelectedIDs = Set(collectionView.selectionIndexPaths.compactMap {
                dataSource.itemIdentifier(for: $0)
            })
            let nextSelection = AssetCollectionSelectionPolicy.toggling(
                identifier,
                in: actualSelectedIDs
            )
            applySelection(nextSelection)
            parent.onSelectionChange(nextSelection)
            return true
        }

        private func updateInteractionState(_ isEnabled: Bool) {
            let didChange = interactionsAreEnabled != isEnabled
            interactionsAreEnabled = isEnabled
            collectionView?.isSelectable = isEnabled
            collectionView?.setAccessibilityEnabled(isEnabled)
            guard didChange else { return }
            collectionView?.visibleItems().forEach {
                ($0 as? AssetCollectionItem)?.updateInteractionsEnabled(isEnabled)
            }
            // AppKit may clear its actual selection when selection is disabled. The model remains
            // authoritative during the busy interval, so restore it once interaction is allowed.
            if isEnabled {
                applySelection(parent.selectedIDs)
            }
        }

        private func reconfigureVisibleItems() {
            guard let collectionView, let dataSource else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let identifier = dataSource.itemIdentifier(for: indexPath),
                      let asset = assetsByID[identifier],
                      let item = collectionView.item(at: indexPath) as? AssetCollectionItem
                else { continue }
                configure(item, for: asset, identifier: identifier)
            }
        }

        private func refreshVisibleMetadata() {
            guard let collectionView, let dataSource else { return }
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let identifier = dataSource.itemIdentifier(for: indexPath),
                      let item = collectionView.item(at: indexPath) as? AssetCollectionItem
                else { continue }
                item.updateStatus(
                    sceneName: sceneName(for: identifier),
                    isExcluded: excludedIDs.contains(identifier)
                )
                item.updateMetadata(
                    rating: ratings[identifier] ?? .unrated,
                    ratingIsLoaded: ratingLoadedIDs.contains(identifier),
                    ratingIsExplicit: ratingExplicitIDs.contains(identifier),
                    labelNumber: labelNumbers[identifier] ?? 0,
                    labelIsLoaded: labelLoadedIDs.contains(identifier),
                    hasError: metadataErrorIDs.contains(identifier),
                    errorMessage: metadataErrors[identifier],
                    warningMessage: metadataWarnings[identifier],
                    metadataIsLoading: metadataIsLoading
                )
            }
        }

        private func sceneName(for assetID: UUID) -> String? {
            sceneAssignments[assetID].flatMap { sceneNamesByID[$0] }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            publishSelection(from: collectionView)
        }

        @objc func openDoubleClickedItem(_ recognizer: NSClickGestureRecognizer) {
            guard interactionsAreEnabled,
                  recognizer.state == .ended,
                  let collectionView,
                  let dataSource
            else { return }
            let point = recognizer.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  let identifier = dataSource.itemIdentifier(for: indexPath),
                  let asset = assetsByID[identifier]
            else { return }
            parent.onOpen(asset)
        }

        func openSelectedItem() {
            guard interactionsAreEnabled,
                  let collectionView,
                  let dataSource,
                  let indexPath = collectionView.selectionIndexPaths.sorted(by: {
                      if $0.section != $1.section { return $0.section < $1.section }
                      return $0.item < $1.item
                  }).first,
                  let identifier = dataSource.itemIdentifier(for: indexPath),
                  let asset = assetsByID[identifier] else { return }
            parent.onOpen(asset)
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            startPrefetching(indexPaths)
        }

        private func startPrefetching(_ indexPaths: [IndexPath]) {
            guard let dataSource, let pipeline = parent.mediaPipeline else { return }
            for indexPath in indexPaths {
                guard let identifier = dataSource.itemIdentifier(for: indexPath),
                      let asset = assetsByID[identifier],
                      prefetchTasks[identifier] == nil
                else { continue }
                let token = UUID()
                let requestedPixelSize = thumbnailPixelSize
                let task = Task<Void, Never> { [weak self] in
                    _ = try? await pipeline.thumbnail(
                        for: asset.url,
                        pixelSize: requestedPixelSize,
                        priority: .nearVisible
                    )
                    self?.finishPrefetch(identifier: identifier, token: token)
                }
                prefetchTasks[identifier] = PrefetchRequest(token: token, task: task)
            }
        }

        private func finishPrefetch(identifier: UUID, token: UUID) {
            guard prefetchTasks[identifier]?.token == token else { return }
            prefetchTasks.removeValue(forKey: identifier)
        }

        /// Re-primes only the next viewport around the visible cells. This preserves near-visible
        /// prefetching after a pipeline/cache generation change without applying an O(N) diffable
        /// snapshot reload.
        private func refreshNearVisiblePrefetch() {
            guard let collectionView, let layout = collectionView.collectionViewLayout else { return }
            let visibleRect = collectionView.visibleRect
            guard !visibleRect.isEmpty else { return }
            let verticalPadding = max(visibleRect.height, 154)
            let nearVisibleRect = visibleRect
                .insetBy(dx: 0, dy: -verticalPadding)
                .intersection(collectionView.bounds)
            let visibleIndexPaths = collectionView.indexPathsForVisibleItems()
            let nearVisibleIndexPaths = layout.layoutAttributesForElements(in: nearVisibleRect)
                .filter { $0.representedElementCategory == .item }
                .compactMap(\.indexPath)
                .filter { !visibleIndexPaths.contains($0) }
            startPrefetching(nearVisibleIndexPaths)
        }

        private func cancelAllPrefetchTasks() {
            for request in prefetchTasks.values { request.task.cancel() }
            prefetchTasks.removeAll(keepingCapacity: true)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            guard let dataSource else { return }
            for indexPath in indexPaths {
                guard let identifier = dataSource.itemIdentifier(for: indexPath) else { continue }
                prefetchTasks.removeValue(forKey: identifier)?.task.cancel()
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            publishSelection(from: collectionView)
        }

        private func applySelection(_ selectedIDs: Set<UUID>) {
            guard let collectionView, let dataSource else { return }
            let availableSelectedIDs = Set(selectedIDs.filter {
                dataSource.indexPath(for: $0) != nil
            })
            let actualSelectedIDs = Set(collectionView.selectionIndexPaths.compactMap {
                dataSource.itemIdentifier(for: $0)
            })
            let delta = AssetCollectionSelectionPolicy.delta(
                requestedAvailableIDs: availableSelectedIDs,
                actualSelectedIDs: actualSelectedIDs
            )
            guard !delta.isEmpty else {
                appliedSelectionIDs = actualSelectedIDs
                return
            }

            let removedIndexPaths = Set(delta.deselect.compactMap { dataSource.indexPath(for: $0) })
            let addedIndexPaths = Set(delta.select.compactMap { dataSource.indexPath(for: $0) })
            applyingSelection = true
            defer { applyingSelection = false }
            if !removedIndexPaths.isEmpty {
                collectionView.deselectItems(at: removedIndexPaths)
            }
            if !addedIndexPaths.isEmpty {
                collectionView.selectItems(at: addedIndexPaths, scrollPosition: [])
            }
            appliedSelectionIDs = availableSelectedIDs
        }

        private func publishSelection(from collectionView: NSCollectionView) {
            guard interactionsAreEnabled,
                  !applyingSelection,
                  applyingContentSnapshotSequence == nil,
                  let dataSource else { return }
            let identifiers = Set(
                collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
            )
            guard identifiers != appliedSelectionIDs else { return }
            appliedSelectionIDs = identifiers
            parent.onSelectionChange(identifiers)
        }

        deinit {
            for request in prefetchTasks.values { request.task.cancel() }
        }
    }
}

@MainActor
final class AssetCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AssetCollectionItem")

    private let card = AccessibleAssetCardView()
    private let imageContainer = NSView()
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sceneLabel = NSTextField(labelWithString: "")
    private let ratingLabel = NSTextField(labelWithString: "")
    private let colorDot = NSView()
    private let metadataErrorIcon = NSImageView()
    private var selectionAccessibilityAction: NSAccessibilityCustomAction?
    private var thumbnailTask: Task<Void, Never>?
    private var representedURL: URL?
    private var representedRelativePath: String?
    private var isExcluded = false
    private var currentSceneName: String?
    private var currentRating: AdobeRating = .unrated
    private var ratingIsLoaded = false
    private var ratingIsExplicit = false
    private var currentLabelNumber = 0
    private var labelIsLoaded = false
    private var metadataIsLoading = false
    private var hasMetadataError = false
    private var hasMetadataWarning = false
    private var isReviewContext = false
    private var metadataErrorDetail: String?
    private var metadataWarningDetail: String?

    override func loadView() {
        view = card
        card.wantsLayer = true
        card.layer?.cornerRadius = 3
        card.layer?.borderWidth = 1

        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = 2
        imageContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor

        filenameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        sceneLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        sceneLabel.textColor = .controlAccentColor
        sceneLabel.lineBreakMode = .byTruncatingTail

        ratingLabel.font = .systemFont(ofSize: 10, weight: .bold)
        ratingLabel.textColor = .systemYellow
        ratingLabel.alignment = .center
        ratingLabel.wantsLayer = true
        ratingLabel.layer?.cornerRadius = 3
        ratingLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        ratingLabel.setContentHuggingPriority(.required, for: .horizontal)

        colorDot.wantsLayer = true
        colorDot.layer?.cornerRadius = 5
        colorDot.layer?.borderWidth = 1
        colorDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        metadataErrorIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "メタデータエラー"
        )
        metadataErrorIcon.contentTintColor = .systemOrange

        [imageContainer, filenameLabel, detailLabel, sceneLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.addSubview(iconView)
        [ratingLabel, colorDot, metadataErrorIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            imageContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            imageContainer.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            imageContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            imageContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -7),
            imageContainer.heightAnchor.constraint(equalToConstant: 91),
            iconView.topAnchor.constraint(equalTo: imageContainer.topAnchor, constant: 4),
            iconView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor, constant: 4),
            iconView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: -4),
            iconView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -4),
            ratingLabel.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor, constant: 5),
            ratingLabel.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -5),
            ratingLabel.heightAnchor.constraint(equalToConstant: 17),
            ratingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
            colorDot.topAnchor.constraint(equalTo: imageContainer.topAnchor, constant: 5),
            colorDot.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: -5),
            colorDot.widthAnchor.constraint(equalToConstant: 10),
            colorDot.heightAnchor.constraint(equalToConstant: 10),
            metadataErrorIcon.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: -5),
            metadataErrorIcon.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -5),
            metadataErrorIcon.widthAnchor.constraint(equalToConstant: 14),
            metadataErrorIcon.heightAnchor.constraint(equalToConstant: 14),
            filenameLabel.topAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: 7),
            filenameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            sceneLabel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor),
            sceneLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor, constant: 6),
            sceneLabel.trailingAnchor.constraint(equalTo: filenameLabel.trailingAnchor),
        ])
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedURL = nil
        representedRelativePath = nil
        iconView.image = nil
        filenameLabel.stringValue = ""
        detailLabel.stringValue = ""
        sceneLabel.stringValue = ""
        isExcluded = false
        currentSceneName = nil
        currentRating = .unrated
        ratingIsLoaded = false
        ratingIsExplicit = false
        currentLabelNumber = 0
        labelIsLoaded = false
        metadataIsLoading = false
        hasMetadataError = false
        hasMetadataWarning = false
        isReviewContext = false
        ratingLabel.stringValue = ""
        ratingLabel.isHidden = true
        colorDot.isHidden = true
        metadataErrorIcon.isHidden = true
        metadataErrorIcon.toolTip = nil
        view.toolTip = nil
        metadataErrorDetail = nil
        metadataWarningDetail = nil
        card.pressHandler = nil
        selectionAccessibilityAction = nil
        view.setAccessibilityCustomActions(nil)
    }

    deinit {
        // Removing the collection view (for example when switching workspaces) is not guaranteed
        // to send every item through `prepareForReuse`. Do not leave an invisible cell subscribed
        // to a coalesced Quick Look/ImageIO request until that decode happens to finish.
        thumbnailTask?.cancel()
    }

    func configure(
        asset: AppAsset,
        sceneName: String?,
        isExcluded: Bool,
        rating: AdobeRating,
        ratingIsLoaded: Bool,
        ratingIsExplicit: Bool,
        labelNumber: Int,
        labelIsLoaded: Bool,
        hasMetadataError: Bool,
        metadataErrorMessage: String?,
        metadataWarningMessage: String?,
        metadataIsLoading: Bool,
        isReviewContext: Bool,
        mediaPipeline: MediaPipeline?,
        thumbnailPixelSize: MediaPixelSize = MediaRequestSizingPolicy
            .assetTileThumbnailPixelSize(backingScaleFactor: 2),
        interactionsAreEnabled: Bool,
        onToggleSelection: @escaping () -> Bool,
        onOpen: @escaping (AppAsset) -> Void
    ) {
        thumbnailTask?.cancel()
        representedURL = asset.url.standardizedFileURL
        representedRelativePath = asset.relativePath
        let symbolName = asset.category.systemImage
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: asset.category.rawValue)
        iconView.contentTintColor = .secondaryLabelColor
        filenameLabel.stringValue = asset.filename
        detailLabel.stringValue = "\(asset.category.rawValue) · \(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))"
        self.isReviewContext = isReviewContext
        updateStatus(sceneName: sceneName, isExcluded: isExcluded)
        updateMetadata(
            rating: rating,
            ratingIsLoaded: ratingIsLoaded,
            ratingIsExplicit: ratingIsExplicit,
            labelNumber: labelNumber,
            labelIsLoaded: labelIsLoaded,
            hasError: hasMetadataError,
            errorMessage: metadataErrorMessage,
            warningMessage: metadataWarningMessage,
            metadataIsLoading: metadataIsLoading
        )
        view.toolTip = asset.relativePath
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(
            "\(asset.filename)、\(asset.category.rawValue)\(!isReviewContext && isExcluded ? "、取り込み除外" : "")"
        )
        card.pressHandler = { onOpen(asset) }
        let selectionAction = NSAccessibilityCustomAction(
            name: "選択を切り替える",
            handler: { [weak self] in
                guard self?.card.interactionsAreEnabled == true else { return false }
                return onToggleSelection()
            }
        )
        selectionAccessibilityAction = selectionAction
        updateInteractionsEnabled(interactionsAreEnabled)
        updateAccessibilityHelp()
        updateSelectionAppearance()

        guard let mediaPipeline else { return }
        let requestedURL = asset.url.standardizedFileURL
        thumbnailTask = Task { [weak self] in
            do {
                let mediaImage = try await mediaPipeline.thumbnail(
                    for: requestedURL,
                    pixelSize: thumbnailPixelSize,
                    priority: .visible
                )
                try Task.checkCancellation()
                guard let self, representedURL == requestedURL else { return }
                iconView.image = NSImage(cgImage: mediaImage.cgImage, size: .zero)
                iconView.contentTintColor = nil
            } catch {
                // The category icon remains visible; unsupported/cancelled thumbnails are non-fatal.
            }
        }
    }

    func updateStatus(sceneName: String?, isExcluded: Bool) {
        self.isExcluded = isExcluded
        currentSceneName = sceneName
        sceneLabel.stringValue = isExcluded ? "取り込み除外" : (sceneName ?? "")
        sceneLabel.textColor = isExcluded ? .systemOrange : .controlAccentColor
        sceneLabel.isHidden = !isExcluded && sceneName == nil
        updateSelectionAppearance()
    }

    func updateMetadata(
        rating: AdobeRating,
        ratingIsLoaded: Bool,
        ratingIsExplicit: Bool,
        labelNumber: Int,
        labelIsLoaded: Bool,
        hasError: Bool,
        errorMessage: String?,
        warningMessage: String?,
        metadataIsLoading: Bool
    ) {
        currentRating = rating
        self.ratingIsLoaded = ratingIsLoaded
        self.ratingIsExplicit = ratingIsExplicit
        currentLabelNumber = labelNumber
        self.labelIsLoaded = labelIsLoaded
        self.metadataIsLoading = metadataIsLoading
        hasMetadataError = hasError
        hasMetadataWarning = warningMessage != nil
        metadataErrorDetail = errorMessage
        metadataWarningDetail = warningMessage
        if isReviewContext {
            let presentation = ReviewRatingBadgePresentation.make(
                rating: rating,
                isLoaded: ratingIsLoaded,
                isExplicit: ratingIsExplicit,
                isLoading: metadataIsLoading && !hasError
            )
            ratingLabel.stringValue = presentation.text
            ratingLabel.textColor = switch presentation.tone {
            case .secondary: .secondaryLabelColor
            case .rejected: .systemRed
            case .rated: .systemYellow
            }
            ratingLabel.isHidden = false
        } else {
            ratingLabel.stringValue = ""
            ratingLabel.isHidden = true
        }

        let colors = NSWorkspace.shared.fileLabelColors
        if labelIsLoaded, labelNumber > 0, labelNumber < colors.count {
            colorDot.layer?.backgroundColor = colors[labelNumber].cgColor
            colorDot.isHidden = false
        } else {
            colorDot.layer?.backgroundColor = NSColor.clear.cgColor
            colorDot.isHidden = true
        }
        if hasError {
            metadataErrorIcon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "メタデータエラー"
            )
            metadataErrorIcon.contentTintColor = .systemOrange
            metadataErrorIcon.toolTip = [errorMessage, warningMessage]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            metadataErrorIcon.isHidden = false
        } else if let warningMessage {
            metadataErrorIcon.image = NSImage(
                systemSymbolName: "info.circle.fill",
                accessibilityDescription: "互換性に関する注意"
            )
            metadataErrorIcon.contentTintColor = .systemYellow
            metadataErrorIcon.toolTip = warningMessage
            metadataErrorIcon.isHidden = false
        } else {
            metadataErrorIcon.isHidden = true
            metadataErrorIcon.toolTip = nil
        }
        updateAccessibilityHelp()
        updateSelectionAppearance()
    }

    func updateInteractionsEnabled(_ isEnabled: Bool) {
        card.interactionsAreEnabled = isEnabled
        view.setAccessibilityEnabled(isEnabled)
        view.setAccessibilityCustomActions(
            isEnabled ? selectionAccessibilityAction.map { [$0] } : nil
        )
    }

    private func updateSelectionAppearance() {
        card.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : (isExcluded
                ? NSColor.systemOrange.withAlphaComponent(0.8).cgColor
                : NSColor.separatorColor.withAlphaComponent(0.55).cgColor)
        card.layer?.borderWidth = isSelected ? 2 : 1
        card.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
            : (isExcluded ? NSColor.systemOrange.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor)
        imageContainer.alphaValue = isExcluded ? 0.5 : 1
        view.setAccessibilitySelected(isSelected)
        var values: [String?] = [isSelected ? "選択中" : "未選択"]
        if !isReviewContext {
            values.append(isExcluded ? "取り込み除外" : "取り込み対象")
            values.append(currentSceneName.map { "割り当てシーン \($0)" })
        } else {
            values.append(accessibilityRatingDescription)
            values.append(accessibilityColorDescription)
            values.append(hasMetadataError ? metadataErrorDetail ?? "メタデータエラー" : nil)
            values.append(hasMetadataWarning ? metadataWarningDetail ?? "互換性に関する注意" : nil)
        }
        view.setAccessibilityValue(values.compactMap { $0 }.joined(separator: "、"))
    }

    private var accessibilityRatingDescription: String {
        ReviewRatingBadgePresentation.make(
            rating: currentRating,
            isLoaded: ratingIsLoaded,
            isExplicit: ratingIsExplicit,
            isLoading: metadataIsLoading && !hasMetadataError
        ).accessibilityDescription
    }

    private var accessibilityColorDescription: String {
        guard labelIsLoaded else {
            return metadataIsLoading && !hasMetadataError
                ? "Finderカラーを読み込み中"
                : "Finderカラーを取得できません"
        }
        let labels = NSWorkspace.shared.fileLabels
        guard currentLabelNumber > 0, currentLabelNumber < labels.count else {
            return "Finderカラーなし"
        }
        return "Finderカラー \(labels[currentLabelNumber])"
    }

    private func updateAccessibilityHelp() {
        let details = [representedRelativePath, metadataErrorDetail, metadataWarningDetail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        view.setAccessibilityHelp(details.joined(separator: "。"))
    }
}
