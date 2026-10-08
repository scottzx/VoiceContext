import Foundation

@main
struct YimaItemsChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yima-items-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("items.sqlite")
        let store = YimaItemsStore(url: url)
        precondition(store.available)
        let eventID = UUID().uuidString
        let requestID = UUID().uuidString
        let draft = YimaEvent(id: eventID, title: "方案共创机制宣贯", location: "西溪科创园", sourceSessionID: "source-chat")
        try store.createEvent(draft, notice: "5月22日 13:30–14:30，年份未提供", requestID: requestID)
        try store.createEvent(draft, notice: "5月22日 13:30–14:30，年份未提供", requestID: requestID)
        precondition(store.state.events.count == 1 && store.state.meetings.count == 1)
        precondition(store.event(eventID)?.start == nil)
        let meeting = store.state.meetings[0]
        precondition(meeting.eventID == eventID)
        let todo = YimaTodo(id: UUID().uuidString, title: "准备共创机制问题", meetingID: meeting.id, evidence: "用户确认的个人行动")
        try store.createTodo(todo, requestID: todo.id)
        try store.createTodo(todo, requestID: todo.id)
        var completed = todo; completed.completed = true
        try store.updateTodo(completed, expectedRevision: 1)
        precondition(store.todo(todo.id)?.completed == true)
        try rejects { try store.updateTodo(completed, expectedRevision: 1) }
        var changedIntent = draft; changedIntent.title = "另一场会议"
        try rejects { try store.createEvent(changedIntent, notice: "5月22日 13:30–14:30，年份未提供", requestID: requestID) }
        precondition(store.event(eventID)?.title == draft.title)
        var invalid = draft; invalid.start = Date(); invalid.end = invalid.start!.addingTimeInterval(-60)
        try rejects { try store.updateEvent(invalid, expectedRevision: 1) }
        precondition(store.event(eventID)?.revision == 1)
        let start = ISO8601DateFormatter().date(from: "2027-05-22T13:30:00+08:00")!
        var dated = store.event(eventID)!; dated.start = start; dated.end = start.addingTimeInterval(3600)
        try store.updateEvent(dated, expectedRevision: 1)
        precondition(store.state.meetings[0].eventID == eventID && store.state.events.count == 1)
        let recordingID = UUID().uuidString
        try store.linkRecording(recordingID, meetingID: meeting.id)
        try store.linkRecording(recordingID, meetingID: meeting.id)
        precondition(store.meeting(meeting.id)?.recordingIDs == [recordingID])
        try store.migrateRecording(id: recordingID, title: "录音标题", recordedAt: Date())
        precondition(store.state.meetings.count == 1)
        let migrationID = UUID().uuidString
        try store.migrateRecording(id: migrationID, title: "旧会议", recordedAt: Date())
        try store.migrateRecording(id: migrationID, title: "改过的旧标题", recordedAt: Date())
        precondition(store.state.meetings.count == 2)
        precondition(store.state.events.first { $0.meetingID == store.meetingForRecording(migrationID)?.id }?.start == nil)
        let reopened = YimaItemsStore(url: url)
        precondition(reopened.state == store.state)
        // Closing and reopening is checked independently of EventKit/notification access.
        try store.deleteEvent(eventID, expectedRevision: 2)
        precondition(store.todo(todo.id)?.completed == true && store.todo(todo.id)?.meetingID == nil)
        precondition(store.todo(todo.id)?.evidence == todo.evidence)
        precondition(store.event(eventID) == nil)
        try rejects { try store.createEvent(draft, notice: "5月22日 13:30–14:30，年份未提供", requestID: requestID) }
        try store.migrateRecording(id: recordingID, title: "已删会议录音", recordedAt: Date())
        precondition(store.state.meetings.count == 1, "Deleting a meeting must not re-create it on the next recorder refresh")
        // Reject corrupt schema/relationships without replacing the durable snapshot.
        let repository = try YimaItemsRepository(url: directory.appendingPathComponent("validation.sqlite"))
        try rejects { try repository.transact { $0.meetings.append(YimaMeeting(id: UUID().uuidString, eventID: UUID().uuidString)) } }
        precondition(repository.state == YimaItemsState())
        try rejects { try repository.transact { $0.schemaVersion = 2 } }
        precondition(repository.state == YimaItemsState())
        print("Yima local persistence, relationships, revisions, retries, deletion and migration checks passed")
    }
    static func rejects<T>(_ action: () throws -> T) throws {
        do { _ = try action(); fatalError("Expected validation failure") }
        catch is YimaItemsError { }
    }
}
