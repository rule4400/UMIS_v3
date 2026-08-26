import SwiftUI

struct AssetExclusionConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reason = ""
    @State private var operatorIdentifier = ""
    @State private var acknowledged = false

    private var canConfirm: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operatorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acknowledged
            && !model.pendingExclusionAssets.isEmpty
    }

    private var pendingBytes: Int64 {
        model.pendingExclusionAssets.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("取り込まない素材を個別に確認", systemImage: "exclamationmark.shield")
                .font(.title2.weight(.semibold))

            Text(
                "ここで除外した素材はコピーされません。カード初期化時には原本も消えるため、"
                    + "ユーザーが不要と判断した項目だけを、理由と担当者を記録して除外してください。"
            )
            .foregroundStyle(.secondary)

            GroupBox("除外候補 \(model.pendingExclusionAssets.count)件・\(ByteCountFormatter.string(fromByteCount: pendingBytes, countStyle: .file))") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.pendingExclusionAssets) { asset in
                            HStack {
                                Text(asset.relativePath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(8)
            }

            TextField("除外理由（必須）", text: $reason, axis: .vertical)
                .lineLimit(2 ... 4)
            TextField("確認担当者（必須）", text: $operatorIdentifier)

            Toggle(
                "上記の各ファイルを取り込まないこと、およびカード初期化後は復元できないことを確認しました",
                isOn: $acknowledged
            )

            HStack {
                Button("取り消す") { model.cancelPendingAssetExclusion() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("理由付きで除外", role: .destructive) {
                    model.confirmPendingAssetExclusion(
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
        .frame(width: 660)
        .interactiveDismissDisabled()
    }
}
