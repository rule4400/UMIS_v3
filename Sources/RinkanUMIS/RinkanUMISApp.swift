import SwiftUI

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
            UMISApplicationCommands(model: model)
        }

        Settings {
            SettingsWorkspaceView()
                .environmentObject(model)
                .frame(width: 620, height: 480)
        }
    }

}
