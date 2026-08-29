import Darwin
import Foundation
import XCTest
@testable import UMISCore

final class MetadataIdentityBindingTests: XCTestCase {
    func testFinderLabelDescriptorWriteBindsToHeldInodeAndLeavesDescriptorOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-finder-descriptor-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("held.mov")
        try Data("descriptor-bound-review-media".utf8).write(to: media)
        let expected = try FileFingerprint.capture(at: media)
        let descriptor = Darwin.open(media.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        let namedTags = try PropertyListSerialization.data(
            fromPropertyList: ["Keep Named Tag\n6"],
            format: .binary,
            options: 0
        )
        try setMetadataIdentityXattr(
            name: "com.apple.metadata:_kMDItemUserTags",
            data: namedTags,
            at: media
        )

        try FinderColorLabelService().writeLabelNumber(
            5,
            atFileDescriptor: descriptor,
            displayURL: media,
            expectedFingerprint: expected
        )

        XCTAssertEqual(try media.resourceValues(forKeys: [.labelNumberKey]).labelNumber, 5)
        XCTAssertEqual(
            try FinderColorLabelService().readLabelNumber(
                atFileDescriptor: descriptor,
                displayURL: media,
                expectedFingerprint: expected
            ),
            5
        )
        XCTAssertEqual(
            try readMetadataIdentityXattr(
                name: "com.apple.metadata:_kMDItemUserTags",
                at: media
            ),
            namedTags
        )
        var status = stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &status), 0, "the service must not close the borrowed descriptor")
        XCTAssertEqual(try FileFingerprint.capture(at: media), expected)
    }

    func testFinderLabelDescriptorWriteRejectsStaleFingerprintAndHardLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-finder-descriptor-reject-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("original.mov")
        try Data("original-descriptor-media".utf8).write(to: media)
        let stale = try FileFingerprint.capture(at: media)
        try Data("replacement-descriptor-media-with-another-size".utf8).write(to: media, options: .atomic)
        let descriptor = Darwin.open(media.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        XCTAssertThrowsError(
            try FinderColorLabelService().writeLabelNumber(
                2,
                atFileDescriptor: descriptor,
                displayURL: media,
                expectedFingerprint: stale
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .concurrentModification(media.path))
        }

        let hardlink = root.appendingPathComponent("alias.mov")
        try FileManager.default.linkItem(at: media, to: hardlink)
        let current = try FileFingerprint.capture(at: media)
        XCTAssertThrowsError(
            try FinderColorLabelService().writeLabelNumber(
                2,
                atFileDescriptor: descriptor,
                displayURL: media,
                expectedFingerprint: current
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(media.path))
        }
        XCTAssertEqual(try media.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0, 0)
    }

    func testFinderLabelDescriptorRoundTripsEveryColorAndHandlesMissingOrShortFinderInfo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-finder-all-labels-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("labels.mov")
        try Data("all-finder-label-values".utf8).write(to: media)
        let expected = try FileFingerprint.capture(at: media)
        let descriptor = Darwin.open(media.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        let service = FinderColorLabelService()

        XCTAssertEqual(
            try service.readLabelNumber(
                atFileDescriptor: descriptor,
                displayURL: media,
                expectedFingerprint: expected
            ),
            0,
            "a missing FinderInfo xattr means no color label"
        )
        var originalFinderInfo = [UInt8](repeating: 0, count: 32)
        // Seed non-label FinderInfo data, including other flag bits in bytes 8...9. Production
        // descriptor writes must preserve it bit-for-bit except for mask 0x000E.
        originalFinderInfo.replaceSubrange(0 ..< 8, with: Array("TEXTUMIS".utf8))
        originalFinderInfo[9] = 0x01
        try setMetadataIdentityXattr(
            name: "com.apple.FinderInfo",
            data: Data(originalFinderInfo),
            at: media
        )
        for label in 0 ... 7 {
            try service.writeLabelNumber(
                label,
                atFileDescriptor: descriptor,
                displayURL: media,
                expectedFingerprint: expected
            )
            XCTAssertEqual(
                try service.readLabelNumber(
                    atFileDescriptor: descriptor,
                    displayURL: media,
                    expectedFingerprint: expected
                ),
                label
            )
            var freshPublicURL = URL(fileURLWithPath: media.path)
            freshPublicURL.removeAllCachedResourceValues()
            XCTAssertEqual(
                try freshPublicURL.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0,
                label,
                "Finder's public resource-value API must agree with the exact-FD mapping"
            )
            let persisted = [UInt8](try readMetadataIdentityXattr(
                name: "com.apple.FinderInfo",
                at: media
            ))
            XCTAssertEqual(persisted.count, 32)
            for index in persisted.indices where index != 8 && index != 9 {
                XCTAssertEqual(persisted[index], originalFinderInfo[index], "byte \(index)")
            }
            let originalFlags = (UInt16(originalFinderInfo[8]) << 8)
                | UInt16(originalFinderInfo[9])
            let persistedFlags = (UInt16(persisted[8]) << 8) | UInt16(persisted[9])
            XCTAssertEqual(persistedFlags & ~UInt16(0x000E), originalFlags & ~UInt16(0x000E))
        }
        try service.writeLabelNumber(
            5,
            atFileDescriptor: descriptor,
            displayURL: media,
            expectedFingerprint: expected
        )
        try service.writeLabelNumber(
            0,
            atFileDescriptor: descriptor,
            displayURL: media,
            expectedFingerprint: expected
        )
        var clearedPublicURL = URL(fileURLWithPath: media.path)
        clearedPublicURL.removeAllCachedResourceValues()
        XCTAssertEqual(
            try clearedPublicURL.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0,
            0
        )

        for malformedSize in [9, 33, 4_096] {
            XCTAssertThrowsError(
                try FinderColorLabelService.finderLabelNumber(
                    fromFinderInfo: Data(repeating: 0, count: malformedSize),
                    displayPath: media.path
                )
            ) { error in
                guard case .metadataCoordinationFailed = error as? AssetMetadataError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testFinderLabelReadAndWriteRejectHardLinkedTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-finder-hardlink-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.mov")
        let hardlink = root.appendingPathComponent("hardlink.mov")
        try Data("hard-linked-review-media".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardlink)
        let expected = try FileFingerprint.capture(at: hardlink)
        let service = FinderColorLabelService()

        XCTAssertThrowsError(
            try service.readLabelNumber(at: hardlink, expectedFingerprint: expected)
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(hardlink.path))
        }
        XCTAssertThrowsError(
            try service.writeLabelNumber(3, at: hardlink, expectedFingerprint: expected)
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .hardLinkRejected(hardlink.path))
        }
        XCTAssertEqual(try original.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0, 0)
    }

    func testFinderLabelWriteBindsToCompleteExpectedFingerprint() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umis-finder-fingerprint-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("replaceable.mov")
        try Data("scan-time-file".utf8).write(to: media)
        let scanned = try FileFingerprint.capture(at: media)
        try Data("replacement-file-with-other-size".utf8).write(to: media, options: .atomic)
        let replacement = try Data(contentsOf: media)

        XCTAssertThrowsError(
            try FinderColorLabelService().writeLabelNumber(
                4,
                at: media,
                expectedFingerprint: scanned
            )
        ) { error in
            XCTAssertEqual(error as? AssetMetadataError, .concurrentModification(media.path))
        }
        XCTAssertEqual(try Data(contentsOf: media), replacement)
        XCTAssertEqual(try media.resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? 0, 0)
    }
}

private func setMetadataIdentityXattr(name: String, data: Data, at url: URL) throws {
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

private func readMetadataIdentityXattr(name: String, at url: URL) throws -> Data {
    let size = url.withUnsafeFileSystemRepresentation { path -> Int in
        guard let path else { return -1 }
        return Darwin.getxattr(path, name, nil, 0, 0, 0)
    }
    guard size >= 0 else {
        throw UMISCoreError.posix(operation: "test getxattr size", code: errno, path: url.path)
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let count = bytes.withUnsafeMutableBytes { buffer in
        url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return Darwin.getxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
    }
    guard count >= 0 else {
        throw UMISCoreError.posix(operation: "test getxattr", code: errno, path: url.path)
    }
    return Data(bytes.prefix(count))
}
