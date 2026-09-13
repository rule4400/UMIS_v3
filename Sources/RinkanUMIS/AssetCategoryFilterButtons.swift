import SwiftUI

/// Both ingest and archive review use the same always-visible category controls.
/// A compact browser wraps the controls instead of hiding choices behind a menu.
struct AssetCategoryFilterButtons: View {
    @Binding var selection: AssetCategory?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 76), spacing: 4)],
            spacing: 4
        ) {
            categoryButton(nil)
            ForEach(AssetCategory.allCases, id: \.self) { category in
                categoryButton(category)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("素材の種類で絞り込み")
    }

    private func categoryButton(_ category: AssetCategory?) -> some View {
        let label = category?.rawValue ?? "すべて"
        return Toggle(isOn: Binding(
            get: { selection == category },
            // Category filters are mutually exclusive. Pressing the active button must not
            // silently turn the filter off; the explicit "すべて" button clears it.
            set: { _ in selection = category }
        )) {
            Label(label, systemImage: category?.systemImage ?? "square.grid.2x2")
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(category == nil ? "すべての種類を表示" : "\(label)だけを表示")
        .accessibilityLabel("素材の種類: \(label)")
        .accessibilityValue(selection == category ? "選択中" : "未選択")
        .accessibilityIdentifier("asset-category-\(category.map { String(describing: $0) } ?? "all")")
    }
}
