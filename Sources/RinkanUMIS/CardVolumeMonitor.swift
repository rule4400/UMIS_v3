import CryptoKit
import DiskArbitration
import Foundation
import IOKit
import UMISCore

enum CardVolumeMonitorEvent: Sendable {
  case appeared(VolumeIdentity)
  case disappeared(sourceID: SourceVolumeID, arrivalGeneration: UUID)
}

struct CardInsertionIdentity: Equatable, Sendable {
  let sourceID: SourceVolumeID
  let arrivalGeneration: UUID
}

struct CardInsertionIdentityReservation: Equatable, Sendable {
  let identity: CardInsertionIdentity
  let createdNewInsertion: Bool
}

/// Process-local identity state for physical insertion sessions.
///
/// An active session may receive more than one Disk Arbitration appearance/description callback,
/// so those callbacks retain the current identity. A disappearance ends the session immediately:
/// no time window, registry-entry reuse, or assumption about the card may bridge that boundary.
struct CardInsertionIdentitySessions: Sendable {
  private var activeByRegistryEntryID: [UInt64: CardInsertionIdentity] = [:]

  mutating func reserveAppearance(
    registryEntryID: UInt64,
    sourceIDFactory: () -> SourceVolumeID = { SourceVolumeID() },
    arrivalGenerationFactory: () -> UUID = { UUID() }
  ) -> CardInsertionIdentityReservation {
    if let active = activeByRegistryEntryID[registryEntryID] {
      return CardInsertionIdentityReservation(
        identity: active,
        createdNewInsertion: false
      )
    }
    let identity = CardInsertionIdentity(
      sourceID: sourceIDFactory(),
      arrivalGeneration: arrivalGenerationFactory()
    )
    activeByRegistryEntryID[registryEntryID] = identity
    return CardInsertionIdentityReservation(
      identity: identity,
      createdNewInsertion: true
    )
  }

  @discardableResult
  mutating func registerDisappearance(registryEntryID: UInt64) -> CardInsertionIdentity? {
    activeByRegistryEntryID.removeValue(forKey: registryEntryID)
  }

  mutating func cancelUnacceptedAppearance(
    registryEntryID: UInt64,
    reservation: CardInsertionIdentityReservation
  ) {
    guard reservation.createdNewInsertion,
      activeByRegistryEntryID[registryEntryID] == reservation.identity
    else { return }
    activeByRegistryEntryID.removeValue(forKey: registryEntryID)
  }

  func contains(
    registryEntryID: UInt64,
    identity: CardInsertionIdentity
  ) -> Bool {
    activeByRegistryEntryID[registryEntryID] == identity
  }
}

/// App-lifecycle adapter for Disk Arbitration. All destructive decisions remain in
/// UMISCore; this object only turns mount-session observations into resolver input.
final class CardVolumeMonitor: @unchecked Sendable {
  private struct Record {
    var identity: VolumeIdentity
  }

  private let lock = NSLock()
  private let session: DASession
  private let queue = DispatchQueue(label: "jp.rinkan.umis.volume-monitor", qos: .utility)
  private let resolver: DiskutilIdentityResolver
  private let registry: VolumeIdentityRegistry
  private let onEvent: @Sendable (CardVolumeMonitorEvent) -> Void
  private var recordsByRegistryID: [UInt64: Record] = [:]
  private var registryIDByBSDName: [String: UInt64] = [:]
  private var insertionIdentitySessions = CardInsertionIdentitySessions()
  private var pendingTicketsByRegistryID: [UInt64: UUID] = [:]
  private var pendingRegistryIDByBSDName: [String: UInt64] = [:]
  private var started = false

  init(
    registry: VolumeIdentityRegistry,
    resolver: DiskutilIdentityResolver = DiskutilIdentityResolver(),
    onEvent: @escaping @Sendable (CardVolumeMonitorEvent) -> Void
  ) throws {
    guard let session = DASessionCreate(kCFAllocatorDefault) else {
      throw UMISCoreError.backendFailure("Disk Arbitration session could not be created")
    }
    self.session = session
    self.registry = registry
    self.resolver = resolver
    self.onEvent = onEvent
  }

  func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()

