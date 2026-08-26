import Foundation
import SQLite3

struct MediaCacheIndexDatabaseFailure: Error, Sendable {
    enum Reason: Sendable {
        case sqlite(Int32)
        case newerSchema(Int)
    }

    let reason: Reason

    var canRebuildDerivedIndex: Bool {
        switch reason {
        case let .sqlite(code):
            let primaryCode = code & 0xff
            return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
        case .newerSchema:
            return true
        }
    }

    var pipelineFailure: MediaPipelineFailure {
        switch reason {
        case let .sqlite(code):
            MediaPipelineFailure(.cacheIO, diagnostic: "sqlite code \(code)")
        case .newerSchema:
            MediaPipelineFailure(.cacheIO, diagnostic: "cache schema newer")
        }
    }
}

struct MediaCacheIndexRecord: Sendable {
    let key: String
    let kind: MediaCacheKind
    let filename: String
    let byteSize: Int64
    let createdAt: Date
    let lastAccessAt: Date
    let lastAccessSequence: UInt64
    let fingerprintDigest: String
    let pipelineVersion: Int
    let generationMethod: MediaGenerationMethod
    let isFallback: Bool
    let fallbackReason: MediaFailureCode?
    let requestedTimeSeconds: Double?
    let actualTimeSeconds: Double?
}

