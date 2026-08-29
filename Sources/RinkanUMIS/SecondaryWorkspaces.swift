import AppKit
import SwiftUI
import UMISCore

struct RatingWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    private let workspace = NSWorkspace.shared

    var body: some View {
        let toolbarState = model.reviewToolbarState
        let finderLabels = workspace.fileLabels
        let finderLabelColors = workspace.fileLabelColors
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("アーカイブの評価とカラータグ")
                        .font(.title2.weight(.semibold))
                    Text("星評価は対応形式のAdobe XMPへ埋め込み、カメラRAWは標準XMP sidecarへ保存します。カラーはFinderと双方向で共有します。")
                        .foregroundStyle(.secondary)
                    if let sourceURL = model.reviewSourceURL {
                        Label(sourceURL.path, systemImage: "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sourceURL.path)
                        if let archiveWriteRestriction {
                            Label(
                                model.reviewSourceIsReadOnly == nil ? "安全確認不可" : "変更不可",
                                systemImage: "lock.fill"
                            )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .help(archiveWriteRestriction)
                        }
                        if let recoveryReason = model.reviewMetadataRecoveryBlockReason {
                            Label("XMP保護データの復旧確認が必要", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .help(recoveryDetail.isEmpty ? recoveryReason : recoveryDetail)
                        }
                        if model.reviewUnsupportedRegularFileCount > 0 {
                            Label(
                                "未対応形式 \(model.reviewUnsupportedRegularFileCount)件は表示対象外",
                                systemImage: "doc.badge.ellipsis"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .help(unsupportedReviewFilesDetail)
                        }
                        if let scanIssueSummary = model.reviewScanIssueStatusSummary {
                            Label(scanIssueSummary, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .help(reviewScanIssuesDetail)
                        }
                    }
                }
                Spacer()
                if model.reviewMetadataIsLoading || model.reviewMetadataIsWriting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    model.refreshReviewMetadata()
                } label: {
                    Label("メタデータ再読込", systemImage: "arrow.clockwise")
                }
                .disabled(
                    model.reviewAssets.isEmpty
                        || model.reviewIsScanning
                        || model.reviewMetadataIsLoading
                        || model.reviewMetadataIsWriting
                        || !model.canStartExclusiveOperation
                )
                Button {
                    model.rescanReviewSource()
                } label: {
                    Label("フォルダ再スキャン", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.reviewSourceURL == nil || !model.canStartExclusiveOperation)
                Button("アーカイブを選択…") { model.chooseReviewSource() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.reviewIsScanning
                            || model.reviewMetadataIsLoading
                            || model.reviewMetadataIsWriting
                            || !model.canStartExclusiveOperation
                    )
            }
            .padding(16)
            Divider()
            AssetBrowserView(context: .review)
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Text("選択中 \(toolbarState.visibleSelectionCount)件")
                        .font(.subheadline.monospacedDigit())
                        .frame(minWidth: 90, alignment: .leading)

                    HStack(spacing: 3) {
                        ratingButton(
                            .rejected,
                            title: "除外",
                            systemImage: "xmark",
                            state: toolbarState
                        )
                        ratingButton(
                            .unrated,
                            title: "評価なし",
                            systemImage: "star.slash",
                            state: toolbarState
                        )
                        ForEach(1 ... 5, id: \.self) { stars in
                            ratingButton(
                                AdobeRating(rawValue: stars) ?? .unrated,
                                title: "\(stars)つ星",
                                systemImage: "star.fill",
                                state: toolbarState
                            )
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Adobe XMPレーティング")

                    Divider()
                        .frame(height: 28)

                    HStack(spacing: 5) {
                        colorButton(
                            number: 0,
                            labels: finderLabels,
                            colors: finderLabelColors,
                            state: toolbarState
                        )
                        ForEach(1 ..< min(finderLabels.count, finderLabelColors.count), id: \.self) {
                            number in
                            colorButton(
                                number: number,
                                labels: finderLabels,
                                colors: finderLabelColors,
                                state: toolbarState
                            )
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Finderカラー")

                    Spacer()
                    if model.reviewMetadataIsWriting {
                        Button("残りを中止") {
                            model.cancelReviewMetadataWrite()
                        }
                        .controlSize(.small)
                        .help("現在処理中のファイルを安全に完了してから、未開始の保存を中止します")
                        Label("保存中", systemImage: "externaldrive.badge.timemachine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: reviewStatusIcon)
                        .foregroundStyle(reviewStatusColor)
                    Text(model.reviewStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let reason = toolbarState.mutationBlockReason,
                       toolbarState.visibleSelectionCount > 0 {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("評価・タグ")
    }

    private var reviewStatusIcon: String {
        if model.reviewMetadataRecoveryBlockReason != nil {
            return "externaldrive.badge.exclamationmark"
        }
        if model.reviewIsScanning || model.reviewMetadataIsLoading {
            return "arrow.clockwise.circle"
        }
        if model.reviewMetadataIsWriting {
            return "externaldrive.badge.timemachine"
        }
        if !model.reviewMetadataErrorIDs.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if model.reviewScanIssueCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if !model.reviewMetadataWarnings.isEmpty {
            return "info.circle.fill"
        }
        if model.reviewSourceURL == nil {
            return "archivebox"
        }
        if model.reviewAssets.isEmpty {
            return "tray"
        }
        return "checkmark.circle"
    }

    private var archiveWriteRestriction: String? {
        guard model.reviewSourceURL != nil else { return nil }
        if model.reviewSourceIsReadOnly == true {
            return "ボリュームが読み取り専用です"
        }
        if model.reviewSourceIsReadOnly == nil {
            return "ボリュームの書き込み可否を確認できないため、安全のため変更しません"
        }
        if !model.reviewSourceIsLocal {
            return "ネットワーク上のアーカイブはmount世代を証明できないため、評価とカラーを変更しません"
        }
        if model.reviewSourceIsEjectable || !model.reviewSourceIsInternal {
            return "外付け・取り外し可能・媒体種別不明のアーカイブは安全のため変更しません"
        }
        return nil
    }

    private var reviewStatusColor: Color {
        if model.reviewMetadataRecoveryBlockReason != nil {
            return .red
        }
        if model.reviewIsScanning || model.reviewMetadataIsLoading || model.reviewMetadataIsWriting {
            return .accentColor
        }
        if !model.reviewMetadataErrorIDs.isEmpty {
            return .orange
        }
        if model.reviewScanIssueCount > 0 {
            return .orange
        }
        if !model.reviewMetadataWarnings.isEmpty {
            return .yellow
        }
        return .secondary
    }

    private var recoveryDetail: String {
        var lines = model.reviewMetadataRecoveryRecords.prefix(20).map { record in
            "\(record.recoveryDirectoryRelativePath): \(record.warning)"
        }
        if model.reviewMetadataRecoveryRecords.count > 20 {
            lines.append("ほか\(model.reviewMetadataRecoveryRecords.count - 20)件")
        }
        if model.reviewMetadataRecoveryScanWasTruncated {
            lines.append("検査件数が上限に達しました")
        }
        if let error = model.reviewMetadataRecoveryScanError {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    private var unsupportedReviewFilesDetail: String {
        var lines = ["拡張子を安全に分類できない通常ファイルは、誤ったXMP保存を避けるため表示していません。"]
        lines.append(contentsOf: model.reviewUnsupportedRegularFileSamples)
        if model.reviewUnsupportedRegularFileCount > model.reviewUnsupportedRegularFileSamples.count {
            lines.append(
                "ほか\(model.reviewUnsupportedRegularFileCount - model.reviewUnsupportedRegularFileSamples.count)件"
            )
        }
        return lines.joined(separator: "\n")
    }

    private var reviewScanIssuesDetail: String {
        var lines = [
            "走査中に変更された、見つからなくなった、または読み取れなかった項目は、評価・タグの対象に含めていません。",
        ]
        lines.append(contentsOf: model.reviewScanIssueSamples)
        if model.reviewScanIssueCount > model.reviewScanIssueSamples.count {
            lines.append(
                "ほか\(model.reviewScanIssueCount - model.reviewScanIssueSamples.count)件"
            )
        }
        lines.append("フォルダが更新中でない状態で再スキャンしてください。")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func ratingButton(
        _ rating: AdobeRating,
        title: String,
        systemImage: String,
        state: ReviewToolbarState
    ) -> some View {
        let isSelected = state.selectionRating == rating
            && (rating != .unrated || state.selectionRatingIsExplicit == true)
        Button {
            model.applyReviewRating(rating)
        } label: {
            Group {
                if rating.rawValue > 0 {
                    HStack(spacing: 2) {
                        Text("\(rating.rawValue)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Image(systemName: isSelected ? "star.fill" : "star")
                    }
                } else {
                    Image(systemName: systemImage)
                }
            }
            .foregroundStyle(rating == .rejected
                ? Color.red
                : (isSelected ? Color.yellow : Color.secondary))
            .frame(minWidth: rating.rawValue > 0 ? 34 : 28, minHeight: 26)
            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!state.canMutateMetadata)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "選択中" : "")
    }

    @ViewBuilder
    private func colorButton(
        number: Int,
        labels: [String],
        colors: [NSColor],
        state: ReviewToolbarState
    ) -> some View {
        let isSelected = state.selectionLabelNumber == number
        let label = number < labels.count
            ? labels[number]
            : "カラーなし"
        Button {
            model.applyReviewLabelNumber(number)
        } label: {
            ZStack {
                Circle()
                    .fill(number == 0 || number >= colors.count
                        ? Color.clear
                        : Color(nsColor: colors[number]))
                    .overlay {
                        Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    }
                if number == 0 {
                    Image(systemName: "slash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .padding(3)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!state.canMutateMetadata)
        .help(number == 0 ? "Finderカラーを解除（名前付きタグは保持）" : label)
        .accessibilityLabel(number == 0 ? "Finderカラーなし" : "Finderカラー \(label)")
        .accessibilityValue(isSelected ? "選択中" : "")
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
            .disabled(!model.canStartExclusiveOperation)

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
            .disabled(!model.canStartExclusiveOperation)

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
                    .disabled(
                        (model.activity.isEmpty && model.operationHistory.isEmpty)
                            || !model.canStartExclusiveOperation
                    )
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
                                            .disabled(!model.canStartExclusiveOperation)
                                    } else if operation.status == .recoveryRequired {
                                        Text("要手動確認")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            Text("再開できるのは、現在のアプリ起動・同一カード挿入・同一凍結計画を再検証できる取り込みだけです。Copy and Renameや再起動後の処理は要手動確認です。")
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
        case .copyAndRename: "Copy and Rename"
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
