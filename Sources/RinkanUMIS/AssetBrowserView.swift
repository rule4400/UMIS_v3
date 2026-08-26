import SwiftUI

struct AssetBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var category: AssetCategory?

    private var filteredAssets: [AppAsset] {
        model.assets.filter { asset in
            let categoryMatches = category == nil || asset.category == category
            let searchMatches = searchText.isEmpty || asset.filename.localizedCaseInsensitiveContains(searchText)
            return categoryMatches && searchMatches
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("ファイル名を検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("種類", selection: $category) {
                    Text("すべて").tag(AssetCategory?.none)
                    ForEach(AssetCategory.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                .frame(width: 110)
                Button("全選択") { model.selectAll() }
                Button("解除") { model.clearSelection() }
            }
            .padding(10)

            Divider()

            if model.phase == .scanning {
                Spacer()
                ProgressView("素材をスキャン中…")
                Spacer()
            } else if filteredAssets.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 42))
                        .foregroundStyle(.tertiary)
                    Text(model.sourceURL == nil ? "撮影カードまたは素材フォルダを選択してください" : "表示する素材がありません")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                AssetCollectionView(
                    assets: filteredAssets,
                    selectedIDs: model.selectedAssetIDs,
                    excludedIDs: model.explicitlyExcludedAssetIDs,
                    mediaPipeline: model.mediaPipeline,
                    sceneNames: Dictionary(
                        uniqueKeysWithValues: filteredAssets.compactMap { asset in
                            model.assignedScene(for: asset.id).map { (asset.id, $0.name) }
                        }
                    ),
                    onSelectionChange: { model.selectedAssetIDs = $0 },
                    onOpen: model.presentPreview
                )
            }
        }
        .disabled(!model.canPresentMediaPreview)
    }
}
