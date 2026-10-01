import Foundation

enum TaskCalendarRules {
    enum Group: CaseIterable { case overdue, today, future, unscheduled }

    static func group(due: Date?, today: Date, calendar: Calendar = .current) -> Group {
        guard let due else { return .unscheduled }
        let start = calendar.startOfDay(for: today)
        if due < start { return .overdue }
        return calendar.isDate(due, inSameDayAs: today) ? .today : .future
    }

    static func intersects(start: Date, end: Date, day: Date, calendar: Calendar = .current) -> Bool {
        let interval = calendar.dateInterval(of: .day, for: day)!
        // EventKit's all-day end is exclusive. Zero-duration events belong to their start day.
        if start == end { return interval.contains(start) && start < interval.end }
        return start < interval.end && end > interval.start
    }

    static func days(month: Date, selected: Date, expanded: Bool, calendar: Calendar = .current) -> [Date] {
        let interval = calendar.dateInterval(of: .month, for: month)!
        let anchor = expanded ? interval.start : calendar.startOfDay(for: selected)
        let offset = (calendar.component(.weekday, from: anchor) + 5) % 7
        let first = calendar.date(byAdding: .day, value: -offset, to: anchor)!
        let count = expanded ? ((offset + calendar.range(of: .day, in: .month, for: month)!.count + 6) / 7) * 7 : 7
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    static func page(month: Date, selected: Date, expanded: Bool, step: Int,
                     calendar: Calendar = .current) -> (month: Date, selected: Date) {
        if expanded {
            return (calendar.date(byAdding: .month, value: step,
                                  to: calendar.dateInterval(of: .month, for: month)!.start)!, selected)
        }
        let next = calendar.date(byAdding: .day, value: step * 7, to: selected)!
        return (next, next)
    }
}

/// Separate instances persist calendar and reminder identifiers, never display names.
struct TaskSourceSelection: Codable, Equatable {
    var known: Set<String> = []
    var selected: Set<String> = []

    @discardableResult mutating func reconcile(_ available: Set<String>) -> Bool {
        let removed = !known.subtracting(available).isEmpty
        selected = selected.intersection(available).union(available.subtracting(known))
        known = available
        return removed
    }

    mutating func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var encoded: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
    init(encoded: String) { self = (try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8))) ?? Self() }
    init() {}
}
