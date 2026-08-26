import SwiftUI

struct IngestWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourceConfigurationView()
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)

                AssetBrowserView()
                    .frame(minWidth: 500)

                if model.showInspector {
                    SceneAssignmentView()
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                        .disabled(
                            model.phase.isBusy
                                || model.renameIsBusy
                                || model.projectOperationInFlight
                        )
                }
            }

            Divider()
            IngestActionBar()
        }
        .navigationTitle("取り込み")
        .toolbar {
            ToolbarItemGroup {
                Button { model.rescan() } label: {
                    Label("再スキャン", systemImage: "arrow.clockwise")
                }
                .disabled(model.sourceURL == nil || model.phase.isBusy)

                Button { model.showInspector.toggle() } label: {
                    Label("シーン", systemImage: "sidebar.right")
                }
            }
        }
    }
}

private struct SourceConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDeleteProjectConfirmation = false

    var body: some View {
        Form {
            Section("プロジェクト") {
                Picker(
                    "保存済み",
                    selection: Binding(
                        get: { model.selectedStoredProjectID },
                        set: { next in
                            model.selectedStoredProjectID = next
                            model.loadStoredProject(id: next)
                        }
                    )
                ) {
                    Text("新規／未選択").tag(UUID?.none)
                    ForEach(model.availableProjects, id: \.id.rawValue) { project in
                        Text(project.name).tag(Optional(project.id.rawValue))
                    }
                }
                TextField("プロジェクト名", text: $model.projectName)
                TextField("会場", text: $model.locationName)
                HStack {
                    Button("新規") { model.createNewProject() }
                    Button("保存") { model.saveCurrentProject() }
                    Spacer()
                    Button("削除…", role: .destructive) {
                        showDeleteProjectConfirmation = true
                    }
                    .disabled(model.selectedStoredProjectID == nil)
                }
                HStack {
                    Button("旧UMIS JSONを移行…") { model.importLegacyProject() }
                    Button("直前の削除を復旧") { model.recoverLastDeletedProject() }
                        .disabled(!model.canRecoverLastDeletedProject)
                }
                Text(model.projectPersistenceStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.phase.isBusy || model.renameIsBusy || model.projectOperationInFlight)

            Section("撮影情報") {
                TextField("撮影者", text: $model.photographer)
                TextField("カードNo", text: $model.cardNumber)
                    .onSubmit { model.resolveLocalCardConfiguration() }
                Text("保存済みのカードNoと一致すると、プロジェクト内の撮影者を安定IDで解決します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("ソース") {
                PathButton(
                    title: "撮影カード／フォルダ",
                    url: model.sourceURL,
                    action: model.chooseSource
                )
                Button("安全に取り出す") {
                    model.ejectActiveSource()
                }
                .disabled(!model.canEjectActiveSource)
                if let safeEjectAvailabilityMessage = model.safeEjectAvailabilityMessage {
                    Text(safeEjectAvailabilityMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if model.cardInitializationEnabled {
                Section("カード初期化") {
                    Text(model.cardInitializationStatus)
                        .font(.caption)
                        .foregroundStyle(model.canPrepareCardInitialization ? Color.green : Color.secondary)
                    Button("最終全再読検証を開始…") {
                        model.prepareCardInitialization()
                    }
                    .disabled(!model.canPrepareCardInitialization)
                    Text("コピー完了だけでは有効になりません。全Required Setの再読SHA-256と同一物理媒体の確認が必要です。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("保存先") {
                PathButton(
                    title: "アーカイブ先",
                    url: model.destinationURL,
                    action: model.chooseDestination
                )
            }

            if !model.scanErrors.isEmpty {
                Section("スキャン警告") {
                    Label("\(model.scanErrors.count)件の読取警告", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !model.emptyDirectoryReviewPaths.isEmpty {
                Section("空フォルダ") {
                    Text(
                        "\(model.emptyDirectoryReviewPaths.count)件中 "
                            + "\(model.reviewedEmptyDirectoryCount)件確認済み"
                    )
                    .font(.caption)
                    .foregroundStyle(model.unreviewedEmptyDirectoryCount == 0 ? Color.green : Color.orange)
                    Button("再作成しない空フォルダを確認…") {
                        model.reviewEmptyDirectoryExclusions()
                    }
                }
            }
        }
        .disabled(model.phase.isBusy || model.renameIsBusy || model.projectOperationInFlight)
        .formStyle(.grouped)
        .disabled(model.renameIsBusy)
        .sheet(isPresented: $model.showCardEraseConfirmation) {
            CardEraseConfirmationView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showAssetExclusionConfirmation) {
            AssetExclusionConfirmationView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showEmptyDirectoryExclusionConfirmation) {
            EmptyDirectoryExclusionConfirmationView()
                .environmentObject(model)
        }
        .confirmationDialog(
            "保存済みプロジェクトを削除しますか？",
            isPresented: $showDeleteProjectConfirmation
        ) {
            Button("復旧可能なTrashへ移動", role: .destructive) {
                model.deleteCurrentStoredProject()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("原本素材は削除しません。プロジェクトJSONはアプリ管理のTrashへ移動します。")
        }
    }
}

struct PathButton: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                Label(url == nil ? "選択…" : "変更…", systemImage: "folder")
            }
            Text(url?.path(percentEncoded: false) ?? title)
                .font(.caption)
                .foregroundStyle(url == nil ? .tertiary : .secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

private struct SceneAssignmentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("シーン")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(1 ... 4, id: \.self) { day in
                        Button("\(day)日目へ追加") { model.addScene(day: day) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .disabled(model.phase.isBusy || model.renameIsBusy)
            }
            .padding(12)

            Divider()

            List(selection: $model.selectedSceneID) {
                ForEach(model.scenes) { scene in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(scene.code)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "シーン名",
                                    text: Binding(
                                        get: {
                                            model.scenes.first(where: { $0.id == scene.id })?.name
                                                ?? scene.name
                                        },
                                        set: { model.updateSceneName(id: scene.id, name: $0) }
                                    )
                                )
                                    .textFieldStyle(.plain)
                            }
                            let count = model.sceneAssignments.values.filter { $0 == scene.id }.count
                            Text("\(count)項目")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(scene.id)
                    .contextMenu {
                        Button("上へ移動") { model.moveScene(scene, offset: -1) }
                        Button("下へ移動") { model.moveScene(scene, offset: 1) }
                        Divider()
                        if scene.day != 0 {
                            Button("削除", role: .destructive) { model.removeScene(scene) }
                        }
                    }
                }
            }
            .disabled(model.phase.isBusy || model.renameIsBusy)

            Divider()

            VStack(spacing: 8) {
                Button("選択素材を割り当て") { model.assignSelectionToCurrentScene() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(
                        model.phase.isBusy || model.renameIsBusy
                            || model.selectedAssetIDs.isEmpty || model.selectedSceneID == nil
                    )
                Button("選択素材の割り当てを解除") { model.removeAssignmentsForSelection() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase.isBusy || model.renameIsBusy || model.selectedAssetIDs.isEmpty)
                Divider()
                Button("選択素材を今回の取り込みから除外") {
                    model.excludeSelectionFromIngest()
                }
                .frame(maxWidth: .infinity)
                .disabled(model.phase.isBusy || model.renameIsBusy || model.selectedAssetIDs.isEmpty)
                Button("選択素材を取り込み対象に戻す") {
                    model.includeSelectionInIngest()
                }
                .frame(maxWidth: .infinity)
                .disabled(
                    model.phase.isBusy || model.renameIsBusy
                        || model.selectedAssetIDs.isDisjoint(with: model.explicitlyExcludedAssetIDs)
                )
                if !model.explicitlyExcludedAssetIDs.isEmpty {
                    Button("除外をすべて戻す（\(model.explicitlyExcludedAssetIDs.count)件）") {
                        model.restoreAllExcludedAssets()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase.isBusy || model.renameIsBusy)
                }
                if model.unreviewedEmptyDirectoryCount > 0 {
                    Text("空フォルダ \(model.unreviewedEmptyDirectoryCount)件の判断が未確認です")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }
}

private struct IngestActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("割り当て済み \(model.assignedCount) / \(model.includedAssetCount)")
                    .font(.subheadline.monospacedDigit())
                if model.unassignedCount > 0 {
                    Text("未割り当て \(model.unassignedCount)件")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !model.assets.isEmpty {
                    Text("すべての素材に保存先があります")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if !model.explicitlyExcludedAssetIDs.isEmpty {
                    Text("利用者確認による明示除外 \(model.explicitlyExcludedAssetIDs.count)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.canCancelCurrentOperation {
                Button("中止") { model.cancelCurrentOperation() }
            }
            Button("検証付き取り込みを開始") { model.beginVerifiedIngest() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    model.includedAssetCount == 0
                        || model.destinationURL == nil
                        || model.unassignedCount != 0
                        || model.unreviewedEmptyDirectoryCount != 0
                        || !model.canStartExclusiveOperation
                )
        }
        .padding(.horizontal, 16)
        .frame(height: 70)
    }
}