/// SQLite is touched only by `MediaDiskCache`, its single-writer actor. FULLMUTEX is
/// retained as defense in depth for teardown and future diagnostics tooling.
final class MediaCacheIndexDatabase: @unchecked Sendable {
    static let schemaVersion = 1

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard openCode == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw Self.failure(openCode)
        }
        database = connection
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, 2_500)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA temp_store=MEMORY")
            try migrate()
        } catch {
            sqlite3_close_v2(connection)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func loadAll() throws -> [MediaCacheIndexRecord] {
        let sql = """
        SELECT cache_key, kind, filename, byte_size, created_at, last_access_at,
               last_access_sequence, fingerprint_digest, pipeline_version,
               generation_method, is_fallback, fallback_reason,
               requested_time_seconds, actual_time_seconds
        FROM media_cache_entries
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var records: [MediaCacheIndexRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return records }
            guard code == SQLITE_ROW else { throw Self.failure(code) }
            guard let key = text(statement, 0),
                  let kindText = text(statement, 1),
                  let kind = MediaCacheKind(rawValue: kindText),
                  let filename = text(statement, 2),
                  let fingerprint = text(statement, 7),
                  let methodText = text(statement, 9),
                  let method = MediaGenerationMethod(rawValue: methodText)
            else {
                // A malformed derived row is omitted and removed by startup replaceAll.
                continue
            }
            let sequenceValue = sqlite3_column_int64(statement, 6)
            let fallbackReason = text(statement, 11).flatMap(MediaFailureCode.init(rawValue:))
            records.append(MediaCacheIndexRecord(
                key: key,
                kind: kind,
                filename: filename,
                byteSize: sqlite3_column_int64(statement, 3),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                lastAccessAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                lastAccessSequence: UInt64(max(0, sequenceValue)),
                fingerprintDigest: fingerprint,
                pipelineVersion: Int(sqlite3_column_int64(statement, 8)),
                generationMethod: method,
                isFallback: sqlite3_column_int64(statement, 10) != 0,
                fallbackReason: fallbackReason,
                requestedTimeSeconds: optionalDouble(statement, 12),
                actualTimeSeconds: optionalDouble(statement, 13)
            ))
        }
    }

    func apply(
        upserts: [MediaCacheIndexRecord],
        deletions: Set<String>
    ) throws {
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        try transaction {
            if !deletions.isEmpty {
                let statement = try prepare("DELETE FROM media_cache_entries WHERE cache_key = ?")
                defer { sqlite3_finalize(statement) }
                for key in deletions.sorted() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(key, to: statement, at: 1)
                    try expectDone(statement)
                }
            }
            if !upserts.isEmpty {
                let statement = try prepare(Self.upsertSQL)
                defer { sqlite3_finalize(statement) }
                for record in upserts.sorted(by: { $0.key < $1.key }) {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(record, to: statement)
                    try expectDone(statement)
                }
            }
        }
    }

    func replaceAll(with records: [MediaCacheIndexRecord]) throws {
        try transaction {
            try execute("DELETE FROM media_cache_entries")
            guard !records.isEmpty else { return }
            let statement = try prepare(Self.upsertSQL)
            defer { sqlite3_finalize(statement) }
            for record in records.sorted(by: { $0.key < $1.key }) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(record, to: statement)
                try expectDone(statement)
            }
        }
    }

    func removeAll() throws {
        try execute("DELETE FROM media_cache_entries")
    }

    private func migrate() throws {
        let version = try userVersion()
        guard version <= Self.schemaVersion else {
            throw MediaCacheIndexDatabaseFailure(reason: .newerSchema(version))
        }
        if version == 0 {
            try transaction {
                try execute("""
                CREATE TABLE IF NOT EXISTS media_cache_entries (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
                    created_at REAL NOT NULL,
                    last_access_at REAL NOT NULL,
                    last_access_sequence INTEGER NOT NULL CHECK(last_access_sequence >= 0),
                    fingerprint_digest TEXT NOT NULL,
                    pipeline_version INTEGER NOT NULL,
                    generation_method TEXT NOT NULL,
                    is_fallback INTEGER NOT NULL CHECK(is_fallback IN (0, 1)),
                    fallback_reason TEXT,
                    requested_time_seconds REAL,
                    actual_time_seconds REAL
                )
                """)
                try execute("""
                CREATE INDEX IF NOT EXISTS media_cache_lru
                ON media_cache_entries(kind, last_access_sequence)
                """)
                try execute("PRAGMA user_version=\(Self.schemaVersion)")
            }
        }
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw Self.failure(code) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard code == SQLITE_OK else { throw Self.failure(code) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw Self.failure(code) }
        return statement
    }

    private func expectDone(_ statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw Self.failure(code) }
    }

    private func bind(_ record: MediaCacheIndexRecord, to statement: OpaquePointer?) throws {
        try bind(record.key, to: statement, at: 1)
        try bind(record.kind.rawValue, to: statement, at: 2)
        try bind(record.filename, to: statement, at: 3)
        try check(sqlite3_bind_int64(statement, 4, record.byteSize))
        try check(sqlite3_bind_double(statement, 5, record.createdAt.timeIntervalSince1970))
        try check(sqlite3_bind_double(statement, 6, record.lastAccessAt.timeIntervalSince1970))
        let sequence = Int64(clamping: record.lastAccessSequence)
        try check(sqlite3_bind_int64(statement, 7, sequence))
        try bind(record.fingerprintDigest, to: statement, at: 8)
        try check(sqlite3_bind_int64(statement, 9, Int64(record.pipelineVersion)))
        try bind(record.generationMethod.rawValue, to: statement, at: 10)
        try check(sqlite3_bind_int64(statement, 11, record.isFallback ? 1 : 0))
        try bindOptional(record.fallbackReason?.rawValue, to: statement, at: 12)
        try bindOptional(record.requestedTimeSeconds, to: statement, at: 13)
        try bindOptional(record.actualTimeSeconds, to: statement, at: 14)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, transient))
    }

    private func bindOptional(
        _ value: String?,
        to statement: OpaquePointer?,
        at index: Int32
    ) throws {
        if let value {
            try bind(value, to: statement, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bindOptional(
        _ value: Double?,
        to statement: OpaquePointer?,
        at index: Int32
    ) throws {
        if let value {
            try check(sqlite3_bind_double(statement, index, value))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw Self.failure(code) }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: value)
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private static func failure(_ code: Int32) -> MediaCacheIndexDatabaseFailure {
        MediaCacheIndexDatabaseFailure(reason: .sqlite(code))
    }

    private static let upsertSQL = """
    INSERT INTO media_cache_entries (
        cache_key, kind, filename, byte_size, created_at, last_access_at,
        last_access_sequence, fingerprint_digest, pipeline_version,
        generation_method, is_fallback, fallback_reason,
        requested_time_seconds, actual_time_seconds
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(cache_key) DO UPDATE SET
        kind = excluded.kind,
        filename = excluded.filename,
        byte_size = excluded.byte_size,
        created_at = excluded.created_at,
        last_access_at = excluded.last_access_at,
        last_access_sequence = excluded.last_access_sequence,
        fingerprint_digest = excluded.fingerprint_digest,
        pipeline_version = excluded.pipeline_version,
        generation_method = excluded.generation_method,
        is_fallback = excluded.is_fallback,
        fallback_reason = excluded.fallback_reason,
        requested_time_seconds = excluded.requested_time_seconds,
        actual_time_seconds = excluded.actual_time_seconds
    """
}
