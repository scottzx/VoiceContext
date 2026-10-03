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
    private var requestingAccess = false
    var authorized: Bool { authorization == .fullAccess }
    var writable: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    func requestAccess() async {
        guard !loading, !requestingAccess else { return }
        requestingAccess = true
        loading = true
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch { self.error = error.localizedDescription }
        requestingAccess = false
        await refresh()
    }

    func refresh() async {
        generation += 1
        let current = generation
        authorization = EKEventStore.authorizationStatus(for: .reminder)
        guard authorized else {
            reminders = []; calendars = []; loading = requestingAccess; readError = nil
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
    @StateObject private var calendarModel = SystemCalendarModel()
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected = Date()
    @State private var month = Date()
    @State private var expanded = true
    @State private var today = Date()
    @State private var futureEnd = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    @State private var editor: ReminderEditorItem?
    @State private var deleteCandidate: EKReminder?
    @State private var eventDetail: TaskCalendarEvent?
    @State private var showAll = false
    @State private var filtersOpen = false
    @State private var homeFiltersOpen = false
    @State private var sourceNotice = false
    @State private var dateJump: TaskDateJumpRequest?
    @State private var jumpTargetDate: Date?
    @AppStorage("yima.reminders.showCompleted") private var showCompleted = false
    @AppStorage("yima.tasks.reminderSources") private var reminderSources = ""
    @AppStorage("yima.tasks.eventSources") private var eventSources = ""
    private var calendar: Calendar { .current }
    private var days: [Date] { TaskCalendarRules.days(month: month, selected: selected, expanded: expanded) }
    private var overviewInterval: DateInterval {
        let start = min(days.first!, calendar.startOfDay(for: selected))
        let last = max(days.last!, calendar.startOfDay(for: selected))
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: last)!)
    }
    private var futureInterval: DateInterval {
        DateInterval(start: calendar.startOfDay(for: today), end: futureEnd)
    }
    private var reminderReady: Bool { model.authorized && !model.loading && model.readError == nil }
    private var calendarReady: Bool {
        calendarModel.authorized && !calendarModel.loading && calendarModel.readError == nil &&
        calendarModel.loadedOverview == overviewInterval && calendarModel.loadedFuture == futureInterval
    }
    private var canAdd: Bool { reminderReady && !model.writable.isEmpty }
    private var visibleReminders: [EKReminder] {
        let sources = TaskSourceSelection(encoded: reminderSources)
        return model.reminders.filter {
            sources.includesReminder(sourceID: $0.calendar.calendarIdentifier, completed: $0.isCompleted,
                showCompleted: showCompleted, recentlyCompleted: model.recentlyCompleted.contains($0.calendarItemIdentifier))
        }
    }
    private var visibleOverviewEvents: [TaskCalendarEvent] {
        let sources = TaskSourceSelection(encoded: eventSources).selected
        return calendarModel.events.filter { sources.contains($0.sourceID) }
    }
    private var dayReminders: [EKReminder] {
        visibleReminders.filter {
            guard let due = ReminderDateEditing.date(from: $0.dueDateComponents) else { return false }
            return calendar.isDate(due, inSameDayAs: selected)
        }.sorted {
            let left = $0.dueDateComponents?.hour == nil ? Date.distantFuture : ReminderDateEditing.date(from: $0.dueDateComponents)!
            let right = $1.dueDateComponents?.hour == nil ? Date.distantFuture : ReminderDateEditing.date(from: $1.dueDateComponents)!
            return left == right ? ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending : left < right
        }
    }
    private var dayEvents: [TaskCalendarEvent] {
        visibleOverviewEvents.filter { TaskCalendarRules.intersects(start: $0.start, end: $0.end, day: selected) }
    }
    private var overdueCount: Int {
        visibleReminders.filter { !$0.isCompleted && TaskCalendarRules.group(due: ReminderDateEditing.date(from: $0.dueDateComponents), today: today) == .overdue }.count
    }

    var body: some View {
        NavigationStack {
            home
                .navigationTitle("提醒").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { homeFiltersOpen = true } label: { Image(systemName: "line.3.horizontal.decrease") }
                            .accessibilityLabel("筛选提醒")
                    }
                }
                .navigationDestination(isPresented: $showAll) { allItems }
                .sheet(isPresented: $homeFiltersOpen) {
                    NavigationStack {
                        List { sourceFilters }
                            .navigationTitle("筛选提醒").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { homeFiltersOpen = false } } }
                    }
                }
                .sheet(item: $editor) { item in
                    ReminderEditor(model: model, existing: item.reminder, preferredCalendarID: nil, suggestedDate: item.suggestedDate)
                }
                .sheet(item: $eventDetail) { event in TaskEventDetail(event: event) }
                .confirmationDialog("删除此系统提醒事项？", isPresented: Binding(
                    get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
                ), titleVisibility: .visible) {
                    if let item = deleteCandidate {
                        Button("删除", role: .destructive) { deleteCandidate = nil; Task { await model.delete(item) } }
                    }
                    Button("取消", role: .cancel) { deleteCandidate = nil }
                } message: { Text(deleteCandidate?.title ?? "") }
                .alert("提醒事项", isPresented: Binding(get: { model.error != nil && editor == nil }, set: { if !$0 { model.error = nil } })) {
                    Button("好", role: .cancel) { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
        .toolbar(showAll ? .hidden : .visible, for: .tabBar)
        .task { await model.refresh(); reconcileSources() }
        .task(id: overviewInterval) { await refreshCalendar() }
        .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in Task { await refresh() } }
        .onChange(of: model.loading) { _, loading in if !loading { reconcileSources() } }
        .onChange(of: calendarModel.loading) { _, loading in if !loading { reconcileSources() } }
    }

    private var home: some View {
        List {
            TaskCalendarView(selected: $selected, month: $month, expanded: $expanded, counts: counts)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20)).listRowSeparator(.hidden)
            ViewThatFits(in: .horizontal) {
                HStack { dayHeading; Spacer(minLength: 8); sectionActions }
                VStack(alignment: .leading, spacing: 8) { dayHeading; HStack { Spacer(); sectionActions } }
            }.listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 12, trailing: 20)).listRowSeparator(.hidden)
            if !hasSelectedSources && (reminderReady || calendarReady) {
                quietText("尚未选择列表，请在筛选中勾选要展示的日历或待办列表。")
            }
            groupHeading("待办", count: reminderReady ? dayReminders.count : nil)
            reminderStatus
            if reminderReady {
                if dayReminders.isEmpty { quietText("这天没有待办。") }
                ForEach(dayReminders, id: \.calendarItemIdentifier) { reminderRow($0) }
                if model.writable.isEmpty { quietText("没有可写的提醒事项列表，请在系统提醒事项中创建列表。") }
            }
            groupHeading("日程", count: calendarReady ? dayEvents.count : nil)
            calendarStatus
            if calendarReady {
                if dayEvents.isEmpty { quietText("这天没有日程。") }
                ForEach(dayEvents) { eventRow($0) }
            }
            if reminderReady && overdueCount > 0 {
                Text("\(overdueCount) 项逾期待办 · 在“全部”中查看")
                    .font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await refresh() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: dayReminders.map(\.calendarItemIdentifier))
    }

    private var dayHeading: some View {
        Group {
            if calendar.isDateInToday(selected) { Text("今日事项") }
            else { Text("\(selected, format: .dateTime.month().day().weekday())事项") }
        }.font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
    }

    private var sectionActions: some View {
        HStack(spacing: 4) {
            Button { showAll = true } label: { HStack(spacing: 4) { Text("全部"); Image(systemName: "chevron.right").font(.caption) } }
                .font(.subheadline).frame(minWidth: 44, minHeight: 44).accessibilityLabel("查看全部事项")
            Button { editor = ReminderEditorItem(reminder: nil, suggestedDate: selected) } label: {
                Image(systemName: "plus").font(.title2)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
            }.disabled(!canAdd).opacity(canAdd ? 1 : 0.4).accessibilityLabel("新增待办事项")
                .accessibilityHint(canAdd ? "预填所选日期，通知单独设置" : "允许提醒事项访问并选择可写列表后可新增")
        }.buttonStyle(.plain)
    }

    private func counts(_ day: Date) -> TaskDayCounts {
        let reminders = reminderReady ? visibleReminders.filter {
            guard !$0.isCompleted, let due = ReminderDateEditing.date(from: $0.dueDateComponents) else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }.count : nil
        let covered = calendarModel.loadedOverview.map { $0.start <= day && day < $0.end } ?? false
        let events = calendarReady && covered ? visibleOverviewEvents.filter {
            TaskCalendarRules.intersects(start: $0.start, end: $0.end, day: day)
        }.count : nil
        return TaskDayCounts(reminders: reminders, events: events)
    }

    private func reminderRow(_ item: EKReminder) -> some View {
        SystemReminderRow(model: model, item: item, edit: { editor = ReminderEditorItem(reminder: $0) }, delete: { deleteCandidate = $0 })
            .padding(.vertical, 8).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private func eventRow(_ event: TaskCalendarEvent) -> some View {
        TaskEventRow(event: event) { eventDetail = event }
            .padding(.vertical, 8).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private func groupHeading(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack {
            Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            Spacer()
            if let count { Text("\(count) 项") } else { Text("未读取") }
        }.font(.subheadline).foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20)).listRowSeparator(.hidden)
    }

    private func quietText(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8).listRowSeparator(.hidden)
    }

    @ViewBuilder private var reminderStatus: some View {
        if !model.authorized {
            TaskSourcePermission(isCalendar: false, authorization: model.authorization, loading: model.loading) { Task { await model.requestAccess() } }
                .listRowSeparator(.hidden)
        } else if model.loading { ProgressView("正在读取提醒事项…").listRowSeparator(.hidden) }
        else if let error = model.readError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await model.refresh() } }.frame(minHeight: 44)
            }.buttonStyle(.plain).listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var calendarStatus: some View {
        if !calendarModel.authorized {
            TaskSourcePermission(isCalendar: true, authorization: calendarModel.authorization, loading: calendarModel.requestingAccess) {
                Task { await calendarModel.requestAccess(overview: overviewInterval, future: futureInterval) }
            }.listRowSeparator(.hidden)
            if let error = calendarModel.readError { quietText(LocalizedStringKey(error)) }
        } else if calendarModel.loading || (calendarModel.readError == nil && !calendarReady) {
            ProgressView("正在读取日历…").listRowSeparator(.hidden)
        }
        else if let error = calendarModel.readError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await refreshCalendar() } }.frame(minHeight: 44)
            }.buttonStyle(.plain).listRowSeparator(.hidden)
        }
    }

    private var allItems: some View {
        let entries = allEntries
        let dated = Dictionary(grouping: entries.filter { $0.date != nil }, by: { calendar.startOfDay(for: $0.date!) })
        let dateIndex = TaskDateIndex(dates: Array(dated.keys), calendar: calendar)
        let unscheduled = entries.filter { $0.date == nil }
        return ScrollViewReader { proxy in
            List {
                if filtersOpen {
                    sourceFilters
                } else { reminderStatus; calendarStatus }
                if sourceNotice {
                    VStack(alignment: .leading) {
                        Text("部分来源列表已不可用，已移除失效选择。其他筛选保持不变。").font(.subheadline).foregroundStyle(.secondary)
                        Button("知道了") { sourceNotice = false }.frame(minHeight: 44)
                    }.buttonStyle(.plain).listRowSeparator(.hidden)
                }
                if !hasSelectedSources && (reminderReady || calendarReady) {
                    quietText("尚未选择列表，请在筛选中勾选要展示的日历或待办列表。")
                } else if hasSelectedSources {
                    ForEach(dateIndex.dates, id: \.self) { date in
                        Section {
                            ForEach(dated[date] ?? []) { entry in
                                if let reminder = entry.reminder { reminderRow(reminder) }
                                if let event = entry.event { eventRow(event) }
                            }
                        } header: {
                            Button { dateJump = TaskDateJumpRequest(id: date) } label: {
                                HStack(spacing: 6) {
                                    Text(date, format: .dateTime.year().month().day().weekday())
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(dated[date]?.count ?? 0) 项").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityHint("选择已有事项的日期并跳转")
                                .id(date)
                        }
                    }
                    if !unscheduled.isEmpty {
                        Section {
                            ForEach(unscheduled) { entry in
                                if let reminder = entry.reminder { reminderRow(reminder) }
                            }
                        } header: { groupHeading("未安排", count: unscheduled.count) }
                    }
                    if entries.isEmpty && (reminderReady || calendarReady) {
                        quietText("当前已读取的所选列表没有事项。")
                    }
                    if calendarReady && !TaskSourceSelection(encoded: eventSources).selected.isEmpty {
                        Section {
                            if let interval = calendarModel.loadedFuture {
                                Text("日程已读取至 \(interval.end, format: .dateTime.year().month().day())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("加载更多日程") {
                                futureEnd = calendar.date(byAdding: .year, value: 1, to: futureEnd)!
                                Task { await refreshCalendar() }
                            }.frame(minHeight: 44).disabled(calendarModel.loading)
                        }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("全部事项").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { filtersOpen.toggle() } label: { Image(systemName: "line.3.horizontal.decrease") }
                        .accessibilityLabel("筛选全部事项").accessibilityValue(filtersOpen ? "已展开" : "已收起")
                }
            }
            .refreshable { await refresh() }
            .sheet(item: $dateJump, onDismiss: {
                guard let target = jumpTargetDate else { return }
                jumpTargetDate = nil
                guard dateIndex.dates.contains(target) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
            }) { request in
                TaskDateJumpSheet(dates: dateIndex.dates, initialDate: request.id) { jumpTargetDate = $0 }
            }
        }
    }

    private var hasSelectedSources: Bool {
        !TaskSourceSelection(encoded: reminderSources).selected.isEmpty || !TaskSourceSelection(encoded: eventSources).selected.isEmpty
    }

    private var sourceFilters: some View {
        Group {
            Section("日历列表") {
                calendarStatus
                if calendarReady && calendarModel.sources.isEmpty { quietText("没有可读取的日历列表。") }
                ForEach(calendarModel.sources) { source in
                    sourceToggle(id: source.id, title: source.title, account: source.account, isCalendar: true)
                }
            }
            Section("待办列表") {
                reminderStatus
                if reminderReady && model.calendars.isEmpty { quietText("没有可读取的待办列表。") }
                ForEach(model.calendars, id: \.calendarIdentifier) { source in
                    sourceToggle(id: source.calendarIdentifier, title: source.title, account: source.source.title, isCalendar: false)
                }
                Toggle("显示已完成待办", isOn: $showCompleted).tint(.primary)
            }
        }
    }

    private func sourceToggle(id: String, title: String, account: String, isCalendar: Bool) -> some View {
        let selection = TaskSourceSelection(encoded: isCalendar ? eventSources : reminderSources)
        return Button {
            var value = selection; value.toggle(id)
            if isCalendar { eventSources = value.encoded } else { reminderSources = value.encoded }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selection.selected.contains(id) ? "checkmark.square.fill" : "square").frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(account).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain).accessibilityValue(selection.selected.contains(id) ? "已选择" : "未选择")
    }

    private struct Entry: Identifiable {
        let id: String
        let date: Date?
        let time: Date
        var reminder: EKReminder?
        var event: TaskCalendarEvent?
    }

    private var allEntries: [Entry] {
        let eventIDs = TaskSourceSelection(encoded: eventSources).selected
        var entries: [Entry] = []
        if reminderReady {
            entries += visibleReminders.map {
                let due = ReminderDateEditing.date(from: $0.dueDateComponents)
                return Entry(id: "reminder:" + $0.calendarItemIdentifier, date: due,
                    time: $0.dueDateComponents?.hour == nil ? .distantFuture : due ?? .distantFuture,
                    reminder: $0)
            }
        }
        if calendarReady {
            entries += calendarModel.futureEvents.filter { eventIDs.contains($0.sourceID) }.map {
                let date = max($0.start, calendar.startOfDay(for: today))
                return Entry(id: "event:" + $0.id, date: date, time: $0.allDay ? .distantFuture : date,
                             event: $0)
            }
        }
        return entries.sorted {
            let left = $0.date.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            let right = $1.date.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            if left != right { return left < right }
            return $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
        }
    }

    private func reconcileSources() {
        if reminderReady {
            var value = TaskSourceSelection(encoded: reminderSources)
            let ids = Set(model.calendars.map(\.calendarIdentifier))
            // Keep the existing persisted filter when sharing it with the overview.
            if reminderSources.isEmpty, let old = UserDefaults.standard.string(forKey: "yima.reminders.calendarID"), ids.contains(old) {
                value.known = ids; value.selected = [old]
            }
            if value.reconcile(ids) { sourceNotice = true }
            reminderSources = value.encoded
        }
        if calendarReady {
            var value = TaskSourceSelection(encoded: eventSources)
            if value.reconcile(Set(calendarModel.sources.map(\.id))) { sourceNotice = true }
            eventSources = value.encoded
        }
    }

    private func refreshCalendar() async { await calendarModel.refresh(overview: overviewInterval, future: futureInterval) }
    private func refresh() async {
        let now = Date()
        let followedToday = calendar.isDate(selected, inSameDayAs: today)
        if followedToday && calendar.isDate(month, equalTo: today, toGranularity: .month) { month = now }
        today = now
        if followedToday { selected = now }
        if futureEnd <= now { futureEnd = calendar.date(byAdding: .year, value: 1, to: now)! }
        async let reminders: Void = model.refresh()
        async let events: Void = refreshCalendar()
        _ = await (reminders, events)
        reconcileSources()
    }
}

private struct TaskSourcePermission: View {
    let isCalendar: Bool
    let authorization: EKAuthorizationStatus
    let loading: Bool
    let request: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if authorization == .restricted {
                Text(isCalendar ? "系统限制了日历访问，请检查设备的访问限制。" : "系统限制了提醒事项访问，请检查设备的访问限制。")
            } else if authorization == .notDetermined {
                Text(isCalendar ? "允许读取系统日历后，可在这里查看日程。" : "允许访问后，可在这里管理与 iPhone 提醒事项相同的待办。")
            } else {
                Text(isCalendar ? "日历访问已关闭，请在系统设置中允许访问。" : "提醒事项访问已关闭，请在系统设置中允许访问。")
            }
            if authorization == .notDetermined || (isCalendar && authorization == .writeOnly) {
                Button(isCalendar ? "允许访问日历" : "允许访问提醒事项", action: request).disabled(loading).frame(minHeight: 44)
            }
            if authorization != .notDetermined {
                Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!).tint(.blue).frame(minHeight: 44)
            }
        }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain).padding(.vertical, 8)
    }
}

