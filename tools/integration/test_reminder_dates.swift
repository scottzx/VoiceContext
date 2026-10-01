import Foundation

@main
struct ReminderDateTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var original = DateComponents()
        original.calendar = calendar
        original.timeZone = calendar.timeZone
        original.year = 2026; original.month = 10; original.day = 1
        original.hour = 23; original.minute = 47; original.second = 19
        original.nanosecond = 123_000_000
        let edited = ISO8601DateFormatter().date(from: "2026-10-02T18:30:00Z")!
        let unchanged = ReminderDateEditing.components(existing: original, date: edited,
            hasTime: true, dateChanged: false, timeChanged: false)
        precondition(unchanged == original, "Untouched components must remain identical")
        let day = ReminderDateEditing.components(existing: original, date: edited,
            hasTime: true, dateChanged: true, timeChanged: false)
        precondition(day.year == 2026 && day.month == 10 && day.day == 3, "Edit must use the original time zone")
        precondition(day.hour == 23 && day.minute == 47 && day.second == 19 && day.nanosecond == original.nanosecond)
        precondition(day.timeZone == original.timeZone && day.calendar == original.calendar)
        let time = ReminderDateEditing.components(existing: original, date: edited,
            hasTime: true, dateChanged: false, timeChanged: true)
        precondition(time.day == 1 && time.hour == 2 && time.minute == 30 && time.second == 0 && time.nanosecond == 0)
        let allDay = ReminderDateEditing.components(existing: original, date: edited,
            hasTime: false, dateChanged: false, timeChanged: true)
        precondition(allDay.hour == nil && allDay.minute == nil && allDay.second == nil && allDay.nanosecond == nil)
        let newDay = ReminderDateEditing.components(existing: nil, date: edited,
            hasTime: false, dateChanged: true, timeChanged: false)
        precondition(newDay.hour == nil && ReminderDateEditing.date(from: newDay) != nil)
        let newTime = ReminderDateEditing.components(existing: nil, date: edited,
            hasTime: true, dateChanged: true, timeChanged: true)
        precondition(newTime.hour != nil && newTime.minute != nil)
        var toolDate = DateComponents()
        toolDate.year = 2026; toolDate.month = 10; toolDate.day = 1
        precondition(ReminderDateEditing.date(from: toolDate) != nil, "CLI date components without a calendar must display")
        precondition(ReminderDateEditing.date(from: nil) == nil)
        print("Reminder date regressions passed (untouched/date/time/all-day/new/time-zone/CLI dates)")
    }
}
