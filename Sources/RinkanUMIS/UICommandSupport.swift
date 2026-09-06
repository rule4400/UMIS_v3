import SwiftUI

private struct UMISSearchActionFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// The active media browser supplies this action so the standard Find shortcut can move
    /// keyboard focus without coupling the app command menu to one workspace implementation.
    var umisSearchAction: (() -> Void)? {
        get { self[UMISSearchActionFocusedValueKey.self] }
        set { self[UMISSearchActionFocusedValueKey.self] = newValue }
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
