@preconcurrency import AppKit
import Foundation
import UMISCore

/// A mount lifecycle observation emitted by `NSWorkspace`. The notification URL is the mounted
/// volume root, not a caller-selected destination folder below that volume.
struct NetworkMountLifecycleEvent: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case mounted
    case unmounted
  }

  let kind: Kind
  let mountURL: URL
  /// Event-source-owned epoch advanced synchronously inside the NSWorkspace callback, before
  /// asynchronous delivery to the monitor actor.
  let lifecycleEpoch: UUID
}

/// Injectable boundary around `NSWorkspace` so mount/unmount ordering can be tested without a NAS.
protocol NetworkMountLifecycleEventSource: Sendable {
  func setEventHandler(
    _ handler: @escaping @Sendable (NetworkMountLifecycleEvent) async -> Void
  )

  /// Returns the source-owned current lifecycle epoch for one normalized mount root. The first
  /// query creates an epoch; every mount/unmount callback replaces it synchronously.
  func currentLifecycleEpoch(for mountURL: URL) -> UUID
}

/// Production event source. A source supports one monitor for its lifetime.
final class NSWorkspaceNetworkMountLifecycleEventSource: NetworkMountLifecycleEventSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let notificationCenter: NotificationCenter
  private var handler: (@Sendable (NetworkMountLifecycleEvent) async -> Void)?
  private var observerTokens: [NSObjectProtocol] = []
  private var lifecycleEpochsByMountPath: [String: UUID] = [:]
  /// Tail of the asynchronous delivery chain. `NSLock` gives lifecycle callbacks a total order;
  /// chaining handler work while that same lock is held preserves that order after the callback
  /// crosses into Swift concurrency. Independent unstructured tasks may start in reverse order.
  private var deliveryTail: Task<Void, Never>?
  private var started = false

  init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
    self.notificationCenter = notificationCenter
  }

  func setEventHandler(
    _ handler: @escaping @Sendable (NetworkMountLifecycleEvent) async -> Void
  ) {
    let shouldStart = lock.withLock { () -> Bool in
      self.handler = handler
      guard !started else { return false }
      started = true
      return true
    }
    guard shouldStart else { return }

    let mounted = notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.publish(notification, mounted: true)
    }
    let unmounted = notificationCenter.addObserver(
      forName: NSWorkspace.didUnmountNotification,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.publish(notification, mounted: false)
    }
    lock.withLock {
      observerTokens = [mounted, unmounted]
    }
  }

  private func publish(_ notification: Notification, mounted: Bool) {
    guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
      // A lifecycle notification without an observed volume root cannot be attributed
      // safely. Rotate every session already observed by this source; false-positive plan
      // invalidation is preferable to reusing a possibly stale network generation.
      lock.withLock {
        for key in Array(lifecycleEpochsByMountPath.keys) {
          lifecycleEpochsByMountPath[key] = UUID()
        }
      }
      return
    }
    let normalizedURL = Self.normalizedMountURL(volumeURL)
    lock.withLock {
      let epoch = UUID()
      lifecycleEpochsByMountPath[Self.mountKey(normalizedURL)] = epoch
      let event = NetworkMountLifecycleEvent(
        kind: mounted ? .mounted : .unmounted,
        mountURL: normalizedURL,
        lifecycleEpoch: epoch
      )
      guard let currentHandler = handler else { return }

      let predecessor = deliveryTail
      deliveryTail = Task {
        await predecessor?.value
        guard !Task.isCancelled else { return }
        await currentHandler(event)
      }
    }
  }

  func currentLifecycleEpoch(for mountURL: URL) -> UUID {
    let key = Self.mountKey(mountURL)
    return lock.withLock {
      if let existing = lifecycleEpochsByMountPath[key] { return existing }
      let created = UUID()
      lifecycleEpochsByMountPath[key] = created
      return created
    }
  }

  deinit {
    let (tokens, pendingDelivery) = lock.withLock { (observerTokens, deliveryTail) }
    for token in tokens {
      notificationCenter.removeObserver(token)
    }
    pendingDelivery?.cancel()
  }

  private static func normalizedMountURL(_ url: URL) -> URL {
    URL(
      fileURLWithPath: url.standardizedFileURL.path.precomposedStringWithCanonicalMapping,
      isDirectory: true
    )
  }

  private static func mountKey(_ url: URL) -> String {
    url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
  }
}

