import Combine
import Foundation

@MainActor final class IOSAgentSessionRunner {}
enum AgentRole { case main, executor }
enum AgentRunRole: String { case main, executor }
enum AgentToolPolicy: String { case standalone }
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
        let deadline = Date().addingTimeInterval(max(seconds, 1))
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
    enum SendBehavior { case direct, queuedCompaction, stalledCompaction, rejected }
    @Published var isProcessing = false
    var isCompacting = false
    var compactTask: Task<Void, Never>?
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
    var behavior = SendBehavior.direct
    var cancelled = 0
    var sent = 0
    var executed = 0
    var loaded = 0
    var answer: String?
    func loadSession() async { loaded += 1 }
    func cancel() { cancelled += 1; isProcessing = false }
    func send() {
        sent += 1
        switch behavior {
        case .rejected: return
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
        Task { [weak self] in
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
        func request(_ source: String = "meeting_assistant", timeout: TimeInterval = 1) -> AgentSessionRunRequest {
            .init(sessionId: "recording-session", prompt: "查日程", source: source,
                  systemPromptBlock: "new-meeting-rules", timeoutSeconds: timeout)
        }
        for busyCase in 0..<6 {
            let vm = AIChatViewModel()
            cache.vm = vm
            switch busyCase {
            case 0: vm.isProcessing = true
            case 1: vm.isCompacting = true
            case 2: SessionActivityTracker.shared.active = true
            case 3: vm.compactTask = Task {}
            case 4: vm.postCompactDrainPending = true
            default: vm.promptQueue = [QueuedPrompt()]
            }
            let result = await runner.run(request())
            precondition(!result.accepted && vm.sent == 0 && vm.cancelled == 0)
            precondition(vm.groupId == "existing-group" && vm.agentId == "existing-agent"
                         && vm.sessionSource == "existing-source" && vm.groupPromptBlock == "existing-system-rules",
                         "Busy rejection must precede session and prompt mutation")
            SessionActivityTracker.shared.active = false
        }

        for behavior in [AIChatViewModel.SendBehavior.direct, .queuedCompaction] {
            let vm = AIChatViewModel()
            vm.behavior = behavior
            cache.vm = vm
            let result = await runner.run(request())
            precondition(result.accepted && !result.timedOut && result.text == "工具结果")
            precondition(vm.sent == 1 && vm.executed == 1 && vm.cancelled == 0)
            precondition(vm.inputText == "existing unsent draft" && vm.promptQueue.isEmpty)
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
        print("PASS: production runner preserves busy meeting tasks, accepts queued compaction once, removes rejected queued commands, and preserves non-meeting behavior")
    }
}
