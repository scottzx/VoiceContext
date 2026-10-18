//
//  AsyncTaskNoticeManager.swift
//  Minis
//
//  Central asynchronous task notice bus.
//  Coordinates background task completion notices (shell commands, subagents,
//  and direct A2A), manages pending queues in SQLite, injects paired
//  synthetic tool_use / tool_result messages, and reactively revives the agent loop.
//

import Foundation

private let logger = AppLogger(category: "AsyncTaskNotice")

@MainActor
public final class AsyncTaskNoticeManager {

    public static let shared = AsyncTaskNoticeManager()

    public var sessionRunner: any AgentSessionRunning = IOSAgentSessionRunner.shared
    public struct ReplyHooks {
        public let prepare: @MainActor (String) async -> Bool
        public let finish: @MainActor (String, AgentSessionRunResult) async -> Void

        public init(prepare: @escaping @MainActor (String) async -> Bool,
                    finish: @escaping @MainActor (String, AgentSessionRunResult) async -> Void) {
            self.prepare = prepare
            self.finish = finish
        }
    }
    public var replyHooks: [String: ReplyHooks] = [:]
    /// Host-owned terminal state events are saved in conversation history
    /// without requesting a new model turn or a public/voice reply.
    public var historyOnlyTaskTypes: Set<String> = []

    private var loopEndObserver: NSObjectProtocol?
    private var isDraining: Set<String> = []

    public init() {
        setupLoopEndObserver()
    }

