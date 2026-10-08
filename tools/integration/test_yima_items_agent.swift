import Foundation

// Canonical tool types are supplied by AgentProvider.swift by the test command.
enum AgentBuildIdentity { static let recordingURLScheme = "voicecontext-check" }

@main
struct YimaAgentChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yima-agent-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = YimaItemsStore(url: directory.appendingPathComponent("items.sqlite"))
        func run(_ args: [String: Any]) -> (output: String, success: Bool) {
            YimaItemsAgentTool.execute(args, sessionID: "chat-source", store: store)
        }
        let id = UUID().uuidString
        let request: [String: Any] = ["action": "create", "kind": "event", "request_id": id,
            "title": "会议通知", "as_meeting": true, "notice": "5月22日，无年份"]
        precondition(run(request).success)
        precondition(run(request).success && store.state.events.count == 1)
        precondition(store.event(id)?.start == nil && store.event(id)?.sourceSessionID == "chat-source")
        let receipt = run(["action": "get", "kind": "event", "id": id])
        precondition(receipt.success && receipt.output.contains("voicecontext-check://yima-event/" + id))
        let eventLink = URL(string: "voicecontext-check://yima-event/" + id.lowercased())!
        precondition(YimaItemLink(url: eventLink, scheme: AgentBuildIdentity.recordingURLScheme) == YimaItemLink(id: id, kind: .event))
        for raw in ["voicecontext://yima-event/" + id, "voicecontext-check://unknown/" + id,
                    "voicecontext-check://yima-event/not-a-uuid", "voicecontext-check://yima-event/extra/" + id] {
            precondition(YimaItemLink(url: URL(string: raw)!, scheme: AgentBuildIdentity.recordingURLScheme) == nil)
        }
        precondition(run(["action": "open", "kind": "event", "id": id]).success)
        precondition(store.pendingItem == YimaItemLink(id: id, kind: .event), "Opening must stay queued until a mounted, unlocked UI consumes it")
        store.pendingItem = nil
        var invalid = request; invalid["request_id"] = UUID().uuidString
        invalid["start"] = "05-22 13:30"; invalid["end"] = "05-22 14:30"
        precondition(!run(invalid).success && store.state.events.count == 1)
        invalid["start"] = "2027-05-22T13:30:00+08:00"; invalid["end"] = "2027-05-22T14:30:00+08:00"
        precondition(!run(invalid).success, "Dated creates need an explicit time zone")
        invalid["time_zone"] = "Asia/Shanghai"
        invalid["start"] = "2027-05-22T13:30:00"
        precondition(!run(invalid).success, "Dates must include an explicit UTC offset")
        invalid["start"] = "2027-05-22T13:30:00.000+08:00"
        precondition(run(invalid).success)
        let beforeInvalidDates = store.state
        for raw in ["2027-02-30T13:30:00+08:00", "2027-02-29T13:30:00Z",
                    "2027-04-31T13:30:00+08:00", "2027-13-01T13:30:00Z",
                    "2027-05-22T24:00:00+08:00", "2027-05-22T13:60:00Z",
                    "2027-05-22T13:30:00+08:60", "2027-05-22T13:30:00Z\n"] {
            precondition(!run(["action": "create", "kind": "todo", "request_id": UUID().uuidString,
                               "title": "无效日期", "due": raw]).success, "Invalid date must be rejected: " + raw)
            precondition(store.state == beforeInvalidDates, "A rejected date must not save an item")
        }
        let leapTodoID = UUID().uuidString
        precondition(run(["action": "create", "kind": "todo", "request_id": leapTodoID,
                          "title": "闰年事项", "due": "2028-02-29T13:30:00.125-00:30"]).success)
        let leapTodo = store.todo(leapTodoID)!
        precondition(abs(leapTodo.due!.timeIntervalSince(ISO8601DateFormatter().date(from: "2028-02-29T14:00:00Z")!) - 0.125) < 0.001)
        precondition(!run(["action": "update", "kind": "todo", "id": leapTodoID, "revision": 1,
                           "due": "2027-02-30T13:30:00+08:00"]).success)
        precondition(store.todo(leapTodoID) == leapTodo, "An invalid edit must preserve the original due date and revision")
        precondition(!run(["action": "update", "kind": "event", "id": id, "revision": 1,
                           "start": "2027-02-30T13:30:00+08:00", "end": "2027-03-02T14:30:00+08:00"]).success)
        precondition(store.event(id)?.start == nil && store.event(id)?.revision == 1)
        precondition(!run(["action": "delete", "kind": "event", "id": id]).success)
        precondition(!run(["action": "update", "kind": "event", "id": id, "revision": 99, "title": "stale"]).success)
        let todoID = UUID().uuidString
        let meetingID = store.event(id)!.meetingID!
        precondition(run(["action": "create", "kind": "todo", "request_id": todoID, "title": "会后行动", "meeting_id": meetingID]).success)
        let todoLink = URL(string: "voicecontext-check://yima-todo/" + todoID)!
        precondition(YimaItemLink(url: todoLink, scheme: AgentBuildIdentity.recordingURLScheme)?.kind == .todo)
        precondition(run(["action": "open", "kind": "todo", "id": todoID]).success)
        precondition(store.pendingItem == YimaItemLink(id: todoID, kind: .todo))
        store.pendingItem = nil
        precondition(!run(["action": "complete", "kind": "todo", "id": todoID, "revision": 1]).success)
        precondition(run(["action": "complete", "kind": "todo", "id": todoID, "revision": 1, "completed": true]).success)
        precondition(store.todo(todoID)?.completed == true)
        let listing = run(["action": "list", "kind": "event"])
        precondition(listing.success && !listing.output.contains("requests") && !listing.output.contains("无年份"))
        precondition(run(["action": "delete", "kind": "event", "id": id, "revision": 1]).success)
        precondition(!run(request).success && store.todo(todoID)?.meetingID == nil)
        print("Yima agent dates, source links, intent retries, revision guards and meeting actions passed")
    }
}
