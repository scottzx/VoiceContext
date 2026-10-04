import Foundation

@MainActor
enum MicrophoneAccess {
    enum Permission { case granted, denied }
    static let deniedStartMessage = "denied"
    static var requests = 0
    static var continuation: CheckedContinuation<Permission, Never>?
    static func requestPermissionIfNeeded() async -> Permission {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    static func resolve(_ permission: Permission) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: permission)
    }
}

enum AACSegmentRecorder {
    static let defaultSegmentDuration: TimeInterval = 60
    enum RecorderError: Error { case microphonePermissionDenied, testFailure }
}

@MainActor
enum LocationAccess {
    static let isAutoRecordLocationEnabled = false
    static func fetchCurrentLocationAddress() async -> String? { nil }
}

@MainActor
final class EntryCoordinator {
    var starts = 0
    var appends = 0
    var shouldFail = false
    var lastTitle: String?
    var lastIsMeeting = false
    func start(isMeeting: Bool, title: String?) async throws -> UUID {
        starts += 1
        lastTitle = title
        lastIsMeeting = isMeeting
        if shouldFail { throw AACSegmentRecorder.RecorderError.testFailure }
        return UUID()
    }
    func startAppend(recordingID: UUID) async throws -> UUID {
        appends += 1
        if shouldFail { throw AACSegmentRecorder.RecorderError.testFailure }
        return recordingID
    }
}

@main
struct RecordingEntryPlaybackChecks {
    @MainActor static func main() async {
        // Production start/append methods are compiled verbatim; only permission,
        // storage/capture and refresh dependencies are replaced with host fakes.
        let model = EntryModel()
        let first = Task { await model.start(title: "  周会  ", isMeeting: true) }
        await waitForPermission()
        precondition(model.isStartingRecording)
        await model.start()
        await model.append(recordingID: UUID())
        precondition(MicrophoneAccess.requests == 1 && model.coordinator.starts == 0)
        MicrophoneAccess.resolve(.granted)
        await first.value
        precondition(!model.isStartingRecording && model.coordinator.starts == 1)
        precondition(model.coordinator.lastTitle == "周会" && model.coordinator.lastIsMeeting)
        await model.start()
        await model.append(recordingID: UUID())
        precondition(MicrophoneAccess.requests == 1)
        print("PASS: duplicate start/append during permission and active capture")

        let denied = EntryModel()
        let denial = Task { await denied.start() }
        await waitForPermission()
        MicrophoneAccess.resolve(.denied)
        await denial.value
        precondition(!denied.isStartingRecording && denied.activeRecordingID == nil)
        precondition(denied.notice == MicrophoneAccess.deniedStartMessage && denied.coordinator.starts == 0)
        let retry = Task { await denied.start(title: "  ") }
        await waitForPermission()
        MicrophoneAccess.resolve(.granted)
        await retry.value
        precondition(denied.coordinator.starts == 1 && denied.coordinator.lastTitle == nil)
        print("PASS: denied permission releases gate for explicit retry")

        let failing = EntryModel()
        failing.coordinator.shouldFail = true
        let failure = Task { await failing.append(recordingID: UUID()) }
        await waitForPermission()
        await failing.start()
        MicrophoneAccess.resolve(.granted)
        await failure.value
        precondition(!failing.isStartingRecording && failing.activeRecordingID == nil)
        precondition(failing.coordinator.appends == 1 && failing.coordinator.starts == 0)
        failing.coordinator.shouldFail = false
        let appendID = UUID()
        let append = Task { await failing.append(recordingID: appendID) }
        await waitForPermission()
        MicrophoneAccess.resolve(.granted)
        await append.value
        precondition(failing.activeRecordingID == appendID && !failing.isStartingRecording)
        print("PASS: append failure releases gate and prevents cross-entry start")

        await verifyRecordingStartFailures()

        typealias Bubble = RecordingDetailPlaybackPresentation.SentenceBubble
        let a = Bubble(id: UUID(), offsetMilliseconds: 2_000, endMilliseconds: 5_000, speaker: "A", text: "a")
        let b = Bubble(id: UUID(), offsetMilliseconds: 8_000, endMilliseconds: 10_000, speaker: "B", text: "b")
        let c = Bubble(id: UUID(), offsetMilliseconds: 10_000, endMilliseconds: 12_000, speaker: "A", text: "c")
        let bubbles = [a, b, c]
        func current(_ time: Double) -> UUID? {
            RecordingDetailPlaybackPresentation.currentBubbleID(at: time, bubbles: bubbles)
        }
        precondition(current(2) == a.id && current(4.999) == a.id)
        precondition(current(8) == b.id && current(10) == c.id)
        for time in [-1, 0, 5, 6, 12, 20, .nan, .infinity] {
            precondition(current(time) == nil, "Non-speech position must not highlight a previous sentence")
        }
        precondition(RecordingDetailPlaybackPresentation.currentBubbleID(at: 3, bubbles: []) == nil)
        let anchor = Bubble(id: UUID(), offsetMilliseconds: 5_000, endMilliseconds: 5_000, speaker: nil, text: "legacy")
        let legacy = RecordingDetailPlaybackPresentation.normalizingBubbleEndTimes([b, anchor])
        precondition(legacy.first?.id == anchor.id && legacy.first?.endMilliseconds == 5_000)
        precondition(RecordingDetailPlaybackPresentation.currentBubbleID(at: 6, bubbles: legacy) == nil)
        precondition(RecordingDetailPlaybackPresentation.currentBubbleID(at: 5, bubbles: legacy) == nil)
        print("PASS: exact speech intervals, boundaries, gaps and invalid positions")
    }

    @MainActor private static func waitForPermission() async {
        while MicrophoneAccess.continuation == nil { await Task.yield() }
    }
}
