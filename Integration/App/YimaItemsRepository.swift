import Foundation
import SQLite3

nonisolated struct YimaEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var location = ""
    var notes = ""
    var start: Date?
    var end: Date?
    var timeZone = TimeZone.current.identifier
    var meetingID: String?
    var sourceSessionID: String?
    var evidence = ""
    var revision = 1
}

nonisolated struct YimaMeeting: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var eventID: String
    var notice = ""
    var recordingIDs: [String] = []
}

nonisolated struct YimaTodo: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var notes = ""
    var due: Date?
    var completed = false
    var meetingID: String?
    var sourceSessionID: String?
    var evidence = ""
    var revision = 1
}

nonisolated struct YimaItemsState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var events: [YimaEvent] = []
    var meetings: [YimaMeeting] = []
    var todos: [YimaTodo] = []
    // Kept after deletion: a retried creation must never resurrect an item.
    var requests: [String: YimaCreationReceipt] = [:]
}

nonisolated struct YimaCreationReceipt: Codable, Equatable, Sendable {
    var id: String
    var payload: Data
}

nonisolated enum YimaItemsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// A single durable snapshot keeps the small personal lists and their relationships
/// atomic. SQLite owns the transaction; recorder and chat storage remain independent.
nonisolated final class YimaItemsRepository {
    static let calendarSourceID = "yima:calendar"
    static let todoSourceID = "yima:todos"
    private var db: OpaquePointer?
    private(set) var state: YimaItemsState

    init(url: URL) throws {
        state = YimaItemsState()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM items WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw YimaItemsError.invalid("本地事项资料无法读取。") }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                state = try decoder.decode(YimaItemsState.self, from: data)
                try validate(state)
            } else if result != SQLITE_DONE { throw failure() }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    func transact(_ change: (inout YimaItemsState) throws -> Void) throws {
        var next = state
        try change(&next)
        try validate(next)
        let data = try Self.encode(next)
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO items(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            let bound = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
            state = next
        } catch { try? execute("ROLLBACK"); throw error }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func validate(_ state: YimaItemsState) throws {
        guard state.schemaVersion == 1 else { throw YimaItemsError.invalid("本地事项版本不受支持，请升级应用。") }
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count && ids.allSatisfy { UUID(uuidString: $0) != nil } }
        guard unique(state.events.map(\.id)), unique(state.meetings.map(\.id)), unique(state.todos.map(\.id)) else { throw YimaItemsError.invalid("本地事项标识重复或无效。") }
        for event in state.events {
            guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.revision > 0, TimeZone(identifier: event.timeZone) != nil,
                  (event.start == nil && event.end == nil) || (event.start != nil && event.end != nil && event.end! > event.start!) else {
                throw YimaItemsError.invalid("请填写标题和有效起止时间，或将日程设为时间待确认。")
            }
            if let id = event.meetingID {
                guard state.meetings.contains(where: { $0.id == id && $0.eventID == event.id }) else { throw YimaItemsError.invalid("会议日程关联无效。") }
            }
        }
        for meeting in state.meetings {
            guard state.events.contains(where: { $0.id == meeting.eventID && $0.meetingID == meeting.id }),
                  Set(meeting.recordingIDs).count == meeting.recordingIDs.count else { throw YimaItemsError.invalid("每场会议必须关联一个日程。") }
        }
        let recordings = state.meetings.flatMap(\.recordingIDs)
        guard Set(recordings).count == recordings.count, recordings.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw YimaItemsError.invalid("同一录音已关联另一会议。") }
        for todo in state.todos {
            guard !todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, todo.revision > 0,
                  todo.meetingID == nil || state.meetings.contains(where: { $0.id == todo.meetingID }) else { throw YimaItemsError.invalid("待办标题或会议关联无效。") }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> Error {
        YimaItemsError.invalid("本地事项保存失败：" + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"))
    }
}
