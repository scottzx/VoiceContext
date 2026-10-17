import Combine
import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

func AppLocalized(_ value: String) -> String { value }

// Minimal host boundaries; the execute method's observer, tool binding,
// callbacks, result branching and cleanup all come from the product file.
@MainActor final class MeetingAssistantBridge {
    static let shared = MeetingAssistantBridge()
    struct Request {
        let id = UUID()
        var recordingID = UUID()
        var title = "验收会议"
        var command = "查询今天的日程"
        var transcriptSegments: [MeetingTranscriptContext.Segment]? = []
        var recordingStartedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    }
    struct Result { let text: String; let isError: Bool }
    var currentID: UUID?
    var responseGeneration = UUID()
    var results: [Result] = []
    var spoken: [String] = []
    var events: [String] = []
    func activate(_ id: UUID) { currentID = id; results = []; spoken = []; events = [] }
    func close() { currentID = nil; events.append("close") }
    func canRespond(to id: UUID) -> Bool { currentID == id }
    func markAccepted(requestID: UUID, sessionID: String) {
        if canRespond(to: requestID) { events.append("accepted") }
    }
    func showResult(requestID: UUID, text: String, isError: Bool) {
        guard canRespond(to: requestID) else { return }
        results.append(.init(text: text, isError: isError))
        events.append("result:\(text)")
    }
    func recordSpeech(_ text: String, requestID: UUID) {
        guard canRespond(to: requestID) else { return }
        spoken.append(text)
        events.append("speech:\(text)")
    }
    func finish(requestID: UUID) {
        if currentID == requestID { currentID = nil }
        events.append("finish")
    }
}

struct AgentMessage {
    enum Role { case user, assistant }
    enum Part { case text(String) }
    var role: Role
    var parts: [Part]
    var dbMessageId: String?
}
@MainActor final class HostViewModel {
    let sessionID: String
    @Published var isProcessing = false
    var isCompacting = false
    var compactTask: Task<Void, Never>?
    var postCompactDrainPending = false
    var promptQueue: [String] = []
    var agentHistory: [AgentMessage] = []
    var reloadWhilePersisting = false
    init(sessionID: String) { self.sessionID = sessionID }
    func loadSession() async { agentHistory = ChatStore.shared.histories[sessionID] ?? [] }
    func persistAgentMessage(_ message: AgentMessage) async -> String? {
        var saved = message
        saved.dbMessageId = UUID().uuidString
        ChatStore.shared.histories[sessionID, default: []].append(saved)
        if reloadWhilePersisting, message.parts.contains(where: {
            if case .text(let text) = $0 { return text.hasPrefix("<system-reminder>") }
            return false
        }) { await loadSession() }
        return saved.dbMessageId
    }
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var sessionID = ""
    var models: [String: HostViewModel] = [:]
    var vm: HostViewModel { models[sessionID]! }
    func get(for id: String) -> HostViewModel? { models[id] }
    func getOrCreate(for id: String) -> (HostViewModel, Bool) {
        if let existing = models[id] { return (existing, false) }
        let fresh = HostViewModel(sessionID: id)
        models[id] = fresh
        return (fresh, true)
    }
}
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var histories: [String: [AgentMessage]] = [:]
    var owners: [String: String] = [:]
    func sessionExists(id: String) async -> Bool { histories[id] != nil }
    func updateSessionTitle(_ id: String, title: String) async {}
}
@MainActor enum XiaolanAgent {
    static let id = "agent-xiaolan"
    static func ensure() async throws {}
    static func ownsSession(_ sessionID: String) async -> Bool { ChatStore.shared.owners[sessionID] == id }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var active: Set<String> = []
    func isActive(_ id: String) -> Bool { active.contains(id) }
}
@MainActor final class AsyncTaskNoticeManager {
    static let shared = AsyncTaskNoticeManager()
    func checkAndDrain(sessionId: String) async {}
}
struct AgentSessionCreateRequest { let agentId: String; let source: String; let role: String; let toolPolicy: String }
struct AgentSessionRunRequest {
    let sessionId: String
    let prompt: String
    let agentId: String
    let source: String
    let systemPromptBlock: String
    let role: String
    let toolPolicy: String
    let timeoutSeconds: Int
}
struct AgentSessionRunResult {
    let text: String?
    var accepted = true
    var timedOut = false
    var cancelled = false
}
@MainActor final class IOSAgentSessionRunner {
    static let shared = IOSAgentSessionRunner()
    var created = 0
    var runs: [AgentSessionRunRequest] = []
    var perform: (AgentSessionRunRequest) async -> AgentSessionRunResult = { _ in .init(text: nil) }
    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        precondition(request.source == "meeting_assistant" && request.agentId == XiaolanAgent.id && request.role == "main" && request.toolPolicy == "orchestrator")
        let cache = ViewModelCache.shared
        cache.sessionID = UUID().uuidString
        created += 1
        cache.models[cache.sessionID] = HostViewModel(sessionID: cache.sessionID)
        ChatStore.shared.histories[cache.sessionID] = []
        ChatStore.shared.owners[cache.sessionID] = request.agentId
        return cache.sessionID
    }
    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        precondition(request.source == "meeting_assistant")
        precondition(request.agentId == XiaolanAgent.id && ChatStore.shared.owners[request.sessionId] == XiaolanAgent.id)
        runs.append(request)
        ViewModelCache.shared.sessionID = request.sessionId
        let vm = ViewModelCache.shared.models[request.sessionId]!
        vm.isProcessing = true // Real Combine acceptance observer must fire.
        var command = AgentMessage(role: .user, parts: [.text(request.prompt)])
        command.dbMessageId = await vm.persistAgentMessage(command)
        vm.agentHistory.append(command)
        let result = await perform(request)
        vm.isProcessing = false
        return result
    }
}
@MainActor final class MeetingAssistantController {
    let bridge = MeetingAssistantBridge.shared
    let runner = IOSAgentSessionRunner.shared
    var activeRequestID: UUID?
    var acknowledgementTask: Task<Void, Never>?
    var answerSpeechTask: Task<Void, Never>?
    var sessionCreationTasks: [UUID: Task<String?, Never>] = [:]
    var executingSessions: Set<String> = []
    struct ReplyAuthorization { let generation: UUID; let systemPrompt: String }
    var replyAuthorizations: [String: ReplyAuthorization] = [:]
    func speak(_ text: String, requestID: UUID) async { bridge.recordSpeech(text, requestID: requestID) }
    func speakResult(_ text: String, requestID: UUID) async { await speak(text, requestID: requestID) }
    func report(_ text: String, isError: Bool, request: MeetingAssistantBridge.Request) async {
        guard activeRequestID == request.id, bridge.canRespond(to: request.id) else { return }
        bridge.showResult(requestID: request.id, text: text, isError: isError)
        await speakResult(text, requestID: request.id)
    }
}

