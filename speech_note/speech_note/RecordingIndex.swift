import Foundation
import SQLite3

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class RecordingIndex: @unchecked Sendable {
    nonisolated enum IndexError: LocalizedError {
        case open(String)
        case execute(sql: String, message: String)
        case invalidRow(String)

        var errorDescription: String? {
            switch self {
            case let .open(message):
                "无法打开录音索引：\(message)"
            case let .execute(sql, message):
                "录音索引执行失败（\(sql)）：\(message)"
            case let .invalidRow(message):
                "录音索引包含无效数据：\(message)"
            }
        }
    }

    nonisolated struct PurgeCandidate: Equatable, Sendable {
        let chunkID: UUID
        let recordingID: UUID
        let relativePath: String
    }

    fileprivate enum Value {
        case text(String)
        case double(Double)
        case int(Int64)
        case null
    }

    let url: URL

    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw IndexError.open(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            try query("PRAGMA journal_mode = WAL") { _ in }
            try migrate()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    var schemaVersion: Int {
        lock.withLock {
            Int((try? scalarInt("PRAGMA user_version")) ?? 0)
        }
    }

    @discardableResult
    func apply(_ event: RecordingJournalEvent) throws -> Bool {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute(
                    "INSERT OR IGNORE INTO journal_events(event_id, occurred_at, kind) VALUES (?, ?, ?)",
                    [.text(event.id.uuidString), .double(event.occurredAt.timeIntervalSince1970), .text(event.kind)]
                )
                guard sqlite3_changes(database) > 0 else {
                    try execute("COMMIT")
                    return false
                }

                try applyPayload(event.payload, occurredAt: event.occurredAt)
                try execute("COMMIT")
                return true
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func recording(id: UUID) throws -> Recording? {
        try lock.withLock {
            var result: Recording?
            try query(
                "SELECT id, started_at, ended_at, title, is_meeting, state, retention_expires_at, retention_pinned, updated_at FROM recordings WHERE id = ?",
                [.text(id.uuidString)]
            ) { statement in
                result = try decodeRecording(statement)
            }
            return result
        }
    }

    func recordings(states: Set<RecordingState>? = nil) throws -> [Recording] {
        try lock.withLock {
            var result: [Recording] = []
            try query(
                "SELECT id, started_at, ended_at, title, is_meeting, state, retention_expires_at, retention_pinned, updated_at FROM recordings ORDER BY started_at"
            ) { statement in
                let recording = try decodeRecording(statement)
                if states == nil || states?.contains(recording.state) == true {
                    result.append(recording)
                }
            }
            return result
        }
    }

    func chunks(recordingID: UUID) throws -> [AudioChunk] {
        try lock.withLock {
            var result: [AudioChunk] = []
            try query(
                "SELECT id, recording_id, relative_path, start_sample, end_sample, started_at, ended_at, state, retention_pinned, audio_removed_at FROM audio_chunks WHERE recording_id = ? ORDER BY start_sample",
                [.text(recordingID.uuidString)]
            ) { statement in
                result.append(try decodeChunk(statement))
            }
            return result
        }
    }

    func jobs(recordingID: UUID) throws -> [RecordingJob] {
        try lock.withLock {
            var result: [RecordingJob] = []
            try query(
                "SELECT id, recording_id, kind, state, attempt_count, last_error, created_at, updated_at FROM recording_jobs WHERE recording_id = ? ORDER BY created_at",
                [.text(recordingID.uuidString)]
            ) { statement in
                guard
                    let id = UUID(uuidString: text(statement, 0)),
                    let ownerID = UUID(uuidString: text(statement, 1)),
                    let kind = RecordingJobKind(rawValue: text(statement, 2)),
                    let state = RecordingJobState(rawValue: text(statement, 3))
                else { throw IndexError.invalidRow("recording_jobs") }
                result.append(RecordingJob(
                    id: id,
                    recordingID: ownerID,
                    kind: kind,
                    state: state,
                    attemptCount: Int(sqlite3_column_int64(statement, 4)),
                    lastError: optionalText(statement, 5),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                ))
            }
            return result
        }
    }

    func gaps(recordingID: UUID) throws -> [RecordingGap] {
        try lock.withLock {
            var result: [RecordingGap] = []
            try query(
                "SELECT id, recording_id, reason, start_sample, end_sample, started_at, ended_at FROM recording_gaps WHERE recording_id = ? ORDER BY start_sample",
                [.text(recordingID.uuidString)]
            ) { statement in
                guard
                    let id = UUID(uuidString: text(statement, 0)),
                    let ownerID = UUID(uuidString: text(statement, 1)),
                    let reason = RecordingGapReason(rawValue: text(statement, 2))
                else { throw IndexError.invalidRow("recording_gaps") }
                result.append(RecordingGap(
                    id: id,
                    recordingID: ownerID,
                    reason: reason,
                    startSample: sqlite3_column_int64(statement, 3),
                    endSample: optionalInt(statement, 4),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    endedAt: optionalDate(statement, 6)
                ))
            }
            return result
        }
    }

    func purgeCandidates(at date: Date) throws -> [PurgeCandidate] {
        try lock.withLock {
            var result: [PurgeCandidate] = []
            try query(
                """
                SELECT c.id, c.recording_id, c.relative_path
                FROM audio_chunks c
                JOIN recordings r ON r.id = c.recording_id
                WHERE r.retention_expires_at <= ?
                  AND r.retention_pinned = 0
                  AND c.retention_pinned = 0
                  AND c.audio_removed_at IS NULL
                  AND c.state = 'closed'
                ORDER BY c.started_at
                """,
                [.double(date.timeIntervalSince1970)]
            ) { statement in
                guard
                    let chunkID = UUID(uuidString: text(statement, 0)),
                    let recordingID = UUID(uuidString: text(statement, 1))
                else { throw IndexError.invalidRow("purge candidate") }
                result.append(PurgeCandidate(
                    chunkID: chunkID,
                    recordingID: recordingID,
                    relativePath: text(statement, 2)
                ))
            }
            return result
        }
    }

    var appliedEventCount: Int {
        lock.withLock {
            Int((try? scalarInt("SELECT COUNT(*) FROM journal_events")) ?? 0)
        }
    }

    private func migrate() throws {
        let current = try scalarInt("PRAGMA user_version")
        guard current <= 1 else {
            throw IndexError.open("数据库版本 \(current) 高于当前应用支持的版本 1")
        }
        guard current == 0 else { return }

        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                CREATE TABLE recordings(
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    title TEXT,
                    is_meeting INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    retention_expires_at REAL NOT NULL,
                    retention_pinned INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE audio_chunks(
                    id TEXT PRIMARY KEY NOT NULL,
                    recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL UNIQUE,
                    start_sample INTEGER NOT NULL,
                    end_sample INTEGER NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL NOT NULL,
                    state TEXT NOT NULL,
                    retention_pinned INTEGER NOT NULL DEFAULT 0,
                    audio_removed_at REAL
                )
                """)
            try execute("CREATE INDEX audio_chunks_recording_sample ON audio_chunks(recording_id, start_sample)")
            try execute("""
                CREATE TABLE recording_jobs(
                    id TEXT PRIMARY KEY NOT NULL,
                    recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    state TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    last_error TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try execute("CREATE INDEX recording_jobs_recording_state ON recording_jobs(recording_id, state)")
            try execute("""
                CREATE TABLE recording_gaps(
                    id TEXT PRIMARY KEY NOT NULL,
                    recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    reason TEXT NOT NULL,
                    start_sample INTEGER NOT NULL,
                    end_sample INTEGER,
                    started_at REAL NOT NULL,
                    ended_at REAL
                )
                """)
            try execute("CREATE INDEX recording_gaps_recording_sample ON recording_gaps(recording_id, start_sample)")
            try execute("""
                CREATE TABLE journal_events(
                    event_id TEXT PRIMARY KEY NOT NULL,
                    occurred_at REAL NOT NULL,
                    kind TEXT NOT NULL
                )
                """)
            try execute("PRAGMA user_version = 1")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func applyPayload(_ payload: RecordingJournalPayload, occurredAt: Date) throws {
        switch payload {
        case let .recordingCreated(recording):
            try execute(
                """
                INSERT INTO recordings(id, started_at, ended_at, title, is_meeting, state, retention_expires_at, retention_pinned, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                recording.bindings
            )
        case let .recordingStateChanged(recordingID, state, endedAt):
            try execute(
                "UPDATE recordings SET state = ?, ended_at = COALESCE(?, ended_at), updated_at = ? WHERE id = ?",
                [.text(state.rawValue), endedAt.sqliteValue, .double(occurredAt.timeIntervalSince1970), .text(recordingID.uuidString)]
            )
        case let .chunkClosed(chunk):
            try execute(
                """
                INSERT INTO audio_chunks(id, recording_id, relative_path, start_sample, end_sample, started_at, ended_at, state, retention_pinned, audio_removed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                chunk.bindings
            )
        case let .jobUpserted(job):
            try execute(
                """
                INSERT INTO recording_jobs(id, recording_id, kind, state, attempt_count, last_error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    attempt_count = excluded.attempt_count,
                    last_error = excluded.last_error,
                    updated_at = excluded.updated_at
                """,
                job.bindings
            )
        case let .gapOpened(gap):
            try execute(
                """
                INSERT INTO recording_gaps(id, recording_id, reason, start_sample, end_sample, started_at, ended_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                gap.bindings
            )
        case let .gapClosed(gapID, endSample, endedAt):
            try execute(
                "UPDATE recording_gaps SET end_sample = ?, ended_at = ? WHERE id = ?",
                [.int(endSample), .double(endedAt.timeIntervalSince1970), .text(gapID.uuidString)]
            )
        case let .retentionChanged(recordingID, retention):
            try execute(
                "UPDATE recordings SET retention_expires_at = ?, retention_pinned = ?, updated_at = ? WHERE id = ?",
                [.double(retention.expiresAt.timeIntervalSince1970), .int(retention.isPinned ? 1 : 0), .double(occurredAt.timeIntervalSince1970), .text(recordingID.uuidString)]
            )
        case let .chunkPinChanged(chunkID, isPinned):
            try execute(
                "UPDATE audio_chunks SET retention_pinned = ? WHERE id = ?",
                [.int(isPinned ? 1 : 0), .text(chunkID.uuidString)]
            )
        case let .chunkAudioRemoved(chunkID, removedAt):
            try execute(
                "UPDATE audio_chunks SET state = ?, audio_removed_at = ? WHERE id = ?",
                [.text(AudioChunkState.audioRemoved.rawValue), .double(removedAt.timeIntervalSince1970), .text(chunkID.uuidString)]
            )
        }
    }

    private func decodeRecording(_ statement: OpaquePointer) throws -> Recording {
        guard
            let id = UUID(uuidString: text(statement, 0)),
            let state = RecordingState(rawValue: text(statement, 5))
        else { throw IndexError.invalidRow("recordings") }
        return Recording(
            id: id,
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            endedAt: optionalDate(statement, 2),
            title: optionalText(statement, 3),
            isMeeting: sqlite3_column_int(statement, 4) != 0,
            state: state,
            retention: AudioRetention(
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                isPinned: sqlite3_column_int(statement, 7) != 0
            ),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        )
    }

    private func decodeChunk(_ statement: OpaquePointer) throws -> AudioChunk {
        guard
            let id = UUID(uuidString: text(statement, 0)),
            let recordingID = UUID(uuidString: text(statement, 1)),
            let state = AudioChunkState(rawValue: text(statement, 7))
        else { throw IndexError.invalidRow("audio_chunks") }
        return AudioChunk(
            id: id,
            recordingID: recordingID,
            relativePath: text(statement, 2),
            startSample: sqlite3_column_int64(statement, 3),
            endSample: sqlite3_column_int64(statement, 4),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            state: state,
            isPinned: sqlite3_column_int(statement, 8) != 0,
            audioRemovedAt: optionalDate(statement, 9)
        )
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        guard let database else { throw IndexError.open("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, sql: sql)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query(
        _ sql: String,
        _ values: [Value] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        guard let database else { throw IndexError.open("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, sql: sql)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        var value: Int64 = 0
        try query(sql) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func bind(_ values: [Value], to statement: OpaquePointer, sql: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case let .text(value):
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .double(value):
                sqlite3_bind_double(statement, index, value)
            case let .int(value):
                sqlite3_bind_int64(statement, index, value)
            case .null:
                sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "bind failed"
                throw IndexError.execute(sql: sql, message: message)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
}

private extension RecordingJournalEvent {
    nonisolated var kind: String {
        switch payload {
        case .recordingCreated: "recordingCreated"
        case .recordingStateChanged: "recordingStateChanged"
        case .chunkClosed: "chunkClosed"
        case .jobUpserted: "jobUpserted"
        case .gapOpened: "gapOpened"
        case .gapClosed: "gapClosed"
        case .retentionChanged: "retentionChanged"
        case .chunkPinChanged: "chunkPinChanged"
        case .chunkAudioRemoved: "chunkAudioRemoved"
        }
    }
}

private extension Optional where Wrapped == Date {
    nonisolated var sqliteValue: RecordingIndex.Value {
        map { .double($0.timeIntervalSince1970) } ?? .null
    }
}

private extension Optional where Wrapped == String {
    nonisolated var sqliteValue: RecordingIndex.Value {
        map(RecordingIndex.Value.text) ?? .null
    }
}

private extension Recording {
    nonisolated var bindings: [RecordingIndex.Value] {
        [
            .text(id.uuidString),
            .double(startedAt.timeIntervalSince1970),
            endedAt.sqliteValue,
            title.sqliteValue,
            .int(isMeeting ? 1 : 0),
            .text(state.rawValue),
            .double(retention.expiresAt.timeIntervalSince1970),
            .int(retention.isPinned ? 1 : 0),
            .double(updatedAt.timeIntervalSince1970),
        ]
    }
}

private extension AudioChunk {
    nonisolated var bindings: [RecordingIndex.Value] {
        [
            .text(id.uuidString),
            .text(recordingID.uuidString),
            .text(relativePath),
            .int(startSample),
            .int(endSample),
            .double(startedAt.timeIntervalSince1970),
            .double(endedAt.timeIntervalSince1970),
            .text(state.rawValue),
            .int(isPinned ? 1 : 0),
            audioRemovedAt.sqliteValue,
        ]
    }
}

private extension RecordingJob {
    nonisolated var bindings: [RecordingIndex.Value] {
        [
            .text(id.uuidString),
            .text(recordingID.uuidString),
            .text(kind.rawValue),
            .text(state.rawValue),
            .int(Int64(attemptCount)),
            lastError.sqliteValue,
            .double(createdAt.timeIntervalSince1970),
            .double(updatedAt.timeIntervalSince1970),
        ]
    }
}

private extension RecordingGap {
    nonisolated var bindings: [RecordingIndex.Value] {
        [
            .text(id.uuidString),
            .text(recordingID.uuidString),
            .text(reason.rawValue),
            .int(startSample),
            endSample.map(RecordingIndex.Value.int) ?? .null,
            .double(startedAt.timeIntervalSince1970),
            endedAt.sqliteValue,
        ]
    }
}
