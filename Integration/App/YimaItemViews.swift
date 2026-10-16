import SwiftUI
import VoiceRecording

struct YimaItemRequest: Identifiable {
    typealias Kind = YimaItemLink.Kind
    let id: String
    let kind: Kind
    var isNew = false
    var suggestedDate: Date?
    var meetingID: String?
    var asMeeting = false
    static func new(_ kind: Kind, date: Date? = nil, meetingID: String? = nil, asMeeting: Bool = false) -> Self {
        Self(id: UUID().uuidString, kind: kind, isNew: true, suggestedDate: date, meetingID: meetingID, asMeeting: asMeeting)
    }
}

extension View {
    func protectedYimaSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(YimaProtectedSheet(item: item, onDismiss: onDismiss, sheet: content))
    }
}

private struct YimaProtectedSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheet: (Item) -> Sheet
    @ObservedObject private var lock = SessionLockStore.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { lock.appIsLocked ? nil : item },
            set: { value in
                // A lock-driven dismissal keeps the request for the next unlock.
                if value != nil || !lock.appIsLocked { item = value }
            }
        ), onDismiss: {
            if item == nil { onDismiss?() }
        }) { request in
            sheet(request).modifier(YimaSheetPrivacy())
        }
    }
}

private struct YimaSheetPrivacy: ViewModifier {
    @ObservedObject private var lock = SessionLockStore.shared
    func body(content: Content) -> some View {
        let hidden = lock.appIsLocked || lock.showPrivacyScreen
        content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
            .overlay { if hidden { YimaDesign.Color.canvas.ignoresSafeArea() } }
    }
}

struct YimaEventRow: View {
    let event: YimaEvent
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: YimaDesign.Space.md) {
                Image(systemName: event.meetingID == nil ? "calendar" : "person.2")
                    .frame(width: YimaDesign.Layout.hitTarget, height: YimaDesign.Layout.hitTarget).accessibilityHidden(true)
                TaskItemContent(title: event.title, source: AppLocalized("Yima日历")) {
                    if let start = event.start, let end = event.end {
                        TaskEventDateMetadata(start: start, end: end)
                    } else {
                        Text("时间待确认")
                    }
                    if !event.location.isEmpty { Text(event.location) }
                }
            }.foregroundStyle(YimaDesign.Color.ink).padding(.vertical, YimaDesign.Layout.rowPaddingY)
                .frame(minHeight: YimaDesign.Layout.rowMinHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("查看日程详情")
    }
}

