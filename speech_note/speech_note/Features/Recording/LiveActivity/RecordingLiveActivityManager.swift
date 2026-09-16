import ActivityKit
import Foundation

/// Starts a Dynamic Island Live Activity for the active recording.
/// Lock-screen banner content is intentionally empty so only the island shows.
@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var currentActivity: Activity<RecordingActivityAttributes>?
    private var recordingStartedAt: Date?

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
        Task {
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
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func trackedActivities() -> [Activity<RecordingActivityAttributes>] {
        if let currentActivity {
            return [currentActivity]
        }
        return Array(Activity<RecordingActivityAttributes>.activities)
    }
}
