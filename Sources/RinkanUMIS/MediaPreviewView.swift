import AVKit
import SwiftUI
import UMISMedia

struct MediaPreviewView: View {
    let asset: AppAsset
    let pipeline: MediaPipeline?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var preview: MediaPreview?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Text(asset.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                }
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ZStack {
                Color.black.opacity(0.94)
                if isLoading {
                    ProgressView("プレビューを準備中…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: asset.category.systemImage)
                            .font(.system(size: 42))
                        Text("プレビューできません")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                } else if let preview {
                    previewContent(preview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let preview {
                Divider()
                metadataBar(preview.metadata)
            }
        }
        .task(id: asset.id) {
            await loadPreview()
        }
        .onDisappear {
            player?.pause()
            player = nil
            model.previewPlaybackDidStop(assetID: asset.id)
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: MediaPreview) -> some View {
        if let playback = preview.playback, playback.isPlayable {
            VideoPlayer(player: player)
                .onAppear {
                    if player == nil {
                        if model.previewPlaybackDidStart(assetID: asset.id) {
                            player = AVPlayer(url: playback.sourceURL)
                        } else {
                            errorMessage = "安全な取り出しまたはカード照合中のため再生を開始できません。"
                        }
                    }
                }
                .padding(16)
        } else {
            Image(decorative: preview.image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .padding(16)
        }
    }

    private func metadataBar(_ metadata: MediaMetadata) -> some View {
        HStack(spacing: 18) {
            Label(asset.category.rawValue, systemImage: asset.category.systemImage)
            Text(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))
            if let dimensions = metadata.pixelSize, dimensions.width > 0, dimensions.height > 0 {
                Text("\(dimensions.width) × \(dimensions.height)")
            }
            if let duration = metadata.durationSeconds {
                Text(Self.durationFormatter.string(from: duration) ?? "")
            }
            if !metadata.codecs.isEmpty {
                Text(metadata.codecs.joined(separator: " / "))
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        player?.pause()
        player = nil
        guard let pipeline else {
            errorMessage = "メディア処理を初期化できませんでした。"
            isLoading = false
            return
        }
        do {
            let result = try await pipeline.preview(
                for: asset.url,
                pixelSize: MediaPixelSize(width: 1_920, height: 1_080),
                priority: .interactive
            )
            try Task.checkCancellation()
            preview = result
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
