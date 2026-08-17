import Foundation
import Testing
@testable import speech_note

struct AppDeepLinkTests {
    @Test func parsesStartRecordingHost() {
        let url = URL(string: "voicecontext://start-recording")!
        #expect(AppDeepLink.parse(url) == .startRecording)
    }

    @Test func parsesRecordAlias() {
        let url = URL(string: "voicecontext://record")!
        #expect(AppDeepLink.parse(url) == .startRecording)
    }

    @Test func rejectsUnknownSchemeAndPath() {
        #expect(AppDeepLink.parse(URL(string: "https://example.com/start-recording")!) == nil)
        #expect(AppDeepLink.parse(URL(string: "voicecontext://settings")!) == nil)
    }

    @Test func startRecordingURLUsesRegisteredScheme() {
        #expect(AppDeepLink.startRecordingURL.scheme == "voicecontext")
        #expect(AppDeepLink.startRecordingURL.host == "start-recording")
    }
}
