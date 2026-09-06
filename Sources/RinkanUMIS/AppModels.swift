import Foundation
import SwiftUI
import UMISCore

enum WorkspaceRoute: String, CaseIterable, Identifiable, Sendable {
    case ingest
    case review
    case rename
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ingest: "取り込み"
        case .review: "評価・タグ"
        case .rename: "フォルダリネーム"
        case .history: "履歴"
        case .settings: "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .ingest: "square.and.arrow.down"
        case .review: "star.square.on.square"
        case .rename: "character.cursor.ibeam"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum AssetCategory: String, CaseIterable, Codable, Sendable {
    case movie = "動画"
    case photo = "写真"
    case raw = "RAW"
    case audio = "音声"
    case other = "その他"

    var tint: Color {
        switch self {
        case .movie: .blue
        case .photo: .green
        case .raw: .orange
        case .audio: .purple
        case .other: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .movie: "film"
        case .photo: "photo"
        case .raw: "camera.aperture"
        case .audio: "waveform"
        case .other: "doc"
        }
    }
}

struct AppAsset: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let relativePath: String
    var byteCount: Int64
    var modifiedAt: Date
    let category: AssetCategory
    let sourceVolumeID: SourceVolumeID
    var fingerprint: FileFingerprint

    var filename: String { url.lastPathComponent }

    init(coreAsset: MediaAsset) {
        id = coreAsset.id.rawValue
        url = coreAsset.canonicalURL
        relativePath = coreAsset.relativePath
        byteCount = coreAsset.byteSize
        modifiedAt = coreAsset.modifiedAt ?? .distantPast
        category = AssetCategory(coreKind: coreAsset.kind)
        sourceVolumeID = coreAsset.sourceVolumeID
        fingerprint = coreAsset.fingerprint
    }

    init(
        id: UUID,
        url: URL,
        relativePath: String,
        byteCount: Int64,
        modifiedAt: Date,
        category: AssetCategory,
        sourceVolumeID: SourceVolumeID,
        fingerprint: FileFingerprint
    ) {
        self.id = id
        self.url = url
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.category = category
        self.sourceVolumeID = sourceVolumeID
        self.fingerprint = fingerprint
    }

    func matchesBrowserFilter(searchText: String, category filterCategory: AssetCategory?) -> Bool {
        let categoryMatches = filterCategory == nil || category == filterCategory
        let searchMatches = searchText.isEmpty
            || filename.localizedCaseInsensitiveContains(searchText)
            || relativePath.localizedCaseInsensitiveContains(searchText)
        return categoryMatches && searchMatches
    }
}

/// Immutable, revisioned input for the asset browser. Filtering is performed only when the source
/// inventory or filter changes; selection/status updates reuse this snapshot instead of repeatedly
/// walking every asset from multiple SwiftUI computed properties.
struct AssetBrowserProjection: Equatable, Sendable {
    let visibleAssets: [AppAsset]
    let visibleAssetIDs: Set<UUID>
    let revision: UInt64

    static let empty = Self(visibleAssets: [], visibleAssetIDs: [], revision: 0)

    static func make(
        assets: [AppAsset],
        searchText: String,
        category: AssetCategory?,
        revision: UInt64
    ) -> Self {
        var visibleAssets: [AppAsset] = []
        visibleAssets.reserveCapacity(assets.count)
        var visibleAssetIDs = Set<UUID>()
        visibleAssetIDs.reserveCapacity(assets.count)
        for asset in assets where asset.matchesBrowserFilter(
            searchText: searchText,
            category: category
        ) {
            visibleAssets.append(asset)
            visibleAssetIDs.insert(asset.id)
        }
        return Self(
            visibleAssets: visibleAssets,
            visibleAssetIDs: visibleAssetIDs,
            revision: revision
        )
    }
}

private extension AssetCategory {
    init(coreKind: UMISCore.MediaKind) {
        switch coreKind {
        case .movie: self = .movie
        case .photo: self = .photo
        case .rawPhoto: self = .raw
        case .audio: self = .audio
        case .sidecar, .other: self = .other
        }
    }
}

struct AppScene: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var day: Int
    var number: Int
    var name: String
    var codeOverride: String? = nil
    var entityVersion: Int = 1

    var displayName: String {
        day == 0 ? name : "\(code)  \(name)"
    }

    var code: String {
        codeOverride ?? (day == 0 ? "OTHER" : "D\(day)\(String(format: "%02d", number))")
    }
}

struct ActivityRecord: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
        case verified
    }

    let id: UUID
    let startedAt: Date
    let title: String
    let detail: String
    let state: State
    let itemCount: Int
    let totalBytes: Int64
}

