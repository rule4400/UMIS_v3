import SwiftUI

struct IngestWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                if model.showInspector, viewport.size.width < 1_100 {
                    // AppKit's nested split view retains oversized pane widths when shrinking.
                    // At compact widths reserve the side panels explicitly, leaving the browser
                    // the remaining space instead of clipping either side of the workspace.
                    HStack(spacing: 0) {
                        SourceConfigurationView()
                            .frame(width: 230)
                        Divider()
                        AssetBrowserView()
                            .frame(minWidth: 0, maxWidth: .infinity)
                        Divider()
                        SceneAssignmentView()
                            .controlSize(.small)
                            .frame(width: 280)
                            .disabled(!model.canStartExclusiveOperation)
                    }
                } else {
                    HSplitView {
                        SourceConfigurationView()
                            .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)

                        AssetBrowserView()
                            .frame(minWidth: 340, idealWidth: 500, maxWidth: .infinity)

                        if model.showInspector {
                            SceneAssignmentView()
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                                .disabled(!model.canStartExclusiveOperation)
                        }
                    }
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
                .disabled(model.sourceURL == nil || !model.canStartIngestSourceScan)
                .help("ソースを再読み込みします。現在の素材選択と割り当ては再確認が必要です")

                Button { model.showInspector.toggle() } label: {
                    Label("シーン", systemImage: "sidebar.right")
                }
                .help(model.showInspector ? "シーンパネルを隠す" : "シーンパネルを表示")
                .accessibilityLabel(model.showInspector ? "シーンパネルを隠す" : "シーンパネルを表示")
            }
        }
        // Keep modal identity outside the compact/wide layout branches so resizing the
        // main window cannot discard the sheet's local, uncommitted capture draft.
        .sheet(isPresented: $model.showCaptureConfigurationSheet) {
            CaptureConfigurationSheet(draft: model.makeCaptureConfigurationDraft())
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showProjectLocationSheet) {
            ProjectLocationSheet().environmentObject(model)
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
                            model.loadStoredProject(id: next)
                        }
                    )
                ) {
                    Text("新規／未選択").tag(UUID?.none)
                    ForEach(model.availableProjects, id: \.id.rawValue) { project in
                        Text(project.name).tag(Optional(project.id.rawValue))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("プロジェクト名").font(.caption).foregroundStyle(.secondary)
                    TextField("プロジェクト名", text: $model.projectName)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("プロジェクト名")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("会場").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.beginAddProjectLocation() } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("会場を追加")
                        .help("このプロジェクトで使う会場を追加します")
                    }
                    Picker("会場", selection: Binding(
                        get: { model.selectedProjectLocationID },
                        set: { model.selectProjectLocation(id: $0) }
                    )) {
                        Text("会場を選択").tag(UUID?.none)
                        ForEach(model.availableProjectLocations, id: \.id.rawValue) { location in
                            Text(location.displayName).tag(Optional(location.id.rawValue))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("会場")
                    if model.availableProjectLocations.isEmpty {
                        Text("＋から会場を登録できます")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("新規") { model.createNewProject() }
                    Button("保存") { model.saveCurrentProject() }
                    Spacer()
                    Button("削除…", role: .destructive) {
                        showDeleteProjectConfirmation = true
                    }
                    .disabled(!model.canDeleteCurrentStoredProject)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("旧UMIS JSONを移行…") { model.importLegacyProject() }
                    Button("直前の削除を復旧") { model.recoverLastDeletedProject() }
                        .disabled(!model.canRecoverLastDeletedProject)
                }
                Text(model.projectPersistenceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.canStartExclusiveOperation)

            Section("撮影情報") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.photographer.isEmpty ? "撮影者 未選択" : model.photographer,
                          systemImage: "person.crop.circle")
                        .lineLimit(2)
                        .help(model.photographer)
                    Label(model.cardNumber.isEmpty ? "カードNo 未選択" : "カードNo \(model.cardNumber)",
                          systemImage: "sdcard")
                        .lineLimit(2)
                        .help(model.cardNumber)
                    Button {
                        model.beginCaptureConfiguration()
                    } label: {
                        Label("撮影者・カードを選択…", systemImage: "person.crop.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("撮影者とカードNoを選択")
                }
                Text("別画面で撮影者とカードを選び、「決定」で反映します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.canStartExclusiveOperation)

            Section("ソース") {
                Label(model.cardAutoSelectionStatus, systemImage: "sdcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .help(model.cardAutoSelectionStatus)
                if !model.connectedCardCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("接続中のSDカード").font(.caption.weight(.medium))
                        ForEach(model.connectedCardCandidates, id: \.id.rawValue) { card in
                            Button {
                                model.selectConnectedCard(
                                    sourceID: card.id,
                                    arrivalGeneration: card.arrivalGeneration
                                )
                            } label: {
                                Label(
                                    card.mountURL?.lastPathComponent ?? "SDカード",
                                    systemImage: model.activeSourceIdentity?.id == card.id
                                        ? "checkmark.circle.fill" : "sdcard"
                                )
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .help(card.mountURL?.path ?? "SDカードを読み込み対象に選択")
                        }
                    }
                }
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canStartIngestSourceScan)

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
                Text(model.projectDestinationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(model.projectDestinationStatus)
            }
            .disabled(!model.canStartExclusiveOperation)

            if !model.scanErrors.isEmpty {
                Section("スキャン警告") {
                    DisclosureGroup {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(model.scanErrors.enumerated()), id: \.offset) { _, message in
                                    Text(message)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    } label: {
                        Label("\(model.scanErrors.count)件の読取警告", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
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
                .disabled(!model.canStartExclusiveOperation)
            }
        }
        .formStyle(.grouped)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Button(action: action) {
                    Label(url == nil ? "選択…" : "変更…", systemImage: "folder")
                }
                .accessibilityLabel("\(title)を\(url == nil ? "選択" : "変更")")
                .help("\(title)のフォルダを選択します")
            }
            if let url {
                Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(url?.path(percentEncoded: false) ?? "フォルダが選択されていません")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url?.path(percentEncoded: false) ?? "選択ボタンで\(title)を指定してください")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IngestActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.assets.isEmpty
                    ? "取り込みの準備"
                    : "割り当て済み \(model.assignedCount) / \(model.includedAssetCount)")
                    .font(.subheadline.monospacedDigit())
                Label(readinessMessage, systemImage: canBeginIngest ? "checkmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(canBeginIngest ? Color.green : Color.secondary)
                    .lineLimit(3)
                    .help(readinessMessage)
                if !model.explicitlyExcludedAssetIDs.isEmpty {
                    Text("利用者確認による明示除外 \(model.explicitlyExcludedAssetIDs.count)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.canCancelCurrentOperation {
                Button("中止") { model.cancelCurrentOperation() }
                    .help("処理中のファイルを安全に完了してから停止します")
            }
            Button("検証付き取り込みを開始") { model.beginVerifiedIngest() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canBeginIngest)
                .help(readinessMessage)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 78)
        .background(.bar)
    }

    private var canBeginIngest: Bool {
        model.includedAssetCount > 0
            && model.phase.failureMessage == nil
            && model.destinationURL != nil
            && model.unassignedCount == 0
            && model.unreviewedEmptyDirectoryCount == 0
            && model.canStartExclusiveOperation
    }

    private var readinessMessage: String {
        if model.ingestScanBoundaryIsRetiring {
            return "前のスキャンを安全に終了しています。しばらくお待ちください"
        }
        if model.phase.isBusy { return model.phase.label }
        if model.phase.failureMessage != nil {
            return "処理が失敗しました。画面下部の理由と必要な対応をご確認ください"
        }
        if !model.canStartExclusiveOperation {
            return "現在の処理・安全確認の完了を待っています。画面下部の状況をご確認ください"
        }
        if model.assets.isEmpty {
            return model.sourceURL == nil
                ? "撮影カードまたは素材フォルダを選択してください"
                : "対応する素材がありません。再スキャンするか、別のフォルダを選択してください"
        }
        if model.includedAssetCount == 0 { return "すべての素材が除外されています。必要な素材を取り込み対象に戻してください" }
        if model.destinationURL == nil { return "左側の「保存先」でアーカイブ先を選択してください" }
        if model.unassignedCount > 0 { return "残り\(model.unassignedCount)件をシーンに割り当ててください" }
        if model.unreviewedEmptyDirectoryCount > 0 { return "左側の「空フォルダ」で残り\(model.unreviewedEmptyDirectoryCount)件をご確認ください" }
        return "準備が整いました。コピー後に全ファイルの内容を検証します"
    }
}
