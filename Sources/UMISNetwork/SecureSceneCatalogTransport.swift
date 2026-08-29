import Foundation
import Network
import Security

public enum SceneCatalogPairingCredentialError: Error, Equatable, Sendable {
    case invalidPSKLength(actual: Int)
    case publicKeyFingerprintMismatch
    case randomGenerationFailed(OSStatus)
}

/// Credential produced *after* an explicit out-of-band pairing ceremony.
///
/// This value is intentionally not Codable because it contains a TLS PSK.
/// Production callers must keep it in Keychain and should construct it only
/// after invite fingerprint, TLS transcript/SAS, scope, and operator approval
/// checks have completed. Bonjour discovery alone never creates this value.
public struct PairedSceneCatalogCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let projectID: UUID
    public let catalogID: UUID
    public let authorityID: UUID
    public let authorityEpoch: UUID
    public let catalogPublicKeyFingerprint: SHA256Value
    public let catalogPublicKeyRawRepresentation: Data
    public let pskIdentity: UUID

    let transportPSK: Data
    private let storedTrust: SceneCatalogTrust

    public init(
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        catalogPublicKeyFingerprint: SHA256Value,
        catalogPublicKeyRawRepresentation: Data,
        pskIdentity: UUID,
        transportPSK: Data
    ) throws {
        guard (32...64).contains(transportPSK.count) else {
            throw SceneCatalogPairingCredentialError.invalidPSKLength(actual: transportPSK.count)
        }
        guard SHA256Value.hash(catalogPublicKeyRawRepresentation) == catalogPublicKeyFingerprint else {
            throw SceneCatalogPairingCredentialError.publicKeyFingerprintMismatch
        }
        let trust = try SceneCatalogTrust(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            trustedCatalogKeyID: catalogPublicKeyFingerprint.hex,
            publicKeyRawRepresentation: catalogPublicKeyRawRepresentation
        )
        self.projectID = projectID
        self.catalogID = catalogID
        self.authorityID = authorityID
        self.authorityEpoch = authorityEpoch
        self.catalogPublicKeyFingerprint = catalogPublicKeyFingerprint
        self.catalogPublicKeyRawRepresentation = catalogPublicKeyRawRepresentation
        self.pskIdentity = pskIdentity
        self.transportPSK = transportPSK
        self.storedTrust = trust
    }

    public static func generate(
        projectID: UUID,
        catalogID: UUID,
        authorityID: UUID,
        authorityEpoch: UUID,
        catalogPublicKeyRawRepresentation: Data,
        pskIdentity: UUID = UUID()
    ) throws -> Self {
        var psk = Data(count: 32)
        let status = psk.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw SceneCatalogPairingCredentialError.randomGenerationFailed(status)
        }
        return try Self(
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            catalogPublicKeyFingerprint: .hash(catalogPublicKeyRawRepresentation),
            catalogPublicKeyRawRepresentation: catalogPublicKeyRawRepresentation,
            pskIdentity: pskIdentity,
            transportPSK: psk
        )
    }

    public var catalogTrust: SceneCatalogTrust { storedTrust }

    public var description: String {
        "PairedSceneCatalogCredential(projectID: \(projectID), pskIdentity: \(pskIdentity), secret: <redacted>)"
    }

    public var debugDescription: String { description }
}

public enum SecureSceneCatalogTransportError: Error, Equatable, Sendable {
    case invalidTimeout
    case invalidEndpoint
    case invalidServiceType
    case invalidFrame
    case frameTooLarge(actual: Int)
    case unexpectedMessage
    case responseRequestIDMismatch
    case projectOrCatalogMismatch
    case timedOut
    case cancelled
    case connectionFailed(String)
    case serverAlreadyRunning
    case noPairedClients
    case pairedClientScopeMismatch
    case invalidServiceName
}

public enum SecureSceneCatalogServerState: Equatable, Sendable {
    case idle
    case preparing
    case ready(port: UInt16?)
    case waiting(reason: String)
    case failed(reason: String)
    case stopped
}

public enum SecureSceneCatalogServerEvent: Equatable, Sendable {
    case stateChanged(SecureSceneCatalogServerState)
    case snapshotServed(requestID: UUID, revision: UInt64)
    case requestRejected(reason: String)
}

