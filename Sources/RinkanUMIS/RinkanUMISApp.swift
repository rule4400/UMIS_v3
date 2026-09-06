import AppKit
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
            UMISSearchCommands()

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
                        modalInteractionIsPresented
                            || (model.route != .ingest && model.route != .rename)
                            || !model.canStartExclusiveOperation
                    )
            }
            CommandMenu("素材") {
                Button("表示中をすべて選択") {
                    // First-responder changes do not invalidate `Commands`, so this command stays
                    // dispatchable and decides at invocation time. Native text editing always wins;
                    // an unavailable/background media selection is a safe no-op.
                    if selectAllInFocusedTextEditor() { return }
                    guard !selectionCommandsAreDisabled else { return }
                    if model.route == .review {
                        model.selectAllReviewAssets()
                    } else {
                        model.selectAll()
                    }
                }
                    .keyboardShortcut("a", modifiers: .command)
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
                    .disabled(
                        model.route != .ingest
                            || !model.canStartExclusiveOperation
                            || model.visibleSelectedIngestAssetIDs.isEmpty
                            || model.selectedSceneID == nil
                            || modalInteractionIsPresented
                    )
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
            CommandMenu("ワークスペース") {
                workspaceCommand("取り込み", route: .ingest, key: "1")
                workspaceCommand("評価・タグ", route: .review, key: "2")
                workspaceCommand("フォルダリネーム", route: .rename, key: "3")
                workspaceCommand("履歴", route: .history, key: "4")
                workspaceCommand("設定", route: .settings, key: "5")
                Divider()
                Button(model.showInspector ? "シーンパネルを隠す" : "シーンパネルを表示") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.route != .ingest || modalInteractionIsPresented)
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
        guard !modalInteractionIsPresented else { return true }
        return switch model.route {
        case .ingest:
            !model.canStartIngestSourceScan
        case .review, .rename:
            !model.canStartExclusiveOperation
        case .history, .settings:
            true
        }
    }

    private var selectionCommandsAreDisabled: Bool {
        guard !modalInteractionIsPresented else { return true }
        return switch model.route {
        case .ingest:
            !model.canPresentMediaPreview
        case .review:
            model.reviewIsScanning || model.reviewMetadataIsWriting || !model.canPresentMediaPreview
        case .rename, .history, .settings:
            true
        }
    }

    private var modalInteractionIsPresented: Bool {
        model.previewAsset != nil
            || model.showAssetExclusionConfirmation
            || model.showEmptyDirectoryExclusionConfirmation
            || model.showCardEraseConfirmation
    }

    private var focusedEditableTextView: NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView
    }

    @discardableResult
    private func selectAllInFocusedTextEditor() -> Bool {
        guard let textView = focusedEditableTextView else { return false }
        textView.selectAll(nil)
        return true
    }

    @ViewBuilder
    private func workspaceCommand(
        _ title: String,
        route: WorkspaceRoute,
        key: KeyEquivalent
    ) -> some View {
        Button {
            model.route = route
        } label: {
            if model.route == route {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        // Command-1...5 remain dedicated to Adobe-compatible rating entry in the review workspace.
        .keyboardShortcut(key, modifiers: [.command, .control])
        .disabled(modalInteractionIsPresented)
    }
}
