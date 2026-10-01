import EventKit
import SwiftUI

func AppLocalized(_ key: String.LocalizationValue) -> String { String(localized: key) }

private final class Authorization: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EKAuthorizationStatus = .notDetermined
    func get() -> EKAuthorizationStatus { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: EKAuthorizationStatus) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private actor Reader: SystemCalendarReading {
    var operations: [String] = []
    func invalidate() { operations.append("invalidate") }
    func read(overview: DateInterval, future: DateInterval) -> SystemCalendarSnapshot {
        operations.append("read")
        let event = TaskCalendarEvent(id: "event", title: "Fixture", sourceID: "source", source: "Fixture",
            start: overview.start, end: overview.end, allDay: false, location: nil, notes: nil)
        return SystemCalendarSnapshot(sources: [TaskCalendarSource(id: "source", title: "Fixture", account: "Fixture")],
            overview: [event], future: [event])
    }
}

@MainActor
private final class PermissionDialog {
    var continuation: CheckedContinuation<Bool, Never>?
    var requests = 0
    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ granted: Bool) { continuation!.resume(returning: granted); continuation = nil }
}

@main
struct CalendarAccessTests {
    @MainActor static func main() async {
        let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 0), duration: 86400)
        let auth = Authorization(), reader = Reader(), dialog = PermissionDialog()
        let model = SystemCalendarModel(reader: reader, accessRequest: { await dialog.request() }, authorizationStatus: { auth.get() })
        precondition(model.loading)
        let request = Task { await model.requestAccess(overview: interval, future: interval) }
        while dialog.continuation == nil { await Task.yield() }
        precondition(model.requestingAccess, "Initial data loading must not block the permission request")
        await model.requestAccess(overview: interval, future: interval)
        precondition(dialog.requests == 1, "Ignore duplicate authorization taps")
        await model.refresh(overview: interval, future: interval)
        precondition(model.requestingAccess && model.loading, "Foreground notifications must not finish an open permission dialog")
        auth.set(.fullAccess)
        dialog.complete(true)
        await request.value
        precondition(model.authorized && !model.loading && !model.requestingAccess && model.readError == nil)
        precondition(model.sources.count == 1 && model.events.count == 1 && model.futureEvents.count == 1)
        precondition(model.loadedOverview == interval && model.loadedFuture == interval)
        let operations = await reader.operations
        precondition(operations == ["invalidate", "read"], "Read through a fresh EventKit session after granting access")

        auth.set(.denied)
        await model.refresh(overview: interval, future: interval)
        precondition(!model.authorized && !model.loading && model.events.isEmpty && model.sources.isEmpty)
        precondition(model.loadedOverview == nil && model.loadedFuture == nil, "Revoked permission must clear coverage")
        let revokedOperations = await reader.operations
        precondition(revokedOperations == ["invalidate", "read", "invalidate"])

        let deniedReader = Reader()
        let denied = SystemCalendarModel(reader: deniedReader, accessRequest: { false }, authorizationStatus: { .denied })
        await denied.requestAccess(overview: interval, future: interval)
        let deniedOperations = await deniedReader.operations
        precondition(deniedOperations == ["invalidate"] && !denied.loading && !denied.requestingAccess && denied.events.isEmpty)

        let failed = SystemCalendarModel(reader: Reader(), accessRequest: {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture failure"])
        }, authorizationStatus: { .notDetermined })
        await failed.requestAccess(overview: interval, future: interval)
        precondition(!failed.loading && !failed.requestingAccess && failed.readError == "Fixture failure")
        print("Calendar access regressions passed: initial loading, duplicate requests, foreground during permission, grant reload, revoked/denied access, request errors")
    }
}
