import Foundation

public enum SDManagementModelError: Error, Equatable, Sendable {
    case emptyValue(field: String)
    case valueTooLong(field: String, maximumUTF8Bytes: Int)
    case valueNotNFC(field: String)
    case controlCharacter(field: String)
}

/// Business card identifier. It is intentionally a String, so `"01"` and
/// `"1"` remain different values. Project scope lives beside it in requests and
/// events; this value must never be populated from a volume UUID or BSD name.
public struct CardNo: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try SDManagementStringValidator.validate(
            rawValue,
            field: "cardNo",
            maximumUTF8Bytes: 128
        )
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RemotePhotographerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try SDManagementStringValidator.validate(
            rawValue,
            field: "remotePhotographerID",
            maximumUTF8Bytes: 256
        )
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RemoteSceneID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        try SDManagementStringValidator.validate(
            rawValue,
            field: "remoteSceneID",
            maximumUTF8Bytes: 256
        )
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CardResolutionQuery: Codable, Hashable, Sendable {
    public let queryID: UUID
    public let projectID: UUID
    public let cardNo: CardNo
    public let cardBindingID: UUID
    public let catalogVersion: CatalogVersionRef?
    public let requestedAt: CanonicalTimestamp

    public init(
        queryID: UUID = UUID(),
        projectID: UUID,
        cardNo: CardNo,
        cardBindingID: UUID,
        catalogVersion: CatalogVersionRef?,
        requestedAt: CanonicalTimestamp
    ) {
        self.queryID = queryID
        self.projectID = projectID
        self.cardNo = cardNo
        self.cardBindingID = cardBindingID
        self.catalogVersion = catalogVersion
        self.requestedAt = requestedAt
    }
}

public enum AssignmentResolutionSource: String, Codable, Sendable {
    case remote
    case cache
    case manual
}

public enum AssignmentConfidence: String, Codable, Sendable {
    case exact
    case ambiguous
    case unknown
}

public struct AssignmentResolution: Codable, Hashable, Sendable {
    public let resolutionID: UUID
    public let queryID: UUID
    public let projectID: UUID
    public let cardNo: CardNo
    public let cardBindingID: UUID
    public let photographerID: RemotePhotographerID?
    public let sceneIDs: [RemoteSceneID]
    public let catalogVersion: CatalogVersionRef?
    public let source: AssignmentResolutionSource
    public let serverRevision: String
    public let fetchedAt: CanonicalTimestamp
    public let validUntil: CanonicalTimestamp?
    public let isStale: Bool
    public let confidence: AssignmentConfidence

    public init(
        resolutionID: UUID,
        queryID: UUID,
        projectID: UUID,
        cardNo: CardNo,
        cardBindingID: UUID,
        photographerID: RemotePhotographerID?,
        sceneIDs: [RemoteSceneID],
        catalogVersion: CatalogVersionRef?,
        source: AssignmentResolutionSource,
        serverRevision: String,
        fetchedAt: CanonicalTimestamp,
        validUntil: CanonicalTimestamp?,
        isStale: Bool,
        confidence: AssignmentConfidence
    ) {
        self.resolutionID = resolutionID
        self.queryID = queryID
        self.projectID = projectID
        self.cardNo = cardNo
        self.cardBindingID = cardBindingID
        self.photographerID = photographerID
        self.sceneIDs = sceneIDs
        self.catalogVersion = catalogVersion
        self.source = source
        self.serverRevision = serverRevision
        self.fetchedAt = fetchedAt
        self.validUntil = validUntil
        self.isStale = isStale
        self.confidence = confidence
    }
}

public struct GatewayCapabilities: Codable, Hashable, Sendable {
    public let isEnabled: Bool
    public let canResolveAssignments: Bool
    public let canPublishIngestEvents: Bool
    public let supportedEventSchemaVersions: Set<UInt16>

    public init(
        isEnabled: Bool,
        canResolveAssignments: Bool,
        canPublishIngestEvents: Bool,
        supportedEventSchemaVersions: Set<UInt16>
    ) {
        self.isEnabled = isEnabled
        self.canResolveAssignments = canResolveAssignments
        self.canPublishIngestEvents = canPublishIngestEvents
        self.supportedEventSchemaVersions = supportedEventSchemaVersions
    }

    public static let disabled = Self(
        isEnabled: false,
        canResolveAssignments: false,
        canPublishIngestEvents: false,
        supportedEventSchemaVersions: []
    )
}

