import AppKit
import SwiftUI
import UMISCore

private struct UMISSearchActionFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct UMISMainSceneIsActiveFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// The active media browser supplies this action so the standard Find shortcut can move
    /// keyboard focus without coupling the app command menu to one workspace implementation.
    var umisSearchAction: (() -> Void)? {
        get { self[UMISSearchActionFocusedValueKey.self] }
        set { self[UMISSearchActionFocusedValueKey.self] = newValue }
    }

    /// RootView supplies this only from the active main window. A separate Settings scene must not
    /// redirect keyboard commands into media or selection state hidden behind that window.
    var umisMainSceneIsActive: Bool? {
        get { self[UMISMainSceneIsActiveFocusedValueKey.self] }
        set { self[UMISMainSceneIsActiveFocusedValueKey.self] = newValue }
    }
}

struct UMISRatingCommandContext {
    let mutationBlockReason: String?
    let canRefreshMetadata: Bool
    let applyRating: (AdobeRating) -> Void
    let refreshMetadata: () -> Void
}

private struct UMISRatingCommandContextFocusedValueKey: FocusedValueKey {
    typealias Value = UMISRatingCommandContext
}

extension FocusedValues {
    /// Only the active rating workspace provides this context. Keeping rating mutations out of
    /// app-global state prevents shortcuts in Settings or another workspace from changing a stale
    /// background selection.
    var umisRatingCommandContext: UMISRatingCommandContext? {
        get { self[UMISRatingCommandContextFocusedValueKey.self] }
        set { self[UMISRatingCommandContextFocusedValueKey.self] = newValue }
    }
}

struct UMISSearchCommands: Commands {
    @FocusedValue(\.umisSearchAction) private var searchAction

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("素材を検索…") {
                searchAction?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(searchAction == nil)
        }
    }
}

struct UMISApplicationCommands: Commands {
    @ObservedObject private var model: AppModel
    @FocusedValue(\.umisMainSceneIsActive) private var mainSceneIsActive

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some Commands {
        UMISSearchCommands()

        // The safety model intentionally has one media workspace. Multiple media windows sharing
        // one AppModel could otherwise hide a still-running AVPlayer from eject/erase quiescence.
        CommandGroup(replacing: .newItem) {
            Button(openSourceTitle) {
                guard !openSourceCommandIsDisabled else { return }
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
                guard mainSceneIsActive == true,
                      !modalInteractionIsPresented,
                      model.canStartExclusiveOperation else { return }
                if model.route == .rename {
                    model.chooseRenameDestination()
                } else if model.route == .ingest {
                    model.chooseDestination()
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(
                mainSceneIsActive != true
                    || modalInteractionIsPresented
                    || (model.route != .ingest && model.route != .rename)
                    || !model.canStartExclusiveOperation
            )
        }

        CommandMenu("素材") {
            Button("表示中をすべて選択") {
                // Command availability doesn't necessarily refresh when the first responder moves.
                // Keep native text editing available everywhere, then require the active main scene
                // before dispatching any media selection to the shared AppModel.
                if selectAllInFocusedTextEditor() { return }
                guard mainSceneIsActive == true,
                      !selectionCommandsAreDisabled else { return }
                if model.route == .review {
                    model.selectAllReviewAssets()
                } else {
                    model.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("選択を解除") {
                guard mainSceneIsActive == true,
                      !selectionCommandsAreDisabled else { return }
                if model.route == .review {
                    model.clearReviewSelection()
                } else {
                    model.clearSelection()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(mainSceneIsActive != true || selectionCommandsAreDisabled)

            Divider()
            Button("現在のシーンへ割り当て") {
                guard assignToSceneCommandIsEnabled else { return }
                model.assignSelectionToCurrentScene()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!assignToSceneCommandIsEnabled)
        }

        UMISRatingCommands()

        CommandMenu("ワークスペース") {
            workspaceCommand("取り込み", route: .ingest, key: "1")
            workspaceCommand("評価・タグ", route: .review, key: "2")
            workspaceCommand("フォルダリネーム", route: .rename, key: "3")
            workspaceCommand("履歴", route: .history, key: "4")
            workspaceCommand("設定", route: .settings, key: "5")
            Divider()
            Button(model.showInspector ? "シーンパネルを隠す" : "シーンパネルを表示") {
                guard mainSceneIsActive == true,
                      model.route == .ingest,
                      !modalInteractionIsPresented else { return }
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(
                mainSceneIsActive != true
                    || model.route != .ingest
                    || modalInteractionIsPresented
            )
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
        guard mainSceneIsActive == true,
              !modalInteractionIsPresented else { return true }
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

    private var assignToSceneCommandIsEnabled: Bool {
        mainSceneIsActive == true
            && model.route == .ingest
            && model.canInteractWithScenePanel
            && !model.visibleSelectedIngestAssetIDs.isEmpty
            && model.selectedSceneIsVisible
            && !modalInteractionIsPresented
    }

    private var modalInteractionIsPresented: Bool {
        model.previewAsset != nil
            || model.showAssetExclusionConfirmation
            || model.showEmptyDirectoryExclusionConfirmation
            || model.showCardEraseConfirmation
            || model.showCaptureConfigurationSheet
            || model.showProjectLocationSheet
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
            guard mainSceneIsActive == true,
                  !modalInteractionIsPresented else { return }
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
        .disabled(mainSceneIsActive != true || modalInteractionIsPresented)
    }
}

struct UMISRatingCommands: Commands {
    @FocusedValue(\.umisRatingCommandContext) private var context

    var body: some Commands {
        CommandMenu("評価") {
            // Keep this row structurally present while its title changes. Besides explaining why
            // commands are unavailable, a stable command tree avoids rebuilding the open menu as
            // selection and metadata state change.
            Button(ratingStatusTitle) {}
                .disabled(true)
            Divider()

            Button("評価なし") { applyRating(.unrated) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(ratingCommandsAreDisabled)
            ForEach(1 ... 5, id: \.self) { stars in
                Button("\(stars)つ星") {
                    applyRating(AdobeRating(rawValue: stars) ?? .unrated)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .command)
                .disabled(ratingCommandsAreDisabled)
            }
            Divider()
            Button("除外評価") { applyRating(.rejected) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(ratingCommandsAreDisabled)
            Button("メタデータを再読み込み") {
                context?.refreshMetadata()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(context?.canRefreshMetadata != true)
        }
    }

    private var ratingCommandsAreDisabled: Bool {
        guard let context else { return true }
        return context.mutationBlockReason != nil
    }

    private var ratingStatusTitle: String {
        guard let context else {
            return "「評価・タグ」画面で素材を選択してください"
        }
        return context.mutationBlockReason ?? "選択中の素材へ評価を適用できます"
    }

    private func applyRating(_ rating: AdobeRating) {
        context?.applyRating(rating)
    }
}
