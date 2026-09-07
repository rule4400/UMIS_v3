import AVKit
import SwiftUI
import UMISMedia

enum MediaPreviewNotice {
    static func message(
        kind: MediaKind,
        isPlayable: Bool,
        generationMethod: MediaGenerationMethod,
        isFallback: Bool
    ) -> String? {
        if (kind == .movie || kind == .audio), !isPlayable {
            let media = kind == .audio ? "音声" : "動画"
            let representation = generationMethod == .genericIcon
                ? "代替アイコンを表示しています。"
                : "静止プレビューを表示しています。"
            return "この\(media)は現在のプレビューでは再生できません。\(representation)「Finderで表示」から対応アプリで確認してください。"
        }
        // A playable movie may have only a fallback poster, but its player is still usable.
        guard !isPlayable else { return nil }
        if generationMethod == .genericIcon {
            return "画像を生成できないため、代替アイコンを表示しています。「Finderで表示」から元ファイルを確認してください。"
        }
        if isFallback {
            return "簡易プレビューを表示しています。画質や細部は元ファイルを対応アプリで確認してください。"
        }
        return nil
    }
}

struct MediaPreviewView: View {
    let asset: AppAsset
    let pipeline: MediaPipeline?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var model: AppModel
    @State private var preview: MediaPreview?
    @State private var player: AVPlayer?
    @State private var playbackAsset: AVURLAsset?
    @State private var playbackToken: UUID?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var loadedPreviewPixelSize: MediaPixelSize?
    @State private var reloadGeneration = UUID()
    @AccessibilityFocusState private var accessibilityFocus: PreviewAccessibilityFocus?

