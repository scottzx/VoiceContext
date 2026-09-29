import SwiftUI
import EventKit

@MainActor
final class SystemRemindersModel: ObservableObject {
    let store = EKEventStore()
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var loading = false
    @Published private(set) var authorized = false
    @Published var error: String?
    private var generation = 0

    func requestAccess() async {
        do {
            if try await store.requestFullAccessToReminders() { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        generation += 1
        let current = generation
        authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard authorized else { reminders = []; calendars = []; loading = false; return }
        loading = true
        calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        let result: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        guard current == generation else { return }
        loading = false
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            authorized = false; reminders = []; calendars = []; return
        }
        guard let result else { error = "无法读取提醒事项，请重试。"; return }
        reminders = result.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }
    }

    func toggle(_ item: EKReminder) async {
        guard item.calendar.allowsContentModifications else { error = "此提醒事项列表为只读。"; return }
        let oldValue = item.isCompleted
        item.isCompleted.toggle()
        do { try store.save(item, commit: true); await refresh() }
        catch { item.isCompleted = oldValue; self.error = error.localizedDescription }
    }
}

struct SystemRemindersView: View {
    @StateObject private var model = SystemRemindersModel()
    @Environment(\.scenePhase) private var phase
    @State private var editor: ReminderEditorItem?
    @State private var showCompleted = false
    private var visible: [EKReminder] { model.reminders.filter { showCompleted || !$0.isCompleted } }

    var body: some View {
        NavigationStack {
            Group {
                if !model.authorized {
                    ContentUnavailableView {
                        Label("系统提醒事项", systemImage: "checklist")
                    } description: {
                        Text("允许访问后，可在这里管理与 iPhone 提醒事项相同的待办。")
                    } actions: {
                        Button("允许访问") { Task { await model.requestAccess() } }
                        Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                } else {
                    List {
                        Toggle("显示已完成", isOn: $showCompleted)
                        ForEach(visible, id: \.calendarItemIdentifier) { item in
                            HStack {
                                Button { Task { await model.toggle(item) } } label: {
                                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.isCompleted ? "标为未完成" : "完成待办")
                                Button { editor = ReminderEditorItem(reminder: item) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title ?? "未命名待办").foregroundStyle(.primary)
                                        Text(item.calendar.title).font(.caption).foregroundStyle(.secondary)
                                        if let due = item.dueDateComponents?.date {
                                            Text(due, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if visible.isEmpty && !model.loading { Text("暂无待办事项").foregroundStyle(.secondary) }
                    }
                    .refreshable { await model.refresh() }
                }
            }
            .navigationTitle("待办事项")
            .toolbar {
                if model.authorized {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editor = ReminderEditorItem(reminder: nil) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("新增待办事项")
                    }
                }
            }
            .overlay { if model.loading { ProgressView() } }
            .sheet(item: $editor) { item in ReminderEditor(model: model, existing: item.reminder) }
            .alert("提醒事项", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .task { await model.refresh() }
        .onChange(of: phase) { value in if value == .active { Task { await model.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.refresh() } }
    }
}

private struct ReminderEditorItem: Identifiable {
    let id = UUID()
    let reminder: EKReminder?
}

private struct ReminderEditor: View {
    @ObservedObject var model: SystemRemindersModel
    let existing: EKReminder?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var calendarID = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var error: String?
    @State private var deleting = false
    private var writable: [EKCalendar] { model.calendars.filter(\.allowsContentModifications) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("备注", text: $notes, axis: .vertical)
                Picker("列表", selection: $calendarID) {
                    ForEach(writable, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                }
                Toggle("到期日期", isOn: $hasDueDate)
                if hasDueDate { DatePicker("日期", selection: $dueDate, displayedComponents: .date) }
                if let error { Text(error).foregroundStyle(.red) }
                if existing != nil { Button("删除待办事项", role: .destructive) { deleting = true } }
            }
            .navigationTitle(existing == nil ? "新增待办" : "编辑待办")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calendarID.isEmpty)
                }
            }
            .confirmationDialog("删除此系统提醒事项？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let existing else { return }
                    do { try model.store.remove(existing, commit: true); dismiss(); Task { await model.refresh() } }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear {
            title = existing?.title ?? ""
            notes = existing?.notes ?? ""
            calendarID = existing?.calendar.calendarIdentifier ?? model.store.defaultCalendarForNewReminders()?.calendarIdentifier ?? writable.first?.calendarIdentifier ?? ""
            hasDueDate = existing?.dueDateComponents != nil
            dueDate = existing?.dueDateComponents?.date ?? Date()
        }
    }

    private func save() {
        guard let calendar = writable.first(where: { $0.calendarIdentifier == calendarID }) else { error = "请选择可写的提醒事项列表。"; return }
        let reminder: EKReminder
        if let existing {
            guard let current = model.store.calendarItem(withIdentifier: existing.calendarItemIdentifier) as? EKReminder else {
                error = "此提醒事项已被删除，请关闭后刷新。"; return
            }
            reminder = current
        } else { reminder = EKReminder(eventStore: model.store) }
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = notes
        reminder.calendar = calendar
        // Editing a title must preserve an existing reminder's time/time zone.
        if !hasDueDate { reminder.dueDateComponents = nil }
        else if existing?.dueDateComponents?.date != dueDate {
            var components = reminder.dueDateComponents ?? DateComponents()
            let day = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            components.year = day.year; components.month = day.month; components.day = day.day
            reminder.dueDateComponents = components
        }
        do { try model.store.save(reminder, commit: true); dismiss(); Task { await model.refresh() } }
        catch { self.error = error.localizedDescription }
    }
}