/// Stable properties of one observed network mount. Mutable directory attributes (size, mtime,
/// contents) are deliberately excluded; a copy must not rotate the mount generation by itself.
struct NetworkMountSignature: Hashable, Sendable {
  let mountRoot: URL
  let volumeUUID: String?
  let fileSystem: String
  let device: UInt64
  let rootInode: UInt64

  init(
    mountRoot: URL,
    volumeUUID: String?,
    fileSystem: String,
    device: UInt64,
    rootInode: UInt64
  ) {
    self.mountRoot = Self.normalizedMountRoot(mountRoot)
    self.volumeUUID = volumeUUID?.nilIfBlank?.precomposedStringWithCanonicalMapping
    self.fileSystem = fileSystem.precomposedStringWithCanonicalMapping
    self.device = device
    self.rootInode = rootInode
  }

  private static func normalizedMountRoot(_ url: URL) -> URL {
    URL(
      fileURLWithPath: url.standardizedFileURL.path.precomposedStringWithCanonicalMapping,
      isDirectory: true
    )
  }
}

struct NetworkMountObservation: Hashable, Sendable {
  let mountRoot: URL
  let isNetwork: Bool
  let networkSignature: NetworkMountSignature?

  init(mountRoot: URL, isNetwork: Bool, networkSignature: NetworkMountSignature?) {
    self.mountRoot = URL(
      fileURLWithPath: mountRoot.standardizedFileURL.path.precomposedStringWithCanonicalMapping,
      isDirectory: true
    )
    self.isNetwork = isNetwork
    self.networkSignature = networkSignature
  }
}

/// Injectable volume-root/stat reader. The system implementation uses Foundation's volume
/// locality/root observation and POSIX device/inode identity. Any missing property is an error.
struct NetworkMountSignatureReader: Sendable {
  let read: @Sendable (URL) throws -> NetworkMountObservation

  static let system = NetworkMountSignatureReader { destinationURL in
    let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw UMISCoreError.invalidPath(
        "Destination does not exist or is not a readable directory: \(destination.path)"
      )
    }

    let keys: Set<URLResourceKey> = [
      .volumeURLKey,
      .volumeIsLocalKey,
      .volumeUUIDStringKey,
      .volumeLocalizedFormatDescriptionKey,
    ]
    let values: URLResourceValues
    do {
      values = try destination.resourceValues(forKeys: keys)
    } catch {
      throw UMISCoreError.eraseNotEligible(
        "Destination mount identity could not be read"
      )
    }
    guard let volumeRoot = values.volume?.standardizedFileURL.resolvingSymlinksInPath(),
      let isLocal = values.volumeIsLocal
    else {
      throw UMISCoreError.eraseNotEligible(
        "Destination mount root or locality is unknown"
      )
    }
    guard !isLocal else {
      return NetworkMountObservation(
        mountRoot: volumeRoot,
        isNetwork: false,
        networkSignature: nil
      )
    }
    guard let fileSystem = values.volumeLocalizedFormatDescription?.nilIfBlank else {
      throw UMISCoreError.eraseNotEligible(
        "Network destination filesystem identity is unknown"
      )
    }
    let rootFingerprint: FileFingerprint
    do {
      rootFingerprint = try FileFingerprint.capture(
        at: volumeRoot,
        followSymbolicLinks: true
      )
    } catch {
      throw UMISCoreError.eraseNotEligible(
        "Network destination root stat identity could not be read"
      )
    }
    let signature = NetworkMountSignature(
      mountRoot: volumeRoot,
      volumeUUID: values.volumeUUIDString,
      fileSystem: fileSystem,
      device: rootFingerprint.device,
      rootInode: rootFingerprint.inode
    )
    return NetworkMountObservation(
      mountRoot: volumeRoot,
      isNetwork: true,
      networkSignature: signature
    )
  }
}

