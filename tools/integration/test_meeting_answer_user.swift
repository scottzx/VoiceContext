import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

// Boundary fixture for the canonical peer-directory tools.
enum AgentDirectoryTools {
    static var definitions: [AgentToolDefinition] {
        ["list_agents", "send_agent_message", "create_agent"].map {
            AgentToolDefinition(name: $0, description: $0, parameters: [:], required: [])
        }
    }
}

// Only the surrounding chat VM/UI storage is fake. The canonical schema,
// answer tool, meeting-only registration and dispatcher case are product code.
@MainActor final class AIChatViewModel {
    enum Role { case main, executor }
    struct Block { var content = "" }
    struct Message { var blocks = [Block()] }
    var sessionId: String? = "meeting-test"
    var sessionSource: String? = "meeting_assistant"
    var isNoticeDriven = false
    var runtimePolicy: AgentRuntimePolicy { AgentRuntimePolicies.policy(for: sessionSource) }
    var agentRole: Role = .main
    var messages = [Message()]
}

@main struct MeetingAnswerUserChecks {
    @MainActor static func main() async {
        for source in ["meeting_assistant", "xiaolan_voice", "fixture_interaction"] {
            AgentRuntimePolicies.register(source: source, policy: .init(
                replyDelivery: .init(definition: MeetingAnswerUserTool.definition,
                                     canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) },
                                     reminder: MeetingAnswerUserTool.deliveryReminder)
            ))
        }

        let vm = AIChatViewModel()
        let sessionID = vm.sessionId!
        func status(_ result: (output: String, success: Bool)) -> String {
            let body = try! JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: String]
            return body["status"]!
        }
        func execute(_ args: [String: Any]) async -> (output: String, success: Bool) {
            await vm.dispatchAnswer(args)
        }
        func request() -> UUID { UUID() }

        precondition(vm.runtimeHostToolDefinitions.map(\.name) == ["answer_user"])
        vm.agentRole = .executor
        precondition(vm.runtimeHostToolDefinitions.isEmpty, "Executors must never see the user speech tool")
        vm.agentRole = .main
        precondition(MeetingAnswerUserTool.definition.required == ["text"])
        precondition(Set(MeetingAnswerUserTool.definition.parameters.keys) == ["text"])
        for source: String? in [nil, "chat", "shortcut", "hardware", "group"] {
            vm.sessionSource = source
            precondition(vm.runtimeHostToolDefinitions.isEmpty, "Ordinary sessions must never see answer_user")
            let result = await execute(["text": "不应交付"])
            precondition(!result.success && status(result) == "wrong_session")
        }
        vm.sessionSource = "meeting_assistant"
        precondition(MeetingAnswerUserTool.activeRequestID(sessionID: sessionID) == nil)
        let missing = await execute(["text": "无绑定"])
        precondition(!missing.success && status(missing) == "stale")

        vm.sessionSource = "fixture_interaction"
        let thirdID = request()
        var thirdTexts: [String] = []
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: thirdID) { text in
            thirdTexts.append(text)
            return true
        }
        let thirdReceipt = await execute(["text": "第三种交互已交付"])
        precondition(thirdReceipt.success && status(thirdReceipt) == "delivered" && thirdTexts == ["第三种交互已交付"])
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: thirdID)
        vm.sessionSource = "meeting_assistant"

        let firstID = request()
        var publicTexts: [String] = []
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: firstID) { text in
            publicTexts.append(text)
            return true // Public text remains delivered even if host TTS fails.
        }
        precondition(MeetingAnswerUserTool.activeRequestID(sessionID: sessionID) == firstID)
        let invalid: [[String: Any]] = [
            [:], ["text": ""], ["text": " \n\t"], ["text": 42],
            ["text": NSNull()], ["text": ["answer"]], ["text": String(repeating: "字", count: 2_001)],
            ["text": "答复", "reasoning": "private"], ["reasoning": "private"],
            ["text": "答复", "tool_title": "extra"]
        ]
        for args in invalid {
            let result = await execute(args)
            precondition(!result.success && status(result) == "invalid_arguments")
        }
        precondition(publicTexts.isEmpty && !MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: firstID))
        let valid = await execute(["text": "  已保存待办。\n"])
        precondition(valid.success && status(valid) == "delivered")
        precondition(MeetingAnswerUserTool.activeRequestID(sessionID: sessionID) == nil,
                     "A public answer closes authority for further business handoffs")
        precondition(publicTexts == ["已保存待办。"])
        precondition(MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: firstID))
        precondition(vm.messages[0].blocks[0].content == valid.output, "Dispatcher must preserve the truthful receipt")
        // Rebinding the same request cannot reset the delivery claim.
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: firstID) { _ in
            preconditionFailure("Same-request rebind must not replace the delivery callback")
        }
        let duplicate = await execute(["text": "另一条答复"])
        precondition(duplicate.success && status(duplicate) == "already_delivered" && publicTexts.count == 1)
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: request())
        precondition(MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: firstID))
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: firstID)
        precondition(!MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: firstID))
        let late = await execute(["text": "迟到答复"])
        precondition(status(late) == "stale")

        let concurrentID = request()
        var release: CheckedContinuation<Bool, Never>?
        var concurrentCalls = 0
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: concurrentID) { _ in
            concurrentCalls += 1
            return await withCheckedContinuation { release = $0 }
        }
        let inFlight = Task { await execute(["text": "最终答复"]) }
        for _ in 0..<1_000 {
            if release != nil { break }
            await Task.yield()
        }
        precondition(release != nil, "First call must reach the host callback")
        precondition(MeetingAnswerUserTool.activeRequestID(sessionID: sessionID) == nil,
                     "An in-flight answer has already closed business handoff authority")
        let parallel = await execute(["text": "并发重复答复"])
        precondition(parallel.success && status(parallel) == "in_progress" && concurrentCalls == 1)
        release!.resume(returning: true)
        let completed = await inFlight.value
        precondition(status(completed) == "delivered")
        precondition(MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: concurrentID))

        let staleID = request()
        var staleCalls = 0
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: staleID) { _ in
            staleCalls += 1
            return false
        }
        let rejected = await execute(["text": "当前已关闭"])
        precondition(!rejected.success && status(rejected) == "stale")
        precondition(!MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: staleID))
        let rejectedAgain = await execute(["text": "重复交付"])
        precondition(status(rejectedAgain) == "stale" && staleCalls == 1)

        // Closing/replacing during async speech must not undo already shown
        // text or let an old completion/cleanup mutate a newer request.
        let oldID = request(), newID = request()
        release = nil
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: oldID) { _ in
            return await withCheckedContinuation { release = $0 }
        }
        let old = Task { await execute(["text": "已展示，播报仍在等待"]) }
        for _ in 0..<1_000 {
            if release != nil { break }
            await Task.yield()
        }
        precondition(release != nil)
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: oldID)
        var newCalls = 0
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: newID) { _ in newCalls += 1; return true }
        release!.resume(returning: true)
        let oldResult = await old.value
        precondition(oldResult.success && status(oldResult) == "delivered", "Displayed text must not be reported stale")
        precondition(!MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: newID))
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: oldID)
        let newResult = await execute(["text": "新请求答复"])
        precondition(status(newResult) == "delivered" && newCalls == 1)

        let limitID = request()
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: limitID) { text in
            precondition(text.count == 2_000)
            return true
        }
        let maxResult = await execute(["text": String(repeating: "字", count: 2_000)])
        precondition(status(maxResult) == "delivered")
        MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: limitID)
        print("PASS: explicit meeting answers, schema validation, source gate, async deduplication and stale isolation")
    }
}
