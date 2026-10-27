import Foundation

// Host-only platform boundaries. The production coordinator, capture event
// types and state machine are compiled unchanged by the companion script.
@MainActor final class AACSegmentRecorder {
    nonisolated init() {}
    typealias Segment = CaptureTypes.Segment
    typealias CaptureEvent = CaptureTypes.CaptureEvent
    static let defaultSegmentDuration: TimeInterval = 60
    var onSegmentClosed: (@Sendable (Segment) -> Void)?
    var onCaptureEvent: (@Sendable (CaptureEvent) -> Void)?
    var currentSample: Int64 = 16_000
    var resumeAttempts = 0
    var resumeError: NSError?
    var cancelCount = 0
    func start(in directory: URL, segmentDuration: TimeInterval, initialSampleOffset: Int64) async throws {}
    func pause() throws {}
    func resume() throws {
        resumeAttempts += 1
        if let resumeError { throw resumeError }
    }
    func stop() throws -> Segment {
        Segment(id: UUID(), url: URL(fileURLWithPath: "/tmp/host-only.m4a"), startSample: 0,
                endSample: currentSample, startedAt: Date(), endedAt: Date())
    }
    func cancel() { cancelCount += 1 }
    func emit(_ kind: CaptureEvent.Kind, diagnostic: CaptureEvent.Diagnostic? = nil) {
        onCaptureEvent?(.init(kind: kind, occurredAt: Date(), sampleIndex: currentSample, diagnostic: diagnostic))
    }
}

enum TranscriptionLanguageMode { static let current = "chinese" }
nonisolated struct Recording: Sendable {
    let id = UUID()
    let startedAt: Date
    let title: String?
    let isMeeting: Bool
    let languageMode: String
    var state: RecordingState = .recording
    func lifecycleState(jobs: [Int], liveCaptureState: RecordingCaptureState?) -> RecordingLifecycleState {
        RecordingLifecycleState()
    }
}
nonisolated struct RecordingLifecycleState: Sendable {}
nonisolated struct LowStorageGuard { func validateCanStartRecording(at url: URL) throws {} }
enum ForegroundTranscriptionScheduler {
    struct Outcome { enum State { case completed, failed(message: String) } }
}

actor RecordingRepository {
    nonisolated let rootURL = URL(fileURLWithPath: "/tmp/recording-recovery-host")
    var recordings: [UUID: Recording] = [:]
    var storedGaps: [UUID: RecordingGap] = [:]
    var storedChunks: [UUID: AudioChunk] = [:]
    var failGapPersistence = false
    func createRecording(_ recording: Recording, at: Date) throws { recordings[recording.id] = recording }
    func recording(id: UUID) throws -> Recording? { recordings[id] }
    func changeState(recordingID: UUID, to state: RecordingState, endedAt: Date? = nil, at: Date) throws {
        recordings[recordingID]?.state = state
    }
    func addChunk(_ chunk: AudioChunk, at: Date) throws { storedChunks[chunk.id] = chunk }
    func chunks(recordingID: UUID) throws -> [AudioChunk] { storedChunks.values.filter { $0.recordingID == recordingID } }
    func jobs(recordingID: UUID) throws -> [Int] { [] }
    func reconcileChunksFromDisk(recordingID: UUID) throws -> [AudioChunk] { [] }
    func openGap(_ gap: RecordingGap, at: Date) throws {
        if failGapPersistence { throw NSError(domain: "HostJournal", code: 28) }
        storedGaps[gap.id] = gap
    }
    func closeGap(id: UUID, endSample: Int64, endedAt: Date) throws { storedGaps[id]?.endSample = endSample; storedGaps[id]?.endedAt = endedAt }
    func gaps(recordingID: UUID) throws -> [RecordingGap] { storedGaps.values.filter { $0.recordingID == recordingID } }
    func setFailGapPersistence(_ value: Bool) { failGapPersistence = value }
}