/// TLS-PSK client for a single signed full-snapshot request.
///
/// It has no scene mutation API. The returned snapshot is verified against the
/// explicitly paired Ed25519 key before it leaves this method.
public struct SecureSceneCatalogClient: Sendable {
    public init() {}

    public func fetchFullSnapshot(
        from service: DiscoveredSceneCatalogService,
        credential: PairedSceneCatalogCredential,
        timeout: TimeInterval = 10
    ) async throws -> SignedSceneCatalogSnapshot {
        guard service.type == BonjourSceneCatalogDiscovery.serviceType else {
            throw SecureSceneCatalogTransportError.invalidServiceType
        }
        let endpoint = NWEndpoint.service(
            name: service.name,
            type: service.type,
            domain: service.domain,
            interface: nil
        )
        return try await fetchFullSnapshot(
            endpoint: endpoint,
            credential: credential,
            timeout: timeout
        )
    }

    /// Manual/diagnostic endpoint that retains the exact same TLS PSK and
    /// signed-key checks as Bonjour. Host entry never weakens pairing trust.
    public func fetchFullSnapshot(
        host: String,
        port: UInt16,
        credential: PairedSceneCatalogCredential,
        timeout: TimeInterval = 10
    ) async throws -> SignedSceneCatalogSnapshot {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw SecureSceneCatalogTransportError.invalidEndpoint
        }
        return try await fetchFullSnapshot(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
            credential: credential,
            timeout: timeout
        )
    }

    private func fetchFullSnapshot(
        endpoint: NWEndpoint,
        credential: PairedSceneCatalogCredential,
        timeout: TimeInterval
    ) async throws -> SignedSceneCatalogSnapshot {
        guard timeout > 0, timeout <= 120, timeout.isFinite else {
            throw SecureSceneCatalogTransportError.invalidTimeout
        }
        let requestID = UUID()
        let request = SceneCatalogTransportCodec.encodeRequest(
            requestID: requestID,
            projectID: credential.projectID,
            catalogID: credential.catalogID
        )
        let operation = TLSPSKFetchOperation(
            endpoint: endpoint,
            parameters: SceneCatalogTLS.parameters(credentials: [credential]),
            framedRequest: try SceneCatalogTransportCodec.frame(request)
        )
        let response = try await withTaskCancellationHandler {
            try await operation.run(timeout: timeout)
        } onCancel: {
            operation.cancel()
        }
        let snapshot = try SceneCatalogTransportCodec.decodeResponse(
            response,
            expectedRequestID: requestID
        )
        _ = try SceneCatalogVerifier.verify(snapshot, trust: credential.catalogTrust)
        return snapshot
    }

    public func fetchAndAcceptFullSnapshot(
        from service: DiscoveredSceneCatalogService,
        credential: PairedSceneCatalogCredential,
        store: AtomicVerifiedSnapshotStore,
        timeout: TimeInterval = 10
    ) async throws -> SnapshotAcceptance {
        let snapshot = try await fetchFullSnapshot(
            from: service,
            credential: credential,
            timeout: timeout
        )
        return try await store.accept(snapshot)
    }
}

