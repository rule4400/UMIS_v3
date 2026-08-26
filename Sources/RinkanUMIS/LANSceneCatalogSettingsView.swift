import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct LANSceneCatalogSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var coordinator: LANSceneCatalogCoordinator

    @State private var serviceName = "RINKAN-UMIS-Master"
    @State private var experimentalAcknowledged = false
    @State private var pairingOperatorAcknowledged = false
    @State private var typedClientSAS = ""
    @State private var clientInviteData: Data?
    @State private var typedFingerprint = ""
    @State private var typedSAS = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("実験機能 — 本番運用不可", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(
                "署名済み全量スナップショット、revision、Keychainペアリングは実装済みですが、"
                    + "現在の通信はTLS 1.2 PSKです。LAN CA・相互TLS・端末証明書失効が完成するまでproductionEligibleはfalseです。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                TextField("Bonjourサービス名", text: $serviceName)
                    .textFieldStyle(.roundedBorder)
                Button("マスターとして設定") { configureMaster() }
                Button("クライアントとして設定") { configureClient() }
                Button("停止") {
                    runSync {
                        try coordinator.setOffIfIdle()
                        model.lanCatalogEnabled = false
                        clearClientInviteSecret()
                    }
                }
            }
            .disabled(
                model.phase.isBusy
                    || model.renameIsBusy
                    || model.projectOperationInFlight
                    || coordinator.operationInProgress
            )

            LabeledContent("状態", value: coordinator.statusMessage)
            LabeledContent("モード", value: modeDescription)

            if coordinator.mode != .off {
                Toggle(
                    "現方式がmTLS要件を満たさない実験通信であることを理解しました",
                    isOn: $experimentalAcknowledged
                )
                HStack {
                    Button(coordinator.experimentalTransportOptIn ? "実験通信を無効化" : "この起動中だけ実験通信を有効化") {
                        setExperimentalTransport(!coordinator.experimentalTransportOptIn)
                    }
                    .disabled(
                        coordinator.operationInProgress
                            || model.projectOperationInFlight
                            || (!coordinator.experimentalTransportOptIn && !experimentalAcknowledged)
                    )
                    Text("設定変更またはアプリ終了でopt-inは失効します")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            switch coordinator.mode {
            case .off:
                EmptyView()
            case .master:
                masterControls
            case .client:
                clientControls
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .onDisappear { clearClientInviteSecret() }
    }

    private var masterControls: some View {
        GroupBox("マスター（読み取り専用配信）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("現在のシーンを署名・公開") {
                        model.publishCurrentLANSceneCatalog()
                    }
                    .disabled(
                        !model.canStartExclusiveOperation
                            || model.projectOperationInFlight
                            || coordinator.operationInProgress
                    )
                    Text("revision \(coordinator.publishedRevision.map(String.init) ?? "未公開")")
                        .monospacedDigit()
                    Spacer()
                    Button("サーバー開始") { runAsync { try await coordinator.startServer() } }
                        .disabled(
                            !coordinator.experimentalTransportOptIn
                                || coordinator.operationInProgress
                        )
                    Button("停止") { coordinator.stopServer() }
                        .disabled(coordinator.operationInProgress)
                }

                HStack {
                    Button("期限付き招待を書き出す…") { issueAndExportInvite() }
                        .disabled(
                            !coordinator.experimentalTransportOptIn
                                || coordinator.operationInProgress
                        )
                    Text("承認済み端末 \(coordinator.pairedClientCount)")
                        .font(.caption)
                }

                if let invite = coordinator.pendingMasterInvite {
                    inviteSummary(invite)
                    TextField("クライアントに表示されたSASを入力", text: $typedClientSAS)
                    Toggle("別経路でクライアント本人とSASを照合しました", isOn: $pairingOperatorAcknowledged)
                    HStack {
                        Button("このクライアントを承認") {
                            runAsync {
                                try await coordinator.approvePendingPairingInvite(
                                    typedClientSAS: typedClientSAS,
                                    operatorConfirmed: pairingOperatorAcknowledged
                                )
                                typedClientSAS = ""
                                pairingOperatorAcknowledged = false
                            }
                        }
                        .disabled(
                            typedClientSAS.isEmpty
                                || !pairingOperatorAcknowledged
                                || coordinator.operationInProgress
                        )
                        Button("招待を失効", role: .destructive) {
                            runAsync { try await coordinator.revokePendingPairingInvite() }
                        }
                        .disabled(coordinator.operationInProgress)
                    }
                }
            }
            .padding(8)
            .disabled(model.projectOperationInFlight)
        }
    }

    private var clientControls: some View {
        GroupBox("クライアント（署名検証後に明示適用）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("招待ファイルを検査…") { inspectInviteFile() }
                        .disabled(
                            !coordinator.experimentalTransportOptIn
                                || coordinator.operationInProgress
                        )
                    Text(coordinator.clientIsPaired ? "ペアリング済み" : "未ペアリング")
                        .font(.caption)
                }

                if let invite = coordinator.inspectedClientInvite, clientInviteData != nil {
                    inviteSummary(invite)
                    TextField("別経路で確認したカタログ指紋", text: $typedFingerprint)
                    TextField("別経路で確認したSAS", text: $typedSAS)
                    Toggle("指紋とSASをマスター担当者と照合しました", isOn: $pairingOperatorAcknowledged)
                    Button("このマスターを信頼してKeychainへ保存") { confirmClientInvite() }
                        .disabled(
                            typedFingerprint.isEmpty
                                || typedSAS.isEmpty
                                || !pairingOperatorAcknowledged
                                || coordinator.operationInProgress
                        )
                }

                HStack {
                    Button("Bonjour検索開始") { runSync { try coordinator.startDiscovery() } }
                        .disabled(
                            !coordinator.experimentalTransportOptIn
                                || !coordinator.clientIsPaired
                                || coordinator.operationInProgress
                        )
                    Button("検索停止") { coordinator.stopDiscovery() }
                        .disabled(coordinator.operationInProgress)
                    Picker(
                        "マスター",
                        selection: Binding(
                            get: { coordinator.selectedServiceID },
                            set: { next in runSync { try coordinator.selectDiscoveredService(id: next) } }
                        )
                    ) {
                        Text("未選択").tag(String?.none)
                        ForEach(coordinator.discoveredServices) { service in
                            Text(service.name).tag(Optional(service.id))
                        }
                    }
                    .frame(maxWidth: 280)
                    .disabled(coordinator.operationInProgress)
                    Button("署名snapshotを取得") {
                        runAsync { _ = try await coordinator.fetchSelectedService() }
                    }
                    .disabled(
                        coordinator.selectedServiceID == nil
                            || coordinator.operationInProgress
                            || model.projectOperationInFlight
                    )
                }

                if let version = coordinator.receivedVersion {
                    HStack {
                        Text("検証済み revision \(version.revision)・有効シーン \(coordinator.receivedActiveScenes.count)件")
                        Spacer()
                        Button("現在のプロジェクトへ明示適用") {
                            model.applyReceivedLANSceneCatalog(expectedVersion: version)
                        }
                        .disabled(
                            !model.canStartExclusiveOperation
                                || model.projectOperationInFlight
                                || !coordinator.canBeginReceivedSnapshotApplication(
                                    expectedVersion: version
                                )
                        )
                    }
                }
            }
            .padding(8)
            .disabled(model.projectOperationInFlight)
        }
    }

    @ViewBuilder
    private func inviteSummary(_ invite: LANSceneCatalogInvitePresentation) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow { Text("指紋").foregroundStyle(.secondary); Text(invite.catalogFingerprint).monospaced() }
            GridRow { Text("SAS").foregroundStyle(.secondary); Text(invite.sas).font(.title3.monospaced().bold()) }
            GridRow { Text("期限").foregroundStyle(.secondary); Text(invite.expiresAt.rawValue).monospaced() }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private var modeDescription: String {
        switch coordinator.mode {
        case .off: "停止"
        case .master: "マスター"
        case .client: "クライアント"
        }
    }

    private func configureMaster() {
        clearClientInviteSecret()
        runAsync {
            try await coordinator.configureMaster(
                projectID: model.currentProjectIdentifier,
                serviceName: serviceName
            )
            model.lanCatalogEnabled = true
            experimentalAcknowledged = false
        }
    }

    private func configureClient() {
        clearClientInviteSecret()
        runAsync {
            try await coordinator.configureClient(projectID: model.currentProjectIdentifier)
            model.lanCatalogEnabled = true
            experimentalAcknowledged = false
        }
    }

    private func setExperimentalTransport(_ enabled: Bool) {
        runSync {
            try coordinator.setExperimentalTransportOptIn(
                enabled,
                operatorConfirmed: enabled && experimentalAcknowledged
            )
        }
    }

    private func issueAndExportInvite() {
        runAsync {
            _ = try await coordinator.issuePairingInvite()
            let data = try coordinator.exportPendingPairingInviteData()
            let panel = NSSavePanel()
            panel.title = "秘密を含む期限付きLAN招待を書き出す"
            panel.nameFieldStringValue = "UMIS-LAN-Pairing.umis-pairing"
            panel.allowedContentTypes = [.data]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try writeSecretFileAtomically(data, to: url)
        }
    }

    private func inspectInviteFile() {
        let panel = NSOpenPanel()
        panel.title = "LANペアリング招待を検査"
        panel.allowedContentTypes = [.data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clearClientInviteSecret()
        runSync {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            _ = try coordinator.inspectClientPairingInvite(exportedData: data)
            clientInviteData = data
            typedFingerprint = ""
            typedSAS = ""
            pairingOperatorAcknowledged = false
        }
    }

    private func confirmClientInvite() {
        guard let clientInviteData else { return }
        errorMessage = nil
        Task { @MainActor in
            defer { clearClientInviteSecret() }
            do {
                try await coordinator.confirmClientPairing(
                    exportedData: clientInviteData,
                    typedCatalogFingerprint: typedFingerprint,
                    typedSAS: typedSAS,
                    operatorConfirmed: pairingOperatorAcknowledged
                )
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func clearClientInviteSecret() {
        clientInviteData = nil
        typedFingerprint = ""
        typedSAS = ""
        pairingOperatorAcknowledged = false
    }

    /// Writes pairing material without ever exposing a world-readable intermediate file.
    /// The fully written, fsynced 0600 inode is linked into place atomically and never replaces
    /// an existing file. Every failure path removes the private temporary inode.
    private func writeSecretFileAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: false
        )
        let descriptor: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError("秘密招待ファイルの作成", path: temporary.path) }
        var descriptorIsOpen = true
        var shouldRemoveTemporary = true
        var shouldRemoveDestination = false
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if shouldRemoveTemporary {
                temporary.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.unlink(path) }
                }
            }
            if shouldRemoveDestination {
                destination.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.unlink(path) }
                }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError("秘密招待ファイルの書込み", path: temporary.path)
                }
                guard result > 0 else {
                    throw posixError("秘密招待ファイルの書込み", path: temporary.path, code: EIO)
                }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("秘密招待ファイルの同期", path: temporary.path)
        }
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("秘密招待ファイルのclose", path: temporary.path)
        }
        descriptorIsOpen = false

        let linked: Int32 = temporary.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return -1 }
                return Darwin.link(from, to)
            }
        }
        guard linked == 0 else {
            throw posixError("既存ファイルを上書きしないatomic公開", path: destination.path)
        }
        shouldRemoveDestination = true
        let unlinkedTemporary: Int32 = temporary.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.unlink(path)
        }
        guard unlinkedTemporary == 0 else {
            throw posixError("秘密招待の一時リンク削除", path: temporary.path)
        }
        shouldRemoveTemporary = false

        let directoryDescriptor: Int32 = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw posixError("招待ファイル親フォルダのopen", path: directory.path)
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError("招待ファイル親フォルダの同期", path: directory.path)
        }
        shouldRemoveDestination = false
    }

    private func posixError(_ operation: String, path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation)に失敗しました（errno \(code)）",
                NSFilePathErrorKey: path,
            ]
        )
    }

    private func runAsync(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task {
            do { try await operation() }
            catch { errorMessage = String(describing: error) }
        }
    }

    private func runSync(_ operation: () throws -> Void) {
        errorMessage = nil
        do { try operation() }
        catch { errorMessage = String(describing: error) }
    }
}
