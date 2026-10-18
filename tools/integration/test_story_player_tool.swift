import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

@MainActor final class AppNavigationCenter {
    static let shared = AppNavigationCenter()
    var available = true
}

@MainActor final class XiaolanVoiceController {
    static let shared = XiaolanVoiceController()
    var sessionID = "voice"
    var generation: UInt64? = 2
    func executionGeneration(sessionID: String) -> UInt64? {
        sessionID == self.sessionID ? generation : nil
    }
}

struct StoryAudio {
    let id: UUID
    let title: String
    let fileName: String
    let duration: TimeInterval
}

@MainActor final class StoryLibraryStore {
    static let shared = StoryLibraryStore()
    var stories: [StoryAudio] = [
        .init(id: UUID(), title: "小兔回家", fileName: "private.m4a", duration: 100),
        .init(id: UUID(), title: "小兔回家", fileName: "other.m4a", duration: 90)
    ]
    var loadError: String?
}

/// Audio is stubbed to verify tool admission and the controller call contract on macOS.
@MainActor final class StoryPlaybackController {
    static let shared = StoryPlaybackController()
    var currentStoryID: UUID?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var status = "stopped"
    var isRecording = false
    var calls: [String] = []
    var sourceSessionID: String?
    private func admit(_ action: String) throws {
        calls.append(action)
        if isRecording { throw NSError(domain: "StoryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音未结束，无法播放故事。"] ) }
    }
    func play(_ story: StoryAudio, sourceSessionID: String? = nil) throws {
        try admit("play")
        self.sourceSessionID = sourceSessionID
        currentStoryID = story.id
        duration = story.duration
        currentTime = 0
        status = "waiting_for_voice"
    }
    func pause() { calls.append("pause"); isPlaying = false; status = "paused" }
    func resume(sourceSessionID: String? = nil) throws { try admit("resume"); self.sourceSessionID = sourceSessionID; status = "waiting_for_voice" }
    func next(sourceSessionID: String? = nil) throws { try admit("next"); self.sourceSessionID = sourceSessionID; status = "waiting_for_voice" }
    func stop() { calls.append("stop"); currentStoryID = nil; isPlaying = false; status = "stopped" }
    func seek(to value: TimeInterval) throws { try admit("seek"); currentTime = value }
    func snapshot() -> [String: Any] {
        ["status": status, "current_story_id": currentStoryID?.uuidString as Any? ?? NSNull(),
         "position_seconds": currentTime, "duration_seconds": duration]
    }
}

