import Foundation
import XCTest
@testable import UMISNetwork

final class SDManagementOutboxTests: XCTestCase, @unchecked Sendable {
    func testCardNoPreservesLeadingZeroesAndDisabledGatewayIsSafe() async throws {
        XCTAssertNotEqual(try CardNo("01"), try CardNo("1"))
        let gateway: any SDManagementGateway = DisabledSDManagementGateway()
        let capabilities = try await gateway.capabilities()
        XCTAssertEqual(capabilities, .disabled)

        let query = CardResolutionQuery(
            projectID: UUID(),
            cardNo: try CardNo("01"),
            cardBindingID: UUID(),
            catalogVersion: nil,
            requestedAt: try CanonicalTimestamp("2026-01-01T00:00:00Z")
        )
        do {
            _ = try await gateway.resolveAssignment(query)
            XCTFail("disabled gateway must not resolve")
        } catch {
            XCTAssertEqual(error as? SDManagementGatewayError, .disabled)
        }
        do {
            _ = try await gateway.publish([])
            XCTFail("disabled gateway must not publish")
        } catch {
            XCTAssertEqual(error as? SDManagementGatewayError, .disabled)
        }
    }

    func testRetryUsesFullJitterAndHonorsRetryAfter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableOutboxStore(directoryURL: directory)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = try makeEvent(sequence: 1)
        let enqueueResult = try await store.enqueue(event, now: start)
        XCTAssertEqual(enqueueResult, .inserted)
        let claimed = try await store.claim(
            limit: 10,
            now: start,
            leaseDuration: 30
        )
        let lease = try XCTUnwrap(claimed)
        try await store.apply(
            PublishReceipt(results: [EventPublishResult(
                eventID: event.eventID,
                status: .retryable,
                retryAfterSeconds: 120,
                errorCode: "rate_limited"
            )]),
            toAttempt: lease.attemptID,
            now: start,
            retryPolicy: OutboxRetryPolicy(baseDelaySeconds: 10, maximumDelaySeconds: 600),
            randomUnit: 0.5
        )
        let scheduledValue = await store.record(eventID: event.eventID)
        let scheduled = try XCTUnwrap(scheduledValue)
        XCTAssertEqual(scheduled.state, .retryScheduled)
        XCTAssertEqual(scheduled.nextAttemptAt, start.addingTimeInterval(120))
        let tooEarly = try await store.claim(
            limit: 1,
            now: start.addingTimeInterval(119),
            leaseDuration: 30
        )
        XCTAssertNil(tooEarly)
        let retriedValue = try await store.claim(
            limit: 1,
            now: start.addingTimeInterval(120),
            leaseDuration: 30
        )
        let retried = try XCTUnwrap(retriedValue)
        XCTAssertEqual(retried.events.map(\.eventID), [event.eventID])
        let retriedRecord = await store.record(eventID: event.eventID)
        XCTAssertEqual(retriedRecord?.attemptCount, 2)
    }

    func testAckLossAndRestartReclaimsSameEventID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = try makeEvent(sequence: 1)
        let firstStore = try DurableOutboxStore(directoryURL: directory)
        _ = try await firstStore.enqueue(event, now: start)
        let firstClaim = try await firstStore.claim(
            limit: 1,
            now: start,
            leaseDuration: 30
        )
        let firstLease = try XCTUnwrap(firstClaim)

        // Simulates server commit followed by lost ACK and local process exit.
        let reopened = try DurableOutboxStore(directoryURL: directory)
        let beforeExpiry = try await reopened.claim(
            limit: 1,
            now: start.addingTimeInterval(29),
            leaseDuration: 30
        )
        XCTAssertNil(beforeExpiry)
        let secondClaim = try await reopened.claim(
            limit: 1,
            now: start.addingTimeInterval(30),
            leaseDuration: 30
        )
        let secondLease = try XCTUnwrap(secondClaim)
        XCTAssertNotEqual(firstLease.attemptID, secondLease.attemptID)
        XCTAssertEqual(secondLease.events.map(\.eventID), [event.eventID])

        try await reopened.apply(
            PublishReceipt(results: [EventPublishResult(
                eventID: event.eventID,
                status: .duplicate,
                serverReceiptID: "existing-receipt"
            )]),
            toAttempt: secondLease.attemptID,
            now: start.addingTimeInterval(31)
        )
        let persistedRecord = await reopened.record(eventID: event.eventID)
        let record = try XCTUnwrap(persistedRecord)
        XCTAssertEqual(record.state, .acknowledged)
        XCTAssertEqual(record.serverReceiptID, "existing-receipt")
        XCTAssertEqual(record.event.eventID, event.eventID)
    }

    func testSameEventIDDifferentPayloadIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableOutboxStore(directoryURL: directory)
        let eventID = UUID()
        let jobID = UUID()
        let first = try makeEvent(
            eventID: eventID,
            jobID: jobID,
            sequence: 1,
            type: .ingestStarted
        )
        let changed = try makeEvent(
            eventID: eventID,
            jobID: jobID,
            sequence: 1,
            type: .ingestVerified
        )
        let inserted = try await store.enqueue(first)
        let duplicate = try await store.enqueue(first)
        XCTAssertEqual(inserted, .inserted)
        XCTAssertEqual(duplicate, .alreadyPresent)
        do {
            _ = try await store.enqueue(changed)
            XCTFail("idempotency key reuse with another payload must fail")
        } catch {
            XCTAssertEqual(
                error as? DurableOutboxError,
                .eventIDPayloadMismatch(eventID)
            )
        }
    }

    func testPartialReceiptDoesNotAcknowledgeOmittedEvent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableOutboxStore(directoryURL: directory)
        let time = Date(timeIntervalSince1970: 2_000_000_000)
        let jobID = UUID()
        let first = try makeEvent(jobID: jobID, sequence: 1)
        let second = try makeEvent(jobID: jobID, sequence: 2)
        _ = try await store.enqueue(first, now: time)
        _ = try await store.enqueue(second, now: time.addingTimeInterval(1))
        let claimed = try await store.claim(
            limit: 2,
            now: time.addingTimeInterval(2),
            leaseDuration: 30
        )
        let lease = try XCTUnwrap(claimed)
        try await store.apply(
            PublishReceipt(results: [EventPublishResult(
                eventID: first.eventID,
                status: .accepted
            )]),
            toAttempt: lease.attemptID,
            now: time.addingTimeInterval(3)
        )
        let firstRecord = await store.record(eventID: first.eventID)
        let secondRecord = await store.record(eventID: second.eventID)
        XCTAssertEqual(firstRecord?.state, .acknowledged)
        XCTAssertEqual(secondRecord?.state, .inFlight)
        XCTAssertEqual(secondRecord?.attemptID, lease.attemptID)
    }

    func testAuthPauseAndManualRetryPreserveEventIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableOutboxStore(directoryURL: directory)
        let time = Date(timeIntervalSince1970: 2_000_000_000)
        let event = try makeEvent(sequence: 1)
        _ = try await store.enqueue(event, now: time)
        let claimed = try await store.claim(limit: 1, now: time)
        let lease = try XCTUnwrap(claimed)
        try await store.recordTransportFailure(
            attemptID: lease.attemptID,
            failure: .authenticationRequired(errorCode: "credential_expired"),
            now: time.addingTimeInterval(1)
        )
        let pausedRecord = await store.record(eventID: event.eventID)
        XCTAssertEqual(pausedRecord?.state, .pausedForAuth)
        try await store.manualRetry(eventID: event.eventID, now: time.addingTimeInterval(2))
        let retriedValue = try await store.claim(
            limit: 1,
            now: time.addingTimeInterval(2)
        )
        let retried = try XCTUnwrap(retriedValue)
        XCTAssertEqual(retried.events.first?.eventID, event.eventID)
        let retriedDigest = try retried.events.first?.payloadDigest()
        let originalDigest = try event.payloadDigest()
        XCTAssertEqual(retriedDigest, originalDigest)
    }

    func testPermanentFailureRemainsVisibleAsDeadLetter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableOutboxStore(directoryURL: directory)
        let time = Date(timeIntervalSince1970: 2_000_000_000)
        let event = try makeEvent(sequence: 1)
        _ = try await store.enqueue(event, now: time)
        let claimed = try await store.claim(limit: 1, now: time)
        let lease = try XCTUnwrap(claimed)
        try await store.apply(
            PublishReceipt(results: [EventPublishResult(
                eventID: event.eventID,
                status: .permanent,
                errorCode: "schema_rejected"
            )]),
            toAttempt: lease.attemptID,
            now: time.addingTimeInterval(1)
        )
        let deadLetter = await store.record(eventID: event.eventID)
        XCTAssertEqual(deadLetter?.state, .deadLetter)
        XCTAssertEqual(deadLetter?.lastErrorCode, "schema_rejected")
        XCTAssertEqual(deadLetter?.event.eventID, event.eventID)
    }

    func testCanonicalEventContainsNoSensitivePathOrEraseFields() throws {
        let event = try makeEvent(sequence: 1)
        let json = try XCTUnwrap(String(data: event.canonicalBytes(), encoding: .utf8))
        for forbidden in [
            "path", "filename", "hardwareSerial", "eraseAuthorization",
            "token", "localIP", "macAddress",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), json)
        }
    }

    private func makeEvent(
        eventID: UUID = UUID(),
        jobID: UUID = UUID(),
        sequence: UInt64,
        type: CanonicalIngestEventType = .ingestStarted
    ) throws -> CanonicalIngestEvent {
        try CanonicalIngestEvent(
            eventID: eventID,
            jobID: jobID,
            jobSequence: sequence,
            projectID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            cardNo: CardNo("01"),
            cardBindingID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            photographerID: RemotePhotographerID("photographer-stable-id"),
            sceneIDs: [RemoteSceneID("scene-stable-id")],
            catalogVersion: nil,
            eventType: type,
            fileCount: type == .ingestVerified ? 10 : nil,
            totalBytes: type == .ingestVerified ? 1_024 : nil,
            verificationAlgorithm: type == .ingestVerified ? .sha256Manifest : nil,
            verificationResult: type == .ingestVerified ? .verified : nil,
            occurredAtUTC: CanonicalTimestamp("2026-01-01T00:00:00Z")
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UMISOutboxTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