    let context = Unmanaged.passUnretained(self).toOpaque()
    DARegisterDiskAppearedCallback(session, nil, cardDiskAppeared, context)
    DARegisterDiskDisappearedCallback(session, nil, cardDiskDisappeared, context)
    let changedKeys =
      [
        kDADiskDescriptionVolumePathKey,
        kDADiskDescriptionVolumeNameKey,
      ] as CFArray
    DARegisterDiskDescriptionChangedCallback(
      session,
      nil,
      changedKeys,
      cardDiskDescriptionChanged,
      context
    )
    DASessionSetDispatchQueue(session, queue)
  }

  func identity(containing url: URL) -> VolumeIdentity? {
    let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
    lock.lock()
    defer { lock.unlock() }
    return recordsByRegistryID.values
      .compactMap(\.identity)
      .filter { identity in
        guard let mount = identity.mountURL?.standardizedFileURL.resolvingSymlinksInPath().path
        else {
          return false
        }
        return candidate == mount || candidate.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
      }
      .max { ($0.mountURL?.path.count ?? 0) < ($1.mountURL?.path.count ?? 0) }
  }

  fileprivate func handleAppearance(_ disk: DADisk) {
    guard let observation = Self.observation(for: disk), let mountURL = observation.mountURL else {
      return
    }

    let observationTicket = UUID()
    let identityReservation: CardInsertionIdentityReservation
    lock.lock()
    if pendingTicketsByRegistryID[observation.registryEntryID] != nil {
      lock.unlock()
      return
    }
    pendingTicketsByRegistryID[observation.registryEntryID] = observationTicket
    pendingRegistryIDByBSDName[observation.bsdName] = observation.registryEntryID
    identityReservation = insertionIdentitySessions.reserveAppearance(
      registryEntryID: observation.registryEntryID
    )
    lock.unlock()

    let sourceID = identityReservation.identity.sourceID
    let arrivalGeneration = identityReservation.identity.arrivalGeneration

    let evidence = DiskArbitrationIdentityEvidence(
      mediaRegistryEntryID: observation.registryEntryID,
      parentChainDigest: observation.parentChainDigest,
      isEjectable: observation.isEjectable,
      physicalMediaEvidence: observation.physicalMediaEvidence
    )
    Task { [weak self, resolver, registry, onEvent] in
      do {
        let initiallyResolved = try await resolver.resolve(
          mountURL: mountURL,
          sourceID: sourceID,
          arrivalGeneration: arrivalGeneration,
          diskArbitrationEvidence: evidence
        )
        guard let self else { return }
        guard let freshObservation = self.freshObservation(bsdName: observation.bsdName),
          Self.samePhysicalObservation(observation, freshObservation),
          let freshMountURL = freshObservation.mountURL
        else { throw UMISCoreError.identityChanged }
        let freshEvidence = DiskArbitrationIdentityEvidence(
          mediaRegistryEntryID: freshObservation.registryEntryID,
          parentChainDigest: freshObservation.parentChainDigest,
          isEjectable: freshObservation.isEjectable,
          physicalMediaEvidence: freshObservation.physicalMediaEvidence
        )
        let identity = try await resolver.resolve(
          mountURL: freshMountURL,
          sourceID: sourceID,
          arrivalGeneration: arrivalGeneration,
          diskArbitrationEvidence: freshEvidence
        )
        guard identity.securityDigest == initiallyResolved.securityDigest else {
          throw UMISCoreError.identityChanged
        }
        var accepted = false
        self.lock.withLock {
          guard
            self.pendingTicketsByRegistryID[observation.registryEntryID]
              == observationTicket,
            self.pendingRegistryIDByBSDName[observation.bsdName]
              == observation.registryEntryID,
            self.insertionIdentitySessions.contains(
              registryEntryID: observation.registryEntryID,
              identity: identityReservation.identity
            )
          else { return }
          self.pendingTicketsByRegistryID.removeValue(forKey: observation.registryEntryID)
          self.pendingRegistryIDByBSDName.removeValue(forKey: observation.bsdName)
          self.recordsByRegistryID[observation.registryEntryID] = Record(
            identity: identity
          )
          self.registryIDByBSDName[observation.bsdName] = observation.registryEntryID
          accepted = true
        }
        guard accepted else { return }
        await registry.registerAppearance(identity)
        let stillActive = self.lock.withLock {
          self.recordsByRegistryID[observation.registryEntryID]?.identity.id
            == identity.id
            && self.recordsByRegistryID[observation.registryEntryID]?.identity
              .arrivalGeneration == identity.arrivalGeneration
            && self.registryIDByBSDName[observation.bsdName] == observation.registryEntryID
        }
        guard stillActive else {
          await registry.registerDisappearance(
            sourceVolumeID: identity.id,
            arrivalGeneration: identity.arrivalGeneration
          )
          return
        }
        onEvent(.appeared(identity))
      } catch {
        self?.lock.withLock {
          guard
            self?.pendingTicketsByRegistryID[observation.registryEntryID]
              == observationTicket
          else { return }
          self?.pendingTicketsByRegistryID.removeValue(forKey: observation.registryEntryID)
          if self?.pendingRegistryIDByBSDName[observation.bsdName]
            == observation.registryEntryID
          {
            self?.pendingRegistryIDByBSDName.removeValue(forKey: observation.bsdName)
          }
          self?.insertionIdentitySessions.cancelUnacceptedAppearance(
            registryEntryID: observation.registryEntryID,
            reservation: identityReservation
          )
        }
        // Internal, network, multi-partition and incompletely identified volumes
        // are intentionally absent from the card registry.
      }
    }
  }

  fileprivate func handleDisappearance(_ disk: DADisk) {
    guard let namePointer = DADiskGetBSDName(disk) else { return }
    let bsdName = String(cString: namePointer)
    lock.lock()
    if let pendingRegistryID = pendingRegistryIDByBSDName.removeValue(forKey: bsdName) {
      pendingTicketsByRegistryID.removeValue(forKey: pendingRegistryID)
      insertionIdentitySessions.registerDisappearance(registryEntryID: pendingRegistryID)
    }
    guard let registryID = registryIDByBSDName.removeValue(forKey: bsdName),
      let record = recordsByRegistryID.removeValue(forKey: registryID)
    else {
      lock.unlock()
      return
    }
    insertionIdentitySessions.registerDisappearance(registryEntryID: registryID)
    lock.unlock()
    let identity = record.identity
    Task { [registry, onEvent] in
      await registry.registerDisappearance(
        sourceVolumeID: identity.id,
        arrivalGeneration: identity.arrivalGeneration
      )
      onEvent(
        .disappeared(
          sourceID: identity.id,
          arrivalGeneration: identity.arrivalGeneration
        ))
    }
  }

  deinit {
    DASessionSetDispatchQueue(session, nil)
  }

  private struct Observation: Sendable, Hashable {
    let bsdName: String
    let mountURL: URL?
    let registryEntryID: UInt64
    let parentChainDigest: String
    let isEjectable: Bool
    let physicalMediaEvidence: PhysicalMediaEvidence
  }

  private func freshObservation(bsdName: String) -> Observation? {
    let devicePath = "/dev/\(bsdName)"
    guard
      let disk = devicePath.withCString({ path in
        DADiskCreateFromBSDName(kCFAllocatorDefault, session, path)
      })
    else { return nil }
    return Self.observation(for: disk)
  }

  private static func samePhysicalObservation(_ left: Observation, _ right: Observation) -> Bool {
    left.bsdName == right.bsdName
      && left.registryEntryID == right.registryEntryID
      && left.parentChainDigest == right.parentChainDigest
      && left.isEjectable == right.isEjectable
      && left.physicalMediaEvidence == right.physicalMediaEvidence
      && left.mountURL?.standardizedFileURL.resolvingSymlinksInPath()
        == right.mountURL?.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func observation(for disk: DADisk) -> Observation? {
    guard let namePointer = DADiskGetBSDName(disk),
      let description = DADiskCopyDescription(disk) as? [String: Any]
    else { return nil }
    let bsdName = String(cString: namePointer)
    let mountURL = description[kDADiskDescriptionVolumePathKey as String] as? URL
    let ejectable =
      (description[kDADiskDescriptionMediaEjectableKey as String] as? NSNumber)?.boolValue ?? false
    let devicePath = description[kDADiskDescriptionDevicePathKey as String] as? String ?? ""
    let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
    let mediaKind = description[kDADiskDescriptionMediaKindKey as String] as? String
    let vendor = description[kDADiskDescriptionDeviceVendorKey as String] as? String
    let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
    let media = DADiskCopyIOMedia(disk)
    guard media != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(media) }
    var registryEntryID: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(media, &registryEntryID) == KERN_SUCCESS,
      registryEntryID != 0,
      !devicePath.isEmpty
    else { return nil }
    let registry = registryEvidence(startingAt: media)
    let classification = classifyPhysicalMedia(
      deviceProtocol: deviceProtocol ?? registry.transportProtocol,
      mediaKind: mediaKind ?? registry.mediaType,
      registryClassChain: registry.classChain
    )
    let physicalMediaEvidence = PhysicalMediaEvidence(
      classification: classification,
      provenance: .diskArbitrationAndIOKit,
      transportProtocol: deviceProtocol ?? registry.transportProtocol,
      interconnectLocation: registry.interconnectLocation,
      mediaType: mediaKind ?? registry.mediaType,
      vendor: vendor ?? registry.vendor,
      model: model ?? registry.model,
      registryClassChain: registry.classChain
    )
    let digestMaterial = [
      String(registryEntryID),
      devicePath.precomposedStringWithCanonicalMapping,
      physicalMediaEvidence.transportProtocol ?? "",
      physicalMediaEvidence.interconnectLocation ?? "",
      physicalMediaEvidence.mediaType ?? "",
      physicalMediaEvidence.vendor ?? "",
      physicalMediaEvidence.model ?? "",
      physicalMediaEvidence.registryClassChain.joined(separator: ">"),
    ].joined(separator: "|")
    let parentChainDigest = SHA256.hash(data: Data(digestMaterial.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return Observation(
      bsdName: bsdName,
      mountURL: mountURL,
      registryEntryID: registryEntryID,
      parentChainDigest: parentChainDigest,
      isEjectable: ejectable,
      physicalMediaEvidence: physicalMediaEvidence
    )
  }

  private struct RegistryEvidence {
    var classChain: [String] = []
    var transportProtocol: String?
    var interconnectLocation: String?
    var mediaType: String?
    var vendor: String?
    var model: String?
  }

  private static func registryEvidence(startingAt media: io_registry_entry_t) -> RegistryEvidence {
    var evidence = RegistryEvidence()
    var current = media
    var currentIsOwned = false
    defer {
      if currentIsOwned { IOObjectRelease(current) }
    }

    for _ in 0..<32 {
      if let copiedClass = IOObjectCopyClass(current) {
        evidence.classChain.append(copiedClass.takeRetainedValue() as String)
      }
      if let properties = registryProperties(current) {
        evidence.transportProtocol =
          evidence.transportProtocol
          ?? stringProperty(
            in: properties,
            keys: ["Physical Interconnect", "Physical Interconnect Type", "Protocol"]
          )
        evidence.interconnectLocation =
          evidence.interconnectLocation
          ?? stringProperty(
            in: properties,
            keys: ["Physical Interconnect Location", "Location"]
          )
        evidence.mediaType =
          evidence.mediaType
          ?? stringProperty(in: properties, keys: ["Media Type", "Medium Type"])
        evidence.vendor =
          evidence.vendor
          ?? stringProperty(in: properties, keys: ["Vendor Identification", "Vendor Name"])
        evidence.model =
          evidence.model
          ?? stringProperty(
            in: properties, keys: ["Product Name", "Model", "Product Identification"])
      }

      var parent: io_registry_entry_t = 0
      guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
        parent != IO_OBJECT_NULL
      else { break }
      if currentIsOwned { IOObjectRelease(current) }
      current = parent
      currentIsOwned = true
    }
    return evidence
  }

  private static func registryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(
        entry,
        &unmanaged,
        kCFAllocatorDefault,
        0
      ) == KERN_SUCCESS,
      let unmanaged,
      let dictionary = unmanaged.takeRetainedValue() as NSDictionary as? [String: Any]
    else { return nil }
    return dictionary
  }

  private static func stringProperty(in properties: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = properties[key] as? String, !value.isEmpty { return value }
      for nestedKey in ["Protocol Characteristics", "Device Characteristics"] {
        if let nested = properties[nestedKey] as? [String: Any],
          let value = nested[key] as? String,
          !value.isEmpty
        {
          return value
        }
      }
    }
    return nil
  }

  private static func classifyPhysicalMedia(
    deviceProtocol: String?,
    mediaKind: String?,
    registryClassChain: [String]
  ) -> PhysicalMediaClassification {
    let trustedSignals = ([deviceProtocol, mediaKind] + registryClassChain.map(Optional.some))
      .compactMap { $0?.precomposedStringWithCanonicalMapping.lowercased() }
    if trustedSignals.contains(where: {
      $0.contains("secure digital")
        || $0.contains("sd card")
        || $0.contains("iosd")
        || $0.contains("sdxc")
        || $0.contains("sdhc")
    }) {
      return .secureDigitalCard
    }
    if trustedSignals.contains(where: { $0.contains("solid state") || $0.contains("ssd") }) {
      return .solidStateDrive
    }
    if trustedSignals.contains(where: { $0.contains("hard disk") || $0.contains("sata") }) {
      return .hardDiskDrive
    }
    if trustedSignals.contains(where: { $0.contains("usb") }) {
      return .genericUSBStorage
    }
    return .unknown
  }
}

private func cardDiskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  Unmanaged<CardVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handleAppearance(disk)
}

private func cardDiskDescriptionChanged(
  _ disk: DADisk,
  _ changedKeys: CFArray,
  _ context: UnsafeMutableRawPointer?
) {
  _ = changedKeys
  guard let context else { return }
  Unmanaged<CardVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handleAppearance(disk)
}

private func cardDiskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  Unmanaged<CardVolumeMonitor>.fromOpaque(context).takeUnretainedValue().handleDisappearance(disk)
}
