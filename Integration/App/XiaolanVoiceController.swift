import AVFoundation
import Combine
import Foundation
import VoiceRecording

/// User-enabled voice input shares one Agent conversation across foreground
/// and background, with navigation and reply authority scoped separately.
@MainActor
final class XiaolanVoiceController: ObservableObject {
    static let shared = XiaolanVoiceController()

    @Published private(set) var isEnabled = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var status = "语音模式未开启"
    @Published private(set) var error: String?
    @Published private(set) var lastCommand = ""
    @Published private(set) var lastAnswer = ""
    @Published private(set) var sessionID: String?

    private(set) var responseGeneration: UInt64 = 0
    private var foreground = true
    private var placeConfirmationPresented = false
    private var installed = false
    private weak var recordings: VoiceRecordingWorkspace?
    private var input: IndependentVoiceInput?
    private var activationID: UUID?
    private var activeRequestID: UUID?
    private var commandCaptureActive = false
    private var captureAllowsNavigation = true
    private var directAllowsNavigation: Bool?
    private var requestAllowsNavigation = false
    private var requestGeneration: UInt64?
    private var requestPageRevision: Int?
    private var authorizedReplyGeneration: UInt64?
    private var authorizedReplyPageRevision: Int?
    private var backgroundRequests: [String: UUID] = [:]
    private var answerSpeechTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var executionHandoff: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var speechToken: UUID?
    private var acknowledgementID: UUID?
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var isCapturingVoice: Bool { isEnabled && !isPaused && input?.isRunning == true }

    /// Live voice mode owns this session's input; typing requires a takeover (pause).
    func ownsComposer(sessionID: String?) -> Bool {
        isEnabled && !isPaused && sessionID != nil && self.sessionID == sessionID
    }

