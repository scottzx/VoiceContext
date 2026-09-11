import Foundation
import Testing
@testable import speech_note

struct RecordingLiveActivityTests {
    @Test func attributesAndContentStateCodableRoundtrip() throws {
        let now = Date()
        let contentState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            startedAt: now
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(contentState)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RecordingActivityAttributes.ContentState.self, from: data)

        #expect(decoded.isRecording == true)
        #expect(decoded.isPaused == false)
        #expect(abs(decoded.startedAt.timeIntervalSince(now)) < 0.001)
    }

    @Test func pausedContentStateRoundtrip() throws {
        let now = Date()
        let contentState = RecordingActivityAttributes.ContentState(
            isRecording: false,
            isPaused: true,
            startedAt: now
        )

        let data = try JSONEncoder().encode(contentState)
        let decoded = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: data)

        #expect(decoded.isRecording == false)
        #expect(decoded.isPaused == true)
    }

    @Test func attributesInitialization() {
        let sessionID = UUID().uuidString.lowercased()
        let attributes = RecordingActivityAttributes(sessionID: sessionID)
        #expect(attributes.sessionID == sessionID)
    }
}
