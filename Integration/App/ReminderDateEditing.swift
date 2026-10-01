import Foundation

/// Patch only the date fields the user edited, retaining the system calendar,
/// time zone, and untouched time components.
enum ReminderDateEditing {
    static func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = components.calendar ?? Calendar.current
        calendar.timeZone = components.timeZone ?? calendar.timeZone
        return calendar.date(from: components)
    }

    static func components(existing: DateComponents?, date: Date, hasTime: Bool,
                           dateChanged: Bool, timeChanged: Bool) -> DateComponents {
        var result = existing ?? DateComponents()
        var calendar = result.calendar ?? Calendar.current
        calendar.timeZone = result.timeZone ?? calendar.timeZone
        if existing == nil {
            result.calendar = calendar
            result.timeZone = calendar.timeZone
        }
        if existing == nil || dateChanged {
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            result.year = day.year
            result.month = day.month
            result.day = day.day
        }
        if existing == nil || timeChanged {
            if hasTime {
                let time = calendar.dateComponents([.hour, .minute], from: date)
                result.hour = time.hour
                result.minute = time.minute
                result.second = 0
                result.nanosecond = 0
            } else {
                result.hour = nil
                result.minute = nil
                result.second = nil
                result.nanosecond = nil
            }
        }
        return result
    }
}
