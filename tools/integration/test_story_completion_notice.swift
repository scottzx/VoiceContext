import Foundation

struct AppLogger {
    init(category: String) {}
    func info(_ text: String) {}
    func debug(_ text: String) {}
    func error(_ text: String) {}
}
enum AgentToolPolicy { case orchestrator }
extension Notification.Name { static let sessionAgentLoopDidEnd = Notification.Name("test.loop.end") }
public struct AgentSessionRunResult {
    public let accepted: Bool
    public static let rejected = Self(accepted: false)
}
@MainActor public protocol AgentSessionRunning: AnyObject {
    func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult
}
@MainActor final class IOSAgentSessionRunner: AgentSessionRunning {
    static let shared = IOSAgentSessionRunner()
    var resumed: [String] = []
    func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult {
        resumed.append(sessionId)
        return .rejected
    }
}
struct AsyncTaskNotice {
    let id: String, sourceSessionId: String, taskType: String, taskId: String
    let agentId: String?, title: String?, status: String, result: String, filesPath: String?
    let createdAt: Date
    var isDelivered: Bool
}
struct ToolUse { let toolUseId: String, name: String, input: String, description: String }
struct ToolResult { let toolUseId: String, output: String; let success: Bool; let status: String }
enum ContentPart { case toolUse(ToolUse), toolResult(ToolResult), text(String) }
struct RawMessage {
    enum Role { case assistant, user }
    let id: String, sessionId: String
    let role: Role
    let parts: [ContentPart]
    let createdAt: Date
}
struct AssistantBlock {
    enum Kind { case text }
    let kind: Kind
    let content: String
}
struct ChatMessage {
    enum Role { case assistant }
    let role: Role
    let content: String
    let blocks: [AssistantBlock]
}
enum ChatPersistenceSchema {
    static let asyncTaskNoticeToolUseIdPrefix = "async-notice:"
    static let asyncTaskNoticeToolName = "async_task_notice"
}
@MainActor final class ChatStore {
    struct Session { let source: String }
    static let shared = ChatStore()
    var notices: [String: AsyncTaskNotice] = [:]
    var messages: [RawMessage] = []
    var injections = 0
    var failInjection = false
    var beginBusyDuringInjection: String?
    var endBusyWhileMarkingPending: String?
    func hasDeliveredNotice(id: String) async -> Bool { notices[id]?.isDelivered == true }
    func saveAsyncTaskNotice(_ notice: AsyncTaskNotice) async { notices[notice.id] = notice }
    func getSession(_ id: String) async -> Session? { .init(source: "xiaolan_voice") }
    func pendingAsyncTaskNotices(for id: String) async -> [AsyncTaskNotice] {
        notices.values.filter { $0.sourceSessionId == id && !$0.isDelivered }.sorted { $0.createdAt < $1.createdAt }
    }
    func sessionsWithPendingAsyncTaskNotices() async -> [String] {
        Array(Set(notices.values.filter { !$0.isDelivered }.map(\.sourceSessionId)))
    }
    func injectAsyncTaskNoticeMessages(_ input: [RawMessage], noticeIds: [String]) async -> Bool {
        guard !failInjection else { return false }
        injections += 1
        let known = Set(messages.map(\.id))
        messages.append(contentsOf: input.filter { !known.contains($0.id) })
        for id in noticeIds { notices[id]?.isDelivered = true }
        if let id = beginBusyDuringInjection {
            beginBusyDuringInjection = nil
            SessionActivityTracker.shared.active.insert(id)
        }
        return true
    }
    func markAsyncTaskNoticesPending(ids: [String]) async {
        for id in ids { notices[id]?.isDelivered = false }
        if let id = endBusyWhileMarkingPending {
            endBusyWhileMarkingPending = nil
            SessionActivityTracker.shared.active.remove(id)
            NotificationCenter.default.post(name: .sessionAgentLoopDidEnd, object: id)
            // Let the observer hit the existing drain reservation before this
            // pending-write await returns to its owner.
            await Task.yield()
        }
    }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var active: Set<String> = []
    func isActive(_ id: String) -> Bool { active.contains(id) }
}
@MainActor final class HostViewModel {
    var isProcessing = false
    var isCompacting = false
    var isTruncatingForRetry = false
    var compactTask: Task<Void, Never>?
    var postCompactDrainPending = false
    var promptQueue: [String] = []
    var agentHistory: [AgentMessage] = []
    var messages: [ChatMessage] = []
}
@MainActor enum AIChatViewModel { static var activeSessionId: String? = "unrelated-visible-session" }
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var models: [String: HostViewModel] = [:]
    func get(for id: String) -> HostViewModel? { models[id] }
}

