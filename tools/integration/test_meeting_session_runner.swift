import Combine
import Foundation

@MainActor final class IOSAgentSessionRunner {}
@MainActor final class AppNavigationCenter {
    static let shared = AppNavigationCenter()
    func voiceGeneration(sessionID: String) -> UInt64? { 42 }
}
enum AgentRole { case main, executor }
enum AgentRunRole: String { case main, executor }
enum AgentToolPolicy: String { case standalone, orchestrator }
enum ThinkingLevel: String { case low }
struct SessionInferenceConfig { var thinkingLevel: ThinkingLevel = .low }
struct QueuedPrompt { let id = UUID() }
struct HostMessage { let queuedPromptId: UUID? }

@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func inferenceConfig(for id: String) -> SessionInferenceConfig? { nil }
    func setInferenceConfig(_ config: SessionInferenceConfig, for id: String) {}
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var active = false
    func isActive(_ id: String) -> Bool { active }
}
@MainActor final class AgentDirectoryCoordinator {
    static let shared = AgentDirectoryCoordinator()
    var discarded = 0
    func discardPendingGroupMessage(callerSessionId: String) { discarded += 1 }
    func consumePendingGroupMessage(callerSessionId: String) -> String? { nil }
}
@MainActor enum AgentTurnAwaiter {
    static func awaitTurn(vm: AIChatViewModel, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds > 0 ? seconds : 120)
        while vm.isProcessing && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return !vm.isProcessing
    }
    static func lastAssistantText(vm: AIChatViewModel, after: Int) -> String? { vm.answer }
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var vm = AIChatViewModel()
    var fresh = false
    func getOrCreate(for id: String) -> (AIChatViewModel, Bool) { (vm, fresh) }
}
@MainActor final class AIChatViewModel {
    enum SendBehavior { case direct, queuedCompaction, stalledCompaction, rejected, held }
    @Published var isProcessing = false
    var isCompacting = false
    var isTruncatingForRetry = false
    var currentTask: Task<Void, Never>?
    var compactTask: Task<Void, Never>?
    var appNavigationVoiceGeneration: UInt64?
    var executionGate: CheckedContinuation<Void, Never>?
    var postCompactDrainPending = false
    var promptQueue: [QueuedPrompt] = []
    var messages: [HostMessage] = []
    var groupId: String? = "existing-group"
    var agentId: String? = "existing-agent"
    var agentRole: AgentRole = .executor
    var sessionSource: String? = "existing-source"
    var groupPromptBlock: String? = "existing-system-rules"
    var resolvedToolPolicy: AgentToolPolicy = .standalone
    var inputText = "existing unsent draft"
    var attachments = ["manual-draft-file"]
    var sentAttachments: [[String]] = []
    var behavior = SendBehavior.direct
    var cancelled = 0
    var userDidCancel = false
    var sent = 0
    var executed = 0
    var loaded = 0
    var answer: String?
    func loadSession() async { loaded += 1 }
    func cancel() { cancelled += 1; userDidCancel = true; currentTask?.cancel(); currentTask = nil; isProcessing = false }
    func send() {
        sent += 1
        sentAttachments.append(attachments)
        attachments = []
        userDidCancel = false
        switch behavior {
        case .rejected: return
        case .held:
            isProcessing = true
            currentTask = Task { [weak self] in
                guard let self else { return }
                await withCheckedContinuation { self.executionGate = $0 }
                self.answer = "actual completed result"
                self.isProcessing = false
            }
        case .direct:
            isProcessing = true
            executeSoon()
        case .queuedCompaction, .stalledCompaction:
            let queued = QueuedPrompt()
            promptQueue.append(queued)
            messages.append(.init(queuedPromptId: queued.id))
            let stalled = behavior == .stalledCompaction
            compactTask = Task { [weak self] in
                guard let self else { return }
                self.isCompacting = true
                self.isProcessing = true
                do { try await Task.sleep(for: .milliseconds(stalled ? 150 : 20)) }
                catch { self.isCompacting = false; self.isProcessing = false; self.compactTask = nil; return }
                self.isCompacting = false
                self.isProcessing = false
                self.compactTask = nil
                guard self.promptQueue.contains(where: { $0.id == queued.id }) else { return }
                self.isProcessing = true
                self.promptQueue.removeAll { $0.id == queued.id }
                self.executeSoon()
            }
        }
    }
    private func executeSoon() {
        executed += 1
        currentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            self?.answer = "工具结果"
            self?.isProcessing = false
        }
    }
}

