import Foundation

extension AIChatViewModel {
    /// Rehydrate from the server after navigation or a transport interruption.
    /// Reconnecting observes the existing run; it never resends a user prompt.
    func loadDSHSession() async {
        guard let service = dshService, !isLoadingSession else { return }
        detachDSHSession()
        let generation = dshGeneration
        isLoadingSession = true
        dshStatusText = AppLocalized("正在连接 \(service.name)…")
        errorMessage = nil
        defer {
            if generation == dshGeneration {
                isLoadingSession = false
                hasCompletedInitialLoad = true
            }
        }
        do {
            guard let token = DSHServiceStore.shared.token(for: service.id, matching: service.url) else {
                throw DSHClientError.unauthorized
            }
            let client = DSHClient(baseURL: service.url, token: token)
            try await client.connect()
            guard generation == dshGeneration, !Task.isCancelled else { client.disconnect(); return }
            dshClient = client
            dshConnected = true
            dshStatusText = service.name
            if let sessionId { followDSHSession(sessionId, client: client) }
            Task { [weak self] in
                do {
                    let models = try await client.modelCatalog()
                    if let self, self.dshGeneration == generation { self.dshModels = models }
                } catch {
                    // Model configuration is optional; conversation transport is usable.
                    if let self, self.dshGeneration == generation { self.dshModels = [] }
                }
            }
        } catch {
            guard generation == dshGeneration else { return }
            dshStatusText = AppLocalized("未连接 · 检查 Tailscale 和服务地址")
            errorMessage = error.localizedDescription
        }
    }

    /// Closing the page releases the subscription, leaving the remote run intact.
    func detachDSHSession() {
        dshGeneration = UUID()
        dshFollowTask?.cancel()
        dshFollowTask = nil
        dshClient?.disconnect()
        dshClient = nil
        dshConnected = false
        isLoadingSession = false
        isProcessing = false
        dshInteractions = []
        dshControlBusy = false
    }

