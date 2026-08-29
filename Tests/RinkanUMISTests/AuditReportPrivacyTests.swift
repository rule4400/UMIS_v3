import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

final class AuditReportPrivacyTests: XCTestCase {
    func testRemovedSelectionCopyCategoryStillDecodesLegacyAuditExports() throws {
        let legacy = Data(#""selectionCopy""#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionActivityAuditCategory.self, from: legacy),
            .selectionCopy
        )
    }

    func testDefaultReportOmitsHomePathsRawErrorsTitlesAndDetails() throws {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let secretPath = "\(homePath)/CLIENT_SECRET/day1/card-0042.mov"
        let volumePath = "/Volumes/CLIENT_SECRET/PRIVATE/card-0042.mov"
        let rawError = "NSPOSIXErrorDomain code=13 path=\(secretPath) token=do-not-export"
        let operationID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let activities = [
            ActivityRecord(
                id: operationID,
                startedAt: startedAt,
                title: "Unknown operation at \(secretPath)",
                detail: rawError,
                state: .failed,
                itemCount: 0,
                totalBytes: 0
            ),
            ActivityRecord(
                id: UUID(),
                startedAt: startedAt,
                title: "取り込み失敗",
                detail: "Destination \(volumePath): \(rawError)",
                state: .failed,
                itemCount: 3,
                totalBytes: 4_096
            ),
        ]
        let auditEvent = AuditEventRecord(
            sequence: 1,
            operationID: operationID,
            eventType: "operation.failed",
            payload: Data(),
            isPayloadRedacted: true,
            payloadDigest: String(repeating: "a", count: 64),
            previousHash: String(repeating: "0", count: 64),
            eventHash: String(repeating: "b", count: 64),
            createdAt: startedAt,
            chainVerification: .verified,
            epoch: .canonicalV2,
            isEpochGenesis: true
        )
        let report = try AppAuditReport(
            generatedAt: startedAt,
            auditChainVerification: AuditChainVerificationReport(
                status: .verified,
                eventCount: 1,
                verifiedEventCount: 1,
                canonicalEpochStartSequence: 1
            ),
            operations: [],
            auditEvents: [auditEvent],
            sessionActivity: activities
        )

        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(report.privacy, .defaultRedactedExport)
        XCTAssertEqual(report.sessionActivity.map(\.category), [.other, .ingestFailure])
        XCTAssertEqual(report.sessionActivity.map(\.state), [.failed, .failed])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(homePath))
        XCTAssertFalse(json.contains(secretPath))
        XCTAssertFalse(json.contains(volumePath))
        XCTAssertFalse(json.contains("CLIENT_SECRET"))
        XCTAssertFalse(json.contains("NSPOSIXErrorDomain"))
        XCTAssertFalse(json.contains("do-not-export"))
        XCTAssertFalse(json.contains("Unknown operation"))
        XCTAssertFalse(json.contains("\"title\""))
        XCTAssertFalse(json.contains("\"detail\""))
        XCTAssertTrue(json.contains("\"sessionActivityDetailsRedacted\":true"))
        XCTAssertTrue(json.contains("\"localFilesystemPathsIncluded\":false"))
        XCTAssertTrue(json.contains("\"rawErrorMessagesIncluded\":false"))
    }

    func testDefaultReportRejectsAnUnredactedAuditEventPayload() {
        let event = AuditEventRecord(
            sequence: 1,
            operationID: nil,
            eventType: "operation.failed",
            payload: Data("/Users/example/private.mov".utf8),
            isPayloadRedacted: false,
            previousHash: String(repeating: "0", count: 64),
            eventHash: String(repeating: "a", count: 64),
            createdAt: Date(),
            chainVerification: .verified,
            epoch: .canonicalV2,
            isEpochGenesis: true
        )

        XCTAssertThrowsError(
            try AppAuditReport(
                generatedAt: Date(),
                auditChainVerification: AuditChainVerificationReport(
                    status: .verified,
                    eventCount: 1,
                    verifiedEventCount: 1,
                    canonicalEpochStartSequence: 1
                ),
                operations: [],
                auditEvents: [event],
                sessionActivity: []
            )
        ) { error in
            guard case UMISCoreError.invalidPlan = error else {
                return XCTFail("Unexpected report-construction error: \(error)")
            }
        }
    }
}