struct YimaTodoRow: View {
    @ObservedObject var store: YimaItemsStore
    let todo: YimaTodo
    let open: () -> Void
    @State private var error: String?
    var body: some View {
        HStack(alignment: .top, spacing: YimaDesign.Space.sm) {
            Button {
                do { var updated = todo; updated.completed.toggle(); try store.updateTodo(updated, expectedRevision: todo.revision) }
                catch { self.error = error.localizedDescription }
            } label: {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(todo.completed ? "恢复待办" : "完成待办")
                .accessibilityValue(todo.title)
            Button(action: open) {
                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                    Text(todo.title).font(YimaDesign.Typography.body).strikethrough(todo.completed)
                    Text(todo.completed ? "Yima待办 · 已完成" : "Yima待办").font(YimaDesign.Typography.compactMetadata).foregroundStyle(YimaDesign.Color.muted)
                    if let due = todo.due { Text(due, format: .dateTime.year().month().day().hour().minute()).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.muted) }
                    if todo.meetingID != nil { Text("会议行动").font(YimaDesign.Typography.compactMetadata).foregroundStyle(YimaDesign.Color.muted) }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.foregroundStyle(YimaDesign.Color.ink).padding(.vertical, YimaDesign.Layout.rowPaddingY)
            .alert("未能保存待办", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}

/// Local forms never construct EventKit objects or ask for system access.
struct YimaItemSheet: View {
    @ObservedObject var store: YimaItemsStore
    let request: YimaItemRequest
    var allowsRecording = true
    @EnvironmentObject private var recordings: VoiceRecordingWorkspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("yima.tasks.eventSources") private var eventSources = ""
    @AppStorage("yima.tasks.reminderSources") private var reminderSources = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var location = ""
    @State private var notice = ""
    @State private var asMeeting: Bool
    @State private var dated = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var completed = false
    @State private var revision = 1
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var child: YimaItemRequest?
    @State private var recordingDetail: RecordingLink?
    private var isEvent: Bool { request.kind == .event }
    private var event: YimaEvent? { store.event(request.id) }
    private var todo: YimaTodo? { store.todo(request.id) }
    private var meeting: YimaMeeting? { event?.meetingID.flatMap { store.meeting($0) } }
    private var sourceSessionID: String? { isEvent ? event?.sourceSessionID : todo?.sourceSessionID }

    init(store: YimaItemsStore, request: YimaItemRequest, allowsRecording: Bool = true) {
        self.store = store
        self.request = request
        self.allowsRecording = allowsRecording
        _asMeeting = State(initialValue: request.asMeeting)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure = store.failure { Section { Text(failure).foregroundStyle(.secondary) } }
                let sourceID = isEvent ? YimaItemsRepository.calendarSourceID : YimaItemsRepository.todoSourceID
                let selection = TaskSourceSelection(encoded: isEvent ? eventSources : reminderSources)
                if selection.known.contains(sourceID) && !selection.selected.contains(sourceID) {
                    Section { Text("此列表已在提醒页隐藏；事项仍保存在本机。可在提醒页筛选中重新勾选。").foregroundStyle(.secondary) }
                }
                Section(isEvent ? "Yima日历 · 仅本机" : "Yima待办 · 仅本机") {
                    if isEvent && request.isNew {
                        Picker("日程类型", selection: $asMeeting) {
                            Text("普通日程").tag(false)
                            Text("会议").tag(true)
                        }
                    }
                    TextField("标题", text: $title, axis: .vertical)
                    if isEvent { TextField("地点", text: $location, axis: .vertical) }
                    TextField("备注", text: $notes, axis: .vertical)
                    if !isEvent { Toggle("已完成", isOn: $completed).tint(YimaDesign.Color.ink) }
                }
                Section {
                    Toggle(isEvent ? "安排时间" : "设置到期时间", isOn: $dated).tint(YimaDesign.Color.ink)
                    if dated {
                        DatePicker(isEvent ? "开始" : "到期", selection: $start)
                        if isEvent { DatePicker("结束", selection: $end, in: start...) }
                    }
                } footer: { Text(isEvent ? "时间待确认的日程保存在未安排中。时间按设备当前时区保存。" : "到期时间仅用于排列待办，本轮不设置定时通知。") }
                if isEvent && request.isNew && asMeeting { Section("会议通知") { TextField("原通知", text: $notice, axis: .vertical) } }
                if let meeting {
                    Section("会议资料") {
                        if !meeting.notice.isEmpty { Text(meeting.notice).textSelection(.enabled) }
                        ForEach(meeting.recordingIDs, id: \.self) { id in
                            Button { recordingDetail = RecordingLink(id: id) } label: { Label("打开录音与逐字稿", systemImage: "waveform") }
                        }
                        if allowsRecording {
                            Button {
                                save(beginRecording: true)
                            } label: { Label("开始会议录音", systemImage: "mic") }
                                .disabled(!recordings.ready || recordings.showsRecording)
                        }
                    }
                    Section("会议待办") {
                        ForEach(store.state.todos.filter { $0.meetingID == meeting.id }) { item in
                            YimaTodoRow(store: store, todo: item) { child = YimaItemRequest(id: item.id, kind: .todo) }
                        }
                        Button("新增会议待办") { child = .new(.todo, meetingID: meeting.id) }
                    }
                }
                if let meetingID = todo?.meetingID, let meeting = store.meeting(meetingID), let event = store.event(meeting.eventID) {
                    Section("来源会议") { Button(event.title) { child = YimaItemRequest(id: event.id, kind: .event) } }
                }
                let evidence = isEvent ? event?.evidence : todo?.evidence
                if let evidence, !evidence.isEmpty { Section("依据") { Text(evidence).textSelection(.enabled) } }
                if let sourceSessionID {
                    Section("来源") {
                        Button("返回来源聊天") {
                            NotificationCenter.default.post(name: Notification.Name("Yima.openSourceChat"), object: nil, userInfo: ["sessionID": sourceSessionID])
                            dismiss()
                        }
                    }
                }
                if !request.isNew {
                    Section {
                        Button(meeting == nil ? "删除此事项" : "删除会议及其日程", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isEvent ? (meeting != nil || (request.isNew && asMeeting) ? "会议安排" : "日程") : "待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!store.available || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.tint(YimaDesign.Color.ink)
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Yima.openSourceChat"))) { _ in dismiss() }
        .onChange(of: start) { _, value in
            if isEvent && end <= value { end = value.addingTimeInterval(3600) }
        }
        .protectedYimaSheet(item: $child) { YimaItemSheet(store: store, request: $0, allowsRecording: false) }
        .protectedYimaSheet(item: $recordingDetail) { item in
            if let id = UUID(uuidString: item.id) { recordings.detail(id: id) }
        }
        .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(meeting == nil ? "删除此事项？" : "删除会议及其日程？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do {
                    if isEvent { try store.deleteEvent(request.id, expectedRevision: revision) }
                    else { try store.deleteTodo(request.id, expectedRevision: revision) }
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text(meeting == nil ? "此操作无法撤销。" : "删除会议安排和原通知，录音及行动待办保留；待办将解除会议关联。") }
    }

    static func didDismiss() {
        NotificationCenter.default.post(name: Notification.Name("Yima.itemSheetDismissed"), object: nil)
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        if let event {
            title = event.title; notes = event.notes; location = event.location; revision = event.revision
            dated = event.start != nil; start = event.start ?? Date(); end = event.end ?? start.addingTimeInterval(3600)
        } else if let todo {
            title = todo.title; notes = todo.notes; completed = todo.completed; revision = todo.revision
            dated = todo.due != nil; start = todo.due ?? Date()
        } else if request.isNew {
            dated = request.suggestedDate != nil
            start = request.suggestedDate ?? Date(); end = start.addingTimeInterval(3600)
        } else { error = "事项已删除。" }
    }

    private func save(beginRecording: Bool = false) {
        do {
            if isEvent {
                var draft = event ?? YimaEvent(id: request.id, title: title)
                draft.title = title; draft.notes = notes; draft.location = location
                let originalStart = draft.start; let originalEnd = draft.end
                draft.start = dated ? start : nil; draft.end = dated ? end : nil
                if request.isNew || draft.start != originalStart || draft.end != originalEnd { draft.timeZone = TimeZone.current.identifier }
                if request.isNew { try store.createEvent(draft, notice: asMeeting ? notice : nil, requestID: request.id) }
                else { try store.updateEvent(draft, expectedRevision: revision) }
            } else {
                var draft = todo ?? YimaTodo(id: request.id, title: title, meetingID: request.meetingID)
                draft.title = title; draft.notes = notes; draft.due = dated ? start : nil; draft.completed = completed
                if request.isNew { try store.createTodo(draft, requestID: request.id) }
                else { try store.updateTodo(draft, expectedRevision: revision) }
            }
            if beginRecording, let meetingID = store.event(request.id)?.meetingID { store.recordingMeetingInProgress = meetingID }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RecordingLink: Identifiable { let id: String }
