import Foundation
import UMISCore
import XCTest

@testable import RinkanUMIS

final class NetworkMountLifecycleMonitorTests: XCTestCase {
  func testSameMountSessionKeepsWitnessAndSignatureChangeRotatesGeneration() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-NAS", isDirectory: true)
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    let generations = TestUUIDSequence([firstGeneration, secondGeneration])
    let tracker = TestNetworkMountSignatureTracker(
      .network(root: root, device: 101, inode: 201)
    )
    let source = TestNetworkMountEventSource()
    let authority = UUID()
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: authority,
      eventSource: source,
      signatureReader: tracker.reader,
      generationFactory: generations.next
    )

    let firstObserved = try await monitor.witness(for: root)
    let unchangedObserved = try await monitor.witness(for: root.appendingPathComponent("Job"))
    let first = try XCTUnwrap(firstObserved)
    let unchanged = try XCTUnwrap(unchangedObserved)
    XCTAssertEqual(first.authorityID, authority)
    XCTAssertEqual(first.generation, firstGeneration)
    XCTAssertEqual(unchanged, first)

    tracker.set(.network(root: root, device: 102, inode: 201))
    let changedObserved = try await monitor.witness(for: root)
    let changed = try XCTUnwrap(changedObserved)
    XCTAssertEqual(changed.authorityID, authority)
    XCTAssertEqual(changed.generation, secondGeneration)
    XCTAssertNotEqual(changed.generation, first.generation)
  }

  func testUnmountThenRemountAlwaysRotatesEvenForIdenticalSignature() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Remount", isDirectory: true)
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    let generations = TestUUIDSequence([firstGeneration, secondGeneration])
    let original = NetworkMountObservation.network(root: root, device: 301, inode: 401)
    let tracker = TestNetworkMountSignatureTracker(original)
    let source = TestNetworkMountEventSource()
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: source,
      signatureReader: tracker.reader,
      generationFactory: generations.next
    )

    let firstObserved = try await monitor.witness(for: root)
    let first = try XCTUnwrap(firstObserved)
    XCTAssertEqual(first.generation, firstGeneration)

    await source.emit(.unmounted, root: root)
    tracker.failReads = true
    do {
      _ = try await monitor.witness(for: root)
      XCTFail("An unreadable unmounted destination must fail closed")
    } catch {
      XCTAssertEqual(
        error as? UMISCoreError,
        .eraseNotEligible("Test signature observation is unavailable")
      )
    }

    tracker.failReads = false
    tracker.set(original)
    await source.emit(.mounted, root: root)
    let remountedObserved = try await monitor.witness(for: root)
    let remounted = try XCTUnwrap(remountedObserved)
    XCTAssertEqual(remounted.generation, secondGeneration)
    XCTAssertNotEqual(remounted.generation, first.generation)
  }

  func testMountNotificationAloneDefinesNewSessionForSameSignature() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Reconnect", isDirectory: true)
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    let generations = TestUUIDSequence([firstGeneration, secondGeneration])
    let tracker = TestNetworkMountSignatureTracker(
      .network(root: root, device: 501, inode: 601)
    )
    let source = TestNetworkMountEventSource()
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: source,
      signatureReader: tracker.reader,
      generationFactory: generations.next
    )

    let firstObserved = try await monitor.witness(for: root)
    let first = try XCTUnwrap(firstObserved)
    await source.emit(.mounted, root: root)
    let reconnectedObserved = try await monitor.witness(for: root)
    let reconnected = try XCTUnwrap(reconnectedObserved)
    XCTAssertEqual(first.generation, firstGeneration)
    XCTAssertEqual(reconnected.generation, secondGeneration)
  }

  func testSynchronousLifecycleEpochClosesDelayedActorDeliveryWindow() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Delayed-Delivery", isDirectory: true)
    let firstGeneration = UUID()
    let secondGeneration = UUID()
    let generations = TestUUIDSequence([firstGeneration, secondGeneration])
    let tracker = TestNetworkMountSignatureTracker(
      .network(root: root, device: 1_101, inode: 1_201)
    )
    let source = TestNetworkMountEventSource()
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: source,
      signatureReader: tracker.reader,
      generationFactory: generations.next
    )

    let firstObserved = try await monitor.witness(for: root)
    let first = try XCTUnwrap(firstObserved)
    XCTAssertEqual(first.generation, firstGeneration)

    // Simulate NSWorkspace's callback synchronously advancing its epoch while the Task that
    // delivers the callback to the monitor actor is arbitrarily delayed.
    let delayedEvent = source.recordWithoutDelivery(.mounted, root: root)
    let beforeActorDeliveryObserved = try await monitor.witness(for: root)
    let beforeActorDelivery = try XCTUnwrap(beforeActorDeliveryObserved)
    XCTAssertEqual(beforeActorDelivery.generation, secondGeneration)
    XCTAssertNotEqual(beforeActorDelivery.generation, first.generation)

    // Late delivery of that same event must neither restore the old generation nor rotate a
    // second time for the same lifecycle epoch.
    await source.deliver(delayedEvent)
    let afterActorDeliveryObserved = try await monitor.witness(for: root)
    XCTAssertEqual(try XCTUnwrap(afterActorDeliveryObserved), beforeActorDelivery)
  }

  func testLocalVolumeHasNoWitnessAndIncompleteOrUnreadableNetworkFailsClosed() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Classification", isDirectory: true)
    let tracker = TestNetworkMountSignatureTracker(.local(root: root))
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: TestNetworkMountEventSource(),
      signatureReader: tracker.reader
    )

    let localWitness = try await monitor.witness(for: root)
    XCTAssertNil(localWitness)

    tracker.set(
      NetworkMountObservation(
        mountRoot: root,
        isNetwork: true,
        networkSignature: nil
      ))
    do {
      _ = try await monitor.witness(for: root)
      XCTFail("Incomplete network identity must fail closed")
    } catch {
      XCTAssertEqual(
        error as? UMISCoreError,
        .eraseNotEligible("Network destination mount signature is incomplete")
      )
    }

    tracker.failReads = true
    do {
      _ = try await monitor.witness(for: root)
      XCTFail("Unreadable network identity must fail closed")
    } catch {
      XCTAssertEqual(
        error as? UMISCoreError,
        .eraseNotEligible("Test signature observation is unavailable")
      )
    }
  }

  func testProcessAuthorityChangesAndRejectsOldPlanWitness() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Authority", isDirectory: true)
    let tracker = TestNetworkMountSignatureTracker(
      .network(root: root, device: 701, inode: 801)
    )
    let firstMonitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: TestNetworkMountEventSource(),
      signatureReader: tracker.reader
    )
    let restartedMonitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: TestNetworkMountEventSource(),
      signatureReader: tracker.reader
    )
    let firstObserved = try await firstMonitor.witness(for: root)
    let restartedObserved = try await restartedMonitor.witness(for: root)
    let firstWitness = try XCTUnwrap(firstObserved)
    let restartedWitness = try XCTUnwrap(restartedObserved)
    XCTAssertNotEqual(firstWitness.authorityID, restartedWitness.authorityID)

    let expected = makeNetworkIdentity(root: root, witness: firstWitness)
    XCTAssertThrowsError(
      try NetworkMountLifecycleValidator.validate(
        expected: expected,
        freshWitness: restartedWitness
      )
    ) { error in
      XCTAssertEqual(error as? UMISCoreError, .identityChanged)
    }
  }

  func testDestinationProviderSuppliesHandlerAndRemountInvalidatesExpectedIdentity() async throws {
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Provider", isDirectory: true)
    let tracker = TestNetworkMountSignatureTracker(
      .network(root: root, device: 901, inode: 1_001)
    )
    let source = TestNetworkMountEventSource()
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: source,
      signatureReader: tracker.reader
    )
    let resolver = DestinationIdentityResolverClient(
      resolve: { rootURL, destinationID, witness in
        guard let witness else { throw UMISCoreError.identityChanged }
        return makeNetworkIdentity(
          root: rootURL,
          destinationID: destinationID,
          witness: witness
        )
      },
      revalidate: { expected, witness in
        guard let witness else { throw UMISCoreError.identityChanged }
        try NetworkMountLifecycleValidator.validate(
          expected: expected,
          freshWitness: witness
        )
        return expected
      }
    )
    let provider = DestinationIdentityProvider(monitor: monitor, resolver: resolver)

    let identity = try await provider.resolve(rootURL: root)
    XCTAssertTrue(identity.hasCopyGradeIdentity)
    XCTAssertFalse(identity.hasEraseGradeIdentity)
    XCTAssertNil(identity.durabilityProfileID)
    let handler = provider.makeRevalidationHandler()
    let revalidated = try await handler(identity)
    XCTAssertEqual(revalidated, identity)

    await source.emit(.mounted, root: root)
    do {
      _ = try await handler(identity)
      XCTFail("A plan from the preceding mount generation must not be resumed")
    } catch {
      XCTAssertEqual(error as? UMISCoreError, .identityChanged)
    }
  }

  func testDestinationProviderPassesNoWitnessForLocalDestination() async throws {
    let root = URL(fileURLWithPath: "/tmp/UMIS-Test-Local", isDirectory: true)
    let tracker = TestNetworkMountSignatureTracker(.local(root: root))
    let monitor = NetworkMountLifecycleMonitor(
      authorityID: UUID(),
      eventSource: TestNetworkMountEventSource(),
      signatureReader: tracker.reader
    )
    let resolver = DestinationIdentityResolverClient(
      resolve: { rootURL, destinationID, witness in
        guard witness == nil else { throw UMISCoreError.identityChanged }
        return makeLocalIdentity(root: rootURL, destinationID: destinationID)
      },
      revalidate: { expected, witness in
        guard witness == nil else { throw UMISCoreError.identityChanged }
        return expected
      }
    )
    let provider = DestinationIdentityProvider(monitor: monitor, resolver: resolver)

    let local = try await provider.resolve(rootURL: root)
    XCTAssertFalse(local.isNetwork)
    XCTAssertNil(local.networkMountLifecycleAuthorityID)
    let revalidated = try await provider.makeRevalidationHandler()(local)
    XCTAssertEqual(revalidated, local)
  }

  func testNSWorkspaceEventSourceMapsMountAndUnmountNotifications() async throws {
    let center = NotificationCenter()
    let source = NSWorkspaceNetworkMountLifecycleEventSource(notificationCenter: center)
    let root = URL(fileURLWithPath: "/Volumes/UMIS-Test-Notifications", isDirectory: true)
    let expectation = SendableExpectation(
      XCTestExpectation(description: "mount and unmount notifications")
    )
    expectation.value.expectedFulfillmentCount = 2
    let received = LockedEvents()
    source.setEventHandler { event in
      received.append(event)
      expectation.value.fulfill()
    }

    let epochBeforeMalformedNotification = source.currentLifecycleEpoch(for: root)
    center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [:])
    XCTAssertNotEqual(
      source.currentLifecycleEpoch(for: root),
      epochBeforeMalformedNotification,
      "An unattributable lifecycle event must invalidate every already-observed session"
    )
    center.post(
      name: NSWorkspace.didMountNotification,
      object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: root]
    )
    center.post(
      name: NSWorkspace.didUnmountNotification,
      object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: root]
    )
    await fulfillment(of: [expectation.value], timeout: 2)
    let events = received.value
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].kind, .mounted)
    XCTAssertEqual(events[0].mountURL, root)
    XCTAssertEqual(events[1].kind, .unmounted)
    XCTAssertEqual(events[1].mountURL, root)
    XCTAssertNotEqual(events[0].lifecycleEpoch, events[1].lifecycleEpoch)
  }
}

