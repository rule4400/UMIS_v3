import SwiftUI

struct EmptyDirectoryExclusionConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reason = "保存先に空フォルダは再作成しない"
    @State private var operatorIdentifier = ""
    @State private var acknowledged = false

    private var canConfirm: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acknowledged
            && !model.emptyDirectoryReviewPaths.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("空フォルダの取り扱いを確認", systemImage: "folder.badge.questionmark")
                .font(.title2.weight(.semibold))

            Text(
                "空フォルダにはコピー検証できるファイルがありません。"
                    + "カード初期化前に、保存先へ再作成しないという利用者の判断を監査証跡として記録します。"
            )
            .foregroundStyle(.secondary)

            GroupBox("確認対象 \(model.emptyDirectoryReviewPaths.count)件") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.emptyDirectoryReviewPaths, id: \.self) { path in
                            Label(path, systemImage: "folder")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 190)
            }

            TextField("除外理由（必須）", text: $reason, axis: .vertical)
                .lineLimit(2 ... 4)
            TextField("確認担当者（必須）", text: $operatorIdentifier)
            Toggle(
                "上記の空フォルダを保存先に再作成しないことを確認しました",
                isOn: $acknowledged
            )

            HStack {
                Button("取り消す") { model.cancelEmptyDirectoryExclusionConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("理由付きで確認") {
                    model.confirmEmptyDirectoryExclusions(
                        reason: reason,
                        operatorIdentifier: operatorIdentifier
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 680)
        .interactiveDismissDisabled()
    }
}