private struct TaskDateJumpRequest: Identifiable { let id: Date }

private struct TaskDateJumpSheet: View {
    let dates: [Date]
    let initialDate: Date
    let onSelect: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate: Date?
    private var index: TaskDateIndex { TaskDateIndex(dates: dates) }
    private var selection: Date? {
        let candidate = selectedDate ?? initialDate
        return index.dates.contains(candidate) ? candidate : index.dates.first
    }
    private var year: Int { selection.map { index.calendar.component(.year, from: $0) } ?? 0 }
    private var month: Int { selection.map { index.calendar.component(.month, from: $0) } ?? 0 }
    private var day: Int { selection.map { index.calendar.component(.day, from: $0) } ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if index.dates.isEmpty {
                    ContentUnavailableView("暂无可用事项日期", systemImage: "calendar.badge.exclamationmark")
                } else {
                    Text("选择已有待办或日程的年月日快速定位")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Picker("年", selection: Binding(get: { year }, set: {
                            selectedDate = index.resolving(year: $0, month: month, day: day)
                        })) {
                            ForEach(index.years, id: \.self) { Text("\(String($0))年").tag($0) }
                        }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
                        Picker("月", selection: Binding(get: { month }, set: {
                            selectedDate = index.resolving(year: year, month: $0, day: day)
                        })) {
                            ForEach(index.months(in: year), id: \.self) { Text("\($0)月").tag($0) }
                        }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
                        Picker("日", selection: Binding(get: { day }, set: {
                            selectedDate = index.resolving(year: year, month: month, day: $0)
                        })) {
                            ForEach(index.days(in: year, month: month), id: \.self) { Text("\($0)日").tag($0) }
                        }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
                    }.frame(height: 160)
                }
                Spacer(minLength: 0)
            }.padding(16)
                .navigationTitle("快速跳转日期").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("跳转") {
                            if let selection { onSelect(selection) }
                            dismiss()
                        }.disabled(selection == nil)
                    }
                }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(340), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct TaskItemContent<Details: View>: View {
    let title: String
    let source: String
    let completed: Bool
    let details: Details

    init(title: String, source: String, completed: Bool = false, @ViewBuilder details: () -> Details) {
        self.title = title; self.source = source; self.completed = completed; self.details = details()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium)).strikethrough(completed).foregroundStyle(.primary)
            Text(source).font(.caption).foregroundStyle(.secondary)
            details.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private struct TaskEventRow: View {
    let event: TaskCalendarEvent
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack {
                Image(systemName: "calendar").frame(width: 44, height: 44).accessibilityHidden(true)
                TaskItemContent(title: event.title.isEmpty ? AppLocalized("未命名日程") : event.title, source: event.source) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.start, format: .dateTime.year().month().day())
                        Spacer(minLength: 8)
                        if event.allDay {
                            Text("全天")
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(event.start, format: .dateTime.hour().minute())
                                Text(verbatim: "–")
                                Text(event.end, format: Calendar.current.isDate(event.start, inSameDayAs: event.end)
                                    ? .dateTime.hour().minute() : .dateTime.year().month().day().hour().minute())
                            }.monospacedDigit().multilineTextAlignment(.trailing)
                        }
                    }.accessibilityElement(children: .combine)
                    if let location = event.location, !location.isEmpty {
                        Text(location)
                    }
                }
            }.foregroundStyle(.primary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("查看日程详情")
    }
}