    func followDSHSession(_ id: String, client: DSHClient) {
        dshFollowTask?.cancel()
        let generation = dshGeneration
        dshFollowTask = Task { [weak self] in
            do {
                for try await snapshot in client.follow(sessionID: id) {
                    guard !Task.isCancelled, let self, self.dshGeneration == generation else { return }
                    self.applyDSHSnapshot(snapshot)
                }
            } catch {
                guard !Task.isCancelled, let self, self.dshGeneration == generation else { return }
                self.dshConnected = false
                self.dshStatusText = AppLocalized("连接已中断 · 可重新连接")
                self.dshInteractions = []
                self.isProcessing = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func sendDSHMessage() {
        guard let service = dshService, let client = dshClient,
              dshConnected, !isProcessing, !dshSending, !dshControlBusy else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, attachments.isEmpty else { return }
        let generation = dshGeneration
        let requestID = UUID().uuidString
        let originalInput = inputText
        dshSending = true
        isProcessing = true
        userDidCancel = false
        errorMessage = nil
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.dshSending = false }
            do {
                let id = try await self.ensureDSHSession(client: client, service: service)
                if self.dshGeneration == generation && self.dshFollowTask == nil {
                    self.followDSHSession(id, client: client)
                }
                guard !self.userDidCancel else { self.isProcessing = false; return }
                // This request is sent once. An uncertain acknowledgement is reconciled
                // by the live history stream, never by automatic prompt retry.
                try await client.send(text: text, sessionID: id, requestID: requestID)
                if self.inputText == originalInput { self.inputText = "" }
            } catch {
                guard self.dshGeneration == generation else { return }
                self.isProcessing = false
                self.errorMessage = AppLocalized("发送结果未确认，请核对会话后再发送。\n\(error.localizedDescription)")
            }
        }
    }

    func cancelDSHTurn() {
        if dshSending && sessionId == nil {
            userDidCancel = true
            isProcessing = false
            return
        }
        guard dshConnected, let client = dshClient, let sessionId, !dshControlBusy else { return }
        let generation = dshGeneration
        dshControlBusy = true
        Task { [weak self] in
            do {
                try await client.cancel(sessionID: sessionId)
                guard let self, self.dshGeneration == generation else { return }
                self.userDidCancel = true
                self.dshControlBusy = false
            } catch {
                guard let self, self.dshGeneration == generation else { return }
                self.dshControlBusy = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func loadOlderDSHMessages() {
        guard let client = dshClient, let sessionId else { return }
        Task { await performDSHControl { try await client.loadOlder(sessionID: sessionId) } }
    }

    func selectDSHModel(_ option: DSHModelOption, reasoningEffort: String? = nil) async -> Bool {
        guard let client = dshClient, let service = dshService, !isProcessing, !dshSending,
              dshAgentPreset?.hasPrefix("oneagents-acp-") != true else { return false }
        return await performDSHControl { [weak self] in
            guard let self else { return }
            let id = try await self.ensureDSHSession(client: client, service: service)
            try await client.selectModel(sessionID: id, provider: option.provider,
                                         model: option.model, reasoningEffort: reasoningEffort)
        }
    }

    func loadDSHACPConfiguration() async {
        guard let client = dshClient, let sessionId else { return }
        let generation = dshGeneration
        _ = await performDSHControl { [weak self] in
            let value = try await client.acpConfiguration(sessionID: sessionId)
            if let self, self.dshGeneration == generation { self.dshACPConfiguration = value }
        }
    }

    func setDSHACPConfiguration(configID: String, value: String) async -> Bool {
        guard let client = dshClient, let sessionId, !isProcessing else { return false }
        let generation = dshGeneration
        return await performDSHControl { [weak self] in
            var result = try await client.configureACP(sessionID: sessionId, configID: configID, value: value)
            guard let self, self.dshGeneration == generation else { return }
            if result["writable"] == nil { result["writable"] = self.dshACPConfiguration["writable"] }
            self.dshACPConfiguration = result
        }
    }

    func respondToDSHApproval(_ interaction: DSHInteraction, allow: Bool) async -> Bool {
        guard let client = dshClient,
              dshInteractions.contains(where: { $0.id == interaction.id }) else { return false }
        return await performDSHControl { try await client.respondToApproval(interactionID: interaction.id, allow: allow) }
    }

    func respondToDSHQuestions(_ interaction: DSHInteraction, answers: [DSHQuestionAnswer]) async -> Bool {
        guard let client = dshClient,
              dshInteractions.contains(where: { $0.id == interaction.id }) else { return false }
        return await performDSHControl { try await client.respondToQuestions(interactionID: interaction.id, answers: answers) }
    }

    @discardableResult
    private func performDSHControl(_ action: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard dshConnected, !dshControlBusy else { return false }
        let generation = dshGeneration
        dshControlBusy = true
        errorMessage = nil
        defer { if generation == dshGeneration { dshControlBusy = false } }
        do {
            try await action()
            return generation == dshGeneration
        } catch {
            if generation == dshGeneration { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func ensureDSHSession(client: DSHClient, service: DSHService) async throws -> String {
        if let sessionId { return sessionId }
        let id = try await client.createSession()
        sessionId = id
        ViewModelCache.shared.cacheDSHSession(self, serviceID: service.id, sessionID: id)
        if dshClient === client {
            Self.activeSessionId = ViewModelCache.dshKey(serviceID: service.id, sessionID: id)
            followDSHSession(id, client: client)
        }
        NotificationCenter.default.post(
            name: Notification.Name("Yima.dshSessionDidCreate"), object: id,
            userInfo: ["serviceID": service.id.uuidString, "draftID": draftId ?? ""]
        )
        return id
    }

    private func applyDSHSnapshot(_ snapshot: DSHChatSnapshot) {
        guard snapshot.sessionID == sessionId else { return }
        dshTitle = snapshot.title.isEmpty ? dshTitle : snapshot.title
        dshHasMore = snapshot.hasMore
        dshInteractions = snapshot.interactions
        dshAgentPreset = snapshot.agentPreset
        dshModelSelection = snapshot.modelSelection
        switch snapshot.connectionState {
        case .connecting: dshStatusText = AppLocalized("正在连接…")
        case .connected: dshStatusText = snapshot.isRunning ? AppLocalized("远程执行中") : dshService?.name ?? AppLocalized("已连接")
        case .reconnecting: dshStatusText = AppLocalized("连接中断，正在恢复…")
        case .disconnected: dshStatusText = AppLocalized("未连接 · 可重新连接")
        }
        let connected = snapshot.connectionState == .connected
        dshConnected = connected
        if !connected {
            dshInteractions = []
            isProcessing = false
            return
        }
        // Match local chat: one assistant turn owns its interleaved text and tools.
        // A user/question reply breaks the group even when the server keeps its turn ID.
        var groups: [(key: String, role: ChatMessageRole, entries: [DSHChatEntry])] = []
        var userBoundary = "window"
        var seenEntries: Set<String> = []
        for entry in snapshot.entries where seenEntries.insert(entry.id).inserted {
            if entry.role == .user {
                userBoundary = entry.id
                groups.append(("user:\(entry.id)", .user, [entry]))
            } else {
                let key = entry.turn.map { "turn:\($0):after:\(userBoundary)" } ?? "row:\(entry.id)"
                if groups.last?.key == key, groups.last?.role == .assistant {
                    groups[groups.count - 1].entries.append(entry)
                } else {
                    groups.append((key, .assistant, [entry]))
                }
            }
        }
        var next: [ChatMessage] = []
        var blocksChanged = false
        var visibleMessageKeys: Set<String> = []
        var visibleRawKeys: Set<String> = []
        var visibleBlockIDs: Set<String> = []
        var usedNativeBlockIDs: Set<UUID> = []
        var usedMessageIDs: Set<UUID> = []
        func prepareNonThinkingBlock(_ id: String) {
            // Settlement may compact part indices. Never mutate a shared
            // thinking alias into text/a tool, or reuse an already placed block.
            if let block = dshBlocks[id], block.kind == .thinking || usedNativeBlockIDs.contains(block.id) {
                dshBlocks.removeValue(forKey: id)
            }
        }
        for group in groups {
            let key = "group:" + group.key
            // Entry aliases preserve a visible turn when pagination prepends its
            // first step or user boundary, changing the group's canonical key.
            let candidates = group.entries.compactMap { dshMessages["entry:" + $0.id] } + [dshMessages[key]].compactMap { $0 }
            let message = candidates.first { !usedMessageIDs.contains($0.id) }
                ?? ChatMessage(role: group.role, content: "")
            usedMessageIDs.insert(message.id)
            dshMessages[key] = message
            visibleMessageKeys.insert(key)
            for entry in group.entries {
                let alias = "entry:" + entry.id
                dshMessages[alias] = message
                visibleMessageKeys.insert(alias)
            }
            message.remoteAssistantName = dshService?.name ?? "DSH"
            let rawText = group.entries.filter { $0.role != .tool }.map(\.text).joined(separator: "\n\n")
            let messageRawKey = "message:" + message.id.uuidString
            visibleRawKeys.insert(messageRawKey)
            if dshRawTexts[messageRawKey] != rawText {
                dshRawTexts[messageRawKey] = rawText
                message.content = Self.dshDisplayText(rawText)
            }
            var blocks: [AssistantBlock] = []
            var reasoningRun: [(id: String, text: String)] = []
            func flushReasoning() {
                guard let first = reasoningRun.first else { return }
                // Parts are complete snapshots, not deltas. Rebuild the run so
                // replay and reconnect cannot append the same thinking twice.
                let text = reasoningRun.map(\.text).joined(separator: "\n\n")
                let existing = reasoningRun.compactMap { dshBlocks[$0.id] }.first {
                    $0.kind == .thinking && !usedNativeBlockIDs.contains($0.id)
                }
                dshBlocks[first.id] = existing ?? AssistantBlock(kind: .thinking, content: text)
                let block = dshBlock(first.id, kind: .thinking, content: text)
                block.thinkingContentBuffer = text
                usedNativeBlockIDs.insert(block.id)
                // Keep every member as an alias when pagination prepends an
                // earlier reasoning part, preserving the visible block state.
                for part in reasoningRun { dshBlocks[part.id] = block }
                blocks.append(block)
                reasoningRun.removeAll(keepingCapacity: true)
            }
            for entry in group.entries where entry.role != .user {
                if entry.role == .tool {
                    flushReasoning()
                    let id = "orphan:" + entry.id
                    guard visibleBlockIDs.insert(id).inserted else { continue }
                    let tool = DSHChatTool(id: entry.id, name: entry.toolName ?? AppLocalized("远程工具"),
                                          arguments: "", status: entry.toolStatus ?? "unknown",
                                          output: entry.toolOutput ?? entry.text)
                    prepareNonThinkingBlock(id)
                    let block = dshToolBlock(id, tool: tool)
                    usedNativeBlockIDs.insert(block.id)
                    blocks.append(block)
                    continue
                }
                let parts = Self.dshParts(for: entry)
                for (index, part) in parts.enumerated() {
                    guard visibleBlockIDs.insert(part.id).inserted else { continue }
                    switch part.kind {
                    case .text(let text):
                        flushReasoning()
                        guard !text.isEmpty else { continue }
                        prepareNonThinkingBlock(part.id)
                        let rawKey = "part:" + part.id
                        visibleRawKeys.insert(rawKey)
                        let display: String
                        if dshRawTexts[rawKey] == text, let existing = dshBlocks[part.id] {
                            display = existing.content
                        } else {
                            dshRawTexts[rawKey] = text
                            display = Self.dshDisplayText(text)
                        }
                        let block = dshBlock(part.id, kind: .text, content: display)
                        let streaming = entry.isStreaming && index == parts.count - 1
                        if streaming {
                            if block.cachedMarkdown != nil { block.cachedMarkdown = nil }
                            if block.cachedAttributedString != nil { block.cachedAttributedString = nil }
                        } else if block.cachedAttributedString == nil {
                            cacheAttributedString(for: block)
                        }
                        usedNativeBlockIDs.insert(block.id)
                        blocks.append(block)
                    case .reasoning(let text):
                        guard !text.isEmpty else { continue }
                        reasoningRun.append((part.id, text))
                    case .tool(let tool):
                        flushReasoning()
                        prepareNonThinkingBlock(part.id)
                        let block = dshToolBlock(part.id, tool: tool)
                        usedNativeBlockIDs.insert(block.id)
                        blocks.append(block)
                    }
                }
            }
            flushReasoning()
            if message.blocks.map(\.id) != blocks.map(\.id) {
                message.blocks = blocks
                blocksChanged = true
            }
            next.append(message)
        }
        if snapshot.isRunning && (next.last?.role == .user || next.isEmpty) {
            let pending = dshMessages["__pending__"] ?? ChatMessage(role: .assistant, content: "")
            pending.remoteAssistantName = dshService?.name ?? "DSH"
            dshMessages["__pending__"] = pending
            visibleMessageKeys.insert("__pending__")
            next.append(pending)
        }
        let structureChanged = messages.map(\.id) != next.map(\.id)
        if structureChanged { messages = next }
        let wasProcessing = isProcessing
        isProcessing = connected && snapshot.isRunning
        hasCompletedInitialLoad = true
        if structureChanged || blocksChanged || (wasProcessing && !isProcessing) {
            if !streamingUIUpdatesSuspended && !isTransitionSuspended {
                retrySnapshotReloadSignal.send()
            } else {
                needsSnapshotReloadOnResume = true
            }
        }
        dshMessages = dshMessages.filter { visibleMessageKeys.contains($0.key) }
        dshRawTexts = dshRawTexts.filter { visibleRawKeys.contains($0.key) }
        dshBlocks = dshBlocks.filter { visibleBlockIDs.contains($0.key) }
    }

    private static func dshParts(for entry: DSHChatEntry) -> [DSHChatPart] {
        if !entry.parts.isEmpty { return entry.parts }
        // Compatibility for old cached/offline snapshots without ordered parts.
        var parts: [DSHChatPart] = []
        if !entry.reasoning.isEmpty {
            parts.append(DSHChatPart(id: entry.id + ":thinking", kind: .reasoning(entry.reasoning)))
        }
        if !entry.text.isEmpty {
            parts.append(DSHChatPart(id: entry.id + ":text", kind: .text(entry.text)))
        }
        for (index, tool) in entry.tools.enumerated() {
            parts.append(DSHChatPart(id: entry.id + ":tool:\(index):" + tool.id, kind: .tool(tool)))
        }
        return parts
    }

    private static let dshResourcePatterns = [
            #"(\]\(\s*<?)([^\s)>]+)"#,
            #"(^\s{0,3}\[[^\]]+\]:\s*<?)([^\s>]+)"#,
            #"(?i)(\b(?:src|href)\s*=\s*["'])([^"']+)"#,
            #"(<)((?:minis|file)://[^>]+)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Native media treats every relative path as a phone workspace resource.
    /// Keep web resources intact and namespace all other Markdown/HTML targets.
    static func dshDisplayText(_ text: String) -> String {
        var fence: String?
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                return line
            }
            guard fence == nil else { return line }
            return line.components(separatedBy: "`").enumerated().map { index, part in
                guard index.isMultiple(of: 2) else { return part }
                let result = NSMutableString(string: part)
                for pattern in Self.dshResourcePatterns {
                    let value = result as String
                    for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                        let target = (value as NSString).substring(with: match.range(at: 2))
                        let scheme = URL(string: target)?.scheme?.lowercased()
                        if scheme == "http" || scheme == "https" || scheme == "dshresource" { continue }
                        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unavailable"
                        result.replaceCharacters(in: match.range(at: 2), with: "dshresource://unavailable/" + encoded)
                    }
                }
                return result as String
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }

    private func dshToolBlock(_ id: String, tool: DSHChatTool) -> AssistantBlock {
        let args = tool.arguments.data(using: .utf8).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        let path = args["path"] as? String ?? args["file_path"] as? String ?? args["filename"] as? String ?? ""
        let name = tool.name.components(separatedBy: "__").last?.components(separatedBy: ".").last?.lowercased() ?? tool.name
        let kind: AssistantBlockKind
        switch name {
        case "file_read", "read", "read_file": kind = .fileReadTool(path: path)
        case "file_write", "write", "write_file", "create_file": kind = .fileWriteTool(path: path)
        case "file_edit", "edit", "edit_file", "apply_patch": kind = .fileEditTool(path: path)
        case "browser_use", "browser": kind = .browserTool(action: args["action"] as? String ?? "")
        case "read_image", "view_image": kind = .readImageTool(path: path)
        case "memory_get", "memory_write", "search_chat_history": kind = .memoryTool(action: name)
        case "spawn_subagent", "check_subagent", "message_subagent", "stop_subagent", "send_agent_message", "spawn_cloud_subagent":
            kind = .subagentTool(action: name, taskTitle: args["task_title"] as? String ?? args["title"] as? String ?? "")
        default: kind = .shellTool(command: args["command"] as? String ?? tool.name)
        }
        let block = dshBlock(id, kind: kind, content: tool.output ?? "")
        block.remoteToolName = tool.name
        block.toolUseId = tool.id
        block.toolInputArgs = tool.arguments
        block.toolSummary = args["tool_title"] as? String
        // Remote paths are labels only, never phone image/browser resources.
        block.imageFilePath = nil
        block.browserURL = nil
        switch tool.status {
        case "running", "pending": block.toolStatus = .running
        case "completed", "success": block.toolStatus = .success
        case "error", "failed": block.toolStatus = .failed(message: AppLocalized("远程工具执行失败"))
        case "cancelled", "canceled": block.toolStatus = .cancelled
        default: block.toolStatus = nil
        }
        return block
    }

    private func dshBlock(_ id: String, kind: AssistantBlockKind, content: String) -> AssistantBlock {
        let block = dshBlocks[id] ?? AssistantBlock(kind: kind, content: content)
        dshBlocks[id] = block
        if block.kind != kind { block.kind = kind }
        if block.content != content {
            block.content = content
            block.cachedMarkdown = nil
            block.cachedAttributedString = nil
        }
        return block
    }
}