@main struct StoryCompletionNoticeChecks {
    @MainActor static func main() async throws {
        let manager = AsyncTaskNoticeManager.shared
        manager.historyOnlyTaskTypes.insert("story_playback")
        AgentRuntimePolicies.register(source: "xiaolan_voice", policy: .init(requiresNoticeReplyBinding: true))
        let store = ChatStore.shared
        let source = "voice-story-origin"
        let other = "another-voice-session"
        let vm = HostViewModel()
        ViewModelCache.shared.models[source] = vm
        var hooksCalled = 0
        manager.replyHooks["xiaolan_voice"] = .init(prepare: { _ in
            hooksCalled += 1
            return false // Host is paused/unavailable for speech.
        }, finish: { _, _ in hooksCalled += 1 })
        let library = StoryLibraryStore()
        let first = StoryAudio(id: UUID(), title: "西游记", fileName: "first.wav", duration: 180)
        let second = StoryAudio(id: UUID(), title: "小王子", fileName: "second.wav", duration: 180)
        library.stories = [first, second]
        let player = StoryPlaybackController(library: library)
        func waitUntil(line: UInt = #line, _ condition: @MainActor () -> Bool) async {
            for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
            preconditionFailure("Expected completion flow at line \(line)")
        }
        func settle() async { for _ in 0..<40 { await Task.yield() } }
        func finish(_ audio: AVAudioPlayer, successfully: Bool = true) {
            audio.currentTime = 0 // Native completion can reset progress.
            audio.isPlaying = false
            audio.delegate?.audioPlayerDidFinishPlaying(audio, successfully: successfully)
        }
        func playbackID() -> String { player.snapshot()["playback_id"] as! String }
        func noticeID(_ playbackID: String) -> String { "async:story_playback:" + playbackID }

        try player.play(first, sourceSessionID: source)
        let firstID = playbackID()
        let audio = AVAudioPlayer.latest!
        let oldDelegate = audio.delegate!
        player.beginVoiceInteraction()
        player.finishVoiceInteraction()
        precondition(playbackID() == firstID, "Automatic voice suspension must keep a stable playback identity")
        let completionDelegate = audio.delegate!
        finish(audio)
        await waitUntil { vm.agentHistory.count == 3 }
        precondition(store.notices.count == 1 && store.messages.count == 3 && vm.messages.count == 1)
        let notice = store.notices[noticeID(firstID)]!
        let payload = try JSONSerialization.jsonObject(with: Data(notice.result.utf8)) as! [String: Any]
        precondition(notice.sourceSessionId == source && notice.taskId == firstID && notice.isDelivered)
        precondition(payload["playback_id"] as? String == firstID && payload["story_id"] as? String == first.id.uuidString)
        precondition(payload["title"] as? String == first.title && payload["status"] as? String == "finished")
        precondition(payload["position_seconds"] as? Double == 180 && payload["duration_seconds"] as? Double == 180)
        precondition(vm.messages.last!.content.contains("西游记") && vm.messages.last!.content.contains("已播放完成"))
        precondition(vm.agentHistory.last!.role == .assistant, "Passive terminal receipt must not leave an unfinished tool-result tail")
        precondition(AIChatViewModel.activeSessionId == "unrelated-visible-session")
        precondition(hooksCalled == 0 && IOSAgentSessionRunner.shared.resumed.isEmpty,
                     "A completion is persisted while paused without a new agent turn, speech, or navigation")
        completionDelegate.audioPlayerDidFinishPlaying(audio, successfully: true)
        oldDelegate.audioPlayerDidFinishPlaying(audio, successfully: true)
        _ = await manager.postNotice(sourceSessionId: source, taskType: notice.taskType, taskId: notice.taskId,
                                     title: notice.title, status: notice.status, result: notice.result)
        await settle()
        precondition(store.notices.count == 1 && store.messages.count == 3 && vm.agentHistory.count == 3,
                     "Duplicate or late delegates and duplicate notice posts cannot duplicate terminal history")

        // Pause, stop, cancelled voice intent, seek-to-end, switch, and decoder
        // failure invalidate completion generations rather than claiming success.
        try player.play(first, sourceSessionID: source)
        let pausedAudio = AVAudioPlayer.latest!, pausedDelegate = pausedAudio.delegate!
        player.pause()
        pausedDelegate.audioPlayerDidFinishPlaying(pausedAudio, successfully: true)
        try player.resume(sourceSessionID: source)
        let stoppedDelegate = pausedAudio.delegate!
        player.stop()
        stoppedDelegate.audioPlayerDidFinishPlaying(pausedAudio, successfully: true)
        try player.play(first, sourceSessionID: source)
        let seekAudio = AVAudioPlayer.latest!, seekDelegate = seekAudio.delegate!
        try player.seek(to: 180)
        seekDelegate.audioPlayerDidFinishPlaying(seekAudio, successfully: true)
        try player.play(first, sourceSessionID: source)
        let switchedAudio = AVAudioPlayer.latest!, switchedDelegate = switchedAudio.delegate!
        try player.next(sourceSessionID: source)
        switchedDelegate.audioPlayerDidFinishPlaying(switchedAudio, successfully: true)
        finish(AVAudioPlayer.latest!, successfully: false)
        try player.play(first, sourceSessionID: source)
        let cancelledAudio = AVAudioPlayer.latest!, cancelledDelegate = cancelledAudio.delegate!
        player.beginVoiceInteraction()
        player.cancelVoiceInteraction()
        cancelledDelegate.audioPlayerDidFinishPlaying(cancelledAudio, successfully: true)
        player.stop()
        await settle()
        precondition(store.notices.count == 1, "Only authoritative natural completion can publish finished")

        try player.play(first, sourceSessionID: source)
        try player.play(second) // Explicit manual selection has no old session binding.
        finish(AVAudioPlayer.latest!)
        await settle()
        precondition(store.notices.count == 1, "Manual selection must not notify a previous voice session")
        try player.play(first)
        try player.resume(sourceSessionID: other)
        let resumedID = playbackID()
        finish(AVAudioPlayer.latest!)
        await waitUntil { store.notices[noticeID(resumedID)]?.isDelivered == true }
        precondition(store.notices[noticeID(resumedID)]!.sourceSessionId == other,
                     "An explicitly voiced resume binds the playback request to its own session")

        SessionActivityTracker.shared.active.insert(source)
        try player.play(first, sourceSessionID: source)
        let busyID = playbackID()
        finish(AVAudioPlayer.latest!)
        await waitUntil { store.notices[noticeID(busyID)] != nil }
        precondition(!store.notices[noticeID(busyID)]!.isDelivered && vm.agentHistory.count == 3)
        SessionActivityTracker.shared.active.remove(source)
        NotificationCenter.default.post(name: .sessionAgentLoopDidEnd, object: source)
        await waitUntil { vm.agentHistory.count == 6 }
        precondition(store.notices[noticeID(busyID)]!.isDelivered && vm.messages.count == 2,
                     "Busy completion stays durable until loop end then enters the same cached session history")

        // Fail once at the atomic write, then recover through the same durable
        // pending queue a new manager sees after process restoration.
        store.failInjection = true
        try player.play(first, sourceSessionID: source)
        let recoverID = playbackID()
        finish(AVAudioPlayer.latest!)
        await waitUntil { store.notices[noticeID(recoverID)] != nil }
        await settle()
        precondition(!store.notices[noticeID(recoverID)]!.isDelivered && vm.agentHistory.count == 6)
        store.failInjection = false
        weak var recoveredReference: AsyncTaskNoticeManager?
        do {
            let recoveredManager = AsyncTaskNoticeManager()
            recoveredReference = recoveredManager
            recoveredManager.historyOnlyTaskTypes.insert("story_playback")
            await recoveredManager.recoverPendingNotices()
            precondition(store.notices[noticeID(recoverID)]!.isDelivered && vm.agentHistory.count == 9)
            await recoveredManager.checkAndDrain(sessionId: source)
            precondition(vm.agentHistory.count == 9 && vm.messages.count == 3)
            await settle()
        }
        await waitUntil { recoveredReference == nil }

        store.beginBusyDuringInjection = source
        try player.play(first, sourceSessionID: source)
        let racedID = playbackID()
        finish(AVAudioPlayer.latest!)
        await waitUntil { store.notices[noticeID(racedID)] != nil && SessionActivityTracker.shared.isActive(source) }
        await settle()
        precondition(!store.notices[noticeID(racedID)]!.isDelivered && vm.agentHistory.count == 9)
        let rowsAfterRace = store.messages.count
        SessionActivityTracker.shared.active.remove(source)
        await manager.checkAndDrain(sessionId: source)
        precondition(store.messages.count == rowsAfterRace && vm.agentHistory.count == 12,
                     "A user turn winning the atomic-write race leaves a retry without duplicate persisted messages")
        let nextRequestHistory = vm.agentHistory + [AgentMessage(role: .user, parts: [.text("故事播完了吗？")])]
        var uses: Set<String> = [], results: Set<String> = []
        for message in nextRequestHistory {
            for part in message.parts {
                switch part {
                case .toolUse(let id, _, _): uses.insert(id)
                case .toolResult(let id, _, let content, _, _, _, _, _):
                    results.insert(id)
                    precondition(content.contains("\"status\":\"finished\""))
                default: break
                }
            }
        }
        precondition(uses == results && uses.count == 4 && nextRequestHistory.last?.role == .user,
                     "The next real user request must inherit complete paired terminal states, with no unresolved completion turn")
        let eventsBeforeManualResume = store.notices.count
        try player.play(first, sourceSessionID: source)
        player.pause()
        try player.resume(sourceSessionID: nil)
        finish(AVAudioPlayer.latest!)
        await settle()
        precondition(store.notices.count == eventsBeforeManualResume,
                     "Manual resume with voice disabled must clear an old conversation binding")

        try player.play(first) // User starts audio before the first voice turn.
        let adoptedID = playbackID()
        player.bindCompletionSessionIfUnowned("")
        player.bindCompletionSessionIfUnowned(other)
        player.bindCompletionSessionIfUnowned(source)
        precondition(playbackID() == adoptedID, "Binding a newly created voice session must not restart playback")
        finish(AVAudioPlayer.latest!)
        await waitUntil { store.notices[noticeID(adoptedID)]?.isDelivered == true }
        precondition(store.notices[noticeID(adoptedID)]?.sourceSessionId == other,
                     "First real voice session adopts unowned manual audio; later sessions cannot steal its completion")
        let eventsAfterAdoption = store.notices.count
        player.bindCompletionSessionIfUnowned(source)
        await settle()
        precondition(store.notices.count == eventsAfterAdoption,
                     "Attaching a session cannot synthesize an already finished playback event")
        let rowsBeforeLoopEndRace = store.messages.count
        let historyBeforeLoopEndRace = vm.agentHistory.count
        let injectionsBeforeLoopEndRace = store.injections
        store.beginBusyDuringInjection = source
        store.endBusyWhileMarkingPending = source
        try player.play(first, sourceSessionID: source)
        let loopEndRaceID = playbackID()
        finish(AVAudioPlayer.latest!)
        await waitUntil {
            store.notices[noticeID(loopEndRaceID)]?.isDelivered == true
                && vm.agentHistory.count == historyBeforeLoopEndRace + 3
        }
        precondition(store.messages.count == rowsBeforeLoopEndRace + 3
                     && store.injections == injectionsBeforeLoopEndRace + 2,
                     "Loop end during markPending must retry automatically into cached history without duplicate persisted rows")
        precondition(hooksCalled == 0 && IOSAgentSessionRunner.shared.resumed.isEmpty)
        print("PASS: real natural completion emits one session-bound finished payload and visible terminal receipt")
        print("PASS: manual selection, pause, stop, cancelled voice, seek-to-end, switch, decode failure and late delegates cannot report false completion")
        print("PASS: paused/headless and busy delivery, cached model history, pending recovery, write failure and user-turn race remain durable without speech, new runs or navigation")
        print("PASS: manual playback can bind the first real voice session without replay, and disabled manual resume clears obsolete ownership")
        print("PASS: loop end during the pending-write await retries automatically after releasing the drain reservation")
    }
}