@main struct MeetingSessionRunnerChecks {
    @MainActor static func main() async {
        let runner = IOSAgentSessionRunner()
        let cache = ViewModelCache.shared
        let configuredSources = ["meeting_assistant", "xiaolan_voice", "arbitrary_adapter"]
        for source in configuredSources {
            AgentRuntimePolicies.register(source: source, policy: .init(
                requiresIdle: true, requiresNoticeReplyBinding: true, requiresNavigationBinding: source != "meeting_assistant"))
        }
        func request(_ source: String = "meeting_assistant", timeout: TimeInterval = 1, owner: String? = "configured-owner") -> AgentSessionRunRequest {
            .init(sessionId: "configured-session", prompt: "查日程", agentId: owner, source: source,
                  systemPromptBlock: "adapter rules", toolPolicy: "orchestrator", timeoutSeconds: timeout)
        }
        for source in configuredSources {
        for busyCase in 0..<7 {
            let vm = AIChatViewModel()
            cache.vm = vm
            switch busyCase {
            case 0: vm.isProcessing = true
            case 1: vm.isCompacting = true
            case 2: SessionActivityTracker.shared.active = true
            case 3: vm.compactTask = Task {}
            case 4: vm.postCompactDrainPending = true
            case 6: vm.isTruncatingForRetry = true
            default: vm.promptQueue = [QueuedPrompt()]
            }
            let result = await runner.run(request(source))
            precondition(!result.accepted && vm.sent == 0 && vm.cancelled == 0)
            precondition(vm.groupId == "existing-group" && vm.agentId == "existing-agent"
                         && vm.sessionSource == "existing-source" && vm.groupPromptBlock == "existing-system-rules",
                         "Busy rejection must precede session and prompt mutation")
            SessionActivityTracker.shared.active = false
        }
        }

        for source in configuredSources {
        for behavior in [AIChatViewModel.SendBehavior.direct, .queuedCompaction] {
            let vm = AIChatViewModel()
            vm.behavior = behavior
            cache.vm = vm
            let result = await runner.run(request(source))
            precondition(result.accepted && !result.timedOut && result.text == "工具结果")
            precondition(vm.sent == 1 && vm.executed == 1 && vm.cancelled == 0)
            precondition(vm.agentId == "configured-owner" && vm.resolvedToolPolicy == .orchestrator)
            precondition(vm.inputText == "existing unsent draft" && vm.promptQueue.isEmpty)
            precondition(vm.attachments == ["manual-draft-file"] && vm.sentAttachments == [[]],
                         "Programmatic prompt-only runs preserve staged composer text/files for every source")
            precondition(vm.appNavigationVoiceGeneration == (source == "meeting_assistant" ? nil : 42),
                         "Navigation generation capture follows registered policy, including an arbitrary source")
        }
        }

        let stalled = AIChatViewModel()
        stalled.behavior = .stalledCompaction
        cache.vm = stalled
        let rejected = await runner.run(request(timeout: 0.02))
        precondition(!rejected.accepted && stalled.executed == 0 && stalled.promptQueue.isEmpty)
        precondition(stalled.messages.isEmpty && stalled.inputText == "existing unsent draft")
        try? await Task.sleep(for: .milliseconds(180))
        precondition(stalled.executed == 0, "A timed out queued request must never execute later")

        let cancelled = AIChatViewModel()
        cancelled.behavior = .stalledCompaction
        cache.vm = cancelled
        let cancellationRun = Task { await runner.run(request()) }
        while cancelled.promptQueue.isEmpty { await Task.yield() }
        cancellationRun.cancel()
        let cancellationResult = await cancellationRun.value
        precondition(!cancellationResult.accepted && cancelled.promptQueue.isEmpty && cancelled.messages.isEmpty)
        try? await Task.sleep(for: .milliseconds(180))
        precondition(cancelled.executed == 0, "A cancelled queued request must never execute later")

        let legacy = AIChatViewModel()
        legacy.isProcessing = true
        cache.vm = legacy
        let legacyResult = await runner.run(request("group"))
        precondition(legacyResult.accepted && legacy.cancelled == 1 && legacy.executed == 1,
                     "Existing non-meeting cancellation behavior must remain unchanged")
        let owned = AIChatViewModel(); cache.vm = owned
        let savedOwner = owned.agentId
        let nilOwnerResult = await runner.run(request("subagent", owner: nil))
        precondition(nilOwnerResult.accepted && owned.agentId == savedOwner,
                     "A generic child run with no explicit agent keeps its persisted owner")
        let held = AIChatViewModel(); held.behavior = .held; cache.vm = held
        let timedOut = await runner.run(request("arbitrary_adapter", timeout: 0.01))
        precondition(timedOut.accepted && timedOut.timedOut && held.isProcessing,
                     "Configured adapters retain the ordinary runner timeout contract")
        held.cancel(); held.executionGate?.resume(); held.executionGate = nil
        print("PASS: registered idle/navigation policies work for both voice sources and an arbitrary third adapter; busy/queued/cancel gates, owner inheritance and ordinary timeout behavior remain intact")
    }
}
