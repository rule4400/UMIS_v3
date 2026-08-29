import CryptoKit
import Foundation
@testable import UMISCore

struct CoreFixture {
    let root: URL
    let source: URL
    let destination: URL
    let database: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umis-core-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        database = root.appendingPathComponent("journal/operations.sqlite3")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writeSource(name: String = "A001.MOV", data: Data) throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}

func makeStrongVolume(id: SourceVolumeID, mountURL: URL, arrival: UUID = UUID()) -> VolumeIdentity {
    VolumeIdentity(
        id: id,
        volumeUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        mediaUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
        mediaRegistryEntryID: 987_654,
        parentChainDigest: "parent-chain-proof",
        bsdName: "disk99s1",
        wholeDiskBSDName: "disk99",
        mountURL: mountURL,
        displayName: "TESTCARD",
        capacityBytes: 64_000_000,
        volumeDeviceIdentifier: 9_999_999,
        physicalMediaEvidence: PhysicalMediaEvidence(
            classification: .secureDigitalCard,
            provenance: .diskArbitrationAndIOKit,
            transportProtocol: "Secure Digital",
            interconnectLocation: "External",
            mediaType: "SDXC",
            vendor: "TEST",
            model: "TESTCARD",
            registryClassChain: ["IOSDHostDevice", "IOMedia"]
        ),
        blockSize: 512,
        fileSystem: "ExFAT",
        isInternal: false,
        isRemovable: true,
        isEjectable: true,
        isWritable: true,
        isNetwork: false,
        isDiskImage: false,
        partitionCount: 1,
        arrivalGeneration: arrival,
        identityStrength: .strongForCurrentInsertion
    )
}

func makeSingleFilePlan(
    fixture: CoreFixture,
    data: Data,
    duplicatePolicy: DuplicatePolicy = .block,
    expectedHash: String? = nil
) async throws -> (IngestPlan, MediaAsset) {
    _ = try fixture.writeSource(data: data)
    let sourceID = SourceVolumeID()
    let scan = try await MediaScanner().scan(root: fixture.source, sourceVolumeID: sourceID)
    let asset = try XCTUnwrapValue(scan.assets.first)
    let destination = try DestinationIdentityResolver().resolve(rootURL: fixture.destination)
    let required = try scan.validatedRequiredSet(destinationID: destination.id)
    let item = IngestPlanItem(
        asset: asset,
        sourceURL: asset.canonicalURL,
        finalURL: fixture.destination.appendingPathComponent(asset.originalName),
        expectedSourceFingerprint: asset.fingerprint,
        expectedContentSHA256: expectedHash,
        duplicatePolicy: duplicatePolicy
    )
    let plan = IngestPlan(
        project: Project(name: "Test Project", destination: fixture.destination),
        sourceVolume: makeStrongVolume(id: sourceID, mountURL: fixture.source),
        destination: destination,
        requiredSet: required,
        items: [item]
    )
    return (plan, asset)
}

func XCTUnwrapValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        throw TestSupportError.missingValue("Expected non-nil value at \(file):\(line)")
    }
    return value
}

enum TestSupportError: Error { case missingValue(String) }

final class LockedIntRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

