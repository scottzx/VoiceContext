import EventKit
import SwiftUI

struct TaskCalendarSource: Identifiable, Sendable {
    let id: String
    let title: String
    let account: String
}

struct TaskCalendarEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let sourceID: String
    let source: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let notes: String?
}

struct SystemCalendarSnapshot: Sendable {
    let sources: [TaskCalendarSource]
    let overview: [TaskCalendarEvent]
    let future: [TaskCalendarEvent]
}

protocol SystemCalendarReading: Sendable {
    func invalidate() async
    func read(overview: DateInterval, future: DateInterval) async throws -> SystemCalendarSnapshot
}

// Create the read session only after access is granted. EventKit objects stay
// on this actor; the UI receives immutable snapshots.
private actor SystemCalendarReader: SystemCalendarReading {
    private var store: EKEventStore?
    func invalidate() { store = nil }

    func read(overview: DateInterval, future: DateInterval) throws -> SystemCalendarSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw NSError(domain: "Yima.Calendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalized("日历访问已关闭，请在系统设置中允许访问。")])
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        let calendars = store.calendars(for: .event)
        let sources = calendars.map { TaskCalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
        func events(in interval: DateInterval) -> [TaskCalendarEvent] {
            guard !calendars.isEmpty else { return [] }
            var result: [String: TaskCalendarEvent] = [:]
            var start = interval.start
            // EventKit truncates queries longer than four years. Query each year separately.
            while start < interval.end {
                let end = min(Calendar.current.date(byAdding: .year, value: 1, to: start)!, interval.end)
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                for event in store.events(matching: predicate) {
                    let id = event.calendarItemIdentifier + ":" + String(event.startDate.timeIntervalSinceReferenceDate)
                    result[id] = TaskCalendarEvent(id: id, title: event.title ?? "", sourceID: event.calendar.calendarIdentifier,
                        source: event.calendar.title, start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                        location: event.location, notes: event.notes)
                }
                start = end
            }
            return result.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        }
        let overviewEvents = events(in: overview)
        let futureEvents = events(in: future)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw NSError(domain: "Yima.Calendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalized("日历访问已关闭，请在系统设置中允许访问。")])
        }
        return SystemCalendarSnapshot(sources: sources, overview: overviewEvents, future: futureEvents)
    }
}

@MainActor
final class SystemCalendarModel: ObservableObject {
    @Published private(set) var sources: [TaskCalendarSource] = []
    @Published private(set) var events: [TaskCalendarEvent] = []
    @Published private(set) var futureEvents: [TaskCalendarEvent] = []
    @Published private(set) var authorization: EKAuthorizationStatus
    @Published private(set) var loading = true
    @Published private(set) var requestingAccess = false
    @Published private(set) var readError: String?
    @Published private(set) var loadedOverview: DateInterval?
    @Published private(set) var loadedFuture: DateInterval?
    private let reader: any SystemCalendarReading
    private let accessRequest: @MainActor () async throws -> Bool
    private let authorizationStatus: @Sendable () -> EKAuthorizationStatus
    private var generation = 0
    var authorized: Bool { authorization == .fullAccess }

    init(reader: any SystemCalendarReading = SystemCalendarReader(),
         accessRequest: @escaping @MainActor () async throws -> Bool = {
             let store = EKEventStore()
             return try await store.requestFullAccessToEvents()
         },
         authorizationStatus: @escaping @Sendable () -> EKAuthorizationStatus = {
             EKEventStore.authorizationStatus(for: .event)
         }) {
        self.reader = reader
        self.accessRequest = accessRequest
        self.authorizationStatus = authorizationStatus
        authorization = authorizationStatus()
    }

    func requestAccess(overview: DateInterval, future: DateInterval) async {
        guard !requestingAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        loading = true
        do {
            let granted = try await accessRequest()
            if granted { await reader.invalidate() }
            await refresh(overview: overview, future: future)
        } catch {
            authorization = authorizationStatus()
            loading = false; readError = error.localizedDescription
        }
    }

    func refresh(overview: DateInterval, future: DateInterval) async {
        generation += 1
        let current = generation
        authorization = authorizationStatus()
        guard authorized else {
            // Foreground/store-change notifications can arrive while the system
            // permission dialog is still open. Keep that request in flight.
            if requestingAccess && authorization == .notDetermined { return }
            await reader.invalidate()
            guard current == generation else { return }
            sources = []; events = []; futureEvents = []; loadedOverview = nil; loadedFuture = nil
            loading = false; readError = nil
            return
        }
        loading = true
        do {
            let result = try await reader.read(overview: overview, future: future)
            guard current == generation else { return }
            sources = result.sources; events = result.overview; futureEvents = result.future
            loadedOverview = overview; loadedFuture = future; readError = nil
        } catch {
            guard current == generation else { return }
            readError = error.localizedDescription
        }
        authorization = authorizationStatus()
        if !authorized { sources = []; events = []; futureEvents = []; loadedOverview = nil; loadedFuture = nil }
        loading = false
    }
}
