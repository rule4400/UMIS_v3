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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("アーカイブの評価とカラータグ")
                            .font(.title2.weight(.semibold))
                        Text("星評価は対応形式のAdobe XMPへ埋め込み、カメラRAWは標準XMP sidecarへ保存します。カラーはFinderと双方向で共有します。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("アーカイブを選択…") { model.chooseReviewSource() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.reviewIsScanning
                                || model.reviewMetadataIsLoading
                                || model.reviewMetadataIsWriting
                                || !model.canStartExclusiveOperation
                        )
                }

                if let sourceURL = model.reviewSourceURL {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(sourceURL.path, systemImage: "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sourceURL.path)
                            .textSelection(.enabled)
                        reviewSourceNotices
                    }
                } else {
                    Label(
                        "評価する取り込み済みアーカイブを選択してください",
                        systemImage: "archivebox"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
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
                    Spacer()
                    Text("カードや取り込み途中の保存先には書き込みません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            AssetBrowserView(context: .review)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("選択中 \(toolbarState.visibleSelectionCount)件")
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .frame(minWidth: 90, alignment: .leading)

                    Text("Adobe XMP評価")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                HStack(spacing: 10) {
                    Text("Finderカラー")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 90, alignment: .leading)

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
                    if let reason = toolbarState.mutationBlockReason {
                        Label(reason, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(reason)
                    } else {
                        Label("選択した素材の変更を安全に保存できます", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: reviewStatusIcon)
                        .foregroundStyle(reviewStatusColor)
                    Text(model.reviewStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.reviewStatusMessage)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("評価・タグ")
    }

    @ViewBuilder
    private var reviewSourceNotices: some View {
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("既存フォルダのCopy and Rename")
                        .font(.title2.weight(.semibold))
                    Text("元フォルダのファイル名や内容は変更しません。別の保存先へ、新しい名前で検証付きコピーを作成します。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("1. 入力フォルダとコピー先") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            PathButton(
                                title: "元フォルダ（読み取り元）",
                                url: model.renameSourceURL,
                                action: model.chooseRenameSource
                            )
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Image(systemName: "arrow.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            PathButton(
                                title: "コピー先（新規出力）",
                                url: model.renameDestinationURL,
                                action: model.chooseRenameDestination
                            )
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Text("入力と出力は別のフォルダを指定します。元データの上書き・移動・削除は行いません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.canStartExclusiveOperation)

                GroupBox("2. 命名条件") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("テンプレート", text: $model.renameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("出力ファイル名のテンプレート")
                        Text("利用可能: {location}  {scene}  {sceneName}  {date}  {photographer}  {card}  {sequence}  {original}")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("現在の置換値: \(renameContextSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(renameContextSummary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.canStartExclusiveOperation)

                Label(
                    "元ファイルは変更せず、同名衝突を事前に確認し、コピー後に内容が一致するか照合します",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            GroupBox("3. コピー計画を確認") {
                if model.renamePreviewRows.isEmpty {
                    VStack(spacing: 8) {
                        if model.renameIsBusy {
                            ProgressView()
                                .controlSize(.small)
                            Text("出力名と同名衝突、元データに変更がないかを確認中です")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "tablecells")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("入力と命名条件を確定し「計画を作成」を押すと、変更前後の一覧を表示します。")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "\(model.renamePreviewRows.count)件の計画を作成済み。実行前にコピー先の名前を確認してください。",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        Table(model.renamePreviewRows) {
                            TableColumn("元フォルダ内（変更しない）") { row in
                                Text(row.before)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(row.before)
                            }
                            TableColumn("コピー先での名前") { row in
                                Text(row.after)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(row.after)
                            }
                            TableColumn("サイズ") { row in
                                Text(ByteCountFormatter.string(fromByteCount: row.byteCount, countStyle: .file))
                                    .monospacedDigit()
                            }
                            .width(min: 80, ideal: 100, max: 130)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Divider()
            renameActionBar
        }
        .navigationTitle("フォルダリネーム")
    }

    private var renameActionBar: some View {
        HStack(spacing: 12) {
            if model.renameIsBusy {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(renameDisplayStatus)
                    .font(.caption)
                    .foregroundStyle(renameStatusColor)
                    .lineLimit(1)
                    .help(renameDisplayStatus)
                if let reason = nextActionBlockReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(reason)
                }
            }
            Spacer(minLength: 12)
            if model.renameIsBusy, model.canCancelCurrentOperation {
                Button("安全に中止") { model.cancelCurrentOperation() }
                    .help("現在のファイル境界で停止し、ロールバックまたは復旧状態を履歴に記録します")
            }
            Button("3. 計画を作成") {
                model.prepareRenamePlan(template: model.renameTemplate)
            }
            .disabled(planCreationBlockReason != nil)
            .help(planCreationBlockReason ?? "出力名と同名衝突、元データの変更有無を確認し、実行せずに一覧を作成します")
            Button("4. 検証付きコピーを実行") { model.executePreparedRename() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canExecutePreparedRename)
                .help(executionBlockReason ?? "表示中の計画を再検証し、別フォルダへコピーします")
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 66)
        .background(.bar)
    }

    private var templateIsPresent: Bool {
        !model.renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var planCreationBlockReason: String? {
        if model.renameIsBusy { return "現在の計画またはコピー処理の完了を待ってください" }
        if !model.canStartExclusiveOperation { return "別の操作が完了するまで計画を作成できません" }
        if model.renameSourceURL == nil { return "1. 元フォルダを選択してください" }
        if model.renameDestinationURL == nil { return "1. コピー先フォルダを選択してください" }
        if !templateIsPresent { return "2. 命名テンプレートを入力してください" }
        return nil
    }

    private var executionBlockReason: String? {
        if model.renameIsBusy { return "現在の処理が完了するまで実行できません" }
        if !model.canStartExclusiveOperation { return "別の処理・安全確認が完了するまで実行できません" }
        if model.renamePreviewRows.isEmpty { return "3. 実行前にコピー計画を作成してください" }
        if !model.canExecutePreparedRename { return "入力・出力・命名条件が変わったため、計画の再作成が必要です" }
        return nil
    }

    private var nextActionBlockReason: String? {
        model.canExecutePreparedRename ? nil : planCreationBlockReason ?? executionBlockReason
    }

    private var renameStatusColor: Color {
        if model.renameIsBusy { return .secondary }
        if model.canExecutePreparedRename { return .green }
        return .secondary
    }

    private var renameDisplayStatus: String {
        model.renameStatusMessage
            .replacingOccurrences(of: "内容fingerprint", with: "元データの変更有無")
            .replacingOccurrences(of: "SHA-256検証", with: "コピー後の内容照合")
    }

    private var renameContextSummary: String {
        let scene = model.selectedSceneID.flatMap { selectedID in
            model.scenes.first { $0.id == selectedID }
        }
        let values = [
            "会場 \(displayValue(model.locationName))",
            "シーン \(scene.map { "\($0.code) \($0.name)" } ?? "未設定")",
            "撮影者 \(displayValue(model.photographer))",
            "カードNo \(displayValue(model.cardNumber))",
        ]
        return values.joined(separator: " ・ ")
    }

    private func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未設定" : trimmed
    }
}

struct HistoryWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("操作履歴")
                            .font(.title2.weight(.semibold))
                        Text("永続履歴 \(model.operationHistory.count)件 ・ この起動中 \(model.activity.count)件")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refreshOperationHistory()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.exportActivityReport()
                    } label: {
                        Label("匿名化監査レポートを書き出す…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(auditExportBlockReason != nil)
                    .help(auditExportBlockReason ?? "フルパス、ホームフォルダ名、詳細なエラー内容を除いて書き出します")
                }

                HStack(spacing: 8) {
                    if model.auditExportInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: historyStatusIcon)
                            .foregroundStyle(historyStatusColor)
                    }
                    Text(model.historyStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(model.historyStatusMessage)
                        .textSelection(.enabled)
                    Spacer()
                    Label("書き出し時は個人を特定し得る情報を除外", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            if model.activity.isEmpty && model.operationHistory.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("操作履歴はまだありません")
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
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Text(operation.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if model.canResumeOperation(operation) {
                                        Button("再開を検証…") { model.resumeOperation(operation) }
                                            .disabled(!model.canStartExclusiveOperation)
                                            .help(
                                                model.canStartExclusiveOperation
                                                    ? "同一カード・同一挿入・同一計画を再確認し、一致した場合だけ再開します"
                                                    : "実行中の操作が完了するまで再開を確認できません"
                                            )
                                    } else if operation.status == .recoveryRequired {
                                        Label("要手動確認", systemImage: "person.crop.circle.badge.exclamationmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .help("自動再開は行いません。元データと保存先を手動で確認してください")
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
                                            .lineLimit(2)
                                            .help(record.detail)
                                    }
                                    Spacer()
                                    Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
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

    private var auditExportBlockReason: String? {
        if model.activity.isEmpty && model.operationHistory.isEmpty {
            return "書き出す操作履歴がありません"
        }
        if model.auditExportInFlight {
            return "監査レポートを書き出し中です"
        }
        if !model.canStartExclusiveOperation {
            return "実行中の操作が完了するまで書き出せません"
        }
        return nil
    }

    private var historyStatusIcon: String {
        let message = model.historyStatusMessage
        if message.contains("失敗") || message.contains("信頼できません") {
            return "exclamationmark.triangle.fill"
        }
        if model.operationHistory.isEmpty {
            return "clock"
        }
        return "checkmark.circle"
    }

    private var historyStatusColor: Color {
        historyStatusIcon == "exclamationmark.triangle.fill" ? .orange : .secondary
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
