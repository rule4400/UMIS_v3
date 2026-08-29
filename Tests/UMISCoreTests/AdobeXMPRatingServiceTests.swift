import Darwin
import Foundation
import ImageIO
import XCTest
@testable import UMISCore

final class AdobeXMPRatingServiceTests: XCTestCase {
    private let mutationContext = AdobeXMPRatingMutationContext(hasLatestVerifiedReceipt: false)

    func testCoreVolumePolicyRejectsNASExternalEjectableRemovableAndReadOnlyEvidence() throws {
        XCTAssertNoThrow(
            try AdobeXMPRatingService.validateVolumeSafetyFlags(
                isLocal: true,
                isInternal: true,
                isEjectable: false,
                isRemovable: false,
                isReadOnly: false,
                path: "/internal"
            )
        )
        for evidence in [
            (false, true, false, false, false), // NAS/non-local
            (true, false, false, false, false), // external
            (true, true, true, false, false), // ejectable
            (true, true, false, true, false), // removable
            (true, true, false, false, true), // read-only
        ] {
            XCTAssertThrowsError(
                try AdobeXMPRatingService.validateVolumeSafetyFlags(
                    isLocal: evidence.0,
                    isInternal: evidence.1,
                    isEjectable: evidence.2,
                    isRemovable: evidence.3,
                    isReadOnly: evidence.4,
                    path: "/unsafe"
                )
            )
        }
    }

    func testPublicFormatSupportIsTheSingleReviewAndRouteInventory() {
        let support = AdobeXMPRatingService.formatSupport
        XCTAssertEqual(
            support.embeddedStillExtensions,
            ["jpg", "jpeg", "tif", "tiff", "dng", "psd", "png", "gif"]
        )
        XCTAssertEqual(support.embeddedDynamicExtensions, ["mov", "mp4", "m4v", "m4a"])
        XCTAssertEqual(
            support.manufacturerRawExtensions,
            [
                "3fr", "arw", "cr2", "cr3", "crw", "dcr", "erf", "iiq", "k25", "kdc",
                "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2",
                "rwl", "sr2", "srf", "srw", "x3f",
            ]
        )
        XCTAssertEqual(support.knownFallbackSidecarExtensions, ["heic", "heif", "mxf", "r3d"])
        XCTAssertEqual(
            support.knownReviewExtensions,
            support.embeddedStillExtensions
                .union(support.embeddedDynamicExtensions)
                .union(support.manufacturerRawExtensions)
                .union(support.knownFallbackSidecarExtensions)
        )

        XCTAssertEqual(support.routeCandidate(forPathExtension: ".PSD"), .embeddedStillCandidate)
        XCTAssertEqual(support.routeCandidate(forPathExtension: "M4V"), .embeddedDynamicCandidate)
        XCTAssertEqual(support.routeCandidate(forPathExtension: ".Cr3"), .manufacturerRawSidecar)
        XCTAssertEqual(support.routeCandidate(forPathExtension: "HEIC"), .fallbackSidecar)
        XCTAssertEqual(support.routeCandidate(forPathExtension: "future-format"), .fallbackSidecar)
        XCTAssertTrue(support.isKnownReviewExtension(".R3D"))
        XCTAssertFalse(support.isKnownReviewExtension("future-format"))
    }

    func testStillSmartHandlersRoundTripEmbeddedRatingAndRemainDecodable() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService()
        let cases: [(fixture: String, destination: String)] = [
            ("BlueSquare.jpg", "still.jpg"),
            ("BlueSquare.tif", "still.tif"),
            ("BlueSquare.tif", "still.dng"),
            ("BlueSquare.psd", "still.psd"),
            ("BlueSquare.png", "still.png"),
        ]

