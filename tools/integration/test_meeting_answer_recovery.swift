import Foundation

// Boundary fixture for the canonical peer-directory tools.
enum AgentDirectoryTools {
    static var definitions: [AgentToolDefinition] {
        ["list_agents", "send_agent_message", "create_agent"].map {
            AgentToolDefinition(name: $0, description: $0, parameters: [:], required: [])
        }
    }
}

// Host boundaries only. The recovery branches, tool policy/dispatch wrapper,
// speech gate and answer_user implementation are extracted from product code.
struct AgentMessage {
    enum Role { case user, assistant }
    var role: Role
    var parts: [AgentContentPart]
    var dbMessageId: String?
}
enum AgentContentPart {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, content: String, isError: Bool,
                    imageData: Data? = nil, imageMimeType: String? = nil,
                    pageURL: String? = nil, imageLinuxPath: String? = nil)
}
typealias MessageRole = AgentMessage.Role
typealias ContentPart = AgentContentPart
enum AgentStopReason { case endTurn, toolUse, maxTokens, refusal }
enum SubagentTools {
    static let names: Set<String> = ["spawn_subagent", "spawn_cloud_subagent", "check_subagent", "message_subagent", "stop_subagent"]
}
struct HostLogger {
    func info(_ text: String) {}
    func warning(_ text: String) {}
}
let logger = HostLogger()
func AppLocalized(_ text: String) -> String { text }
struct HostModel {}
enum AgentToolPolicy { case standalone, orchestrator }
struct HostModelEntry { var id = "host-model"; var model = HostModel() }
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for id: String) -> HostModelEntry? { nil }
}
@MainActor final class ChatStore {
    struct ErrorUpdate { var messageID: String; var error: String? }
    static let shared = ChatStore()
    var errorUpdates: [ErrorUpdate] = []
    func updateMessageErrorInfo(messageId: String, errorInfo: String?) async {
        errorUpdates.append(.init(messageID: messageId, error: errorInfo))
    }
}
@MainActor final class VoiceOutputState {
    static let shared = VoiceOutputState()
    var canPlay = true
}
@MainActor final class VoiceModePreference {
    static let shared = VoiceModePreference()
    var isCapturing = false
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    func isActive(_ sessionID: String) -> Bool { false }
}
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    var isRecording = false
}
@MainActor final class HostHooks {
    struct Gate { var index = 0; var blockReason: String? }
    func willRunTool(name: String, argsJSON: String?) -> Gate { .init() }
    func didRunTool(name: String, index: Int, succeeded: Bool) {}
    func tools(_ tools: [AgentToolDefinition]) -> [AgentToolDefinition] { tools }
}
struct StreamResult {
    struct ToolEntry {
        var id = UUID().uuidString
        var name: String
        var args: [String: Any]
        var blockIdx = 0
    }
    var assistantText: String
    var toolEntries: [ToolEntry] = []
    var stopReason: AgentStopReason? = .endTurn
    var reasoningContent: String?
    var isStreamInterrupted = false
}
struct ScriptTurn {
    var text = ""
    var reasoning = "PRIVATE_REASONING_MUST_NOT_BE_SPOKEN"
    var calls: [StreamResult.ToolEntry] = []
    var stopReason: AgentStopReason? = .endTurn
    var interrupted = false
    var throwsError = false
}
@MainActor final class ScriptProvider {
    var turns: [ScriptTurn]
    var requests: [[String]] = []
    var requiredToolNames: [String?] = []
    var histories: [[AgentMessage]] = []
    var emptyRetryClassifications: [Bool] = []
    init(_ turns: [ScriptTurn]) { self.turns = turns }
    func next(tools: [AgentToolDefinition], requiredToolName: String?, history: [AgentMessage]) throws -> ScriptTurn {
        requests.append(tools.map(\.name))
        requiredToolNames.append(requiredToolName)
        histories.append(history)
        if let requiredToolName {
            precondition(tools.map(\.name) == [requiredToolName],
                         "Required delivery must target the only exposed tool")
        }
        precondition(!turns.isEmpty, "Unexpected extra provider request: recovery must be bounded")
        let turn = turns.removeFirst()
        if turn.throwsError { throw NSError(domain: "HostProviderFailure", code: 1) }
        return turn
    }
}
@MainActor final class AIChatViewModel {
    enum Role { case main, executor }
    struct BatchImageBudget {}
    struct ToolExecOutcome { var cancelled = false; let resultPart: AgentContentPart }
    struct Message {
        var role: AgentMessage.Role = .assistant
        var blocks: [Int] = []
        var error: String?
        var isAwaitingModelResponse = true
    }
    var sessionId: String? = UUID().uuidString
    var sessionSource: String? = "meeting_assistant"
    var agentRole: Role = .main
    var hooks: HostHooks? = HostHooks()
    var canResume = false
    var isProcessing = false
    var isRedetectingInterruptedTail = false
    var userDidCancel = false
    var promptQueue: [String] = []
    var isNoticeDriven = false
    var agentHistory: [AgentMessage] = []
    var persisted: [AgentMessage] = []
    var messages = [Message()]
    var committedBlockCount = 0
    var prevCommittedBlockCount = 0
    var businessExecutions = 0
    var refused: [String] = []
    var spoken: [String] = []
    var publicTexts: [String] = []
    var trace: [String] = []
    var failPersistence = false
    var onReminderPersist: (@MainActor () async -> Bool)?
    func effectiveContextWindow(for model: HostModel) -> Int { 0 }
    func estimateContextTokens() -> Int { 0 }
    func makeAgentTools() -> [AgentToolDefinition] {
        runtimeHostToolDefinitions
    }
    func persistAgentMessage(_ message: AgentMessage) async -> String? {
        guard !failPersistence else { return nil }
        if message.parts.contains(where: { if case .text(let text) = $0 { return text == MeetingAnswerUserTool.deliveryReminder }; return false }),
           let onReminderPersist, !(await onReminderPersist()) { return nil }
        persisted.append(message)
        trace.append("persist:\(message.role)")
        return "row-\(persisted.count)"
    }
    func stopSpeech() {}
    func ordinarySpeech(_ text: String) {
        if testCanSpeakNow && !text.isEmpty { spoken.append(text) }
    }
    func executeSingleToolUseInner(tu: StreamResult.ToolEntry, msgIdx: Int,
                                  tools: [AgentToolDefinition], batchBudget: BatchImageBudget) async -> ToolExecOutcome {
        let result: (output: String, success: Bool)
        if tu.name == "answer_user" {
            result = await MeetingAnswerUserTool.execute(tu.args, sessionID: sessionId, sessionSource: sessionSource)
        } else {
            precondition(tu.name == "apple_native")
            businessExecutions += 1
            result = ("Verified calendar result", true)
        }
        return .init(resultPart: .toolResult(id: tu.id, name: tu.name, content: result.output, isError: !result.success))
    }
    func hookBlockedOutcome(tu: StreamResult.ToolEntry, msgIdx: Int, reason: String,
                            isPolicyBlock: Bool = false) async -> ToolExecOutcome {
        precondition(isPolicyBlock)
        refused.append(tu.name)
        return .init(resultPart: .toolResult(id: tu.id, name: tu.name, content: reason, isError: true))
    }
    func bind(deliver: (@MainActor (String) async -> Bool)? = nil) -> UUID {
        let id = UUID()
        MeetingAnswerUserTool.bind(sessionID: sessionId!, requestID: id) { [self] text in
            if let deliver { return await deliver(text) }
            publicTexts.append(text)
            spoken.append(text)
            return true
        }
        return id
    }
    func seedExecutedBusiness() async {
        let call = StreamResult.ToolEntry(name: "apple_native", args: [:])
        let result = await executeSingleToolUse(tu: call, msgIdx: 0, tools: makeAgentTools(), batchBudget: .init())
        let message = AgentMessage(role: .user, parts: [result.resultPart])
        agentHistory.append(message)
        _ = await persistAgentMessage(message)
    }
    var reminderCount: Int {
        persisted.filter { message in
            message.parts.contains { if case .text(let text) = $0 { return text == MeetingAnswerUserTool.deliveryReminder }; return false }
        }.count
    }
    var completionCount: Int {
        persisted.filter { message in
            message.parts.contains { if case .text(let text) = $0 { return text == RawMessage.publicReplyCompletionText }; return false }
        }.count
    }
}
enum GroupMentionRouter {
    static func isPass(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) == "(pass)" }
}