private final class TestNetworkMountEventSource: NetworkMountLifecycleEventSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var handler: (@Sendable (NetworkMountLifecycleEvent) async -> Void)?
  private var lifecycleEpochsByMountPath: [String: UUID] = [:]

  func setEventHandler(
    _ handler: @escaping @Sendable (NetworkMountLifecycleEvent) async -> Void
  ) {
    lock.withLock {
      self.handler = handler
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

  func recordWithoutDelivery(
    _ kind: NetworkMountLifecycleEvent.Kind,
    root: URL
  ) -> NetworkMountLifecycleEvent {
    lock.withLock {
      let epoch = UUID()
      lifecycleEpochsByMountPath[Self.mountKey(root)] = epoch
      return NetworkMountLifecycleEvent(
        kind: kind,
        mountURL: root,
        lifecycleEpoch: epoch
      )
    }
  }

  func deliver(_ event: NetworkMountLifecycleEvent) async {
    let currentHandler = lock.withLock { handler }
    await currentHandler?(event)
  }

  func emit(_ kind: NetworkMountLifecycleEvent.Kind, root: URL) async {
    await deliver(recordWithoutDelivery(kind, root: root))
  }

  private static func mountKey(_ url: URL) -> String {
    url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
  }
}

private final class TestNetworkMountSignatureTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var observation: NetworkMountObservation
  private var unavailable = false

  init(_ observation: NetworkMountObservation) {
    self.observation = observation
  }

  var reader: NetworkMountSignatureReader {
    NetworkMountSignatureReader { [self] _ in
      try lock.withLock {
        guard !unavailable else {
          throw UMISCoreError.eraseNotEligible(
            "Test signature observation is unavailable"
          )
        }
        return observation
      }
    }
  }

  var failReads: Bool {
    get { lock.withLock { unavailable } }
    set { lock.withLock { unavailable = newValue } }
  }

  func set(_ observation: NetworkMountObservation) {
    lock.withLock {
      self.observation = observation
    }
  }
}

