import SwiftUI

enum AssetBrowserContext: Equatable, Sendable {
    case ingest
    case review
}

struct AssetBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchIsFocused: Bool
    let context: AssetBrowserContext

    init(context: AssetBrowserContext = .ingest) {
        self.context = context
    }

    private var allAssets: [AppAsset] {
        context == .review ? model.reviewAssets : model.assets
    }

    private var browserProjection: AssetBrowserProjection {
        context == .review ? model.reviewBrowserProjection : model.ingestBrowserProjection
    }

    private var sourceURL: URL? {
        context == .review ? model.reviewSourceURL : model.sourceURL
    }

    private var selectedIDs: Set<UUID> {
        context == .review ? model.reviewSelectedAssetIDs : model.selectedAssetIDs
    }

    private var searchText: Binding<String> {
        Binding(
            get: {
                context == .review
                    ? model.reviewAssetSearchText
                    : model.ingestAssetSearchText
            },
            set: { value in
                if context == .review {
                    model.reviewAssetSearchText = value
                } else {
                    model.ingestAssetSearchText = value
                }
            }
        )
    }

    private var category: Binding<AssetCategory?> {
        Binding(
            get: {
                context == .review
                    ? model.reviewAssetCategoryFilter
                    : model.ingestAssetCategoryFilter
            },
            set: { value in
                if context == .review {
                    model.reviewAssetCategoryFilter = value
                } else {
                    model.ingestAssetCategoryFilter = value
                }
            }
        )
    }

    private var currentSearchText: String { searchText.wrappedValue }
    private var currentCategory: AssetCategory? { category.wrappedValue }

    private var isScanning: Bool {
        context == .review ? model.reviewIsScanning : model.phase == .scanning
    }

    private var hasActiveFilter: Bool {
        currentCategory != nil || !currentSearchText.isEmpty
    }

    private var canFocusSearch: Bool {
        model.canPresentMediaPreview
            && model.previewAsset == nil
            && !model.showAssetExclusionConfirmation
            && !model.showEmptyDirectoryExclusionConfirmation
            && !model.showCardEraseConfirmation
    }

    var body: some View {
        let projection = browserProjection
        let filteredAssets = projection.visibleAssets
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("ファイル名・フォルダを検索", text: searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .accessibilityLabel("素材をファイル名またはフォルダ名で検索")
                    .help("ファイル名・フォルダ名で絞り込み（⌘F）")
                Picker("種類", selection: category) {
                    Text("すべて").tag(AssetCategory?.none)
                    ForEach(AssetCategory.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                .frame(width: 110)
                if hasActiveFilter {
                    Button {
                        clearFilters()
                    } label: {
                        Label("絞り込み解除", systemImage: "line.3.horizontal.decrease.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .help("検索とカテゴリの絞り込みを解除")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .disabled(!model.canPresentMediaPreview)

            HStack(spacing: 8) {
                Text("表示 \(filteredAssets.count) / 全 \(allAssets.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !selectedIDs.isEmpty {
                    Text("選択 \(selectedIDs.count)")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .accessibilityLabel("\(selectedIDs.count)項目を選択中")
                }
                Spacer(minLength: 4)
                Button("表示中を選択") {
                    setSelectedIDs(projection.visibleAssetIDs)
                }
                .disabled(filteredAssets.isEmpty)
                .help("絞り込み後の表示中の素材をすべて選択（⌘A）")
                Button("選択解除") { setSelectedIDs([]) }
                    .disabled(selectedIDs.isEmpty)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .disabled(!model.canPresentMediaPreview)

            Divider()

            if isScanning {
                Spacer()
                ProgressView(context == .review ? "アーカイブを読み込み中…" : "素材をスキャン中…")
                Spacer()
            } else if filteredAssets.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: context == .review ? "star.square.on.square" : "photo.on.rectangle.angled")
                        .font(.system(size: 42))
                        .foregroundStyle(.tertiary)
                    Text(emptyStateMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if sourceURL == nil {
                        Button(context == .review ? "アーカイブを選択…" : "撮影カード／フォルダを選択…") {
                            if context == .review {
                                model.chooseReviewSource()
                            } else {
                                model.chooseSource()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(context == .review
                            ? !model.canStartExclusiveOperation
                            : !model.canStartIngestSourceScan)
                        Text(context == .review
                            ? "取り込み済みの素材に星評価とFinderカラーを付けられます"
                            : "フォルダをこの画面へドラッグして読み込むこともできます")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if sourceURL != nil, hasActiveFilter, !allAssets.isEmpty {
                        Button("絞り込みを解除") {
                            clearFilters()
                        }
                        .disabled(!model.canPresentMediaPreview)
                    }
                    if sourceURL != nil, allAssets.isEmpty {
                        HStack {
                            Button("再スキャン") {
                                if context == .review { model.rescanReviewSource() }
                                else { model.rescan() }
                            }
                            Button("別のフォルダを選択…") {
                                if context == .review { model.chooseReviewSource() }
                                else { model.chooseSource() }
                            }
                        }
                        .disabled(context == .review
                            ? !model.canStartExclusiveOperation
                            : !model.canStartIngestSourceScan)
                    }
                }
                .padding(24)
                Spacer()
            } else {
                AssetCollectionView(
                    assets: filteredAssets,
                    contentRevision: projection.revision,
                    selectionRevision: context == .review
                        ? model.reviewCollectionSelectionRevision
                        : model.ingestCollectionSelectionRevision,
                    selectedIDs: selectedIDs,
                    excludedIDs: context == .ingest ? model.explicitlyExcludedAssetIDs : [],
                    mediaPipeline: model.mediaPipeline,
                    sceneAssignments: context == .ingest ? model.sceneAssignments : [:],
                    sceneNamesByID: context == .ingest ? model.sceneNamesByID : [:],
                    ratings: context == .review ? model.reviewRatings : [:],
                    ratingLoadedIDs: context == .review ? model.reviewRatingLoadedAssetIDs : [],
                    ratingExplicitIDs: context == .review ? model.reviewRatingExplicitAssetIDs : [],
                    labelNumbers: context == .review ? model.reviewLabelNumbers : [:],
                    labelLoadedIDs: context == .review ? model.reviewLabelLoadedAssetIDs : [],
                    metadataErrorIDs: context == .review ? model.reviewMetadataErrorIDs : [],
                    metadataErrors: context == .review ? model.reviewMetadataErrors : [:],
                    metadataWarnings: context == .review ? model.reviewMetadataWarnings : [:],
                    metadataRevision: context == .review
                        ? model.reviewCollectionMetadataRevision
                        : model.ingestCollectionMetadataRevision,
                    thumbnailReloadGeneration: context == .review
                        ? model.reviewThumbnailReloadGeneration
                        : model.ingestThumbnailReloadGeneration,
                    metadataIsLoading: context == .review && model.reviewMetadataIsLoading,
                    isReviewContext: context == .review,
                    onSelectionChange: setSelectedIDs,
                    onOpen: model.presentPreview
                )
                .disabled(!model.canPresentMediaPreview)
            }
        }
        .focusedSceneValue(\.umisSearchAction, canFocusSearch ? {
            searchIsFocused = true
        } : nil)
        .onChange(of: projection.revision) { _ in
            // A hidden selection must never receive a scene assignment or metadata mutation by
            // surprise. Filtering therefore narrows the active selection to what is still visible.
            let narrowed = selectedIDs.intersection(projection.visibleAssetIDs)
            if narrowed != selectedIDs {
                setSelectedIDs(narrowed)
            }
        }
    }

    private var emptyStateMessage: String {
        if sourceURL == nil {
            return context == .review
                ? "評価する取り込み済みアーカイブを選択してください"
                : "撮影カードまたは素材フォルダを選択してください"
        }
        if hasActiveFilter, !allAssets.isEmpty {
            return "現在の絞り込みに一致する素材がありません"
        }
        if context == .ingest, model.phase.failureMessage != nil {
            return "素材を安全に読み込めませんでした。画面下部の理由と必要な対応をご確認ください"
        }
        return context == .review
            ? "評価に対応する素材が見つかりませんでした。フォルダや読込時の案内をご確認ください"
            : "対応する素材が見つかりませんでした。フォルダやスキャン警告をご確認ください"
    }

    private func setSelectedIDs(_ ids: Set<UUID>) {
        if context == .review {
            model.selectReviewAssets(ids)
        } else {
            model.selectedAssetIDs = ids.intersection(model.ingestAllAssetIDs)
        }
    }

    private func clearFilters() {
        searchText.wrappedValue = ""
        category.wrappedValue = nil
    }
}
