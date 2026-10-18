import Foundation

@MainActor
enum YimaItemsAgentTool {
    static let definition = AgentToolDefinition(
        name: "yima_items",
        description: "Read and manage Yima's local calendar, meetings and personal todos without EventKit permission. Use for meeting notices and confirmed personal actions. Ask for missing year/time instead of guessing; omit dates for unscheduled items. This does not write Apple system lists or schedule notifications. create requires a new UUID request_id per intent; retry with the same ID and identical payload. For update/complete/delete, first get the item and pass its revision. Delete meeting/event keeps recordings and todos, detaching todos. Return the receipt's actual local state and link. Only create/delete when the user authorizes that specific action.",
        parameters: [
            "tool_title": AgentToolParam(type: .string, description: "Short action summary in the user's language"),
            "action": AgentToolParam(type: .string, description: "Operation", enumValues: ["list", "get", "create", "update", "complete", "delete", "open", "link_recording"]),
            "kind": AgentToolParam(type: .string, description: "Item type", enumValues: ["event", "todo"]),
            "query": AgentToolParam(type: .string, description: "Optional title filter for list. List returns summaries; get reads only the selected item and its meeting context"),
            "id": AgentToolParam(type: .string, description: "Existing item ID from get/list"),
            "request_id": AgentToolParam(type: .string, description: "Creation intent UUID. Also becomes the item's stable ID; reuse only for exact retries"),
            "revision": AgentToolParam(type: .integer, description: "Current revision from get/list, required for update/complete/delete"),
            "title": AgentToolParam(type: .string, description: "Item title; required for create"),
            "notes": AgentToolParam(type: .string, description: "Personal notes"),
            "location": AgentToolParam(type: .string, description: "Event location"),
            "start": AgentToolParam(type: .string, description: "Event start: complete ISO8601 date/time with explicit UTC offset"),
            "end": AgentToolParam(type: .string, description: "Event end: complete ISO8601 date/time with explicit UTC offset, after start"),
            "time_zone": AgentToolParam(type: .string, description: "IANA zone e.g. Asia/Shanghai; required with dated events"),
            "due": AgentToolParam(type: .string, description: "Todo due: complete ISO8601 date/time with explicit UTC offset. No alarm is scheduled"),
            "clear_dates": AgentToolParam(type: .boolean, description: "Explicitly remove dates on update"),
            "as_meeting": AgentToolParam(type: .boolean, description: "Create event as a meeting with one unique calendar event"),
            "notice": AgentToolParam(type: .string, description: "Original meeting notice, stored separately from extracted fields"),
            "meeting_id": AgentToolParam(type: .string, description: "Optional todo's originating meeting ID from list/get"),
            "evidence": AgentToolParam(type: .string, description: "Source excerpt and transcript recordingID/revision/time position; do not invent"),
            "recording_id": AgentToolParam(type: .string, description: "Existing recording UUID to link to an event's meeting"),
            "completed": AgentToolParam(type: .boolean, description: "Explicit completed state for complete; do not toggle blindly")
        ], required: ["tool_title", "action", "kind"]
    )