public enum EventPublishStatus: String, Codable, Sendable {
    case accepted
    case duplicate
    case retryable
    case permanent
}

public struct EventPublishResult: Codable, Hashable, Sendable {
    public let eventID: UUID
    public let status: EventPublishStatus
    public let serverReceiptID: String?
    public let correlationID: String?
    public let retryAfterSeconds: UInt64?
    public let errorCode: String?

    public init(
        eventID: UUID,
        status: EventPublishStatus,
        serverReceiptID: String? = nil,
        correlationID: String? = nil,
        retryAfterSeconds: UInt64? = nil,
        errorCode: String? = nil
    ) {
        self.eventID = eventID
        self.status = status
        self.serverReceiptID = serverReceiptID
        self.correlationID = correlationID
        self.retryAfterSeconds = retryAfterSeconds
        self.errorCode = errorCode
    }
}

public struct PublishReceipt: Codable, Hashable, Sendable {
    public let results: [EventPublishResult]

    public init(results: [EventPublishResult]) {
        self.results = results
    }
}

public enum SDManagementGatewayError: Error, Equatable, Sendable {
    case disabled
    case authenticationRequired
    case transportUnavailable
    case invalidResponse
}

public protocol SDManagementGateway: Sendable {
    func capabilities() async throws -> GatewayCapabilities
    func resolveAssignment(_ query: CardResolutionQuery) async throws -> AssignmentResolution
    func publish(_ events: [CanonicalIngestEvent]) async throws -> PublishReceipt
}

/// The only gateway implementation reachable from a release build until a
/// versioned integration API, service authentication, and approval gate exist.
/// This type contains no URL, credential, or browser-API adapter.
public struct DisabledSDManagementGateway: SDManagementGateway, Sendable {
    public init() {}

    public func capabilities() async throws -> GatewayCapabilities { .disabled }

    public func resolveAssignment(_ query: CardResolutionQuery) async throws -> AssignmentResolution {
        throw SDManagementGatewayError.disabled
    }

    public func publish(_ events: [CanonicalIngestEvent]) async throws -> PublishReceipt {
        throw SDManagementGatewayError.disabled
    }
}

#if DEBUG
/// Test/debug-only gateway. It is absent from release compilation, preventing
/// runtime configuration or reflection from selecting it in production.
public actor MockSDManagementGateway: SDManagementGateway {
    public var capabilityResponse: GatewayCapabilities
    public var assignmentResponse: AssignmentResolution?
    public var publishResponse: PublishReceipt
    public var error: SDManagementGatewayError?
    private var receivedQueries: [CardResolutionQuery] = []
    private var receivedEvents: [CanonicalIngestEvent] = []

    public init(
        capabilityResponse: GatewayCapabilities = GatewayCapabilities(
            isEnabled: true,
            canResolveAssignments: true,
            canPublishIngestEvents: true,
            supportedEventSchemaVersions: [1]
        ),
        assignmentResponse: AssignmentResolution? = nil,
        publishResponse: PublishReceipt = PublishReceipt(results: [])
    ) {
        self.capabilityResponse = capabilityResponse
        self.assignmentResponse = assignmentResponse
        self.publishResponse = publishResponse
    }

    public func capabilities() async throws -> GatewayCapabilities {
        if let error { throw error }
        return capabilityResponse
    }

    public func resolveAssignment(_ query: CardResolutionQuery) async throws -> AssignmentResolution {
        receivedQueries.append(query)
        if let error { throw error }
        guard let assignmentResponse else { throw SDManagementGatewayError.invalidResponse }
        return assignmentResponse
    }

    public func publish(_ events: [CanonicalIngestEvent]) async throws -> PublishReceipt {
        receivedEvents.append(contentsOf: events)
        if let error { throw error }
        return publishResponse
    }

    public func queries() -> [CardResolutionQuery] { receivedQueries }
    public func eventsReceived() -> [CanonicalIngestEvent] { receivedEvents }
}
#endif

private enum SDManagementStringValidator {
    static func validate(_ value: String, field: String, maximumUTF8Bytes: Int) throws {
        guard !value.isEmpty else { throw SDManagementModelError.emptyValue(field: field) }
        guard Data(value.utf8) == Data(value.precomposedStringWithCanonicalMapping.utf8) else {
            throw SDManagementModelError.valueNotNFC(field: field)
        }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw SDManagementModelError.controlCharacter(field: field)
        }
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw SDManagementModelError.valueTooLong(
                field: field,
                maximumUTF8Bytes: maximumUTF8Bytes
            )
        }
    }
}
