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
        var next: [ChatMessage] = []
        var blocksChanged = false
        var visibleBlockIDs: Set<String> = []
        for entry in snapshot.entries {
            let message = dshMessages[entry.id] ?? ChatMessage(
                role: entry.role == .user ? .user : .assistant, content: ""
            )
            dshMessages[entry.id] = message
            message.remoteAssistantName = dshService?.name ?? "DSH"
            if dshRawTexts[entry.id] != entry.text {
                dshRawTexts[entry.id] = entry.text
                message.content = Self.dshDisplayText(entry.text)
            }
            var blocks: [AssistantBlock] = []
            if entry.role == .tool {
                let id = entry.id + ":tool"
                let block = dshToolBlock(id, name: entry.toolName ?? AppLocalized("远程工具"),
                                         content: entry.toolOutput ?? entry.text, status: entry.toolStatus ?? "unknown")
                blocks.append(block)
                visibleBlockIDs.insert(id)
            } else if entry.role == .assistant {
                if !entry.reasoning.isEmpty {
                    let id = entry.id + ":thinking"
                    let block = dshBlock(id, kind: .thinking, content: entry.reasoning)
                    block.thinkingContentBuffer = entry.reasoning
                    blocks.append(block)
                    visibleBlockIDs.insert(id)
                }
                if !entry.text.isEmpty {
                    let id = entry.id + ":text"
                    blocks.append(dshBlock(id, kind: .text, content: message.content))
                    visibleBlockIDs.insert(id)
                }
                for tool in entry.tools {
                    let id = entry.id + ":tool:" + tool.id
                    let content = [tool.arguments, tool.output ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    blocks.append(dshToolBlock(id, name: tool.name, content: content, status: tool.status))
                    visibleBlockIDs.insert(id)
                }
            }
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
        // Drop stale pagination/placeholder objects without changing stable IDs.
        let visibleIDs = Set(snapshot.entries.map(\.id) + (snapshot.isRunning ? ["__pending__"] : []))
        dshMessages = dshMessages.filter { visibleIDs.contains($0.key) }
        dshRawTexts = dshRawTexts.filter { visibleIDs.contains($0.key) }
        dshBlocks = dshBlocks.filter { visibleBlockIDs.contains($0.key) }
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

    private func dshToolBlock(_ id: String, name: String, content: String, status: String) -> AssistantBlock {
        let block = dshBlock(id, kind: .shellTool(command: name), content: content)
        switch status {
        case "running", "pending": block.toolStatus = .running
        case "completed", "success": block.toolStatus = .success
        case "error", "failed": block.toolStatus = .failed(message: AppLocalized("远程工具执行失败"))
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