    static func execute(_ args: [String: Any], sessionID: String?, store: YimaItemsStore? = nil,
                        allowsPresentation: Bool = true) -> (output: String, success: Bool) {
        do {
            let store = store ?? YimaItemsStore.shared
            guard store.available else { throw YimaItemsError.invalid(store.failure ?? "本地事项暂不可用。") }
            guard let kind = args["kind"] as? String, ["event", "todo"].contains(kind), let action = args["action"] as? String else { throw YimaItemsError.invalid("请提供 action 和 kind。") }
            if action == "list" {
                let query = args["query"] as? String ?? ""
                let recordingID = (args["recording_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
                let recordingMeeting = recordingID.flatMap { store.meetingForRecording($0)?.id }
                let events = store.state.events.filter {
                    (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
                    (args["recording_id"] == nil || (recordingMeeting != nil && $0.meetingID == recordingMeeting))
                }
                let todos = store.state.todos.filter {
                    (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
                    (args["recording_id"] == nil || (recordingMeeting != nil && $0.meetingID == recordingMeeting))
                }
                // Do not send unrelated notices, notes or evidence to the model.
                let listing = YimaItemsListing(events: events.map(YimaEventSummary.init), todos: todos.map(YimaTodoSummary.init))
                return (String(decoding: try YimaItemsRepository.encode(listing), as: UTF8.self), true)
            }
            func required(_ key: String) throws -> String {
                guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw YimaItemsError.invalid("缺少参数：" + key) }
                return value
            }
            func date(_ key: String) throws -> Date? {
                guard let raw = args[key] as? String else { return nil }
                guard let value = parseDate(raw) else { throw YimaItemsError.invalid(key + " 必须是含年份与时区的有效完整 ISO8601 时间。") }
                return value
            }
            let creating = action == "create"
            let rawID = try required(creating ? "request_id" : "id")
            guard let uuid = UUID(uuidString: rawID) else { throw YimaItemsError.invalid("事项和创建请求 ID 必须为 UUID。") }
            let id = uuid.uuidString
            if action == "open" {
                guard allowsPresentation else { throw YimaItemsError.invalid("当前入口只返回事项内容，请在手机主动打开详情。") }
                guard (kind == "event" ? store.event(id) != nil : store.todo(id) != nil) else { throw YimaItemsError.invalid("事项不存在。") }
                store.pendingItem = YimaItemLink(id: id, kind: kind == "event" ? .event : .todo)
                return ("已请求打开本地事项 \(id)", true)
            }
            if action == "link_recording" {
                guard kind == "event", let meetingID = store.event(id)?.meetingID else { throw YimaItemsError.invalid("请指定会议日程。") }
                let raw = try required("recording_id")
                guard let recording = UUID(uuidString: raw) else { throw YimaItemsError.invalid("录音 ID 无效。") }
                // Link only known recorder evidence; a guessed UUID is not proof.
                guard store.knownRecordingIDs.contains(recording.uuidString) else { throw YimaItemsError.invalid("找不到该录音，请先从会议录音入口打开资料。") }
                try store.linkRecording(recording.uuidString, meetingID: meetingID)
            } else if action != "get" {
                guard ["create", "update", "complete", "delete"].contains(action) else { throw YimaItemsError.invalid("不支持此操作。") }
                let revision = args["revision"] as? Int
                if !creating && revision == nil { throw YimaItemsError.invalid("修改前请先查询事项并提供 revision。") }
                if kind == "event" {
                    guard action != "complete" else { throw YimaItemsError.invalid("日程没有待办完成状态。") }
                    var draft: YimaEvent
                    if creating { draft = YimaEvent(id: id, title: try required("title"), sourceSessionID: sessionID) }
                    else {
                        guard let current = store.event(id) else { throw YimaItemsError.invalid("日程不存在。") }
                        draft = current
                    }
                    if action == "delete" { try store.deleteEvent(id, expectedRevision: revision!); return ("已删除本地日程 \(id)，录音和行动待办保留。", true) }
                    if let value = args["title"] as? String { draft.title = value }
                    if let value = args["notes"] as? String { draft.notes = value }
                    if let value = args["location"] as? String { draft.location = value }
                    if let value = args["evidence"] as? String { draft.evidence = value }
                    if args["clear_dates"] as? Bool == true { draft.start = nil; draft.end = nil }
                    else {
                        if let value = try date("start") { draft.start = value }
                        if let value = try date("end") { draft.end = value }
                    }
                    if let value = args["time_zone"] as? String { draft.timeZone = value }
                    if creating && draft.start != nil && args["time_zone"] == nil { throw YimaItemsError.invalid("有日期的日程须提供 time_zone。") }
                    if creating {
                        let asMeeting = args["as_meeting"] as? Bool == true
                        try store.createEvent(draft, notice: asMeeting ? (args["notice"] as? String ?? "") : nil, requestID: id)
                    } else { try store.updateEvent(draft, expectedRevision: revision!) }
                } else {
                    var draft: YimaTodo
                    if creating { draft = YimaTodo(id: id, title: try required("title"), sourceSessionID: sessionID) }
                    else {
                        guard let current = store.todo(id) else { throw YimaItemsError.invalid("待办不存在。") }
                        draft = current
                    }
                    if action == "delete" { try store.deleteTodo(id, expectedRevision: revision!); return ("已删除本地待办 \(id)。", true) }
                    if let value = args["title"] as? String { draft.title = value }
                    if let value = args["notes"] as? String { draft.notes = value }
                    if let value = args["evidence"] as? String { draft.evidence = value }
                    if let value = args["meeting_id"] as? String { draft.meetingID = value }
                    if args["clear_dates"] as? Bool == true { draft.due = nil }
                    else if let value = try date("due") { draft.due = value }
                    if action == "complete" {
                        guard let completed = args["completed"] as? Bool else { throw YimaItemsError.invalid("请提供明确的 completed 状态。") }
                        draft.completed = completed
                    }
                    if creating { try store.createTodo(draft, requestID: id) }
                    else { try store.updateTodo(draft, expectedRevision: revision!) }
                }
            }
            let payload: Data
            if kind == "event", let item = store.event(id) { payload = try YimaItemsRepository.encode(YimaEventDetails(event: item, meeting: item.meetingID.flatMap { store.meeting($0) })) }
            else if kind == "todo", let item = store.todo(id) { payload = try YimaItemsRepository.encode(item) }
            else { throw YimaItemsError.invalid("事项不存在。") }
            let host = kind == "event" ? "yima-event" : "yima-todo"
            let link = "\(AgentBuildIdentity.recordingURLScheme)://\(host)/\(id)"
            return ("本地已保存/可查询 · \(kind == "event" ? "Yima日历" : "Yima待办") · 仅本机 · 未写入系统 · 未设置定时通知\n" + String(decoding: payload, as: UTF8.self) + "\n[打开事项](\(link))", true)
        } catch { return ("未能完成：" + error.localizedDescription, false) }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let pattern = "^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"
        let text = raw as NSString
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: raw, range: NSRange(location: 0, length: text.length)),
              match.range.length == text.length else { return nil }
        let values = (1...6).map { Int(text.substring(with: match.range(at: $0)))! }
        let offset = text.substring(with: match.range(at: 7))
        var seconds = 0
        if offset != "Z" {
            let parts = offset.dropFirst().split(separator: ":").map { Int($0)! }
            guard parts[0] < 24, parts[1] < 60 else { return nil }
            seconds = (parts[0] * 3600 + parts[1] * 60) * (offset.hasPrefix("-") ? -1 : 1)
        }
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(calendar: calendar, timeZone: zone, year: values[0], month: values[1],
                                        day: values[2], hour: values[3], minute: values[4], second: values[5])
        // DateFormatter normalizes some impossible dates; validate before parsing.
        guard values[0] > 0, components.isValidDate else { return nil }
        let parser = ISO8601DateFormatter()
        if let date = parser.date(from: raw) { return date }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: raw)
    }
}

private struct YimaItemsListing: Encodable {
    let events: [YimaEventSummary]
    let todos: [YimaTodoSummary]
}

private struct YimaEventDetails: Encodable {
    let event: YimaEvent
    let meeting: YimaMeeting?
}

private struct YimaEventSummary: Encodable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let meetingID: String?
    let revision: Int
    init(_ item: YimaEvent) {
        id = item.id; title = item.title; start = item.start; end = item.end; meetingID = item.meetingID; revision = item.revision
    }
}

private struct YimaTodoSummary: Encodable {
    let id: String
    let title: String
    let due: Date?
    let completed: Bool
    let meetingID: String?
    let revision: Int
    init(_ item: YimaTodo) {
        id = item.id; title = item.title; due = item.due; completed = item.completed; meetingID = item.meetingID; revision = item.revision
    }
}