@MainActor final class MPRemoteCommandCenter {
    static let instance = MPRemoteCommandCenter()
    static func shared() -> MPRemoteCommandCenter { instance }
    let stopCommand = RemoteCommand()
}
@MainActor final class RemoteCommand {
    enum Result { case success }
    var isEnabled = false
    func addTarget(_ handler: (Int) -> Result) -> Any { 0 }
    func removeTarget(_ target: Any) {}
}
@MainActor final class MPNowPlayingInfoCenter {
    static let instance = MPNowPlayingInfoCenter()
    static func `default`() -> MPNowPlayingInfoCenter { instance }
    var nowPlayingInfo: [String: Any]?
}
enum RecordingAudioSession { static let playbackDidRelease = Notification.Name("host.playbackDidRelease") }
enum RecordingLiveActivityCommand { case stop, pause, resume }
@MainActor protocol RecordingLiveActivityCommandHandling: AnyObject {
    func handleLiveActivityCommand(_ command: RecordingLiveActivityCommand) async
}
@MainActor final class RecordingLiveActivityCommandCenter {
    static let shared = RecordingLiveActivityCommandCenter()
    weak var handler: (any RecordingLiveActivityCommandHandling)?
    func startObserving() {}
}
@MainActor final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()
    func startActivity(recordingID: UUID, startedAt: Date) {}
    func updateActivity(isPaused: Bool, isInterrupted: Bool = false) {}
    func endActivity() {}
}