    enum ModeError: LocalizedError {
        case recordingActive, unavailable(String), inactive
        var errorDescription: String? {
            switch self {
            case .recordingActive: "当前有一条未结束的录音。请先结束录音，再开启语音模式。"
            case .unavailable(let message): message
            case .inactive: "请在 App 前台开启或继续语音模式。"
            }
        }
    }

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        XiaolanVoiceAcknowledgement.shared.onSpeakingChanged = { [weak self] speaking in
            guard let self, self.acknowledgementID != nil else { return }
            self.isSpeaking = speaking
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notice in
            guard let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        }
        AsyncTaskNoticeManager.shared.replyHooks["xiaolan_voice"] = .init(
            prepare: { [weak self] sessionID in await self?.prepareBackgroundReply(sessionID: sessionID) ?? false },
            finish: { [weak self] sessionID, result in await self?.finishBackgroundReply(sessionID: sessionID, result: result) }
        )
        IOSAgentSessionRunner.shared.noticeSystemPrompts["xiaolan_voice"] = { [weak self] sessionID in
            guard let self, sessionID == self.sessionID, self.canRespond,
                  self.authorizedReplyGeneration == self.responseGeneration else { return nil }
            return self.systemPrompt + """

            当前由 async_task_notice 完成通知触发，没有新语音指令。只核对已授权任务的真实结果，通过 answer_user 简短交付。
            不得重复执行原任务、重新分派或播报收到。不得跳转页面、打开预览或调用 app_present；后台完成不得抢占当前页面。
            """
        }
    }

    func enable(recordings: VoiceRecordingWorkspace) async throws {
        install()
        if isEnabled {
            if isPaused { try await resume(recordings: recordings) }
            return
        }
        try await activate(recordings: recordings, continuing: false)
    }

    func resume(recordings: VoiceRecordingWorkspace) async throws {
        guard isEnabled else { try await enable(recordings: recordings); return }
        guard isPaused else { return }
        try await activate(recordings: recordings, continuing: true)
    }

    private func activate(recordings: VoiceRecordingWorkspace, continuing: Bool) async throws {
        guard foreground, !placeConfirmationPresented else { throw ModeError.inactive }
        guard !recordings.hasUnfinishedRecording else { throw ModeError.recordingActive }
        if let reason = recordings.startupError ?? IndependentVoiceInput.unavailableReason
            ?? MeetingAssistantController.modelUnavailableReason() {
            error = reason
            throw ModeError.unavailable(reason)
        }
        let activation = UUID()
        activationID = activation
        do { try await XiaolanAgent.ensure() } catch {
            if activationID == activation { activationID = nil }
            self.error = error.localizedDescription
            throw ModeError.unavailable(error.localizedDescription)
        }
        guard activationID == activation, foreground else { throw ModeError.inactive }
        guard await IndependentVoiceInput.requestMicrophonePermission() else {
            if activationID == activation { activationID = nil }
            let reason = "未获得麦克风权限，请在系统设置中允许麦克风后重试。"
            error = reason
            throw ModeError.unavailable(reason)
        }
        guard activationID == activation, foreground else { throw ModeError.inactive }
        try StoryLibraryStore.shared.prepareForBackgroundPlayback()
        // Permission UI may suspend this task while a recording starts.
        guard !recordings.hasUnfinishedRecording,
              AudioSessionCoordinator.shared.reserveIndependentVoice() else {
            activationID = nil
            throw ModeError.recordingActive
        }
        activationID = nil
        StoryPlaybackController.shared.beginVoiceInteraction()
        self.recordings = recordings
        if input == nil { input = recordings.makeIndependentVoiceInput() }
        responseGeneration &+= 1
        isEnabled = true
        isPaused = false
        error = nil
        if !continuing { sessionID = nil; lastCommand = ""; lastAnswer = "" }
        do { try listen() } catch {
            if continuing { pause() } else { disable() }
            self.error = error.localizedDescription
            throw error
        }
    }

    func disable() {
        invalidate()
        isEnabled = false
        isPaused = false
        sessionID = nil
        input = nil
        AudioSessionCoordinator.shared.releaseIndependentVoice()
        status = "语音模式未开启"
    }

    func pause() {
        guard isEnabled else { activationID = nil; return }
        invalidate()
        isPaused = true
        status = "语音模式已暂停"
    }

    /// Stop listening while a tool awaits a deliberate tap, preserving that tool's execution generation.
    func setPlaceConfirmationPresented(_ presented: Bool) {
        guard placeConfirmationPresented != presented else { return }
        placeConfirmationPresented = presented
        if presented {
            input?.stop()
            AudioSessionCoordinator.shared.end(.xiaolanCapture)
            commandCaptureActive = false
            if isEnabled, !isPaused { status = "等待确认收藏" }
        } else if isEnabled, !isPaused, !isBusy, foreground {
            do { try listen() } catch { failAndPause(error.localizedDescription) }
        }
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if !value {
            activationID = nil
            if commandCaptureActive { captureAllowsNavigation = false }
            // The enabled microphone and Agent continue. Only UI authority
            // ends when the app becomes hidden or locked.
            requestAllowsNavigation = false
            AppNavigationCenter.shared.invalidateVoiceSession()
        }
        if isEnabled, !isPaused, !isBusy, !commandCaptureActive {
            status = waitingStatus
        }
    }

    func beginCommand() {
        guard isEnabled, !isPaused, foreground, !placeConfirmationPresented else { return }
        directAllowsNavigation = nil
        interruptCurrentRequest()
        StoryPlaybackController.shared.beginVoiceInteraction()
        do { try listen(direct: true) } catch { failAndPause(error.localizedDescription) }
    }

    func stopSpeaking() {
        answerSpeechTask?.cancel()
        answerSpeechTask = nil
        stopAcknowledgement()
        stopSpeech()
        if isEnabled, !isPaused, !isBusy, foreground {
            do { try listen() } catch { failAndPause(error.localizedDescription) }
        }
    }

    func navigationGeneration(sessionID: String) -> UInt64? {
        guard foreground, requestAllowsNavigation else { return nil }
        return executionGeneration(sessionID: sessionID)
    }

    func executionGeneration(sessionID: String) -> UInt64? {
        guard self.sessionID == sessionID, canRespond else { return nil }
        return requestGeneration
    }

    func isVoiceGenerationCurrent(sessionID: String, generation: UInt64) -> Bool {
        executionGeneration(sessionID: sessionID) == generation
    }

    private var canRespond: Bool {
        isEnabled && !isPaused && activeRequestID != nil
            && requestGeneration == responseGeneration
    }

    private var waitingStatus: String {
        foreground ? "等待小蓝同学" : "熄屏可唤醒，智能体继续运行"
    }

    private var hasPendingVoiceAgentWork: Bool {
        guard let sessionID, let vm = ViewModelCache.shared.get(for: sessionID),
              vm.agentId == XiaolanAgent.id, vm.sessionSource == "xiaolan_voice" else { return false }
        return vm.isProcessing || vm.isCompacting || vm.currentTask != nil || vm.compactTask != nil
            || vm.postCompactDrainPending || !vm.promptQueue.isEmpty
    }

    /// Wake input has priority over model work and output. Join the old model's
    /// actual cleanup before submitting the next command, while capture stays live.
    private func interruptCurrentRequest() {
        let hadRequest = activeRequestID != nil
        let previousCommand = commandTask
        commandTask = nil
        previousCommand?.cancel()
        let previousHandoff = executionHandoff
        var previousModel: Task<Void, Never>?
        var previousCompact: Task<Void, Never>?
        if let sessionID, let vm = ViewModelCache.shared.get(for: sessionID),
           hadRequest || hasPendingVoiceAgentWork {
            previousModel = vm.currentTask
            previousCompact = vm.compactTask
            // A compact task can exist before isCompacting becomes true;
            // cancel() alone does not cover that scheduling window.
            previousCompact?.cancel()
            // These pending prompts belong to the superseded voice turn. Keep
            // completed tools/history; do not let cancel() start an old queue.
            let queued = Set(vm.promptQueue.map(\.id))
            vm.promptQueue.removeAll()
            vm.messages.removeAll { $0.queuedPromptId.map(queued.contains) == true }
            IOSAgentSessionRunner.shared.cancel(sessionId: sessionID)
            vm.compactTask = nil
        }
        if previousCommand != nil || previousModel != nil || previousCompact != nil {
            executionHandoff = Task {
                await previousHandoff?.value
                await previousCommand?.value
                await previousModel?.value
                await previousCompact?.value
            }
        }
        responseGeneration &+= 1
        authorizedReplyGeneration = nil
        authorizedReplyPageRevision = nil
        if let sessionID, let activeRequestID {
            MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: activeRequestID)
        }
        activeRequestID = nil
        requestAllowsNavigation = false
        requestGeneration = nil
        requestPageRevision = nil
        isBusy = false
        answerSpeechTask?.cancel()
        answerSpeechTask = nil
        stopAcknowledgement()
        stopSpeech()
        AppNavigationCenter.shared.invalidateVoiceSession()
    }

    private func invalidate() {
        activationID = nil
        interruptCurrentRequest()
        commandCaptureActive = false
        captureAllowsNavigation = true
        directAllowsNavigation = nil
        input?.stop()
        AudioSessionCoordinator.shared.end(.xiaolanCapture)
        StoryPlaybackController.shared.cancelVoiceInteraction()
    }

    private func listen(direct: Bool = false) throws {
        guard isEnabled, !isPaused, !placeConfirmationPresented else { return }
        guard recordings?.hasUnfinishedRecording != true else {
            disable()
            throw ModeError.recordingActive
        }
        if direct { StoryPlaybackController.shared.beginVoiceInteraction() }
        if input?.isRunning == true {
            if direct {
                input?.beginCommand()
            } else if !isBusy {
                status = waitingStatus
                StoryPlaybackController.shared.finishVoiceInteraction()
            }
            return
        }
        // New microphone activation remains an explicit foreground action.
        guard foreground else { throw ModeError.inactive }
        input?.stop()
        guard AudioSessionCoordinator.shared.beginAndWait(.xiaolanCapture) else {
            throw ModeError.unavailable("当前无法使用麦克风，请稍后继续语音模式。")
        }
        status = direct ? "请说出指令" : "正在准备语音输入"
        do {
            try input?.start(direct: direct) { [weak self] event in self?.receive(event, direct: direct) }
        } catch {
            AudioSessionCoordinator.shared.end(.xiaolanCapture)
            throw error
        }
    }

    private func receive(_ event: IndependentVoiceInput.Event, direct: Bool) {
        guard isEnabled, !isPaused, !placeConfirmationPresented else { return }
        switch event {
        case .ready:
            if !isBusy {
                status = waitingStatus
                StoryPlaybackController.shared.finishVoiceInteraction()
            }
        case .listening:
            interruptCurrentRequest()
            captureAllowsNavigation = foreground && (directAllowsNavigation ?? true)
            directAllowsNavigation = nil
            commandCaptureActive = true
            StoryPlaybackController.shared.beginVoiceInteraction()
            status = "正在听指令"
        case .transcribing:
            captureAllowsNavigation = captureAllowsNavigation && foreground
            commandCaptureActive = true
            StoryPlaybackController.shared.beginVoiceInteraction()
            isBusy = true
            status = "正在识别指令"
        case .wakeOnly:
            let (id, generation) = beginTurn()
            commandTask = Task {
                await acknowledge("我在", id: id, generation: generation)
                finishRequest(id: id, listenDirectly: true)
            }
        case .command(let text):
            lastCommand = text
            let (id, generation) = beginTurn()
            commandTask = Task {
                await acknowledge("收到，开始处理", id: id, generation: generation)
                guard accepts(id, generation: generation) else { return }
                status = "正在处理指令"
                await execute(text, id: id, generation: generation)
            }
        case .timeout:
            guard activeRequestID == nil else { return }
            commandCaptureActive = false
            captureAllowsNavigation = true
            directAllowsNavigation = nil
            isBusy = false
            status = "没有听到指令，请再说一次"
            if direct { do { try listen() } catch { failAndPause(error.localizedDescription) } }
            else { StoryPlaybackController.shared.finishVoiceInteraction() }
        case .failure(let text, let fatal):
            error = text
            if fatal { failAndPause(text) }
            else if activeRequestID == nil {
                commandCaptureActive = false
                captureAllowsNavigation = true
                directAllowsNavigation = nil
                isBusy = false
                do { try listen() } catch { failAndPause(error.localizedDescription) }
            }
        }
    }

    private func beginTurn() -> (UUID, UInt64) {
        interruptCurrentRequest()
        let id = UUID()
        activeRequestID = id
        requestAllowsNavigation = foreground && captureAllowsNavigation
        commandCaptureActive = false
        requestGeneration = responseGeneration
        requestPageRevision = AppNavigationCenter.shared.state.revision
        isBusy = true
        error = nil
        return (id, responseGeneration)
    }

    /// Fixed local feedback never waits for the model or configured network TTS.
    private func acknowledge(_ text: String, id: UUID, generation: UInt64) async {
        guard accepts(id, generation: generation) else { return }
        status = text
        guard !VoiceOutputPreferences.isMuted else { return }
        guard AudioSessionCoordinator.shared.beginAndWait(.xiaolanTTS) else {
            AudioSessionCoordinator.shared.end(.xiaolanTTS)
            return
        }
        acknowledgementID = id
        let completed = await XiaolanVoiceAcknowledgement.shared.say(text)
        guard acknowledgementID == id else { return }
        acknowledgementID = nil
        isSpeaking = false
        AudioSessionCoordinator.shared.end(.xiaolanTTS)
        if !completed, accepts(id, generation: generation) { error = "提示语未能播报，请查看当前语音状态。" }
    }

    private func stopAcknowledgement() {
        guard acknowledgementID != nil else { return }
        acknowledgementID = nil
        XiaolanVoiceAcknowledgement.shared.stop()
        isSpeaking = false
        AudioSessionCoordinator.shared.end(.xiaolanTTS)
    }

    private func voiceSession(id: UUID, generation: UInt64) async -> String? {
        let runner = IOSAgentSessionRunner.shared
        do { try await XiaolanAgent.ensure() } catch {
            report(error.localizedDescription, id: id)
            return nil
        }
        guard accepts(id, generation: generation) else { return nil }
        if let existing = sessionID, await ChatStore.shared.sessionExists(id: existing),
           !(await XiaolanAgent.ownsSession(existing)) {
            sessionID = nil
        }
        if sessionID == nil {
            guard let created = await runner.createSession(.init(agentId: XiaolanAgent.id, source: "xiaolan_voice", role: "main", toolPolicy: "orchestrator")),
                  await XiaolanAgent.ownsSession(created) else {
                report("未能建立语音任务会话，请检查聊天模型配置。", id: id)
                return nil
            }
            guard accepts(id, generation: generation) else { return nil }
            sessionID = created
            await ChatStore.shared.updateSessionTitle(created, title: "小蓝同学 · 语音模式")
        }
        guard let sessionID, accepts(id, generation: generation), await ChatStore.shared.sessionExists(id: sessionID) else {
            report("语音会话已被删除，请关闭后重新开启语音模式。", id: id)
            return nil
        }
        StoryPlaybackController.shared.bindCompletionSessionIfUnowned(sessionID)
        return sessionID
    }

    private func execute(_ command: String, id: UUID, generation: UInt64) async {
        defer { finishRequest(id: id) }
        await executionHandoff?.value
        guard accepts(id, generation: generation),
              let sessionID = await voiceSession(id: id, generation: generation),
              accepts(id, generation: generation) else { return }
        let runner = IOSAgentSessionRunner.shared
        let (vm, fresh) = ViewModelCache.shared.getOrCreate(for: sessionID)
        if fresh { await vm.loadSession() }
        guard accepts(id, generation: generation) else { return }
        guard !vm.isProcessing, !vm.isCompacting, vm.compactTask == nil,
              !vm.postCompactDrainPending, vm.promptQueue.isEmpty,
              !SessionActivityTracker.shared.isActive(sessionID) else {
            report("上一项任务仍在执行，请稍后再说。我不会重复提交。", id: id)
            return
        }
        bindAnswer(sessionID: sessionID, id: id, generation: generation)
        defer { MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: id) }
        if navigationGeneration(sessionID: sessionID) == generation,
           requestPageRevision == AppNavigationCenter.shared.state.revision {
            AppNavigationCenter.shared.bindVoiceSession(sessionID: sessionID, generation: generation)
        }
        let result = await runner.run(.init(
            sessionId: sessionID, prompt: command, agentId: XiaolanAgent.id, source: "xiaolan_voice", systemPromptBlock: systemPrompt,
            role: "main", toolPolicy: "orchestrator", timeoutSeconds: 120
        ))
        guard accepts(id, generation: generation) else { return }
        if result.accepted {
            authorizedReplyGeneration = generation
            let navigation = AppNavigationCenter.shared
            authorizedReplyPageRevision = navigation.isVoiceBindingCurrent(sessionID: sessionID, generation: generation)
                ? navigation.state.revision : requestPageRevision
        }
        await answerSpeechTask?.value
        guard accepts(id, generation: generation), !MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: id) else { return }
        if !result.accepted { report("智能体未接下本次指令，请检查聊天模型配置。", id: id) }
        else if result.timedOut { report("任务仍未返回结果，请查看对话确认。我不会重复提交。", id: id) }
        else { report("本次没有收到公开答复，请查看对话核对执行结果。", id: id) }
    }

    private func accepts(_ id: UUID, generation: UInt64) -> Bool {
        canRespond && activeRequestID == id && responseGeneration == generation
    }

    private func bindAnswer(sessionID: String, id: UUID, generation: UInt64, pageRevision: Int? = nil) {
        MeetingAnswerUserTool.bind(sessionID: sessionID, requestID: id) { [weak self] text in
            guard let self, self.accepts(id, generation: generation) else { return false }
            self.lastAnswer = text
            self.error = nil
            if !self.foreground || pageRevision == nil || pageRevision == AppNavigationCenter.shared.state.revision {
                self.answerSpeechTask = Task { await self.speak(text, id: id, generation: generation, pageRevision: pageRevision) }
            } else {
                self.status = "任务结果已保存，可在对话中查看"
            }
            return true
        }
    }

    private func finishRequest(id: UUID, listenDirectly: Bool = false) {
        guard activeRequestID == id else { return }
        directAllowsNavigation = listenDirectly ? requestAllowsNavigation : nil
        captureAllowsNavigation = true
        commandTask = nil
        activeRequestID = nil
        requestAllowsNavigation = false
        requestGeneration = nil
        requestPageRevision = nil
        isBusy = false
        AppNavigationCenter.shared.invalidateVoiceSession()
        if isEnabled, !isPaused {
            do { try listen(direct: listenDirectly) } catch { failAndPause(error.localizedDescription) }
        }
        if let sessionID { Task { await AsyncTaskNoticeManager.shared.checkAndDrain(sessionId: sessionID) } }
    }

    private func report(_ text: String, id: UUID) {
        guard activeRequestID == id, canRespond else { return }
        error = text
        status = text
    }

    private func failAndPause(_ text: String) {
        pause()
        error = text
    }

    private var systemPrompt: String {
        """
        当前为同一台 iPhone 上独立开启的语音会话，不依附会议或录音。
        同一开启期间连续理解此前指令与已验证工具结果；“今天”等日期采用设备当地时间。
        当前新指令的本地提示已经由宿主完成；直接执行或回答，不重复确认接收。
        用户已开启持续语音，锁屏或切到后台时仍可执行完整智能体任务、调用业务工具和分派子智能体，并通过 answer_user 交付结果。
        页面导航、打开预览和需要系统授权界面的操作仍须前台解锁。后台可以继续不依赖界面的工作；不能把未显示的页面说成已打开。
        用户明确要求查看子任务内容时，使用真实 source_session_id 与其 workspace/attachments 路径，通过现有 App 内预览展示。
        """
    }

    private func prepareBackgroundReply(sessionID: String) async -> Bool {
        guard self.sessionID == sessionID, isEnabled, !isPaused, !isBusy,
              activeRequestID == nil, authorizedReplyGeneration == responseGeneration else { return false }
        let id = UUID(), generation = responseGeneration
        StoryPlaybackController.shared.beginVoiceInteraction()
        isBusy = true
        activeRequestID = id
        requestAllowsNavigation = false
        requestGeneration = generation
        bindAnswer(sessionID: sessionID, id: id, generation: generation, pageRevision: authorizedReplyPageRevision)
        backgroundRequests[sessionID] = id
        AppNavigationCenter.shared.invalidateVoiceSession()
        return true
    }

    private func finishBackgroundReply(sessionID: String, result: AgentSessionRunResult) async {
        guard let id = backgroundRequests.removeValue(forKey: sessionID) else { return }
        defer {
            MeetingAnswerUserTool.unbind(sessionID: sessionID, requestID: id)
            finishRequest(id: id)
        }
        guard self.sessionID == sessionID, activeRequestID == id, canRespond else { return }
        await answerSpeechTask?.value
        if result.accepted, !MeetingAnswerUserTool.didDeliver(sessionID: sessionID, requestID: id),
           result.text?.trimmingCharacters(in: .whitespacesAndNewlines) != "(pass)" {
            report("后台任务没有收到公开答复，请查看对话核对结果。", id: id)
        }
    }

    private func speak(_ text: String, id: UUID, generation: UInt64, pageRevision: Int? = nil) async {
        func canSpeak() -> Bool {
            accepts(id, generation: generation)
                && (!foreground || pageRevision == nil || pageRevision == AppNavigationCenter.shared.state.revision)
        }
        guard canSpeak() else { return }
        guard !VoiceOutputPreferences.isMuted else { status = "已静音，结果保存在对话中"; return }
        stopSpeech()
        let sanitized = VoiceTextSanitizer.sanitize(text)
        let spoken = sanitized.count > 180 ? String(sanitized.prefix(180)) + "，完整结果请查看对话。" : sanitized
        guard !spoken.isEmpty else { return }
        let token = UUID()
        speechToken = token
        status = "正在准备播报"
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSpeech(token: token) }
            do {
                let provider = VoiceProviderResolver.outputProvider()
                let system = provider is SystemVoiceProvider
                let audio = try await provider.synthesize(.init(
                    input: spoken,
                    model: system ? VoiceProviderResolver.resolvedSystemOutputVoiceId() : VoiceProviderResolver.resolvedOutputEntry()?.model.id,
                    voice: system ? VoiceProviderResolver.resolvedSystemOutputVoiceId() : nil,
                    speed: VoiceOutputPreferences.speedMultiplier
                ))
                guard !Task.isCancelled, self.speechToken == token, canSpeak(),
                      !VoiceOutputPreferences.isMuted else { return }
                guard AudioSessionCoordinator.shared.beginAndWait(.xiaolanTTS) else {
                    throw ModeError.unavailable("当前无法播报，结果保存在对话中。")
                }
                let player = try AVAudioPlayer(data: audio)
                self.player = player
                player.prepareToPlay()
                guard player.play() else { throw VoiceProviderError.noAudioData }
                self.isSpeaking = true
                self.status = "正在播报"
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(100))
                    guard self.speechToken == token, canSpeak(),
                          !VoiceOutputPreferences.isMuted else { return }
                }
            } catch is CancellationError {
                // Explicit close/pause/stop invalidates this token immediately.
            } catch {
                guard self.speechToken == token, self.accepts(id, generation: generation) else { return }
                self.error = "播报失败：\(error.localizedDescription)，结果保存在对话中。"
            }
        }
        let synthesisDeadline = Date().addingTimeInterval(30), playbackDeadline = Date().addingTimeInterval(90)
        while speechToken == token {
            guard !Task.isCancelled, canSpeak(), !VoiceOutputPreferences.isMuted else { stopSpeech(); return }
            if Date() >= playbackDeadline || (player == nil && Date() >= synthesisDeadline) {
                error = "播报等待超时，结果保存在对话中。"
                stopSpeech()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func stopSpeech() {
        speechTask?.cancel()
        if let token = speechToken { finishSpeech(token: token) }
    }

    private func finishSpeech(token: UUID) {
        guard speechToken == token else { return }
        speechToken = nil
        player?.stop()
        player = nil
        speechTask = nil
        isSpeaking = false
        AudioSessionCoordinator.shared.end(.xiaolanTTS)
    }
}