private struct TaskEventDetail: View {
    let event: TaskCalendarEvent
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title.isEmpty ? AppLocalized("未命名日程") : event.title).font(.title3.weight(.semibold))
                    Text(event.source).foregroundStyle(.secondary)
                    if event.allDay { Text("全天") }
                    LabeledContent("开始") { Text(event.start, format: .dateTime.year().month().day().hour().minute()) }
                    LabeledContent(event.allDay ? "结束（不含）" : "结束") { Text(event.end, format: .dateTime.year().month().day().hour().minute()) }
                }
                if let location = event.location, !location.isEmpty { Section("地点") { Text(location) } }
                if let notes = event.notes, !notes.isEmpty { Section("备注") { Text(notes).textSelection(.enabled) } }
                Text("日程为只读展示，请在系统日历中编辑。").font(.subheadline).foregroundStyle(.secondary)
            }.navigationTitle("日程详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct SystemReminderRow: View {
    @ObservedObject var model: SystemRemindersModel
    let item: EKReminder
    let edit: (EKReminder) -> Void
    let delete: (EKReminder) -> Void

    var body: some View {
        let writable = item.calendar.allowsContentModifications
        let busy = model.busyIDs.contains(item.calendarItemIdentifier)
        let action = AppLocalized(item.isCompleted ? "标为未完成" : "完成待办")
        HStack {
            Button { Task { await model.toggle(item) } } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!writable || busy)
            .accessibilityLabel(action)
            Button { edit(item) } label: {
                TaskItemContent(title: item.title ?? AppLocalized("未命名待办"), source: item.calendar.title, completed: item.isCompleted) {
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
                Button { delete(item) } label: { Label("删除", systemImage: "trash") }
                    .tint(.red).disabled(busy)
            }
        }
        .contextMenu {
            Button("编辑待办") { edit(item) }.disabled(busy)
            if writable {
                Button(action) { Task { await model.toggle(item) } }.disabled(busy)
                Button("删除", role: .destructive) { delete(item) }.disabled(busy)
            }
        }
        .accessibilityActions {
            if !busy {
                Button("编辑待办") { edit(item) }
                if writable {
                    Button(action) { Task { await model.toggle(item) } }
                    Button("删除", role: .destructive) { delete(item) }
                }
            }
        }
    }
}

private struct ReminderEditorItem: Identifiable {
    let id = UUID()
    let reminder: EKReminder?
    var suggestedDate: Date? = nil
}

private struct ReminderEditor: View {
    @ObservedObject var model: SystemRemindersModel
    let existing: EKReminder?
    let preferredCalendarID: String?
    let suggestedDate: Date?
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
            hasDueDate = existing?.dueDateComponents != nil || (existing == nil && suggestedDate != nil)
            hasTime = existing?.dueDateComponents?.hour != nil
            dueDate = ReminderDateEditing.date(from: existing?.dueDateComponents) ?? suggestedDate ?? Date()
            dateChanged = existing == nil && suggestedDate != nil
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
