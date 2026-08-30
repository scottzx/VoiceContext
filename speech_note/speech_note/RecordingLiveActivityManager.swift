import ActivityKit
import Foundation

/// Manages the lifecycle of the Lock Screen Live Activity card for active recordings.
@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var currentActivity: Activity<RecordingActivityAttributes>?
    private var recordingStartedAt: Date?

    private init() {}

    /// Starts a Live Activity for the active recording session.
    func startActivity(recordingID: UUID, startedAt: Date) {
        // Ensure activities are supported and authorized
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any preexisting activity to prevent duplicates
        endActivity()

        self.recordingStartedAt = startedAt
        let attributes = RecordingActivityAttributes(sessionID: recordingID.uuidString.lowercased())
        let initialState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            startedAt: startedAt
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

    /// Updates the Live Activity (e.g. pause / resume).
    func updateActivity(isPaused: Bool) {
        guard let activity = currentActivity, let startedAt = recordingStartedAt else { return }
        let updatedState = RecordingActivityAttributes.ContentState(
            isRecording: !isPaused,
            isPaused: isPaused,
            startedAt: startedAt
        )
        Task {
            await activity.update(.init(state: updatedState, staleDate: nil))
        }
    }

    /// Ends and removes the Live Activity card immediately.
    func endActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        recordingStartedAt = nil
    }
}
