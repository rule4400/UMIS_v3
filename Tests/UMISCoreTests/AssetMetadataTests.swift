import Darwin
import Foundation
import XCTest
@testable import UMISCore

final class AssetMetadataTests: XCTestCase {
    func testAdobeRatingValidatesOfficialDiscreteValues() throws {
        XCTAssertEqual(try AdobeRating(validating: -1), .rejected)
        XCTAssertEqual(try AdobeRating(validating: 0), .unrated)
        XCTAssertEqual(try AdobeRating(validating: 5), .fiveStars)
        XCTAssertNil(AdobeRating.rejected.starCount)
        XCTAssertEqual(AdobeRating.fourStars.starCount, 4)
        XCTAssertThrowsError(try AdobeRating(validating: -2))
        XCTAssertThrowsError(try AdobeRating(validating: 6))
    }

    func testNewXMPSidecarRoundTripsRatingAndDoesNotModifyMedia() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let originalMedia = Data("original-media-payload".utf8)
        try originalMedia.write(to: fixture.media)

        let service = AdobeXMPSidecarRatingService()
        let sidecar = try service.writeRating(.fourStars, forMediaAt: fixture.media)

        XCTAssertEqual(sidecar, fixture.root.appendingPathComponent("A001.xmp"))
        XCTAssertEqual(try Data(contentsOf: fixture.media), originalMedia)
        XCTAssertEqual(try service.readRating(forMediaAt: fixture.media), .fourStars)

