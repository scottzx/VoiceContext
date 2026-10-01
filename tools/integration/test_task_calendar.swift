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
        print("Task calendar regressions passed: local grouping, Monday grids, month/week paging, midnight, all-day, cross-day, DST, source persistence/removal/independence")
    }
}