/// One-master, read-only full-snapshot service advertised with Bonjour.
///
/// Every accepted TCP connection performs TLS 1.2 PSK authentication. Apple
/// Network.framework's PSK API does not negotiate TLS 1.3, so both bounds are
/// fixed to TLS 1.2; a future mTLS transport can prefer TLS 1.3. The
/// service does not decode or route mutation commands, so an unauthenticated or
/// authenticated client cannot edit the master through this transport.
public final class SecureSceneCatalogServer: @unchecked Sendable {
    public typealias SnapshotProvider = @Sendable () async throws -> SignedSceneCatalogSnapshot

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let serviceName: String
    private let credentials: [PairedSceneCatalogCredential]
    private let trust: SceneCatalogTrust
    private let snapshotProvider: SnapshotProvider
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: SceneCatalogServerSession] = [:]
    private var continuations: [UUID: AsyncStream<SecureSceneCatalogServerEvent>.Continuation] = [:]
    private var state: SecureSceneCatalogServerState = .idle

    public init(
        serviceName: String,
        pairedClients: [PairedSceneCatalogCredential],
        queue: DispatchQueue? = nil,
        snapshotProvider: @escaping SnapshotProvider
    ) throws {
        guard !serviceName.isEmpty, serviceName.utf8.count <= 63,
              !serviceName.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            throw SecureSceneCatalogTransportError.invalidServiceName
        }
        guard let first = pairedClients.first else {
            throw SecureSceneCatalogTransportError.noPairedClients
        }
        guard pairedClients.allSatisfy({
            $0.projectID == first.projectID &&
                $0.catalogID == first.catalogID &&
                $0.authorityID == first.authorityID &&
                $0.authorityEpoch == first.authorityEpoch &&
                $0.catalogPublicKeyFingerprint == first.catalogPublicKeyFingerprint
        }) else {
            throw SecureSceneCatalogTransportError.pairedClientScopeMismatch
        }
        self.serviceName = serviceName
        self.credentials = pairedClients
        self.trust = first.catalogTrust
        self.queue = queue ?? DispatchQueue(
            label: "jp.rinkan.umis.secure-scene-catalog-server",
            qos: .utility
        )
        self.snapshotProvider = snapshotProvider
    }

    public func events() -> AsyncStream<SecureSceneCatalogServerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let currentState = state
            lock.unlock()
            continuation.yield(.stateChanged(currentState))
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    public func start() throws {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            throw SecureSceneCatalogTransportError.serverAlreadyRunning
        }
        lock.unlock()

        let newListener = try NWListener(
            using: SceneCatalogTLS.parameters(credentials: credentials)
        )
        newListener.service = NWListener.Service(
            name: serviceName,
            type: BonjourSceneCatalogDiscovery.serviceType
        )
        newListener.stateUpdateHandler = { [weak self, weak newListener] nextState in
            guard let self, let newListener, self.isCurrent(newListener) else { return }
            switch nextState {
            case .setup:
                self.publishState(.preparing)
            case .waiting(let error):
                self.publishState(.waiting(reason: String(describing: error)))
            case .ready:
                self.publishState(.ready(port: newListener.port?.rawValue))
            case .failed(let error):
                self.publishState(.failed(reason: String(describing: error)))
                self.clearIfCurrent(newListener)
            case .cancelled:
                self.publishState(.stopped)
                self.clearIfCurrent(newListener)
            @unknown default:
                self.publishState(.waiting(reason: "unknown Network.framework state"))
            }
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            guard let self, let newListener, self.isCurrent(newListener) else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }

        lock.lock()
        guard listener == nil else {
            lock.unlock()
            newListener.cancel()
            throw SecureSceneCatalogTransportError.serverAlreadyRunning
        }
        listener = newListener
        lock.unlock()
        publishState(.preparing)
        newListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        activeListener?.cancel()
        for session in activeSessions { session.cancel() }
        publishState(.stopped)
    }

    deinit {
        listener?.cancel()
        for session in sessions.values { session.cancel() }
        for continuation in continuations.values { continuation.finish() }
    }

    private func accept(_ connection: NWConnection) {
        let session = SceneCatalogServerSession(
            connection: connection,
            queue: queue,
            trust: trust,
            snapshotProvider: snapshotProvider,
            onServed: { [weak self] requestID, revision in
                self?.publish(.snapshotServed(requestID: requestID, revision: revision))
            },
            onRejected: { [weak self] reason in
                self?.publish(.requestRejected(reason: reason))
            },
            onFinish: { [weak self] identifier in
                self?.removeSession(identifier)
            }
        )
        lock.lock()
        sessions[session.identifier] = session
        lock.unlock()
        session.start(timeout: 15)
    }

    private func publishState(_ next: SecureSceneCatalogServerState) {
        lock.lock()
        guard state != next else {
            lock.unlock()
            return
        }
        state = next
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(.stateChanged(next)) }
    }

    private func publish(_ event: SecureSceneCatalogServerEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(event) }
    }

    private func isCurrent(_ candidate: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener === candidate
    }

    private func clearIfCurrent(_ candidate: NWListener) {
        lock.lock()
        if listener === candidate { listener = nil }
        lock.unlock()
    }

    private func removeSession(_ identifier: ObjectIdentifier) {
        lock.lock()
        sessions.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func removeContinuation(_ identifier: UUID) {
        lock.lock()
        continuations.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private enum SceneCatalogTLS {
    static func parameters(credentials: [PairedSceneCatalogCredential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        // A resumed TLS 1.2 session authenticates with key material established by an earlier
        // handshake. Network.framework may cache that session process-wide for the same endpoint
        // and PSK identity, which means a newly supplied/rotated PSK is not necessarily exercised.
        // This transport deliberately requires a fresh PSK proof for every snapshot request.
        sec_protocol_options_set_tls_resumption_enabled(
            tls.securityProtocolOptions,
            false
        )
        sec_protocol_options_set_tls_tickets_enabled(
            tls.securityProtocolOptions,
            false
        )
        for credential in credentials {
            let psk = credential.transportPSK.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityBytes = Data(credential.pskIdentity.uuidString.lowercased().utf8)
            let identity = identityBytes.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                tls.securityProtocolOptions,
                psk as dispatch_data_t,
                identity as dispatch_data_t
            )
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

private enum SceneCatalogTransportCodec {
    private static let magic = Data("UMS1".utf8)
    private static let requestType: UInt16 = 1
    private static let responseType: UInt16 = 2

    static func frame(_ body: Data) throws -> Data {
        guard body.count <= SceneCatalogWireFormat.maximumMessageBytes else {
            throw SecureSceneCatalogTransportError.frameTooLarge(actual: body.count)
        }
        var result = Data()
        result.appendBigEndian(UInt32(body.count))
        result.append(body)
        return result
    }

    static func encodeRequest(requestID: UUID, projectID: UUID, catalogID: UUID) -> Data {
        var result = magic
        result.appendBigEndian(requestType)
        result.appendBigEndian(SceneCatalogWireFormat.protocolMajor)
        result.appendBigEndian(SceneCatalogWireFormat.protocolMinor)
        result.appendUUID(requestID)
        result.appendUUID(projectID)
        result.appendUUID(catalogID)
        return result
    }

    static func decodeRequest(_ data: Data) throws -> (requestID: UUID, projectID: UUID, catalogID: UUID) {
        var cursor = DataCursor(data)
        guard try cursor.read(count: magic.count) == magic,
              try cursor.readUInt16() == requestType,
              try cursor.readUInt16() == SceneCatalogWireFormat.protocolMajor,
              try cursor.readUInt16() == SceneCatalogWireFormat.protocolMinor else {
            throw SecureSceneCatalogTransportError.unexpectedMessage
        }
        let requestID = try cursor.readUUID()
        let projectID = try cursor.readUUID()
        let catalogID = try cursor.readUUID()
        guard cursor.isAtEnd else { throw SecureSceneCatalogTransportError.invalidFrame }
        return (requestID, projectID, catalogID)
    }

    static func encodeResponse(
        requestID: UUID,
        snapshot: SignedSceneCatalogSnapshot
    ) throws -> Data {
        guard snapshot.detachedSignature.count == 64 else {
            throw SecureSceneCatalogTransportError.invalidFrame
        }
        guard let payloadLength = UInt32(exactly: snapshot.payloadBytes.count) else {
            throw SecureSceneCatalogTransportError.frameTooLarge(actual: snapshot.payloadBytes.count)
        }
        var result = magic
        result.appendBigEndian(responseType)
        result.appendBigEndian(SceneCatalogWireFormat.protocolMajor)
        result.appendBigEndian(SceneCatalogWireFormat.protocolMinor)
        result.appendUUID(requestID)
        result.appendBigEndian(snapshot.protocolMajor)
        result.appendBigEndian(snapshot.protocolMinor)
        result.appendBigEndian(snapshot.messageType)
        result.appendUUID(snapshot.projectID)
        result.appendUUID(snapshot.catalogID)
        result.appendUUID(snapshot.authorityID)
        result.appendUUID(snapshot.authorityEpoch)
        result.appendBigEndian(snapshot.revision)
        result.appendBigEndian(payloadLength)
        result.append(snapshot.payloadSHA256.bytes)
        result.appendBigEndian(UInt16(snapshot.detachedSignature.count))
        result.append(snapshot.payloadBytes)
        result.append(snapshot.detachedSignature)
        guard result.count <= SceneCatalogWireFormat.maximumMessageBytes else {
            throw SecureSceneCatalogTransportError.frameTooLarge(actual: result.count)
        }
        return result
    }

    static func decodeResponse(
        _ data: Data,
        expectedRequestID: UUID
    ) throws -> SignedSceneCatalogSnapshot {
        var cursor = DataCursor(data)
        guard try cursor.read(count: magic.count) == magic,
              try cursor.readUInt16() == responseType,
              try cursor.readUInt16() == SceneCatalogWireFormat.protocolMajor,
              try cursor.readUInt16() == SceneCatalogWireFormat.protocolMinor else {
            throw SecureSceneCatalogTransportError.unexpectedMessage
        }
        guard try cursor.readUUID() == expectedRequestID else {
            throw SecureSceneCatalogTransportError.responseRequestIDMismatch
        }
        let protocolMajor = try cursor.readUInt16()
        let protocolMinor = try cursor.readUInt16()
        let messageType = try cursor.readUInt16()
        let projectID = try cursor.readUUID()
        let catalogID = try cursor.readUUID()
        let authorityID = try cursor.readUUID()
        let authorityEpoch = try cursor.readUUID()
        let revision = try cursor.readUInt64()
        let payloadLength = Int(try cursor.readUInt32())
        guard payloadLength <= SceneCatalogWireFormat.maximumPayloadBytes else {
            throw SecureSceneCatalogTransportError.frameTooLarge(actual: payloadLength)
        }
        let digest = try SHA256Value(bytes: cursor.read(count: SHA256Value.byteCount))
        let signatureLength = Int(try cursor.readUInt16())
        guard signatureLength == 64 else { throw SecureSceneCatalogTransportError.invalidFrame }
        let payload = try cursor.read(count: payloadLength)
        let signature = try cursor.read(count: signatureLength)
        guard cursor.isAtEnd else { throw SecureSceneCatalogTransportError.invalidFrame }
        return SignedSceneCatalogSnapshot(
            protocolMajor: protocolMajor,
            protocolMinor: protocolMinor,
            messageType: messageType,
            projectID: projectID,
            catalogID: catalogID,
            authorityID: authorityID,
            authorityEpoch: authorityEpoch,
            revision: revision,
            payloadBytes: payload,
            payloadSHA256: digest,
            detachedSignature: signature
        )
    }
}

private struct DataCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SecureSceneCatalogTransportError.invalidFrame
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start..<end])
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try read(count: 2)
        return (UInt16(bytes[bytes.startIndex]) << 8) |
            UInt16(bytes[bytes.index(after: bytes.startIndex)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try read(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try read(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private final class TLSPSKFetchOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let framedRequest: Data
    private let queue = DispatchQueue(
        label: "jp.rinkan.umis.secure-scene-catalog-fetch",
        qos: .utility
    )
    private var continuation: CheckedContinuation<Data, Error>?
    private var terminalResult: Result<Data, Error>?
    private var started = false
    private var ioStarted = false

    init(endpoint: NWEndpoint, parameters: NWParameters, framedRequest: Data) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.framedRequest = framedRequest
    }

    func run(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminalResult {
                lock.unlock()
                continuation.resume(with: terminalResult)
                return
            }
            self.continuation = continuation
            let shouldStart = !started
            started = true
            lock.unlock()
            guard shouldStart else { return }

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(SecureSceneCatalogTransportError.timedOut))
            }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        finish(.failure(SecureSceneCatalogTransportError.cancelled))
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.lock()
            let shouldBegin = !ioStarted && terminalResult == nil
            ioStarted = true
            lock.unlock()
            guard shouldBegin else { return }
            connection.send(content: framedRequest, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(.failure(
                        SecureSceneCatalogTransportError.connectionFailed(String(describing: error))
                    ))
                } else {
                    self?.receiveLength()
                }
            })
        case .failed(let error):
            finish(.failure(
                SecureSceneCatalogTransportError.connectionFailed(String(describing: error))
            ))
        case .cancelled:
            finish(.failure(SecureSceneCatalogTransportError.cancelled))
        default:
            break
        }
    }

    private func receiveLength() {
        receiveExact(count: 4, accumulated: Data()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let lengthBytes):
                let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= SceneCatalogWireFormat.maximumMessageBytes else {
                    self.finish(.failure(
                        SecureSceneCatalogTransportError.frameTooLarge(actual: Int(length))
                    ))
                    return
                }
                self.receiveExact(count: Int(length), accumulated: Data()) { bodyResult in
                    self.finish(bodyResult)
                }
            }
        }
    }

    private func receiveExact(
        count: Int,
        accumulated: Data,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        let remaining = count - accumulated.count
        guard remaining > 0 else {
            completion(.success(accumulated))
            return
        }
        connection.receive(
            minimumIncompleteLength: remaining,
            maximumLength: remaining
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                completion(.failure(
                    SecureSceneCatalogTransportError.connectionFailed(String(describing: error))
                ))
                return
            }
            guard let content, !content.isEmpty else {
                completion(.failure(
                    isComplete ? SecureSceneCatalogTransportError.invalidFrame :
                        SecureSceneCatalogTransportError.connectionFailed("empty receive")
                ))
                return
            }
            var next = accumulated
            next.append(content)
            self.receiveExact(count: count, accumulated: next, completion: completion)
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }
}

