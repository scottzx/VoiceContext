import ActivityKit
import Foundation

public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isRecording: Bool
        public var isPaused: Bool
        public var isInterrupted: Bool
        public var startedAt: Date

        public init(
            isRecording: Bool,
            isPaused: Bool,
            startedAt: Date,
            isInterrupted: Bool = false
        ) {
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.isInterrupted = isInterrupted
            self.startedAt = startedAt
        }

        private enum CodingKeys: String, CodingKey {
            case isRecording, isPaused, isInterrupted, startedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isRecording = try container.decode(Bool.self, forKey: .isRecording)
            isPaused = try container.decode(Bool.self, forKey: .isPaused)
            isInterrupted = try container.decodeIfPresent(Bool.self, forKey: .isInterrupted) ?? false
            startedAt = try container.decode(Date.self, forKey: .startedAt)
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
