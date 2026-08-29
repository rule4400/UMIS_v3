import AppKit
import Darwin
import Dispatch
import Foundation
import UMISCore

/// A descriptor-relative capability for one scanned review asset.
///
/// The user-facing URL is never used as the authority for a metadata read or write. Starting from
/// the frozen review root, every directory is opened with `O_NOFOLLOW`; the resulting parent
/// descriptor remains alive while Core receives only the borrowed descriptor plus one leaf name.
/// Replacing an ancestor directory or redirecting it with a symlink therefore cannot redirect the
/// filesystem mutation to an unrelated pathname.
final class ReviewFileAccessLease {
    let displayURL: URL
    private let parentDescriptor: Int32
    private let leafName: String
    private let rootURL: URL
    private let rootDevice: UInt64
    private let rootInode: UInt64

    init(
        rootURL: URL,
        rootDevice: UInt64,
        rootInode: UInt64,
        fileURL: URL,
        expectedFingerprint: FileFingerprint
    ) throws {
        let normalizedRoot = rootURL.standardizedFileURL
        let normalizedFile = fileURL.standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let fileComponents = normalizedFile.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            throw UMISCoreError.identityChanged
        }
        let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
        guard let leafName = relativeComponents.last,
              Self.isSafePathComponent(leafName),
              relativeComponents.dropLast().allSatisfy(Self.isSafePathComponent) else {
            throw UMISCoreError.invalidPath("Invalid review asset path: \(fileURL.path)")
        }

        var ownedDescriptor = normalizedRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard ownedDescriptor >= 0 else {
            throw Self.openError(operation: "open review root", path: normalizedRoot.path)
        }

        do {
            try Self.requireDirectory(
                descriptor: ownedDescriptor,
                device: rootDevice,
                inode: rootInode,
                path: normalizedRoot.path
            )
            for component in relativeComponents.dropLast() {
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        ownedDescriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw Self.openError(
                        operation: "openat review directory",
                        path: normalizedFile.path
                    )
                }
                do {
                    try Self.requireDirectory(
                        descriptor: nextDescriptor,
                        device: rootDevice,
                        inode: nil,
                        path: normalizedFile.path
                    )
                } catch {
                    Darwin.close(nextDescriptor)
                    throw error
                }
                Darwin.close(ownedDescriptor)
                ownedDescriptor = nextDescriptor
            }

            try Self.requireExpectedFile(
                parentDescriptor: ownedDescriptor,
                leafName: leafName,
                expected: expectedFingerprint,
                path: normalizedFile.path
            )
        } catch {
            Darwin.close(ownedDescriptor)
            throw error
        }

        parentDescriptor = ownedDescriptor
        self.leafName = leafName
        self.rootURL = normalizedRoot
        self.rootDevice = rootDevice
        self.rootInode = rootInode
        displayURL = normalizedFile
    }

    deinit {
        Darwin.close(parentDescriptor)
    }

    /// Supplies a borrowed parent-directory capability plus a single validated leaf component.
    /// Core metadata code must use only descriptor-relative I/O while the closure is running; the
    /// diagnostic pathname is deliberately not part of this authority.
    func withMetadataCapability<Value>(
        expectedFingerprint: FileFingerprint,
        _ operation: (Int32, String) throws -> Value
    ) throws -> Value {
        let parentPathBefore = try validatedCurrentParentPath()
        try Self.requireExpectedFile(
            parentDescriptor: parentDescriptor,
            leafName: leafName,
            expected: expectedFingerprint,
            path: displayURL.path
        )
        let operationResult = Result { try operation(parentDescriptor, leafName) }
        // A committed Core mutation can still report a readback/fsync/cleanup error. Validate the
        // held directory capability even on that error path so moving the directory outside the
        // frozen archive can never be hidden by the earlier operation error. The boundary error is
        // intentionally authoritative when both checks fail.
        let parentPathAfter = try validatedCurrentParentPath()
        guard parentPathAfter == parentPathBefore else {
            throw UMISCoreError.identityChanged
        }
        return try operationResult.get()
    }

    /// Finder color writes operate on the exact open inode. The parent/root check surrounding the
    /// closure prevents a directory moved outside the selected archive from receiving a mutation.
    func withExpectedFileDescriptor<Value>(
        expectedFingerprint: FileFingerprint,
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        let parentPathBefore = try validatedCurrentParentPath()
        let descriptor = leafName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw Self.openError(operation: "openat review asset", path: displayURL.path)
        }
        defer { Darwin.close(descriptor) }
        try Self.requireExpectedDescriptor(
            descriptor,
            expected: expectedFingerprint,
            path: displayURL.path
        )
        let operationResult = Result { try operation(descriptor) }
        // Finder writes mutate the exact open inode. Revalidate that descriptor and its containing
        // archive whether the write succeeds or throws; otherwise an operation error could mask an
        // ancestor that was concurrently moved outside the selected root.
        try Self.requireExpectedDescriptor(
            descriptor,
            expected: expectedFingerprint,
            path: displayURL.path
        )
        let parentPathAfter = try validatedCurrentParentPath()
        guard parentPathAfter == parentPathBefore else {
            throw UMISCoreError.identityChanged
        }
        return try operationResult.get()
    }

    private func validatedCurrentParentPath() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(parentDescriptor, F_GETPATH, &buffer) == 0 else {
            throw UMISCoreError.posix(
                operation: "fcntl F_GETPATH review directory",
                code: errno,
                path: displayURL.path
            )
        }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let parentURL = URL(
            fileURLWithPath: String(decoding: pathBytes, as: UTF8.self),
            isDirectory: true
        ).standardizedFileURL
        guard parentURL == parentURL.resolvingSymlinksInPath(),
              Self.isSameOrDescendant(parentURL, of: rootURL) else {
            throw UMISCoreError.identityChanged
        }
        try Self.requireDirectory(
            descriptor: parentDescriptor,
            device: rootDevice,
            inode: nil,
            path: parentURL.path
        )
        let currentRoot = try FileFingerprint.capture(at: rootURL)
        guard currentRoot.device == rootDevice, currentRoot.inode == rootInode else {
            throw UMISCoreError.identityChanged
        }
        return parentURL
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func requireDirectory(
        descriptor: Int32,
        device: UInt64,
        inode: UInt64?,
        path: String
    ) throws {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw UMISCoreError.posix(operation: "fstat review directory", code: errno, path: path)
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR,
              UInt64(value.st_dev) == device,
              inode == nil || UInt64(value.st_ino) == inode else {
            throw UMISCoreError.identityChanged
        }
    }

    private static func requireExpectedFile(
        parentDescriptor: Int32,
        leafName: String,
        expected: FileFingerprint,
        path: String
    ) throws {
        let descriptor = leafName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw openError(operation: "openat review asset", path: path)
        }
        defer { Darwin.close(descriptor) }
        try requireExpectedDescriptor(descriptor, expected: expected, path: path)
    }

    private static func requireExpectedDescriptor(
        _ descriptor: Int32,
        expected: FileFingerprint,
        path: String
    ) throws {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw UMISCoreError.posix(operation: "fstat review asset", code: errno, path: path)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw UMISCoreError.notRegularFile(path)
        }
        guard value.st_nlink == 1 else {
            throw AssetMetadataError.hardLinkRejected(path)
        }
        let current = FileFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteSize: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
        guard current == expected else {
            throw AssetMetadataError.concurrentModification(path)
        }
    }

    private static func openError(operation: String, path: String) -> Error {
        let code = errno
        if code == ELOOP || code == ENOTDIR {
            return UMISCoreError.symbolicLinkRejected(path)
        }
        return UMISCoreError.posix(operation: operation, code: code, path: path)
    }
}

enum ReviewCoordinationAccess: Sendable {
    case read
    case write
    case contentIndependentMetadataWrite
}

struct ReviewCoordinationIntent: Sendable {
    let url: URL
    let access: ReviewCoordinationAccess

    init(url: URL, access: ReviewCoordinationAccess) {
        self.url = url
        self.access = access
    }

    init(coreIntent: AdobeXMPCoordinationIntent) {
        url = coreIntent.url
        access = switch coreIntent.access {
        case .read: .read
        case .write: .write
        case .contentIndependentMetadataWrite: .contentIndependentMetadataWrite
        }
    }
}

