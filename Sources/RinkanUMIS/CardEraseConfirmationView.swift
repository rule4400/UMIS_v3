import SwiftUI

struct CardEraseConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmationText = ""
    @State private var acknowledged = false
    @State private var acknowledgedExclusions = false

    private var confirmationMatches: Bool {
        confirmationText == "初期化"
            && acknowledged
            && ((model.explicitExclusionAssets.isEmpty && model.emptyDirectoryReviewPaths.isEmpty)
                || acknowledgedExclusions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("カードを完全に初期化します")
                        .font(.title2.weight(.bold))
                    Text("この操作は取り消せず、カード内の全データが消去されます。")
                        .foregroundStyle(.red)
                }
            }

            GroupBox("実行対象（表示名では認可していません）") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("現在のカード")
                            .foregroundStyle(.secondary)
                        Text(model.pendingCardDisplayName)
                    }
                    GridRow {
                        Text("カードNo")
                            .foregroundStyle(.secondary)
                        Text(model.cardNumber.isEmpty ? "未設定" : model.cardNumber)
                    }
                    GridRow {
                        Text("物理ID")
                            .foregroundStyle(.secondary)
                        Text(model.pendingCardIdentitySummary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("容量")
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: model.pendingCardCapacityBytes,
                            countStyle: .file
                        ))
                        .monospacedDigit()
                    }
                    GridRow {
                        Text("初期化形式")
                            .foregroundStyle(.secondary)
                        Text("ExFAT / \(model.pendingCardFormatLabel)")
                    }
                    GridRow {
                        Text("最終検証")
                            .foregroundStyle(.secondary)
                        Text(model.pendingFinalVerificationAt?.formatted(date: .numeric, time: .standard) ?? "未確認")
                    }
                    GridRow {
                        Text("Required / 検証済み")
                            .foregroundStyle(.secondary)
                        Text("\(model.pendingRequiredAssetCount) / \(model.pendingVerifiedDeliveryCount)")
                            .monospacedDigit()
                    }
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("全Required Setのコピー元と保存先を再読し、SHA-256一致を事前確認済み", systemImage: "checkmark.shield.fill")
                Label("ジャーナルのdurable commitと同一挿入世代を確認済み", systemImage: "checkmark.shield.fill")
                Label("このボタンを押した後にも全件を再検証し、許可発行直後に一度だけ実行", systemImage: "arrow.triangle.2.circlepath")
                Label("Returnキーだけでは初期化を実行できません", systemImage: "keyboard")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle(
                "対象カードと保存先を自分で確認し、このカードの全データが消えることを理解しました",
                isOn: $acknowledged
            )

            if !model.explicitExclusionAssets.isEmpty || !model.emptyDirectoryReviewPaths.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "コピーしない素材 \(model.explicitExclusionAssets.count)件・"
                                + ByteCountFormatter.string(
                                    fromByteCount: model.explicitExclusionTotalBytes,
                                    countStyle: .file
                                )
                                + " / 再作成しない空フォルダ \(model.emptyDirectoryReviewPaths.count)件"
                        )
                        .font(.headline)
                        .foregroundStyle(.red)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(model.explicitExclusionAssets) { asset in
                                    Text("• \(asset.relativePath)")
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                ForEach(model.emptyDirectoryReviewPaths, id: \.self) { path in
                                    Text("• \(path) [空フォルダ]")
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                        Toggle(
                            "この一覧は保存先へ配送・再作成されず、初期化で消えることを別途確認しました",
                            isOn: $acknowledgedExclusions
                        )
                    }
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("確認のため「初期化」と入力してください")
                    .font(.caption)
                TextField("初期化", text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取り消す") { model.cancelPendingCardInitialization() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("カードを初期化", role: .destructive) {
                    model.confirmCardInitialization()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!confirmationMatches)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
}
