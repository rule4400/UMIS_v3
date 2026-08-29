import SwiftUI
import UMISCore

struct SettingsWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            ingestSection
            categorySection
            lanSection
            sdManagementSection
            mediaCacheSection
            distributionSection
        }
        // Settings is a separate window, so it must participate in the same filesystem/media/LAN
        // admission boundary as every workspace instead of checking only ingest and rename phases.
        .disabled(!model.canStartExclusiveOperation)
        .formStyle(.grouped)
        .navigationTitle("設定")
    }

    private var ingestSection: some View {
        Section("取り込み") {
            Toggle("検証完了後にカード初期化導線を表示", isOn: $model.cardInitializationEnabled)
                .disabled(!model.cardEraseRuntimeUnlocked)
            Text(model.cardEraseAvailabilityMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var categorySection: some View {
        Section("カテゴリと走査ポリシー") {
            ForEach(model.configuredCategories, id: \.id.rawValue) { category in
                CategorySettingsRow(category: category)
            }
            Toggle(
                "隠し素材も通常対象として扱う",
                isOn: Binding(
                    get: { model.includesHiddenFiles },
                    set: { model.setIncludesHiddenFiles($0) }
                )
            )
            TextField(
                "要確認フォルダ名（カンマ区切り）",
                text: Binding(
                    get: { model.excludedFolderNamesText },
                    set: { model.setExcludedFolderNames($0) }
                )
            )
            Text("無効カテゴリ、隠し素材、指定フォルダ内の素材も黙って捨てず一覧に出し、今回取り込むか明示除外するかを確定します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lanSection: some View {
        Section("LANシーン共有") {
            if let coordinator = model.lanSceneCatalog {
                LANSceneCatalogSettingsView(coordinator: coordinator)
                    .environmentObject(model)
            } else {
                Label("KeychainまたはLAN保存領域を初期化できません", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sdManagementSection: some View {
        Section("SD管理システム") {
            Toggle("SD管理連携", isOn: $model.sdManagementEnabled)
                .disabled(true)
            Text("専用integration APIが未実装のため、このbuildではDisabled Gatewayに固定されています。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mediaCacheSection: some View {
        Section("メディアキャッシュ") {
            LabeledContent("使用量", value: model.mediaCacheSummary)
            HStack {
                Button("再計測") { model.refreshMediaCacheSummary() }
                Button("すべて消去", role: .destructive) { model.clearMediaCaches() }
                    .disabled(!model.canClearMediaCaches)
                    .help(
                        model.captureDateMetadataIsLoading
                            ? "撮影日時の解析完了後に消去できます"
                            : "表示中のプレビューを閉じ、派生キャッシュをすべて消去します"
                    )
            }
            if model.captureDateMetadataIsLoading {
                Label("撮影日時を解析中のため、キャッシュ消去を保留しています", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(model.mediaCacheStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("thumbnail、preview、posterとmetadataを同じquota／LRU方針で管理します。原本と取り込み済み素材は削除しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var distributionSection: some View {
        Section("配布") {
            LabeledContent("Bundle ID", value: "jp.rinkan.umis")
            LabeledContent("署名", value: "Developer ID必須（開発時のみad-hoc可）")
            LabeledContent("最小macOS", value: "13.0（暫定）")
        }
    }
}

private struct CategorySettingsRow: View {
    @EnvironmentObject private var model: AppModel
    let category: ProjectCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                category.displayName,
                isOn: Binding(
                    get: { category.isEnabled },
                    set: { model.setCategoryEnabled(id: category.id.rawValue, isEnabled: $0) }
                )
            )
            HStack {
                Text("出力フォルダ")
                    .foregroundStyle(.secondary)
                TextField(
                    "フォルダ名",
                    text: Binding(
                        get: { category.folderName },
                        set: { model.setCategoryFolderName(id: category.id.rawValue, folderName: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
            Text(category.extensions.sorted().map { "." + $0 }.joined(separator: "  "))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
