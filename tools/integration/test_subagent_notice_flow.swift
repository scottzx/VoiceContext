import Foundation

func AppLocalized(_ text: String) -> String { text }
struct AppLogger {
    init(category: String) {}
    func info(_ text: String) {}
    func warning(_ text: String) {}
    func error(_ text: String) {}
    func debug(_ text: String) {}
}
enum AgentToolPolicy: String { case standalone, orchestrator }
enum AgentRunRole: String { case main, executor }
enum AgentProfile { static let defaultAgentId = "agent-default" }
struct AgentCoreDecision {}
extension Notification.Name { static let sessionAgentLoopDidEnd = Notification.Name("testLoopDidEnd") }
enum OrchestratorPrompt {
    static func taskDeliveryDir(taskId: String) -> String { "/var/minis/shared/tasks/" + taskId }
}
struct ChatSession {
    let id: String
    var source: String = "subagent"
    var agentId: String?
    var parentSessionId: String?
    var title: String?
    var spawnTitle: String?
    var spawnStatus: String? = "running"
    var spawnResult: String?
    var lastMessage: String?
    var createdAt = Date()
}
struct AsyncTaskNotice {
    let id: String; let sourceSessionId: String; let taskType: String; let taskId: String
    let agentId: String?; let title: String?; let status: String; let result: String
    let filesPath: String?; let createdAt: Date; var isDelivered: Bool
}
struct ToolUse { let toolUseId: String; let name: String; let input: String; let description: String }
struct ToolResult { let toolUseId: String; let output: String; let success: Bool; let status: String }
enum ContentPart { case toolUse(ToolUse), toolResult(ToolResult), text(String) }
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
struct RawMessage {
    enum Role { case assistant, user }
    let id: String; let sessionId: String; let role: Role; let parts: [ContentPart]; let createdAt: Date
}
enum ChatPersistenceSchema {
    static let asyncTaskNoticeToolUseIdPrefix = "notice:"
    static let asyncTaskNoticeToolName = "async_task_notice"
}
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var sessions: [String: ChatSession] = [:]
    var notices: [String: AsyncTaskNotice] = [:]
    var messages: [RawMessage] = []
    var injections = 0
    var holdNextSessionRead: String?
    var sessionReadGate: CheckedContinuation<Void, Never>?
    var holdNextDeliveredCheck: String?
    var deliveredCheckGate: CheckedContinuation<Void, Never>?
    var saves: [String: Int] = [:]
    func getSession(_ id: String) async -> ChatSession? {
        let snapshot = sessions[id]
        if holdNextSessionRead == id {
            holdNextSessionRead = nil
            await withCheckedContinuation { sessionReadGate = $0 }
        }
        return snapshot
    }
    func updateSpawnOutcome(_ id: String, status: String, result: String?) async {
        sessions[id]?.spawnStatus = status
        if let result { sessions[id]?.spawnResult = result }
    }
    func runningSubagentSessions() async -> [ChatSession] { sessions.values.filter { $0.spawnStatus == "running" && $0.parentSessionId != nil } }
    func hasDeliveredNotice(id: String) async -> Bool {
        let delivered = notices[id]?.isDelivered == true
        if let held = holdNextDeliveredCheck, id.contains(held) {
            holdNextDeliveredCheck = nil
            await withCheckedContinuation { deliveredCheckGate = $0 }
        }
        return delivered
    }
    func saveAsyncTaskNotice(_ notice: AsyncTaskNotice) async {
        saves[notice.id, default: 0] += 1
        notices[notice.id] = notice
    }
    func sessionsWithPendingAsyncTaskNotices() async -> [String] { Array(Set(notices.values.filter { !$0.isDelivered }.map(\.sourceSessionId))) }
    func pendingAsyncTaskNotices(for id: String) async -> [AsyncTaskNotice] {
        await Task.yield()
        return notices.values.filter { $0.sourceSessionId == id && !$0.isDelivered }.sorted { $0.createdAt < $1.createdAt }
    }
    func injectAsyncTaskNoticeMessages(_ input: [RawMessage], noticeIds: [String]) async -> Bool {
        injections += 1
        precondition(input.count == noticeIds.count * 2)
        messages.append(contentsOf: input)
        for id in noticeIds { notices[id]?.isDelivered = true }
        return true
    }
    func markAsyncTaskNoticesPending(ids: [String]) async { for id in ids { notices[id]?.isDelivered = false } }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var active: Set<String> = []
    func isActive(_ id: String) -> Bool { active.contains(id) }
}
@MainActor final class HostViewModel {
    var agentHistory: [AgentMessage] = []
    var messages: [ChatMessage] = []
    var isProcessing = false
    var isCompacting = false
    var isTruncatingForRetry = false
    var compactTask: Task<Void, Never>?
    var postCompactDrainPending = false
    var promptQueue: [String] = []
}
@MainActor enum AIChatViewModel { static var activeSessionId: String? }
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var models: [String: HostViewModel] = [:]
    func get(for id: String) -> HostViewModel? { models[id] }
}
@MainActor final class HostRunner: AgentSessionRunning {
    static let shared = HostRunner()
    var creates: [AgentSessionCreateRequest] = []
    var runs: [AgentSessionRunRequest] = []
    var resumed: [String] = []
    var waits: [String: CheckedContinuation<AgentSessionRunResult, Never>] = [:]
    var live: Set<String> = []
    var holdNextStatus: String?
    var statusGate: CheckedContinuation<Void, Never>?
    var cancellations = 0
    var holdNextResume = false
    var resumeGate: CheckedContinuation<Void, Never>?
    var source = "third-voice-entry"
    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        creates.append(request)
        let id = UUID().uuidString
        ChatStore.shared.sessions[id] = ChatSession(id: id, agentId: request.agentId, parentSessionId: request.parentSessionId, spawnTitle: request.spawnTitle)
        return id
    }
    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        runs.append(request); live.insert(request.sessionId)
        let result = await withCheckedContinuation { waits[request.sessionId] = $0 }
        if !result.timedOut { live.remove(request.sessionId) }
        ChatStore.shared.sessions[request.sessionId]?.lastMessage = result.text
        return result
    }
    func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult {
        resumed.append(sessionId)
        if holdNextResume {
            holdNextResume = false
            await withCheckedContinuation { resumeGate = $0 }
        }
        let outputs = ChatStore.shared.messages.filter { $0.sessionId == sessionId }.flatMap(\.parts).compactMap { part -> String? in
            if case .toolResult(let result) = part { return result.output }; return nil
        }
        let delivered = await MeetingAnswerUserTool.execute(["text": outputs.last ?? "结果缺失"], sessionID: sessionId, sessionSource: source)
        return .init(text: nil, accepted: delivered.success, timedOut: false, cancelled: false)
    }
    func status(sessionId: String) async -> AgentSessionStatus {
        let snapshot = AgentSessionStatus(isRunning: live.contains(sessionId), lastAssistantText: ChatStore.shared.sessions[sessionId]?.lastMessage)
        if holdNextStatus == sessionId {
            holdNextStatus = nil
            await withCheckedContinuation { statusGate = $0 }
        }
        return snapshot
    }
    func isRunning(sessionId: String) async -> Bool { live.contains(sessionId) }
    func cancel(sessionId: String) {
        cancellations += 1
        live.remove(sessionId)
        waits.removeValue(forKey: sessionId)?.resume(returning: .init(text: nil, accepted: true, timedOut: false, cancelled: true))
    }
    func complete(_ id: String, text: String) {
        waits.removeValue(forKey: id)!.resume(returning: .init(text: text, accepted: true, timedOut: false, cancelled: false))
    }
    func timeout(_ id: String) {
        waits.removeValue(forKey: id)!.resume(returning: .init(text: nil, accepted: true, timedOut: true, cancelled: false))
    }
}
typealias IOSAgentSessionRunner = HostRunner
@MainActor final class RoutingSubagentExecutor: SubagentExecutor {
    func spawn(_ task: SubagentTask) async throws -> String { preconditionFailure("Only injected real local executor is permitted") }
    func status(taskId: String) async -> SubagentStatus { preconditionFailure() }
    func message(taskId: String, text: String) async throws { preconditionFailure() }
    func stop(taskId: String) async -> Bool { preconditionFailure() }
}

