import SwiftUI
import UMISCore

struct SelectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("アーカイブから選別素材を作成")
                        .font(.title2.weight(.semibold))
                    Text("元ファイルを変更せず、選択項目をシーン内の「選別」フォルダへ検証付きコピーします。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("アーカイブを選択…") { model.chooseSource() }
            }
            .padding(16)
            Divider()
            AssetBrowserView()
            Divider()
            HStack {
                Text("選択中 \(model.selectedAssetIDs.count)件")
                Spacer()
                if model.canCancelCurrentOperation {
                    Button("中止") { model.cancelCurrentOperation() }
                }
                Button("選別フォルダへコピー") { model.copySelectionToSelectFolders() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedAssetIDs.isEmpty || !model.canStartExclusiveOperation)
            }
            .padding(14)
        }
        .navigationTitle("セレクト")
    }
}

struct RenameWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("既存フォルダのCopy and Rename")
                    .font(.title2.weight(.semibold))
                Text("元フォルダを変更せず、全出力名と衝突を事前検査してから別フォルダへコピーします。")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                GroupBox("入力") {
                    PathButton(title: "既存素材フォルダ", url: model.renameSourceURL, action: model.chooseRenameSource)
                        .padding(8)
                }
                GroupBox("出力") {
                    PathButton(title: "リネーム済みコピー先", url: model.renameDestinationURL, action: model.chooseRenameDestination)
                        .padding(8)
                }
            }

            GroupBox("命名テンプレート") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("テンプレート", text: $model.renameTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text("利用可能: {location} {scene} {date} {photographer} {card} {original}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("安全設定") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("同名出力を実行前に全件検出", systemImage: "checkmark.shield")
                    Label("一時ファイルへ書込み、SHA-256検証後にatomic commit", systemImage: "checkmark.shield")
                    Label("元フォルダ内での直接renameは初版では無効", systemImage: "lock.shield")
                }
                .padding(8)
            }

            if model.renameIsBusy {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.renameStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Text(model.renameStatusMessage)
                    .font(.caption)
                    .foregroundStyle(model.renamePreviewRows.isEmpty ? Color.secondary : Color.green)
            }

            if !model.renamePreviewRows.isEmpty {
                Table(model.renamePreviewRows) {
                    TableColumn("変更前") { row in
                        Text(row.before)
                            .lineLimit(1)
                            .help(row.before)
                    }
                    TableColumn("変更後") { row in
                        Text(row.after)
                            .lineLimit(1)
                            .help(row.after)
                    }
                    TableColumn("サイズ") { row in
                        Text(ByteCountFormatter.string(fromByteCount: row.byteCount, countStyle: .file))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 100, max: 130)
                }
                .frame(minHeight: 180)
            } else {
                Spacer()
            }

            HStack {
                Spacer()
                if model.renameIsBusy {
                    Button("中止") { model.cancelCurrentOperation() }
                }
                Button("計画を作成してプレビュー") {
                    model.prepareRenamePlan(template: model.renameTemplate)
                }
                .disabled(
                    model.renameSourceURL == nil
                        || model.renameDestinationURL == nil
                        || !model.canStartExclusiveOperation
                )
                Button("この計画を実行") { model.executePreparedRename() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canExecutePreparedRename)
            }
        }
        .padding(20)
        .navigationTitle("フォルダリネーム")
        .disabled(model.projectOperationInFlight)
    }
}

struct HistoryWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("操作履歴")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("再読み込み") { model.refreshOperationHistory() }
                Button("匿名化監査レポートを書き出す…") { model.exportActivityReport() }
                    .disabled(model.activity.isEmpty && model.operationHistory.isEmpty)
                    .help("監査payload、フルパス、ホームフォルダ名、生のエラー詳細は書き出しません")
            }
            .padding(16)
            Divider()
            if model.activity.isEmpty && model.operationHistory.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(model.historyStatusMessage)
                        .foregroundStyle(.secondary)
                    Text("成功・失敗・中止・検証結果をすべてここへ記録します。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                List {
                    if !model.operationHistory.isEmpty {
                        Section("永続ジャーナル") {
                            ForEach(model.operationHistory, id: \.id) { operation in
                                HStack(spacing: 12) {
                                    Image(systemName: operationIcon(operation.status))
                                        .foregroundStyle(operationColor(operation.status))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(operationKind(operation.kind)) · \(operationStatus(operation.status))")
                                        Text(operation.id.uuidString.lowercased())
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(operation.updatedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if model.canResumeOperation(operation) {
                                        Button("再開を検証…") { model.resumeOperation(operation) }
                                            .disabled(model.phase.isBusy || model.renameIsBusy)
                                    } else if operation.status == .recoveryRequired {
                                        Text("要手動確認")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            Text("再開できるのは、現在のアプリ起動・同一カード挿入・同一凍結計画を再検証できる取り込みだけです。Copy and Rename／選別コピーや再起動後の処理は要手動確認です。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !model.activity.isEmpty {
                        Section("この起動中の補助イベント") {
                            ForEach(model.activity) { record in
                                HStack {
                                    Image(systemName: icon(for: record.state))
                                        .foregroundStyle(color(for: record.state))
                                    VStack(alignment: .leading) {
                                        Text(record.title)
                                        Text(record.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("履歴")
        .onAppear { model.refreshOperationHistory() }
    }

    private func icon(for state: ActivityRecord.State) -> String {
        switch state {
        case .completed, .verified: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private func color(for state: ActivityRecord.State) -> Color {
        switch state {
        case .completed, .verified: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func operationKind(_ kind: OperationKind) -> String {
        switch kind {
        case .ingest: "取り込み"
        case .copyAndRename: "Copy and Rename／選別"
        case .erase: "カード初期化"
        case .eject: "カード取り出し"
        }
    }

    private func operationStatus(_ status: OperationStatus) -> String {
        switch status {
        case .planned: "計画済み"
        case .running: "実行中／中断検出"
        case .cancelled: "中止"
        case .failed: "失敗"
        case .rolledBack: "ロールバック済み"
        case .completed: "検証完了"
        case .recoveryRequired: "復旧確認が必要"
        }
    }

    private func operationIcon(_ status: OperationStatus) -> String {
        switch status {
        case .completed: "checkmark.seal.fill"
        case .planned, .running: "arrow.triangle.2.circlepath"
        case .cancelled, .rolledBack: "arrow.uturn.backward.circle"
        case .failed, .recoveryRequired: "exclamationmark.triangle.fill"
        }
    }

    private func operationColor(_ status: OperationStatus) -> Color {
        switch status {
        case .completed: .green
        case .planned, .running: .blue
        case .cancelled, .rolledBack: .secondary
        case .failed: .red
        case .recoveryRequired: .orange
        }
    }
}