        let document = try XMLDocument(data: Data(contentsOf: sidecar), options: [])
        let nodes = try document.nodes(forXPath: "//@*").filter {
            $0.localName == "Rating" && $0.uri == "http://ns.adobe.com/xap/1.0/"
        }
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.stringValue, "4")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .allSatisfy { !$0.contains(".umis-") && !$0.hasSuffix(".partial") }
        )
    }

    func testMissingRatingReadsAsUnrated() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let xmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/x-test"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(xmp.utf8).write(to: fixture.replacingSidecar)

        let result = try AdobeXMPSidecarRatingService().readRatingResult(forMediaAt: fixture.media)
        XCTAssertEqual(result.rating, .unrated)
        XCTAssertFalse(result.hasExplicitRating)
    }

    func testWritingUnratedCreatesExplicitZeroAndExistingPacketKeepsExplicitZero() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let service = AdobeXMPSidecarRatingService()

        let prospective = try service.writeRating(.unrated, forMediaAt: fixture.media)
        XCTAssertEqual(prospective, fixture.replacingSidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.replacingSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingSidecar.path))
        let newlyExplicitZero = try service.readRatingResult(forMediaAt: fixture.media)
        XCTAssertEqual(newlyExplicitZero.rating, .unrated)
        XCTAssertTrue(newlyExplicitZero.hasExplicitRating)

        let existing = Data(validXMP(rating: "4").utf8)
        try existing.write(to: fixture.replacingSidecar)
        try service.writeRating(.unrated, forMediaAt: fixture.media)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.replacingSidecar.path))
        let explicitZero = try service.readRatingResult(forMediaAt: fixture.media)
        XCTAssertEqual(explicitZero.rating, .unrated)
        XCTAssertTrue(explicitZero.hasExplicitRating)
    }

    func testEmptyRDFReceivesDescriptionWithoutReplacingPacket() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <!--empty-rdf-marker-->
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>
        </x:xmpmeta>
        """
        try Data(xmp.utf8).write(to: fixture.replacingSidecar)

        let service = AdobeXMPSidecarRatingService()
        try service.writeRating(.twoStars, forMediaAt: fixture.media)

        XCTAssertEqual(try service.readRating(forMediaAt: fixture.media), .twoStars)
        let updated = try XCTUnwrap(String(data: Data(contentsOf: fixture.replacingSidecar), encoding: .utf8))
        XCTAssertTrue(updated.contains("empty-rdf-marker"))
    }

    func testExistingXMPPreservesUnknownMetadataCommentsPermissionsAndXattrs() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <!--keep-this-comment-->
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:custom="https://example.invalid/umis/custom/1.0/"
              xmp:Rating="2" dc:format="video/quicktime" custom:stable="retain-me">
              <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Original title</rdf:li></rdf:Alt></dc:title>
              <custom:payload>opaque-value</custom:payload>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(xmp.utf8).write(to: fixture.replacingSidecar)
        XCTAssertEqual(Darwin.chmod(fixture.replacingSidecar.path, 0o640), 0)
        let customXattr = Data("unrelated-sidecar-xattr".utf8)
        try setRawXattr(name: "com.rinkan.umis.metadata-test", data: customXattr, at: fixture.replacingSidecar)

        let service = AdobeXMPSidecarRatingService()
        try service.writeRating(.fiveStars, forMediaAt: fixture.media)

        XCTAssertEqual(try service.readRating(forMediaAt: fixture.media), .fiveStars)
        let updatedData = try Data(contentsOf: fixture.replacingSidecar)
        let updatedText = try XCTUnwrap(String(data: updatedData, encoding: .utf8))
        XCTAssertTrue(updatedText.contains("keep-this-comment"))
        XCTAssertTrue(updatedText.contains("Original title"))
        XCTAssertTrue(updatedText.contains("opaque-value"))

        let document = try XMLDocument(data: updatedData, options: [])
        XCTAssertEqual(
            try document.nodes(forXPath: "//*[local-name()='payload']").first?.stringValue,
            "opaque-value"
        )
        XCTAssertEqual(
            try document.nodes(forXPath: "//@*[local-name()='stable']").first?.stringValue,
            "retain-me"
        )
        XCTAssertEqual(
            try document.nodes(forXPath: "//@*[local-name()='format']").first?.stringValue,
            "video/quicktime"
        )
        XCTAssertEqual(try rawXattr(name: "com.rinkan.umis.metadata-test", at: fixture.replacingSidecar), customXattr)

        var status = stat()
        let statResult: Int32 = fixture.replacingSidecar.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        XCTAssertEqual(statResult, 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o640)
    }

    func testIntegralRealRatingAndChildRepresentationAreSupported() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let xmp = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <rdf:Description rdf:about=""><xmp:Rating>3.0</xmp:Rating></rdf:Description>
        </rdf:RDF>
        """
        try Data(xmp.utf8).write(to: fixture.appendingSidecar)
        let service = AdobeXMPSidecarRatingService()

        XCTAssertEqual(try service.readRating(forMediaAt: fixture.media), .threeStars)
        let resolved = try service.writeRating(.rejected, forMediaAt: fixture.media)
        XCTAssertEqual(resolved, fixture.appendingSidecar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.replacingSidecar.path))

        let document = try XMLDocument(data: Data(contentsOf: resolved), options: [])
        let elements = try document.nodes(forXPath: "//*").filter {
            $0.localName == "Rating" && $0.uri == "http://ns.adobe.com/xap/1.0/"
        }
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.stringValue, "-1")
    }

    func testFractionalOrConflictingRatingFailsClosedWithoutChangingSidecar() throws {
        for ratingXML in [
            "<xmp:Rating>2.5</xmp:Rating>",
            "<xmp:Rating>1e300</xmp:Rating>",
            "<xmp:Rating>2</xmp:Rating><xmp:Rating>4</xmp:Rating>",
        ] {
            let fixture = try MetadataFixture()
            defer { fixture.cleanup() }
            let xmp = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                     xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <rdf:Description rdf:about="">\(ratingXML)</rdf:Description>
            </rdf:RDF>
            """
            let original = Data(xmp.utf8)
            try original.write(to: fixture.replacingSidecar)
            let service = AdobeXMPSidecarRatingService()
            XCTAssertThrowsError(try service.readRating(forMediaAt: fixture.media))
            XCTAssertThrowsError(try service.writeRating(.fiveStars, forMediaAt: fixture.media))
            XCTAssertEqual(try Data(contentsOf: fixture.replacingSidecar), original)
        }
    }

    func testMalformedOrDoctypeXMPIsNeverOverwritten() throws {
        for original in [
            Data("not XML at all".utf8),
            Data("""
            <!DOCTYPE rdf:RDF [<!ENTITY dangerous SYSTEM "file:///etc/passwd">]>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="">&dangerous;</rdf:Description>
            </rdf:RDF>
            """.utf8),
        ] {
            let fixture = try MetadataFixture()
            defer { fixture.cleanup() }
            try original.write(to: fixture.replacingSidecar)

            XCTAssertThrowsError(
                try AdobeXMPSidecarRatingService().writeRating(.oneStar, forMediaAt: fixture.media)
            )
            XCTAssertEqual(try Data(contentsOf: fixture.replacingSidecar), original)
        }
    }

    func testMediaAndSidecarSymbolicLinksAreRejectedWithoutTouchingTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-metadata-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realMedia = root.appendingPathComponent("real.mov")
        let linkedMedia = root.appendingPathComponent("linked.mov")
        try Data("real-media".utf8).write(to: realMedia)
        try FileManager.default.createSymbolicLink(at: linkedMedia, withDestinationURL: realMedia)
        XCTAssertThrowsError(try AdobeXMPSidecarRatingService().writeRating(.oneStar, forMediaAt: linkedMedia)) {
            XCTAssertEqual($0 as? UMISCoreError, .symbolicLinkRejected(linkedMedia.path))
        }

        let media = root.appendingPathComponent("A001.mov")
        let sidecar = root.appendingPathComponent("A001.xmp")
        let innocentTarget = root.appendingPathComponent("innocent.txt")
        let innocentData = Data("must-not-change".utf8)
        try Data("media".utf8).write(to: media)
        try innocentData.write(to: innocentTarget)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: innocentTarget)
        XCTAssertThrowsError(try AdobeXMPSidecarRatingService().writeRating(.fiveStars, forMediaAt: media)) {
            XCTAssertEqual($0 as? UMISCoreError, .symbolicLinkRejected(sidecar.path))
        }
        XCTAssertEqual(try Data(contentsOf: innocentTarget), innocentData)
    }

    func testTwoNamingVariantsAreRejectedAsAmbiguous() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let valid = Data(validXMP(rating: "1").utf8)
        try valid.write(to: fixture.replacingSidecar)
        try valid.write(to: fixture.appendingSidecar)

        XCTAssertThrowsError(try AdobeXMPSidecarRatingService().readRating(forMediaAt: fixture.media)) {
            guard case .ambiguousXMPSidecars = $0 as? AssetMetadataError else {
                return XCTFail("Expected ambiguousXMPSidecars, got \($0)")
            }
        }
    }

    func testUppercaseXMPIsReusedRatherThanCreatingLowercaseDuplicate() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let uppercase = fixture.root.appendingPathComponent("A001.XMP")
        try Data(validXMP(rating: "2").utf8).write(to: uppercase)

        let service = AdobeXMPSidecarRatingService()
        let resolved = try service.writeRating(.threeStars, forMediaAt: fixture.media)
        XCTAssertEqual(try service.readRating(forMediaAt: fixture.media), .threeStars)
        XCTAssertEqual(resolved.lastPathComponent.lowercased(), "a001.xmp")
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.lowercased() == "a001.xmp" }
        XCTAssertEqual(sidecars.count, 1)
    }

    func testAnchoredSidecarRejectsPrivateReplacementLeafSwapBeforeCommit() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let service = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .replaceReplacementBeforeCommit
        )

        XCTAssertThrowsError(
            try service.writeRatingResult(
                .fourStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingSidecar.path))
        let recoveries = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(recoveries.records.count, 1)
        XCTAssertEqual(recoveries.records.first?.state, "pendingCommit")
    }

    func testAnchoredSidecarRetainsOldDataWhenTargetIsReplacedAfterSwap() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let ordinary = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred
        )
        try ordinary.writeRating(
            .oneStar,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        let originalSidecar = try Data(contentsOf: fixture.appendingSidecar)
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .replaceTargetAfterCommit
        )

        XCTAssertThrowsError(
            try faulting.writeRatingResult(
                .fiveStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        ) { error in
            guard case let .recoveryRetained(_, recoveryLeaf, _) = error as? AssetMetadataError else {
                return XCTFail("Expected structured recovery retention, got \(error)")
            }
            XCTAssertTrue(recoveryLeaf.hasPrefix(".umis-xmp-recovery-"))
        }
        XCTAssertNotEqual(try Data(contentsOf: fixture.appendingSidecar), originalSidecar)
        let recoveries = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(recoveries.records.count, 1)
        XCTAssertEqual(recoveries.records.first?.kind, .sidecarXMP)
        XCTAssertNotNil(recoveries.records.first?.original)
    }

    func testAnchoredSidecarCtimeChangeBeforeCommitFailsClosed() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let ordinary = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred
        )
        try ordinary.writeRating(
            .twoStars,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        let before = try Data(contentsOf: fixture.appendingSidecar)
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .changeExistingMetadataBeforeCommit
        )

        XCTAssertThrowsError(
            try faulting.writeRatingResult(
                .fiveStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.appendingSidecar), before)
        let recoveries = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(recoveries.records.count, 1)
        XCTAssertEqual(recoveries.records.first?.state, "pendingCommit")
    }

    func testAnchoredSidecarCleanupMismatchReturnsStructuredErrorAndBlocksLaterWrite() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let ordinary = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred
        )
        try ordinary.writeRating(
            .oneStar,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .changeTargetMetadataBeforeCleanup
        )
        XCTAssertThrowsError(
            try faulting.writeRatingResult(
                .fourStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        ) { error in
            guard case let .recoveryRetained(_, leaf, _) = error as? AssetMetadataError else {
                return XCTFail("Expected structured cleanup recovery error, got \(error)")
            }
            XCTAssertTrue(leaf.hasPrefix(".umis-xmp-recovery-"))
        }
        let recoveries = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(recoveries.records.count, 1)
        XCTAssertEqual(recoveries.records.first?.state, "awaitingUpperReadback")
        XCTAssertTrue(recoveries.records.first?.mayContainOriginalBackup == true)
        XCTAssertNotNil(recoveries.records.first?.committed)

        XCTAssertThrowsError(
            try ordinary.writeRatingResult(
                .fiveStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        ) { error in
            guard case .recoveryRetained = error as? AssetMetadataError else {
                return XCTFail("Expected unresolved recovery to block a later write, got \(error)")
            }
        }
    }

    func testAnchoredSidecarNeverUnlinksSubstitutedRecoveryArtifact() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let ordinary = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred
        )
        try ordinary.writeRating(
            .oneStar,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .replaceRecoveryArtifactBeforeCleanup
        )

        XCTAssertThrowsError(
            try faulting.writeRatingResult(
                .fiveStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        ) { error in
            guard case .recoveryRetained = error as? AssetMetadataError else {
                return XCTFail("Expected substituted recovery artifact to fail closed, got \(error)")
            }
        }
        let recoveryLeaf = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .first { $0.hasPrefix(".umis-xmp-recovery-") }
        )
        let recoveryURL = fixture.root.appendingPathComponent(recoveryLeaf, isDirectory: true)
        let recoveryEntries = try FileManager.default.contentsOfDirectory(
            at: recoveryURL,
            includingPropertiesForKeys: nil
        )
        let marker = Data("intentional-test-replacement".utf8)
        let substitutedWasRetained = recoveryEntries.contains { entry in
            (try? Data(contentsOf: entry)) == marker
        }
        XCTAssertTrue(substitutedWasRetained)
    }

    func testNewSidecarPostCommitReplacementRetainsRecoveryAndFailsClosed() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .replaceTargetAfterCommit
        )

        XCTAssertThrowsError(
            try faulting.writeRatingResult(
                .fourStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
        ) { error in
            guard case .recoveryRetained = error as? AssetMetadataError else {
                return XCTFail("Expected new-sidecar target replacement to retain recovery, got \(error)")
            }
        }
        let records = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        ).records
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.original)
        XCTAssertEqual(records.first?.state, "pendingCommit")
    }

    func testCleanupFailureAfterVerifiedOriginalUnlinkDoesNotClaimBackupRetention() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: fixture.media)
        let ordinary = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred
        )
        try ordinary.writeRating(
            .oneStar,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        let faulting = AdobeXMPSidecarRatingService(
            preferredNaming: .appendingToMediaFilename,
            resolutionPolicy: .strictPreferred,
            recoveryTestFault: .failAfterOriginalCleanup
        )

        let result = try faulting.writeRatingResult(
            .fourStars,
            parentFileDescriptor: parent,
            mediaLeafName: fixture.media.lastPathComponent,
            displayURL: fixture.media,
            expectedMediaFingerprint: expected
        )
        XCTAssertTrue(result.recoveryAttentionRequired)
        XCTAssertNotNil(result.recoveryWarning)
        XCTAssertEqual(
            try ordinary.readRating(
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            ),
            .fourStars
        )
        let records = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        ).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, "committedOriginalRemoved")
        XCTAssertFalse(records.first?.mayContainOriginalBackup == true)
    }

    func testCleanupStateManifestRemainsAuthoritativeUntilRemovedLast() throws {
        func runCase(
            fault: AdobeXMPSidecarRecoveryTestFault,
            expectedState: String,
            expectedRemainingManifestNames: Set<String>,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let fixture = try MetadataFixture()
            defer { fixture.cleanup() }
            let parent = Darwin.open(
                fixture.root.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            XCTAssertGreaterThanOrEqual(parent, 0, file: file, line: line)
            defer { if parent >= 0 { Darwin.close(parent) } }
            let expected = try FileFingerprint.capture(at: fixture.media)
            let ordinary = AdobeXMPSidecarRatingService(
                preferredNaming: .appendingToMediaFilename,
                resolutionPolicy: .strictPreferred
            )
            try ordinary.writeRating(
                .oneStar,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
            let faulting = AdobeXMPSidecarRatingService(
                preferredNaming: .appendingToMediaFilename,
                resolutionPolicy: .strictPreferred,
                recoveryTestFault: fault
            )

            let result = try faulting.writeRatingResult(
                .fourStars,
                parentFileDescriptor: parent,
                mediaLeafName: fixture.media.lastPathComponent,
                displayURL: fixture.media,
                expectedMediaFingerprint: expected
            )
            XCTAssertTrue(result.recoveryAttentionRequired, file: file, line: line)
            let record = try XCTUnwrap(
                MetadataRecoveryInspector().scanTree(
                    rootFileDescriptor: parent,
                    displayRootURL: fixture.root
                ).records.first,
                file: file,
                line: line
            )
            XCTAssertEqual(record.state, expectedState, file: file, line: line)
            XCTAssertFalse(record.mayContainOriginalBackup, file: file, line: line)

            let recoveryURL = fixture.root.appendingPathComponent(
                record.recoveryDirectoryLeaf,
                isDirectory: true
            )
            let manifestNames = Set(
                try FileManager.default.contentsOfDirectory(atPath: recoveryURL.path)
                    .filter { $0.hasPrefix("manifest.") }
            )
            XCTAssertEqual(
                manifestNames,
                expectedRemainingManifestNames,
                file: file,
                line: line
            )
        }

        try runCase(
            fault: .failAfterSealedManifestCleanup,
            expectedState: "committedOriginalRemoved",
            expectedRemainingManifestNames: [
                "manifest.pending.json",
                "manifest.cleanup.json",
            ]
        )
        try runCase(
            fault: .failAfterPendingManifestCleanup,
            expectedState: "committedOriginalRemoved",
            expectedRemainingManifestNames: ["manifest.cleanup.json"]
        )
        try runCase(
            fault: .failAfterCleanupManifestCleanup,
            expectedState: "unknownOrBroken",
            expectedRemainingManifestNames: []
        )
    }

    func testCleanTreeBatchAuthorizationAvoidsPerAssetDirectoryEnumeration() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let secondMedia = fixture.root.appendingPathComponent("A002.unknown")
        try Data("second-media".utf8).write(to: secondMedia)
        // Model a large archive parent: the one bounded preflight enumerates these entries once,
        // while every subsequent asset must stay O(1) at the recovery guard boundary.
        for index in 0 ..< 512 {
            try Data().write(to: fixture.root.appendingPathComponent("catalog-\(index).dat"))
        }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let preflight = try MetadataRecoveryInspector().prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        let authorization = try XCTUnwrap(preflight.authorization)
        XCTAssertFalse(preflight.scanResult.wasTruncated)
        XCTAssertTrue(preflight.scanResult.records.isEmpty)
        let service = AdobeXMPRatingService()
        let context = AdobeXMPRatingMutationContext(
            hasLatestVerifiedReceipt: false,
            recoveryWriteAuthorization: authorization
        )
        MetadataRecoveryWriteGuard.resetEnumerationCountForTesting()
        for media in [fixture.media, secondMedia] {
            let result = try service.writeRating(
                .threeStars,
                parentFileDescriptor: parent,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: FileFingerprint.capture(at: media),
                context: context
            )
            XCTAssertFalse(
                result.recoveryAttentionRequired,
                result.compatibilityWarning ?? "unexpected recovery attention"
            )
        }
        XCTAssertEqual(MetadataRecoveryWriteGuard.enumerationCountForTesting, 0)

        let thirdMedia = fixture.root.appendingPathComponent("A003.unknown")
        try Data("third-media".utf8).write(to: thirdMedia)
        _ = try service.writeRating(
            .twoStars,
            parentFileDescriptor: parent,
            mediaLeafName: thirdMedia.lastPathComponent,
            displayURL: thirdMedia,
            expectedFingerprint: FileFingerprint.capture(at: thirdMedia),
            context: AdobeXMPRatingMutationContext(hasLatestVerifiedReceipt: false)
        )
        XCTAssertEqual(MetadataRecoveryWriteGuard.enumerationCountForTesting, 1)
    }

    func testWriteAuthorizationIsNilForTruncatedTreeAndInvalidatesFailClosed() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }

        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("nested"),
            withIntermediateDirectories: false
        )
        let bounded = try MetadataRecoveryInspector(maximumDirectories: 1).prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertTrue(bounded.scanResult.wasTruncated)
        XCTAssertNil(bounded.authorization)

        let clean = try MetadataRecoveryInspector().prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        let authorization = try XCTUnwrap(clean.authorization)
        authorization.invalidate(reason: "intentional test invalidation")
        XCTAssertThrowsError(
            try authorization.requireAuthorizedParent(parent, displayURL: fixture.media)
        )
    }

    func testWriteAuthorizationIsNilWhenRecoveryTreeIsDirty() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(
                ".umis-xmp-recovery-unresolved-test",
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let preflight = try MetadataRecoveryInspector().prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertNil(preflight.authorization)
        XCTAssertEqual(preflight.scanResult.records.count, 1)
    }

    func testWriteAuthorizationExclusivelyLocksRootAndReleasesDescriptor() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        var first: MetadataRecoveryWritePreflight? = try MetadataRecoveryInspector().prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertNotNil(first?.authorization)
        XCTAssertThrowsError(
            try MetadataRecoveryInspector().prepareWriteTree(
                rootFileDescriptor: parent,
                displayRootURL: fixture.root
            )
        )
        first = nil
        let reacquired = try MetadataRecoveryInspector().prepareWriteTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertNotNil(reacquired.authorization)
        let descriptorsDuringLease = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(descriptorsDuringLease, descriptorsBefore + 3)
    }

    func testRecoveryInspectorFindsNestedBrokenOrphansWithoutFollowingPackagesOrSymlinks() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let nested = fixture.root
            .appendingPathComponent("day-01", isDirectory: true)
            .appendingPathComponent("camera-a", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let broken = nested.appendingPathComponent(
            ".umis-xmp-recovery-broken-orphan",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        try Data("{not-valid-json".utf8).write(
            to: broken.appendingPathComponent("manifest.sealed.json")
        )

        let package = fixture.root.appendingPathComponent("Ignored.app", isDirectory: true)
        let packageRecovery = package.appendingPathComponent(
            ".umis-xmp-recovery-package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageRecovery, withIntermediateDirectories: true)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umis-recovery-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent(".umis-xmp-recovery-outside"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("outside-link"),
            withDestinationURL: external
        )
        let rootDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(rootDescriptor, 0)
        defer { if rootDescriptor >= 0 { Darwin.close(rootDescriptor) } }

        let result = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: rootDescriptor,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(
            result.records.first?.recoveryDirectoryRelativePath,
            "day-01/camera-a/.umis-xmp-recovery-broken-orphan"
        )
        XCTAssertEqual(result.records.first?.kind, .unknown)
        XCTAssertFalse(result.records.first?.manifestIsValid == true)
        XCTAssertTrue(result.records.first?.warning.contains("Never delete") == true)
    }

    func testRecoveryInspectorDirectoryLimitIsBoundedAndClosesTraversalDescriptors() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        for index in 0 ..< 64 {
            try FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent("folder-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        let rootDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(rootDescriptor, 0)
        defer { if rootDescriptor >= 0 { Darwin.close(rootDescriptor) } }
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let result = try MetadataRecoveryInspector(maximumDirectories: 4).scanTree(
            rootFileDescriptor: rootDescriptor,
            displayRootURL: fixture.root
        )
        XCTAssertTrue(result.wasTruncated)
        let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(descriptorsAfter, descriptorsBefore + 2)
    }

    func testFinderColorLabelRoundTripsThroughPublicResourceValues() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let service = FinderColorLabelService()

        XCTAssertEqual(try service.readLabelNumber(at: fixture.media), 0)
        try service.writeLabelNumber(6, at: fixture.media)
        XCTAssertEqual(try service.readLabelNumber(at: fixture.media), 6)
        try service.writeLabelNumber(0, at: fixture.media)
        XCTAssertEqual(try service.readLabelNumber(at: fixture.media), 0)
    }

    func testFinderColorLabelPreservesExistingNamedTagsAndFileContents() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let originalMedia = try Data(contentsOf: fixture.media)
        let namedTags = try PropertyListSerialization.data(
            fromPropertyList: ["Project Alpha\n0", "Needs review\n0"],
            format: .binary,
            options: 0
        )
        try setRawXattr(
            name: "com.apple.metadata:_kMDItemUserTags",
            data: namedTags,
            at: fixture.media
        )

        try FinderColorLabelService().writeLabelNumber(4, at: fixture.media)

        XCTAssertEqual(try Data(contentsOf: fixture.media), originalMedia)
        XCTAssertEqual(
            try rawXattr(name: "com.apple.metadata:_kMDItemUserTags", at: fixture.media),
            namedTags
        )
        XCTAssertEqual(
            try fixture.media.resourceValues(forKeys: [.tagNamesKey]).tagNames,
            ["Project Alpha", "Needs review"]
        )
    }

    func testFinderColorLabelRejectsInvalidNumberAndSymbolicLink() throws {
        let fixture = try MetadataFixture()
        defer { fixture.cleanup() }
        let service = FinderColorLabelService()

        XCTAssertThrowsError(try service.writeLabelNumber(-1, at: fixture.media)) {
            XCTAssertEqual($0 as? AssetMetadataError, .invalidFinderLabelNumber(-1))
        }
        XCTAssertThrowsError(try service.writeLabelNumber(8, at: fixture.media)) {
            XCTAssertEqual($0 as? AssetMetadataError, .invalidFinderLabelNumber(8))
        }
        XCTAssertEqual(try service.readLabelNumber(at: fixture.media), 0)

        let symlink = fixture.root.appendingPathComponent("linked.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.media)
        XCTAssertThrowsError(try service.writeLabelNumber(3, at: symlink)) {
            XCTAssertEqual($0 as? UMISCoreError, .symbolicLinkRejected(symlink.path))
        }
        XCTAssertEqual(try service.readLabelNumber(at: fixture.media), 0)
    }
}

private struct MetadataFixture {
    let root: URL
    let media: URL
    let replacingSidecar: URL
    let appendingSidecar: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-asset-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        media = root.appendingPathComponent("A001.MOV")
        replacingSidecar = root.appendingPathComponent("A001.xmp")
        appendingSidecar = root.appendingPathComponent("A001.MOV.xmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture-media".utf8).write(to: media)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func validXMP(rating: String) -> String {
    """
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:xmp="http://ns.adobe.com/xap/1.0/">
      <rdf:Description rdf:about="" xmp:Rating="\(rating)"/>
    </rdf:RDF>
    """
}

private func setRawXattr(name: String, data: Data, at url: URL) throws {
    let result: Int32 = data.withUnsafeBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
    }
    guard result == 0 else {
        throw UMISCoreError.posix(operation: "test setxattr", code: errno, path: url.path)
    }
}

private func rawXattr(name: String, at url: URL) throws -> Data {
    let size: Int = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return Darwin.getxattr(path, name, nil, 0, 0, 0)
    }
    guard size >= 0 else {
        throw UMISCoreError.posix(operation: "test getxattr size", code: errno, path: url.path)
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let received: Int = bytes.withUnsafeMutableBytes { buffer in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.getxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
    }
    guard received >= 0 else {
        throw UMISCoreError.posix(operation: "test getxattr", code: errno, path: url.path)
    }
    return Data(bytes.prefix(received))
}