/// Coordinates one complete metadata operation with cooperative Adobe/Finder writers.
///
/// `NSFileCoordinator` may supply a different URL after another presenter moves an item while the
/// operation is waiting. UMIS deliberately does not follow that move: every supplied URL must still
/// be the exact scan-time path below the frozen archive root. The operation then rebuilds its
/// descriptor-relative lease inside the accessor and completes its write plus durable readback
/// before the accessor returns.
enum ReviewFileCoordinationGate {
    static func coordinate<Value: Sendable>(
        intents: [ReviewCoordinationIntent],
        frozenRootURL: URL,
        operation: @escaping @Sendable ([URL]) throws -> Value
    ) throws -> Value {
        guard !intents.isEmpty else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: frozenRootURL.path,
                reason: "no file-access intents were supplied"
            )
        }

        let fileIntents = intents.map { intent in
            switch intent.access {
            case .read:
                NSFileAccessIntent.readingIntent(with: intent.url, options: [])
            case .write:
                NSFileAccessIntent.writingIntent(with: intent.url, options: [])
            case .contentIndependentMetadataWrite:
                NSFileAccessIntent.writingIntent(
                    with: intent.url,
                    options: .contentIndependentMetadataOnly
                )
            }
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let accessorQueue = OperationQueue()
        accessorQueue.name = "jp.rinkan.umis.metadata-coordination"
        accessorQueue.maxConcurrentOperationCount = 1
        accessorQueue.qualityOfService = .userInitiated
        let completion = DispatchSemaphore(value: 0)
        let outcome = ReviewCoordinationOutcome<Value>()

        coordinator.coordinate(with: fileIntents, queue: accessorQueue) { coordinationError in
            defer { completion.signal() }
            if let coordinationError {
                outcome.store(.failure(AssetMetadataError.metadataCoordinationFailed(
                    path: intents[0].url.path,
                    reason: coordinationError.localizedDescription
                )))
                return
            }
            outcome.store(Result {
                let suppliedURLs = fileIntents.map(\.url)
                try requireSuppliedURLs(
                    suppliedURLs,
                    match: intents,
                    frozenRootURL: frozenRootURL
                )
                return try operation(suppliedURLs)
            })
        }

        while completion.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task<Never, Never>.isCancelled {
                coordinator.cancel()
            }
        }
        guard let result = outcome.load() else {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: intents[0].url.path,
                reason: "the file coordinator returned without an accessor result"
            )
        }
        return try result.get()
    }

    static func requireSuppliedURLs(
        _ suppliedURLs: [URL],
        match intents: [ReviewCoordinationIntent],
        frozenRootURL: URL
    ) throws {
        guard suppliedURLs.count == intents.count else {
            throw UMISCoreError.identityChanged
        }
        let root = frozenRootURL.standardizedFileURL
        for (supplied, intent) in zip(suppliedURLs, intents) {
            let actual = supplied.standardizedFileURL
            let expected = intent.url.standardizedFileURL
            guard actual == expected,
                  actual == actual.resolvingSymlinksInPath(),
                  isSameOrDescendant(actual, of: root) else {
                throw UMISCoreError.identityChanged
            }
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private final class ReviewCoordinationOutcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private struct ReviewMetadataLoadResult: Sendable {
    let assetID: UUID
    let rating: AdobeRating?
    let ratingIsExplicit: Bool?
    let labelNumber: Int?
    let ratingErrors: [String]
    let labelErrors: [String]
    let warnings: [String]
}

struct ReviewMetadataWriteResult: Sendable {
    let assetID: UUID
    let error: String?
    let fingerprintAfter: FileFingerprint?
    let warning: String?
    let ratingIsExplicit: Bool?
    let recoveryAttentionRequired: Bool

    init(
        assetID: UUID,
        error: String?,
        fingerprintAfter: FileFingerprint?,
        warning: String?,
        ratingIsExplicit: Bool?,
        recoveryAttentionRequired: Bool = false
    ) {
        self.assetID = assetID
        self.error = error
        self.fingerprintAfter = fingerprintAfter
        self.warning = warning
        self.ratingIsExplicit = ratingIsExplicit
        self.recoveryAttentionRequired = recoveryAttentionRequired
    }

    var succeeded: Bool { error == nil }
}

private struct ReviewRatingWriteVerification: Sendable {
    let written: AdobeXMPRatingWriteResult
    let persisted: AdobeXMPRatingReadResult
}

enum ReviewMetadataDomain {
    case rating
    case finderLabel
}

private struct ReviewSourceIdentity: Equatable, Sendable {
    let rootURL: URL
    let rootDevice: UInt64
    let rootInode: UInt64
    let volumeUUID: String?
    let isReadOnly: Bool?
    let isRemovable: Bool
    let isLocal: Bool
    let isEjectable: Bool
    let isInternal: Bool
}

private struct ReviewMutationContext: Sendable {
    let sourceIdentity: ReviewSourceIdentity
    let sourceVolumeID: SourceVolumeID
    let hasLatestVerifiedReceipt: Bool
}

private struct ReviewRecoveryInspectionOutcome: Sendable {
    let result: MetadataRecoveryScanResult?
    let errorMessage: String?
}

/// A complete frozen-root recovery scan plus the short-lived capability that authorizes one
/// rating batch. The authorization deliberately never enters AppModel state; retaining it beyond
/// the current batch could let later UI actions rely on stale directory evidence.
private struct ReviewRecoveryWritePreflightOutcome: Sendable {
    let inspection: ReviewRecoveryInspectionOutcome
    let authorization: MetadataRecoveryWriteAuthorization?
}

private enum ReviewSourceValidationError: LocalizedError, Sendable {
    case notDirectory
    case removableMedia
    case networkArchiveUnsupported
    case overlapsIngestSource
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "評価対象のアーカイブフォルダを確認できません"
        case .removableMedia:
            "SDカード等の取り外し可能メディアには書き込みません"
        case .networkArchiveUnsupported:
            "ネットワーク上のアーカイブは、再マウント同一性を証明できないため現在は読み取り専用です"
        case .overlapsIngestSource:
            "現在の取り込み元と重なるフォルダは評価対象にできません"
        case .identityChanged:
            "読み込み中にアーカイブまたはボリュームが変更されました。再スキャンが必要です"
        }
    }
}

struct ReviewToolbarState: Equatable {
    let visibleSelectionCount: Int
    let selectionRating: AdobeRating?
    let selectionRatingIsExplicit: Bool?
    let selectionLabelNumber: Int?
    let mutationBlockReason: String?

    var canMutateMetadata: Bool { mutationBlockReason == nil }
}

struct ReviewScanIssueDisplaySummary: Equatable, Sendable {
    let totalCount: Int
    let samples: [String]
}

extension AppModel {
    /// Review supports a fixed, all-enabled media inventory independent of the current ingest
    /// project's destination/category choices. Otherwise disabling a project category—or simply
    /// using an older project extension table—could make a Core-supported Adobe format disappear
    /// from the rating grid without explanation.
    nonisolated static func reviewMediaScanPolicy() -> MediaScanPolicy {
        let support = AdobeXMPRatingService.formatSupport
        let photoExtensions = support.embeddedStillExtensions
            .subtracting(["dng"])
            .union(["heic", "heif", "bmp"])
        let rawExtensions = support.manufacturerRawExtensions.union(["dng"])
        let movieExtensions = support.embeddedDynamicExtensions
            .subtracting(["m4a"])
            .union(["mxf", "r3d", "avi", "mkv", "mts", "m2ts"])
        let audioExtensions: Set<String> = [
            "m4a", "wav", "aif", "aiff", "mp3", "aac", "flac", "bwf",
        ]
        return MediaScanPolicy(
            categoryRules: [
                ProjectCategory(
                    displayName: "動画",
                    folderName: "動画",
                    extensions: movieExtensions,
                    mediaKind: .movie,
                    sortOrder: 0
                ),
                ProjectCategory(
                    displayName: "写真",
                    folderName: "写真",
                    extensions: photoExtensions,
                    mediaKind: .photo,
                    sortOrder: 1
                ),
                ProjectCategory(
                    displayName: "RAW",
                    folderName: "RAW",
                    extensions: rawExtensions,
                    mediaKind: .rawPhoto,
                    sortOrder: 2
                ),
                ProjectCategory(
                    displayName: "音声",
                    folderName: "音声",
                    extensions: audioExtensions,
                    mediaKind: .audio,
                    sortOrder: 3
                ),
            ],
            sidecarExtensions: ["xmp", "xml", "thm", "srt", "lrv", "aae"],
            includeHiddenFiles: true,
            excludedFolderNames: []
        )
    }

    nonisolated static func unsupportedReviewRegularFilePaths(
        in inventory: [InventoryEntry]
    ) -> [String] {
        inventory.compactMap { entry in
            entry.type == .regularFile && entry.classification == .unknown
                ? entry.relativePath
                : nil
        }
    }

    /// Converts scanner diagnostics into a bounded, display-only summary. Scanner errors may be
    /// backed by Foundation diagnostics containing an absolute `NSFilePath`; those raw messages
    /// must never be retained in observable UI state. The relative entry name is validated and the
    /// reason is reduced to a small privacy-safe category instead.
    nonisolated static func reviewScanIssueDisplaySummary(
        issues: [ScanIssue],
        sampleLimit: Int = 20
    ) -> ReviewScanIssueDisplaySummary {
        let limit = max(0, sampleLimit)
        let samples = issues.prefix(limit).map { issue in
            let relativePath = safeReviewScanIssueRelativePath(issue.relativePath)
            let reason = safeReviewScanIssueReason(issue.message)
            return "\(relativePath): \(reason)"
        }
        return ReviewScanIssueDisplaySummary(totalCount: issues.count, samples: samples)
    }