actor DeterministicRetainedMediaClaimProvider: RetainedMediaClaimProviding {
    nonisolated let assurance: RetainedMediaClaimAssurance = .deterministicTestDouble

    private let registry: VolumeIdentityRegistry
    private let activity: VolumeIOActivityRegistry?
    private var claims: [UUID: RetainedMediaClaim] = [:]
    private var revalidationCounts: [UUID: Int] = [:]
    private var replacementAfterFirstRevalidation: VolumeIdentity?
    private var disappearAfterFirstRevalidation = false
    private var acquisitionError: UMISCoreError?
    private var acquiredPurposes: [RetainedMediaClaimPurpose] = []
    private var releaseCountValue = 0
    private var ejectCountValue = 0
    private var observedEjectQuiescence = false
    private var rejectedCompetingEjectActivity = false

    init(
        registry: VolumeIdentityRegistry,
        activity: VolumeIOActivityRegistry? = nil
    ) {
        self.registry = registry
        self.activity = activity
    }

    func failAcquisition(with error: UMISCoreError) {
        acquisitionError = error
    }

    func replaceAfterFirstRevalidation(with identity: VolumeIdentity) {
        replacementAfterFirstRevalidation = identity
    }

    func disappearAfterFirstRevalidationCallback() {
        disappearAfterFirstRevalidation = true
    }

    func acquire(
        expectedIdentity: VolumeIdentity,
        purpose: RetainedMediaClaimPurpose,
        timeout: TimeInterval
    ) async throws -> RetainedMediaClaim {
        if let acquisitionError { throw acquisitionError }
        guard timeout > 0 else {
            throw UMISCoreError.backendFailure("Injected retained-media claim timeout")
        }
        let current = try await registry.current(sourceVolumeID: expectedIdentity.id)
        guard current.matchesSameEraseTarget(as: expectedIdentity) else {
            throw UMISCoreError.identityChanged
        }
        let claimedAt = Date()
        let claim = try RetainedMediaClaim(
            purpose: purpose,
            expectedIdentityDigest: expectedIdentity.securityDigest,
            freshlyRevalidatedIdentity: current,
            evidenceDigest: sha256(Data("TEST-CLAIM|\(UUID().uuidString)".utf8)),
            claimedAt: claimedAt,
            expiresAt: claimedAt.addingTimeInterval(min(timeout, 30))
        )
        claims[claim.handleID] = claim
        revalidationCounts[claim.handleID] = 0
        acquiredPurposes.append(purpose)
        return claim
    }

    func revalidate(_ claim: RetainedMediaClaim) async throws -> VolumeIdentity {
        guard claims[claim.handleID] == claim else { throw UMISCoreError.identityChanged }
        let current = try await registry.current(
            sourceVolumeID: claim.freshlyRevalidatedIdentity.id
        )
        let count = revalidationCounts[claim.handleID, default: 0]
        revalidationCounts[claim.handleID] = count + 1
        if count == 0 {
            if let replacementAfterFirstRevalidation {
                await registry.registerAppearance(replacementAfterFirstRevalidation)
                self.replacementAfterFirstRevalidation = nil
            } else if disappearAfterFirstRevalidation {
                await registry.registerDisappearance(
                    sourceVolumeID: current.id,
                    arrivalGeneration: current.arrivalGeneration
                )
                disappearAfterFirstRevalidation = false
            }
        }
        return current
    }

    func ejectRetained(_ claim: RetainedMediaClaim, timeout: TimeInterval) async throws {
        guard timeout > 0, claims[claim.handleID] == claim, claim.purpose == .eject else {
            throw UMISCoreError.invalidToken
        }
        let current = try await revalidate(claim)
        guard current.matchesSameEraseTarget(as: claim.freshlyRevalidatedIdentity) else {
            throw UMISCoreError.identityChanged
        }
        if let activity {
            observedEjectQuiescence = await activity.isDestructivelyQuiesced(
                sourceVolumeID: current.id
            )
            do {
                _ = try await activity.withActivity(sourceVolumeID: current.id) { true }
            } catch {
                rejectedCompetingEjectActivity = true
            }
        }
        ejectCountValue += 1
        await registry.registerDisappearance(
            sourceVolumeID: current.id,
            arrivalGeneration: current.arrivalGeneration
        )
    }

    func release(_ claim: RetainedMediaClaim) async {
        if claims.removeValue(forKey: claim.handleID) != nil {
            revalidationCounts.removeValue(forKey: claim.handleID)
            releaseCountValue += 1
        }
    }

    func retainedCount() -> Int { claims.count }
    func releaseCount() -> Int { releaseCountValue }
    func purposes() -> [RetainedMediaClaimPurpose] { acquiredPurposes }
    func ejectCount() -> Int { ejectCountValue }
    func sawEjectQuiescence() -> Bool { observedEjectQuiescence }
    func competingEjectActivityWasRejected() -> Bool { rejectedCompetingEjectActivity }
}