/// Process-local authority for network mount generations. The authority ID intentionally changes
/// on every app launch, so a plan created by a previous process cannot be resumed against a NAS
/// without being reviewed and rebuilt. Nothing is persisted or caller-supplied.
actor NetworkMountLifecycleMonitor {
  nonisolated let authorityID: UUID

  private struct Session: Sendable {
    let signature: NetworkMountSignature
    let lifecycleEpoch: UUID
    let generation: UUID
  }

  private let signatureReader: NetworkMountSignatureReader
  private let eventSource: any NetworkMountLifecycleEventSource
  private let generationFactory: @Sendable () -> UUID
  private var sessionsByMountPath: [String: Session] = [:]

  init() {
    self.init(
      authorityID: UUID(),
      eventSource: NSWorkspaceNetworkMountLifecycleEventSource(),
      signatureReader: .system,
      generationFactory: UUID.init
    )
  }

  /// Internal injection point used by app unit tests. Production never accepts authority or
  /// generation strings from a caller.
  init(
    authorityID: UUID,
    eventSource: any NetworkMountLifecycleEventSource,
    signatureReader: NetworkMountSignatureReader,
    generationFactory: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.authorityID = authorityID
    self.eventSource = eventSource
    self.signatureReader = signatureReader
    self.generationFactory = generationFactory
    eventSource.setEventHandler { [weak self] event in
      await self?.observe(event)
    }
  }

  /// Returns no witness for a local volume. A network volume is accepted only when the current
  /// root/stat observation is complete; unreadable or contradictory observations throw.
  func witness(for destinationURL: URL) throws -> NetworkMountLifecycleWitness? {
    let observation = try signatureReader.read(destinationURL)
    guard observation.isNetwork else {
      sessionsByMountPath.removeValue(forKey: Self.mountKey(observation.mountRoot))
      return nil
    }
    guard let signature = observation.networkSignature,
      Self.mountKey(signature.mountRoot) == Self.mountKey(observation.mountRoot),
      !signature.fileSystem.isEmpty,
      signature.device != 0,
      signature.rootInode != 0
    else {
      sessionsByMountPath.removeValue(forKey: Self.mountKey(observation.mountRoot))
      throw UMISCoreError.eraseNotEligible(
        "Network destination mount signature is incomplete"
      )
    }

    let key = Self.mountKey(observation.mountRoot)
    // This synchronous read observes NSWorkspace callback state even when its actor delivery
    // Task has not run yet, closing the notification-to-actor stale-generation window.
    let lifecycleEpoch = eventSource.currentLifecycleEpoch(for: observation.mountRoot)
    let session: Session
    if let current = sessionsByMountPath[key],
      current.signature == signature,
      current.lifecycleEpoch == lifecycleEpoch
    {
      session = current
    } else {
      session = Session(
        signature: signature,
        lifecycleEpoch: lifecycleEpoch,
        generation: generationFactory()
      )
      sessionsByMountPath[key] = session
    }
    return NetworkMountLifecycleWitness(
      authorityID: authorityID,
      generation: session.generation
    )
  }

  private func observe(_ event: NetworkMountLifecycleEvent) {
    guard eventSource.currentLifecycleEpoch(for: event.mountURL) == event.lifecycleEpoch else {
      // A newer lifecycle callback already happened while this Task was waiting for the
      // actor. A stale callback must not overwrite the newer session state.
      return
    }
    switch event.kind {
    case .unmounted:
      // Do not stat an already-unmounted path. Removing the record guarantees the next
      // successful observation receives a different generation, even if its signature is
      // byte-for-byte identical.
      sessionsByMountPath.removeValue(forKey: Self.mountKey(event.mountURL))

    case .mounted:
      do {
        let observation = try signatureReader.read(event.mountURL)
        let key = Self.mountKey(observation.mountRoot)
        guard observation.isNetwork,
          let signature = observation.networkSignature,
          Self.mountKey(signature.mountRoot) == key,
          !signature.fileSystem.isEmpty,
          signature.device != 0,
          signature.rootInode != 0
        else {
          sessionsByMountPath.removeValue(forKey: key)
          return
        }
        guard
          eventSource.currentLifecycleEpoch(for: observation.mountRoot)
            == event.lifecycleEpoch
        else {
          return
        }
        // A mount notification defines a new session even when the server exports the
        // same UUID/device/inode tuple after reconnecting. If `witness` already observed
        // this synchronous event-source epoch while actor delivery was delayed, keep that
        // newly-created generation rather than rotating twice for one callback.
        if let current = sessionsByMountPath[key],
          current.signature == signature,
          current.lifecycleEpoch == event.lifecycleEpoch
        {
          return
        }
        sessionsByMountPath[key] = Session(
          signature: signature,
          lifecycleEpoch: event.lifecycleEpoch,
          generation: generationFactory()
        )
      } catch {
        // An unreadable mount can never inherit an earlier session generation.
        sessionsByMountPath.removeValue(forKey: Self.mountKey(event.mountURL))
      }
    }
  }

  private static func mountKey(_ url: URL) -> String {
    url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
  }
}

