import AppIntents
import Foundation
import Testing
@testable import speech_note

struct RecordingLiveActivityTests {
    @Test func attributesAndContentStateCodableRoundtrip() throws {
        let now = Date()
        let contentState = RecordingActivityAttributes.ContentState(
            isRecording: true,
            isPaused: false,
            startedAt: now,
            isInterrupted: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(contentState)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RecordingActivityAttributes.ContentState.self, from: data)

        #expect(decoded.isRecording == true)
        #expect(decoded.isPaused == false)
        #expect(decoded.isInterrupted == false)
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
        #expect(decoded.isInterrupted == false)
    }

    @Test func interruptedContentStateRoundtripAndLegacyDecode() throws {
        let now = Date()
        let contentState = RecordingActivityAttributes.ContentState(
            isRecording: false,
            isPaused: false,
            startedAt: now,
            isInterrupted: true
        )
        let decoded = try JSONDecoder().decode(
            RecordingActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(contentState)
        )
        #expect(decoded.isInterrupted)
        #expect(!decoded.isRecording)
        #expect(!decoded.isPaused)

        struct LegacyState: Codable {
            var isRecording: Bool
            var isPaused: Bool
            var startedAt: Date
        }
        let legacyDecoded = try JSONDecoder().decode(
            RecordingActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(LegacyState(
                isRecording: true,
                isPaused: false,
                startedAt: now
            ))
        )
        #expect(legacyDecoded.isInterrupted == false)
        #expect(legacyDecoded.isRecording)
    }

    @Test func liveActivityCommandRawValuesAreStable() {
        #expect(RecordingLiveActivityCommand.stop.rawValue == "YiJie.speech_note.liveActivity.stop")
        #expect(RecordingLiveActivityCommand.pause.rawValue == "YiJie.speech_note.liveActivity.pause")
        #expect(RecordingLiveActivityCommand.resume.rawValue == "YiJie.speech_note.liveActivity.resume")
    }

    @Test func liveActivityIntentsRunLockedWithoutOpeningApp() {
        #expect(StopRecordingLiveActivityIntent.authenticationPolicy == .alwaysAllowed)
        #expect(PauseRecordingLiveActivityIntent.authenticationPolicy == .alwaysAllowed)
        #expect(ResumeRecordingLiveActivityIntent.authenticationPolicy == .alwaysAllowed)
        #expect(StopRecordingLiveActivityIntent.openAppWhenRun == false)
        #expect(PauseRecordingLiveActivityIntent.openAppWhenRun == false)
        #expect(ResumeRecordingLiveActivityIntent.openAppWhenRun == false)
        #expect(StopRecordingLiveActivityIntent.isDiscoverable == false)
        #expect(PauseRecordingLiveActivityIntent.isDiscoverable == false)
        #expect(ResumeRecordingLiveActivityIntent.isDiscoverable == false)
    }

    @Test func attributesInitialization() {
        let sessionID = UUID().uuidString.lowercased()
        let attributes = RecordingActivityAttributes(sessionID: sessionID)
        #expect(attributes.sessionID == sessionID)
    }
}
