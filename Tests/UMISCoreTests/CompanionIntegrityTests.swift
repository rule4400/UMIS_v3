import Foundation
import XCTest
@testable import UMISCore

final class CompanionIntegrityTests: XCTestCase {
    func testGroupKeyUsesRelativeDirectoryAndUnicodeNormalizedStem() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        _ = try fixture.writeSource(name: "DCIM/Café.MOV", data: Data("primary".utf8))
        _ = try fixture.writeSource(name: "DCIM/Cafe\u{301}.XMP", data: Data("sidecar".utf8))
        _ = try fixture.writeSource(name: "OTHER/Café.XMP", data: Data("other".utf8))
        let scan = try await MediaScanner().scan(root: fixture.source)
        let primary = try XCTUnwrapValue(scan.assets.first { $0.pathExtension.lowercased() == "mov" })
        let sameDirectorySidecar = try XCTUnwrapValue(
            scan.assets.first { $0.relativePath.hasPrefix("DCIM/") && $0.kind == .sidecar }
        )
        let otherDirectorySidecar = try XCTUnwrapValue(
            scan.assets.first { $0.relativePath.hasPrefix("OTHER/") }
        )

        XCTAssertEqual(
            MediaCompanionGrouping.groupKey(for: primary),
            MediaCompanionGrouping.groupKey(for: sameDirectorySidecar)
        )
        XCTAssertNotEqual(
            MediaCompanionGrouping.groupKey(for: primary),
            MediaCompanionGrouping.groupKey(for: otherDirectorySidecar)
        )
        XCTAssertEqual(
            MediaCompanionGrouping.assetIDs(sharingGroupWith: primary.id, in: scan.assets),
            [primary.id, sameDirectorySidecar.id]
        )
    }

    func testValidPrimaryAndCompanionsShareFrozenSceneStemAndParent() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let plan = try await makePlan(
            fixture: fixture,
            files: ["DCIM/A001.MOV", "DCIM/A001.XMP", "DCIM/A001.SRT"]
        ) { asset in
            "Movies/SC01/SC01_0001.\(asset.pathExtension)"
        }

        XCTAssertNoThrow(try plan.validate())
        XCTAssertEqual(Set(plan.items.compactMap(\.scene?.id)).count, 1)
        XCTAssertEqual(
            Set(plan.items.map { $0.finalURL.deletingLastPathComponent().path }),
            [fixture.destination.appendingPathComponent("Movies/SC01").path]
        )
        XCTAssertEqual(
            Set(plan.items.map { $0.finalURL.deletingPathExtension().lastPathComponent }),
            ["SC01_0001"]
        )
    }

    func testDecodedPlanRejectsCompanionSceneStemAndParentDivergence() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let valid = try await makePlan(
            fixture: fixture,
            files: ["A001.MOV", "A001.XMP"]
        ) { asset in
            "Movies/SC01/SC01_0001.\(asset.pathExtension)"
        }
        let sidecarIndex = try XCTUnwrapValue(valid.items.firstIndex { $0.asset.kind == .sidecar })

        var wrongScene = valid
        wrongScene.items[sidecarIndex].scene = Scene(
            projectID: valid.project.id,
            displayName: "Different Scene",
            code: "SC02"
        )
        try assertDecodedPlanIsRejected(wrongScene)

        var wrongStem = valid
        wrongStem.items[sidecarIndex].finalURL = fixture.destination
            .appendingPathComponent("Movies/SC01/SC01_9999.XMP")
        try assertDecodedPlanIsRejected(wrongStem)

        var wrongParent = valid
        wrongParent.items[sidecarIndex].finalURL = fixture.destination
            .appendingPathComponent("Sidecars/SC01_0001.XMP")
        try assertDecodedPlanIsRejected(wrongParent)
    }

    func testSidecarOnlyAndMultiplePrimaryGroupsFailClosed() async throws {
        let sidecarOnlyFixture = try CoreFixture(); defer { sidecarOnlyFixture.cleanup() }
        let sidecarOnly = try await makePlan(
            fixture: sidecarOnlyFixture,
            files: ["A001.MOV", "A001.XMP"],
            excludedNames: ["A001.MOV"]
        ) { asset in
            "Movies/SC01/SC01_0001.\(asset.pathExtension)"
        }
        XCTAssertThrowsError(try sidecarOnly.validate()) { error in
            guard case UMISCoreError.invalidPlan = error else {
                return XCTFail("Unexpected sidecar-only error: \(error)")
            }
        }

        let ambiguousFixture = try CoreFixture(); defer { ambiguousFixture.cleanup() }
        let ambiguous = try await makePlan(
            fixture: ambiguousFixture,
            files: ["A001.MOV", "A001.JPG", "A001.XMP"]
        ) { asset in
            "Media/SC01/SC01_0001.\(asset.pathExtension)"
        }
        XCTAssertThrowsError(try ambiguous.validate()) { error in
            guard case UMISCoreError.invalidPlan = error else {
                return XCTFail("Unexpected ambiguous-primary error: \(error)")
            }
        }
    }

    func testAuditedExtraPrimaryExclusionLeavesOneUnambiguousPrimary() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let plan = try await makePlan(
            fixture: fixture,
            files: ["A001.MOV", "A001.JPG", "A001.XMP"],
            excludedNames: ["A001.JPG"]
        ) { asset in
            "Media/SC01/SC01_0001.\(asset.pathExtension)"
        }
        XCTAssertTrue(plan.requiredSet.hasAuditedExplicitExclusions)
        XCTAssertNoThrow(try plan.validate())
    }

    func testDifferentSourceGroupsCannotMergeAtDestinationUsingDifferentExtensions() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let plan = try await makePlan(
            fixture: fixture,
            files: ["A001.MOV", "A001.XMP", "B001.JPG", "B001.AAE"]
        ) { asset in
            // No complete destination filename collides, but the two logical source groups would
            // merge into one stem and make the sidecars ambiguous.
            "Media/SC01/SC01_0001.\(asset.pathExtension)"
        }
        XCTAssertThrowsError(try plan.validate()) { error in
            guard case UMISCoreError.collision = error else {
                return XCTFail("Unexpected destination-group collision error: \(error)")
            }
        }
    }

    private func makePlan(
        fixture: CoreFixture,
        files: [String],
        excludedNames: Set<String> = [],
        destinationRelativePath: (MediaAsset) -> String
    ) async throws -> IngestPlan {
        for name in files {
            _ = try fixture.writeSource(name: name, data: Data(name.utf8))
        }
        let sourceID = SourceVolumeID()
        let scan = try await MediaScanner().scan(root: fixture.source, sourceVolumeID: sourceID)
        let destination = try DestinationIdentityResolver().resolve(rootURL: fixture.destination)
        let excludedAssets = scan.assets.filter { excludedNames.contains($0.originalName) }
        let excludedIDs = Set(excludedAssets.map(\.id))
        let evidence = try excludedAssets.map { asset in
            try scan.makeExplicitExclusionEvidence(
                assetID: asset.id,
                reason: "Operator reviewed ambiguous companion membership",
                operatorIdentifier: "operator-001",
                confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let included = scan.assets.filter { !excludedIDs.contains($0.id) }
        let requiredSet = try scan.validatedRequiredSet(
            selectedAssetIDs: Set(included.map(\.id)),
            destinationID: destination.id,
            explicitlyExcludedAssetIDs: excludedIDs,
            explicitExclusions: evidence
        )
        let project = Project(name: "Companion Test", destination: fixture.destination)
        let scene = Scene(
            projectID: project.id,
            displayName: "Scene 1",
            code: "SC01",
            sortOrder: 1
        )
        let items = included.map { asset in
            IngestPlanItem(
                asset: asset,
                scene: scene,
                sourceURL: asset.canonicalURL,
                finalURL: fixture.destination.appendingPathComponent(
                    destinationRelativePath(asset)
                ),
                expectedSourceFingerprint: asset.fingerprint,
                duplicatePolicy: .verifyIdentical
            )
        }
        return IngestPlan(
            project: project,
            sourceVolume: makeStrongVolume(id: sourceID, mountURL: fixture.source),
            destination: destination,
            requiredSet: requiredSet,
            items: items
        )
    }

    private func assertDecodedPlanIsRejected(
        _ plan: IngestPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(IngestPlan.self, from: encoder.encode(plan))
        XCTAssertThrowsError(try decoded.validate(), file: file, line: line)
    }
}
