import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceRoute.allCases, selection: $model.route) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
                    .padding(.vertical, 3)
            }
            .navigationTitle("RINKAN UMIS")
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 240)
            .accessibilityLabel("作業画面")
        } detail: {
            switch model.route {
            case .ingest:
                IngestWorkspaceView()
            case .review:
                RatingWorkspaceView()
            case .rename:
                RenameWorkspaceView()
            case .history:
                HistoryWorkspaceView()
            case .settings:
                SettingsWorkspaceView()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.route == .ingest else { return false }
            return model.acceptDroppedURLs(urls)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        .sheet(item: $model.previewAsset) { asset in
            MediaPreviewView(asset: asset, pipeline: model.mediaPipeline)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

private struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if currentWorkspaceIsBusy {
                if statusRoute == .ingest, let progress = model.phase.progressFraction {
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .accessibilityLabel(model.phase.label)
                        .accessibilityValue("\(Int(progress * 100))パーセント")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(currentWorkspaceLabel)
                }
            } else if statusRoute == .ingest, case .failed = model.phase {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            } else if statusRoute == .ingest, model.phase == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Text(currentWorkspaceLabel)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(currentWorkspaceLabel)
            Text("—")
                .foregroundStyle(.tertiary)
            Text(currentWorkspaceStatus)
                .font(.callout)
                .lineLimit(1)
                .help(currentWorkspaceStatus)
                .accessibilityLabel("状況: \(currentWorkspaceStatus)")
            Spacer()
            if model.reviewMetadataIsWriting, model.route != .review {
                Button("残りを中止") { model.cancelReviewMetadataWrite() }
                    .controlSize(.small)
                    .help("現在処理中のファイルを安全に完了してから、未開始の保存を中止します")
            } else if model.canCancelCurrentOperation,
                      statusRoute != model.route {
                Button("中止") { model.cancelCurrentOperation() }
                    .controlSize(.small)
                    .help("現在のファイル境界で安全に停止します")
            }
            if currentAssetCount > 0 {
                Text("\(currentAssetCount)項目  ·  \(ByteCountFormatter.string(fromByteCount: currentTotalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var currentWorkspaceIsBusy: Bool {
        switch statusRoute {
        case .ingest:
            return model.phase.isBusy || model.ingestScanBoundaryIsBusy
        case .review:
            return model.reviewIsScanning || model.reviewMetadataIsLoading || model.reviewMetadataIsWriting
        case .rename:
            return model.renameIsBusy
        case .settings:
            return model.projectOperationInFlight
                || model.mediaCacheOperationInFlight
                || model.lanOperationInProgress
        case .history:
            return model.auditExportInFlight
        }
    }

    private var currentWorkspaceLabel: String {
        let label = switch statusRoute {
        case .ingest:
            if model.ingestScanBoundaryIsRetiring { "スキャン終了待機中" }
            else if case .failed = model.phase { "処理に失敗" }
            else { model.phase.label }
        case .review:
            if model.reviewIsScanning { "読込中" }
            else if model.reviewMetadataIsWriting { "保存中" }
            else if model.reviewMetadataIsLoading { "メタデータ解析中" }
            else { "評価・タグ" }
        case .rename:
            model.renameIsBusy ? "リネーム中" : "フォルダリネーム"
        case .history:
            model.auditExportInFlight ? "監査レポート書き出し中" : "履歴"
        case .settings:
            if model.mediaCacheOperationInFlight { "キャッシュ消去中" }
            else if model.lanOperationInProgress { "LANシーン共有処理中" }
            else if model.projectOperationInFlight { "プロジェクト処理中" }
            else { "設定" }
        }
        return statusRoute == model.route ? label : "\(statusRoute.title) · \(label)"
    }

    private var currentWorkspaceStatus: String {
        switch statusRoute {
        case .ingest:
            if model.ingestScanBoundaryIsRetiring {
                "前のスキャンがファイルとカードの読み取りを安全に終了するまで待っています"
            } else if case let .failed(message) = model.phase {
                message
            } else {
                model.statusMessage
            }
        case .review: model.reviewStatusMessage
        case .rename: model.renameStatusMessage
        case .history: model.historyStatusMessage
        case .settings:
            if model.mediaCacheOperationInFlight { model.mediaCacheStatusMessage }
            else if model.lanOperationInProgress { model.lanStatusMessage }
            else { model.projectPersistenceStatus }
        }
    }

    private var currentAssetCount: Int {
        switch statusRoute {
        case .ingest: model.assets.count
        case .review: model.reviewAssets.count
        case .rename, .history, .settings: 0
        }
    }

    private var currentTotalBytes: Int64 {
        switch statusRoute {
        case .ingest: model.totalBytes
        case .review: model.reviewTotalBytes
        case .rename, .history, .settings: 0
        }
    }

    /// Route changes must not hide a still-running operation. The status bar follows the active
    /// operation first, and returns to the visible workspace when the operation settles.
    private var statusRoute: WorkspaceRoute {
        if model.phase.isBusy || model.ingestScanBoundaryIsBusy { return .ingest }
        if model.reviewIsScanning || model.reviewMetadataIsLoading || model.reviewMetadataIsWriting {
            return .review
        }
        if model.renameIsBusy { return .rename }
        if model.mediaCacheOperationInFlight || model.lanOperationInProgress { return .settings }
        if model.auditExportInFlight { return .history }
        if model.projectOperationInFlight { return .settings }
        return model.route
    }
}