    private nonisolated static func safeReviewScanIssueRelativePath(_ rawValue: String) -> String {
        let singleLine = rawValue
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return "アーカイブ直下" }
        let lowercased = singleLine.lowercased()
        let components = singleLine.split(separator: "/", omittingEmptySubsequences: false)
        guard !(singleLine as NSString).isAbsolutePath,
              !singleLine.hasPrefix("~"),
              !lowercased.hasPrefix("file:"),
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return "場所非表示"
        }
        let maximumCharacters = 160
        guard singleLine.count > maximumCharacters else { return singleLine }
        return String(singleLine.prefix(maximumCharacters - 1)) + "…"
    }

    private nonisolated static func safeReviewScanIssueReason(_ rawValue: String) -> String {
        let message = rawValue.lowercased()
        if message.contains("changed") || message.contains("変更") {
            return "走査中に内容が変更されました"
        }
        if message.contains("disappeared")
            || message.contains("no such file")
            || message.contains("enoent")
            || message.contains("見つか") {
            return "走査中に見つからなくなりました"
        }
        if message.contains("permission")
            || message.contains("not permitted")
            || message.contains("eacces")
            || message.contains("code=257")
            || message.contains("権限") {
            return "読み取り権限を確認できませんでした"
        }
        if message.contains("lstat") || message.contains("stat failed") {
            return "ファイル情報を取得できませんでした"
        }
        return "読み込み中に問題が発生しました"
    }

    func adoptReviewScanIssues(from result: ScanResult, sampleLimit: Int = 20) {
        let summary = Self.reviewScanIssueDisplaySummary(
            issues: result.issues,
            sampleLimit: sampleLimit
        )
        reviewScanIssueCount = summary.totalCount
        reviewScanIssueSamples = summary.samples
    }

    var reviewScanIssueStatusSummary: String? {
        guard reviewScanIssueCount > 0 else { return nil }
        return "走査中に確認できなかった項目 \(reviewScanIssueCount)件"
    }

    private func reviewStatusIncludingScanIssues(_ message: String) -> String {
        guard let reviewScanIssueStatusSummary else { return message }
        return "\(message)（\(reviewScanIssueStatusSummary)）"
    }

    var reviewTotalBytes: Int64 {
        reviewAssetTotalBytes
    }

    var reviewMetadataErrorIDs: Set<UUID> {
        reviewMetadataErrorIDsProjection
    }

    var reviewMetadataErrors: [UUID: String] {
        reviewMetadataErrorsProjection
    }

    var reviewMetadataRecoveryBlockReason: String? {
        if let reviewMetadataRecoveryScanError {
            return "中断されたXMP更新の保護データを確認できません: \(reviewMetadataRecoveryScanError)"
        }
        if reviewMetadataRecoveryScanWasTruncated {
            return "XMP保護データの検査が上限に達したため、変更を停止しています"
        }
        if !reviewMetadataRecoveryRecords.isEmpty {
            return "中断されたXMP更新の保護データが\(reviewMetadataRecoveryRecords.count)件あります。自動削除せず、復旧確認まで変更を停止します"
        }
        return nil
    }

    private func applyReviewRecoveryInspection(_ outcome: ReviewRecoveryInspectionOutcome) {
        reviewMetadataRecoveryRecords = outcome.result?.records ?? []
        reviewMetadataRecoveryScanWasTruncated = outcome.result?.wasTruncated ?? false
        reviewMetadataRecoveryScanError = outcome.errorMessage
    }

    private nonisolated static func recoveryBlockReason(
        for outcome: ReviewRecoveryInspectionOutcome
    ) -> String? {
        if let error = outcome.errorMessage {
            return "中断されたXMP更新の保護データを確認できません: \(error)"
        }
        guard let result = outcome.result else {
            return "XMP保護データの検査結果を確認できません"
        }
        if result.wasTruncated {
            return "XMP保護データの検査が上限に達したため、変更を停止しています"
        }
        if !result.records.isEmpty {
            return "中断されたXMP更新の保護データが\(result.records.count)件あります。復旧確認まで変更を停止します"
        }
        return nil
    }

    var reviewSelectedAssets: [AppAsset] {
        let selected = Self.visibleSelection(reviewSelectedAssetIDs, within: visibleReviewAssetIDs)
        return reviewAssets.filter { selected.contains($0.id) }
    }

    var reviewVisibleSelectionCount: Int {
        Self.visibleSelection(reviewSelectedAssetIDs, within: visibleReviewAssetIDs).count
    }

    var visibleReviewAssetIDs: Set<UUID> {
        reviewBrowserProjection.visibleAssetIDs
    }

    var reviewMutationBlockReason: String? {
        reviewMutationBlockReason(
            forVisibleSelection: Self.visibleSelection(
                reviewSelectedAssetIDs,
                within: visibleReviewAssetIDs
            )
        )
    }

    private func reviewMutationBlockReason(forVisibleSelection selectedIDs: Set<UUID>) -> String? {
        if selectedIDs.isEmpty {
            return "評価またはカラーを設定する素材を選択してください"
        }
        if let reviewMetadataRecoveryBlockReason {
            return reviewMetadataRecoveryBlockReason
        }
        if reviewSourceIsReadOnly != false {
            return reviewSourceIsReadOnly == true
                ? "選択したアーカイブは読み取り専用です"
                : "アーカイブの書き込み可否を確認できないため、変更できません"
        }
        if !reviewSourceIsLocal {
            return ReviewSourceValidationError.networkArchiveUnsupported.localizedDescription
        }
        if reviewSourceIsEjectable || !reviewSourceIsInternal {
            return "外付け・取り外し可能・媒体種別不明のアーカイブは現在読み取り専用です"
        }
        if reviewIsScanning || reviewMetadataIsLoading {
            return "アーカイブと既存メタデータの読み込み完了を待ってください"
        }
        if reviewMetadataIsWriting {
            return "別のメタデータ変更を処理しています"
        }
        if reviewSourceURL == nil
            || reviewSourceRootDevice == nil
            || reviewSourceRootInode == nil
            || reviewSourceVolumeUUID == nil {
            return "アーカイブを再スキャンして同一性を確認してください"
        }
        if let sourceURL, let reviewSourceURL,
           Self.pathsOverlap(sourceURL, reviewSourceURL) {
            return "現在の取り込み元と重なるフォルダは評価できません"
        }
        if previewAsset != nil {
            return "プレビューを閉じてから評価・タグを変更してください"
        }
        if latestVerifiedReceipt != nil {
            return "カード初期化の可否を確定するまで、検証済み保存先のメタデータは変更できません"
        }
        if !canStartExclusiveOperation {
            return "実行中の処理が完了してから評価・タグを変更してください"
        }
        return nil
    }

    var canMutateReviewMetadata: Bool {
        reviewMutationBlockReason == nil
    }

    var reviewSelectionRating: AdobeRating? {
        let selectedIDs = Self.visibleSelection(reviewSelectedAssetIDs, within: visibleReviewAssetIDs)
        return reviewSelectionRating(for: selectedIDs)
    }

    private func reviewSelectionRating(for selectedIDs: Set<UUID>) -> AdobeRating? {
        guard !selectedIDs.isEmpty,
              selectedIDs.allSatisfy({
                  reviewRatingLoadedAssetIDs.contains($0) && reviewRatingErrors[$0] == nil
              }) else { return nil }
        return commonValue(for: selectedIDs, values: reviewRatings, defaultValue: .unrated)
    }

    var reviewSelectionRatingIsExplicit: Bool? {
        let selectedIDs = Self.visibleSelection(reviewSelectedAssetIDs, within: visibleReviewAssetIDs)
        return reviewSelectionRatingIsExplicit(
            for: selectedIDs,
            selectionRating: reviewSelectionRating(for: selectedIDs)
        )
    }

    private func reviewSelectionRatingIsExplicit(
        for selectedIDs: Set<UUID>,
        selectionRating: AdobeRating?
    ) -> Bool? {
        guard selectionRating != nil, let firstID = selectedIDs.first else { return nil }
        let first = reviewRatingExplicitAssetIDs.contains(firstID)
        return selectedIDs.allSatisfy {
            reviewRatingExplicitAssetIDs.contains($0) == first
        } ? first : nil
    }

    var reviewSelectionLabelNumber: Int? {
        let selectedIDs = Self.visibleSelection(reviewSelectedAssetIDs, within: visibleReviewAssetIDs)
        return reviewSelectionLabelNumber(for: selectedIDs)
    }

    private func reviewSelectionLabelNumber(for selectedIDs: Set<UUID>) -> Int? {
        guard !selectedIDs.isEmpty,
              selectedIDs.allSatisfy({
                  reviewLabelLoadedAssetIDs.contains($0) && reviewLabelErrors[$0] == nil
              }) else { return nil }
        return commonValue(for: selectedIDs, values: reviewLabelNumbers, defaultValue: 0)
    }

    var reviewToolbarState: ReviewToolbarState {
        let selectedIDs = Self.visibleSelection(
            reviewSelectedAssetIDs,
            within: visibleReviewAssetIDs
        )
        let rating = reviewSelectionRating(for: selectedIDs)
        return ReviewToolbarState(
            visibleSelectionCount: selectedIDs.count,
            selectionRating: rating,
            selectionRatingIsExplicit: reviewSelectionRatingIsExplicit(
                for: selectedIDs,
                selectionRating: rating
            ),
            selectionLabelNumber: reviewSelectionLabelNumber(for: selectedIDs),
            mutationBlockReason: reviewMutationBlockReason(forVisibleSelection: selectedIDs)
        )
    }

    private var reviewMutationContext: ReviewMutationContext? {
        guard let rootURL = reviewSourceURL,
              let rootDevice = reviewSourceRootDevice,
              let rootInode = reviewSourceRootInode,
              let volumeUUID = reviewSourceVolumeUUID else { return nil }
        return ReviewMutationContext(
            sourceIdentity: ReviewSourceIdentity(
                rootURL: rootURL,
                rootDevice: rootDevice,
                rootInode: rootInode,
                volumeUUID: volumeUUID,
                isReadOnly: reviewSourceIsReadOnly,
                isRemovable: false,
                isLocal: reviewSourceIsLocal,
                isEjectable: reviewSourceIsEjectable,
                isInternal: reviewSourceIsInternal
            ),
            sourceVolumeID: reviewSourceVolumeID,
            hasLatestVerifiedReceipt: latestVerifiedReceipt != nil
        )
    }

    func chooseReviewSource() {
        guard reviewScanAdmissionAllowed else { return }

        let panel = NSOpenPanel()
        panel.title = "評価するアーカイブを選択"
        panel.prompt = "アーカイブを開く"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        guard reviewScanAdmissionAllowed else {
            reviewStatusMessage = "別の処理が開始されたため、アーカイブ選択を適用しませんでした"
            return
        }

        let url = selectedURL.standardizedFileURL
        if let sourceURL, Self.pathsOverlap(url, sourceURL) {
            reviewStatusMessage = "現在の取り込みカードは評価対象にできません。取り込み済みアーカイブを選択してください"
            return
        }
        if sourceURL == nil,
           let mountURL = activeSourceIdentity?.mountURL,
           Self.pathsOverlap(url, mountURL) {
            reviewStatusMessage = "現在の取り込み媒体は評価対象にできません"
            return
        }
        scanReviewSource(url)
    }

    func rescanReviewSource() {
        guard let reviewSourceURL,
              !reviewMetadataIsWriting,
              canStartExclusiveOperation else { return }
        scanReviewSource(reviewSourceURL)
    }

    private var reviewScanAdmissionAllowed: Bool {
        Self.reviewScanAdmissionAllowed(
            canStartExclusiveOperation: canStartExclusiveOperation,
            reviewIsScanning: reviewIsScanning,
            reviewMetadataIsLoading: reviewMetadataIsLoading,
            reviewMetadataIsWriting: reviewMetadataIsWriting
        )
    }

    nonisolated static func reviewScanAdmissionAllowed(
        canStartExclusiveOperation: Bool,
        reviewIsScanning: Bool,
        reviewMetadataIsLoading: Bool,
        reviewMetadataIsWriting: Bool
    ) -> Bool {
        canStartExclusiveOperation
            && !reviewIsScanning
            && !reviewMetadataIsLoading
            && !reviewMetadataIsWriting
    }

    func refreshReviewMetadata() {
        guard canStartExclusiveOperation,
              !reviewAssets.isEmpty,
              !reviewIsScanning,
              !reviewMetadataIsLoading,
              !reviewMetadataIsWriting else { return }
        let generation = reviewScanGeneration
        loadReviewMetadata(for: reviewAssets, generation: generation)
    }

    func selectAllReviewAssets() {
        reviewSelectedAssetIDs = visibleReviewAssetIDs
    }

    func clearReviewSelection() {
        reviewSelectedAssetIDs.removeAll()
    }

    func cancelReviewMetadataWrite() {
        guard reviewMetadataIsWriting else { return }
        reviewStatusMessage = "現在のファイルを安全に完了してから、残りの保存を中止します"
        reviewMetadataTask?.cancel()
    }

    func selectReviewAssets(_ ids: Set<UUID>) {
        let valid = visibleReviewAssetIDs
        reviewSelectedAssetIDs = ids.intersection(valid)
    }

    func applyReviewRating(_ rating: AdobeRating) {
        guard canMutateReviewMetadata else {
            if let reviewMutationBlockReason { reviewStatusMessage = reviewMutationBlockReason }
            return
        }
        let selectedAssets = reviewSelectedAssets
        guard !selectedAssets.isEmpty, let context = reviewMutationContext else {
            reviewStatusMessage = "アーカイブの同一性を確認できないため再スキャンが必要です"
            return
        }
        let generation = reviewScanGeneration
        let attempt = UUID()
        reviewMetadataWriteAttempt = attempt
        reviewMetadataIsWriting = true
        beginReviewMediaMutationQuiescence()
        reviewStatusMessage = "\(selectedAssets.count)件へAdobe XMPレーティングを書き込んでいます"
        reviewMetadataTask = Task { [weak self] in
            guard let self else { return }
            let results: [ReviewMetadataWriteResult]
            var recoveryInspection: ReviewRecoveryInspectionOutcome?
            do {
                try await suspendMediaReadsForReviewMutation()
                let writePreflight = await Self.prepareMetadataRecoveryWrite(
                    sourceIdentity: context.sourceIdentity
                )
                recoveryInspection = writePreflight.inspection
                if let blockReason = Self.recoveryBlockReason(for: writePreflight.inspection) {
                    results = Self.failedReviewWriteResults(
                        for: selectedAssets,
                        error: AssetMetadataError.metadataCoordinationFailed(
                            path: context.sourceIdentity.rootURL.path,
                            reason: blockReason
                        )
                    )
                } else if let authorization = writePreflight.authorization {
                    results = await Self.writeReviewRatings(
                        rating,
                        assets: selectedAssets,
                        context: context,
                        recoveryWriteAuthorization: authorization
                    )
                    // Rating writes can create a durable recovery directory even when the
                    // individual result is an error. Re-scan the entire frozen root before the
                    // mutation boundary is released; the batch authorization only proves the
                    // tree was clean immediately before this batch began.
                    recoveryInspection = await Self.inspectMetadataRecoveries(
                        sourceIdentity: context.sourceIdentity,
                        honorCancellation: false
                    )
                } else {
                    results = Self.failedReviewWriteResults(
                        for: selectedAssets,
                        error: AssetMetadataError.metadataCoordinationFailed(
                            path: context.sourceIdentity.rootURL.path,
                            reason: "A clean frozen-root recovery scan did not issue write authorization"
                        )
                    )
                }
            } catch {
                results = Self.failedReviewWriteResults(for: selectedAssets, error: error)
            }
            let wasCancelled = Task.isCancelled
            await finishReviewMediaMutationQuiescence()
            guard reviewMetadataWriteAttempt == attempt else { return }
            defer {
                reviewMetadataIsWriting = false
                reviewMetadataTask = nil
            }
            guard reviewScanGeneration == generation else {
                reviewStatusMessage = "評価対象が変更されたため結果を破棄しました。再スキャンしてください"
                return
            }
            if let recoveryInspection {
                applyReviewRecoveryInspection(recoveryInspection)
            }
            if results.contains(where: \.recoveryAttentionRequired),
               reviewMetadataRecoveryBlockReason == nil {
                reviewMetadataRecoveryScanError =
                    "XMP更新が保護データの残留を報告しましたが、再検査で場所を特定できません"
            }
            applyReviewWriteResults(results, domain: .rating, rating: rating)
            let succeeded = results.filter(\.succeeded).count
            let failed = results.count - succeeded
            let warningCount = results.filter { $0.warning != nil }.count
            if let reviewMetadataRecoveryBlockReason {
                reviewStatusMessage = "\(succeeded)件を更新。\(reviewMetadataRecoveryBlockReason)"
            } else if wasCancelled {
                reviewStatusMessage = "保存を中止しました（完了 \(succeeded)件、未完了 \(failed)件）"
            } else if failed > 0 {
                reviewStatusMessage = "\(succeeded)件を更新、\(failed)件は競合または書き込みエラーです"
            } else if warningCount > 0 {
                reviewStatusMessage = "\(succeeded)件を更新。\(warningCount)件に注意事項があります（タイルの情報アイコンを確認）"
            } else {
                reviewStatusMessage = "\(succeeded)件のレーティングを更新しました"
            }
        }
    }

    func applyReviewLabelNumber(_ labelNumber: Int) {
        guard canMutateReviewMetadata else {
            if let reviewMutationBlockReason { reviewStatusMessage = reviewMutationBlockReason }
            return
        }
        guard (0 ... 7).contains(labelNumber) else {
            reviewStatusMessage = "Finderカラー番号が不正です"
            return
        }
        let selectedAssets = reviewSelectedAssets
        guard !selectedAssets.isEmpty, let context = reviewMutationContext else {
            reviewStatusMessage = "アーカイブの同一性を確認できないため再スキャンが必要です"
            return
        }
        let generation = reviewScanGeneration
        let attempt = UUID()
        reviewMetadataWriteAttempt = attempt
        reviewMetadataIsWriting = true
        beginReviewMediaMutationQuiescence()
        reviewStatusMessage = "\(selectedAssets.count)件のFinderカラーを更新しています"
        reviewMetadataTask = Task { [weak self] in
            guard let self else { return }
            let results: [ReviewMetadataWriteResult]
            var recoveryInspection: ReviewRecoveryInspectionOutcome?
            do {
                try await suspendMediaReadsForReviewMutation()
                let writePreflight = await Self.prepareMetadataRecoveryWrite(
                    sourceIdentity: context.sourceIdentity
                )
                recoveryInspection = writePreflight.inspection
                if let blockReason = Self.recoveryBlockReason(for: writePreflight.inspection) {
                    results = Self.failedReviewWriteResults(
                        for: selectedAssets,
                        error: AssetMetadataError.metadataCoordinationFailed(
                            path: context.sourceIdentity.rootURL.path,
                            reason: blockReason
                        )
                    )
                } else if let authorization = writePreflight.authorization {
                    results = await Self.writeReviewLabels(
                        labelNumber,
                        assets: selectedAssets,
                        context: context,
                        recoveryWriteAuthorization: authorization
                    )
                } else {
                    results = Self.failedReviewWriteResults(
                        for: selectedAssets,
                        error: AssetMetadataError.metadataCoordinationFailed(
                            path: context.sourceIdentity.rootURL.path,
                            reason: "A clean frozen-root recovery scan did not issue write authorization"
                        )
                    )
                }
            } catch {
                results = Self.failedReviewWriteResults(for: selectedAssets, error: error)
            }
            let wasCancelled = Task.isCancelled
            await finishReviewMediaMutationQuiescence()
            guard reviewMetadataWriteAttempt == attempt else { return }
            defer {
                reviewMetadataIsWriting = false
                reviewMetadataTask = nil
            }
            guard reviewScanGeneration == generation else {
                reviewStatusMessage = "評価対象が変更されたため結果を破棄しました。再スキャンしてください"
                return
            }
            if let recoveryInspection {
                applyReviewRecoveryInspection(recoveryInspection)
            }
            applyReviewWriteResults(results, domain: .finderLabel, labelNumber: labelNumber)
            let succeeded = results.filter(\.succeeded).count
            let failed = results.count - succeeded
            if let reviewMetadataRecoveryBlockReason {
                reviewStatusMessage = "\(succeeded)件を更新。\(reviewMetadataRecoveryBlockReason)"
            } else if wasCancelled {
                reviewStatusMessage = "保存を中止しました（完了 \(succeeded)件、未完了 \(failed)件）"
            } else {
                reviewStatusMessage = failed == 0
                    ? "\(succeeded)件のFinderカラーを更新しました"
                    : "\(succeeded)件を更新、\(failed)件は競合または書き込みエラーです"
            }
        }
    }

    private nonisolated static func writeReviewRatings(
        _ rating: AdobeRating,
        assets: [AppAsset],
        context: ReviewMutationContext,
        recoveryWriteAuthorization: MetadataRecoveryWriteAuthorization
    ) async -> [ReviewMetadataWriteResult] {
        defer { withExtendedLifetime(recoveryWriteAuthorization) {} }
        var results: [ReviewMetadataWriteResult] = []
        results.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            do {
                try Task.checkCancellation()
                try await validateReviewAsset(asset, context: context, requiresWritableVolume: true)
                let preflightLease = try ReviewFileAccessLease(
                    rootURL: context.sourceIdentity.rootURL,
                    rootDevice: context.sourceIdentity.rootDevice,
                    rootInode: context.sourceIdentity.rootInode,
                    fileURL: asset.url,
                    expectedFingerprint: asset.fingerprint
                )
                let service = AdobeXMPRatingService()
                let preflightPlan = try preflightLease.withMetadataCapability(
                    expectedFingerprint: asset.fingerprint
                ) { parentDescriptor, leafName in
                    try service.coordinationPlan(
                        parentFileDescriptor: parentDescriptor,
                        mediaLeafName: leafName,
                        displayURL: asset.url,
                        expectedFingerprint: asset.fingerprint,
                        forWriting: true
                    )
                }
                let coordinationIntents = preflightPlan.intents.map {
                    ReviewCoordinationIntent(coreIntent: $0)
                }
                guard let mediaIntentIndex = preflightPlan.intents.firstIndex(where: {
                    $0.url.standardizedFileURL == asset.url.standardizedFileURL
                }) else {
                    throw UMISCoreError.identityChanged
                }
                let verification = try ReviewFileCoordinationGate.coordinate(
                    intents: coordinationIntents,
                    frozenRootURL: context.sourceIdentity.rootURL
                ) { coordinatedURLs in
                    guard coordinatedURLs.indices.contains(mediaIntentIndex) else {
                        throw UMISCoreError.identityChanged
                    }
                    let coordinatedMediaURL = coordinatedURLs[mediaIntentIndex]
                    let coordinatedLease = try ReviewFileAccessLease(
                        rootURL: context.sourceIdentity.rootURL,
                        rootDevice: context.sourceIdentity.rootDevice,
                        rootInode: context.sourceIdentity.rootInode,
                        fileURL: coordinatedMediaURL,
                        expectedFingerprint: asset.fingerprint
                    )
                    return try coordinatedLease.withMetadataCapability(
                        expectedFingerprint: asset.fingerprint
                    ) { parentDescriptor, leafName in
                        let livePlan = try service.coordinationPlan(
                            parentFileDescriptor: parentDescriptor,
                            mediaLeafName: leafName,
                            displayURL: coordinatedMediaURL,
                            expectedFingerprint: asset.fingerprint,
                            forWriting: true
                        )
                        guard livePlan == preflightPlan else {
                            throw AssetMetadataError.concurrentModification(
                                coordinatedMediaURL.path
                            )
                        }
                        let written = try service.writeRating(
                            rating,
                            parentFileDescriptor: parentDescriptor,
                            mediaLeafName: leafName,
                            displayURL: coordinatedMediaURL,
                            expectedFingerprint: asset.fingerprint,
                            context: AdobeXMPRatingMutationContext(
                                hasLatestVerifiedReceipt: context.hasLatestVerifiedReceipt,
                                recoveryWriteAuthorization: recoveryWriteAuthorization
                            )
                        )
                        let persisted = try service.readRating(
                            parentFileDescriptor: parentDescriptor,
                            mediaLeafName: leafName,
                            displayURL: coordinatedMediaURL,
                            expectedFingerprint: written.fingerprintAfter
                        )
                        return ReviewRatingWriteVerification(
                            written: written,
                            persisted: persisted
                        )
                    }
                }
                guard verification.persisted.rating == rating,
                      verification.persisted.hasExplicitRating
                else {
                    throw AssetMetadataError.concurrentModification(asset.url.path)
                }
                try await validateReviewAsset(
                    asset,
                    context: context,
                    requiresWritableVolume: true,
                    expectedFingerprint: verification.written.fingerprintAfter,
                    honorCancellation: false
                )
                results.append(ReviewMetadataWriteResult(
                    assetID: asset.id,
                    error: nil,
                    fingerprintAfter: verification.written.fingerprintAfter,
                    warning: verification.written.compatibilityWarning,
                    ratingIsExplicit: verification.persisted.hasExplicitRating,
                    recoveryAttentionRequired: verification.written.recoveryAttentionRequired
                ))
                if verification.written.recoveryAttentionRequired {
                    results.append(contentsOf: assets.dropFirst(index + 1).map {
                        ReviewMetadataWriteResult(
                            assetID: $0.id,
                            error: "XMP保護データが残ったため、安全確認まで保存を開始しませんでした",
                            fingerprintAfter: nil,
                            warning: nil,
                            ratingIsExplicit: nil
                        )
                    })
                    break
                }
            } catch {
                let recoveryAttentionRequired = Self.isRecoveryRetained(error)
                results.append(ReviewMetadataWriteResult(
                    assetID: asset.id,
                    error: String(describing: error),
                    fingerprintAfter: nil,
                    warning: nil,
                    ratingIsExplicit: nil,
                    recoveryAttentionRequired: recoveryAttentionRequired
                ))
                // Core invalidates the clean-tree authorization after any mutation-path failure.
                // Stop here instead of turning every later asset into an opaque authorization
                // error. A fresh user action always performs a new full-root preflight scan.
                let remainingReason: String
                if recoveryAttentionRequired {
                    remainingReason = "XMP保護データが残ったため、安全確認まで保存を開始しませんでした"
                } else if Task<Never, Never>.isCancelled {
                    remainingReason = "保存は開始されませんでした（ユーザーによる中止）"
                } else {
                    remainingReason = "前のファイルの書き込みまたは検証に失敗したため、安全のため保存を開始しませんでした"
                }
                results.append(contentsOf: assets.dropFirst(index + 1).map {
                    ReviewMetadataWriteResult(
                        assetID: $0.id,
                        error: remainingReason,
                        fingerprintAfter: nil,
                        warning: nil,
                        ratingIsExplicit: nil
                    )
                })
                break
            }
        }
        return results
    }

    nonisolated static func isRecoveryRetained(_ error: Error) -> Bool {
        if let serviceError = error as? AdobeXMPRatingServiceError,
           case .recoveryRetained = serviceError {
            return true
        }
        if let metadataError = error as? AssetMetadataError,
           case .recoveryRetained = metadataError {
            return true
        }
        return false
    }

    private nonisolated static func failedReviewWriteResults(
        for assets: [AppAsset],
        error: Error
    ) -> [ReviewMetadataWriteResult] {
        assets.map {
            ReviewMetadataWriteResult(
                assetID: $0.id,
                error: String(describing: error),
                fingerprintAfter: nil,
                warning: nil,
                ratingIsExplicit: nil
            )
        }
    }

    private nonisolated static func writeReviewLabels(
        _ labelNumber: Int,
        assets: [AppAsset],
        context: ReviewMutationContext,
        recoveryWriteAuthorization: MetadataRecoveryWriteAuthorization
    ) async -> [ReviewMetadataWriteResult] {
        // Finder labels do not create XMP recovery artifacts, but they share the same top-level
        // metadata exclusivity boundary. Keep the root lock alive until the whole label batch has
        // finished so another UMIS process cannot start an XMP batch after our clean preflight.
        defer { withExtendedLifetime(recoveryWriteAuthorization) {} }
        var results: [ReviewMetadataWriteResult] = []
        results.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            do {
                try Task.checkCancellation()
                try await validateReviewAsset(
                    asset,
                    context: context,
                    requiresWritableVolume: true
                )
                let coordinationIntents = [ReviewCoordinationIntent(
                    url: asset.url,
                    access: .contentIndependentMetadataWrite
                )]
                try ReviewFileCoordinationGate.coordinate(
                    intents: coordinationIntents,
                    frozenRootURL: context.sourceIdentity.rootURL
                ) { coordinatedURLs in
                    guard let coordinatedURL = coordinatedURLs.first else {
                        throw UMISCoreError.identityChanged
                    }
                    let lease = try ReviewFileAccessLease(
                        rootURL: context.sourceIdentity.rootURL,
                        rootDevice: context.sourceIdentity.rootDevice,
                        rootInode: context.sourceIdentity.rootInode,
                        fileURL: coordinatedURL,
                        expectedFingerprint: asset.fingerprint
                    )
                    let service = FinderColorLabelService()
                    try lease.withExpectedFileDescriptor(
                        expectedFingerprint: asset.fingerprint
                    ) { descriptor in
                        try service.writeLabelNumber(
                            labelNumber,
                            atFileDescriptor: descriptor,
                            displayURL: coordinatedURL,
                            expectedFingerprint: asset.fingerprint
                        )
                    }
                    let persisted = try lease.withExpectedFileDescriptor(
                        expectedFingerprint: asset.fingerprint
                    ) { descriptor in
                        try service.readLabelNumber(
                            atFileDescriptor: descriptor,
                            displayURL: coordinatedURL,
                            expectedFingerprint: asset.fingerprint
                        )
                    }
                    guard persisted == labelNumber else {
                        throw AssetMetadataError.concurrentModification(coordinatedURL.path)
                    }
                }
                // Once the xattr write and descriptor-bound readback have committed, cancellation
                // must not relabel that successful mutation as a failure. Cancellation is honored
                // before the next asset begins.
                try await validateReviewAsset(
                    asset,
                    context: context,
                    requiresWritableVolume: true,
                    honorCancellation: false
                )
                results.append(ReviewMetadataWriteResult(
                    assetID: asset.id,
                    error: nil,
                    fingerprintAfter: asset.fingerprint,
                    warning: nil,
                    ratingIsExplicit: nil
                ))
            } catch {
                results.append(ReviewMetadataWriteResult(
                    assetID: asset.id,
                    error: String(describing: error),
                    fingerprintAfter: nil,
                    warning: nil,
                    ratingIsExplicit: nil
                ))
                if Task<Never, Never>.isCancelled {
                    results.append(contentsOf: assets.dropFirst(index + 1).map {
                        ReviewMetadataWriteResult(
                            assetID: $0.id,
                            error: "保存は開始されませんでした（ユーザーによる中止）",
                            fingerprintAfter: nil,
                            warning: nil,
                            ratingIsExplicit: nil
                        )
                    })
                    break
                }
            }
        }
        return results
    }

    private func scanReviewSource(_ requestedURL: URL) {
        guard reviewScanAdmissionAllowed else {
            reviewStatusMessage = "別の処理が実行中のため、アーカイブをスキャンできません"
            return
        }
        reviewScanTask?.cancel()
        reviewMetadataTask?.cancel()
        reviewMetadataAttempt = UUID()
        reviewMetadataWriteAttempt = UUID()
        let generation = UUID()
        reviewScanGeneration = generation
        invalidateReviewSourceStateForScan(requestedURL: requestedURL)
        reviewIsScanning = true
        reviewMetadataIsLoading = false
        reviewMetadataTask = nil
        reviewStatusMessage = "アーカイブの安全性とボリューム同一性を確認しています"
        let policy = Self.reviewMediaScanPolicy()

        reviewScanTask = Task { [weak self] in
            do {
                let initialIdentity = try await Self.captureReviewSourceIdentity(requestedURL)
                guard let self,
                      !Task.isCancelled,
                      reviewScanGeneration == generation else { return }
                guard !initialIdentity.isRemovable else {
                    throw ReviewSourceValidationError.removableMedia
                }
                if let sourceURL, Self.pathsOverlap(initialIdentity.rootURL, sourceURL) {
                    throw ReviewSourceValidationError.overlapsIngestSource
                }
                if sourceURL == nil,
                   let mountURL = activeSourceIdentity?.mountURL,
                   Self.pathsOverlap(initialIdentity.rootURL, mountURL) {
                    throw ReviewSourceValidationError.overlapsIngestSource
                }

                let canonicalPath = initialIdentity.rootURL.path
                let volumeID = if reviewSourceRootPath != canonicalPath
                    || reviewSourceRootDevice != initialIdentity.rootDevice
                    || reviewSourceRootInode != initialIdentity.rootInode
                    || reviewSourceVolumeUUID != initialIdentity.volumeUUID {
                    SourceVolumeID()
                } else {
                    reviewSourceVolumeID
                }
                reviewStatusMessage = "アーカイブ内の写真・動画・RAW・音声を読み込んでいます"

                let result = try await MediaScanner().scan(
                    root: initialIdentity.rootURL,
                    sourceVolumeID: volumeID,
                    policy: policy
                )
                let finalIdentity = try await Self.captureReviewSourceIdentity(result.root)
                guard Self.isSameReviewSource(initialIdentity, finalIdentity),
                      !finalIdentity.isRemovable else {
                    throw ReviewSourceValidationError.identityChanged
                }
                let committedRootURL = try Self.committedReviewRootURL(
                    scanResultRoot: result.root,
                    validatedIdentityRoot: finalIdentity.rootURL
                )
                let recoveryInspection = await Self.inspectMetadataRecoveries(
                    sourceIdentity: finalIdentity
                )
                guard !Task.isCancelled,
                      reviewScanGeneration == generation else { return }

                let primaryAssets = result.assets.filter { $0.kind != .sidecar }
                let unsupportedPaths = Self.unsupportedReviewRegularFilePaths(in: result.inventory)
                // MediaScanner canonicalizes with POSIX realpath, while Foundation can spell the
                // same temporary hierarchy as `/tmp` instead of `/private/tmp`. The mutation
                // context must retain the exact URL representation that was validated into
                // `finalIdentity`; otherwise its first fresh identity check fails despite pointing
                // at the same inode.
                reviewSourceURL = committedRootURL
                reviewSourceVolumeID = volumeID
                reviewSourceRootPath = canonicalPath
                reviewSourceRootDevice = finalIdentity.rootDevice
                reviewSourceRootInode = finalIdentity.rootInode
                reviewSourceVolumeUUID = finalIdentity.volumeUUID
                reviewSourceIsReadOnly = finalIdentity.isReadOnly
                reviewSourceIsLocal = finalIdentity.isLocal
                reviewSourceIsEjectable = finalIdentity.isEjectable
                reviewSourceIsInternal = finalIdentity.isInternal
                reviewAssets = primaryAssets.map(AppAsset.init(coreAsset:))
                reviewUnsupportedRegularFileCount = unsupportedPaths.count
                reviewUnsupportedRegularFileSamples = Array(unsupportedPaths.prefix(20))
                adoptReviewScanIssues(from: result)
                reviewSelectedAssetIDs.removeAll()
                reviewRatings.removeAll()
                reviewRatingLoadedAssetIDs.removeAll()
                reviewRatingExplicitAssetIDs.removeAll()
                reviewRatingErrors.removeAll()
                reviewLabelNumbers.removeAll()
                reviewLabelLoadedAssetIDs.removeAll()
                reviewLabelErrors.removeAll()
                reviewMetadataWarnings.removeAll()
                reviewMetadataRecoveryRecords = recoveryInspection.result?.records ?? []
                reviewMetadataRecoveryScanWasTruncated = recoveryInspection.result?.wasTruncated ?? false
                reviewMetadataRecoveryScanError = recoveryInspection.errorMessage
                reviewIsScanning = false
                reviewScanTask = nil
                if reviewAssets.isEmpty {
                    let emptyMessage = reviewMetadataRecoveryBlockReason
                        ?? (unsupportedPaths.isEmpty
                            ? "評価できる素材が見つかりませんでした"
                            : "対応形式の素材がありません（未対応形式 \(unsupportedPaths.count)件）")
                    reviewStatusMessage = reviewStatusIncludingScanIssues(emptyMessage)
                    return
                }
                let loadedMessage = "\(reviewAssets.count)件を読み込みました"
                    + (unsupportedPaths.isEmpty ? "" : "（未対応形式 \(unsupportedPaths.count)件は表示対象外）")
                    + "。既存の評価とFinderカラーを確認しています"
                reviewStatusMessage = reviewStatusIncludingScanIssues(loadedMessage)
                loadReviewMetadata(for: reviewAssets, generation: generation)
            } catch is CancellationError {
                guard let self, reviewScanGeneration == generation else { return }
                reviewIsScanning = false
                reviewScanTask = nil
                reviewStatusMessage = "アーカイブの読み込みを中止しました"
            } catch {
                guard let self, reviewScanGeneration == generation else { return }
                reviewIsScanning = false
                reviewScanTask = nil
                reviewStatusMessage = "アーカイブを読み込めませんでした: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func committedReviewRootURL(
        scanResultRoot: URL,
        validatedIdentityRoot: URL
    ) throws -> URL {
        guard scanResultRoot.standardizedFileURL
            == validatedIdentityRoot.standardizedFileURL else {
            throw ReviewSourceValidationError.identityChanged
        }
        return validatedIdentityRoot
    }

    /// Accepting a new source is a security-boundary transition, not a cosmetic folder change.
    /// The previous archive's frozen identity, inventory, selection, and metadata must become
    /// unusable before the asynchronous validation of the requested folder starts. Otherwise a
    /// failed scan could expose the old selection again and let an operator mutate the wrong
    /// archive while believing the new folder was active.
    func invalidateReviewSourceStateForScan(requestedURL: URL) {
        reviewSourceURL = requestedURL.standardizedFileURL
        reviewSourceVolumeID = SourceVolumeID()
        reviewSourceRootPath = nil
        reviewSourceRootDevice = nil
        reviewSourceRootInode = nil
        reviewSourceVolumeUUID = nil
        reviewSourceIsReadOnly = nil
        reviewSourceIsLocal = false
        reviewSourceIsEjectable = true
        reviewSourceIsInternal = false

        reviewAssets = []
        reviewSelectedAssetIDs.removeAll()
        reviewRatings.removeAll()
        reviewRatingLoadedAssetIDs.removeAll()
        reviewRatingExplicitAssetIDs.removeAll()
        reviewRatingErrors.removeAll()
        reviewLabelNumbers.removeAll()
        reviewLabelLoadedAssetIDs.removeAll()
        reviewLabelErrors.removeAll()
        reviewMetadataWarnings.removeAll()
        reviewMetadataRecoveryRecords = []
        reviewMetadataRecoveryScanWasTruncated = false
        reviewMetadataRecoveryScanError = nil
        reviewUnsupportedRegularFileCount = 0
        reviewUnsupportedRegularFileSamples = []
        reviewScanIssueCount = 0
        reviewScanIssueSamples = []
        previewAsset = nil
    }

    private func loadReviewMetadata(for assets: [AppAsset], generation: UUID) {
        reviewMetadataTask?.cancel()
        guard let context = reviewMutationContext else {
            let reason = "アーカイブの同一性を確認できないため再スキャンが必要です"
            reviewRatingLoadedAssetIDs.removeAll()
            reviewLabelLoadedAssetIDs.removeAll()
            reviewRatingErrors = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, reason) })
            reviewLabelErrors = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, reason) })
            reviewMetadataIsLoading = false
            reviewStatusMessage = reason
            return
        }
        reviewRatings.removeAll()
        reviewRatingLoadedAssetIDs.removeAll()
        reviewRatingExplicitAssetIDs.removeAll()
        reviewRatingErrors.removeAll()
        reviewLabelNumbers.removeAll()
        reviewLabelLoadedAssetIDs.removeAll()
        reviewLabelErrors.removeAll()
        reviewMetadataWarnings.removeAll()
        let attempt = UUID()
        reviewMetadataAttempt = attempt
        reviewMetadataIsLoading = true
        reviewMetadataTask = Task { [weak self] in
            do {
                let results = try await Self.readReviewMetadataBounded(
                    assets,
                    context: context
                )
                guard let self,
                      !Task.isCancelled,
                      reviewScanGeneration == generation,
                      reviewMetadataAttempt == attempt else { return }
                reviewRatings = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                    guard result.ratingErrors.isEmpty else { return nil }
                    return result.rating.map { (result.assetID, $0) }
                })
                reviewRatingLoadedAssetIDs = Set(results.compactMap { result in
                    result.rating != nil && result.ratingErrors.isEmpty ? result.assetID : nil
                })
                reviewRatingExplicitAssetIDs = Set(results.compactMap { result in
                    result.ratingIsExplicit == true && result.ratingErrors.isEmpty
                        ? result.assetID
                        : nil
                })
                reviewRatingErrors = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                    result.ratingErrors.isEmpty
                        ? nil
                        : (result.assetID, result.ratingErrors.joined(separator: "\n"))
                })
                reviewLabelNumbers = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                    guard result.labelErrors.isEmpty else { return nil }
                    return result.labelNumber.map { (result.assetID, $0) }
                })
                reviewLabelLoadedAssetIDs = Set(results.compactMap { result in
                    result.labelNumber != nil && result.labelErrors.isEmpty ? result.assetID : nil
                })
                reviewLabelErrors = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                    result.labelErrors.isEmpty
                        ? nil
                        : (result.assetID, result.labelErrors.joined(separator: "\n"))
                })
                reviewMetadataWarnings = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                    result.warnings.isEmpty ? nil : (result.assetID, result.warnings.joined(separator: "\n"))
                })
                reviewMetadataIsLoading = false
                reviewMetadataTask = nil
                if let reviewMetadataRecoveryBlockReason {
                    reviewStatusMessage = reviewStatusIncludingScanIssues(
                        "\(results.count)件を読み込みました。\(reviewMetadataRecoveryBlockReason)"
                    )
                } else if !reviewMetadataErrorIDs.isEmpty,
                          !reviewMetadataWarnings.isEmpty {
                    reviewStatusMessage = reviewStatusIncludingScanIssues(
                        "\(results.count)件を読み込み、エラー\(reviewMetadataErrorIDs.count)件・Adobe sidecar互換性の注意\(reviewMetadataWarnings.count)件があります"
                    )
                } else if !reviewMetadataErrorIDs.isEmpty {
                    reviewStatusMessage = reviewStatusIncludingScanIssues(
                        "\(results.count)件を読み込み、\(reviewMetadataErrorIDs.count)件はメタデータの確認が必要です"
                    )
                } else if !reviewMetadataWarnings.isEmpty {
                    reviewStatusMessage = reviewStatusIncludingScanIssues(
                        "\(results.count)件を読み込み、\(reviewMetadataWarnings.count)件はAdobe sidecar互換性が未検証です"
                    )
                } else {
                    reviewStatusMessage = reviewStatusIncludingScanIssues(
                        "\(results.count)件の評価とFinderカラーを読み込みました"
                    )
                }
            } catch is CancellationError {
                guard let self,
                      reviewScanGeneration == generation,
                      reviewMetadataAttempt == attempt else { return }
                reviewMetadataIsLoading = false
                reviewMetadataTask = nil
                reviewStatusMessage = "メタデータの読み込みを中止しました"
            } catch {
                guard let self,
                      reviewScanGeneration == generation,
                      reviewMetadataAttempt == attempt else { return }
                reviewMetadataIsLoading = false
                reviewMetadataTask = nil
                reviewStatusMessage = "メタデータを読み込めませんでした: \(error.localizedDescription)"
            }
        }
    }

    private nonisolated static func readReviewMetadataBounded(
        _ assets: [AppAsset],
        context: ReviewMutationContext,
        maximumConcurrentTasks: Int = 8
    ) async throws -> [ReviewMetadataLoadResult] {
        guard !assets.isEmpty else { return [] }
        var iterator = assets.makeIterator()
        var results: [ReviewMetadataLoadResult] = []
        results.reserveCapacity(assets.count)
        return try await withThrowingTaskGroup(of: ReviewMetadataLoadResult.self) { group in
            func enqueueNext() -> Bool {
                guard let asset = iterator.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    let ratingService = AdobeXMPRatingService()
                    let labelService = FinderColorLabelService()
                    var rating: AdobeRating?
                    var ratingIsExplicit: Bool?
                    var labelNumber: Int?
                    var ratingErrors: [String] = []
                    var labelErrors: [String] = []
                    var warnings: [String] = []
                    var boundaryIsValid = true
                    do {
                        try await validateReviewAsset(
                            asset,
                            context: context,
                            requiresWritableVolume: false
                        )
                    } catch {
                        let message = String(describing: error)
                        ratingErrors.append(message)
                        labelErrors.append(message)
                        boundaryIsValid = false
                    }
                    try Task.checkCancellation()
                    if boundaryIsValid {
                        let lease: ReviewFileAccessLease
                        do {
                            lease = try ReviewFileAccessLease(
                                rootURL: context.sourceIdentity.rootURL,
                                rootDevice: context.sourceIdentity.rootDevice,
                                rootInode: context.sourceIdentity.rootInode,
                                fileURL: asset.url,
                                expectedFingerprint: asset.fingerprint
                            )
                        } catch {
                            let message = String(describing: error)
                            ratingErrors.append(message)
                            labelErrors.append(message)
                            return ReviewMetadataLoadResult(
                                assetID: asset.id,
                                rating: nil,
                                ratingIsExplicit: nil,
                                labelNumber: nil,
                                ratingErrors: ratingErrors,
                                labelErrors: labelErrors,
                                warnings: warnings
                            )
                        }
                        do {
                            let preflightPlan = try lease.withMetadataCapability(
                                expectedFingerprint: asset.fingerprint
                            ) { parentDescriptor, leafName in
                                try ratingService.coordinationPlan(
                                    parentFileDescriptor: parentDescriptor,
                                    mediaLeafName: leafName,
                                    displayURL: asset.url,
                                    expectedFingerprint: asset.fingerprint,
                                    forWriting: false
                                )
                            }
                            let coordinationIntents = preflightPlan.intents.map {
                                ReviewCoordinationIntent(coreIntent: $0)
                            }
                            guard let mediaIntentIndex = preflightPlan.intents.firstIndex(where: {
                                $0.url.standardizedFileURL == asset.url.standardizedFileURL
                            }) else {
                                throw UMISCoreError.identityChanged
                            }
                            let read = try ReviewFileCoordinationGate.coordinate(
                                intents: coordinationIntents,
                                frozenRootURL: context.sourceIdentity.rootURL
                            ) { coordinatedURLs in
                                guard coordinatedURLs.indices.contains(mediaIntentIndex) else {
                                    throw UMISCoreError.identityChanged
                                }
                                let coordinatedMediaURL = coordinatedURLs[mediaIntentIndex]
                                let coordinatedLease = try ReviewFileAccessLease(
                                    rootURL: context.sourceIdentity.rootURL,
                                    rootDevice: context.sourceIdentity.rootDevice,
                                    rootInode: context.sourceIdentity.rootInode,
                                    fileURL: coordinatedMediaURL,
                                    expectedFingerprint: asset.fingerprint
                                )
                                return try coordinatedLease.withMetadataCapability(
                                    expectedFingerprint: asset.fingerprint
                                ) { parentDescriptor, leafName in
                                    let livePlan = try ratingService.coordinationPlan(
                                        parentFileDescriptor: parentDescriptor,
                                        mediaLeafName: leafName,
                                        displayURL: coordinatedMediaURL,
                                        expectedFingerprint: asset.fingerprint,
                                        forWriting: false
                                    )
                                    guard livePlan == preflightPlan else {
                                        throw AssetMetadataError.concurrentModification(
                                            coordinatedMediaURL.path
                                        )
                                    }
                                    return try ratingService.readRating(
                                        parentFileDescriptor: parentDescriptor,
                                        mediaLeafName: leafName,
                                        displayURL: coordinatedMediaURL,
                                        expectedFingerprint: asset.fingerprint
                                    )
                                }
                            }
                            rating = read.rating
                            ratingIsExplicit = read.hasExplicitRating
                            if read.storage == .compatibilityUnverifiedSidecar {
                                warnings.append(
                                    "この形式はfilename.ext.xmpを使用します。対象Adobe製品での認識は未検証です。"
                                )
                            }
                        } catch {
                            ratingErrors.append(String(describing: error))
                        }
                        do {
                            labelNumber = try ReviewFileCoordinationGate.coordinate(
                                intents: [ReviewCoordinationIntent(url: asset.url, access: .read)],
                                frozenRootURL: context.sourceIdentity.rootURL
                            ) { coordinatedURLs in
                                guard let coordinatedURL = coordinatedURLs.first else {
                                    throw UMISCoreError.identityChanged
                                }
                                let coordinatedLease = try ReviewFileAccessLease(
                                    rootURL: context.sourceIdentity.rootURL,
                                    rootDevice: context.sourceIdentity.rootDevice,
                                    rootInode: context.sourceIdentity.rootInode,
                                    fileURL: coordinatedURL,
                                    expectedFingerprint: asset.fingerprint
                                )
                                return try coordinatedLease.withExpectedFileDescriptor(
                                    expectedFingerprint: asset.fingerprint
                                ) { descriptor in
                                    try labelService.readLabelNumber(
                                        atFileDescriptor: descriptor,
                                        displayURL: coordinatedURL,
                                        expectedFingerprint: asset.fingerprint
                                    )
                                }
                            }
                        } catch {
                            labelErrors.append(String(describing: error))
                        }
                        do {
                            try await validateReviewAsset(
                                asset,
                                context: context,
                                requiresWritableVolume: false
                            )
                        } catch {
                            let message = String(describing: error)
                            ratingErrors.append(message)
                            labelErrors.append(message)
                        }
                    }
                    return ReviewMetadataLoadResult(
                        assetID: asset.id,
                        rating: rating,
                        ratingIsExplicit: ratingIsExplicit,
                        labelNumber: labelNumber,
                        ratingErrors: ratingErrors,
                        labelErrors: labelErrors,
                        warnings: warnings
                    )
                }
                return true
            }

            for _ in 0 ..< min(maximumConcurrentTasks, assets.count) {
                _ = enqueueNext()
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                results.append(result)
                _ = enqueueNext()
            }
            return results
        }
    }

    func applyReviewWriteResults(
        _ results: [ReviewMetadataWriteResult],
        domain: ReviewMetadataDomain,
        rating: AdobeRating? = nil,
        labelNumber: Int? = nil
    ) {
        // Build one index and mutate local value-semantic snapshots. The former implementation did
        // firstIndex plus several @Published subscript writes for every result, making a full-archive
        // batch O(N²) and emitting tens of thousands of UI notifications. Each collection below is
        // now assigned at most once after an O(N + result-count) reduction.
        var nextAssets = reviewAssets
        let assetIndexByID = Dictionary(
            uniqueKeysWithValues: nextAssets.indices.map { (nextAssets[$0].id, $0) }
        )
        var assetsChanged = false
        var nextRatingErrors = reviewRatingErrors
        var nextLabelErrors = reviewLabelErrors
        var nextRatings = reviewRatings
        var nextRatingLoadedIDs = reviewRatingLoadedAssetIDs
        var nextRatingExplicitIDs = reviewRatingExplicitAssetIDs
        var nextLabelNumbers = reviewLabelNumbers
        var nextLabelLoadedIDs = reviewLabelLoadedAssetIDs
        var nextWarnings = reviewMetadataWarnings

        for result in results {
            Self.applyReviewDomainErrorResult(
                result,
                domain: domain,
                ratingErrors: &nextRatingErrors,
                labelErrors: &nextLabelErrors
            )
            if result.succeeded {
                if let fingerprint = result.fingerprintAfter,
                   let index = assetIndexByID[result.assetID] {
                    nextAssets[index].fingerprint = fingerprint
                    nextAssets[index].byteCount = fingerprint.byteSize
                    nextAssets[index].modifiedAt = Date(
                        timeIntervalSince1970: TimeInterval(fingerprint.modifiedSeconds)
                    )
                    assetsChanged = true
                }
                switch domain {
                case .rating:
                    guard let rating else { continue }
                    nextRatings[result.assetID] = rating
                    nextRatingLoadedIDs.insert(result.assetID)
                    if result.ratingIsExplicit == true {
                        nextRatingExplicitIDs.insert(result.assetID)
                    } else {
                        nextRatingExplicitIDs.remove(result.assetID)
                    }
                    Self.applyReviewRatingWarningResult(
                        result,
                        warnings: &nextWarnings
                    )
                case .finderLabel:
                    guard let labelNumber else { continue }
                    nextLabelNumbers[result.assetID] = labelNumber
                    nextLabelLoadedIDs.insert(result.assetID)
                }
            }
        }

        if assetsChanged { reviewAssets = nextAssets }
        switch domain {
        case .rating:
            if nextRatingErrors != reviewRatingErrors { reviewRatingErrors = nextRatingErrors }
            if nextRatings != reviewRatings { reviewRatings = nextRatings }
            if nextRatingLoadedIDs != reviewRatingLoadedAssetIDs {
                reviewRatingLoadedAssetIDs = nextRatingLoadedIDs
            }
            if nextRatingExplicitIDs != reviewRatingExplicitAssetIDs {
                reviewRatingExplicitAssetIDs = nextRatingExplicitIDs
            }
            if nextWarnings != reviewMetadataWarnings { reviewMetadataWarnings = nextWarnings }
        case .finderLabel:
            if nextLabelErrors != reviewLabelErrors { reviewLabelErrors = nextLabelErrors }
            if nextLabelNumbers != reviewLabelNumbers { reviewLabelNumbers = nextLabelNumbers }
            if nextLabelLoadedIDs != reviewLabelLoadedAssetIDs {
                reviewLabelLoadedAssetIDs = nextLabelLoadedIDs
            }
        }
    }

    /// A failed rating mutation cannot disprove a compatibility warning learned by an earlier
    /// successful read/write. Preserve that independent fact until a later successful rating
    /// operation supplies authoritative replacement warning state.
    nonisolated static func applyReviewRatingWarningResult(
        _ result: ReviewMetadataWriteResult,
        warnings: inout [UUID: String]
    ) {
        guard result.succeeded else { return }
        if let warning = result.warning {
            warnings[result.assetID] = warning
        } else {
            warnings.removeValue(forKey: result.assetID)
        }
    }

    nonisolated static func applyReviewDomainErrorResult(
        _ result: ReviewMetadataWriteResult,
        domain: ReviewMetadataDomain,
        ratingErrors: inout [UUID: String],
        labelErrors: inout [UUID: String]
    ) {
        switch domain {
        case .rating:
            if result.succeeded {
                ratingErrors.removeValue(forKey: result.assetID)
            } else {
                ratingErrors[result.assetID] = result.error ?? "不明なXMPエラー"
            }
        case .finderLabel:
            if result.succeeded {
                labelErrors.removeValue(forKey: result.assetID)
            } else {
                labelErrors[result.assetID] = result.error ?? "不明なFinderカラーエラー"
            }
        }
    }

    private func commonValue<Value: Hashable>(
        for selectedIDs: Set<UUID>,
        values: [UUID: Value],
        defaultValue: Value
    ) -> Value? {
        guard let firstID = selectedIDs.first else { return nil }
        let first = values[firstID] ?? defaultValue
        return selectedIDs.allSatisfy { (values[$0] ?? defaultValue) == first } ? first : nil
    }

    private nonisolated static func validateReviewAsset(
        _ asset: AppAsset,
        context: ReviewMutationContext,
        requiresWritableVolume: Bool,
        expectedFingerprint: FileFingerprint? = nil,
        honorCancellation: Bool = true
    ) async throws {
        if honorCancellation { try Task.checkCancellation() }
        let standardizedAssetURL = asset.url.standardizedFileURL
        let currentlyResolvedAssetURL = standardizedAssetURL.resolvingSymlinksInPath()
        guard asset.sourceVolumeID == context.sourceVolumeID,
              standardizedAssetURL == currentlyResolvedAssetURL,
              isSameOrDescendant(currentlyResolvedAssetURL, of: context.sourceIdentity.rootURL) else {
            throw UMISCoreError.identityChanged
        }
        let currentSource = try await captureReviewSourceIdentity(
            context.sourceIdentity.rootURL,
            honorCancellation: honorCancellation
        )
        guard isSameReviewSource(context.sourceIdentity, currentSource),
              !currentSource.isRemovable else {
            throw ReviewSourceValidationError.identityChanged
        }
        if requiresWritableVolume, currentSource.isReadOnly != false {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: context.sourceIdentity.rootURL.path,
                reason: currentSource.isReadOnly == true
                    ? "archive volume is read-only"
                    : "archive volume read-only state is unavailable"
            )
        }
        if requiresWritableVolume, !currentSource.isLocal {
            throw ReviewSourceValidationError.networkArchiveUnsupported
        }
        if requiresWritableVolume,
           currentSource.isEjectable || !currentSource.isInternal {
            throw ReviewSourceValidationError.removableMedia
        }

        let expected = expectedFingerprint ?? asset.fingerprint
        let currentFingerprint = try FileFingerprint.capture(at: asset.url)
        guard currentFingerprint == expected else {
            throw AssetMetadataError.concurrentModification(asset.url.path)
        }
        let assetVolume = try asset.url.resourceValues(forKeys: [
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
        ])
        if requiresWritableVolume {
            guard assetVolume.volumeIsRemovable == false,
                  assetVolume.volumeIsEjectable == false,
                  assetVolume.volumeIsLocal == true,
                  assetVolume.volumeIsInternal == true else {
                throw ReviewSourceValidationError.removableMedia
            }
        }
        if requiresWritableVolume, assetVolume.volumeIsReadOnly != false {
            throw AssetMetadataError.metadataCoordinationFailed(
                path: asset.url.path,
                reason: assetVolume.volumeIsReadOnly == true
                    ? "asset volume is read-only"
                    : "asset volume read-only state is unavailable"
            )
        }
        if honorCancellation { try Task.checkCancellation() }
    }

    private nonisolated static func captureReviewSourceIdentity(
        _ requestedURL: URL,
        honorCancellation: Bool = true
    ) async throws -> ReviewSourceIdentity {
        if honorCancellation { try Task.checkCancellation() }
        let resolved = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeUUIDStringKey,
        ])
        guard values.isDirectory == true else {
            throw ReviewSourceValidationError.notDirectory
        }
        let fingerprint = try FileFingerprint.capture(at: resolved)
        if honorCancellation { try Task.checkCancellation() }
        return ReviewSourceIdentity(
            rootURL: resolved,
            rootDevice: fingerprint.device,
            rootInode: fingerprint.inode,
            volumeUUID: values.volumeUUIDString,
            isReadOnly: values.volumeIsReadOnly,
            isRemovable: values.volumeIsRemovable != false,
            isLocal: values.volumeIsLocal == true,
            isEjectable: values.volumeIsEjectable != false,
            isInternal: values.volumeIsInternal == true
        )
    }

    private nonisolated static func inspectMetadataRecoveries(
        sourceIdentity: ReviewSourceIdentity,
        honorCancellation: Bool = true
    ) async -> ReviewRecoveryInspectionOutcome {
        let inspectionTask = Task.detached(priority: .utility) {
            do {
                if honorCancellation { try Task.checkCancellation() }
                let descriptor = sourceIdentity.rootURL.withUnsafeFileSystemRepresentation {
                    path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw UMISCoreError.posix(
                        operation: "open metadata-recovery root",
                        code: errno,
                        path: sourceIdentity.rootURL.path
                    )
                }
                defer { Darwin.close(descriptor) }
                var before = stat()
                guard Darwin.fstat(descriptor, &before) == 0,
                      (before.st_mode & S_IFMT) == S_IFDIR,
                      UInt64(before.st_dev) == sourceIdentity.rootDevice,
                      UInt64(before.st_ino) == sourceIdentity.rootInode else {
                    throw ReviewSourceValidationError.identityChanged
                }
                let result = try MetadataRecoveryInspector().scanTree(
                    rootFileDescriptor: descriptor,
                    displayRootURL: sourceIdentity.rootURL,
                    isCancelled: {
                        honorCancellation && Task<Never, Never>.isCancelled
                    }
                )
                if honorCancellation { try Task.checkCancellation() }
                var after = stat()
                let pathFingerprint = try FileFingerprint.capture(at: sourceIdentity.rootURL)
                guard Darwin.fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino,
                      pathFingerprint.device == sourceIdentity.rootDevice,
                      pathFingerprint.inode == sourceIdentity.rootInode else {
                    throw ReviewSourceValidationError.identityChanged
                }
                return ReviewRecoveryInspectionOutcome(result: result, errorMessage: nil)
            } catch is CancellationError {
                return ReviewRecoveryInspectionOutcome(
                    result: nil,
                    errorMessage: "保護データの検査を中止しました"
                )
            } catch {
                return ReviewRecoveryInspectionOutcome(
                    result: nil,
                    errorMessage: String(describing: error)
                )
            }
        }
        guard honorCancellation else {
            // A safety inspection after a possibly committed mutation is intentionally
            // non-cancellable. The current file boundary includes surfacing its recovery state.
            return await inspectionTask.value
        }
        return await withTaskCancellationHandler {
            await inspectionTask.value
        } onCancel: {
            inspectionTask.cancel()
        }
    }

    /// Takes the single complete recovery inventory required immediately before a rating batch and
    /// keeps Core's root lock alive in the returned opaque authorization. This scan is intentionally
    /// non-cancellable: once the UI enters the mutation boundary it must produce a conclusive
    /// clean/dirty result before any file is allowed to change.
    private nonisolated static func prepareMetadataRecoveryWrite(
        sourceIdentity: ReviewSourceIdentity
    ) async -> ReviewRecoveryWritePreflightOutcome {
        await Task.detached(priority: .utility) {
            do {
                let descriptor = sourceIdentity.rootURL.withUnsafeFileSystemRepresentation {
                    path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else {
                    throw UMISCoreError.posix(
                        operation: "open metadata-recovery write root",
                        code: errno,
                        path: sourceIdentity.rootURL.path
                    )
                }
                defer { Darwin.close(descriptor) }

                var before = stat()
                guard Darwin.fstat(descriptor, &before) == 0,
                      (before.st_mode & S_IFMT) == S_IFDIR,
                      UInt64(before.st_dev) == sourceIdentity.rootDevice,
                      UInt64(before.st_ino) == sourceIdentity.rootInode else {
                    throw ReviewSourceValidationError.identityChanged
                }

                let preflight = try MetadataRecoveryInspector().prepareWriteTree(
                    rootFileDescriptor: descriptor,
                    displayRootURL: sourceIdentity.rootURL,
                    isCancelled: { false }
                )

                var after = stat()
                let pathFingerprint = try FileFingerprint.capture(at: sourceIdentity.rootURL)
                guard Darwin.fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino,
                      pathFingerprint.device == sourceIdentity.rootDevice,
                      pathFingerprint.inode == sourceIdentity.rootInode else {
                    throw ReviewSourceValidationError.identityChanged
                }

                return ReviewRecoveryWritePreflightOutcome(
                    inspection: ReviewRecoveryInspectionOutcome(
                        result: preflight.scanResult,
                        errorMessage: nil
                    ),
                    authorization: preflight.authorization
                )
            } catch {
                return ReviewRecoveryWritePreflightOutcome(
                    inspection: ReviewRecoveryInspectionOutcome(
                        result: nil,
                        errorMessage: String(describing: error)
                    ),
                    authorization: nil
                )
            }
        }.value
    }

    private nonisolated static func isSameReviewSource(
        _ first: ReviewSourceIdentity,
        _ second: ReviewSourceIdentity
    ) -> Bool {
        first.rootURL == second.rootURL
            && first.rootDevice == second.rootDevice
            && first.rootInode == second.rootInode
            && first.volumeUUID == second.volumeUUID
            && first.isReadOnly == second.isReadOnly
            && first.isRemovable == second.isRemovable
            && first.isLocal == second.isLocal
            && first.isEjectable == second.isEjectable
            && first.isInternal == second.isInternal
    }

    private nonisolated static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        isSameOrDescendant(first, of: second) || isSameOrDescendant(second, of: first)
    }

    private nonisolated static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
