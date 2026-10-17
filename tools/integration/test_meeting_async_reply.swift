import Combine
import Foundation

func AppLocalized(_ value: String) -> String { value }
struct HostLogger {
    func info(_ value: String) {}
    func debug(_ value: String) {}
    func error(_ value: String) {}
}
let logger = HostLogger()
enum AgentRole { case main, executor }
enum AgentToolPolicy { case standalone, orchestrator }
struct HostSession { let source: String }
struct HostMessage {
    let role: AgentMessage.Role
    let blocks: [Int]
}
struct HostNotice {
    let id: String
    var taskType = "subagent"
    var taskId = "child-task"
    var agentId: String? = nil
    var title: String? = "后台查询"
    var status = "done"
    var filesPath: String? = nil
    var result = "已查到结果"
}
struct ToolUse { let toolUseId: String; let name: String; let input: String; let description: String }
struct ToolResult { let toolUseId: String; let output: String; let success: Bool; let status: String }
enum ContentPart { case toolUse(ToolUse), toolResult(ToolResult) }
struct RawMessage {
    enum Role { case user, assistant }
    let id: String; let sessionId: String; let role: Role
    let parts: [ContentPart]; let createdAt: Date
}
enum ChatPersistenceSchema {
    static let asyncTaskNoticeToolUseIdPrefix = "async-notice:"
    static let asyncTaskNoticeToolName = "async_task_notice"
}
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var sources: [String: String] = [:]
    var histories: [String: [AgentMessage]] = [:]
    var interruptedSessions: Set<String> = []
    var notices: [String: [HostNotice]] = [:]
    var delivered: Set<String> = []
    var injections = 0
    var failInjection = false
    func getSession(_ id: String) async -> HostSession? { sources[id].map { HostSession(source: $0) } }
    func pendingAsyncTaskNotices(for id: String) async -> [HostNotice] {
        await Task.yield() // The drain reservation must already be held here.
        return (notices[id] ?? []).filter { !delivered.contains($0.id) }
    }
    func injectAsyncTaskNoticeMessages(_ messages: [RawMessage], noticeIds: [String]) async -> Bool {
        guard !failInjection else { return false }
        injections += 1
        precondition(messages.count == noticeIds.count * 2)
        for message in messages {
            let parts = message.parts.map { part -> AgentContentPart in
                switch part {
                case .toolUse(let use):
                    return .toolUse(id: use.toolUseId, name: use.name, input: [:])
                case .toolResult(let result):
                    return .toolResult(id: result.toolUseId, name: ChatPersistenceSchema.asyncTaskNoticeToolName,
                                       content: result.output, isError: !result.success)
                }
            }
            histories[message.sessionId, default: []].append(AgentMessage(
                role: message.role == .user ? .user : .assistant, parts: parts))
        }
        delivered.formUnion(noticeIds)
        return true
    }
    func markAsyncTaskNoticesPending(ids: [String]) async { delivered.subtract(ids) }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var active: Set<String> = []
    func isActive(_ id: String) -> Bool { active.contains(id) }
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var models: [String: HostViewModel] = [:]
    func get(for id: String) -> HostViewModel? { models[id] }
    func getOrCreate(for id: String) -> (HostViewModel, Bool) {
        if let existing = models[id] { return (existing, false) }
        let vm = HostViewModel(sessionID: id)
        models[id] = vm
        return (vm, true)
    }
}
@MainActor final class HostViewModel {
    let sessionID: String
    @Published var isProcessing = false
    var isCompacting = false
    var canResume = false
    var compactTask: Task<Void, Never>?
    var postCompactDrainPending = false
    var promptQueue: [String] = []
    var sessionSource: String?
    var isTruncatingForRetry = false
    var onLoad: (@MainActor (HostViewModel) -> Void)?
    var agentRole = AgentRole.executor
    var resolvedToolPolicy = AgentToolPolicy.standalone
    var groupPromptBlock: String?
    var messages: [HostMessage] = []
    var agentHistory: [AgentMessage] = []
    var committedBlockCount = 0
    var skipReload = false
    var reloads = 0
    var resumedWithNoticeCanResume = false
    var answer: String?
    var resumes = 0
    init(sessionID: String) { self.sessionID = sessionID }
    func loadSession() async {
        await Task.yield()
        onLoad?(self)
        sessionSource = ChatStore.shared.sources[sessionID]
        resolvedToolPolicy = .standalone
        groupPromptBlock = nil // Simulate an evicted/rebuilt VM.
        agentHistory = ChatStore.shared.histories[sessionID]
            ?? [AgentMessage(role: .assistant, parts: [.text("上一轮已完成")])]
        canResume = ChatStore.shared.interruptedSessions.contains(sessionID)
            || agentHistory.last?.role == .user // Synthetic tool results have this real persistence behavior.
    }
    func reloadMessagesFromDB(reason: String) async {
        reloads += 1
        if skipReload || (canResume && messages.last?.blocks.count ?? 0 > committedBlockCount) { return }
        await loadSession()
    }
    func resumeNoticeDrivenLoop() async -> Bool {
        resumedWithNoticeCanResume = canResume
        canResume = false
        resumes += 1
        isProcessing = true
        Task {
            answer = await IOSAgentSessionRunner.shared.perform(self)
            let complete = AgentMessage(role: .assistant, parts: [.text(answer ?? "(pass)")])
            agentHistory.append(complete)
            ChatStore.shared.histories[sessionID, default: []].append(complete)
            isProcessing = false
        }
        return true
    }
}
@MainActor enum AgentTurnAwaiter {
    static func awaitTurn(vm: HostViewModel, seconds: TimeInterval) async -> Bool {
        while vm.isProcessing { try? await Task.sleep(for: .milliseconds(1)) }
        return true
    }
    static func lastAssistantText(vm: HostViewModel, after: Int) -> String? { vm.answer }
}
@MainActor final class IOSAgentSessionRunner {
    static let shared = IOSAgentSessionRunner()
    var noticeSystemPrompts: [String: @MainActor (String) -> String?] = [:]
    var perform: (HostViewModel) async -> String? = { _ in nil }
}
@MainActor final class AsyncTaskNoticeManager {
    static let shared = AsyncTaskNoticeManager()
    var sessionRunner = IOSAgentSessionRunner.shared
    struct ReplyHooks {
        let prepare: @MainActor (String) async -> Bool
        let finish: @MainActor (String, AgentSessionRunResult) async -> Void
    }
    var replyHooks: [String: ReplyHooks] = [:]
    var isDraining: Set<String> = []
    func formatNoticeResultOutput(_ notice: HostNotice) -> String { notice.result }
}
@MainActor final class MeetingAssistantController {
    let bridge: MeetingAssistantBridge
    let runner = IOSAgentSessionRunner.shared
    struct ReplyAuthorization { let generation: UUID; let systemPrompt: String }
    var replyAuthorizations: [String: ReplyAuthorization] = [:]
    var backgroundReplies: [String: UUID] = [:]
    var executingSessions: Set<String> = []
    var activeRequestID: UUID?
    var acknowledgementTask: Task<Void, Never>?
    var answerSpeechTask: Task<Void, Never>?
    var spoken: [String] = []
    init(bridge: MeetingAssistantBridge) { self.bridge = bridge }
    func speakResult(_ text: String, requestID: UUID) async {
        try? await Task.sleep(for: .milliseconds(2))
        if bridge.canSpeak(to: requestID) { spoken.append(text) }
    }
}

