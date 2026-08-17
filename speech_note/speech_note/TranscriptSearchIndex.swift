import Foundation
import SQLite3

/// One list-row hit from offline transcript search (FR-ADD-SRCH-*).
nonisolated struct TranscriptSearchHit: Equatable, Identifiable, Sendable {
    let recordingID: UUID
    let title: String
    let excerpt: String
    let firstMatchingSegmentID: UUID?

    var id: UUID { recordingID }
}

/// Pure matching / excerpt helpers — unit-tested without SQLite.
nonisolated enum TranscriptSearchEngine {
    struct SegmentRef: Equatable, Sendable {
        let id: UUID
        let text: String
    }

    struct Document: Equatable, Sendable {
        var recordingID: UUID
        var title: String
        var body: String
        var speakers: String
        var tags: String
        var segments: [SegmentRef]
        var revision: Int
    }

    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contains(_ haystack: String, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func matches(_ document: Document, query: String) -> Bool {
        let q = normalizedQuery(query)
        guard !q.isEmpty else { return false }
        return contains(document.title, query: q)
            || contains(document.body, query: q)
            || contains(document.speakers, query: q)
            || contains(document.tags, query: q)
    }

    /// Single-line keyword context for the result list.
    static func excerpt(in text: String, query: String, radius: Int = 28) -> String? {
        let q = normalizedQuery(query)
        guard !q.isEmpty,
              let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }

        let lower = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        while snippet.contains("  ") {
            snippet = snippet.replacingOccurrences(of: "  ", with: " ")
        }
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = lower == text.startIndex ? "" : "…"
        let suffix = upper == text.endIndex ? "" : "…"
        return prefix + snippet + suffix
    }

    static func firstMatchingSegment(in segments: [SegmentRef], query: String) -> UUID? {
        let q = normalizedQuery(query)
        guard !q.isEmpty else { return nil }
        return segments.first { contains($0.text, query: q) }?.id
    }

    static func hit(from document: Document, query: String) -> TranscriptSearchHit? {
        let q = normalizedQuery(query)
        guard matches(document, query: q) else { return nil }

        let excerptText: String
        if let bodyExcerpt = excerpt(in: document.body, query: q) {
            excerptText = bodyExcerpt
        } else if contains(document.title, query: q) {
            excerptText = document.title
        } else if let speakerExcerpt = excerpt(in: document.speakers, query: q) {
            excerptText = "说话人：\(speakerExcerpt)"
        } else if let tagExcerpt = excerpt(in: document.tags, query: q) {
            excerptText = "标签：\(tagExcerpt)"
        } else {
            excerptText = document.title.isEmpty ? "匹配转写内容" : document.title
        }

        let displayTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptSearchHit(
            recordingID: document.recordingID,
            title: displayTitle.isEmpty ? "未命名录音" : displayTitle,
            excerpt: excerptText,
            firstMatchingSegmentID: firstMatchingSegment(in: document.segments, query: q)
        )
    }

    static func document(from transcript: TranscriptDocumentV1) -> Document {
        let segments = transcript.segments.map {
            SegmentRef(id: $0.id, text: $0.text)
        }
        return Document(
            recordingID: transcript.recordingID,
            title: transcript.title ?? "",
            body: segments.map(\.text).joined(separator: "\n"),
            speakers: transcript.speakers.joined(separator: " "),
            tags: transcript.tags.joined(separator: " "),
            segments: segments,
            revision: transcript.revision
        )
    }

    static func titleOnlyDocument(
        recordingID: UUID,
        title: String?,
        revision: Int = 0
    ) -> Document {
        Document(
            recordingID: recordingID,
            title: title ?? "",
            body: "",
            speakers: "",
            tags: "",
            segments: [],
            revision: revision
        )
    }
}