@main struct MeetingAnswerRecoveryChecks {
    @MainActor static func main() async {
        for source in ["meeting_assistant", "xiaolan_voice", "fixture_interaction"] {
            AgentRuntimePolicies.register(source: source, policy: .init(
                allowedTools: ["answer_user", "apple_native"], noticeAllowedTools: ["answer_user"],
                additionalTools: [.init(name: "apple_native", description: "Host business boundary", parameters: [:], required: [])],
                replyDelivery: .init(definition: MeetingAnswerUserTool.definition,
                                     canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) },
                                     reminder: MeetingAnswerUserTool.deliveryReminder,
                                     didDeliver: { MeetingAnswerUserTool.didDeliver(sessionID: $0) }),
                allowsAutomaticSpeech: false
            ))
        }

        let plain = "PLAIN_ANSWER_MUST_NOT_BE_AUTOMATICALLY_SPOKEN"
        let answer = "今天有一项系统日程。"
        let reply = StreamResult.ToolEntry(name: "answer_user", args: ["text": answer])
        func twoTurns(_ second: ScriptTurn = .init(calls: [reply], stopReason: .toolUse)) -> ScriptProvider {
            ScriptProvider([.init(text: plain), second])
        }
        func assertNoRecovery(_ vm: AIChatViewModel, turn: ScriptTurn = .init(text: plain)) async {
            let provider = ScriptProvider([turn])
            await vm.runRecoveryScript(provider)
            precondition(provider.requests.count == 1 && vm.reminderCount == 0,
                         "Ineligible turns must not inject a reminder or request a supplementary delivery")
            precondition(provider.requiredToolNames.count == 1 && provider.requiredToolNames[0] == nil,
                         "Ordinary or rejected recovery must never force a tool choice")
        }

        let third = AIChatViewModel()
        third.sessionSource = "fixture_interaction"
        _ = third.bind()
        await third.seedExecutedBusiness()
        let thirdProvider = twoTurns()
        await third.runRecoveryScript(thirdProvider)
        precondition(thirdProvider.requests.count == 2 && thirdProvider.requests[1] == ["answer_user"]
                     && third.publicTexts == [answer] && third.businessExecutions == 1,
                     "An arbitrary registered interaction gets bounded reply recovery without engine branches")

        let voice = AIChatViewModel()
        voice.sessionSource = "xiaolan_voice"
        _ = voice.bind()
        await voice.seedExecutedBusiness()
        let voiceProvider = twoTurns()
        await voice.runRecoveryScript(voiceProvider)
        precondition(voiceProvider.requests.count == 2 && voiceProvider.requests[1] == ["answer_user"])
        precondition(voice.publicTexts == [answer] && voice.spoken == [answer] && voice.businessExecutions == 1,
                     "Independent voice also needs explicit once-only public delivery, with no ordinary or reasoning speech")

        let vm = AIChatViewModel()
        _ = vm.bind()
        await vm.seedExecutedBusiness()
        let provider = twoTurns()
        await vm.runRecoveryScript(provider)
        precondition(provider.requests.count == 2 && Set(provider.requests[0]) == ["answer_user", "apple_native"])
        precondition(provider.requests[1] == ["answer_user"], "Supplementary round may expose only the delivery tool")
        precondition(provider.requiredToolNames.count == 2 && provider.requiredToolNames[0] == nil
                     && provider.requiredToolNames[1] == "answer_user",
                     "Ordinary round keeps automatic choice; delivery round requires the tool at request scope")
        precondition(vm.businessExecutions == 1 && vm.publicTexts == [answer] && vm.spoken == [answer])
        precondition(vm.reminderCount == 1 && vm.persisted.count == 6 && vm.completionCount == 1,
                     "Business result, original answer, hidden reminder, paired delivery results and completion must persist")
        precondition(vm.persisted[1].role == .assistant && vm.persisted[2].role == .user)
        precondition(!vm.spoken.contains(plain) && !vm.spoken.contains(where: { $0.contains("PRIVATE_REASONING") }))
        let reminder = vm.persisted[2].parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
        precondition(reminder == MeetingAnswerUserTool.deliveryReminder)
        precondition(ContextDisplayCheck.stripSystemReminders(reminder).isEmpty,
                     "The actual reload display conversion must hide the durable delivery reminder")
        precondition(ContextDisplayCheck.stripSystemReminders(reminder + "\n新的用户指令").trimmingCharacters(in: .whitespacesAndNewlines) == "新的用户指令")

        // Same durable session after a previous public delivery. A fresh
        // request binding must not inherit the earlier answer's claimed flag,
        // and recovery must reuse all existing history and current tool results.
        let continuing = AIChatViewModel()
        let continuingSessionID = continuing.sessionId!
        let previousRequest = continuing.bind()
        let previousAnswer = "此前的会议事项已记录。"
        let previousCallID = "prior-answer-call"
        let previousReceipt = await MeetingAnswerUserTool.execute(
            ["text": previousAnswer], sessionID: continuingSessionID, sessionSource: continuing.sessionSource)
        precondition(previousReceipt.success)
        let priorHistory: [AgentMessage] = [
            .init(role: .user, parts: [.text("记住此前的会议事项")]),
            .init(role: .assistant, parts: [.toolUse(id: previousCallID, name: "answer_user", input: ["text": previousAnswer])]),
            .init(role: .user, parts: [.toolResult(id: previousCallID, name: "answer_user", content: previousReceipt.output, isError: false)])
        ]
        for var message in priorHistory {
            message.dbMessageId = await continuing.persistAgentMessage(message)
            continuing.agentHistory.append(message)
        }
        precondition(!MeetingAnswerUserTool.canRequestDelivery(sessionID: continuingSessionID))
        MeetingAnswerUserTool.unbind(sessionID: continuingSessionID, requestID: previousRequest)
        let currentRequest = continuing.bind()
        precondition(currentRequest != previousRequest
                     && MeetingAnswerUserTool.canRequestDelivery(sessionID: continuingSessionID))
        let currentCommand = AgentMessage(role: .user, parts: [.text("查一下今天的系统日程")])
        continuing.agentHistory.append(currentCommand)
        _ = await continuing.persistAgentMessage(currentCommand)
        await continuing.seedExecutedBusiness()
        let retainedHistoryIDs = continuing.agentHistory.compactMap(\.dbMessageId)
        let retainedHistoryCount = continuing.agentHistory.count
        let continuingProvider = twoTurns()
        await continuing.runRecoveryScript(continuingProvider)
        precondition(continuing.sessionId == continuingSessionID && continuing.sessionSource == "meeting_assistant",
                     "Supplementary delivery must not replace an existing recording session")
        precondition(continuingProvider.requests.count == 2
                     && continuingProvider.requiredToolNames[0] == nil
                     && continuingProvider.requiredToolNames[1] == "answer_user")
        precondition(continuingProvider.histories[0].count == retainedHistoryCount
                     && continuingProvider.histories[1].count == retainedHistoryCount + 2)
        precondition(Array(continuingProvider.histories[1].prefix(priorHistory.count)).compactMap(\.dbMessageId)
                     == Array(retainedHistoryIDs.prefix(priorHistory.count)),
                     "Existing persisted turns must remain in the supplemental provider request")
        for history in continuingProvider.histories {
            precondition(history.contains { message in message.parts.contains {
                if case .toolResult(_, let name, let content, let failed, _, _, _, _) = $0 {
                    return name == "apple_native" && content == "Verified calendar result" && !failed
                }
                return false
            } }, "Supplementary reply must reuse the already verified calendar result")
        }
        precondition(continuing.businessExecutions == 1 && continuing.reminderCount == 1
                     && continuing.publicTexts == [previousAnswer, answer]
                     && continuing.spoken == [previousAnswer, answer])
        precondition(!MeetingAnswerUserTool.didDeliver(sessionID: continuingSessionID, requestID: previousRequest)
                     && MeetingAnswerUserTool.didDeliver(sessionID: continuingSessionID, requestID: currentRequest))

        let emptyStop = AIChatViewModel()
        _ = emptyStop.bind()
        await emptyStop.seedExecutedBusiness()
        let errorUpdatesBeforeEmpty = ChatStore.shared.errorUpdates.count
        let emptyProvider = ScriptProvider([
            .init(text: "", reasoning: ""),
            .init(calls: [reply], stopReason: .toolUse)
        ])
        await emptyStop.runRecoveryScript(emptyProvider)
        precondition(emptyProvider.requests.count == 2
                     && emptyProvider.requiredToolNames[0] == nil
                     && emptyProvider.requiredToolNames[1] == "answer_user")
        precondition(emptyProvider.emptyRetryClassifications == [false, false],
                     "A clean empty meeting endTurn must bypass generic full-business-tool retries")
        precondition(emptyStop.businessExecutions == 1 && emptyStop.publicTexts == [answer]
                     && emptyStop.spoken == [answer] && !emptyStop.canResume && emptyStop.messages[0].error == nil)
        let emptyErrorUpdates = Array(ChatStore.shared.errorUpdates.dropFirst(errorUpdatesBeforeEmpty))
        precondition(emptyErrorUpdates.count == 2 && emptyErrorUpdates[0].error != nil
                     && emptyErrorUpdates[1].error == nil
                     && emptyErrorUpdates[0].messageID == emptyErrorUpdates[1].messageID,
                     "Only an accepted supplemental request clears the original empty-response error in memory and storage")

        for reason: AgentStopReason? in [nil, .maxTokens, .refusal] {
            let failedEmpty = AIChatViewModel()
            _ = failedEmpty.bind()
            let failedProvider = ScriptProvider([.init(text: "", reasoning: "", stopReason: reason)])
            await failedEmpty.runRecoveryScript(failedProvider)
            precondition(failedProvider.requests.count == 1 && failedProvider.requiredToolNames[0] == nil
                         && failedEmpty.reminderCount == 0 && failedEmpty.canResume
                         && failedEmpty.messages[0].error != nil)
            precondition(failedProvider.emptyRetryClassifications == [reason == nil],
                         "Nil stop retains generic empty-response retry classification; token/refusal failures do not become forced delivery")
        }
        let interruptedEmpty = AIChatViewModel()
        _ = interruptedEmpty.bind()
        await assertNoRecovery(interruptedEmpty, turn: .init(text: "", reasoning: "", interrupted: true))
        precondition(interruptedEmpty.canResume && interruptedEmpty.messages[0].error != nil)

        for losesBinding in [false, true] {
            let rejectedEmpty = AIChatViewModel()
            let rejectedRequest = rejectedEmpty.bind()
            rejectedEmpty.onReminderPersist = {
                if losesBinding {
                    MeetingAnswerUserTool.unbind(sessionID: rejectedEmpty.sessionId!, requestID: rejectedRequest)
                }
                return losesBinding
            }
            let rejectedProvider = ScriptProvider([.init(text: "", reasoning: "")])
            let errorUpdatesBeforeRejection = ChatStore.shared.errorUpdates.count
            await rejectedEmpty.runRecoveryScript(rejectedProvider)
            precondition(rejectedProvider.requests.count == 1 && rejectedProvider.requiredToolNames[0] == nil
                         && rejectedEmpty.canResume && rejectedEmpty.messages[0].error != nil)
            let rejectedUpdates = Array(ChatStore.shared.errorUpdates.dropFirst(errorUpdatesBeforeRejection))
            precondition(rejectedUpdates.count == 1 && rejectedUpdates[0].error != nil,
                         "Reminder persistence failure or binding loss must retain the original resumable error")
        }

        for noReplyBinding in [false, true] {
            let unavailableEmpty = AIChatViewModel()
            if noReplyBinding {
                _ = unavailableEmpty.bind()
                _ = await MeetingAnswerUserTool.execute(["text": answer], sessionID: unavailableEmpty.sessionId,
                                                        sessionSource: unavailableEmpty.sessionSource)
            }
            precondition(unavailableEmpty.testIsEmptyResponse(.init(assistantText: "", reasoningContent: "")),
                         "Unbound or already claimed delivery must keep generic empty-response behavior")
            precondition(unavailableEmpty.testUsesGenericEmptyFallback(.init(assistantText: "", reasoningContent: "")),
                         "Model-group fallback must retain its existing behavior without an open reply binding")
        }

        let emptyFallback = AIChatViewModel()
        _ = emptyFallback.bind()
        precondition(!emptyFallback.testUsesGenericEmptyFallback(.init(assistantText: "", reasoningContent: "")),
                     "A model-group clean empty endTurn must return directly to the bounded meeting delivery round")
        for reason: AgentStopReason? in [nil, .refusal] {
            precondition(emptyFallback.testUsesGenericEmptyFallback(
                .init(assistantText: "", stopReason: reason, reasoningContent: "")),
                         "The meeting exception must not intercept the existing nil/refusal generic fallback path")
        }
        let nonemptyFallbackResults: [StreamResult] = [
            .init(assistantText: plain, reasoningContent: ""),
            .init(assistantText: "", reasoningContent: "reasoning"),
            .init(assistantText: "", toolEntries: [reply], reasoningContent: ""),
            .init(assistantText: "", stopReason: .maxTokens, reasoningContent: ""),
            .init(assistantText: "", reasoningContent: "", isStreamInterrupted: true)
        ]
        for result in nonemptyFallbackResults {
            precondition(!emptyFallback.testUsesGenericEmptyFallback(result),
                         "Nonempty, token-limit and interrupted results retain the pre-existing direct-return boundary")
        }
        for source: String? in [nil, "chat", "group"] {
            let ordinaryFallback = AIChatViewModel()
            _ = ordinaryFallback.bind()
            ordinaryFallback.sessionSource = source
            precondition(ordinaryFallback.testUsesGenericEmptyFallback(.init(assistantText: "", reasoningContent: "")),
                         "Ordinary sessions must continue their existing empty model-group fallback")
        }
        let childFallback = AIChatViewModel()
        _ = childFallback.bind()
        childFallback.agentRole = .executor
        precondition(childFallback.testUsesGenericEmptyFallback(.init(assistantText: "", reasoningContent: "")))

        let bounded = AIChatViewModel()
        _ = bounded.bind()
        await bounded.seedExecutedBusiness()
        let twicePlain = twoTurns(.init(text: "SECOND_PLAIN_MUST_STAY_SILENT"))
        await bounded.runRecoveryScript(twicePlain)
        precondition(twicePlain.requests.count == 2 && bounded.reminderCount == 1)
        precondition(bounded.businessExecutions == 1 && bounded.publicTexts.isEmpty && bounded.spoken.isEmpty,
                     "A second omission must stop without replay or plain-text speech")

        let forged = AIChatViewModel()
        _ = forged.bind()
        await forged.seedExecutedBusiness()
        let forgedProvider = twoTurns(.init(calls: [.init(name: "apple_native", args: [:]), reply], stopReason: .toolUse))
        await forged.runRecoveryScript(forgedProvider)
        precondition(forged.businessExecutions == 1 && forged.refused == ["apple_native"])
        precondition(forged.publicTexts == [answer] && forgedProvider.requests.count == 2,
                     "Real dispatch policy must reject a forged business tool in delivery-only mode")

        // A provider can close its turn in the same response as a business call.
        let closeWithTool = AIChatViewModel()
        _ = closeWithTool.bind()
        let toolCloseProvider = ScriptProvider([
            .init(text: plain, calls: [.init(name: "apple_native", args: [:])]),
            .init(calls: [reply], stopReason: .toolUse)
        ])
        await closeWithTool.runRecoveryScript(toolCloseProvider)
        precondition(toolCloseProvider.requests.count == 2 && toolCloseProvider.requests[1] == ["answer_user"])
        precondition(toolCloseProvider.requiredToolNames[0] == nil && toolCloseProvider.requiredToolNames[1] == "answer_user")
        precondition(closeWithTool.businessExecutions == 1 && closeWithTool.publicTexts == [answer])

        for toolClose in [false, true] {
            for persistenceSucceeds in [false, true] {
                let raced = AIChatViewModel()
                _ = raced.bind()
                raced.onReminderPersist = {
                    raced.promptQueue.append("新的用户指令，必须由新的回合处理")
                    if persistenceSucceeds {
                        _ = await MeetingAnswerUserTool.execute(["text": answer], sessionID: raced.sessionId, sessionSource: raced.sessionSource)
                    }
                    return persistenceSucceeds
                }
                let calls: [StreamResult.ToolEntry] = toolClose ? [.init(name: "apple_native", args: [:])] : []
                let racedProvider = ScriptProvider([.init(text: plain, calls: calls)])
                await raced.runRecoveryScript(racedProvider)
                precondition(racedProvider.requests.count == 1 && raced.promptQueue.count == 1,
                             "Failed reminder persistence or a claim during its await must stop; queued instructions belong to a fresh run")
                precondition(raced.businessExecutions == (toolClose ? 1 : 0))
                precondition(raced.publicTexts == (persistenceSucceeds ? [answer] : []))
                if toolClose { precondition(!raced.messages[0].isAwaitingModelResponse) }
            }
        }

        for delivered in [true, false] {
            let claimed = AIChatViewModel()
            _ = claimed.bind(deliver: { _ in delivered })
            _ = await MeetingAnswerUserTool.execute(["text": answer], sessionID: claimed.sessionId, sessionSource: claimed.sessionSource)
            precondition(!MeetingAnswerUserTool.canRequestDelivery(sessionID: claimed.sessionId))
            await assertNoRecovery(claimed)
        }
        let inFlight = AIChatViewModel()
        var release: CheckedContinuation<Bool, Never>?
        _ = inFlight.bind(deliver: { _ in await withCheckedContinuation { release = $0 } })
        let delivery = Task { await MeetingAnswerUserTool.execute(["text": answer], sessionID: inFlight.sessionId, sessionSource: inFlight.sessionSource) }
        for _ in 0..<1_000 { if release != nil { break }; await Task.yield() }
        precondition(release != nil && !MeetingAnswerUserTool.canRequestDelivery(sessionID: inFlight.sessionId))
        await assertNoRecovery(inFlight)
        release!.resume(returning: true)
        _ = await delivery.value

        let unbound = AIChatViewModel()
        let old = unbound.bind()
        MeetingAnswerUserTool.unbind(sessionID: unbound.sessionId!, requestID: old)
        await assertNoRecovery(unbound)
        precondition(!MeetingAnswerUserTool.canRequestDelivery(sessionID: nil))
        let cancelled = AIChatViewModel()
        _ = cancelled.bind()
        cancelled.userDidCancel = true
        await assertNoRecovery(cancelled)
        let queued = AIChatViewModel()
        _ = queued.bind()
        queued.promptQueue.append("用户已有排队请求")
        await assertNoRecovery(queued)
        let cancelledTask = AIChatViewModel()
        _ = cancelledTask.bind()
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            precondition(!MeetingAnswerUserTool.canRequestDelivery(sessionID: cancelledTask.sessionId))
            await assertNoRecovery(cancelledTask)
        }.value

        for reason: AgentStopReason? in [nil, .maxTokens, .refusal] {
            let broken = AIChatViewModel()
            _ = broken.bind()
            await assertNoRecovery(broken, turn: .init(text: plain, stopReason: reason, interrupted: true))
        }
        let interrupted = AIChatViewModel()
        _ = interrupted.bind()
        await assertNoRecovery(interrupted, turn: .init(text: plain, interrupted: true))
        let error = AIChatViewModel()
        _ = error.bind()
        await assertNoRecovery(error, turn: .init(throwsError: true))
        let pass = AIChatViewModel()
        _ = pass.bind()
        pass.isNoticeDriven = true
        await assertNoRecovery(pass, turn: .init(text: "(pass)"))
        for source: String? in [nil, "chat", "hardware", "group"] {
            let ordinary = AIChatViewModel()
            _ = ordinary.bind()
            ordinary.sessionSource = source
            await assertNoRecovery(ordinary)
        }
        let child = AIChatViewModel()
        _ = child.bind()
        child.agentRole = .executor
        await assertNoRecovery(child)

        print("PASS: actual recovery branches request only answer_user once, retain verified business results and deliver once without plain-text/reasoning TTS")
        print("PASS: existing recording history and prior public reply survive a fresh binding; only the supplemental request requires answer_user across all five production request sites")
        print("PASS: clean empty endTurn skips generic retries and forces one answer without replay; interrupted/nil/token/refusal/claimed cases retain their original boundaries")
        print("PASS: actual model-group empty fallback returns authorized meeting stops for delivery; ordinary/child/unbound/claimed/nil/refusal fallback and nonempty exits remain unchanged")
        print("PASS: real dispatch blocks forged business calls; claimed/in-flight/stale/cancelled/interrupted/error/pass/ordinary turns never request recovery")
        print("PASS: independent voice reuses bounded answer-only recovery without ordinary/reasoning speech or replayed business operations")

        for reason in [AgentStopReason.endTurn, .toolUse] {
            let direct = AIChatViewModel()
            _ = direct.bind()
            let directProvider = ScriptProvider([.init(calls: [reply], stopReason: reason)])
            await direct.runRecoveryScript(directProvider)
            precondition(directProvider.requests.count == 1 && direct.reminderCount == 0
                         && direct.completionCount == 1 && direct.publicTexts == [answer] && direct.spoken == [answer],
                         "Direct public delivery must finish once, without another model request or duplicate speech")
            let reloaded = AIChatViewModel()
            reloaded.agentHistory = direct.persisted
            reloaded.testRecheckCanResumeFromHistory()
            let tail = reloaded.agentHistory.last!
            precondition(!reloaded.canResume && !ChatStore.isInterruptedTail(role: tail.role, parts: tail.parts))
        }
        let failedDelivery = AIChatViewModel()
        _ = failedDelivery.bind(deliver: { _ in false })
        await failedDelivery.runRecoveryScript(twoTurns())
        precondition(failedDelivery.completionCount == 0 && !MeetingAnswerUserTool.didDeliver(sessionID: failedDelivery.sessionId),
                     "Claiming a failed public delivery must not mark the turn complete")
        let cancelledDelivery = AIChatViewModel()
        _ = cancelledDelivery.bind(deliver: { _ in cancelledDelivery.userDidCancel = true; return true })
        await cancelledDelivery.runRecoveryScript(twoTurns())
        precondition(cancelledDelivery.completionCount == 0 && cancelledDelivery.userDidCancel,
                     "A cancelled delivery round must not append a normal completion")
        for incomplete in [failedDelivery, cancelledDelivery] {
            let reloaded = AIChatViewModel()
            reloaded.agentHistory = incomplete.persisted
            reloaded.testRecheckCanResumeFromHistory()
            let tail = reloaded.agentHistory.last!
            precondition(reloaded.canResume && ChatStore.isInterruptedTail(role: tail.role, parts: tail.parts),
                         "Failed or cancelled delivery must retain its recovery after persistence reload")
        }
        precondition(bounded.completionCount == 0 && unbound.completionCount == 0 && inFlight.completionCount == 0)
        precondition(RawMessage.isInternalBridgeText(RawMessage.publicReplyCompletionText)
                     && ContextDisplayCheck.stripSystemReminders(RawMessage.publicReplyCompletionText).isEmpty,
                     "The durable completion must be hidden by real bridge and text display filters")

        // Keep genuinely unfinished business and cancelled public delivery
        // resumable in both the reloaded detail view and the session list.
        let unfinishedTails: [AgentMessage] = [
            .init(role: .assistant, parts: [.toolUse(id: "unfinished-business", name: "apple_native", input: [:])]),
            .init(role: .user, parts: [.toolResult(id: "unfinished-business", name: "apple_native",
                                               content: "Verified calendar result", isError: false)]),
            .init(role: .user, parts: [.toolResult(id: "cancelled-answer", name: "answer_user",
                                               content: "{\"status\":\"stale\"}", isError: true)])
        ]
        for tail in unfinishedTails {
            let reloaded = AIChatViewModel()
            reloaded.agentHistory = [tail]
            reloaded.testRecheckCanResumeFromHistory()
            precondition(reloaded.canResume && ChatStore.isInterruptedTail(role: tail.role, parts: tail.parts),
                         "Unfinished business or cancelled delivery must remain resumable after reload")
        }

        // Recovery has already delivered its public answer and returned
        // normally. Rebuild from the actual persisted recovery records, then
        // run both production interruption classifiers without a wake/cancel.
        // A successful reply must not turn into Interrupted while host TTS is
        // still playing or when the user opens this conversation later.
        for completed in [voice, vm, emptyStop] {
            precondition(!completed.userDidCancel && !completed.canResume && completed.publicTexts == [answer]
                         && completed.completionCount == 1)
            let reloaded = AIChatViewModel()
            reloaded.sessionId = completed.sessionId
            reloaded.agentHistory = completed.persisted
            reloaded.testRecheckCanResumeFromHistory()
            let tail = reloaded.agentHistory.last!
            let listInterrupted = ChatStore.isInterruptedTail(role: tail.role, parts: tail.parts)
            print("Recovery reload: source=\(completed.sessionSource ?? "nil") detailInterrupted=\(reloaded.canResume) listInterrupted=\(listInterrupted)")
            precondition(!reloaded.canResume && !listInterrupted,
                         "A normally delivered public answer must remain completed after persistence reload")
        }
        print("PASS: completed public delivery remains completed after real detail/list tail checks; unfinished and cancelled tool turns remain resumable")
    }
}