private final class TestUUIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID]

  init(_ values: [UUID]) {
    self.values = values
  }

  func next() -> UUID {
    lock.withLock {
      precondition(!values.isEmpty, "Test exhausted its mount generations")
      return values.removeFirst()
    }
  }
}

private final class SendableExpectation: @unchecked Sendable {
  let value: XCTestExpectation

  init(_ value: XCTestExpectation) {
    self.value = value
  }
}

private final class LockedEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [NetworkMountLifecycleEvent] = []

  var value: [NetworkMountLifecycleEvent] {
    lock.withLock { events }
  }

  func append(_ event: NetworkMountLifecycleEvent) {
    lock.withLock {
      events.append(event)
    }
  }
}

extension NetworkMountObservation {
  fileprivate static func network(root: URL, device: UInt64, inode: UInt64)
    -> NetworkMountObservation
  {
    NetworkMountObservation(
      mountRoot: root,
      isNetwork: true,
      networkSignature: NetworkMountSignature(
        mountRoot: root,
        volumeUUID: nil,
        fileSystem: "SMB",
        device: device,
        rootInode: inode
      )
    )
  }

  fileprivate static func local(root: URL) -> NetworkMountObservation {
    NetworkMountObservation(
      mountRoot: root,
      isNetwork: false,
      networkSignature: nil
    )
  }
}

