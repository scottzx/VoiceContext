import ActivityKit
import Foundation

public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isRecording: Bool
        public var isPaused: Bool
        public var startedAt: Date

        public init(isRecording: Bool, isPaused: Bool, startedAt: Date) {
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.startedAt = startedAt
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