@main struct RecordingCaptureRecoveryCheck {
    @MainActor static func drainEvents() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }

    @MainActor static func context() async throws -> (RecordingSessionCoordinator, AACSegmentRecorder, RecordingRepository, UUID) {
        let capture = AACSegmentRecorder()
        let repository = RecordingRepository()
        let coordinator = RecordingSessionCoordinator(repository: repository, capture: capture)
        let id = try await coordinator.start()
        return (coordinator, capture, repository, id)
    }

    @MainActor static func main() async throws {
        // Background `shouldResume=false` must still attempt capture; the gap
        // ends at successful recovery, rather than merely at the system event.
        do {
            let (coordinator, capture, repository, id) = try await context()
            coordinator.applicationEnteredBackground()
            capture.emit(.interruptionBegan)
            await drainEvents()
            precondition(coordinator.captureState == .interrupted)
            capture.emit(.interruptionEnded(shouldResume: false))
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .recording)
            let gaps = try await repository.gaps(recordingID: id)
            precondition(gaps.count == 1 && gaps[0].endedAt != nil)
            await coordinator.cancel()
        }

        // A still-active call is rejected by iOS. Playback/configuration events
        // do not retry it; foreground/manual controls may make one attempt.
        do {
            let (coordinator, capture, _, _) = try await context()
            capture.emit(.interruptionBegan)
            await drainEvents()
            capture.resumeError = NSError(domain: "HostCall", code: 561017449)
            coordinator.applicationBecameActive()
            NotificationCenter.default.post(name: RecordingAudioSession.playbackDidRelease, object: nil)
            capture.emit(.engineConfigurationChanged)
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .interrupted)
            do { try await coordinator.resume(); preconditionFailure("Expected platform activation failure") }
            catch { precondition((error as NSError).domain == "HostCall") }
            precondition(capture.resumeAttempts == 2 && coordinator.captureState == .interrupted)
            capture.resumeError = nil
            capture.emit(.interruptionEnded(shouldResume: true))
            await drainEvents()
            precondition(capture.resumeAttempts == 3 && coordinator.captureState == .recording)
            await coordinator.cancel()
        }

        // The system does not guarantee an ended notification. Neither a
        // foreground return nor explicit Continue may remain permanently gated.
        do {
            let (coordinator, capture, _, _) = try await context()
            capture.emit(.interruptionBegan)
            await drainEvents()
            coordinator.applicationBecameActive()
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .recording)
            capture.emit(.interruptionBegan)
            await drainEvents()
            try await coordinator.resume()
            precondition(capture.resumeAttempts == 2 && coordinator.captureState == .recording)
            await coordinator.cancel()
        }

        // A user pause survives both system interruption and engine changes.
        do {
            let (coordinator, capture, _, _) = try await context()
            try await coordinator.pause()
            capture.emit(.engineConfigurationChanged)
            capture.emit(.interruptionBegan)
            capture.emit(.interruptionEnded(shouldResume: true))
            await drainEvents()
            precondition(capture.resumeAttempts == 0 && coordinator.captureState == .paused)
            try await coordinator.resume()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .recording)
            await coordinator.cancel()
        }

        // Activation failures keep the capture interrupted, retain domain/code
        // and leave the gap open. A later explicit lifecycle signal retries.
        do {
            let (coordinator, capture, repository, id) = try await context()
            capture.resumeError = NSError(domain: "HostAudioSession", code: 561017449,
                                          userInfo: [NSLocalizedDescriptionKey: "Insufficient audio priority"])
            capture.emit(.interruptionBegan)
            capture.emit(.interruptionEnded(shouldResume: false))
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .interrupted)
            precondition(coordinator.lastCaptureDiagnostic?.domain == "HostAudioSession")
            precondition(coordinator.lastCaptureDiagnostic?.code == 561017449)
            precondition(coordinator.lastCaptureDiagnostic?.message == "Insufficient audio priority")
            let gaps = try await repository.gaps(recordingID: id)
            precondition(gaps.count == 1 && gaps[0].endedAt == nil)
            await drainEvents()
            precondition(capture.resumeAttempts == 1, "No blind activation polling")
            capture.resumeError = nil
            coordinator.applicationBecameActive()
            await drainEvents()
            precondition(capture.resumeAttempts == 2 && coordinator.captureState == .recording)
            await coordinator.cancel()
        }

        // A known stopped-engine configuration event recovers through the same
        // state machine. Late events after stop/cancel cannot restart capture.
        do {
            let (coordinator, capture, repository, id) = try await context()
            var stoppedCallbacks = 0
            coordinator.onCaptureStopped = { stoppedID in
                precondition(stoppedID == id && coordinator.activeRecordingID == nil)
                precondition(coordinator.captureState == .idle && coordinator.presentationState == .idle)
                stoppedCallbacks += 1
                await Task.yield()
            }
            capture.emit(.engineConfigurationChanged)
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .recording)
            let gaps = try await repository.gaps(recordingID: id)
            precondition(gaps.count == 1 && gaps[0].reason == .routeChange && gaps[0].endedAt != nil)
            _ = try await coordinator.stop()
            precondition(stoppedCallbacks == 1)
            capture.emit(.engineConfigurationChanged)
            capture.emit(.interruptionEnded(shouldResume: true))
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .idle)
            await coordinator.cancel()
            precondition(stoppedCallbacks == 1)
        }

        do {
            let (coordinator, _, _, _) = try await context()
            var stoppedCallbacks = 0
            coordinator.onCaptureStopped = { _ in stoppedCallbacks += 1 }
            await coordinator.cancel()
            precondition(stoppedCallbacks == 0, "Cancel must not schedule stopped-recording processing")
        }

        // Write diagnostics retain the actual NSError instead of a generic gap.
        do {
            let (coordinator, capture, repository, id) = try await context()
            let diagnostic = AACSegmentRecorder.CaptureEvent.Diagnostic(operation: "writeAudio",
                error: NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSLocalizedDescriptionKey: "Disk full"]))
            capture.emit(.writeFailed, diagnostic: diagnostic)
            await drainEvents()
            precondition(coordinator.lastCaptureDiagnostic == diagnostic)
            let gaps = try await repository.gaps(recordingID: id)
            precondition(gaps.count == 1 && gaps[0].reason == .writeFailure)
            await coordinator.cancel()
        }

        // Journal failure must not prevent engine recovery or swallow details.
        do {
            let (coordinator, capture, repository, _) = try await context()
            await repository.setFailGapPersistence(true)
            capture.emit(.engineConfigurationChanged)
            await drainEvents()
            precondition(capture.resumeAttempts == 1 && coordinator.captureState == .recording)
            precondition(coordinator.lastCaptureDiagnostic?.domain == "HostJournal")
            await coordinator.cancel()
        }
        print("PASS: background interruption recovery, call/pause/stop guards, engine-change recovery, open failure gaps and NSError diagnostics; host only, no audio runtime")
    }
}
