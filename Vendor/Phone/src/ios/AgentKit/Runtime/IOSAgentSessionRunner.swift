import Combine
import Foundation

/// Temporary iOS adapter around the existing ViewModel-hosted engine. All
/// AgentKit callers target `AgentSessionRunning`; extraction of AgentRunEngine
/// can therefore replace this adapter without changing group business rules.
@MainActor
final class IOSAgentSessionRunner: AgentSessionRunning {
    static let shared = IOSAgentSessionRunner()
    var meetingNoticeSystemPrompt: (@MainActor (String) -> String?)?

    private init() {}

    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        let vm = ViewModelCache.shared.createDraft()
        vm.sessionSource = request.source
        vm.agentId = request.agentId
        vm.groupId = request.groupId
        vm.isGroupTranscript = request.role == GroupSessionRole.group
        vm.agentRole = request.role == "subagent" ? .executor : .main
        if let rawPolicy = request.toolPolicy, let policy = AgentToolPolicy(rawValue: rawPolicy) {
            vm.resolvedToolPolicy = policy
        }

        let sessionId = await vm.ensureSessionReturningId()
        guard !sessionId.isEmpty else { return nil }
        if request.role == GroupSessionRole.group {
            await ChatStore.shared.linkGroupSession(sessionId, title: request.title ?? request.spawnTitle ?? "")
        } else if let agentId = request.agentId {
            await ChatStore.shared.linkSession(
                sessionId,
                agentId: agentId,
                role: request.role,
                parentSessionId: request.parentSessionId,
                spawnTitle: request.spawnTitle
            )
        }