private final class SceneCatalogServerSession: @unchecked Sendable {
    let identifier: ObjectIdentifier

    private let lock = NSLock()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let trust: SceneCatalogTrust
    private let snapshotProvider: SecureSceneCatalogServer.SnapshotProvider
    private let onServed: @Sendable (UUID, UInt64) -> Void
    private let onRejected: @Sendable (String) -> Void
    private let onFinish: @Sendable (ObjectIdentifier) -> Void
    private var completed = false
    private var requestTask: Task<Void, Never>?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        trust: SceneCatalogTrust,
        snapshotProvider: @escaping SecureSceneCatalogServer.SnapshotProvider,
        onServed: @escaping @Sendable (UUID, UInt64) -> Void,
        onRejected: @escaping @Sendable (String) -> Void,
        onFinish: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.trust = trust
        self.snapshotProvider = snapshotProvider
        self.onServed = onServed
        self.onRejected = onRejected
        self.onFinish = onFinish
        self.identifier = ObjectIdentifier(connection)
    }

    func start(timeout: TimeInterval) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLength()
            case .failed(let error):
                self.rejectAndFinish(String(describing: error))
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.rejectAndFinish("request timeout")
        }
        connection.start(queue: queue)
    }

    func cancel() { finish() }

    private func receiveLength() {
        receiveExact(count: 4, accumulated: Data()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.rejectAndFinish(String(describing: error))
            case .success(let bytes):
                let length = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= SceneCatalogWireFormat.maximumMessageBytes else {
                    self.rejectAndFinish("frame too large")
                    return
                }
                self.receiveExact(count: Int(length), accumulated: Data()) { bodyResult in
                    switch bodyResult {
                    case .failure(let error):
                        self.rejectAndFinish(String(describing: error))
                    case .success(let body):
                        self.handleRequest(body)
                    }
                }
            }
        }
    }

    private func handleRequest(_ body: Data) {
        let request: (requestID: UUID, projectID: UUID, catalogID: UUID)
        do {
            request = try SceneCatalogTransportCodec.decodeRequest(body)
            guard request.projectID == trust.projectID, request.catalogID == trust.catalogID else {
                throw SecureSceneCatalogTransportError.projectOrCatalogMismatch
            }
        } catch {
            rejectAndFinish(String(describing: error))
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.snapshotProvider()
                _ = try SceneCatalogVerifier.verify(snapshot, trust: self.trust)
                let response = try SceneCatalogTransportCodec.encodeResponse(
                    requestID: request.requestID,
                    snapshot: snapshot
                )
                let frame = try SceneCatalogTransportCodec.frame(response)
                self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.rejectAndFinish(String(describing: error))
                    } else {
                        self.onServed(request.requestID, snapshot.revision)
                        self.finish()
                    }
                })
            } catch {
                self.rejectAndFinish(String(describing: error))
            }
        }
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
        } else {
            requestTask = task
            lock.unlock()
        }
    }

    private func receiveExact(
        count: Int,
        accumulated: Data,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        let remaining = count - accumulated.count
        guard remaining > 0 else {
            completion(.success(accumulated))
            return
        }
        connection.receive(
            minimumIncompleteLength: remaining,
            maximumLength: remaining
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let content, !content.isEmpty else {
                completion(.failure(
                    isComplete ? SecureSceneCatalogTransportError.invalidFrame :
                        SecureSceneCatalogTransportError.connectionFailed("empty receive")
                ))
                return
            }
            var next = accumulated
            next.append(content)
            self.receiveExact(count: count, accumulated: next, completion: completion)
        }
    }

    private func rejectAndFinish(_ reason: String) {
        onRejected(reason)
        finish()
    }

    private func finish() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let task = requestTask
        requestTask = nil
        lock.unlock()
        task?.cancel()
        connection.cancel()
        onFinish(identifier)
    }
}