@main struct StoryPlayerToolChecks {
    @MainActor static func main() async throws {
        AgentRuntimePolicies.register(source: "xiaolan_voice", policy: .init(
            allowedTools: ["story_player"], noticeAllowedTools: ["answer_user"],
            additionalTools: [StoryPlayerTool.definition]
        ))
        AgentRuntimePolicies.register(source: "forged_voice", policy: .init(
            allowedTools: ["story_player"], requiresNavigationBinding: true
        ))
        let library = StoryLibraryStore.shared
        let player = StoryPlaybackController.shared
        let voice = XiaolanVoiceController.shared
        func call(_ args: [String: Any], source: String? = "xiaolan_voice", executor: Bool = false,
                  notice: Bool = false, generation: UInt64? = 2, session: String? = "voice") -> (output: String, success: Bool) {
            StoryPlayerTool.execute(args, sessionID: session, sessionSource: source, isExecutor: executor,
                                    noticeDriven: notice, voiceGeneration: generation)
        }
        func json(_ result: (output: String, success: Bool)) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
        }
        func rejected(_ args: [String: Any]) {
            do { _ = try StoryPlayerTool.invocation(args); preconditionFailure("Invalid story arguments accepted: \(args)") }
            catch {}
        }
        for args: [String: Any] in [
            [:], ["action": "download"], ["action": "list", "query": "小兔"],
            ["action": "status", "story_id": UUID().uuidString], ["action": "pause", "position_seconds": 0],
            ["action": "resume", "url": "https://example.test/story.mp3"], ["action": "next", "file_name": "private.m4a"],
            ["action": "stop", "extra": NSNull()], ["action": "play"], ["action": "play", "story_id": "小兔回家"],
            ["action": "play", "story_id": "file:///tmp/story.m4a"], ["action": "play", "story_id": UUID().uuidString, "position_seconds": 0],
            ["action": "seek"], ["action": "seek", "position_seconds": true], ["action": "seek", "position_seconds": "5"],
            ["action": "seek", "position_seconds": -1], ["action": "seek", "position_seconds": 0.5],
            ["action": "seek", "position_seconds": Double.nan], ["action": "seek", "position_seconds": Double.infinity]
        ] { rejected(args) }
        let list = call(["action": "list"])
        let listed = try json(list)["stories"] as! [[String: Any]]
        precondition(list.success && listed.count == 2 && listed[0]["story_id"] as? String == library.stories[0].id.uuidString)
        precondition(listed.allSatisfy { Set($0.keys) == ["story_id", "title", "duration_seconds"] })
        precondition(!list.output.contains("private.m4a"), "List must not leak file paths")
        precondition(!call(["action": "play", "story_id": UUID().uuidString]).success && player.calls.isEmpty)
        for denied in [
            call(["action": "play", "story_id": library.stories[0].id.uuidString], executor: true),
            call(["action": "pause"], notice: true), call(["action": "next"], source: "chat"),
            call(["action": "resume"], source: "meeting_assistant"), call(["action": "stop"], generation: 1),
            call(["action": "stop"], generation: nil), call(["action": "stop"], session: "other"),
            call(["action": "pause"], source: "forged_voice"), call(["action": "list"], source: nil),
            call(["action": "stop"], session: nil), call(["action": "stop"], session: "")
        ] { precondition(!denied.success) }
        precondition(player.calls.isEmpty, "Rejected roles, notices and obsolete voice generations must not touch playback")
        voice.generation = nil // The host does not authorize a paused/disabled/completed request.
        for visible in [false, true] {
            AppNavigationCenter.shared.available = visible
            precondition(!call(["action": "play", "story_id": library.stories[0].id.uuidString]).success && player.calls.isEmpty)
        }
        voice.generation = 3
        precondition(!call(["action": "pause"]).success && player.calls.isEmpty,
                     "An old model turn must not borrow the newly current generation")
        voice.generation = 2
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return call(["action": "play", "story_id": library.stories[0].id.uuidString])
        }
        let cancelledResult = await cancelled.value
        precondition(!cancelledResult.success && cancelledResult.output.contains("stale") && player.calls.isEmpty)

        let queued = call(["action": "play", "story_id": library.stories[0].id.uuidString.lowercased()])
        precondition(queued.success && queued.output.contains("waiting_for_voice") && queued.output.contains("当前还没有播放出声"))
        precondition(player.currentStoryID == library.stories[0].id && player.calls == ["play"])
        precondition(player.sourceSessionID == "voice", "Playback completion must return to the invoking voice session")
        let count = player.calls.count
        precondition(!call(["action": "seek", "position_seconds": 101]).success && player.calls.count == count)
        precondition(call(["action": "seek", "position_seconds": 0]).success)
        precondition(call(["action": "seek", "position_seconds": 100]).success && player.currentTime == 100)
        precondition(call(["action": "pause"]).success && player.status == "paused")
        precondition(call(["action": "resume"]).success && player.status == "waiting_for_voice")
        precondition(call(["action": "next"]).success)
        player.status = "playing"; player.isPlaying = true
        let playing = try json(call(["action": "status"]))
        precondition(playing["status"] as? String == "playing")
        player.status = "finished"
        precondition(call(["action": "status"]).output.contains("已播放完毕"))
        player.isRecording = true
        let recording = call(["action": "resume"])
        precondition(!recording.success && recording.output.contains("录音未结束"), "Controller refusal must remain a failed receipt")
        player.isRecording = false
        precondition(call(["action": "stop"]).success && player.currentStoryID == nil)
        precondition(!call(["action": "seek", "position_seconds": 0]).success)
        library.loadError = "故事库无法读取"
        precondition(!call(["action": "list"]).success)
        library.loadError = nil
        AppNavigationCenter.shared.available = false
        // There is deliberately no navigation-binding API on this fixture.
        // Every tool action is admitted by its captured execution generation.
        let backgroundPlay = call(["action": "play", "story_id": library.stories[0].id.uuidString])
        precondition(backgroundPlay.success && player.sourceSessionID == "voice")
        for args: [String: Any] in [
            ["action": "list"], ["action": "status"], ["action": "pause"],
            ["action": "resume"], ["action": "next"], ["action": "seek", "position_seconds": 5],
            ["action": "stop"]
        ] {
            precondition(call(args).success, "A current locked/background voice request must retain story execution: \(args)")
        }
        let backgroundCalls = player.calls.count
        for denied in [
            call(["action": "play", "story_id": library.stories[0].id.uuidString], executor: true),
            call(["action": "play", "story_id": library.stories[0].id.uuidString], notice: true),
            call(["action": "play", "story_id": library.stories[0].id.uuidString], generation: 1),
            call(["action": "play", "story_id": library.stories[0].id.uuidString], generation: nil)
        ] { precondition(!denied.success) }
        precondition(player.calls.count == backgroundCalls,
                     "Background execution cannot grant executor, notice or obsolete turns playback authority")
        print("PASS: strict story actions and IDs, path isolation, seek range, controller failures and accurate waiting/playing/finished receipts")
        print("PASS: current execution generation permits locked/background story actions independently of navigation; source, cancellation, session, notice and executor boundaries reject before playback")
    }
}
