import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceRoute.allCases, selection: $model.route) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }
            .navigationTitle("RINKAN UMIS")
            .frame(minWidth: 176)
        } detail: {
            switch model.route {
            case .ingest:
                IngestWorkspaceView()
            case .select:
                SelectWorkspaceView()
            case .rename:
                RenameWorkspaceView()
            case .history:
                HistoryWorkspaceView()
            case .settings:
                SettingsWorkspaceView()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDroppedURLs(urls)
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
            if model.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("—")
                .foregroundStyle(.tertiary)
            Text(model.statusMessage)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            if !model.assets.isEmpty {
                Text("\(model.assets.count)項目  ·  \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