        for testCase in cases {
            let media = try fixture.copyBundledFixture(
                named: testCase.fixture,
                destinationName: testCase.destination
            )
            let before = try FileFingerprint.capture(at: media)

            let capability = try service.probe(mediaURL: media, expectedFingerprint: before)
            XCTAssertEqual(capability.storage, .embedded, testCase.destination)
            XCTAssertTrue(capability.usesAdobeSmartHandler, testCase.destination)
            XCTAssertTrue(capability.supportsSafeUpdate, testCase.destination)

            let written = try service.writeRating(
                .fourStars,
                mediaURL: media,
                expectedFingerprint: before,
                context: mutationContext
            )
            XCTAssertEqual(written.storage, .embedded, testCase.destination)
            XCTAssertEqual(written.rating, .fourStars, testCase.destination)
            XCTAssertNotEqual(written.fingerprintAfter, before, testCase.destination)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: media.deletingPathExtension().appendingPathExtension("xmp").path),
                testCase.destination
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: media.path + ".xmp"),
                testCase.destination
            )

            let read = try service.readRating(
                mediaURL: media,
                expectedFingerprint: written.fingerprintAfter
            )
            XCTAssertEqual(read.rating, .fourStars, testCase.destination)
            XCTAssertTrue(read.hasExplicitRating, testCase.destination)
            XCTAssertEqual(read.storage, .embedded, testCase.destination)

            let imageSource = CGImageSourceCreateWithURL(media as CFURL, nil)
            XCTAssertNotNil(imageSource, testCase.destination)
            if let imageSource {
                XCTAssertGreaterThan(CGImageSourceGetCount(imageSource), 0, testCase.destination)
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil), testCase.destination)
            }
        }
    }

    func testGIFSmartHandlerRoundTripsEmbeddedRating() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = fixture.root.appendingPathComponent("one-pixel.gif")
        try Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
            0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
            0x01, 0x00, 0x3b,
        ]).write(to: media)
        let service = makeService()
        let before = try FileFingerprint.capture(at: media)

        let capability = try service.probe(mediaURL: media, expectedFingerprint: before)
        XCTAssertEqual(capability.storage, .embedded)
        XCTAssertTrue(capability.supportsSafeUpdate)
        let written = try service.writeRating(
            .twoStars,
            mediaURL: media,
            expectedFingerprint: before,
            context: mutationContext
        )
        XCTAssertEqual(written.storage, .embedded)
        XCTAssertEqual(
            try service.readRating(mediaURL: media, expectedFingerprint: written.fingerprintAfter).rating,
            .twoStars
        )
        XCTAssertNotNil(CGImageSourceCreateWithURL(media as CFURL, nil))
    }

    func testEmbeddedMissingRatingAndExplicitZeroRemainDistinguishable() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "unrated.jpg")
        let service = makeService()
        let before = try FileFingerprint.capture(at: media)

        let missing = try service.readRating(mediaURL: media, expectedFingerprint: before)
        XCTAssertEqual(missing.rating, .unrated)
        XCTAssertFalse(missing.hasExplicitRating)

        let written = try service.writeRating(
            .unrated,
            mediaURL: media,
            expectedFingerprint: before,
            context: mutationContext
        )
        let explicitZero = try service.readRating(
            mediaURL: media,
            expectedFingerprint: written.fingerprintAfter
        )
        XCTAssertEqual(explicitZero.rating, .unrated)
        XCTAssertTrue(explicitZero.hasExplicitRating)
    }

    func testSidecarMissingRatingAndExplicitZeroRemainDistinguishable() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = fixture.root.appendingPathComponent("unrated-sidecar.unknown")
        try Data("sidecar-media".utf8).write(to: media)
        let sidecar = URL(fileURLWithPath: media.path + ".xmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let expected = try FileFingerprint.capture(at: media)
        let service = makeService()

        let missing = try service.readRating(mediaURL: media, expectedFingerprint: expected)
        XCTAssertEqual(missing.rating, .unrated)
        XCTAssertFalse(missing.hasExplicitRating)
        XCTAssertEqual(missing.storage, .compatibilityUnverifiedSidecar)

        _ = try service.writeRating(
            .unrated,
            mediaURL: media,
            expectedFingerprint: expected,
            context: mutationContext
        )
        let explicitZero = try service.readRating(mediaURL: media, expectedFingerprint: expected)
        XCTAssertEqual(explicitZero.rating, .unrated)
        XCTAssertTrue(explicitZero.hasExplicitRating)
    }

    func testQuickTimeSmartHandlerUsesEmbeddedOnlyAfterContentCapabilityProbe() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService(maximumEmbeddedDynamicMediaBytes: Int64.max)

        for pathExtension in ["mov", "mp4", "m4v", "m4a"] {
            let media = try fixture.copyBundledFixture(
                named: "BlueSquare.mov",
                destinationName: "clip.\(pathExtension)"
            )
            let beforeBytes = try Data(contentsOf: media)
            let before = try FileFingerprint.capture(at: media)
            let capability = try service.probe(mediaURL: media, expectedFingerprint: before)
            let written = try service.writeRating(
                .threeStars,
                mediaURL: media,
                expectedFingerprint: before,
                context: mutationContext
            )
            if pathExtension == "mov" {
                XCTAssertEqual(capability.storage, .embedded)
                XCTAssertTrue(capability.usesAdobeSmartHandler)
                XCTAssertTrue(capability.supportsSafeUpdate)
                XCTAssertEqual(written.storage, .embedded)
                XCTAssertNotEqual(try Data(contentsOf: media), beforeBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: media.path + ".xmp"))
            } else {
                // These fixtures intentionally contain MOV bytes under another extension. A file
                // extension is not evidence of MP4/M4V/M4A handler support: the descriptor-bound
                // capability probe must fail closed to a collision-free appended sidecar.
                XCTAssertEqual(capability.storage, .compatibilityUnverifiedSidecar, pathExtension)
                XCTAssertFalse(capability.usesAdobeSmartHandler, pathExtension)
                XCTAssertEqual(written.storage, .compatibilityUnverifiedSidecar, pathExtension)
                XCTAssertEqual(try Data(contentsOf: media), beforeBytes, pathExtension)
                XCTAssertTrue(FileManager.default.fileExists(atPath: media.path + ".xmp"), pathExtension)
            }
            XCTAssertEqual(
                try service.readRating(mediaURL: media, expectedFingerprint: written.fingerprintAfter).rating,
                .threeStars,
                pathExtension
            )
        }
    }

    func testEmbeddedUpdatePreservesUnrelatedXMPPermissionsAndExtendedAttributes() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "metadata.jpg")
        XCTAssertEqual(Darwin.chmod(media.path, 0o640), 0)
        let xattrName = "com.rinkan.umis.xmp-bridge-test"
        let xattrValue = Data("must-survive-safe-update".utf8)
        try setXMPTestXattr(name: xattrName, data: xattrValue, at: media)
        let before = try FileFingerprint.capture(at: media)

        let result = try makeService().writeRating(
            .fiveStars,
            mediaURL: media,
            expectedFingerprint: before,
            context: mutationContext
        )

        XCTAssertEqual(try readXMPTestXattr(name: xattrName, at: media), xattrValue)
        var status = stat()
        XCTAssertEqual(Darwin.lstat(media.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o640)
        let updated = try Data(contentsOf: media)
        XCTAssertNotNil(updated.range(of: Data("Blue Square Test File - .jpg".utf8)))
        XCTAssertEqual(
            try makeService().readRating(mediaURL: media, expectedFingerprint: result.fingerprintAfter).rating,
            .fiveStars
        )
    }

    func testLargeOrUnqualifiedDynamicMediaUsesDistinctAppendedSidecar() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(named: "BlueSquare.mov", destinationName: "clip.mov")
        let originalBytes = try Data(contentsOf: media)
        let fingerprint = try FileFingerprint.capture(at: media)
        let service = makeService(maximumEmbeddedDynamicMediaBytes: 0)

        let written = try service.writeRating(
            .rejected,
            mediaURL: media,
            expectedFingerprint: fingerprint,
            context: mutationContext
        )

        XCTAssertEqual(written.storage, .compatibilityUnverifiedSidecar)
        XCTAssertNotNil(written.compatibilityWarning)
        XCTAssertEqual(written.fingerprintAfter, fingerprint)
        XCTAssertEqual(try Data(contentsOf: media), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path + ".xmp"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: media.deletingPathExtension().appendingPathExtension("xmp").path)
        )
        let read = try service.readRating(mediaURL: media, expectedFingerprint: fingerprint)
        XCTAssertEqual(read.rating, .rejected)
        XCTAssertEqual(read.storage, .compatibilityUnverifiedSidecar)
    }

    func testSameStemCameraRAWAndJPEGNeverShareRatingStorage() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let raw = fixture.root.appendingPathComponent("A001.CR3")
        try Data("synthetic-camera-raw".utf8).write(to: raw)
        let jpeg = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "A001.JPG")
        let rawFingerprint = try FileFingerprint.capture(at: raw)
        let jpegFingerprint = try FileFingerprint.capture(at: jpeg)
        let service = makeService()

        let rawWrite = try service.writeRating(
            .twoStars,
            mediaURL: raw,
            expectedFingerprint: rawFingerprint,
            context: mutationContext
        )
        XCTAssertEqual(rawWrite.storage, .cameraRawSidecar)
        let rawSidecar = fixture.root.appendingPathComponent("A001.xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawSidecar.path))
        let rawSidecarBeforeJPEG = try Data(contentsOf: rawSidecar)

        let jpegWrite = try service.writeRating(
            .fiveStars,
            mediaURL: jpeg,
            expectedFingerprint: jpegFingerprint,
            context: mutationContext
        )

        XCTAssertEqual(jpegWrite.storage, .embedded)
        XCTAssertEqual(try Data(contentsOf: rawSidecar), rawSidecarBeforeJPEG)
        XCTAssertEqual(
            try service.readRating(mediaURL: raw, expectedFingerprint: rawFingerprint).rating,
            .twoStars
        )
        XCTAssertEqual(
            try service.readRating(mediaURL: jpeg, expectedFingerprint: jpegWrite.fingerprintAfter).rating,
            .fiveStars
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path + ".xmp"))
    }

    func testSameStemMultipleCameraRAWFilesFailClosedInsteadOfSharingSidecar() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let cr3 = fixture.root.appendingPathComponent("A002.CR3")
        let nef = fixture.root.appendingPathComponent("A002.NEF")
        try Data("synthetic-cr3".utf8).write(to: cr3)
        try Data("synthetic-nef".utf8).write(to: nef)
        let service = makeService()

        for media in [cr3, nef] {
            let fingerprint = try FileFingerprint.capture(at: media)
            XCTAssertThrowsError(
                try service.readRating(mediaURL: media, expectedFingerprint: fingerprint)
            ) { error in
                guard case .ambiguousCameraRawSidecar = error as? AdobeXMPRatingServiceError else {
                    return XCTFail("Expected ambiguous Camera RAW sidecar error, got \(error)")
                }
            }
            XCTAssertThrowsError(
                try service.writeRating(
                    .fourStars,
                    mediaURL: media,
                    expectedFingerprint: fingerprint,
                    context: mutationContext
                )
            ) { error in
                guard case .ambiguousCameraRawSidecar = error as? AdobeXMPRatingServiceError else {
                    return XCTFail("Expected ambiguous Camera RAW sidecar error, got \(error)")
                }
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("A002.xmp").path)
        )
    }

    func testCameraRAWAmbiguityProbeCostIsBoundedIndependentOfSiblingCount() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let raw = fixture.root.appendingPathComponent("bounded.CR3")
        try Data("bounded-raw".utf8).write(to: raw)
        for index in 0 ..< 2_048 {
            try Data().write(to: fixture.root.appendingPathComponent("unrelated-\(index).dat"))
        }
        let expected = try FileFingerprint.capture(at: raw)
        let parent = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let service = makeService()
        AdobeXMPRatingService.resetRawSiblingCandidateLookupCountForTesting()

        for _ in 0 ..< 4 {
            let plan = try service.coordinationPlan(
                parentFileDescriptor: parent,
                mediaLeafName: raw.lastPathComponent,
                displayURL: raw,
                expectedFingerprint: expected,
                forWriting: false
            )
            XCTAssertEqual(plan.storage, .cameraRawSidecar)
        }
        // Supported RAW extensions are at most three ASCII characters. Four probes therefore
        // remain below 4 * extensionCount * 8 regardless of the 2,048 unrelated siblings.
        XCTAssertLessThan(
            AdobeXMPRatingService.rawSiblingCandidateLookupCountForTesting,
            4 * 64 * 8
        )
    }

    func testCameraRAWCaseSensitiveProbeEnumeratesEveryASCIIExtensionSpelling() {
        XCTAssertEqual(
            Set(AdobeXMPRatingService.asciiCaseVariants(of: "cr3")),
            Set(["cr3", "cr3".uppercased(), "Cr3", "cR3"])
        )
        XCTAssertEqual(AdobeXMPRatingService.asciiCaseVariants(of: "nef").count, 8)
        XCTAssertTrue(AdobeXMPRatingService.asciiCaseVariants(of: "nef").contains("NEF"))
    }

    func testCameraRAWCaseSensitiveVolumeRejectsUppercaseSibling() throws {
        guard let mountedRoot = ProcessInfo.processInfo.environment["UMIS_CASE_SENSITIVE_TEST_ROOT"] else {
            throw XCTSkip("Set UMIS_CASE_SENSITIVE_TEST_ROOT to a mounted case-sensitive APFS volume")
        }
        let root = URL(fileURLWithPath: mountedRoot, isDirectory: true)
            .appendingPathComponent("umis-case-sensitive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeValues = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        XCTAssertEqual(volumeValues.volumeSupportsCaseSensitiveNames, true)
        let cr3 = root.appendingPathComponent("A900.CR3")
        let nef = root.appendingPathComponent("A900.NEF")
        try Data("case-sensitive-cr3".utf8).write(to: cr3)
        try Data("case-sensitive-nef".utf8).write(to: nef)
        let service = makeService()

        for media in [cr3, nef] {
            XCTAssertThrowsError(
                try service.readRating(
                    mediaURL: media,
                    expectedFingerprint: FileFingerprint.capture(at: media)
                )
            ) { error in
                guard case .ambiguousCameraRawSidecar = error as? AdobeXMPRatingServiceError else {
                    return XCTFail("Expected case-sensitive RAW collision, got \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A900.xmp").path))
    }

    func testHEICMXFR3DAndUnknownFallbackNamesCannotCollideWithCameraRAW() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService()
        let testCases: [(name: String, rating: AdobeRating)] = [
            ("A001.heic", .oneStar),
            ("A001.mxf", .twoStars),
            ("A001.r3d", .threeStars),
            ("A001.vendorblob", .fourStars),
        ]

        for testCase in testCases {
            let media = fixture.root.appendingPathComponent(testCase.name)
            try Data("fallback-\(testCase.name)".utf8).write(to: media)
            let fingerprint = try FileFingerprint.capture(at: media)
            let written = try service.writeRating(
                testCase.rating,
                mediaURL: media,
                expectedFingerprint: fingerprint,
                context: mutationContext
            )
            XCTAssertEqual(written.storage, .compatibilityUnverifiedSidecar, testCase.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path + ".xmp"), testCase.name)
            XCTAssertEqual(
                try service.readRating(mediaURL: media, expectedFingerprint: fingerprint).rating,
                testCase.rating,
                testCase.name
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("A001.xmp").path))
    }

    func testStaleExpectedFingerprintFailsBeforeEmbeddedOrSidecarMutation() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService()
        let jpeg = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "replaced.jpg")
        let staleJPEGFingerprint = try FileFingerprint.capture(at: jpeg)
        let replacement = try fixture.copyBundledFixture(named: "BlueSquare.png", destinationName: "replacement.tmp")
        _ = try FileManager.default.replaceItemAt(jpeg, withItemAt: replacement)
        let replacementBytes = try Data(contentsOf: jpeg)

        XCTAssertThrowsError(
            try service.writeRating(
                .fiveStars,
                mediaURL: jpeg,
                expectedFingerprint: staleJPEGFingerprint,
                context: mutationContext
            )
        )
        XCTAssertEqual(try Data(contentsOf: jpeg), replacementBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path + ".xmp"))

        let unknown = fixture.root.appendingPathComponent("replaced.unknown")
        try Data("first".utf8).write(to: unknown)
        let staleUnknownFingerprint = try FileFingerprint.capture(at: unknown)
        try Data("second-and-different".utf8).write(to: unknown, options: .atomic)
        let currentUnknownBytes = try Data(contentsOf: unknown)
        XCTAssertThrowsError(
            try service.writeRating(
                .oneStar,
                mediaURL: unknown,
                expectedFingerprint: staleUnknownFingerprint,
                context: mutationContext
            )
        )
        XCTAssertEqual(try Data(contentsOf: unknown), currentUnknownBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path + ".xmp"))
    }

    func testSymlinkAndHardLinkedEmbeddedTargetsAreRejectedWithoutMutation() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService()
        let target = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "target.jpg")
        let original = try Data(contentsOf: target)
        let symlink = fixture.root.appendingPathComponent("symlink.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let symlinkFingerprint = try FileFingerprint.capture(at: symlink)

        XCTAssertThrowsError(
            try service.writeRating(
                .oneStar,
                mediaURL: symlink,
                expectedFingerprint: symlinkFingerprint,
                context: mutationContext
            )
        ) { error in
            XCTAssertEqual(error as? UMISCoreError, .symbolicLinkRejected(symlink.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)

        let hardlink = fixture.root.appendingPathComponent("hardlink.jpg")
        try FileManager.default.linkItem(at: target, to: hardlink)
        let hardlinkFingerprint = try FileFingerprint.capture(at: hardlink)
        XCTAssertThrowsError(
            try service.writeRating(
                .twoStars,
                mediaURL: hardlink,
                expectedFingerprint: hardlinkFingerprint,
                context: mutationContext
            )
        )
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hardlink.path + ".xmp"))
    }

    func testHardLinkedSidecarTargetsAndExistingSidecarsFailClosedWithoutMutation() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let service = makeService()

        for pathExtension in ["CR3", "unknown"] {
            let source = fixture.root.appendingPathComponent("source-\(pathExtension).\(pathExtension)")
            let hardlink = fixture.root.appendingPathComponent("hardlink-\(pathExtension).\(pathExtension)")
            try Data("hard-linked-\(pathExtension)-media".utf8).write(to: source)
            try FileManager.default.linkItem(at: source, to: hardlink)
            let expected = try FileFingerprint.capture(at: hardlink)
            let sidecar = pathExtension == "CR3"
                ? hardlink.deletingPathExtension().appendingPathExtension("xmp")
                : URL(fileURLWithPath: hardlink.path + ".xmp")

            XCTAssertThrowsError(
                try service.writeRating(
                    .threeStars,
                    mediaURL: hardlink,
                    expectedFingerprint: expected,
                    context: mutationContext
                )
            ) { error in
                XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(hardlink.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertEqual(try Data(contentsOf: source), Data("hard-linked-\(pathExtension)-media".utf8))
        }

        let media = fixture.root.appendingPathComponent("existing-sidecar.unknown")
        try Data("ordinary-media".utf8).write(to: media)
        let expected = try FileFingerprint.capture(at: media)
        _ = try service.writeRating(
            .oneStar,
            mediaURL: media,
            expectedFingerprint: expected,
            context: mutationContext
        )
        let sidecar = URL(fileURLWithPath: media.path + ".xmp")
        let sidecarAlias = fixture.root.appendingPathComponent("sidecar-alias.xmp")
        try FileManager.default.linkItem(at: sidecar, to: sidecarAlias)
        let mediaBefore = try Data(contentsOf: media)
        let sidecarBefore = try Data(contentsOf: sidecar)

        XCTAssertThrowsError(
            try service.readRating(mediaURL: media, expectedFingerprint: expected)
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(sidecar.path))
        }
        XCTAssertThrowsError(
            try service.writeRating(
                .fiveStars,
                mediaURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(sidecar.path))
        }
        XCTAssertEqual(try Data(contentsOf: media), mediaBefore)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBefore)
        XCTAssertEqual(try Data(contentsOf: sidecarAlias), sidecarBefore)
    }

    func testVerifiedReceiptBlocksEveryStorageRouteBeforeMutation() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let blocked = AdobeXMPRatingMutationContext(hasLatestVerifiedReceipt: true)
        let service = makeService()
        let jpeg = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "blocked.jpg")
        let beforeJPEG = try Data(contentsOf: jpeg)
        let jpegFingerprint = try FileFingerprint.capture(at: jpeg)

        XCTAssertThrowsError(
            try service.writeRating(
                .threeStars,
                mediaURL: jpeg,
                expectedFingerprint: jpegFingerprint,
                context: blocked
            )
        ) { error in
            XCTAssertEqual(error as? AdobeXMPRatingServiceError, .pendingVerifiedReceipt)
        }
        XCTAssertEqual(try Data(contentsOf: jpeg), beforeJPEG)

        let raw = fixture.root.appendingPathComponent("blocked.CR3")
        try Data("blocked-raw".utf8).write(to: raw)
        let rawFingerprint = try FileFingerprint.capture(at: raw)
        XCTAssertThrowsError(
            try service.writeRating(
                .threeStars,
                mediaURL: raw,
                expectedFingerprint: rawFingerprint,
                context: blocked
            )
        ) { error in
            XCTAssertEqual(error as? AdobeXMPRatingServiceError, .pendingVerifiedReceipt)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("blocked.xmp").path))
    }

    func testPostFingerprintIsRequiredAndSupportsSequentialEmbeddedWrites() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "sequential.jpg")
        let service = makeService()
        let scanned = try FileFingerprint.capture(at: media)
        let first = try service.writeRating(
            .oneStar,
            mediaURL: media,
            expectedFingerprint: scanned,
            context: mutationContext
        )

        XCTAssertThrowsError(
            try service.writeRating(
                .twoStars,
                mediaURL: media,
                expectedFingerprint: scanned,
                context: mutationContext
            )
        )
        let second = try service.writeRating(
            .twoStars,
            mediaURL: media,
            expectedFingerprint: first.fingerprintAfter,
            context: mutationContext
        )
        XCTAssertEqual(
            try service.readRating(mediaURL: media, expectedFingerprint: second.fingerprintAfter).rating,
            .twoStars
        )
    }

    func testHeldDirectoryDescriptorCapabilitySupportsEmbeddedAndSidecarWrites() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let jpeg = try fixture.copyBundledFixture(
            named: "BlueSquare.jpg",
            destinationName: "capability.jpg"
        )
        let unknown = fixture.root.appendingPathComponent("capability.unknown")
        try Data("descriptor-capability-sidecar-media".utf8).write(to: unknown)
        let directoryDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) } }
        let service = makeService()

        let jpegBefore = try FileFingerprint.capture(at: jpeg)
        let initiallyUnrated = try service.readRating(
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: jpegBefore
        )
        XCTAssertEqual(initiallyUnrated.rating, .unrated)
        XCTAssertFalse(initiallyUnrated.hasExplicitRating)
        let jpegWrite = try service.writeRating(
            .threeStars,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: jpegBefore,
            context: mutationContext
        )
        XCTAssertEqual(jpegWrite.storage, .embedded)
        XCTAssertEqual(
            try service.readRating(
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: jpeg.lastPathComponent,
                displayURL: jpeg,
                expectedFingerprint: jpegWrite.fingerprintAfter
            ).rating,
            .threeStars
        )
        XCTAssertEqual(try FileFingerprint.capture(at: jpeg), jpegWrite.fingerprintAfter)

        let explicitZeroWrite = try service.writeRating(
            .unrated,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: jpegWrite.fingerprintAfter,
            context: mutationContext
        )
        let explicitZero = try service.readRating(
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: explicitZeroWrite.fingerprintAfter
        )
        XCTAssertEqual(explicitZero.rating, .unrated)
        XCTAssertTrue(explicitZero.hasExplicitRating)

        let unknownBefore = try FileFingerprint.capture(at: unknown)
        let unknownWrite = try service.writeRating(
            .fourStars,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: unknown.lastPathComponent,
            displayURL: unknown,
            expectedFingerprint: unknownBefore,
            context: mutationContext
        )
        XCTAssertEqual(unknownWrite.storage, .compatibilityUnverifiedSidecar)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("descriptor-capability-sidecar-media".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path + ".xmp"))
        XCTAssertEqual(
            try service.readRating(
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: unknown.lastPathComponent,
                displayURL: unknown,
                expectedFingerprint: unknownBefore
            ).rating,
            .fourStars
        )
        let recoveryScan = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: directoryDescriptor,
            displayRootURL: fixture.root
        )
        XCTAssertTrue(recoveryScan.records.isEmpty)
    }

    func testDescriptorEmbeddedUpperReadbackFailureRetainsDiscoverableOriginal() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(
            named: "BlueSquare.jpg",
            destinationName: "readback-failure.jpg"
        )
        let parent = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: media)
        let service = AdobeXMPRatingService(
            configuration: AdobeXMPRatingConfiguration(
                maximumEmbeddedDynamicMediaBytes: Int64.max,
                safeUpdateReserveBytes: 0
            ),
            embeddedRecoveryTestFault: .failUpperReadback
        )

        XCTAssertThrowsError(
            try service.writeRating(
                .fourStars,
                parentFileDescriptor: parent,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            guard case let .recoveryRetained(_, leaf, originalRetained, incomplete, _) =
                error as? AdobeXMPRatingServiceError else {
                return XCTFail("Expected structured embedded recovery retention, got \(error)")
            }
            XCTAssertTrue(leaf.hasPrefix(".umis-xmp-recovery-"))
            XCTAssertEqual(originalRetained, true)
            XCTAssertTrue(incomplete)
        }

        let scan = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records.first?.kind, .embeddedXMP)
        XCTAssertEqual(scan.records.first?.targetLeaf, media.lastPathComponent)
        XCTAssertEqual(scan.records.first?.state, "awaitingUpperReadback")
        XCTAssertTrue(scan.records.first?.mayContainOriginalBackup == true)
    }

    func testDescriptorEmbeddedTargetReplacementBeforeFinalizeFailsClosedAndRetainsRecovery() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(
            named: "BlueSquare.jpg",
            destinationName: "finalize-swap.jpg"
        )
        let parent = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: media)
        let service = AdobeXMPRatingService(
            configuration: AdobeXMPRatingConfiguration(
                maximumEmbeddedDynamicMediaBytes: Int64.max,
                safeUpdateReserveBytes: 0
            ),
            embeddedRecoveryTestFault: .replaceTargetBeforeFinalization
        )

        XCTAssertThrowsError(
            try service.writeRating(
                .fiveStars,
                parentFileDescriptor: parent,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            guard case let .recoveryRetained(_, leaf, originalRetained, _, _) =
                error as? AdobeXMPRatingServiceError else {
                return XCTFail("Expected target-swap recovery retention, got \(error)")
            }
            XCTAssertTrue(leaf.hasPrefix(".umis-xmp-recovery-"))
            XCTAssertEqual(originalRetained, true)
        }
        XCTAssertEqual(
            try Data(contentsOf: media),
            Data("deterministic-concurrent-replacement".utf8)
        )
        let scan = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records.first?.kind, .embeddedXMP)
        XCTAssertNotNil(scan.records.first?.original)
    }

    func testDescriptorEmbeddedCtimeChangeBeforeFinalizeRetainsRecovery() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(
            named: "BlueSquare.jpg",
            destinationName: "finalize-ctime.jpg"
        )
        let parent = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let expected = try FileFingerprint.capture(at: media)
        let service = AdobeXMPRatingService(
            configuration: AdobeXMPRatingConfiguration(
                maximumEmbeddedDynamicMediaBytes: Int64.max,
                safeUpdateReserveBytes: 0
            ),
            embeddedRecoveryTestFault: .changeTargetMetadataBeforeFinalization
        )

        XCTAssertThrowsError(
            try service.writeRating(
                .twoStars,
                parentFileDescriptor: parent,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            guard case let .recoveryRetained(_, _, originalRetained, _, _) =
                error as? AdobeXMPRatingServiceError else {
                return XCTFail("Expected ctime recovery retention, got \(error)")
            }
            XCTAssertEqual(originalRetained, true)
        }
        let scan = try MetadataRecoveryInspector().scanTree(
            rootFileDescriptor: parent,
            displayRootURL: fixture.root
        )
        XCTAssertEqual(scan.records.count, 1)
        XCTAssertEqual(scan.records.first?.kind, .embeddedXMP)
        XCTAssertTrue(scan.records.first?.mayContainOriginalBackup == true)
    }

    func testCapabilityCoordinationPlanMatchesEmbeddedAndStrictSidecarRoutes() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let jpeg = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "plan.jpg")
        let unknown = fixture.root.appendingPathComponent("plan.media")
        let raw = fixture.root.appendingPathComponent("camera.CR3")
        try Data("unknown".utf8).write(to: unknown)
        try Data("raw".utf8).write(to: raw)
        let parent = Darwin.open(fixture.root.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { if parent >= 0 { Darwin.close(parent) } }
        let service = makeService()

        let embedded = try service.coordinationPlan(
            parentFileDescriptor: parent,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: FileFingerprint.capture(at: jpeg),
            forWriting: true
        )
        XCTAssertEqual(embedded.storage, .embedded)
        XCTAssertEqual(embedded.intents, [AdobeXMPCoordinationIntent(url: jpeg, access: .write)])

        let fallback = try service.coordinationPlan(
            parentFileDescriptor: parent,
            mediaLeafName: unknown.lastPathComponent,
            displayURL: unknown,
            expectedFingerprint: FileFingerprint.capture(at: unknown),
            forWriting: true
        )
        XCTAssertEqual(fallback.storage, .compatibilityUnverifiedSidecar)
        XCTAssertEqual(fallback.intents.map(\.access), [.read, .write])
        XCTAssertEqual(fallback.intents.last?.url.path, unknown.path + ".xmp")

        let cameraRaw = try service.coordinationPlan(
            parentFileDescriptor: parent,
            mediaLeafName: raw.lastPathComponent,
            displayURL: raw,
            expectedFingerprint: FileFingerprint.capture(at: raw),
            forWriting: true
        )
        XCTAssertEqual(cameraRaw.storage, .cameraRawSidecar)
        XCTAssertEqual(cameraRaw.intents.map(\.access), [.read, .write])
        XCTAssertEqual(cameraRaw.intents.last?.url.lastPathComponent, "camera.xmp")
    }

    func testDescriptorCapabilityRejectsReplacedLeafBeforeMutation() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let media = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "swap.jpg")
        let expected = try FileFingerprint.capture(at: media)
        let directoryDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) } }

        let replacement = Data("replacement-media-must-remain-unchanged".utf8)
        try replacement.write(to: media, options: .atomic)
        XCTAssertThrowsError(
            try makeService().writeRating(
                .fiveStars,
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .concurrentModification(media.path))
        }
        XCTAssertEqual(try Data(contentsOf: media), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path + ".xmp"))
    }

    func testDescriptorCapabilityPreservesEmbeddedAndSidecarFilesystemMetadata() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let jpeg = try fixture.copyBundledFixture(named: "BlueSquare.jpg", destinationName: "preserve.jpg")
        let unknown = fixture.root.appendingPathComponent("preserve.unknown")
        try Data("sidecar-media-content".utf8).write(to: unknown)
        let directoryDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) } }
        let service = makeService()

        let embeddedXattr = Data("keep-embedded-xattr".utf8)
        try setXMPTestXattr(name: "com.example.umis.capability", data: embeddedXattr, at: jpeg)
        XCTAssertEqual(Darwin.chmod(jpeg.path, 0o640), 0)
        let jpegExpected = try FileFingerprint.capture(at: jpeg)
        let jpegWrite = try service.writeRating(
            .fourStars,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: jpeg.lastPathComponent,
            displayURL: jpeg,
            expectedFingerprint: jpegExpected,
            context: mutationContext
        )
        XCTAssertEqual(try readXMPTestXattr(name: "com.example.umis.capability", at: jpeg), embeddedXattr)
        var jpegStatus = stat()
        XCTAssertEqual(
            jpeg.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &jpegStatus)
            },
            0
        )
        XCTAssertEqual(jpegStatus.st_mode & 0o777, 0o640)
        XCTAssertEqual(
            try service.readRating(
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: jpeg.lastPathComponent,
                displayURL: jpeg,
                expectedFingerprint: jpegWrite.fingerprintAfter
            ).rating,
            .fourStars
        )

        let unknownExpected = try FileFingerprint.capture(at: unknown)
        _ = try service.writeRating(
            .oneStar,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: unknown.lastPathComponent,
            displayURL: unknown,
            expectedFingerprint: unknownExpected,
            context: mutationContext
        )
        let sidecar = URL(fileURLWithPath: unknown.path + ".xmp")
        let sidecarXattr = Data("keep-sidecar-xattr".utf8)
        try setXMPTestXattr(name: "com.example.umis.sidecar-capability", data: sidecarXattr, at: sidecar)
        XCTAssertEqual(Darwin.chmod(sidecar.path, 0o640), 0)
        _ = try service.writeRating(
            .fiveStars,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: unknown.lastPathComponent,
            displayURL: unknown,
            expectedFingerprint: unknownExpected,
            context: mutationContext
        )
        XCTAssertEqual(
            try readXMPTestXattr(name: "com.example.umis.sidecar-capability", at: sidecar),
            sidecarXattr
        )
        var sidecarStatus = stat()
        XCTAssertEqual(
            sidecar.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &sidecarStatus)
            },
            0
        )
        XCTAssertEqual(sidecarStatus.st_mode & 0o777, 0o640)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                .contains(where: { $0.hasPrefix(".umis-xmp-") })
        )
    }

    func testDescriptorCapabilityRejectsHardLinkedMediaAndSidecar() throws {
        let fixture = try AdobeXMPFixture()
        defer { fixture.cleanup() }
        let directoryDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) } }
        let service = makeService()

        let source = fixture.root.appendingPathComponent("hardlinked-source.unknown")
        let media = fixture.root.appendingPathComponent("hardlinked.unknown")
        try Data("hardlinked-capability-media".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: media)
        let expected = try FileFingerprint.capture(at: media)
        XCTAssertThrowsError(
            try service.writeRating(
                .threeStars,
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: media.lastPathComponent,
                displayURL: media,
                expectedFingerprint: expected,
                context: mutationContext
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(media.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path + ".xmp"))

        let ordinary = fixture.root.appendingPathComponent("ordinary.unknown")
        try Data("ordinary-capability-media".utf8).write(to: ordinary)
        let ordinaryExpected = try FileFingerprint.capture(at: ordinary)
        _ = try service.writeRating(
            .oneStar,
            parentFileDescriptor: directoryDescriptor,
            mediaLeafName: ordinary.lastPathComponent,
            displayURL: ordinary,
            expectedFingerprint: ordinaryExpected,
            context: mutationContext
        )
        let sidecar = URL(fileURLWithPath: ordinary.path + ".xmp")
        let alias = fixture.root.appendingPathComponent("ordinary-alias.xmp")
        try FileManager.default.linkItem(at: sidecar, to: alias)
        let before = try Data(contentsOf: sidecar)
        XCTAssertThrowsError(
            try service.writeRating(
                .fiveStars,
                parentFileDescriptor: directoryDescriptor,
                mediaLeafName: ordinary.lastPathComponent,
                displayURL: ordinary,
                expectedFingerprint: ordinaryExpected,
                context: mutationContext
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(sidecar.path))
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
        XCTAssertEqual(try Data(contentsOf: alias), before)
    }

    private func makeService(
        maximumEmbeddedDynamicMediaBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    ) -> AdobeXMPRatingService {
        AdobeXMPRatingService(
            configuration: AdobeXMPRatingConfiguration(
                maximumEmbeddedDynamicMediaBytes: maximumEmbeddedDynamicMediaBytes,
                safeUpdateReserveBytes: 0
            )
        )
    }
}

private struct AdobeXMPFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-adobe-xmp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func copyBundledFixture(named name: String, destinationName: String) throws -> URL {
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                withExtension: URL(fileURLWithPath: name).pathExtension,
                subdirectory: "Fixtures/AdobeXMP"
            )
        )
        let destination = root.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

private func setXMPTestXattr(name: String, data: Data, at url: URL) throws {
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

private func readXMPTestXattr(name: String, at url: URL) throws -> Data {
    let count: Int = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return Darwin.getxattr(path, name, nil, 0, 0, 0)
    }
    guard count >= 0 else {
        throw UMISCoreError.posix(operation: "test getxattr size", code: errno, path: url.path)
    }
    var bytes = [UInt8](repeating: 0, count: count)
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
