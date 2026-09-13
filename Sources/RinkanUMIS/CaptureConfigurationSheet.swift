import SwiftUI
import UMISCore

/// All controls mutate a local draft. The model validates both selections before publishing either.
struct CaptureConfigurationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureConfigurationDraft
    @State private var localError: String?

    init(draft: CaptureConfigurationDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("撮影者・カードNoを選択").font(.title2.weight(.semibold))
                Text("登録カードを選ぶと撮影者も切り替わります。必要に応じて撮影者を選び直せます。")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(alignment: .top, spacing: 16) {
                cardPane
                photographerPane
            }
            .frame(maxHeight: .infinity)

            if let error = model.captureConfigurationError ?? localError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .lineLimit(3).help(error)
            }
            Text("「決定」でこのプロジェクトに反映します。次回も利用するにはプロジェクトを保存してください。")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
            Divider()
            HStack {
                Text("キャンセルでは変更しません")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("決定") {
                    if model.applyCaptureConfiguration(draft) {
                        close()
                    } else {
                        localError = "現在の状態では反映できません。処理の完了後に選び直してください。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 650, height: 550)
    }

    private var cardPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("1. カードNo", systemImage: "sdcard").font(.headline)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ConfigurationChoiceButton(
                        title: "未指定／新しく入力",
                        subtitle: "登録にないカードはこちら",
                        isSelected: draft.selectedCardID == nil
                    ) {
                        draft.selectedCardID = nil
                    }
                    ForEach(model.availableProjectCards, id: \.id.rawValue) { card in
                        ConfigurationChoiceButton(
                            title: "カードNo \(card.cardNumber)",
                            subtitle: photographerName(for: card) ?? "撮影者 未登録",
                            isSelected: draft.selectedCardID == card.id.rawValue
                        ) {
                            draft.selectCard(
                                id: card.id.rawValue,
                                cards: model.availableProjectCards,
                                photographers: model.availableProjectPhotographers
                            )
                        }
                    }
                }
                .padding(2)
            }
            if draft.selectedCardID == nil {
                TextField("カードNoを入力（例：0007）", text: $draft.newCardNumber)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("新しいカードNo")
                Text("先頭の0もそのまま保持します")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var photographerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("2. 撮影者", systemImage: "person.crop.circle").font(.headline)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ConfigurationChoiceButton(
                        title: "未指定／新しく入力",
                        subtitle: "登録にない撮影者はこちら",
                        isSelected: draft.selectedPhotographerID == nil
                    ) {
                        draft.selectedPhotographerID = nil
                    }
                    ForEach(model.availableProjectPhotographers, id: \.id.rawValue) { person in
                        ConfigurationChoiceButton(
                            title: person.displayName,
                            subtitle: nil,
                            isSelected: draft.selectedPhotographerID == person.id.rawValue
                        ) {
                            draft.selectedPhotographerID = person.id.rawValue
                        }
                    }
                }
                .padding(2)
            }
            if draft.selectedPhotographerID == nil {
                TextField("撮影者名を入力", text: $draft.newPhotographerName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("新しい撮影者名")
                Text("空欄なら撮影者は未指定になります")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func photographerName(for card: CardDefinition) -> String? {
        model.availableProjectPhotographers.first { $0.id == card.photographerID }?.displayName
    }

    private func close() {
        model.showCaptureConfigurationSheet = false
        dismiss()
    }
}

private struct ConfigurationChoiceButton: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(isSelected ? .semibold : .regular)).lineLimit(2)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title)、\($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(title)
    }
}

struct ProjectLocationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var localError: String?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会場を追加").font(.title2.weight(.semibold))
            Text("追加した会場はプルダウンから選択できます。既存の会場名は変更しません。")
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            TextField("会場名", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .accessibilityLabel("追加する会場名")
            if let error = model.projectLocationError ?? localError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).lineLimit(3)
            }
            Text("次回も利用するにはプロジェクトを保存してください。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { close() }.keyboardShortcut(.cancelAction)
                Button("追加して選択") {
                    if model.addProjectLocation(named: name) {
                        close()
                    } else {
                        localError = "現在は追加できません。処理の完了後にもう一度お試しください。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { nameIsFocused = true }
    }

    private func close() {
        model.showProjectLocationSheet = false
        dismiss()
    }
}