@main struct MeetingExecuteChecks {
    @MainActor static func main() async {
        AgentRuntimePolicies.register(source: "meeting_assistant", policy: .init(replyDelivery: .init(
            definition: MeetingAnswerUserTool.definition,
            canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) },
            reminder: MeetingAnswerUserTool.deliveryReminder)))
        let controller = MeetingAssistantController()
        let bridge = controller.bridge
        let runner = controller.runner
        let plain = "PLAIN_PRIVATE_PROCESS_TEXT_MUST_NOT_BE_DELIVERED"
        let answer = "已创建会中助手验收一号，未设置日期。"
        let acknowledgement = "收到，正在执行。"
        let missingTool = "本次没有收到专用回复工具的答复，请查看对话核对执行状态。"
        func status(_ output: String) -> String {
            (try! JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: String])["status"]!
        }

        runner.perform = { _ in .init(text: plain) }
        await controller.runForCheck(.init())
        precondition(bridge.results.count == 1 && bridge.results[0].text == missingTool && bridge.results[0].isError,
                     "Plain text must only lead to the fixed missing-tool diagnostic")
        precondition(bridge.spoken == [acknowledgement, missingTool], "Plain result must never be spoken")
        precondition(!bridge.events.contains(where: { $0.contains(plain) }))

        for timedOut in [false, true] {
            runner.perform = { request in
                let delivered = await MeetingAnswerUserTool.execute(
                    ["text": answer], sessionID: request.sessionId, sessionSource: request.source
                )
                precondition(delivered.success && status(delivered.output) == "delivered")
                return .init(text: plain, timedOut: timedOut)
            }
            let request = MeetingAssistantBridge.Request()
            await controller.runForCheck(request)
            precondition(bridge.results.count == 1 && bridge.results[0].text == answer && !bridge.results[0].isError,
                         "An explicit answer must be authoritative, including after a runner timeout")
            precondition(bridge.spoken == [acknowledgement, answer], "Only the tool argument may become the final speech")
            precondition(bridge.events == ["accepted", "speech:\(acknowledgement)", "result:\(answer)", "speech:\(answer)", "finish"],
                         "Actual execute callback must wait for acknowledgement before final delivery")
            precondition(controller.activeRequestID == nil && controller.answerSpeechTask == nil)
            precondition(!MeetingAnswerUserTool.didDeliver(sessionID: ViewModelCache.shared.sessionID, requestID: request.id),
                         "The actual execute defer must unbind its callback")
        }

        runner.perform = { request in
            await controller.acknowledgementTask?.value
            bridge.close()
            let late = await MeetingAnswerUserTool.execute(
                ["text": answer], sessionID: request.sessionId, sessionSource: request.source
            )
            precondition(!late.success && status(late.output) == "stale")
            return .init(text: plain)
        }
        await controller.runForCheck(.init())
        precondition(bridge.results.isEmpty && bridge.spoken == [acknowledgement],
                     "Closing must make a late answer silent and invisible")
        let afterFinish = await MeetingAnswerUserTool.execute(
            ["text": answer], sessionID: ViewModelCache.shared.sessionID, sessionSource: "meeting_assistant"
        )
        precondition(!afterFinish.success && status(afterFinish.output) == "stale")
        precondition(bridge.results.isEmpty && bridge.spoken == [acknowledgement])

        // Stable recording identity, durable context deltas and VM eviction.
        runner.perform = { request in
            let delivered = await MeetingAnswerUserTool.execute(
                ["text": answer], sessionID: request.sessionId, sessionSource: request.source
            )
            precondition(delivered.success)
            return .init(text: plain)
        }
        let recording = UUID()
        let a = MeetingTranscriptContext.Segment(id: UUID(), startSample: 16_000, endSample: 32_000,
                                                 text: "会议开始的方案", speaker: nil)
        let b = MeetingTranscriptContext.Segment(id: UUID(), startSample: 65 * 16_000, endSample: 66 * 16_000,
                                                 text: "第二分钟内容", speaker: nil)
        let createdBefore = runner.created
        await controller.runForCheck(.init(recordingID: recording, command: "查询今天的日程", transcriptSegments: [a, b]))
        let sessionID = runner.runs.last!.sessionId
        precondition(runner.created == createdBefore + 1)
        precondition(runner.runs.last!.prompt == "查询今天的日程", "The visible user message contains only the current command")
        precondition(runner.runs.last!.systemPromptBlock.contains("最新用户消息是本次需要执行的真实指令"))
        let initialHistory = ChatStore.shared.histories[sessionID]!
        precondition(initialHistory.count == 2, "The hidden context precedes the distinct current command")
        func text(_ message: AgentMessage) -> String {
            message.parts.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined(separator: "\n")
        }
        precondition(text(initialHistory[0]).contains("会议时间 00:00–01:00"))
        precondition(text(initialHistory[1]) == "查询今天的日程")

        let late = MeetingTranscriptContext.Segment(id: UUID(), startSample: 10 * 16_000, endSample: 12 * 16_000,
                                                    text: "稍晚到达的早一分钟转录", speaker: nil)
        await controller.runForCheck(.init(recordingID: recording, command: "把刚才那件事继续办好", transcriptSegments: [a, late, b]))
        precondition(runner.runs.last!.sessionId == sessionID && runner.created == createdBefore + 1)
        let secondHistory = ChatStore.shared.histories[sessionID]!
        precondition(secondHistory.count == 4 && text(secondHistory[2]).contains(late.text))
        precondition(!text(secondHistory[2]).contains(a.text) && !text(secondHistory[2]).contains(b.text))

        ViewModelCache.shared.models.removeValue(forKey: sessionID)
        let reloadedController = MeetingAssistantController()
        await reloadedController.runForCheck(.init(recordingID: recording, command: "刚才查到了什么", transcriptSegments: [a, late, b]))
        precondition(runner.runs.last!.sessionId == sessionID && runner.created == createdBefore + 1,
                     "Controller and VM recreation reuse the persisted recording session")
        precondition(ChatStore.shared.histories[sessionID]!.count == 5,
                     "Reloaded durable cursor does not resend any old transcript")
        precondition(ViewModelCache.shared.models[sessionID]!.agentHistory.count == 5,
                     "The reloaded VM retains earlier commands and transcript context")
        let reloadingVM = ViewModelCache.shared.models[sessionID]!
        reloadingVM.reloadWhilePersisting = true
        let newest = MeetingTranscriptContext.Segment(id: UUID(), startSample: 90 * 16_000, endSample: 91 * 16_000,
                                                      text: "并发刷新时的新片段", speaker: nil)
        await controller.runForCheck(.init(recordingID: recording, transcriptSegments: [a, late, b, newest]))
        precondition(reloadingVM.agentHistory.count == 7 && ChatStore.shared.histories[sessionID]!.count == 7,
                     "A DB reload during context persistence must not append the same row twice")
        reloadingVM.reloadWhilePersisting = false

        let runsBeforeBusy = runner.runs.count
        let busyVM = ViewModelCache.shared.models[sessionID]!
        busyVM.isProcessing = true
        let previousRequest = UUID()
        var oldBindingDelivered = false
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: previousRequest) { _ in
            oldBindingDelivered = true
            return true
        }
        await controller.runForCheck(.init(recordingID: recording, transcriptSegments: [a, late, b]))
        precondition(runner.runs.count == runsBeforeBusy && busyVM.isProcessing)
        precondition(bridge.results.last!.text.contains("上一项任务仍在执行"))
        let oldAnswer = await MeetingAnswerUserTool.execute(["text": "原任务结果"], sessionID: sessionID, sessionSource: "meeting_assistant")
        precondition(oldAnswer.success && oldBindingDelivered, "Busy rejection does not rebind or cancel the active answer tool")
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: previousRequest)
        busyVM.isProcessing = false

        await controller.runForCheck(.init())
        precondition(runner.runs.last!.sessionId != sessionID && runner.created == createdBefore + 2,
                     "A different recording creates a separate conversation")

        let legacyRecording = UUID(), legacySession = UUID().uuidString
        let legacyKey = "meetingAssistant.session.\(legacyRecording.uuidString)"
        ChatStore.shared.histories[legacySession] = [.init(role: .user, parts: [.text("历史一芥会话")])]
        ChatStore.shared.owners[legacySession] = "agent-default"
        UserDefaults.standard.set(legacySession, forKey: legacyKey)
        let createdBeforeLegacy = runner.created
        await controller.runForCheck(.init(recordingID: legacyRecording))
        let replacement = runner.runs.last!.sessionId
        precondition(replacement != legacySession && runner.created == createdBeforeLegacy + 1)
        precondition(ChatStore.shared.owners[legacySession] == "agent-default"
                     && ChatStore.shared.histories[legacySession]!.count == 1,
                     "Historical Yima ownership and transcript must never be reassigned or rewritten")
        precondition(ChatStore.shared.owners[replacement] == XiaolanAgent.id
                     && UserDefaults.standard.string(forKey: legacyKey) == replacement)
        await controller.runForCheck(.init(recordingID: legacyRecording))
        precondition(runner.runs.last!.sessionId == replacement && runner.created == createdBeforeLegacy + 1)

        let createdBeforeDeletion = runner.created
        ChatStore.shared.histories.removeValue(forKey: sessionID)
        await controller.runForCheck(.init(recordingID: recording))
        precondition(runner.created == createdBeforeDeletion && bridge.results.last!.text.contains("已删除本场会话"),
                     "A deleted linked session cannot silently replace the recording's memory")
        for request in runner.runs {
            // Test recording IDs are random; remove only keys created by this host check.
            if let link = UserDefaults.standard.dictionaryRepresentation().first(where: {
                $0.key.hasPrefix("meetingAssistant.session.") && ($0.value as? String) == request.sessionId
            }) { UserDefaults.standard.removeObject(forKey: link.key) }
        }
        print("PASS: actual meeting execute rejects plain text, delivers only explicit answers, preserves delivery across timeout and blocks late replies")
        print("PASS: one recording/session, durable minute deltas, late ASR, cache reload, current-command isolation and busy/deleted-session safeguards")
    }
}
