import Foundation

@main
struct TaskCalendarTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let today = date("2026-10-01T16:00:00Z") // Oct 2 locally
        precondition(TaskCalendarRules.group(due: nil, today: today, calendar: calendar) == .unscheduled)
        precondition(TaskCalendarRules.group(due: date("2026-10-01T15:59:59Z"), today: today, calendar: calendar) == .overdue)
        precondition(TaskCalendarRules.group(due: today, today: today, calendar: calendar) == .today)
        precondition(TaskCalendarRules.group(due: date("2026-10-02T16:00:00Z"), today: today, calendar: calendar) == .future)

        let days = TaskCalendarRules.days(month: today, selected: today, expanded: true, calendar: calendar)
        precondition(days.count == 35 && calendar.component(.weekday, from: days.first!) == 2)
        precondition(calendar.component(.day, from: days.first!) == 28)
        precondition(calendar.component(.month, from: days.last!) == 11)
        let week = TaskCalendarRules.days(month: today, selected: today, expanded: false, calendar: calendar)
        precondition(week.count == 7 && calendar.component(.weekday, from: week.first!) == 2)
        let monthly = TaskCalendarRules.page(month: today, selected: today, expanded: true, step: 1, calendar: calendar)
        precondition(monthly.selected == today && calendar.component(.month, from: monthly.month) == 11)
        let weekly = TaskCalendarRules.page(month: today, selected: today, expanded: false, step: -1, calendar: calendar)
        precondition(calendar.component(.day, from: weekly.selected) == 25 && calendar.component(.month, from: weekly.month) == 9)

        let midnight = date("2026-10-01T16:00:00Z")
        let next = date("2026-10-02T16:00:00Z")
        precondition(TaskCalendarRules.intersects(start: midnight, end: next, day: today, calendar: calendar))
        precondition(!TaskCalendarRules.intersects(start: midnight, end: next, day: next, calendar: calendar), "All-day exclusive end must not add a dot on the next day")
        let crossStart = date("2026-10-01T15:30:00Z"), crossEnd = date("2026-10-01T16:30:00Z")
        precondition(TaskCalendarRules.intersects(start: crossStart, end: crossEnd, day: crossStart, calendar: calendar))
        precondition(TaskCalendarRules.intersects(start: crossStart, end: crossEnd, day: crossEnd, calendar: calendar))
        precondition(TaskCalendarRules.intersects(start: midnight, end: midnight, day: midnight, calendar: calendar))
        precondition(!TaskCalendarRules.intersects(start: next, end: next, day: today, calendar: calendar))
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstStart = date("2026-03-08T08:00:00Z"), dstEnd = date("2026-03-09T07:00:00Z")
        precondition(dst.dateInterval(of: .day, for: dstStart)!.duration == 23 * 3600)
        precondition(TaskCalendarRules.intersects(start: dstStart, end: dstEnd, day: dstStart, calendar: dst))
        precondition(!TaskCalendarRules.intersects(start: dstStart, end: dstEnd, day: dstEnd, calendar: dst))

        let leapDay = date("2024-02-29T02:00:00Z")
        let marchDay = date("2024-03-30T02:00:00Z")
        let nextYear = date("2025-02-28T02:00:00Z")
        let dateIndex = TaskDateIndex(dates: [leapDay, leapDay.addingTimeInterval(3600), marchDay, nextYear], calendar: calendar)
        precondition(dateIndex.dates.count == 3, "Items on the same local day share one date option")
        precondition(dateIndex.years == [2025, 2024])
        precondition(dateIndex.months(in: 2024) == [3, 2])
        precondition(dateIndex.days(in: 2024, month: 2) == [29], "Empty dates must not be selectable")
        precondition(dateIndex.date(year: 2024, month: 2, day: 28) == nil)
        precondition(dateIndex.resolving(year: 2025, month: 2, day: 29) == calendar.startOfDay(for: nextYear), "Changing year must replace an unavailable leap day")
        precondition(dateIndex.resolving(year: 2024, month: 3, day: 29) == calendar.startOfDay(for: marchDay))
        let filteredDates = TaskDateIndex(dates: [leapDay], calendar: calendar)
        precondition(filteredDates.resolving(year: 2025, month: 3, day: 30) == calendar.startOfDay(for: leapDay), "Removed source/completed dates cannot leave an invalid selection")
        let emptyDates = TaskDateIndex(dates: [], calendar: calendar)
        precondition(emptyDates.years.isEmpty && emptyDates.resolving(year: 2024, month: 2, day: 29) == nil)
        let midnightDates = TaskDateIndex(dates: [crossStart, crossEnd], calendar: calendar)
        precondition(midnightDates.dates.count == 2, "Local midnight separates dates even within one UTC day")
        let dstDates = TaskDateIndex(dates: [dstStart, dstEnd.addingTimeInterval(-1)], calendar: dst)
        precondition(dstDates.dates == [dstStart], "A short DST day still has one date option")

        var selection = TaskSourceSelection()
        precondition(!selection.reconcile(["calendar-A", "calendar-B"]))
        precondition(selection.selected == ["calendar-A", "calendar-B"])
        selection.toggle("calendar-A")
        precondition(!selection.reconcile(["calendar-A", "calendar-B"]))
        precondition(selection.selected == ["calendar-B"], "Refresh cannot reselect an unchecked source")
        selection.toggle("calendar-B")
        precondition(selection.selected.isEmpty)
        var restored = TaskSourceSelection(encoded: selection.encoded)
        precondition(restored == selection, "An intentionally empty selection must survive reopening")
        precondition(restored.reconcile(["calendar-B", "calendar-C"]))
        precondition(restored.selected == ["calendar-C"], "Remove stale identifiers and select only genuinely new sources")
        var reminders = TaskSourceSelection()
        reminders.reconcile(["calendar-B"])
        precondition(reminders.selected == ["calendar-B"] && !restored.selected.contains("calendar-B"), "Entity-specific preferences must remain independent")
        precondition(reminders.includesReminder(sourceID: "calendar-B", completed: false, showCompleted: false, recentlyCompleted: false))
        precondition(!reminders.includesReminder(sourceID: "calendar-B", completed: true, showCompleted: false, recentlyCompleted: false))
        precondition(reminders.includesReminder(sourceID: "calendar-B", completed: true, showCompleted: true, recentlyCompleted: false))
        precondition(reminders.includesReminder(sourceID: "calendar-B", completed: true, showCompleted: false, recentlyCompleted: true), "Completion feedback remains visible in both pages")
        precondition(!reminders.includesReminder(sourceID: "hidden", completed: false, showCompleted: true, recentlyCompleted: true), "An unchecked source stays hidden even with completion feedback")

        let suite = "Yima.FilterRegression." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(reminders.encoded, forKey: "yima.tasks.reminderSources")
        preferences.set(restored.encoded, forKey: "yima.tasks.eventSources")
        preferences.set(true, forKey: "yima.reminders.showCompleted")
        let reopened = UserDefaults(suiteName: suite)!
        let reopenedReminders = TaskSourceSelection(encoded: reopened.string(forKey: "yima.tasks.reminderSources")!)
        let reopenedEvents = TaskSourceSelection(encoded: reopened.string(forKey: "yima.tasks.eventSources")!)
        precondition(reopenedReminders == reminders && reopenedEvents == restored)
        precondition(reopened.bool(forKey: "yima.reminders.showCompleted"))
        var emptySelection = reopenedReminders
        emptySelection.toggle("calendar-B")
        preferences.set(emptySelection.encoded, forKey: "yima.tasks.reminderSources")
        precondition(TaskSourceSelection(encoded: reopened.string(forKey: "yima.tasks.reminderSources")!).selected.isEmpty,
                     "Persisting no sources must not reset to all sources")
        print("Task calendar regressions passed: local grouping, grids/paging, event boundaries, populated-date wheels, leap-year/filter reconciliation, DST, source persistence/removal/independence")
    }
}