/// Stable, non-sensitive classification used by the default audit export. The in-memory activity
/// title is intentionally not serialized: unknown/future titles could contain a path, device name,
/// user name, or backend diagnostic.
enum SessionActivityAuditCategory: String, Codable, Sendable {
    case copyAndRename
    /// Decode compatibility for audit exports created before the selection-copy feature was
    /// removed. New records are never classified into this category.
    case selectionCopy
    case safeEject
    case verifiedIngest
    case ingestFailure
    case ingestResume
    case cardErase
    case ingestCancellation
    case other
}

/// Privacy-preserving projection of an in-memory activity. In particular, this type has no field
/// capable of carrying `ActivityRecord.title` or `ActivityRecord.detail`.
struct RedactedSessionActivityRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let category: SessionActivityAuditCategory
    let state: ActivityRecord.State
    let itemCount: Int
    let totalBytes: Int64

    init(redacting record: ActivityRecord) {
        id = record.id
        startedAt = record.startedAt
        category = switch record.title {
        case "フォルダCopy and Rename": .copyAndRename
        case "カード取り出し": .safeEject
        case "検証付き取り込み": .verifiedIngest
        case "取り込み失敗": .ingestFailure
        case "取り込み再開": .ingestResume
        case "カード初期化": .cardErase
        case "取り込み中止": .ingestCancellation
        default: .other
        }
        state = record.state
        itemCount = record.itemCount
        totalBytes = record.totalBytes
    }
}

struct AppAuditReportPrivacy: Codable, Equatable, Sendable {
    let auditEventPayloadsRedacted: Bool
    let sessionActivityTitlesRedacted: Bool
    let sessionActivityDetailsRedacted: Bool
    let localFilesystemPathsIncluded: Bool
    let rawErrorMessagesIncluded: Bool

    static let defaultRedactedExport = AppAuditReportPrivacy(
        auditEventPayloadsRedacted: true,
        sessionActivityTitlesRedacted: true,
        sessionActivityDetailsRedacted: true,
        localFilesystemPathsIncluded: false,
        rawErrorMessagesIncluded: false
    )
}

/// Schema v3 separates audit-chain payload redaction from session-activity redaction. Construction
/// fails if a caller accidentally supplies an audit event carrying its sensitive payload, so the
/// serialized privacy flags cannot overstate what was removed.
struct AppAuditReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let privacy: AppAuditReportPrivacy
    let auditChainVerification: AuditChainVerificationReport
    let operations: [OperationSummary]
    let auditEvents: [AuditEventRecord]
    let sessionActivity: [RedactedSessionActivityRecord]

    init(
        generatedAt: Date,
        auditChainVerification: AuditChainVerificationReport,
        operations: [OperationSummary],
        auditEvents: [AuditEventRecord],
        sessionActivity: [ActivityRecord]
    ) throws {
        guard auditEvents.allSatisfy({ $0.isPayloadRedacted && $0.payload.isEmpty }) else {
            throw UMISCoreError.invalidPlan(
                "The default audit report refuses unredacted audit-event payloads"
            )
        }
        schemaVersion = 3
        self.generatedAt = generatedAt
        privacy = .defaultRedactedExport
        self.auditChainVerification = auditChainVerification
        self.operations = operations
        self.auditEvents = auditEvents
        self.sessionActivity = sessionActivity.map(RedactedSessionActivityRecord.init(redacting:))
    }
}

struct RenamePreviewRow: Identifiable, Hashable, Sendable {
    let id: UUID
    let before: String
    let after: String
    let byteCount: Int64
}

enum WorkspacePhase: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case planning
    case copying(completed: Int, total: Int)
    case verifying(completed: Int, total: Int)
    case ejectingCard
    case erasingCard
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .idle: "待機中"
        case .scanning: "素材をスキャン中"
        case .ready: "素材を読み込み済み"
        case .planning: "コピー計画を確認中"
        case let .copying(completed, total): "コピー中 \(completed) / \(total)"
        case let .verifying(completed, total): "検証中 \(completed) / \(total)"
        case .ejectingCard: "カードを取り出し中"
        case .erasingCard: "カードを初期化中"
        case .completed: "完了"
        case let .failed(message): "失敗: \(message)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .planning, .copying, .verifying, .ejectingCard, .erasingCard: true
        default: false
        }
    }

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }

    /// Item progress is independent of byte size. Unknown totals stay indeterminate, and a stale
    /// or out-of-range callback must never put the native progress bar outside its valid range.
    var progressFraction: Double? {
        switch self {
        case let .copying(completed, total), let .verifying(completed, total):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(completed) / Double(total)))
        default:
            return nil
        }
    }
}
