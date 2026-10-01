import SwiftUI
import EventKit

@MainActor
final class SystemRemindersModel: ObservableObject {
    let store = EKEventStore()
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var loading = true
    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var readError: String?
    @Published private(set) var busyIDs: Set<String> = []
    @Published private(set) var recentlyCompleted: Set<String> = []
    @Published var error: String?
    private var generation = 0
    var authorized: Bool { authorization == .fullAccess }
    var writable: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    func requestAccess() async {
        guard !loading else { return }
        loading = true
        do {
            _ = try await store.requestFullAccessToReminders()
            await refresh()
        } catch { self.error = error.localizedDescription; await refresh() }
    }

    func refresh() async {
        generation += 1
        let current = generation
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        guard authorized else {
            reminders = []; calendars = []; loading = false; readError = nil
            return
        }
        loading = true
        calendars = store.calendars(for: .reminder)
        // An empty calendar array is not passed to a predicate as 'all lists'.
        if calendars.isEmpty { reminders = []; readError = nil; loading = false; return }
        let predicate = store.predicateForReminders(in: calendars)
        let result: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        guard current == generation else { return }
        loading = false
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        guard authorized else { reminders = []; calendars = []; readError = nil; return }
        guard let result else { readError = AppLocalized("无法读取提醒事项，请重试。"); return }
        readError = nil
        reminders = result.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            let left = ReminderDateEditing.date(from: $0.dueDateComponents) ?? .distantFuture
            let right = ReminderDateEditing.date(from: $1.dueDateComponents) ?? .distantFuture
            if left != right { return left < right }
            return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
        }
    }

    func editableReminder(id: String) throws -> EKReminder {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw failure("提醒事项访问已关闭，请在系统设置中允许访问。")
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw failure("此提醒事项已被删除，请关闭后刷新。")
        }
        guard item.refresh() else { throw failure("此提醒事项已被删除，请关闭后刷新。") }
        guard item.calendar.allowsContentModifications else { throw failure("此提醒事项列表为只读。") }
        return item
    }

    func failure(_ message: String.LocalizationValue) -> NSError {
        NSError(domain: "Yima.Reminders", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLocalized(message)])
    }

    func toggle(_ item: EKReminder) async {
        let id = item.calendarItemIdentifier
        guard !busyIDs.contains(id) else { return }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        let completed = !item.isCompleted
        do {
            let current = try editableReminder(id: id)
            current.isCompleted = completed
            do { try store.save(current, commit: true) }
            catch { current.reset(); throw error }
            if completed { recentlyCompleted.insert(id) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: AppLocalized(completed ? "已完成" : "已恢复为未完成"))
            await refresh()
            if completed {
                try? await Task.sleep(for: .milliseconds(650))
                recentlyCompleted.remove(id)
            }
        } catch { self.error = error.localizedDescription; await refresh() }
    }

    @discardableResult func delete(_ item: EKReminder) async -> Bool {
        let id = item.calendarItemIdentifier
        guard !busyIDs.contains(id) else { return false }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            let current = try editableReminder(id: id)
            try store.remove(current, commit: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; await refresh(); return false }
    }
}