        if let inheritedSessionId = request.inheritModelFromSessionId,
           let binding = ProviderConfigStore.shared.binding(for: inheritedSessionId) {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sessionId, primarySource: binding.primarySource),
                for: sessionId
            )
        } else if let entryId = request.defaultModelEntryId,
                  ProviderConfigStore.shared.entry(for: entryId) != nil {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: sessionId, primarySource: .directEntry(modelEntryId: entryId)),
                for: sessionId
            )
        }

        if !request.groupMemberIds.isEmpty {
            var members: [GroupMember] = []
            for (slot, agentId) in request.groupMemberIds.enumerated() {
                guard let profile = await AgentStore.shared.loadAgent(agentId), !profile.isArchived else { continue }
                members.append(GroupMember(
                    id: profile.id,
                    name: profile.name,
                    title: profile.title,
                    emoji: profile.emoji,
                    accentColor: profile.accentColor,
                    summary: profile.summary,
                    slot: slot
                ))
            }
            vm.groupMembers = members
        }
        ViewModelCache.shared.cacheDraft(vm, sessionId: sessionId)
        return sessionId
    }

    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: request.sessionId)
        if isFresh { await vm.loadSession() }
        let isMeeting = request.source == "meeting_assistant"
        // A recording reuses one session. A new command must never cancel or
        // change the prompt of a task that is still running in that session.
        if isMeeting && (vm.isProcessing || vm.isCompacting || vm.compactTask != nil
            || vm.postCompactDrainPending || !vm.promptQueue.isEmpty
            || SessionActivityTracker.shared.isActive(request.sessionId)) {
            return .rejected
        }
        vm.groupId = request.groupId
        vm.agentId = request.agentId
        vm.agentRole = request.role == AgentRunRole.executor.rawValue ? .executor : .main
        vm.sessionSource = request.source
        vm.groupPromptBlock = request.systemPromptBlock
        if let rawPolicy = request.toolPolicy, let policy = AgentToolPolicy(rawValue: rawPolicy) {
            vm.resolvedToolPolicy = policy
        }

        if let rawThinking = request.thinkingLevel, let level = ThinkingLevel(rawValue: rawThinking) {
            var inference = ProviderConfigStore.shared.inferenceConfig(for: request.sessionId) ?? SessionInferenceConfig()
            if inference.thinkingLevel != level {
                inference.thinkingLevel = level
                ProviderConfigStore.shared.setInferenceConfig(inference, for: request.sessionId)
            }
        }

        if vm.isProcessing {
            vm.cancel()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let countBefore = vm.messages.count
        let draft = vm.inputText
        let queuedBefore = Set(vm.promptQueue.map(\.id))
        var accepted = false
        // Compaction also publishes isProcessing; only the later command
        // drain (or a direct send) confirms acceptance of this request.
        let acceptance: AnyCancellable? = isMeeting ? vm.$isProcessing.sink { processing in
            if processing && !vm.isCompacting { accepted = true }
        } : nil
        defer { acceptance?.cancel() }
        AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
        vm.inputText = request.prompt
        vm.send()
        if !isMeeting { accepted = vm.isProcessing }
        vm.inputText = draft
        if isMeeting && !accepted {
            let queuedIDs = Set(vm.promptQueue.map(\.id)).subtracting(queuedBefore)
            let deadline = Date().addingTimeInterval(request.timeoutSeconds > 0 ? request.timeoutSeconds : 120)
            while !accepted, !queuedIDs.isEmpty, Date() < deadline, !Task.isCancelled {
                guard vm.promptQueue.contains(where: { queuedIDs.contains($0.id) })
                    || vm.isCompacting || vm.compactTask != nil || vm.postCompactDrainPending else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            if !accepted && !queuedIDs.isEmpty {
                // Remove our queued operation before cancelling compaction;
                // its delayed completion must not execute a rejected request.
                vm.promptQueue.removeAll { queuedIDs.contains($0.id) }
                vm.messages.removeAll { $0.queuedPromptId.map(queuedIDs.contains) == true }
                vm.compactTask?.cancel()
            }
        }
        guard accepted else {
            AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
            return .rejected
        }
        guard await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: request.timeoutSeconds) else {
            AgentDirectoryCoordinator.shared.discardPendingGroupMessage(callerSessionId: request.sessionId)
            return AgentSessionRunResult(text: nil, accepted: true, timedOut: true, cancelled: false)
        }
        let text = AgentDirectoryCoordinator.shared.consumePendingGroupMessage(callerSessionId: request.sessionId)
            ?? AgentTurnAwaiter.lastAssistantText(vm: vm, after: countBefore)
        return AgentSessionRunResult(text: text, accepted: true, timedOut: false, cancelled: false)
    }

    func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult {
        let (vm, isFresh) = ViewModelCache.shared.getOrCreate(for: sessionId)
        guard !vm.isProcessing, !vm.isCompacting, vm.compactTask == nil,
              !vm.postCompactDrainPending, vm.promptQueue.isEmpty,
              vm.sessionSource != "meeting_assistant" || !vm.canResume,
              !SessionActivityTracker.shared.isActive(sessionId) else { return .rejected }
        if isFresh {
            await vm.loadSession()
        } else {
            await vm.reloadMessagesFromDB(reason: "asyncToolResults")
        }
        guard !vm.isProcessing, !vm.isCompacting, vm.compactTask == nil,
              !vm.postCompactDrainPending, vm.promptQueue.isEmpty,
              !SessionActivityTracker.shared.isActive(sessionId) else { return .rejected }
        if vm.sessionSource == "meeting_assistant" {
            // Loading the synthetic tool-result tail itself sets canResume.
            // Resume only once that notice really reached model history.
            guard let tail = vm.agentHistory.last, tail.role == .user, !tail.parts.isEmpty,
                  tail.parts.allSatisfy({ part in
                      if case .toolResult(let id, let name, _, _, _, _, _, _) = part {
                          return id.hasPrefix(ChatPersistenceSchema.asyncTaskNoticeToolUseIdPrefix)
                              && name == ChatPersistenceSchema.asyncTaskNoticeToolName
                      }
                      return false
                  }) else { return .rejected }
            if vm.canResume, let candidate = vm.messages.last(where: { $0.role == .assistant }),
               candidate.blocks.count > vm.committedBlockCount { return .rejected }
            guard let prompt = meetingNoticeSystemPrompt?(sessionId) else { return .rejected }
            vm.agentRole = .main
            vm.resolvedToolPolicy = .orchestrator
            vm.groupPromptBlock = prompt
        }
        let countBefore = vm.messages.count
        let accepted = await vm.resumeNoticeDrivenLoop()
        guard accepted else { return .rejected }
        guard await AgentTurnAwaiter.awaitTurn(vm: vm, seconds: 120) else {
            return AgentSessionRunResult(text: nil, accepted: true, timedOut: true, cancelled: false)
        }
        let text = AgentTurnAwaiter.lastAssistantText(vm: vm, after: countBefore)
        return AgentSessionRunResult(text: text, accepted: true, timedOut: false, cancelled: false)
    }

    func cancel(sessionId: String) {
        ViewModelCache.shared.get(for: sessionId)?.cancel()
    }

    func status(sessionId: String) async -> AgentSessionStatus {
        let vm = ViewModelCache.shared.get(for: sessionId)
        let iteration = SessionActivityTracker.shared.sessionToolInfo[sessionId]?.loopIteration ?? 0
        let lastAssistant = vm?.messages.last(where: { $0.role == .assistant })
        let toolBlock = lastAssistant?.blocks.last { block in
            switch block.kind {
            case .text, .thinking, .info: return false
            default: return true
            }
        }
        let activity = toolBlock.map { $0.toolSummary ?? $0.toolDescription } ?? ""
        let liveText = lastAssistant?.blocks
            .filter { $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persisted = await ChatStore.shared.getSession(sessionId)?.lastMessage
        return AgentSessionStatus(
            isRunning: vm?.isProcessing == true || SessionActivityTracker.shared.isActive(sessionId),
            lastAssistantText: liveText?.isEmpty == false ? liveText : persisted,
            currentActivity: activity,
            iteration: iteration
        )
    }

    func isRunning(sessionId: String) async -> Bool {
        await status(sessionId: sessionId).isRunning
    }
}