private func makeNetworkIdentity(
  root: URL,
  destinationID: DestinationID = DestinationID(),
  witness: NetworkMountLifecycleWitness
) -> DestinationIdentity {
  DestinationIdentity(
    id: destinationID,
    rootURL: root,
    volumeIdentifier: "network-test-volume",
    fileSystem: "SMB",
    rootFileIdentifier: "network-test-root",
    volumeDeviceIdentifier: 1,
    mountGeneration: witness.generation,
    networkMountLifecycleAuthorityID: witness.authorityID,
    isNetwork: true,
    isWritable: true,
    durabilityProfileID: nil,
    backingEvidence: DestinationBackingEvidence(
      kind: .networkMount,
      provenance: .networkMountLifecycle,
      backingStoreIdentifier: "network-test-volume"
    )
  )
}

private func makeLocalIdentity(root: URL, destinationID: DestinationID) -> DestinationIdentity {
  DestinationIdentity(
    id: destinationID,
    rootURL: root,
    volumeIdentifier: UUID().uuidString,
    fileSystem: "APFS",
    rootFileIdentifier: "local-test-root",
    volumeDeviceIdentifier: 2,
    isNetwork: false,
    isWritable: true,
    backingEvidence: DestinationBackingEvidence(
      kind: .physicalDevice,
      provenance: .foundationInternalVolume,
      backingStoreIdentifier: "local-test-volume"
    )
  )
}