@main struct MeetingAsyncReplyChecks {
    @MainActor static func main() async {
        let reply = AgentReplyDeliveryPolicy(definition: MeetingAnswerUserTool.definition,
            canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) }, reminder: MeetingAnswerUserTool.deliveryReminder)
        for source in ["meeting_assistant", "xiaolan_voice", "arbitrary_adapter"] {
            AgentRuntimePolicies.register(source: source, policy: .init(toolPolicyOverride: .orchestrator,
                replyDelivery: reply, requiresIdle: true, requiresNoticeReplyBinding: true, restoresSourceOnLoad: true))
        }
        let manager = AsyncTaskNoticeManager.shared
        let store = ChatStore.shared
        let runner = IOSAgentSessionRunner.shared
        let cache = ViewModelCache.shared
        func settle() async {
            await Task.yield()
            while !manager.isDraining.isEmpty { await Task.yield() }
        }
        func configure() -> (MeetingFixture, MeetingAssistantController, String) {
            let fixture = MeetingFixture()
            fixture.enable()
            let controller = MeetingAssistantController(bridge: fixture.bridge)
            controller.installForCheck()
            let sid = UUID().uuidString
            store.sources[sid] = "meeting_assistant"
            let voiceID = fixture.reserve()
            fixture.bridge.markAccepted(requestID: voiceID, sessionID: sid)
            controller.authorizeForCheck(sessionID: sid)
            fixture.finish(voiceID)
            return (fixture, controller, sid)
        }
        func post(_ sid: String) -> String {
            let id = UUID().uuidString
            store.notices[sid, default: []].append(HostNotice(id: id))
            return id
        }
        let uninstalled = UUID().uuidString
        store.sources[uninstalled] = "meeting_assistant"
        _ = post(uninstalled)
        manager.replyHooks["meeting_assistant"] = nil
        await manager.checkAndDrain(sessionId: uninstalled)
        precondition(store.injections == 0 && cache.models[uninstalled] == nil,
                     "Meeting notices must wait until the host has installed its reply lifecycle")

        let (fixture, controller, sid) = configure()
        let oldRequest = UUID()
        MeetingAnswerUserTool.bind(sessionID: sid, requestID: oldRequest) { _ in true }
        let started = await MeetingAnswerUserTool.execute(["text": "已分派任务"], sessionID: sid, sessionSource: "meeting_assistant")
        precondition(started.success)
        MeetingAnswerUserTool.unbind(sessionID: sid, requestID: oldRequest)
        let userMessages = fixture.bridge.messages.filter { $0.kind == .user }.count
        let firstNotice = post(sid)
        runner.perform = { vm in
            precondition(vm.agentRole == .main && vm.resolvedToolPolicy == .orchestrator)
            precondition(vm.groupPromptBlock?.contains("answer_user") == true)
            precondition(vm.groupPromptBlock?.contains("不是用户发出了新指令") == true)
            let reply = await MeetingAnswerUserTool.execute(["text": "后台任务已完成。"],
                sessionID: vm.sessionID, sessionSource: vm.sessionSource)
            precondition(reply.success)
            return "PRIVATE_PLAIN_TEXT"
        }
        // A freshly rebuilt VM must receive the meeting rules before resuming.
        cache.models.removeValue(forKey: sid)
        async let first: Void = manager.checkAndDrain(sessionId: sid)
        async let concurrent: Void = manager.checkAndDrain(sessionId: sid)
        _ = await (first, concurrent)
        await settle()
        precondition(store.delivered.contains(firstNotice) && store.injections == 1)
        precondition(controller.spoken == ["后台任务已完成。"] && !fixture.bridge.isBusy)
        precondition(fixture.bridge.messages.filter { $0.kind == .user }.count == userMessages,
                     "Background completion has no fake user turn or received acknowledgement")
        precondition(cache.models[sid]?.resumes == 1 && controller.activeRequestID == nil)
        precondition(cache.models[sid]?.resumedWithNoticeCanResume == true,
                     "Loading a normal synthetic notice sets canResume and must still deliver")
        let stale = await MeetingAnswerUserTool.execute(["text": "重复结果"], sessionID: sid, sessionSource: "meeting_assistant")
        precondition(!stale.success, "Completed background delivery must unbind its once-only answer")

        for timedOut in [true, false] {
            let listeningNotice = post(sid)
            fixture.ready()
            fixture.wake()
            precondition(!fixture.bridge.isBusy, "Wake capture precedes the ASR task reservation")
            let beforeListening = store.injections
            let beforeReplies = controller.spoken.count
            await manager.checkAndDrain(sessionId: sid)
            await settle()
            precondition(store.injections == beforeListening && !store.delivered.contains(listeningNotice),
                         "Background results must not interrupt a command being captured after wake")
            if timedOut {
                fixture.bridge.wakeTimedOut(generationID: fixture.generationID!)
            } else {
                fixture.bridge.wakeFailed(generationID: fixture.generationID!, text: "没有听清指令")
            }
            for _ in 0..<100 where !store.delivered.contains(listeningNotice) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            await settle()
            precondition(store.delivered.contains(listeningNotice) && controller.spoken.count == beforeReplies + 1,
                         "A timeout or recoverable capture error retries only the still-authorized completion")
        }

        let nextNotice = post(sid)
        fixture.ready()
        fixture.wake()
        let busyVoice = fixture.reserve()
        let beforeBusy = store.injections
        let beforeBusyReplies = controller.spoken.count
        await manager.checkAndDrain(sessionId: sid)
        await settle()
        precondition(store.injections == beforeBusy && !store.delivered.contains(nextNotice),
                     "A live voice request wins before background results are injected")
        fixture.finish(busyVoice)
        await manager.checkAndDrain(sessionId: sid)
        await settle()
        precondition(controller.spoken.count == beforeBusyReplies + 1 && store.delivered.contains(nextNotice),
                     "A second completion gets a fresh answer binding")

        let (failedFixture, failedController, failedSession) = configure()
        let failedNotice = post(failedSession)
        let beforeFailure = store.injections
        store.failInjection = true
        await manager.checkAndDrain(sessionId: failedSession)
        await settle()
        precondition(store.injections == beforeFailure && !store.delivered.contains(failedNotice))
        precondition(!failedFixture.bridge.isBusy && failedController.activeRequestID == nil
                     && failedController.executingSessions.isEmpty && failedController.backgroundReplies.isEmpty,
                     "An injection failure must release the reservation and reply binding")
        let failedBinding = await MeetingAnswerUserTool.execute(["text": "未注入的结果"],
            sessionID: failedSession, sessionSource: "meeting_assistant")
        precondition(!failedBinding.success && failedController.spoken.isEmpty)
        store.failInjection = false
        let (compacting, _) = cache.getOrCreate(for: failedSession)
        compacting.isCompacting = true
        await manager.checkAndDrain(sessionId: failedSession)
        let busyResume = await runner.resumeAfterAsyncToolResults(sessionId: failedSession)
        precondition(store.injections == beforeFailure && !busyResume.accepted && compacting.resumes == 0,
                     "Compaction rejects notices before injection and before VM reload")
        compacting.isCompacting = false
        await manager.checkAndDrain(sessionId: failedSession)
        await settle()
        precondition(failedController.spoken == ["后台任务已完成。"] && store.delivered.contains(failedNotice))

        let (stoppedFixture, stoppedController, stoppedSession) = configure()
        let (stopped, _) = cache.getOrCreate(for: stoppedSession)
        await stopped.loadSession()
        stopped.canResume = true
        stopped.messages = [HostMessage(role: .assistant, blocks: [1, 2])]
        stopped.committedBlockCount = 1
        let stoppedNotice = post(stoppedSession)
        let beforeStopped = store.injections
        await manager.checkAndDrain(sessionId: stoppedSession)
        let stoppedRun = await runner.resumeAfterAsyncToolResults(sessionId: stoppedSession)
        await settle()
        precondition(!stoppedRun.accepted && store.injections == beforeStopped && !store.delivered.contains(stoppedNotice)
                     && stopped.resumes == 0 && stopped.reloads == 0 && stopped.canResume
                     && stoppedController.spoken.isEmpty && !stoppedFixture.bridge.isBusy,
                     "An interrupted cached meeting stays stopped before injection or reload")

        let (freshFixture, freshController, freshSession) = configure()
        store.interruptedSessions.insert(freshSession)
        store.histories[freshSession] = [AgentMessage(role: .user, parts: [.text("中断的原任务")])]
        cache.models.removeValue(forKey: freshSession)
        let freshNotice = post(freshSession)
        let beforeFresh = store.injections
        await manager.checkAndDrain(sessionId: freshSession)
        await settle()
        precondition(store.injections == beforeFresh && !store.delivered.contains(freshNotice)
                     && cache.models[freshSession]?.canResume == true && cache.models[freshSession]?.resumes == 0
                     && freshController.spoken.isEmpty && !freshFixture.bridge.isBusy,
                     "A freshly loaded interrupted meeting also stays stopped before injection")
        cache.models.removeValue(forKey: freshSession)
        let freshRun = await runner.resumeAfterAsyncToolResults(sessionId: freshSession)
        precondition(!freshRun.accepted && cache.models[freshSession]?.resumes == 0
                     && cache.models[freshSession]?.canResume == true,
                     "A fresh runner load of an old user tail cannot restart the original request")

        let (reloadFixture, reloadController, reloadSession) = configure()
        let (reload, _) = cache.getOrCreate(for: reloadSession)
        await reload.loadSession()
        reload.skipReload = true
        let reloadNotice = post(reloadSession)
        let beforeReload = store.injections
        await manager.checkAndDrain(sessionId: reloadSession)
        await settle()
        precondition(store.injections == beforeReload + 1 && !store.delivered.contains(reloadNotice)
                     && reload.resumes == 0 && reloadController.spoken.isEmpty && !reloadFixture.bridge.isBusy,
                     "A skipped DB reload cannot resume stale history; the notice claim returns to pending")
        reload.skipReload = false
        await manager.checkAndDrain(sessionId: reloadSession)
        await settle()
        precondition(reload.resumes == 1 && store.delivered.contains(reloadNotice)
                     && reloadController.spoken == ["后台任务已完成。"],
                     "A later successful reload can deliver the pending completion")

        for invalidation in 0..<4 {
            let (f, c, source) = configure()
            let oldGeneration = f.bridge.responseGeneration
            let notice = post(source)
            switch invalidation {
            case 0: f.capture(false); f.capture(true); f.ready()
            case 1: f.bridge.setForeground(false); f.bridge.setForeground(true); f.ready()
            case 2: f.bridge.setEnabled(false, unavailableReason: nil); f.enable()
            default: f.recordingID = UUID(); f.capture(true); f.enable()
            }
            precondition(f.bridge.responseGeneration != oldGeneration)
            await manager.checkAndDrain(sessionId: source)
            await settle()
            precondition(c.spoken.isEmpty && !store.delivered.contains(notice),
                         "Resuming capture/foreground/enabled cannot restore old authorization")
            let newVoice = f.reserve()
            f.bridge.markAccepted(requestID: newVoice, sessionID: source)
            c.authorizeForCheck(sessionID: source)
            f.finish(newVoice)
            await manager.checkAndDrain(sessionId: source)
            await settle()
            precondition(c.spoken == ["后台任务已完成。"] && store.delivered.contains(notice),
                         "Only a newly accepted explicit command refreshes authorization")
        }

        let (closedFixture, closedController, closedSession) = configure()
        _ = post(closedSession)
        runner.perform = { vm in
            closedFixture.bridge.setForeground(false)
            let late = await MeetingAnswerUserTool.execute(["text": "迟到结果"], sessionID: vm.sessionID,
                                                          sessionSource: vm.sessionSource)
            precondition(!late.success)
            return "PRIVATE_LATE_TEXT"
        }
        await manager.checkAndDrain(sessionId: closedSession)
        await settle()
        precondition(closedController.spoken.isEmpty && !closedFixture.bridge.isBusy,
                     "Invalidating during resumed execution makes its late answer silent")

        // Busy state must be checked before and after the history-load await.
        let racedSession = UUID().uuidString
        store.sources[racedSession] = "chat"
        let (racedVM, _) = cache.getOrCreate(for: racedSession)
        await racedVM.loadSession()
        racedVM.isTruncatingForRetry = true
        let reloadsBeforeRace = racedVM.reloads
        let refusedBeforeReload = await runner.resumeAfterAsyncToolResults(sessionId: racedSession)
        precondition(!refusedBeforeReload.accepted && racedVM.resumes == 0 && racedVM.reloads == reloadsBeforeRace)
        racedVM.isTruncatingForRetry = false
        racedVM.onLoad = { $0.isProcessing = true }
        let duringReload = await runner.resumeAfterAsyncToolResults(sessionId: racedSession)
        precondition(!duringReload.accepted && racedVM.resumes == 0 && racedVM.reloads == reloadsBeforeRace + 1)
        racedVM.onLoad = nil; racedVM.isProcessing = false
        runner.perform = { _ in "普通任务结果" }
        let afterRace = await runner.resumeAfterAsyncToolResults(sessionId: racedSession)
        precondition(afterRace.accepted && racedVM.resumes == 1)

        let ordinary = UUID().uuidString
        store.sources[ordinary] = "chat"
        _ = post(ordinary)
        manager.replyHooks["chat"] = .init(prepare: { _ in preconditionFailure("Ordinary notices must not require a host reply hook") }, finish: { _, _ in preconditionFailure("Unrequired hook must not run") })
        runner.perform = { _ in "普通对话结果" }
        await manager.checkAndDrain(sessionId: ordinary)
        precondition(cache.models[ordinary]?.resumes == 1)

        // Independent voice has its own reservation hooks. A paused/closed
        // mode leaves the notice pending before any model history is revived.
        let voice = UUID().uuidString
        store.sources[voice] = "xiaolan_voice"
        let voiceNotice = post(voice)
        var voiceReady = false, voiceFinished = false, voiceDelivered = false
        let voiceRequest = UUID()
        manager.replyHooks["xiaolan_voice"] = .init(prepare: { sessionID in
            precondition(sessionID == voice)
            guard voiceReady else { return false }
            MeetingAnswerUserTool.bind(sessionID: voice, requestID: voiceRequest) { text in
                voiceDelivered = text == "独立语音任务已完成。"
                return true
            }
            return true
        }, finish: { sessionID, result in
            precondition(sessionID == voice && result.accepted)
            voiceFinished = true
            MeetingAnswerUserTool.unbind(sessionID: voice, requestID: voiceRequest)
        })
        runner.noticeSystemPrompts["xiaolan_voice"] = { sessionID in sessionID == voice ? "只交付结果，不跳转页面。" : nil }
        runner.perform = { vm in
            let delivered = await MeetingAnswerUserTool.execute(["text": "独立语音任务已完成。"],
                                                                 sessionID: vm.sessionID, sessionSource: vm.sessionSource)
            precondition(delivered.success)
            return "PRIVATE_REASONING_IS_NOT_SPEECH"
        }
        let injectionsBeforeVoice = store.injections
        await manager.checkAndDrain(sessionId: voice)
        precondition(store.injections == injectionsBeforeVoice && !store.delivered.contains(voiceNotice))
        voiceReady = true
        await manager.checkAndDrain(sessionId: voice)
        precondition(voiceFinished && voiceDelivered && store.delivered.contains(voiceNotice))
        // A third adapter uses the exact same host reservation and resume path.
        let custom = UUID().uuidString
        store.sources[custom] = "arbitrary_adapter"
        let customNotice = post(custom)
        let beforeCustom = store.injections
        await manager.checkAndDrain(sessionId: custom)
        precondition(store.injections == beforeCustom && !store.delivered.contains(customNotice))
        var customPrepared = 0, customFinished = 0
        let (customVM, _) = cache.getOrCreate(for: custom)
        manager.replyHooks["arbitrary_adapter"] = .init(prepare: { _ in
            customVM.isProcessing = true
            await Task.yield()
            return true
        }, finish: { _, result in
            precondition(!result.accepted)
            customFinished += 1
        })
        await manager.checkAndDrain(sessionId: custom)
        precondition(customFinished == 1 && store.injections == beforeCustom && !store.delivered.contains(customNotice),
                     "A user turn winning during host reservation leaves notices pending and releases the reply hook")
        customVM.isProcessing = false
        customFinished = 0
        let customRequest = UUID()
        var customDelivered = false
        manager.replyHooks["arbitrary_adapter"] = .init(prepare: { _ in
            customPrepared += 1
            MeetingAnswerUserTool.bind(sessionID: custom, requestID: customRequest) { text in
                customDelivered = text == "third adapter result"
                return true
            }
            return true
        }, finish: { sessionID, result in
            precondition(sessionID == custom && result.accepted && result.text == "third adapter result")
            customFinished += 1
            MeetingAnswerUserTool.unbind(sessionID: custom, requestID: customRequest)
        })
        runner.noticeSystemPrompts["arbitrary_adapter"] = { _ in "third adapter notice rules" }
        runner.perform = { vm in
            precondition(vm.sessionSource == "arbitrary_adapter" && vm.groupPromptBlock == "third adapter notice rules"
                         && vm.agentRole == .main && vm.resolvedToolPolicy == .orchestrator)
            let delivered = await MeetingAnswerUserTool.execute(["text": "third adapter result"], sessionID: custom, sessionSource: vm.sessionSource)
            precondition(delivered.success)
            return "third adapter result"
        }
        await manager.checkAndDrain(sessionId: custom)
        precondition(customPrepared == 1 && customFinished == 1 && customDelivered && store.delivered.contains(customNotice))
        print("PASS: actual async notice/runner/controller/bridge delivers fresh tool-only TTS, gates before injection, preserves epochs, restores VM policy, serializes drains and leaves ordinary sessions unchanged")
    }
}
