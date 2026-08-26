import AppKit
import SwiftUI
import UMISMedia

struct AssetCollectionView: NSViewRepresentable {
    let assets: [AppAsset]
    let selectedIDs: Set<UUID>
    let excludedIDs: Set<UUID>
    let mediaPipeline: MediaPipeline?
    let sceneNames: [UUID: String]
    let onSelectionChange: (Set<UUID>) -> Void
    let onOpen: (AppAsset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 174, height: 154)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.register(
            AssetCollectionItem.self,
            forItemWithIdentifier: AssetCollectionItem.reuseIdentifier
        )

        context.coordinator.attach(to: collectionView)
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
            selectedIDs: selectedIDs,
            sceneNames: sceneNames,
            excludedIDs: excludedIDs
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        enum Section: Hashable { case main }

        var parent: AssetCollectionView
        private weak var collectionView: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Section, UUID>?
        private var assetsByID: [UUID: AppAsset] = [:]
        private var sceneNames: [UUID: String] = [:]
        private var excludedIDs: Set<UUID> = []
        private var applyingSelection = false
        private var prefetchTasks: [UUID: Task<Void, Never>] = [:]
        private var currentAssetIDs: [UUID] = []
        private var hadMediaPipeline = false

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
                item.configure(
                    asset: asset,
                    sceneName: sceneNames[identifier],
                    isExcluded: excludedIDs.contains(identifier),
                    mediaPipeline: parent.mediaPipeline
                )
                return item
            }
        }

        func update(
            assets: [AppAsset],
            selectedIDs: Set<UUID>,
            sceneNames: [UUID: String],
            excludedIDs: Set<UUID>
        ) {
            let nextIDs = assets.map(\.id)
            let previousSceneNames = self.sceneNames
            let previousExcludedIDs = self.excludedIDs
            assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            self.sceneNames = sceneNames
            self.excludedIDs = excludedIDs
            let hasMediaPipeline = parent.mediaPipeline != nil
            let pipelineBecameAvailable = hasMediaPipeline && !hadMediaPipeline
            hadMediaPipeline = hasMediaPipeline

            let validIDs = Set(nextIDs)
            let removedPrefetchIDs = prefetchTasks.keys.filter { !validIDs.contains($0) }
            for identifier in removedPrefetchIDs {
                prefetchTasks.removeValue(forKey: identifier)?.cancel()
            }

            if nextIDs != currentAssetIDs {
                currentAssetIDs = nextIDs
                var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
                snapshot.appendSections([.main])
                snapshot.appendItems(nextIDs, toSection: .main)
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                    self?.applySelection(selectedIDs)
                }
                return
            }

            if pipelineBecameAvailable, var snapshot = dataSource?.snapshot(), !nextIDs.isEmpty {
                snapshot.reloadItems(nextIDs)
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                    self?.applySelection(selectedIDs)
                }
                return
            }

            if previousSceneNames != sceneNames || previousExcludedIDs != excludedIDs,
               let collectionView,
               let dataSource {
                for indexPath in collectionView.indexPathsForVisibleItems() {
                    guard let identifier = dataSource.itemIdentifier(for: indexPath),
                          let item = collectionView.item(at: indexPath) as? AssetCollectionItem
                    else { continue }
                    item.updateStatus(
                        sceneName: sceneNames[identifier],
                        isExcluded: excludedIDs.contains(identifier)
                    )
                }
            }
            applySelection(selectedIDs)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            publishSelection(from: collectionView)
        }

        @objc func openDoubleClickedItem(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
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

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let dataSource, let pipeline = parent.mediaPipeline else { return }
            for indexPath in indexPaths {
                guard let identifier = dataSource.itemIdentifier(for: indexPath),
                      let asset = assetsByID[identifier],
                      prefetchTasks[identifier] == nil
                else { continue }
                prefetchTasks[identifier] = Task { [weak self] in
                    _ = try? await pipeline.thumbnail(
                        for: asset.url,
                        pixelSize: MediaPixelSize(width: 348, height: 182),
                        priority: .nearVisible
                    )
                    self?.prefetchTasks.removeValue(forKey: identifier)
                }
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            guard let dataSource else { return }
            for indexPath in indexPaths {
                guard let identifier = dataSource.itemIdentifier(for: indexPath) else { continue }
                prefetchTasks.removeValue(forKey: identifier)?.cancel()
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
            applyingSelection = true
            let indexPaths = Set(selectedIDs.compactMap { dataSource.indexPath(for: $0) })
            collectionView.selectionIndexPaths = indexPaths
            applyingSelection = false
        }

        private func publishSelection(from collectionView: NSCollectionView) {
            guard !applyingSelection, let dataSource else { return }
            let identifiers = Set(
                collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
            )
            parent.onSelectionChange(identifiers)
        }

        deinit {
            for task in prefetchTasks.values { task.cancel() }
        }
    }
}

@MainActor
private final class AssetCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AssetCollectionItem")

    private let card = NSView()
    private let imageContainer = NSView()
    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sceneLabel = NSTextField(labelWithString: "")
    private var thumbnailTask: Task<Void, Never>?
    private var representedURL: URL?
    private var isExcluded = false

    override func loadView() {
        view = card
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        card.layer?.borderWidth = 1

        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = 7
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

        [imageContainer, filenameLabel, detailLabel, sceneLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.addSubview(iconView)

        NSLayoutConstraint.activate([
            imageContainer.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            imageContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            imageContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -7),
            imageContainer.heightAnchor.constraint(equalToConstant: 91),
            iconView.topAnchor.constraint(equalTo: imageContainer.topAnchor, constant: 4),
            iconView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor, constant: 4),
            iconView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor, constant: -4),
            iconView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: -4),
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
        iconView.image = nil
        filenameLabel.stringValue = ""
        detailLabel.stringValue = ""
        sceneLabel.stringValue = ""
        isExcluded = false
        view.toolTip = nil
    }

    func configure(
        asset: AppAsset,
        sceneName: String?,
        isExcluded: Bool,
        mediaPipeline: MediaPipeline?
    ) {
        thumbnailTask?.cancel()
        representedURL = asset.url.standardizedFileURL
        let symbolName = asset.category.systemImage
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: asset.category.rawValue)
        iconView.contentTintColor = .secondaryLabelColor
        filenameLabel.stringValue = asset.filename
        detailLabel.stringValue = "\(asset.category.rawValue) · \(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))"
        updateStatus(sceneName: sceneName, isExcluded: isExcluded)
        view.toolTip = asset.relativePath
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(
            "\(asset.filename)、\(asset.category.rawValue)\(isExcluded ? "、取り込み除外" : "")"
        )
        updateSelectionAppearance()

        guard let mediaPipeline else { return }
        let requestedURL = asset.url.standardizedFileURL
        thumbnailTask = Task { [weak self] in
            do {
                let mediaImage = try await mediaPipeline.thumbnail(
                    for: requestedURL,
                    pixelSize: MediaPixelSize(width: 348, height: 182),
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
        sceneLabel.stringValue = isExcluded ? "取り込み除外" : (sceneName ?? "")
        sceneLabel.textColor = isExcluded ? .systemOrange : .controlAccentColor
        sceneLabel.isHidden = !isExcluded && sceneName == nil
        updateSelectionAppearance()
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
        view.setAccessibilityValue(
            "\(isSelected ? "選択中" : "未選択")、\(isExcluded ? "取り込み除外" : "取り込み対象")"
        )
    }
}