    private static let mediaPadding: CGFloat = 16

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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("プレビュー中のファイル")
                .accessibilityValue("\(asset.filename)、\(asset.relativePath)")
                .help(asset.relativePath)
                Spacer()
                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Finderでこのファイルを表示（⇧⌘R）")
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("プレビューを閉じる（Esc）")
            }
            .padding(14)

            Divider()

            if let preview, let notice = MediaPreviewNotice.message(
                kind: preview.kind,
                isPlayable: preview.playback?.isPlayable == true,
                generationMethod: preview.image.generationMethod,
                isFallback: preview.image.isFallback
            ) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .lineLimit(3)
                    .help(notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                    .accessibilityLabel(notice)
            }

            GeometryReader { proxy in
                let viewportPointSize = CGSize(
                    width: max(1, proxy.size.width - (Self.mediaPadding * 2)),
                    height: max(1, proxy.size.height - (Self.mediaPadding * 2))
                )
                let requestPixelSize = MediaRequestSizingPolicy.previewPixelSize(
                    viewportPointSize: viewportPointSize,
                    backingScaleFactor: displayScale
                )

                ZStack {
                    Color.black.opacity(0.94)
                    if isLoading {
                        ProgressView("プレビューを準備中…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    } else if let errorMessage {
                        VStack(spacing: 12) {
                            VStack(spacing: 12) {
                                Image(systemName: asset.category.systemImage)
                                    .font(.system(size: 42))
                                    .accessibilityHidden(true)
                                Text("プレビューできません")
                                    .font(.headline)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.82))
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("プレビューエラー")
                            .accessibilityValue(errorMessage)
                            .accessibilityFocused($accessibilityFocus, equals: .error)

                            if pipeline != nil {
                                Button("再試行") { retryPreview() }
                                    .buttonStyle(.borderedProminent)
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .foregroundStyle(.white)
                    } else if let preview {
                        previewContent(preview)
                    }
                }
                .task(id: PreviewLoadRequest(
                    assetID: asset.id,
                    pixelSize: requestPixelSize,
                    reloadGeneration: reloadGeneration
                )) {
                    await loadPreview(pixelSize: requestPixelSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let preview {
                Divider()
                metadataBar(preview.metadata)
            }
        }
        .onDisappear {
            schedulePlaybackTeardown()
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: MediaPreview) -> some View {
        if let playback = preview.playback, playback.isPlayable {
            VideoPlayer(player: player)
                .accessibilityLabel("動画プレビュー、\(asset.filename)")
                .onAppear {
                    if player == nil {
                        if let token = model.previewPlaybackDidStart(assetID: asset.id) {
                            let sourceAsset = AVURLAsset(url: playback.sourceURL)
                            playbackAsset = sourceAsset
                            playbackToken = token
                            player = AVPlayer(playerItem: AVPlayerItem(asset: sourceAsset))
                        } else {
                            presentPreviewError("安全な取り出しまたはカード照合中のため再生を開始できません。")
                        }
                    }
                }
                .padding(Self.mediaPadding)
        } else {
            Image(
                preview.image.cgImage,
                scale: 1,
                label: Text("画像プレビュー、\(asset.filename)")
            )
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .padding(Self.mediaPadding)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("メディア情報")
        .accessibilityValue(metadataAccessibilityDescription(metadata))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private func loadPreview(pixelSize: MediaPixelSize) async {
        if let loadedPreviewPixelSize,
           loadedPreviewPixelSize.width >= pixelSize.width,
           loadedPreviewPixelSize.height >= pixelSize.height {
            return
        }
        // Once playable media owns AVFoundation objects, resizing the window must not interrupt
        // playback merely to regenerate a poster frame at a different resolution.
        if preview?.playback?.isPlayable == true { return }

        let isInitialLoad = preview == nil
        if isInitialLoad {
            isLoading = true
            errorMessage = nil
            await stopPlaybackAndWait()
        }
        guard let pipeline else {
            if isInitialLoad {
                presentPreviewError("メディア処理を初期化できませんでした。")
                isLoading = false
            }
            return
        }
        do {
            let result = try await pipeline.preview(
                for: asset.url,
                pixelSize: pixelSize,
                priority: .interactive
            )
            try Task.checkCancellation()
            preview = result
            loadedPreviewPixelSize = pixelSize
        } catch is CancellationError {
            return
        } catch {
            if isInitialLoad {
                presentPreviewError(error.localizedDescription)
            }
        }
        if isInitialLoad {
            isLoading = false
        }
    }

    @MainActor
    private func retryPreview() {
        accessibilityFocus = nil
        errorMessage = nil
        preview = nil
        loadedPreviewPixelSize = nil
        isLoading = true
        reloadGeneration = UUID()
    }

    @MainActor
    private func presentPreviewError(_ message: String) {
        errorMessage = message
        Task { @MainActor in
            // Wait for the conditional error view to enter the accessibility tree before focusing it.
            await Task.yield()
            guard errorMessage == message else { return }
            accessibilityFocus = .error
        }
    }

    private func metadataAccessibilityDescription(_ metadata: MediaMetadata) -> String {
        var components = [
            asset.category.rawValue,
            ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file),
        ]
        if let dimensions = metadata.pixelSize, dimensions.width > 0, dimensions.height > 0 {
            components.append("幅 \(dimensions.width) ピクセル、高さ \(dimensions.height) ピクセル")
        }
        if let duration = metadata.durationSeconds,
           let formattedDuration = Self.durationFormatter.string(from: duration),
           !formattedDuration.isEmpty {
            components.append("再生時間 \(formattedDuration)")
        }
        if !metadata.codecs.isEmpty {
            components.append("コーデック \(metadata.codecs.joined(separator: " / "))")
        }
        return components.joined(separator: "、")
    }

    @MainActor
    private func schedulePlaybackTeardown() {
        let retiringToken = playbackToken
        detachAndReleasePlaybackObjects()
        // This task captures only the value-type token. In particular it must not capture an
        // AVPlayer/AVAsset whose lifetime would extend beyond the quiescence acknowledgement.
        player = nil
        playbackAsset = nil
        playbackToken = nil
        Task { @MainActor in
            await model.previewPlaybackObjectsDidRelease(token: retiringToken)
        }
    }

    @MainActor
    private func stopPlaybackAndWait() async {
        let retiringToken = playbackToken
        let hadPlaybackObjects = player != nil || playbackAsset != nil
        detachAndReleasePlaybackObjects()
        player = nil
        playbackAsset = nil
        playbackToken = nil
        guard retiringToken != nil || hadPlaybackObjects else { return }
        await model.previewPlaybackObjectsDidRelease(token: retiringToken)
    }

    /// Performs every synchronous public AVFoundation teardown operation inside one autorelease
    /// pool. The @State references are set to nil by the caller before any asynchronous suspension.
    @MainActor
    private func detachAndReleasePlaybackObjects() {
        autoreleasepool {
            player?.pause()
            player?.cancelPendingPrerolls()
            player?.replaceCurrentItem(with: nil)
            playbackAsset?.cancelLoading()
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

private struct PreviewLoadRequest: Hashable {
    let assetID: UUID
    let pixelSize: MediaPixelSize
    let reloadGeneration: UUID
}

private enum PreviewAccessibilityFocus: Hashable {
    case error
}