/// Durable offline search index over titles + transcript plain text (+ speakers/tags).
/// Local SQLite only — never uploads documents (FR-ADD-SRCH-004).
nonisolated final class TranscriptSearchIndex: @unchecked Sendable {
    nonisolated enum IndexError: LocalizedError {
        case open(String)
        case execute(sql: String, message: String)

        var errorDescription: String? {
            switch self {
            case let .open(message):
                "无法打开转写搜索索引：\(message)"
            case let .execute(sql, message):
                "转写搜索索引执行失败（\(sql)）：\(message)"
            }
        }
    }

    let url: URL
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    private enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
    }

    init(rootURL: URL) throws {
        let directory = rootURL.appendingPathComponent("Search", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("transcript_search.sqlite")

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw IndexError.open(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
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

    func upsert(document: TranscriptDocumentV1) throws {
        try upsert(TranscriptSearchEngine.document(from: document))
    }

    func upsertTitleOnly(recordingID: UUID, title: String?, updatedAt: Date = Date()) throws {
        var document = TranscriptSearchEngine.titleOnlyDocument(
            recordingID: recordingID,
            title: title
        )
        // Preserve body/speakers/tags/segments when a transcript row already exists.
        if let existing = try loadDocument(recordingID: recordingID) {
            document.body = existing.body
            document.speakers = existing.speakers
            document.tags = existing.tags
            document.segments = existing.segments
            document.revision = existing.revision
        }
        _ = updatedAt
        try upsert(document)
    }

    func remove(recordingID: UUID) throws {
        try lock.withLock {
            try execute(
                "DELETE FROM search_documents WHERE recording_id = ?",
                [.text(recordingID.uuidString)]
            )
        }
    }

    func removeAll(except keep: Set<UUID>) throws {
        try lock.withLock {
            let rows: [UUID] = try query(
                "SELECT recording_id FROM search_documents"
            ) { statement in
                UUID(uuidString: text(statement, 0))
            }
            for id in rows where !keep.contains(id) {
                try execute(
                    "DELETE FROM search_documents WHERE recording_id = ?",
                    [.text(id.uuidString)]
                )
            }
        }
    }

    func search(query: String) throws -> [TranscriptSearchHit] {
        let q = TranscriptSearchEngine.normalizedQuery(query)
        guard !q.isEmpty else { return [] }
        let documents = try allDocuments()
        return documents.compactMap { TranscriptSearchEngine.hit(from: $0, query: q) }
    }

    /// Rebuild / repair from recordings + optional transcript documents.
    func reconcile(
        recordings: [Recording],
        documentFor: (UUID) throws -> TranscriptDocumentV1?
    ) throws {
        var keep = Set<UUID>()
        for recording in recordings {
            keep.insert(recording.id)
            if let document = try documentFor(recording.id) {
                try upsert(document: document)
            } else {
                try upsertTitleOnly(
                    recordingID: recording.id,
                    title: recording.title,
                    updatedAt: recording.updatedAt
                )
            }
        }
        try removeAll(except: keep)
    }

    // MARK: - Private

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS search_documents(
                recording_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                speakers TEXT NOT NULL,
                tags TEXT NOT NULL,
                segments_json TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try execute("PRAGMA user_version = 1")
    }

    private func upsert(_ document: TranscriptSearchEngine.Document) throws {
        let segmentsJSON = try encodeSegments(document.segments)
        try lock.withLock {
            try execute(
                """
                INSERT INTO search_documents(
                    recording_id, title, body, speakers, tags, segments_json, revision, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(recording_id) DO UPDATE SET
                    title = excluded.title,
                    body = excluded.body,
                    speakers = excluded.speakers,
                    tags = excluded.tags,
                    segments_json = excluded.segments_json,
                    revision = excluded.revision,
                    updated_at = excluded.updated_at
                """,
                [
                    .text(document.recordingID.uuidString),
                    .text(document.title),
                    .text(document.body),
                    .text(document.speakers),
                    .text(document.tags),
                    .text(segmentsJSON),
                    .int(Int64(document.revision)),
                    .double(Date().timeIntervalSince1970)
                ]
            )
        }
    }

    private func allDocuments() throws -> [TranscriptSearchEngine.Document] {
        try lock.withLock {
            try query(
                """
                SELECT recording_id, title, body, speakers, tags, segments_json, revision
                FROM search_documents
                """
            ) { statement -> TranscriptSearchEngine.Document? in
                let idText = text(statement, 0)
                guard let recordingID = UUID(uuidString: idText) else { return nil }
                let title = text(statement, 1)
                let body = text(statement, 2)
                let speakers = text(statement, 3)
                let tags = text(statement, 4)
                let segmentsJSON = text(statement, 5)
                let revision = Int(sqlite3_column_int64(statement, 6))
                return TranscriptSearchEngine.Document(
                    recordingID: recordingID,
                    title: title,
                    body: body,
                    speakers: speakers,
                    tags: tags,
                    segments: (try? decodeSegments(segmentsJSON)) ?? [],
                    revision: revision
                )
            }
        }
    }

    private func loadDocument(recordingID: UUID) throws -> TranscriptSearchEngine.Document? {
        try lock.withLock {
            var found: TranscriptSearchEngine.Document?
            try query(
                """
                SELECT recording_id, title, body, speakers, tags, segments_json, revision
                FROM search_documents WHERE recording_id = ?
                """,
                [.text(recordingID.uuidString)]
            ) { statement in
                guard found == nil else { return }
                let idText = text(statement, 0)
                guard let id = UUID(uuidString: idText) else { return }
                let segmentsJSON = text(statement, 5)
                found = TranscriptSearchEngine.Document(
                    recordingID: id,
                    title: text(statement, 1),
                    body: text(statement, 2),
                    speakers: text(statement, 3),
                    tags: text(statement, 4),
                    segments: (try? decodeSegments(segmentsJSON)) ?? [],
                    revision: Int(sqlite3_column_int64(statement, 6))
                )
            }
            return found
        }
    }

    private struct SegmentDTO: Codable {
        let id: String
        let text: String
    }

    private func encodeSegments(_ segments: [TranscriptSearchEngine.SegmentRef]) throws -> String {
        let payload = segments.map { SegmentDTO(id: $0.id.uuidString, text: $0.text) }
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeSegments(_ json: String) throws -> [TranscriptSearchEngine.SegmentRef] {
        guard let data = json.data(using: .utf8) else { return [] }
        let payload = try JSONDecoder().decode([SegmentDTO].self, from: data)
        return payload.compactMap { dto in
            guard let id = UUID(uuidString: dto.id) else { return nil }
            return TranscriptSearchEngine.SegmentRef(id: id, text: dto.text)
        }
    }

    private nonisolated(unsafe) static let sqliteTransient =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query(
        _ sql: String,
        _ values: [Value] = [],
        map: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                try map(statement)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw IndexError.execute(sql: sql, message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func query<T>(
        _ sql: String,
        _ values: [Value] = [],
        map: (OpaquePointer) throws -> T?
    ) throws -> [T] {
        var results: [T] = []
        try query(sql, values) { statement in
            if let value = try map(statement) {
                results.append(value)
            }
        }
        return results
    }


    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func bind(_ statement: OpaquePointer, _ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text):
                sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
            case let .int(number):
                sqlite3_bind_int64(statement, index, number)
            case let .double(number):
                sqlite3_bind_double(statement, index, number)
            }
        }
    }
}