struct SystemRemindersView: View {
    @StateObject private var model = SystemRemindersModel()
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editor: ReminderEditorItem?
    @State private var deleteCandidate: EKReminder?
    @AppStorage("yima.reminders.showCompleted") private var showCompleted = false
    @AppStorage("yima.reminders.calendarID") private var calendarID = ""
    private var selectedCalendar: EKCalendar? { model.calendars.first { $0.calendarIdentifier == calendarID } }
    private var visible: [EKReminder] {
        model.reminders.filter {
            (selectedCalendar == nil || $0.calendar.calendarIdentifier == calendarID) &&
            (showCompleted || !$0.isCompleted || model.recentlyCompleted.contains($0.calendarItemIdentifier))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.authorized { permissionView }
                else if let error = model.readError {
                    ContentUnavailableView {
                        Label("无法读取提醒事项", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("重试") { Task { await model.refresh() } }.disabled(model.loading)
                    }
                } else { remindersList }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("待办事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.authorized {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("列表", selection: $calendarID) {
                                Text("全部列表").tag("")
                                ForEach(model.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                            }
                            Toggle("显示已完成", isOn: $showCompleted)
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .accessibilityLabel("筛选待办事项")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editor = ReminderEditorItem(reminder: nil) } label: { Image(systemName: "plus") }
                            .disabled(model.writable.isEmpty || model.loading || model.readError != nil)
                            .accessibilityLabel("新增待办事项")
                    }
                }
            }
            .sheet(item: $editor) { item in
                ReminderEditor(model: model, existing: item.reminder, preferredCalendarID: selectedCalendar?.calendarIdentifier)
            }
            .confirmationDialog("删除此系统提醒事项？", isPresented: Binding(
                get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
            ), titleVisibility: .visible) {
                if let item = deleteCandidate {
                    Button("删除", role: .destructive) { Task { await model.delete(item) } }
                }
                Button("取消", role: .cancel) { deleteCandidate = nil }
            } message: { Text(deleteCandidate?.title ?? "") }
            .alert("提醒事项", isPresented: Binding(get: { model.error != nil && editor == nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .task { await model.refresh() }
        .onChange(of: phase) { value in if value == .active { Task { await model.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await model.refresh() } }
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("系统提醒事项", systemImage: "checklist")
        } description: {
            if model.authorization == .restricted {
                Text("系统限制了提醒事项访问，请检查设备的访问限制。")
            } else if model.authorization == .notDetermined {
                Text("允许访问后，可在这里管理与 iPhone 提醒事项相同的待办。")
            } else { Text("提醒事项访问已关闭，请在系统设置中允许访问。") }
        } actions: {
            if model.authorization == .notDetermined {
                Button("允许访问") { Task { await model.requestAccess() } }.disabled(model.loading)
            }
            Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!).tint(.blue)
        }
    }

    private var remindersList: some View {
        List {
            if model.loading { ProgressView("正在读取提醒事项…") }
            if model.writable.isEmpty && !model.loading {
                Text("没有可写的提醒事项列表，请在系统提醒事项中创建列表。")
                    .foregroundStyle(.secondary)
            }
            if let selectedCalendar {
                Text(selectedCalendar.title).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(visible, id: \.calendarItemIdentifier) { item in reminderRow(item) }
            if visible.isEmpty && !model.loading { Text("暂无待办事项").foregroundStyle(.secondary) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 64)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visible.map(\.calendarItemIdentifier))
        .refreshable { await model.refresh() }
    }

    private func reminderRow(_ item: EKReminder) -> some View {
        let writable = item.calendar.allowsContentModifications
        let busy = model.busyIDs.contains(item.calendarItemIdentifier)
        let action = AppLocalized(item.isCompleted ? "标为未完成" : "完成待办")
        return HStack {
            Button { Task { await model.toggle(item) } } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!writable || busy)
            .accessibilityLabel(action)
            Button { editor = ReminderEditorItem(reminder: item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? AppLocalized("未命名待办"))
                        .strikethrough(item.isCompleted).foregroundStyle(.primary)
                    Text(item.calendar.title).font(.caption).foregroundStyle(.secondary)
                    if item.isCompleted { Text("已完成").font(.caption).foregroundStyle(.secondary) }
                    if !writable { Text("只读列表").font(.caption).foregroundStyle(.secondary) }
                    if let components = item.dueDateComponents, let due = ReminderDateEditing.date(from: components) {
                        Text(due, format: components.hour == nil ? .dateTime.year().month().day() : .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                            .environment(\.timeZone, components.timeZone ?? .current)
                    }
                    if let alarm = item.alarms?.first?.absoluteDate {
                        Label { Text(alarm, format: .dateTime.month().day().hour().minute()) } icon: { Image(systemName: "bell") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { Text("正在更新…").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if writable {
                Button(action) { Task { await model.toggle(item) } }.tint(.gray).disabled(busy)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if writable {
                // Confirmation must precede destructive row semantics/removal.
                Button { deleteCandidate = item } label: { Label("删除", systemImage: "trash") }
                    .tint(.red).disabled(busy)
            }
        }
        .contextMenu {
            Button("编辑待办") { editor = ReminderEditorItem(reminder: item) }.disabled(busy)
            if writable {
                Button(action) { Task { await model.toggle(item) } }.disabled(busy)
                Button("删除", role: .destructive) { deleteCandidate = item }.disabled(busy)
            }
        }
        .accessibilityActions {
            if !busy {
                Button("编辑待办") { editor = ReminderEditorItem(reminder: item) }
                if writable {
                    Button(action) { Task { await model.toggle(item) } }
                    Button("删除", role: .destructive) { deleteCandidate = item }
                }
            }
        }
    }
}

private struct ReminderEditorItem: Identifiable {
    let id = UUID()
    let reminder: EKReminder?
}

private struct ReminderEditor: View {
    @ObservedObject var model: SystemRemindersModel
    let existing: EKReminder?
    let preferredCalendarID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var calendarID = ""
    @State private var hasDueDate = false
    @State private var hasTime = false
    @State private var dueDate = Date()
    @State private var hasAlarm = false
    @State private var alarmDate = Date()
    @State private var dateChanged = false
    @State private var timeChanged = false
    @State private var alarmChanged = false
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var deleting = false
    private var readOnly: Bool { !model.authorized || existing?.calendar.allowsContentModifications == false }
    private var advancedSchedule: Bool { existing.map(Self.hasAdvancedSchedule) ?? false }
    private var timeZone: TimeZone { existing?.dueDateComponents?.timeZone ?? .current }

    private static func hasAdvancedSchedule(_ item: EKReminder) -> Bool {
        let alarms = item.alarms ?? []
        return !(item.recurrenceRules ?? []).isEmpty || alarms.count > 1 ||
            alarms.contains { $0.structuredLocation != nil || $0.absoluteDate == nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("备注", text: $notes, axis: .vertical)
                    Picker("列表", selection: $calendarID) {
                        if let existing, !existing.calendar.allowsContentModifications {
                            Text(existing.calendar.title).tag(existing.calendar.calendarIdentifier)
                        }
                        ForEach(model.writable, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                }.disabled(readOnly || saving)
                Section {
                    Toggle("到期日期", isOn: Binding(get: { hasDueDate }, set: { hasDueDate = $0; dateChanged = true }))
                    if hasDueDate {
                        DatePicker("日期", selection: dateBinding, displayedComponents: .date)
                        Toggle("到期时间", isOn: Binding(get: { hasTime }, set: { hasTime = $0; timeChanged = true }))
                        if hasTime { DatePicker("时间", selection: timeBinding, displayedComponents: .hourAndMinute) }
                    }
                } footer: { Text("到期日期用于安排待办；通知请单独设置定时提醒。") }
                .disabled(readOnly || saving || advancedSchedule)
                .environment(\.timeZone, timeZone)
                Section {
                    Toggle("定时提醒", isOn: Binding(get: { hasAlarm }, set: { hasAlarm = $0; alarmChanged = true }))
                    if hasAlarm {
                        DatePicker("提醒时间", selection: Binding(get: { alarmDate }, set: { alarmDate = $0; alarmChanged = true }), displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: { Text("通知由系统提醒事项发送，是否提示取决于系统通知设置。") }
                .disabled(readOnly || saving || advancedSchedule)
                if advancedSchedule { Text("此事项包含重复或复杂提醒，时间设置已保留。请在系统提醒事项中调整。") }
                if readOnly { Text("此提醒事项不可编辑，请检查列表权限和系统访问设置。") }
                if let error { Text(error).foregroundStyle(.red) }
                if existing != nil && !readOnly {
                    Button("删除待办事项", role: .destructive) { deleting = true }.disabled(saving)
                }
            }
            .navigationTitle(AppLocalized(existing == nil ? "新增待办" : "编辑待办"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(readOnly || saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calendarID.isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .confirmationDialog("删除此系统提醒事项？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let existing else { return }
                    saving = true
                    Task { if await model.delete(existing) { dismiss() }; saving = false }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("提醒事项", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .onAppear {
            guard !loaded else { return }
            title = existing?.title ?? ""
            notes = existing?.notes ?? ""
            let preferred = model.writable.first { $0.calendarIdentifier == preferredCalendarID }
            let systemDefault = model.store.defaultCalendarForNewReminders()
            calendarID = existing?.calendar.calendarIdentifier ?? preferred?.calendarIdentifier ??
                (systemDefault?.allowsContentModifications == true ? systemDefault?.calendarIdentifier : nil) ??
                model.writable.first?.calendarIdentifier ?? ""
            initialTitle = title
            initialNotes = notes
            initialCalendarID = calendarID
            hasDueDate = existing?.dueDateComponents != nil
            hasTime = existing?.dueDateComponents?.hour != nil
            dueDate = ReminderDateEditing.date(from: existing?.dueDateComponents) ?? Date()
            hasAlarm = !(existing?.alarms ?? []).isEmpty
            alarmDate = existing?.alarms?.first?.absoluteDate ?? dueDate
            loaded = true
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { dueDate }, set: { dueDate = $0; dateChanged = true })
    }
    private var timeBinding: Binding<Date> {
        Binding(get: { dueDate }, set: { dueDate = $0; timeChanged = true })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            guard model.authorized, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                throw model.failure("提醒事项访问已关闭，请在系统设置中允许访问。")
            }
            let reminder = try existing.map { try model.editableReminder(id: $0.calendarItemIdentifier) } ?? EKReminder(eventStore: model.store)
            guard let calendar = model.store.calendars(for: .reminder).first(where: {
                $0.calendarIdentifier == calendarID && $0.allowsContentModifications
            }) else { throw model.failure("请选择可写的提醒事项列表。") }
            // Compare against the opened draft, not a newly fetched external version.
            if existing == nil || title != initialTitle { reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if existing == nil || notes != initialNotes { reminder.notes = notes }
            if existing == nil || calendarID != initialCalendarID { reminder.calendar = calendar }
            do {
                if dateChanged || timeChanged || alarmChanged {
                    guard !Self.hasAdvancedSchedule(reminder) else {
                        throw model.failure("此事项的时间设置已在外部变更，请关闭后重新编辑。")
                    }
                }
                if dateChanged || timeChanged {
                    if hasDueDate {
                        reminder.dueDateComponents = ReminderDateEditing.components(
                            existing: reminder.dueDateComponents, date: dueDate, hasTime: hasTime,
                            dateChanged: dateChanged, timeChanged: timeChanged)
                        if reminder.startDateComponents == nil { reminder.startDateComponents = reminder.dueDateComponents }
                    } else { reminder.dueDateComponents = nil }
                }
                if alarmChanged { reminder.alarms = hasAlarm ? [EKAlarm(absoluteDate: alarmDate)] : nil }
                try model.store.save(reminder, commit: true)
            } catch { reminder.reset(); throw error }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            Task { await model.refresh() }
        } catch { self.error = error.localizedDescription }
    }

    @State private var initialTitle = ""
    @State private var initialNotes = ""
    @State private var initialCalendarID = ""
}