    deinit {
        if let observer = loopEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupLoopEndObserver() {
        loopEndObserver = NotificationCenter.default.addObserver(
            forName: .sessionAgentLoopDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let sid = (notification.object as? String)
            Task { @MainActor in
                if let sid {
                    await self.checkAndDrain(sessionId: sid)
                } else if let activeSid = AIChatViewModel.activeSessionId {
                    await self.checkAndDrain(sessionId: activeSid)
                }
            }
        }
    }

    /// Resume notices which were persisted before a process interruption but
    /// were not yet injected into their source sessions.
    public func recoverPendingNotices() async {
        let sessionIds = await ChatStore.shared.sessionsWithPendingAsyncTaskNotices()
        for sessionId in sessionIds {
            await checkAndDrain(sessionId: sessionId)
        }
    }

    /// Post a completion notice for a background task.
    /// Saves to SQLite queue and attempts to drain immediately if the target session is idle.
    @discardableResult
    public func postNotice(
        sourceSessionId: String,
        taskType: String,
        taskId: String,
        agentId: String? = nil,
        title: String? = nil,
        status: String = "done",
        result: String,
        filesPath: String? = nil,
        noticeId: String? = nil
    ) async -> String {
        let nid = noticeId ?? "async:\(taskType):\(taskId)"

        guard await !ChatStore.shared.hasDeliveredNotice(id: nid) else {
            logger.info("[Notice] Notice \(nid) already delivered, skipping duplicate post.")
            return nid
        }

        let notice = AsyncTaskNotice(
            id: nid,
            sourceSessionId: sourceSessionId,
            taskType: taskType,
            taskId: taskId,
            agentId: agentId,
            title: title,
            status: status,
            result: result,
            filesPath: filesPath,
            createdAt: Date(),
            isDelivered: false
        )

        await ChatStore.shared.saveAsyncTaskNotice(notice)
        logger.info("[Notice] Saved pending notice \(nid) (type=\(taskType), taskId=\(taskId)) for session \(sourceSessionId)")

        // Trigger drain if session is available
        await checkAndDrain(sessionId: sourceSessionId)
        return nid
    }

    /// Check if the given session is idle and has pending notices, and inject them atomically.
    public func checkAndDrain(sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        guard isDraining.insert(sessionId).inserted else { return }
        defer { isDraining.remove(sessionId) }
        func isBusy() -> Bool {
            if SessionActivityTracker.shared.isActive(sessionId) { return true }
            guard let vm = ViewModelCache.shared.get(for: sessionId) else { return false }
            return vm.isProcessing || vm.isCompacting || vm.compactTask != nil
                || vm.isTruncatingForRetry || vm.postCompactDrainPending || !vm.promptQueue.isEmpty
        }

        // If the session is currently active or processing, do not inject — wait for loop end
        if SessionActivityTracker.shared.isActive(sessionId) {
            logger.debug("[Notice] Session \(sessionId) is currently active, deferring notice drain.")
            return
        }

        if let vm = ViewModelCache.shared.get(for: sessionId) {
            if vm.isProcessing || vm.isCompacting || vm.compactTask != nil || vm.postCompactDrainPending {
                logger.debug("[Notice] VM for \(sessionId) isProcessing, deferring notice drain.")
                return
            }
            // User queued message has higher priority
            if !vm.promptQueue.isEmpty {
                logger.debug("[Notice] Session \(sessionId) has a queued user message, yielding priority to user.")
                return
            }
        }

        var pending = await ChatStore.shared.pendingAsyncTaskNotices(for: sessionId)
        guard !pending.isEmpty else { return }
        let source = await ChatStore.shared.getSession(sessionId)?.source
        guard !isBusy() else { return }
        let historyOnly = pending.filter { historyOnlyTaskTypes.contains($0.taskType) }
        let isHistoryOnly = !historyOnly.isEmpty
        // State events must reach history even when the voice adapter is
        // paused or unavailable. Other notices retain their reply binding.
        if isHistoryOnly { pending = historyOnly }
        let requiresReply = !isHistoryOnly && AgentRuntimePolicies.policy(for: source).requiresNoticeReplyBinding
        let hooks = source.flatMap { replyHooks[$0] }
        if requiresReply {
            // Reserve host delivery before results enter session history.
            // Unregistered or unavailable adapters leave notices pending.
            guard let hooks, await hooks.prepare(sessionId) else { return }
            guard !isBusy() else {
                await hooks.finish(sessionId, .rejected)
                return
            }
        }

        logger.info("[Notice] Draining \(pending.count) pending notice(s) for session \(sessionId)")

        var messages: [RawMessage] = []
        var history: [AgentMessage] = []
        let now = Date()

        for (index, notice) in pending.enumerated() {
            let toolUseId = ChatPersistenceSchema.asyncTaskNoticeToolUseIdPrefix + notice.id

            var inputDict: [String: Any] = [
                "notice_id": notice.id,
                "task_type": notice.taskType,
                "task_id": notice.taskId,
                "status": notice.status
            ]
            if let agentId = notice.agentId, !agentId.isEmpty { inputDict["agent_id"] = agentId }
            if let title = notice.title, !title.isEmpty { inputDict["title"] = title }
            if let filesPath = notice.filesPath, !filesPath.isEmpty { inputDict["files_path"] = filesPath }

            let inputJSON = (try? JSONSerialization.data(withJSONObject: inputDict))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let toolUse = ContentPart.toolUse(ToolUse(
                toolUseId: toolUseId,
                name: ChatPersistenceSchema.asyncTaskNoticeToolName,
                input: inputJSON,
                description: notice.title ?? "\(notice.taskType) completed"
            ))

            let outputText = formatNoticeResultOutput(notice)
            let toolResult = ContentPart.toolResult(ToolResult(
                toolUseId: toolUseId,
                output: outputText,
                success: notice.status == "done" || notice.status == "escalate",
                status: notice.status
            ))
            let offset = Double(index) * (isHistoryOnly ? 0.003 : 0.002)
            messages.append(RawMessage(
                id: "async-notice-use:\(notice.id)",
                sessionId: sessionId,
                role: .assistant,
                parts: [toolUse],
                createdAt: now.addingTimeInterval(offset)
            ))
            messages.append(RawMessage(
                id: "async-notice-result:\(notice.id)",
                sessionId: sessionId,
                role: .user,
                parts: [toolResult],
                createdAt: now.addingTimeInterval(offset + 0.001)
            ))
            if isHistoryOnly {
                // Close the synthetic tool pair with a truthful receipt.
                // A bare tool-result tail would look like an interrupted
                // agent turn after a cold load and incorrectly offer Resume.
                let receipt = "儿童故事机：《\(notice.title ?? "故事")》已播放完成。"
                messages.append(RawMessage(
                    id: "async-notice-receipt:\(notice.id)", sessionId: sessionId,
                    role: .assistant, parts: [.text(receipt)],
                    createdAt: now.addingTimeInterval(offset + 0.002)
                ))
                history.append(AgentMessage(role: .assistant, parts: [.toolUse(
                    id: toolUseId, name: ChatPersistenceSchema.asyncTaskNoticeToolName, input: inputDict
                )], dbMessageId: "async-notice-use:\(notice.id)"))
                history.append(AgentMessage(role: .user, parts: [.toolResult(
                    id: toolUseId, name: ChatPersistenceSchema.asyncTaskNoticeToolName,
                    content: outputText, isError: false
                )], dbMessageId: "async-notice-result:\(notice.id)"))
                history.append(AgentMessage(role: .assistant, parts: [.text(receipt)],
                                            dbMessageId: "async-notice-receipt:\(notice.id)"))
            }
        }

        guard await ChatStore.shared.injectAsyncTaskNoticeMessages(
            messages,
            noticeIds: pending.map(\.id)
        ) else {
            logger.error("[Notice] Failed to atomically inject notices for session \(sessionId); leaving them pending.")
            if requiresReply { await hooks?.finish(sessionId, .rejected) }
            return
        }

        if isHistoryOnly {
            guard !isBusy() else {
                await ChatStore.shared.markAsyncTaskNoticesPending(ids: pending.map(\.id))
                // Loop end can race this write while isDraining still owns
                // the session. Retry once after releasing that reservation.
                Task { await self.checkAndDrain(sessionId: sessionId) }
                return
            }
            if let vm = ViewModelCache.shared.get(for: sessionId) {
                // Append only the notice history and its text receipt instead
                // of loadSession(), which changes the active page/session and
                // can overwrite interrupted UI state.
                let knownIds = Set(vm.agentHistory.compactMap(\.dbMessageId))
                vm.agentHistory.append(contentsOf: history.filter { message in
                    message.dbMessageId.map { !knownIds.contains($0) } ?? false
                })
                for notice in pending where !knownIds.contains("async-notice-receipt:\(notice.id)") {
                    let receipt = "儿童故事机：《\(notice.title ?? "故事")》已播放完成。"
                    vm.messages.append(ChatMessage(role: .assistant, content: receipt,
                                                   blocks: [AssistantBlock(kind: .text, content: receipt)]))
                }
            }
            Task { await self.checkAndDrain(sessionId: sessionId) }
            return
        }

        logger.info("[Notice] Atomically injected \(pending.count) notice pair(s) into session \(sessionId), resuming agent loop...")

        // Revive the agent loop
        let result = await sessionRunner.resumeAfterAsyncToolResults(sessionId: sessionId)
        if requiresReply { await hooks?.finish(sessionId, result) }
        if !result.accepted {
            // A user turn may have won the race after the idle check. Keep the
            // notice claim pending; deterministic message ids make the retry
            // an idempotent reload-and-resume rather than a duplicate insert.
            await ChatStore.shared.markAsyncTaskNoticesPending(ids: pending.map(\.id))
            return
        }

        // Notices may have arrived while this notice-driven turn was active.
        // Its loop-end notification fires before awaitTurn returns, while the
        // session is still in isDraining, so explicitly perform one tail drain.
        Task { await self.checkAndDrain(sessionId: sessionId) }
    }

    private func formatNoticeResultOutput(_ notice: AsyncTaskNotice) -> String {
        switch notice.taskType {
        case "story_playback":
            return """
            [Story Playback Finished]
            \(notice.result)

            The native audio player confirmed natural completion. This is a terminal playback state, not a new user request. Do not replay, switch stories, dispatch tasks, navigate, or speak automatically. Use this verified state when answering the next user request.
            """

        case "subagent":
            var lines: [String] = [
                "[Background Subagent Finished]",
                "task_id: \(notice.taskId)",
                "title: \(notice.title ?? "")",
                "status: \(notice.status)"
            ]
            if let files = notice.filesPath, !files.isEmpty {
                lines.append("files: \(files)")
            }
            lines.append("")
            lines.append("Result:")
            lines.append(notice.result)
            lines.append("")
            lines.append("This background subagent has finished. Review the result above. If you need to update the user with new information, answer them in your own voice. If no user update is required, respond with (pass).")
            return lines.joined(separator: "\n")

        case "subagent_cloud":
            if notice.status == "escalate" {
                let lines: [String] = [
                    "[Cloud Subagent Intercepted - Awaiting Approval]",
                    "task_id: \(notice.taskId)",
                    "title: \(notice.title ?? "")",
                    "status: waiting_approval",
                    "",
                    "Decision / Reason:",
                    notice.result,
                    "",
                    "The cloud subagent encountered a high-risk policy boundary and escalated this task for founder approval.",
                    "An interactive approval banner has been presented right above the user's input box. Notify the user that this task has hit a policy check and is waiting for their approval in the input area."
                ]
                return lines.joined(separator: "\n")
            } else if notice.status == "failed" {
                let lines: [String] = [
                    "[Cloud Subagent Infrastructure Failure]",
                    "task_id: \(notice.taskId)",
                    "title: \(notice.title ?? "")",
                    "status: failed",
                    "",
                    "Error Details:",
                    notice.result,
                    "",
                    "Infrastructure error notice: The remote cloud gateway was unreachable or returned a gateway error. Directly inform the user about this infrastructure failure. Do NOT state that the request was intercepted by policy or risk controls."
                ]
                return lines.joined(separator: "\n")
            } else {
                var lines: [String] = [
                    "[Cloud Subagent Finished]",
                    "task_id: \(notice.taskId)",
                    "title: \(notice.title ?? "")",
                    "status: \(notice.status)"
                ]
                if let files = notice.filesPath, !files.isEmpty {
                    lines.append("files: \(files)")
                }
                lines.append("")
                lines.append("Result:")
                lines.append(notice.result)
                lines.append("")
                lines.append("The remote Amazon Bedrock AgentCore cloud subagent has finished. Review the result above. Deliver the answer to the user in your own voice.")
                return lines.joined(separator: "\n")
            }

        case "shell", "command":
            let lines: [String] = [
                "[Background Command Finished]",
                "task_id: \(notice.taskId)",
                "command: \(notice.title ?? "")",
                "status: \(notice.status)",
                "",
                "Output:",
                notice.result,
                "",
                "This background command has finished. Review the output above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass)."
            ]
            return lines.joined(separator: "\n")

        case "a2a":
            let lines: [String] = [
                "[Colleague Assistant Replied]",
                "task_id: \(notice.taskId)",
                "agent_id: \(notice.agentId ?? "")",
                "sender: \(notice.title ?? "")",
                "status: \(notice.status)",
                "",
                "Reply:",
                notice.result,
                "",
                "The colleague assistant has finished replying. Review the reply above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass)."
            ]
            return lines.joined(separator: "\n")

        default:
            return """
            [Background Task Finished]
            task_type: \(notice.taskType)
            task_id: \(notice.taskId)
            status: \(notice.status)

            Result:
            \(notice.result)

            Review the result above. If you need to update the user, answer them in your own voice. If no user update is required, respond with (pass).
            """
        }
    }
}