@main struct SubagentNoticeFlowChecks {
    @MainActor static func main() async throws {
        let childRunner = HostRunner()
        let parentRunner = HostRunner()
        let executor = LocalSubagentExecutor(sessionRunner: childRunner)
        let coordinator = SubagentCoordinator(executor: executor)
        let manager = AsyncTaskNoticeManager.shared
        manager.sessionRunner = parentRunner
        let parent = "parent-session", agent = "third-agent"
        ChatStore.shared.sessions[parent] = ChatSession(id: parent, agentId: agent)
        var policy = AgentRuntimePolicy(requiresNoticeReplyBinding: true)
        policy.replyDelivery = .init(definition: MeetingAnswerUserTool.definition, canRequest: MeetingAnswerUserTool.canRequestDelivery, reminder: MeetingAnswerUserTool.deliveryReminder)
        AgentRuntimePolicies.register(source: parentRunner.source, policy: policy)
        // Source metadata is transport configuration, not a built-in identity.
        ChatStore.shared.sessions[parent]?.source = parentRunner.source
        var canReply = true
        var publicAnswers: [String] = []
        var prepared = 0, finished = 0
        var requestID: UUID?
        manager.replyHooks[parentRunner.source] = .init(prepare: { id in
            guard canReply else { return false }
            prepared += 1
            let token = UUID(); requestID = token
            MeetingAnswerUserTool.bind(sessionID: id, requestID: token) { text in publicAnswers.append(text); return true }
            return true
        }, finish: { id, _ in
            finished += 1
            if let requestID { MeetingAnswerUserTool.unbind(sessionID: id, requestID: requestID) }
        })
        func waitUntil(line: UInt = #line, _ condition: @MainActor () -> Bool) async {
            for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
            preconditionFailure("Expected asynchronous flow to advance at line \(line)")
        }
        func spawn(_ title: String) async -> String {
            let receipt = await coordinator.handle(toolName: "spawn_subagent", input: ["task_title": title, "prompt": "生成经验证的结果并返回自己的文件路径。"], parentSessionId: parent, agentId: agent)
            precondition(receipt.hasPrefix("Task started.") && receipt.contains("async_task_notice"))
            let id = String(receipt.components(separatedBy: .newlines).first { $0.hasPrefix("task_id: ") }!.dropFirst(9))
            await waitUntil { childRunner.waits[id] != nil }
            return id
        }
        let first = await spawn("资料整理")
        precondition(childRunner.creates.count == 1 && childRunner.runs.count == 1)
        precondition(childRunner.creates[0].parentSessionId == parent && childRunner.creates[0].inheritModelFromSessionId == parent)
        precondition(childRunner.creates[0].agentId == agent && childRunner.runs[0].agentId == agent)
        precondition(childRunner.runs[0].source == "subagent" && childRunner.runs[0].role == "executor")
        precondition(publicAnswers.isEmpty && parentRunner.resumed.isEmpty && ChatStore.shared.notices.isEmpty,
                     "Starting work is not completion or a second wake")
        canReply = false
        childRunner.complete(first, text: "资料已整理，真实任务结果")
        await waitUntil { !ChatStore.shared.notices.isEmpty }
        await Task.yield()
        precondition(parentRunner.resumed.isEmpty && publicAnswers.isEmpty, "Unavailable host keeps completion pending")
        canReply = true
        await manager.checkAndDrain(sessionId: parent)
        await waitUntil { publicAnswers.count == 1 && finished == 1 }
        precondition(parentRunner.resumed == [parent] && publicAnswers[0].contains("真实任务结果"))
        precondition(ChatStore.shared.sessions[first]?.spawnStatus == "done")
        precondition(ChatStore.shared.notices.values.first!.taskType == "subagent")
        precondition(ChatStore.shared.notices.values.first!.agentId == agent)
        precondition(ChatStore.shared.notices.values.first!.filesPath == OrchestratorPrompt.taskDeliveryDir(taskId: first))
        await manager.checkAndDrain(sessionId: parent)
        let notice = ChatStore.shared.notices.values.first!
        _ = await manager.postNotice(sourceSessionId: parent, taskType: notice.taskType, taskId: notice.taskId, status: notice.status, result: notice.result, noticeId: notice.id)
        precondition(publicAnswers.count == 1 && prepared == 1 && ChatStore.shared.injections == 1, "Duplicate notices cannot wake twice")
        let second = await spawn("可停止任务")
        let stopped = await coordinator.handle(toolName: "stop_subagent", input: ["task_id": second], parentSessionId: parent, agentId: agent)
        precondition(stopped.contains("stopped"))
        await waitUntil { publicAnswers.count == 2 && finished == 2 }
        precondition(ChatStore.shared.sessions[second]?.spawnStatus == "stopped")
        precondition(childRunner.creates.count == 2 && parentRunner.creates.isEmpty && parentRunner.runs.isEmpty,
                     "Completion resumes the original parent; no Yima main session or replacement parent is created")
        let store = ChatStore.shared
        // Freeze startRun after the actual run finishes but before it persists
        // its result. status() must leave that local finalizer as sole owner.
        let interleaved = await spawn("status 与结束交错")
        let answersBeforeInterleave = publicAnswers.count
        store.holdNextSessionRead = interleaved
        childRunner.complete(interleaved, text: "交错完成结果")
        await waitUntil { store.sessionReadGate != nil }
        let midFinalization = await executor.status(taskId: interleaved)
        store.sessionReadGate?.resume(); store.sessionReadGate = nil
        await waitUntil { publicAnswers.count == answersBeforeInterleave + 1 }
        await Task.yield()
        precondition(midFinalization.state == .running && store.notices.values.filter { $0.taskId == interleaved }.count == 1,
                     "Local finalization and status reconciliation must share one terminal event")
        let parentAwait = await spawn("父会话回复尚未结束")
        let answersBeforeParentAwait = publicAnswers.count
        parentRunner.holdNextResume = true
        childRunner.complete(parentAwait, text: "子任务已经完成")
        await waitUntil { parentRunner.resumeGate != nil }
        let persistedWhileDelivering = await executor.status(taskId: parentAwait)
        precondition(persistedWhileDelivering.state == .done && store.notices.values.filter { $0.taskId == parentAwait }.count == 1,
                     "Terminal child status remains truthful while its sole publisher awaits the parent's delivery turn")
        parentRunner.resumeGate?.resume(); parentRunner.resumeGate = nil
        await waitUntil { publicAnswers.count == answersBeforeParentAwait + 1 }

        // Two recovered-status snapshots both see running. One publisher is
        // held after hasDelivered=false, reproducing the OR REPLACE race if
        // the second is allowed to post the same ID concurrently.
        let recovered = UUID().uuidString
        store.sessions[recovered] = ChatSession(id: recovered, agentId: agent, parentSessionId: parent, lastMessage: "恢复任务结果")
        let answersBeforeRecovery = publicAnswers.count
        store.holdNextSessionRead = recovered
        let earlierStatus = Task { await executor.status(taskId: recovered) }
        await waitUntil { store.sessionReadGate != nil }
        store.holdNextDeliveredCheck = recovered
        let laterStatus = Task { await executor.status(taskId: recovered) }
        await waitUntil { store.deliveredCheckGate != nil }
        store.sessionReadGate?.resume(); store.sessionReadGate = nil
        _ = await earlierStatus.value
        store.deliveredCheckGate?.resume(); store.deliveredCheckGate = nil
        _ = await laterStatus.value
        await waitUntil { publicAnswers.count == answersBeforeRecovery + 1 }
        precondition(store.saves.filter { $0.key.contains(recovered) }.values.reduce(0, +) == 1
                     && store.notices.values.filter { $0.taskId == recovered }.count == 1,
                     "Same-generation terminal publication must be claimed before awaits, not merely share an ID")

        // A correction wins while the old finalizer is suspended reading its
        // session. Old persistence, notice and cleanup must not touch new work.
        let replaced = await spawn("被修正的任务")
        store.holdNextSessionRead = replaced
        childRunner.complete(replaced, text: "旧结果不可覆盖")
        await waitUntil { store.sessionReadGate != nil }
        let runCount = childRunner.runs.count
        try await executor.message(taskId: replaced, text: "按修正要求执行")
        await waitUntil { childRunner.runs.count == runCount + 1 && childRunner.waits[replaced] != nil }
        store.sessionReadGate?.resume(); store.sessionReadGate = nil
        for _ in 0..<20 { await Task.yield() }
        precondition(store.sessions[replaced]?.spawnStatus == "running" && childRunner.live.contains(replaced)
                     && !store.notices.values.contains { $0.taskId == replaced },
                     "A superseded finalizer cannot overwrite or announce the replacement run")
        childRunner.complete(replaced, text: "修正后的真实结果")
        await waitUntil { store.notices.values.contains { $0.taskId == replaced } }
        precondition(store.notices.values.filter { $0.taskId == replaced }.map(\.result) == ["修正后的真实结果"])

        // The timeout classifier can also suspend. Its stale stillRunning
        // result must never cancel the replacement generation.
        let timeoutRace = await spawn("超时分类与修正交错")
        childRunner.holdNextStatus = timeoutRace
        childRunner.timeout(timeoutRace)
        await waitUntil { childRunner.statusGate != nil }
        let timeoutRuns = childRunner.runs.count
        try await executor.message(taskId: timeoutRace, text: "新的一轮")
        await waitUntil { childRunner.runs.count == timeoutRuns + 1 && childRunner.waits[timeoutRace] != nil }
        let cancellationsAfterMessage = childRunner.cancellations
        childRunner.statusGate?.resume(); childRunner.statusGate = nil
        for _ in 0..<20 { await Task.yield() }
        precondition(childRunner.cancellations == cancellationsAfterMessage && childRunner.live.contains(timeoutRace)
                     && store.sessions[timeoutRace]?.spawnStatus == "running",
                     "An old classifier cannot stop or fail a newer generation")
        childRunner.complete(timeoutRace, text: "新一轮完成")
        await waitUntil { store.notices.values.contains { $0.taskId == timeoutRace } }
        precondition(store.notices.values.filter { $0.taskId == timeoutRace }.map(\.status) == ["done"])
        print("PASS: actual spawn/executor persist child ownership, return immediately, enqueue terminal subagent notice, reserve the configured host, wake the original parent once via answer_user, defer closed delivery and preserve stop semantics")
        print("PASS: deterministic finalizer/status, same-ID store, replacement-run and timeout-classifier races publish once and never overwrite or cancel newer work")
    }
}
