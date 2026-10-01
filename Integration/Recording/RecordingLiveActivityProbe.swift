#if DEBUG
import ActivityKit
import Foundation

/// Exercises real ActivityKit updates with temporary recordings and no microphone.
@MainActor
public enum RecordingLiveActivityProbe {
    public static func run() async {
        var report: [String: Any] = [:]
        var startedActivity = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  Activity<RecordingActivityAttributes>.activities.isEmpty else {
                throw failure("Live Activities disabled or a recording activity already exists")
            }
            let repository = try RecordingRepository(rootURL: root)
            let capture = ProbeCapture()
            let coordinator = RecordingSessionCoordinator(repository: repository, capture: capture)
            let id = try await coordinator.start()
            startedActivity = true
            coordinator.applicationEnteredBackground()
            capture.emit(.interruptionBegan)
            try await waitForInterruption(coordinator)
            try await checkActivity(id: id, paused: false, interrupted: true)
            capture.emit(.interruptionEnded(shouldResume: false))
            try await Task.sleep(for: .milliseconds(100))
            try await checkActivity(id: id, paused: false, interrupted: true)
            report["otherAudio"] = "interrupted; no false resume in background"

            capture.resumeFails = true
            do {
                try await coordinator.resume()
                throw failure("Failed microphone resume was accepted")
            } catch AACSegmentRecorder.RecorderError.notRecording {}
            try await checkActivity(id: id, paused: false, interrupted: true)
            capture.resumeFails = false
            try await coordinator.resume()
            try await checkActivity(id: id, paused: false, interrupted: false)
            try await coordinator.pause()
            try await checkActivity(id: id, paused: true, interrupted: false)
            try await coordinator.resume()
            report["pauseResume"] = "pause, failed resume and successful resume match capture"

            // A missing journal reproduces the old path that skipped the card update.
            let journal = root.appendingPathComponent("recording-journal.jsonl")
            let savedJournal = try Data(contentsOf: journal)
            try FileManager.default.removeItem(at: journal)
            capture.emit(.interruptionBegan)
            try await waitForInterruption(coordinator)
            try await checkActivity(id: id, paused: false, interrupted: true)
            try savedJournal.write(to: journal)
            report["persistenceFailure"] = "interrupted card remains truthful when journal write fails"

            let manager = RecordingLiveActivityManager.shared
            manager.updateActivity(isPaused: false)
            manager.updateActivity(isPaused: true)
            manager.updateActivity(isPaused: false, isInterrupted: true)
            try await checkActivity(id: id, paused: false, interrupted: true)
            await coordinator.cancel()
            await manager.waitForPendingUpdates()
            try check(Activity<RecordingActivityAttributes>.activities.isEmpty, "Activity ended after queued updates")
            report["orderedUpdates"] = "latest state wins; ending removes card"
            report["passed"] = true
        } catch {
            report["passed"] = false
            report["error"] = String(describing: error)
            if startedActivity {
                RecordingLiveActivityManager.shared.endActivity()
                await RecordingLiveActivityManager.shared.waitForPendingUpdates()
            }
        }
        try? FileManager.default.removeItem(at: root)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: documents.appendingPathComponent("recording-activity-regression.json"), options: .atomic)
            print("[RECORDING_ACTIVITY_RESULT] \(String(decoding: data, as: UTF8.self))")
        } catch { print("[RECORDING_ACTIVITY_WRITE_FAILED] \(error)") }
    }

    private static func waitForInterruption(_ coordinator: RecordingSessionCoordinator) async throws {
        for _ in 0..<100 {
            if coordinator.presentationState == .interrupted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("Capture interruption did not update presentation")
    }

    private static func checkActivity(id: UUID, paused: Bool, interrupted: Bool) async throws {
        await RecordingLiveActivityManager.shared.waitForPendingUpdates()
        var observed = "missing activity"
        // ActivityKit publishes its local content asynchronously after update returns.
        for _ in 0..<200 {
            if let activity = Activity<RecordingActivityAttributes>.activities.first(where: {
                $0.attributes.sessionID == id.uuidString.lowercased()
            }) {
                let state = activity.content.state
                if state.isPaused == paused && state.isInterrupted == interrupted
                    && state.isRecording == (!paused && !interrupted) { return }
                observed = "recording=\(state.isRecording), paused=\(state.isPaused), interrupted=\(state.isInterrupted)"
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw failure("Card mismatch: expected paused=\(paused), interrupted=\(interrupted); observed \(observed)")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RecordingLiveActivityProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private final class ProbeCapture: RecordingCapturing {
        var onSegmentClosed: (@Sendable (AACSegmentRecorder.Segment) -> Void)?
        var onCaptureEvent: (@Sendable (AACSegmentRecorder.CaptureEvent) -> Void)?
        var currentSample: Int64 = 16_000
        var resumeFails = false
        func start(in directory: URL, segmentDuration: TimeInterval, initialSampleOffset: Int64) async throws {}
        func pause() throws {}
        func resume() throws { if resumeFails { throw AACSegmentRecorder.RecorderError.notRecording } }
        func cancel() {}
        func stop() throws -> AACSegmentRecorder.Segment { throw AACSegmentRecorder.RecorderError.notRecording }
        func emit(_ kind: AACSegmentRecorder.CaptureEvent.Kind) {
            onCaptureEvent?(.init(kind: kind, occurredAt: Date(), sampleIndex: currentSample))
        }
    }
}
#endif
