import AppKit
import SwiftUI
import UMISCore

/// Read-only admission. This policy never creates an erase token or weakens the resolver's
/// hardware proof, insertion identity, or durable-quarantine registration requirements.
enum CardAutoSelectionPolicy {
    enum Decision: Equatable {
        case noCandidate
        case preserveExistingSource
        case waitForDetection
        case waitForInteraction
        case requireChoice
        case select(SourceVolumeID, UUID)
    }

    static func eligibleCandidates(_ identities: [VolumeIdentity]) -> [VolumeIdentity] {
        let unique = Dictionary(grouping: identities, by: \.id).values.compactMap { group -> VolumeIdentity? in
            guard let identity = group.first, group.allSatisfy({ $0 == identity }), isEligible(identity) else {
                return nil
            }
            return identity
        }
        return unique.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison == .orderedSame {
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    static func isEligible(_ identity: VolumeIdentity) -> Bool {
        identity.identityStrength == .strongForCurrentInsertion
            && identity.physicalMediaEvidence?.hasTrustedCameraCardProof == true
            && identity.mediaUUID != nil
            && identity.volumeUUID != nil
            && identity.mediaRegistryEntryID != nil && identity.mediaRegistryEntryID != 0
            && identity.parentChainDigest?.isEmpty == false
            && identity.mountURL?.isFileURL == true
            && identity.mountURL?.standardizedFileURL.path != "/"
            && identity.capacityBytes > 0
            && !identity.isInternal
            && !identity.isNetwork
            && !identity.isDiskImage
            && identity.isRemovable
            && identity.isEjectable
            && identity.isWritable
            && identity.partitionCount == 1
    }

    static func decision(
        candidates: [VolumeIdentity],
        hasExistingSource: Bool,
        detectionInProgress: Bool,
        interactionAllowsSelection: Bool,
        recognizedCardCount: Int? = nil
    ) -> Decision {
        if hasExistingSource { return .preserveExistingSource }
        if detectionInProgress { return .waitForDetection }
        let candidates = eligibleCandidates(candidates)
        if let recognizedCardCount, recognizedCardCount > 1 { return .requireChoice }
        guard !candidates.isEmpty else { return .noCandidate }
        guard candidates.count == 1 else { return .requireChoice }
        guard interactionAllowsSelection else { return .waitForInteraction }
        return .select(candidates[0].id, candidates[0].arrivalGeneration)
    }
}

struct CardAutoSelectionInteractionState {
    var route: WorkspaceRoute = .ingest
    var mainWindowIsKey = true
    var explicitInteractionBlocked = false
    var captureConfigurationVisible = false
    var projectLocationVisible = false
    var previewVisible = false
    var eraseConfirmationVisible = false
    var assetExclusionConfirmationVisible = false
    var emptyDirectoryConfirmationVisible = false
    var nativeModalVisible = false
    var attachedSheetVisible = false

    var allowsSelection: Bool {
        route == .ingest && mainWindowIsKey && !explicitInteractionBlocked
            && !captureConfigurationVisible && !projectLocationVisible && !previewVisible
            && !eraseConfirmationVisible && !assetExclusionConfirmationVisible
            && !emptyDirectoryConfirmationVisible && !nativeModalVisible && !attachedSheetVisible
    }
}

/// Observe the actual hosting window rather than guessing a Settings-window title. A source
/// must not start scanning behind another app window, a sheet, or a native open panel.
struct CardAutoSelectionWindowObserver: NSViewRepresentable {
    var onKeyWindowChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onKeyWindowChange = onKeyWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onKeyWindowChange = onKeyWindowChange
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class WindowObserverView: NSView {
        var onKeyWindowChange: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else {
                publish(false)
                return
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                // Selector observers are non-retaining and automatically stop at deallocation.
                // AppKit posts these window notifications on the main thread. Avoid carrying
                // non-Sendable block-observer tokens into NSView's nonisolated deinitializer.
                NotificationCenter.default.addObserver(
                    self, selector: #selector(keyWindowChanged(_:)), name: name, object: window
                )
            }
            publish(window.isKeyWindow)
        }

        private func publish(_ isKey: Bool) {
            // NSViewRepresentable may be attaching during a SwiftUI update.
            Task { @MainActor [weak self] in self?.onKeyWindowChange?(isKey) }
        }

        @objc private func keyWindowChanged(_ notification: Notification) {
            guard let observedWindow = notification.object as? NSWindow,
                  observedWindow === window else { return }
            publish(observedWindow.isKeyWindow)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            onKeyWindowChange?(false)
            onKeyWindowChange = nil
        }
    }
}
