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
    var pauseNextRead = false
    var pendingRead: CheckedContinuation<Void, Never>?
    var failNextRead = false
    func pause() { pauseNextRead = true }
    func resume() { pendingRead!.resume(); pendingRead = nil }
    func fail() { failNextRead = true }
    func invalidate() { operations.append("invalidate") }
    func read(overview: DateInterval, future: DateInterval) async throws -> SystemCalendarSnapshot {
        operations.append("read")
        if pauseNextRead {
            pauseNextRead = false
            await withCheckedContinuation { pendingRead = $0 }
        }
        if failNextRead {
            failNextRead = false
            throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Refresh failed"])
        }
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
        let firstOccurrence = TaskCalendarEvent.occurrenceID(calendarItemID: "repeat", start: interval.start)
        precondition(firstOccurrence != TaskCalendarEvent.occurrenceID(calendarItemID: "repeat", start: interval.end), "Different repeats cannot open the same native detail")
        precondition(firstOccurrence != TaskCalendarEvent.occurrenceID(calendarItemID: "other", start: interval.start), "Different items at the same time remain distinct")
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
        await model.loadIfNeeded(overview: interval, future: interval)
        await model.loadIfNeeded(overview: interval, future: interval)
        let repeatedAppearances = await reader.operations
        precondition(repeatedAppearances == operations, "Returning to the same tab must not reread EventKit")

        await reader.pause()
        let refresh = Task { await model.refresh(overview: interval, future: interval) }
        while await reader.pendingRead == nil { await Task.yield() }
        precondition(model.loading && model.hasSnapshot(overview: interval, future: interval), "A background refresh must keep the current list available")
        precondition(model.sources.count == 1 && model.events.count == 1)
        let otherInterval = DateInterval(start: interval.end, duration: interval.duration)
        precondition(!model.hasSnapshot(overview: otherInterval, future: interval), "Cached rows must not be used for another calendar range")
        await reader.resume()
        await refresh.value
        await reader.fail()
        await model.refresh(overview: interval, future: interval)
        precondition(model.readError == "Refresh failed" && model.hasSnapshot(overview: interval, future: interval), "A failed refresh must preserve the last successful list")
        await model.loadIfNeeded(overview: interval, future: interval)
        let afterFailedReentry = await reader.operations
        precondition(afterFailedReentry == ["invalidate", "read", "read", "read"], "Tab switching must not start an automatic retry after a refresh failure")

        auth.set(.denied)
        await model.refresh(overview: interval, future: interval)
        precondition(!model.authorized && !model.loading && model.events.isEmpty && model.sources.isEmpty)
        precondition(model.loadedOverview == nil && model.loadedFuture == nil, "Revoked permission must clear coverage")
        precondition(!model.hasSnapshot(overview: interval, future: interval), "Revoked permission must hide cached content")
        let revokedOperations = await reader.operations
        precondition(revokedOperations == ["invalidate", "read", "read", "read", "invalidate"])

        let deniedReader = Reader()
        let denied = SystemCalendarModel(reader: deniedReader, accessRequest: { false }, authorizationStatus: { .denied })
        await denied.requestAccess(overview: interval, future: interval)
        let deniedOperations = await deniedReader.operations
        precondition(deniedOperations == ["invalidate"] && !denied.loading && !denied.requestingAccess && denied.events.isEmpty)
        await denied.loadIfNeeded(overview: interval, future: interval)
        let deniedReentry = await deniedReader.operations
        precondition(deniedReentry == deniedOperations, "Denied access must not be checked again on every tab appearance")

        let changedReader = Reader()
        let changed = SystemCalendarModel(reader: changedReader, authorizationStatus: { .fullAccess })
        await changedReader.pause()
        let initial = Task { await changed.loadIfNeeded(overview: interval, future: interval) }
        while await changedReader.pendingRead == nil { await Task.yield() }
        await changed.loadIfNeeded(overview: interval, future: interval)
        let inFlightOperations = await changedReader.operations
        precondition(inFlightOperations == ["read"], "Reappearing during the initial read must reuse the in-flight request")
        await changedReader.resume()
        await initial.value
        await changed.loadIfNeeded(overview: otherInterval, future: interval)
        let changedOperations = await changedReader.operations
        precondition(changedOperations == ["read", "read"] && changed.loadedOverview == otherInterval, "Changing the visible calendar range must still read the new dates")

        let failed = SystemCalendarModel(reader: Reader(), accessRequest: {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture failure"])
        }, authorizationStatus: { .notDetermined })
        await failed.requestAccess(overview: interval, future: interval)
        precondition(!failed.loading && !failed.requestingAccess && failed.readError == "Fixture failure")
        print("Calendar access regressions passed: cached tab reentry, in-flight reuse, changed ranges, background refresh, refresh failure, permission handling")
    }
}
