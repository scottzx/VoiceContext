import ActivityKit
import Foundation
import UIKit

/// Starts a Dynamic Island Live Activity for the active recording.
/// Keeps the lock-screen card and island synchronized with capture state.
@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var currentActivity: Activity<RecordingActivityAttributes>?
    private var recordingStartedAt: Date?
    private var pendingUpdate: Task<Void, Never>?
    private var updateRevision = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func startActivity(recordingID: UUID, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        endActivity()

        self.recordingStartedAt = startedAt
        let attributes = RecordingActivityAttributes(sessionID: recordingID.uuidString.lowercased())
        let initialState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            startedAt: startedAt,
            isInterrupted: false
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            self.currentActivity = activity
        } catch {
            // Live activity request failed; app continues recording normally.
        }
    }

    func updateActivity(isPaused: Bool, isInterrupted: Bool = false) {
        let activities = trackedActivities()
        guard !activities.isEmpty else { return }
        let startedAt = recordingStartedAt
            ?? activities.first?.content.state.startedAt
            ?? Date()
        let updatedState = RecordingActivityAttributes.ContentState(
            isRecording: !isPaused && !isInterrupted,
            isPaused: isPaused && !isInterrupted,
            startedAt: startedAt,
            isInterrupted: isInterrupted
        )
        enqueueUpdate {
            for activity in activities {
                await activity.update(.init(state: updatedState, staleDate: nil))
            }
        }
    }

    func endActivity() {
        let activities = trackedActivities()
        currentActivity = nil
        recordingStartedAt = nil
        guard !activities.isEmpty else { return }
        enqueueUpdate {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func enqueueUpdate(_ operation: @escaping @MainActor () async -> Void) {
        // Interrupted capture no longer grants audio background execution.
        // Hold a short assertion until ActivityKit has accepted the new state.
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording activity update") { [weak self] in
                MainActor.assumeIsolated { self?.finishBackgroundTask() }
            }
        }
        let previous = pendingUpdate
        updateRevision += 1
        let revision = updateRevision
        pendingUpdate = Task {
            await previous?.value
            await operation()
            guard revision == updateRevision else { return }
            pendingUpdate = nil
            finishBackgroundTask()
        }
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    #if DEBUG
    func waitForPendingUpdates() async {
        await pendingUpdate?.value
    }
    #endif

    private func trackedActivities() -> [Activity<RecordingActivityAttributes>] {
        if let currentActivity {
            return [currentActivity]
        }
        return Array(Activity<RecordingActivityAttributes>.activities)
    }
}
