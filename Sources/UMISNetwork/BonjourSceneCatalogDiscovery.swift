import Foundation
import Network

public struct DiscoveredSceneCatalogService: Hashable, Sendable, Identifiable {
    public let name: String
    public let type: String
    public let domain: String
    public let interfaceName: String?

    public var id: String {
        [name, type, domain, interfaceName ?? ""].joined(separator: "\u{1f}")
    }

    public init(name: String, type: String, domain: String, interfaceName: String?) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceName = interfaceName
    }
}

public enum SceneCatalogDiscoveryState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case permissionDenied
    case waiting(reason: String)
    case failed(reason: String)
    case stopped
}

public enum SceneCatalogDiscoveryEvent: Equatable, Sendable {
    case stateChanged(SceneCatalogDiscoveryState)
    case serviceFound(DiscoveredSceneCatalogService)
    case serviceLost(DiscoveredSceneCatalogService)
}

public protocol SceneCatalogDiscovering: Sendable {
    func events() -> AsyncStream<SceneCatalogDiscoveryEvent>
    func start()
    func stop()
}

/// Stoppable Bonjour browser for `_umis-scene._tcp` advertisements.
///
/// Results are discovery hints only. This type deliberately exposes neither a
/// trust decision nor a network client; pairing fingerprints and signature
/// verification remain mandatory before catalog data is accepted.
public final class BonjourSceneCatalogDiscovery: SceneCatalogDiscovering, @unchecked Sendable {
    public static let serviceType = "_umis-scene._tcp"

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var browser: NWBrowser?
    private var knownServices: Set<DiscoveredSceneCatalogService> = []
    private var continuations: [UUID: AsyncStream<SceneCatalogDiscoveryEvent>.Continuation] = [:]
    private var state: SceneCatalogDiscoveryState = .idle

    public init(queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(
            label: "jp.rinkan.umis.scene-catalog-discovery",
            qos: .utility
        )
    }

    public func events() -> AsyncStream<SceneCatalogDiscoveryEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[streamID] = continuation
            let currentState = state
            let currentServices = knownServices
            lock.unlock()
            continuation.yield(.stateChanged(currentState))
            for service in currentServices.sorted(by: { $0.id < $1.id }) {
                continuation.yield(.serviceFound(service))
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(streamID)
            }
        }
    }

    public func start() {
        let newBrowser: NWBrowser
        lock.lock()
        if browser != nil {
            lock.unlock()
            return
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        newBrowser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser = newBrowser
        lock.unlock()

        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] browserState in
            guard let self, let newBrowser, self.isCurrent(newBrowser) else { return }
            switch browserState {
            case .setup:
                self.publishState(.preparing)
            case .ready:
                self.publishState(.ready)
            case .waiting(let error):
                if Self.isPermissionDenied(error) {
                    self.publishState(.permissionDenied)
                } else {
                    self.publishState(.waiting(reason: String(describing: error)))
                }
            case .failed(let error):
                if Self.isPermissionDenied(error) {
                    self.publishState(.permissionDenied)
                } else {
                    self.publishState(.failed(reason: String(describing: error)))
                }
                self.clearIfCurrent(newBrowser)
            case .cancelled:
                self.publishState(.stopped)
                self.clearIfCurrent(newBrowser)
            @unknown default:
                self.publishState(.waiting(reason: "unknown Network.framework state"))
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self, weak newBrowser] results, _ in
            guard let self, let newBrowser, self.isCurrent(newBrowser) else { return }
            self.updateServices(results)
        }
        publishState(.preparing)
        newBrowser.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let activeBrowser = browser
        browser = nil
        let removedServices = knownServices
        knownServices.removeAll()
        lock.unlock()
        activeBrowser?.cancel()
        for service in removedServices { publish(.serviceLost(service)) }
        publishState(.stopped)
    }

    deinit {
        browser?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    private func updateServices(_ results: Set<NWBrowser.Result>) {
        let mapped = Set(results.compactMap(Self.mapResult))
        lock.lock()
        let added = mapped.subtracting(knownServices)
        let removed = knownServices.subtracting(mapped)
        knownServices = mapped
        lock.unlock()
        for service in added.sorted(by: { $0.id < $1.id }) {
            publish(.serviceFound(service))
        }
        for service in removed.sorted(by: { $0.id < $1.id }) {
            publish(.serviceLost(service))
        }
    }

    private static func mapResult(_ result: NWBrowser.Result) -> DiscoveredSceneCatalogService? {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            return nil
        }
        return DiscoveredSceneCatalogService(
            name: name,
            type: type,
            domain: domain,
            interfaceName: interface?.name
        )
    }

    private static func isPermissionDenied(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EACCES || code == .EPERM
    }

    private func publishState(_ nextState: SceneCatalogDiscoveryState) {
        lock.lock()
        guard state != nextState else {
            lock.unlock()
            return
        }
        state = nextState
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(.stateChanged(nextState)) }
    }

    private func publish(_ event: SceneCatalogDiscoveryEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(event) }
    }

    private func isCurrent(_ candidate: NWBrowser) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return browser === candidate
    }

    private func clearIfCurrent(_ candidate: NWBrowser) {
        lock.lock()
        if browser === candidate { browser = nil }
        lock.unlock()
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
