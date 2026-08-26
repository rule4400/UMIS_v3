import SwiftUI

@main
struct RinkanUMISApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
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
                Button("ソースを選択…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("保存先を選択…") { model.chooseDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("素材") {
                Button("すべて選択") { model.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("選択を解除") { model.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button("現在のシーンへ割り当て") { model.assignSelectionToCurrentScene() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canStartExclusiveOperation)
            }
        }

        Settings {
            SettingsWorkspaceView()
                .environmentObject(model)
                .frame(width: 620, height: 480)
        }
    }
}
