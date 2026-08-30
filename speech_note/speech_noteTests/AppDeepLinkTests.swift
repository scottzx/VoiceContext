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

    @Test func parsesStopRecordingHostAndAliases() {
        let stopUrl = URL(string: "voicecontext://stop-recording")!
        #expect(AppDeepLink.parse(stopUrl) == .stopRecording)

        let aliasUrl = URL(string: "voicecontext://stop")!
        #expect(AppDeepLink.parse(aliasUrl) == .stopRecording)
    }

    @Test func parsesOpenRecordingHost() {
        let openUrl = URL(string: "voicecontext://recording")!
        #expect(AppDeepLink.parse(openUrl) == .openRecording)
    }

    @Test func stopRecordingURLUsesRegisteredScheme() {
        #expect(AppDeepLink.stopRecordingURL.scheme == "voicecontext")
        #expect(AppDeepLink.stopRecordingURL.host == "stop-recording")
    }
}