/// Narrow adapter around Core's resolver. The production adapter deliberately has no durability
/// profile parameter: observed network storage is copy-grade only in this release.
struct DestinationIdentityResolverClient: Sendable {
  let resolve:
    @Sendable (
      _ rootURL: URL,
      _ destinationID: DestinationID,
      _ witness: NetworkMountLifecycleWitness?
    ) throws -> DestinationIdentity
  let revalidate:
    @Sendable (
      _ expected: DestinationIdentity,
      _ witness: NetworkMountLifecycleWitness?
    ) throws -> DestinationIdentity

  static let system = DestinationIdentityResolverClient(
    resolve: { rootURL, destinationID, witness in
      try DestinationIdentityResolver().resolve(
        rootURL: rootURL,
        destinationID: destinationID,
        networkMountLifecycleWitness: witness,
        durabilityProfileID: nil
      )
    },
    revalidate: { expected, witness in
      try DestinationIdentityResolver().revalidate(
        expected,
        freshNetworkMountLifecycleWitness: witness
      )
    }
  )
}

/// App-owned destination identity authority. All initial resolution and every ingest/rename I/O
/// boundary must use this same actor instance and its revalidation handler.
actor DestinationIdentityProvider {
  private let monitor: NetworkMountLifecycleMonitor
  private let resolver: DestinationIdentityResolverClient

  init(monitor: NetworkMountLifecycleMonitor = NetworkMountLifecycleMonitor()) {
    self.monitor = monitor
    resolver = .system
  }

  init(
    monitor: NetworkMountLifecycleMonitor,
    resolver: DestinationIdentityResolverClient
  ) {
    self.monitor = monitor
    self.resolver = resolver
  }

  func resolve(
    rootURL: URL,
    destinationID: DestinationID = DestinationID()
  ) async throws -> DestinationIdentity {
    let witness = try await monitor.witness(for: rootURL)
    return try resolver.resolve(rootURL, destinationID, witness)
  }

  func revalidate(_ expected: DestinationIdentity) async throws -> DestinationIdentity {
    let witness = try await monitor.witness(for: expected.rootURL)
    return try resolver.revalidate(expected, witness)
  }

  nonisolated func makeRevalidationHandler() -> DestinationIdentityRevalidationHandler {
    { [self] expected in
      try await revalidate(expected)
    }
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
