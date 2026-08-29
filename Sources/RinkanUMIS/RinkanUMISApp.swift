import SwiftUI
import UMISCore

@main
struct RinkanUMISApp: App {
    @StateObject private var model = AppModel()

    var body: some SwiftUI.Scene {
        Window("RINKAN UMIS", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_360, height: 860)
        .commands {
            // The initial safety model intentionally has one media workspace. Multiple windows
            // sharing one AppModel could otherwise hide a still-running AVPlayer from eject/erase
            // quiescence tracking.
            CommandGroup(replacing: .newItem) {
                Button(openSourceTitle) {
                    switch model.route {
                    case .ingest: model.chooseSource()
                    case .review: model.chooseReviewSource()
                    case .rename: model.chooseRenameSource()
                    case .history, .settings: break
                    }
                }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(openSourceCommandIsDisabled)
                Button(openDestinationTitle) {
                    if model.route == .rename {
                        model.chooseRenameDestination()
                    } else {
                        model.chooseDestination()
                    }
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(
                        (model.route != .ingest && model.route != .rename)
                            || !model.canStartExclusiveOperation
                    )
            }
            CommandMenu("素材") {
                Button("表示中をすべて選択") {
                    if model.route == .review {
                        model.selectAllReviewAssets()
                    } else {
                        model.selectAll()
                    }
                }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(selectionCommandsAreDisabled)
                Button("選択を解除") {
                    if model.route == .review {
                        model.clearReviewSelection()
                    } else {
                        model.clearSelection()
                    }
                }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(selectionCommandsAreDisabled)
                Divider()
                Button("現在のシーンへ割り当て") { model.assignSelectionToCurrentScene() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.route != .ingest || !model.canStartExclusiveOperation)
            }
            CommandMenu("評価") {
                Button("評価なし") { model.applyReviewRating(.unrated) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.route != .review || !model.canMutateReviewMetadata)
                ForEach(1 ... 5, id: \.self) { stars in
                    Button("\(stars)つ星") {
                        model.applyReviewRating(AdobeRating(rawValue: stars) ?? .unrated)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .command)
                    .disabled(model.route != .review || !model.canMutateReviewMetadata)
                }
                Divider()
                Button("除外評価") { model.applyReviewRating(.rejected) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.route != .review || !model.canMutateReviewMetadata)
                Button("メタデータを再読み込み") { model.refreshReviewMetadata() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(
                        model.route != .review
                            || model.reviewAssets.isEmpty
                            || model.reviewIsScanning
                            || model.reviewMetadataIsLoading
                            || model.reviewMetadataIsWriting
                            || !model.canStartExclusiveOperation
                    )
            }
        }

        Settings {
            SettingsWorkspaceView()
                .environmentObject(model)
                .frame(width: 620, height: 480)
        }
    }

    private var openSourceTitle: String {
        switch model.route {
        case .ingest: "取り込みソースを選択…"
        case .review: "評価するアーカイブを選択…"
        case .rename: "リネーム元を選択…"
        case .history, .settings: "フォルダを選択…"
        }
    }

    private var openDestinationTitle: String {
        model.route == .rename ? "リネーム済みコピー先を選択…" : "保存先を選択…"
    }

    private var openSourceCommandIsDisabled: Bool {
        switch model.route {
        case .ingest:
            !model.canStartIngestSourceScan
        case .review, .rename:
            !model.canStartExclusiveOperation
        case .history, .settings:
            true
        }
    }

    private var selectionCommandsAreDisabled: Bool {
        switch model.route {
        case .ingest:
            !model.canPresentMediaPreview
        case .review:
            model.reviewIsScanning || model.reviewMetadataIsWriting || !model.canPresentMediaPreview
        case .rename, .history, .settings:
            true
        }
    }
}