actor RecordingDiskutilRunner: ProcessRunning {
    private let registry: VolumeIdentityRegistry
    private let sourceRoot: URL
    private var identity: VolumeIdentity
    private let label: String
    private let eraseTimesOut: Bool
    private var afterFormat = false
    private var requests: [ProcessRequest] = []

    init(
        registry: VolumeIdentityRegistry,
        sourceRoot: URL,
        identity: VolumeIdentity,
        label: String,
        eraseTimesOut: Bool = false
    ) {
        self.registry = registry
        self.sourceRoot = sourceRoot
        self.identity = identity
        self.label = label
        self.eraseTimesOut = eraseTimesOut
    }

    func run(_ request: ProcessRequest) async throws -> ProcessExecutionResult {
        requests.append(request)
        let arguments = request.arguments
        if arguments.first == "info" {
            return success(plist: infoPlist())
        }
        if arguments.first == "list" {
            return success(plist: [
                "AllDisksAndPartitions": [[
                    "DeviceIdentifier": identity.wholeDiskBSDName!,
                    "Partitions": [["DeviceIdentifier": identity.bsdName!]],
                ]],
            ])
        }
        if arguments.first == "unmount" {
            return success()
        }
        if arguments.first == "eraseVolume" {
            if eraseTimesOut {
                return ProcessExecutionResult(
                    exitCode: nil,
                    terminationSignal: nil,
                    standardOutput: Data(),
                    standardError: Data("simulated timeout".utf8),
                    timedOut: true
                )
            }
            for child in (try? FileManager.default.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )) ?? [] {
                try? FileManager.default.removeItem(at: child)
            }
            identity.volumeUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")
            identity.fileSystem = "ExFAT"
            identity.mountURL = sourceRoot
            afterFormat = true
            try await registry.update(identity)
            return success()
        }
        return ProcessExecutionResult(
            exitCode: 64,
            terminationSignal: nil,
            standardOutput: Data(),
            standardError: Data("unexpected command".utf8),
            timedOut: false
        )
    }

    func recordedArguments() -> [[String]] { requests.map(\.arguments) }

    private func infoPlist() -> [String: Any] {
        [
            "DeviceIdentifier": identity.bsdName!,
            "ParentWholeDisk": identity.wholeDiskBSDName!,
            "TotalSize": NSNumber(value: identity.capacityBytes),
            "Internal": false,
            "RemovableMedia": true,
            "Writable": true,
            "VolumeUUID": identity.volumeUUID!.uuidString,
            "MediaUUID": identity.mediaUUID!.uuidString,
            "FilesystemName": afterFormat ? "ExFAT" : "ExFAT",
            "VolumeName": afterFormat ? label : "TESTCARD",
            "MountPoint": sourceRoot.path,
            "VirtualOrPhysical": "Physical",
            "DiskImage": false,
        ]
    }

    private func success(plist: [String: Any]? = nil) -> ProcessExecutionResult {
        let data = plist.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data()
        return ProcessExecutionResult(
            exitCode: 0,
            terminationSignal: nil,
            standardOutput: data,
            standardError: Data(),
            timedOut: false
        )
    }
}

actor RecordingEjectRunner: ProcessRunning {
    private let registry: VolumeIdentityRegistry
    private let identity: VolumeIdentity
    private let activity: VolumeIOActivityRegistry?
    private var requests: [ProcessRequest] = []
    private var observedQuiescence = false
    private var rejectedCompetingActivity = false

    init(
        registry: VolumeIdentityRegistry,
        identity: VolumeIdentity,
        activity: VolumeIOActivityRegistry? = nil
    ) {
        self.registry = registry
        self.identity = identity
        self.activity = activity
    }

    func run(_ request: ProcessRequest) async throws -> ProcessExecutionResult {
        requests.append(request)
        if request.arguments == ["eject", identity.wholeDiskBSDName!] {
            if let activity {
                observedQuiescence = await activity.isDestructivelyQuiesced(
                    sourceVolumeID: identity.id
                )
                do {
                    _ = try await activity.withActivity(sourceVolumeID: identity.id) { true }
                } catch {
                    rejectedCompetingActivity = true
                }
            }
            await registry.registerDisappearance(
                sourceVolumeID: identity.id,
                arrivalGeneration: identity.arrivalGeneration
            )
            return ProcessExecutionResult(
                exitCode: 0,
                terminationSignal: nil,
                standardOutput: Data(),
                standardError: Data(),
                timedOut: false
            )
        }
        return ProcessExecutionResult(
            exitCode: 64,
            terminationSignal: nil,
            standardOutput: Data(),
            standardError: Data(),
            timedOut: false
        )
    }

    func invocationCount() -> Int { requests.count }
    func sawQuiescedReservation() -> Bool { observedQuiescence }
    func competingActivityWasRejected() -> Bool { rejectedCompetingActivity }
}
