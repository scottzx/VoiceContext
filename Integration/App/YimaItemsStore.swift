import Foundation
import Combine

nonisolated struct YimaItemLink: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case event, todo }
    let id: String
    let kind: Kind

    init(id: String, kind: Kind) { self.id = id; self.kind = kind }

    init?(url: URL, scheme: String) {
        guard url.scheme == scheme, url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        switch url.host {
        case "yima-event": kind = .event
        case "yima-todo": kind = .todo
        default: return nil
        }
        self.id = id.uuidString
    }
}

@MainActor
final class YimaItemsStore: ObservableObject {
    static let shared = YimaItemsStore()
    @Published private(set) var state = YimaItemsState()
    @Published private(set) var failure: String?
    // Kept until the root view consumes it, including cold launches and app locks.
    @Published var pendingItem: YimaItemLink?
    var knownRecordingIDs: Set<String> = []
    var recordingMeetingInProgress: String?
    private var repository: YimaItemsRepository?

    init(url: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            repository = try YimaItemsRepository(url: url ?? root.appendingPathComponent("Yima/items.sqlite"))
            state = repository!.state
        } catch { failure = error.localizedDescription }
    }

    var available: Bool { repository != nil }
    func event(_ id: String) -> YimaEvent? { state.events.first { $0.id == id } }
    func todo(_ id: String) -> YimaTodo? { state.todos.first { $0.id == id } }
    func meeting(_ id: String) -> YimaMeeting? { state.meetings.first { $0.id == id } }
    func meetingForRecording(_ id: String) -> YimaMeeting? { state.meetings.first { $0.recordingIDs.contains(id) } }

    private func commit(_ change: (inout YimaItemsState) throws -> Void) throws {
        guard let repository else { throw YimaItemsError.invalid(failure ?? "本地事项暂不可用。") }
        try repository.transact(change)
        state = repository.state
        NotificationCenter.default.post(name: Notification.Name("Yima.itemsChanged"), object: nil)
    }

    /// requestID is a caller-owned intent, not a title. Different payloads with
    /// the same intent are rejected, including after deletion.
    @discardableResult func createEvent(_ draft: YimaEvent, notice: String? = nil, recordingID: String? = nil, requestID: String) throws -> String {
        let payload = try YimaItemsRepository.encode(EventIntent(event: draft, notice: notice, recordingID: recordingID))
        if let receipt = state.requests[requestID] {
            guard receipt.payload == payload else { throw YimaItemsError.invalid("创建请求已用于其他内容，请先查询原事项。") }
            guard event(receipt.id) != nil else { throw YimaItemsError.invalid("此请求创建的日程已删除，不能重试恢复。") }
            return receipt.id
        }
        let id = draft.id
        try commit { state in
            var event = draft
            if notice != nil || recordingID != nil {
                let meetingID = UUID().uuidString
                event.meetingID = meetingID
                state.meetings.append(YimaMeeting(id: meetingID, eventID: id, notice: notice ?? "", recordingIDs: recordingID.map { [$0] } ?? []))
            }
            state.events.append(event)
            state.requests[requestID] = YimaCreationReceipt(id: id, payload: payload)
        }
        return id
    }

    @discardableResult func createTodo(_ draft: YimaTodo, requestID: String) throws -> String {
        let payload = try YimaItemsRepository.encode(draft)
        if let receipt = state.requests[requestID] {
            guard receipt.payload == payload else { throw YimaItemsError.invalid("创建请求已用于其他内容，请先查询原事项。") }
            guard todo(receipt.id) != nil else { throw YimaItemsError.invalid("此请求创建的待办已删除，不能重试恢复。") }
            return receipt.id
        }
        try commit { state in
            state.todos.append(draft)
            state.requests[requestID] = YimaCreationReceipt(id: draft.id, payload: payload)
        }
        return draft.id
    }

    func updateEvent(_ draft: YimaEvent, expectedRevision: Int) throws {
        try commit { state in
            guard let index = state.events.firstIndex(where: { $0.id == draft.id }), state.events[index].revision == expectedRevision else {
                throw YimaItemsError.invalid("日程已被修改或删除，请重新打开后再保存。")
            }
            guard draft.meetingID == state.events[index].meetingID else { throw YimaItemsError.invalid("不能通过编辑日程改变会议关联。") }
            var updated = draft; updated.revision = expectedRevision + 1
            state.events[index] = updated
        }
    }

    func updateTodo(_ draft: YimaTodo, expectedRevision: Int) throws {
        try commit { state in
            guard let index = state.todos.firstIndex(where: { $0.id == draft.id }), state.todos[index].revision == expectedRevision else {
                throw YimaItemsError.invalid("待办已被修改或删除，请重新打开后再保存。")
            }
            var updated = draft; updated.revision = expectedRevision + 1
            state.todos[index] = updated
        }
    }

    func deleteTodo(_ id: String, expectedRevision: Int) throws {
        try commit { state in
            guard let todo = state.todos.first(where: { $0.id == id }), todo.revision == expectedRevision else { throw YimaItemsError.invalid("待办已改变，请重新打开。") }
            state.todos.removeAll { $0.id == id }
        }
    }

    func deleteEvent(_ id: String, expectedRevision: Int) throws {
        try commit { state in
            guard let event = state.events.first(where: { $0.id == id }), event.revision == expectedRevision else { throw YimaItemsError.invalid("日程已改变，请重新打开。") }
            // Delete the meeting context only on an explicit meeting deletion.
            // Action items survive, with their evidence and source chat retained.
            if let meetingID = event.meetingID {
                state.meetings.removeAll { $0.id == meetingID }
                for index in state.todos.indices where state.todos[index].meetingID == meetingID {
                    state.todos[index].meetingID = nil; state.todos[index].revision += 1
                }
            }
            state.events.removeAll { $0.id == id }
        }
    }

    func linkRecording(_ id: String, meetingID: String) throws {
        try commit { state in
            guard let index = state.meetings.firstIndex(where: { $0.id == meetingID }) else { throw YimaItemsError.invalid("会议已删除。") }
            for previous in state.meetings.indices where previous != index {
                state.meetings[previous].recordingIDs.removeAll { $0 == id }
            }
            if !state.meetings[index].recordingIDs.contains(id) { state.meetings[index].recordingIDs.append(id) }
            // Remember explicit associations after meeting deletion so migration
            // cannot turn the same recording into a new meeting next launch.
            if state.requests["recording:" + id] == nil {
                state.requests["recording:" + id] = YimaCreationReceipt(id: state.meetings[index].eventID, payload: Data())
            }
        }
    }

    func migrateRecording(id: String, title: String, recordedAt: Date) throws {
        guard meetingForRecording(id) == nil, state.requests["recording:" + id] == nil else { return }
        let event = YimaEvent(id: UUID().uuidString, title: title.isEmpty ? "未命名会议" : title,
                              notes: "记录时间：\(recordedAt.formatted())。计划时间待确认。", evidence: "recordingID: " + id)
        try createEvent(event, recordingID: id, requestID: "recording:" + id)
    }
}

private struct EventIntent: Encodable {
    let event: YimaEvent
    let notice: String?
    let recordingID: String?
}
