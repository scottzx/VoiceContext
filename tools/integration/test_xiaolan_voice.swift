import Combine
import Foundation

enum AgentToolPolicy { case standalone, orchestrator }

// Only the process boundaries are fake; lifecycle, request authorization and
// answer delivery below execute the real controller and answer_user tool.
let AVAudioSessionInterruptionTypeKey = "interruption"
enum AVAudioSession {
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    static let interruptionNotification = Notification.Name("test.audio.interruption")
}
@MainActor final class AVAudioPlayer {
    static var played = 0
    static var playbackMilliseconds = 10
    var isPlaying = false
    init(data: Data) throws {}
    func prepareToPlay() {}
    func play() -> Bool {
        Self.played += 1
        isPlaying = true
        let duration = Self.playbackMilliseconds
        Task { try? await Task.sleep(for: .milliseconds(duration)); isPlaying = false }
        return true
    }
    func stop() { isPlaying = false }
}
enum VoiceProviderError: Error { case noAudioData }
struct SynthesisRequest { let input: String; let model: String?; let voice: String?; let speed: Double }
@MainActor protocol TestVoiceProvider { func synthesize(_ request: SynthesisRequest) async throws -> Data }
@MainActor final class SystemVoiceProvider: TestVoiceProvider {
    static var inputs: [String] = []
    static var delay: UInt64 = 0
    func synthesize(_ request: SynthesisRequest) async throws -> Data {
        Self.inputs.append(request.input)
        // Simulate a provider whose underlying continuation ignores cancellation.
        if Self.delay > 0 { await withCheckedContinuation { c in
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(Self.delay) / 1_000) { c.resume() }
        } }
        return Data([1])
    }
}
enum VoiceProviderResolver {
    struct Entry { struct Model { let id: String }; let model: Model }
    static func outputProvider() -> any TestVoiceProvider { SystemVoiceProvider() }
    static func resolvedSystemOutputVoiceId() -> String { "system" }
    static func resolvedOutputEntry() -> Entry? { nil }
}
enum VoiceOutputPreferences { static var isMuted = false; static var speedMultiplier = 1.0 }
enum VoiceTextSanitizer { static func sanitize(_ text: String) -> String { text } }
@MainActor final class XiaolanVoiceAcknowledgement {
    static let shared = XiaolanVoiceAcknowledgement()
    var inputs: [String] = []
    var delay = 10
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    private var token: UUID?
    func say(_ text: String) async -> Bool {
        precondition(AudioSessionCoordinator.shared.capture, "Wake input must remain active during fixed feedback")
        inputs.append(text)
        let id = UUID(); token = id
        onSpeakingChanged?(true)
        try? await Task.sleep(for: .milliseconds(delay))
        if token == id { onSpeakingChanged?(false) }
        return token == id
    }
    func stop() { token = nil; onSpeakingChanged?(false) }
}
@MainActor final class IndependentVoiceInput {
    enum Event { case ready, listening, transcribing, wakeOnly, command(String), timeout, failure(String, fatal: Bool) }
    static var unavailableReason: String?
    static var permissionRequests = 0
    static var grantPermission: () async -> Bool = { true }
    static var latest: IndependentVoiceInput?
    static var starts = 0
    static var directStarts = 0
    var handler: (@MainActor (Event) -> Void)?
    var isRunning = false
    static func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        return await grantPermission()
    }
    func start(direct: Bool = false, onEvent: @escaping @MainActor (Event) -> Void) throws {
        Self.starts += 1
        if direct { Self.directStarts += 1 }
        Self.latest = self
        isRunning = true
        handler = onEvent
        onEvent(direct ? .listening : .ready)
    }
    func stop() { handler = nil; isRunning = false }
    func beginCommand() { Self.directStarts += 1; handler?(.listening) }
    func command(_ text: String) { handler?(.transcribing); handler?(.command(text)) }
    func wake() { handler?(.listening) }
    func wakeOnly() { handler?(.transcribing); handler?(.wakeOnly) }
}
@MainActor final class VoiceRecordingWorkspace {
    var hasUnfinishedRecording = false
    var startupError: String?
    func makeIndependentVoiceInput() -> IndependentVoiceInput { IndependentVoiceInput() }
}
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Intent: Hashable { case xiaolanCapture, xiaolanTTS }
    var isIndependentVoiceEnabled = false
    var capture = false
    var recording = false
    var rejectTTS = false
    var ttsReserved = false
    func reserveIndependentVoice() -> Bool {
        guard !recording else { return false }
        isIndependentVoiceEnabled = true
        return true
    }
    func releaseIndependentVoice() { isIndependentVoiceEnabled = false; capture = false; ttsReserved = false }
    func beginAndWait(_ intent: Intent) -> Bool {
        if intent == .xiaolanTTS { ttsReserved = true; return isIndependentVoiceEnabled && !rejectTTS }
        capture = isIndependentVoiceEnabled
        return capture
    }
    func end(_ intent: Intent) {
        if intent == .xiaolanCapture { capture = false }
        else { ttsReserved = false }
    }
}
enum MeetingAssistantController { static var reason: String?; static func modelUnavailableReason() -> String? { reason } }
@MainActor final class StoryLibraryStore {
    static let shared = StoryLibraryStore()
    func prepareForBackgroundPlayback() throws {}
}
@MainActor final class StoryPlaybackController {
    static let shared = StoryPlaybackController()
    var held = false
    var requested = false
    var playing = false
    func bindCompletionSessionIfUnowned(_ sessionID: String) {}
    func beginVoiceInteraction() { held = true; playing = false }
    func finishVoiceInteraction() { held = false; playing = requested }
    func cancelVoiceInteraction() { if held { held = false; requested = false; playing = false } }
}
@MainActor final class ChatStore {
    static let shared = ChatStore()
    var sessions: Set<String> = []
    var owners: [String: String] = [:]
    func updateSessionTitle(_ id: String, title: String) async {}
    func sessionExists(id: String) async -> Bool { sessions.contains(id) }
}
@MainActor enum XiaolanAgent {
    static let id = "agent-xiaolan"
    static var failure: Error?
    static func ensure() async throws { if let failure { throw failure } }
    static func ownsSession(_ sessionID: String) async -> Bool { ChatStore.shared.owners[sessionID] == id }
}
@MainActor final class HostVM {
    var agentId: String? = XiaolanAgent.id
    var sessionSource: String? = "xiaolan_voice"
    var isProcessing = false, isCompacting = false, postCompactDrainPending = false
    var currentTask: Task<Void, Never>?
    var compactTask: Task<Void, Never>?
    struct Prompt { let id: String }
    struct Message { let queuedPromptId: String? }
    var promptQueue: [Prompt] = []
    var messages: [Message] = []
    func loadSession() async {}
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var models: [String: HostVM] = [:]
    func get(for id: String) -> HostVM? { models[id] }
    func getOrCreate(for id: String) -> (HostVM, Bool) {
        if let vm = models[id] { return (vm, false) }
        let vm = HostVM(); models[id] = vm; return (vm, false)
    }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    func isActive(_ id: String) -> Bool { false }
}
@MainActor final class AppNavigationCenter {
    static let shared = AppNavigationCenter()
    struct State { var revision = 0 }
    var state = State()
    var binding: (String, UInt64)?
    func bindVoiceSession(sessionID: String, generation: UInt64) { binding = (sessionID, generation) }
    func invalidateVoiceSession() { binding = nil }
    func isVoiceBindingCurrent(sessionID: String?, generation: UInt64?) -> Bool {
        binding?.0 == sessionID && binding?.1 == generation && generation != nil
    }
}
@MainActor final class AsyncTaskNoticeManager {
    static let shared = AsyncTaskNoticeManager()
    struct ReplyHooks {
        let prepare: @MainActor (String) async -> Bool
        let finish: @MainActor (String, AgentSessionRunResult) async -> Void
    }
    var replyHooks: [String: ReplyHooks] = [:]
    func checkAndDrain(sessionId: String) async {}
}
@MainActor final class IOSAgentSessionRunner {
    static let shared = IOSAgentSessionRunner()
    var noticeSystemPrompts: [String: @MainActor (String) -> String?] = [:]
    var requests: [AgentSessionRunRequest] = []
    var cancellations: [String] = []
    var behavior: (AgentSessionRunRequest) async -> AgentSessionRunResult = { _ in .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false) }
    func createSession(_ request: AgentSessionCreateRequest) async -> String? {
        precondition(request.agentId == XiaolanAgent.id)
        let id = UUID().uuidString
        ChatStore.shared.sessions.insert(id)
        ChatStore.shared.owners[id] = request.agentId
        return id
    }
    func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult {
        precondition(request.agentId == XiaolanAgent.id && ChatStore.shared.owners[request.sessionId] == XiaolanAgent.id)
        requests.append(request)
        return await behavior(request)
    }
    func cancel(sessionId: String) {
        cancellations.append(sessionId)
        if let vm = ViewModelCache.shared.get(for: sessionId) {
            vm.currentTask?.cancel()
            if vm.isCompacting { vm.compactTask?.cancel(); vm.compactTask = nil }
            vm.currentTask = nil
            vm.isProcessing = false
            vm.isCompacting = false
        }
    }
}

@main struct XiaolanVoiceChecks {
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { let pending = continuation; continuation = nil; pending?.resume() }
    }

    @MainActor static func main() async {
        AgentRuntimePolicies.register(source: "xiaolan_voice", policy: .init(replyDelivery: .init(
            definition: MeetingAnswerUserTool.definition,
            canRequest: { MeetingAnswerUserTool.canRequestDelivery(sessionID: $0) },
            reminder: MeetingAnswerUserTool.deliveryReminder)))
        let voice = XiaolanVoiceController.shared
        let workspace = VoiceRecordingWorkspace()
        let runner = IOSAgentSessionRunner.shared
        func settle() async {
            let deadline = Date().addingTimeInterval(2)
            while voice.isBusy && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<2_000 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("Voice test did not reach its expected state")
        }
        func reset() {
            voice.disable(); voice.setForeground(true)
            workspace.hasUnfinishedRecording = false
            IndependentVoiceInput.grantPermission = { true }
            SystemVoiceProvider.delay = 0
            SystemVoiceProvider.inputs = []
            AVAudioPlayer.played = 0
            AVAudioPlayer.playbackMilliseconds = 10
            VoiceOutputPreferences.isMuted = false
            runner.requests = []
            runner.cancellations = []
            XiaolanAgent.failure = nil
            XiaolanVoiceAcknowledgement.shared.inputs = []
            XiaolanVoiceAcknowledgement.shared.delay = 10
            AudioSessionCoordinator.shared.rejectTTS = false
            StoryPlaybackController.shared.held = false
            StoryPlaybackController.shared.requested = false
            StoryPlaybackController.shared.playing = false
        }
        reset()
        workspace.hasUnfinishedRecording = true // Paused/stopping is also unfinished.
        let permissionBefore = IndependentVoiceInput.permissionRequests
        do { try await voice.enable(recordings: workspace); preconditionFailure("Must refuse an unfinished recording") }
        catch { precondition(error is XiaolanVoiceController.ModeError) }
        precondition(!voice.isEnabled && IndependentVoiceInput.permissionRequests == permissionBefore)
        reset()

        XiaolanAgent.failure = NSError(domain: "test.archived", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "小蓝同学已归档"])
        let permissionsBeforeArchive = IndependentVoiceInput.permissionRequests
        do { try await voice.enable(recordings: workspace); preconditionFailure("Archived identity must not start listening") }
        catch {}
        precondition(!voice.isEnabled && IndependentVoiceInput.permissionRequests == permissionsBeforeArchive)
        reset()

        // A recording starting while the system permission dialog is open wins.
        IndependentVoiceInput.grantPermission = { workspace.hasUnfinishedRecording = true; return true }
        do { try await voice.enable(recordings: workspace); preconditionFailure("Recheck after permission") }
        catch {}
        precondition(!voice.isEnabled && !AudioSessionCoordinator.shared.isIndependentVoiceEnabled)
        reset()

        // Closing while permission is pending invalidates the activation itself.
        IndependentVoiceInput.grantPermission = { voice.disable(); return true }
        do { try await voice.enable(recordings: workspace); preconditionFailure("Closed activation must not open the mic") }
        catch {}
        precondition(!voice.isEnabled && !AudioSessionCoordinator.shared.capture)
        reset()

        // An isolated keyword receives local feedback without creating a chat
        // or model request, then grants one bounded no-keyword follow-up.
        try! await voice.enable(recordings: workspace)
        let directBefore = IndependentVoiceInput.directStarts
        IndependentVoiceInput.latest!.wakeOnly()
        await settle()
        precondition(XiaolanVoiceAcknowledgement.shared.inputs == ["我在"])
        precondition(runner.requests.isEmpty && voice.sessionID == nil && voice.lastAnswer.isEmpty)
        precondition(IndependentVoiceInput.directStarts == directBefore + 1 && !voice.isBusy)
        IndependentVoiceInput.latest!.handler?(.timeout)
        precondition(!voice.isBusy && AudioSessionCoordinator.shared.capture)
        precondition(XiaolanVoiceAcknowledgement.shared.inputs.count == 1, "Silent follow-up must not keep saying 我在")
        reset()

        // Closing or pausing during fixed local speech stops it and prevents
        // both model submission and delayed microphone reactivation.
        try! await voice.enable(recordings: workspace)
        XiaolanVoiceAcknowledgement.shared.delay = 120
        IndependentVoiceInput.latest!.command("返回")
        while XiaolanVoiceAcknowledgement.shared.inputs.isEmpty { await Task.yield() }
        voice.disable()
        await settle()
        precondition(runner.requests.isEmpty && !AudioSessionCoordinator.shared.capture && !voice.isSpeaking)
        reset()
        try! await voice.enable(recordings: workspace)
        XiaolanVoiceAcknowledgement.shared.delay = 120
        IndependentVoiceInput.latest!.wakeOnly()
        while XiaolanVoiceAcknowledgement.shared.inputs.isEmpty { await Task.yield() }
        voice.pause()
        await settle()
        precondition(voice.isPaused && !voice.isSpeaking && !AudioSessionCoordinator.shared.capture && runner.requests.isEmpty)
        reset()

        // A manual page change during the immediate acknowledgement must not
        // gain a fresh navigation binding when the model finally starts.
        try! await voice.enable(recordings: workspace)
        XiaolanVoiceAcknowledgement.shared.delay = 120
        var hadNavigationBinding = false
        runner.behavior = { _ in
            hadNavigationBinding = AppNavigationCenter.shared.binding != nil
            return .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("打开日程")
        while XiaolanVoiceAcknowledgement.shared.inputs.isEmpty { await Task.yield() }
        AppNavigationCenter.shared.state.revision += 1
        await settle()
        precondition(runner.requests.count == 1 && !hadNavigationBinding)
        let changedPageSession = voice.sessionID!
        let backgroundAfterPageChange = await AsyncTaskNoticeManager.shared.replyHooks["xiaolan_voice"]!.prepare(changedPageSession)
        precondition(backgroundAfterPageChange)
        _ = await MeetingAnswerUserTool.execute(["text": "换页后的后台完成"], sessionID: changedPageSession, sessionSource: "xiaolan_voice")
        await AsyncTaskNoticeManager.shared.replyHooks["xiaolan_voice"]!.finish(changedPageSession, .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false))
        precondition(SystemVoiceProvider.inputs.isEmpty && AVAudioPlayer.played == 0)
        reset()

        // Muting keeps the local visual acknowledgement but never plays it.
        try! await voice.enable(recordings: workspace)
        VoiceOutputPreferences.isMuted = true
        IndependentVoiceInput.latest!.wakeOnly()
        await settle()
        precondition(XiaolanVoiceAcknowledgement.shared.inputs.isEmpty && runner.requests.isEmpty && !voice.isSpeaking)
        reset()

        // Audio admission may fail after inserting the playback intent. Its
        // failed lease must be released so the next capture can still start.
        try! await voice.enable(recordings: workspace)
        AudioSessionCoordinator.shared.rejectTTS = true
        IndependentVoiceInput.latest!.wakeOnly()
        await settle()
        precondition(!AudioSessionCoordinator.shared.ttsReserved && AudioSessionCoordinator.shared.capture)
        precondition(XiaolanVoiceAcknowledgement.shared.inputs.isEmpty && runner.requests.isEmpty)
        reset()

        // Ordinary generated model text never enters public text or TTS.
        try! await voice.enable(recordings: workspace)
        IndependentVoiceInput.latest!.command("告诉我今天的安排")
        await settle()
        precondition(voice.lastAnswer.isEmpty && SystemVoiceProvider.inputs.isEmpty && AVAudioPlayer.played == 0)
        precondition(runner.requests.count == 1 && runner.requests[0].source == "xiaolan_voice")
        precondition(XiaolanVoiceAcknowledgement.shared.inputs == ["收到，开始处理"])
        let firstSession = voice.sessionID
        runner.behavior = { request in
            let answer = await MeetingAnswerUserTool.execute(["text": "已打开今天的日程。"],
                                                             sessionID: request.sessionId, sessionSource: request.source)
            precondition(answer.success)
            return .init(text: "PRIVATE_REASONING", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("打开今天的日程")
        await settle()
        precondition(voice.lastAnswer == "已打开今天的日程。" && AVAudioPlayer.played == 1)
        precondition(SystemVoiceProvider.inputs == ["已打开今天的日程。"] && voice.sessionID == firstSession)
        precondition(AppNavigationCenter.shared.binding == nil && !voice.isBusy)

        // Completing an older delegated task after manual navigation saves
        // its public answer without speaking or replacing the visible page.
        let manager = AsyncTaskNoticeManager.shared
        let preparedBackgroundReply = await manager.replyHooks["xiaolan_voice"]!.prepare(firstSession!)
        precondition(preparedBackgroundReply)
        precondition(AppNavigationCenter.shared.binding == nil, "Background completion has no navigation authority")
        AppNavigationCenter.shared.state.revision += 1
        let backgroundAnswer = await MeetingAnswerUserTool.execute(["text": "后台结果已保存。"],
                                                                   sessionID: firstSession, sessionSource: "xiaolan_voice")
        precondition(backgroundAnswer.success && voice.lastAnswer == "后台结果已保存。")
        await manager.replyHooks["xiaolan_voice"]!.finish(firstSession!, .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false))
        precondition(AVAudioPlayer.played == 1 && SystemVoiceProvider.inputs.count == 1 && !voice.isBusy)

        // The mode reservation survives pause; foreground return never resumes.
        voice.pause()
        precondition(voice.isEnabled && voice.isPaused && AudioSessionCoordinator.shared.isIndependentVoiceEnabled)
        let startsBefore = IndependentVoiceInput.starts
        voice.setForeground(false); voice.setForeground(true)
        precondition(voice.isPaused && IndependentVoiceInput.starts == startsBefore)
        try! await voice.resume(recordings: workspace)
        precondition(!voice.isPaused && voice.sessionID == firstSession)

        // A delayed model answer after pause cannot speak or regain navigation.
        var lateSuccess: Bool?
        runner.behavior = { request in
            voice.pause()
            let late = await MeetingAnswerUserTool.execute(["text": "迟到结果"], sessionID: request.sessionId, sessionSource: request.source)
            lateSuccess = late.success
            return .init(text: "PRIVATE_LATE", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("慢任务")
        await settle()
        precondition(lateSuccess == false && voice.lastAnswer != "迟到结果" && AppNavigationCenter.shared.binding == nil)
        precondition(voice.isPaused && !AudioSessionCoordinator.shared.capture)

        // An uncancellable synthesis completion cannot play after close.
        reset()
        try! await voice.enable(recordings: workspace)
        SystemVoiceProvider.delay = 120
        runner.behavior = { request in
            _ = await MeetingAnswerUserTool.execute(["text": "可见结果"], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("查询")
        while SystemVoiceProvider.inputs.isEmpty { await Task.yield() }
        voice.disable()
        await settle()
        precondition(!voice.isEnabled && !voice.isSpeaking && AVAudioPlayer.played == 0 && !AudioSessionCoordinator.shared.capture)

        // A formerly unowned/Yima-owned voice session remains historical data.
        // A later voice turn creates a new Xiaolan session instead of relinking it.
        reset()
        runner.behavior = { _ in .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false) }
        try! await voice.enable(recordings: workspace)
        IndependentVoiceInput.latest!.command("查询")
        await settle()
        let oldVoiceSession = voice.sessionID!
        ChatStore.shared.owners[oldVoiceSession] = "agent-default"
        IndependentVoiceInput.latest!.command("返回")
        await settle()
        precondition(voice.sessionID != oldVoiceSession && ChatStore.shared.sessions.contains(oldVoiceSession))
        precondition(ChatStore.shared.owners[oldVoiceSession] == "agent-default"
                     && ChatStore.shared.owners[voice.sessionID!] == XiaolanAgent.id)
        voice.disable()
        reset()
        let story = StoryPlaybackController.shared
        story.requested = true
        story.playing = true
        try! await voice.enable(recordings: workspace)
        precondition(story.playing && !story.held, "Enabling wake input preserves the existing story")
        runner.behavior = { request in
            precondition(story.held && !story.playing, "A voice request pauses stories before executing tools")
            story.requested = true
            _ = await MeetingAnswerUserTool.execute(["text": "将在回复结束后播放"], sessionID: request.sessionId, sessionSource: request.source)
            precondition(!story.playing, "Public reply must precede story playback")
            return .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false)
        }
        voice.beginCommand()
        precondition(story.held && !story.playing)
        IndependentVoiceInput.latest!.command("继续故事")
        await settle()
        precondition(story.playing && !story.held, "Story resumes after the public reply and wake input are ready")
        voice.beginCommand()
        voice.pause()
        precondition(!story.playing && !story.requested && !story.held, "Voice cancellation must discard queued playback")
        voice.disable()
        // A wake is admitted during model work. Capture keeps running while
        // old model cleanup is joined and the new command is collected.
        reset()
        try! await voice.enable(recordings: workspace)
        let oldGate = Gate(), cleanupGate = Gate()
        var cleanupFinished = false
        var oldAnswerAccepted: Bool?
        runner.behavior = { request in
            if request.prompt == "旧任务" {
                let vm = ViewModelCache.shared.get(for: request.sessionId)!
                vm.isProcessing = true
                vm.promptQueue = [.init(id: "queued-old-voice")]
                vm.messages = [.init(queuedPromptId: nil), .init(queuedPromptId: "queued-old-voice")]
                vm.currentTask = Task { await cleanupGate.wait(); cleanupFinished = true }
                await oldGate.wait() // Deliberately ignores caller cancellation.
                oldAnswerAccepted = await MeetingAnswerUserTool.execute(["text": "旧任务迟到结果"], sessionID: request.sessionId, sessionSource: request.source).success
                return .init(text: "PRIVATE_OLD", accepted: true, timedOut: false, cancelled: true)
            }
            precondition(cleanupFinished, "The next run must await actual old model cleanup")
            _ = await MeetingAnswerUserTool.execute(["text": "新指令已完成"], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: "PRIVATE_NEW", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("旧任务")
        await waitUntil { oldGate.waiting && cleanupGate.waiting }
        let busySession = voice.sessionID!
        let inputStarts = IndependentVoiceInput.starts
        let busyGeneration = voice.responseGeneration
        precondition(voice.isBusy && IndependentVoiceInput.latest!.isRunning && AudioSessionCoordinator.shared.capture)
        IndependentVoiceInput.latest!.handler?(.ready)
        precondition(voice.isBusy && StoryPlaybackController.shared.held, "A KWS readiness callback cannot finish a busy voice interaction")
        IndependentVoiceInput.latest!.wake()
        precondition(voice.responseGeneration != busyGeneration && !voice.isBusy && voice.status == "正在听指令")
        precondition(AudioSessionCoordinator.shared.capture && IndependentVoiceInput.starts == inputStarts)
        precondition(runner.cancellations.contains(busySession))
        let interruptedVM = ViewModelCache.shared.get(for: busySession)!
        precondition(interruptedVM.promptQueue.isEmpty && interruptedVM.messages.count == 1)
        IndependentVoiceInput.latest!.command("新指令")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(runner.requests.map(\.prompt) == ["旧任务"])
        oldGate.open()
        await waitUntil { oldAnswerAccepted != nil }
        precondition(oldAnswerAccepted == false && runner.requests.count == 1)
        cleanupGate.open()
        await settle()
        precondition(runner.requests.map(\.prompt) == ["旧任务", "新指令"] && voice.lastAnswer == "新指令已完成")
        precondition(voice.sessionID == busySession && IndependentVoiceInput.starts == inputStarts)

        // A runner timeout ends the voice request while model cleanup can still
        // be alive. The next wake must cancel and join that orphaned work too.
        reset()
        try! await voice.enable(recordings: workspace)
        let timedOutCleanup = Gate()
        var timedOutCleanupFinished = false
        runner.behavior = { request in
            if request.prompt == "超时任务" {
                let vm = ViewModelCache.shared.get(for: request.sessionId)!
                vm.isProcessing = true
                vm.currentTask = Task { await timedOutCleanup.wait(); timedOutCleanupFinished = true }
                return .init(text: nil, accepted: true, timedOut: true, cancelled: false)
            }
            precondition(timedOutCleanupFinished)
            _ = await MeetingAnswerUserTool.execute(["text": "超时后新指令"], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("超时任务")
        await settle()
        await waitUntil { timedOutCleanup.waiting }
        precondition(!voice.isBusy && ViewModelCache.shared.get(for: voice.sessionID!)!.isProcessing)
        let timedOutSession = voice.sessionID!
        IndependentVoiceInput.latest!.wake()
        precondition(runner.cancellations.contains(timedOutSession))
        IndependentVoiceInput.latest!.command("超时后新指令")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(runner.requests.count == 1)
        timedOutCleanup.open()
        await settle()
        precondition(runner.requests.map(\.prompt) == ["超时任务", "超时后新指令"] && voice.lastAnswer == "超时后新指令")

        // Compaction can be scheduled before its busy flag is set. Cancel its
        // saved handle explicitly and clear it before the new model admission.
        let compactVM = ViewModelCache.shared.get(for: timedOutSession)!
        var compactStarted = false, compactCancelled = false
        compactVM.compactTask = Task {
            compactStarted = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { compactCancelled = Task.isCancelled }
        }
        await waitUntil { compactStarted }
        precondition(!compactVM.isCompacting)
        IndependentVoiceInput.latest!.wake()
        IndependentVoiceInput.latest!.command("压缩后新指令")
        await settle()
        precondition(compactCancelled && compactVM.compactTask == nil)
        precondition(runner.requests.map(\.prompt) == ["超时任务", "超时后新指令", "压缩后新指令"])

        // In-loop compaction restores a running state only while it still owns
        // that state. Its real production defer must preserve cancel()'s idle
        // state and also leave a replacement queue's running state intact.
        for (runningOnEntry, cancelled, replacementRunning, expectedRunning) in [
            (false, false, false, false),
            (true, false, false, true),
            (false, true, false, false),
            (true, true, false, false),
            (true, true, true, true)
        ] {
            let vm = HostVM(), cleanup = Gate()
            let task = Task {
                await vm.runCompactionCleanup(wasProcessingOnEntry: runningOnEntry) { await cleanup.wait() }
            }
            await waitUntil { cleanup.waiting }
            if cancelled {
                task.cancel()
                vm.isProcessing = replacementRunning
            }
            cleanup.open()
            await task.value
            precondition(vm.isProcessing == expectedRunning,
                         "Compaction cleanup overwrote its cancellation/replacement owner's state")
            precondition(!vm.isCompacting && vm.compactTask == nil)
        }

        // Exercise the same production defer inside a task interrupted by the
        // real voice controller, then admit the next command after cleanup.
        let inLoopCleanup = Gate()
        compactVM.currentTask = Task {
            await compactVM.runCompactionCleanup(wasProcessingOnEntry: true) { await inLoopCleanup.wait() }
        }
        await waitUntil { inLoopCleanup.waiting }
        IndependentVoiceInput.latest!.wake()
        IndependentVoiceInput.latest!.command("执行中压缩后新指令")
        inLoopCleanup.open()
        await settle()
        precondition(runner.requests.map(\.prompt) == ["超时任务", "超时后新指令", "压缩后新指令", "执行中压缩后新指令"])

        // The acoustic wake also cuts an already audible reply immediately.
        reset()
        try! await voice.enable(recordings: workspace)
        AVAudioPlayer.playbackMilliseconds = 500
        runner.behavior = { request in
            _ = await MeetingAnswerUserTool.execute(["text": request.prompt], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("旧播报")
        await waitUntil { voice.isSpeaking && AVAudioPlayer.played == 1 }
        precondition(AudioSessionCoordinator.shared.capture && IndependentVoiceInput.latest!.isRunning)
        let speechGeneration = voice.responseGeneration
        IndependentVoiceInput.latest!.wake()
        precondition(!voice.isSpeaking && voice.responseGeneration != speechGeneration && AudioSessionCoordinator.shared.capture)
        AVAudioPlayer.playbackMilliseconds = 10
        IndependentVoiceInput.latest!.command("新播报")
        await settle()
        precondition(voice.lastAnswer == "新播报" && runner.requests.map(\.prompt) == ["旧播报", "新播报"])

        // Clicking to speak while the immediate acknowledgement is running
        // has the same priority; the old command never reaches the runner.
        reset()
        try! await voice.enable(recordings: workspace)
        XiaolanVoiceAcknowledgement.shared.delay = 120
        IndependentVoiceInput.latest!.command("旧接单")
        await waitUntil { !XiaolanVoiceAcknowledgement.shared.inputs.isEmpty }
        voice.beginCommand()
        precondition(!voice.isSpeaking && AudioSessionCoordinator.shared.capture)
        IndependentVoiceInput.latest!.command("新接单")
        await settle()
        precondition(runner.requests.map(\.prompt) == ["新接单"] && voice.lastAnswer == "新接单")

        // Locked requests use the same real Agent path, source and session as
        // foreground requests, including non-story work and public-only TTS.
        reset()
        try! await voice.enable(recordings: workspace)
        let unlockedStarts = IndependentVoiceInput.starts
        voice.setForeground(false)
        precondition(!voice.isPaused && voice.isCapturingVoice && AudioSessionCoordinator.shared.capture)
        IndependentVoiceInput.latest!.wakeOnly()
        await settle()
        precondition(XiaolanVoiceAcknowledgement.shared.inputs == ["我在"] && runner.requests.isEmpty)
        precondition(IndependentVoiceInput.starts == unlockedStarts)
        var lockedGenerations: [UInt64] = []
        runner.behavior = { request in
            precondition(request.agentId == XiaolanAgent.id && request.source == "xiaolan_voice")
            precondition(request.role == "main" && request.toolPolicy == "orchestrator")
            precondition(request.systemPromptBlock?.contains("完整智能体任务") == true)
            let generation = voice.executionGeneration(sessionID: request.sessionId)!
            lockedGenerations.append(generation)
            precondition(voice.isVoiceGenerationCurrent(sessionID: request.sessionId, generation: generation))
            precondition(voice.navigationGeneration(sessionID: request.sessionId) == nil && AppNavigationCenter.shared.binding == nil)
            let answer = await MeetingAnswerUserTool.execute(["text": "已核实：" + request.prompt],
                                                             sessionID: request.sessionId, sessionSource: request.source)
            precondition(answer.success)
            return .init(text: "PRIVATE_LOCKED_REASONING", accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("查今天的待办")
        await settle()
        let lockedSession = voice.sessionID!
        IndependentVoiceInput.latest!.wake()
        IndependentVoiceInput.latest!.command("查天气并安排子任务")
        await settle()
        precondition(runner.requests.map(\.prompt) == ["查今天的待办", "查天气并安排子任务"])
        precondition(runner.requests.allSatisfy { $0.sessionId == lockedSession })
        precondition(voice.lastAnswer == "已核实：查天气并安排子任务")
        precondition(SystemVoiceProvider.inputs == ["已核实：查今天的待办", "已核实：查天气并安排子任务"] && AVAudioPlayer.played == 2)
        precondition(voice.executionGeneration(sessionID: lockedSession) == nil,
                     "A completed turn cannot grant execution to a later stale tool")
        precondition(IndependentVoiceInput.starts == unlockedStarts && voice.isCapturingVoice)

        // A delegated result is delivered and spoken while locked even when
        // the UI's availability revision changed. It never gains navigation.
        AppNavigationCenter.shared.state.revision += 1
        let lockedNoticePrepared = await manager.replyHooks["xiaolan_voice"]!.prepare(lockedSession)
        precondition(lockedNoticePrepared && AppNavigationCenter.shared.binding == nil)
        let lockedNoticeAnswer = await MeetingAnswerUserTool.execute(["text": "子任务已完成并核实。"],
                                                                     sessionID: lockedSession, sessionSource: "xiaolan_voice")
        precondition(lockedNoticeAnswer.success)
        await manager.replyHooks["xiaolan_voice"]!.finish(lockedSession, .init(text: "PRIVATE", accepted: true, timedOut: false, cancelled: false))
        precondition(SystemVoiceProvider.inputs.last == "子任务已完成并核实。" && AVAudioPlayer.played == 3)
        precondition(!voice.isBusy && voice.isCapturingVoice && AppNavigationCenter.shared.binding == nil)

        // Unlocking during capture/ASR keeps full execution, while the captured
        // background utterance still cannot acquire UI authority on return.
        for unlockDuringASR in [false, true] {
            reset()
            try! await voice.enable(recordings: workspace)
            if unlockDuringASR {
                voice.setForeground(false)
                IndependentVoiceInput.latest!.wake()
                IndependentVoiceInput.latest!.handler?(.transcribing)
                voice.setForeground(true)
            } else {
                IndependentVoiceInput.latest!.wake()
                voice.setForeground(false)
                voice.setForeground(true)
            }
            var executionWasCurrent = false
            runner.behavior = { request in
                executionWasCurrent = voice.executionGeneration(sessionID: request.sessionId) != nil
                precondition(voice.navigationGeneration(sessionID: request.sessionId) == nil)
                precondition(AppNavigationCenter.shared.binding == nil)
                return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
            }
            IndependentVoiceInput.latest!.command("查我的安排")
            await settle()
            precondition(executionWasCurrent && runner.requests.map(\.prompt) == ["查我的安排"])
            runner.behavior = { request in
                precondition(voice.navigationGeneration(sessionID: request.sessionId) != nil)
                precondition(AppNavigationCenter.shared.binding != nil)
                return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
            }
            IndependentVoiceInput.latest!.wake()
            IndependentVoiceInput.latest!.command("新的前台指令")
            await settle()
            precondition(runner.requests.count == 2)
        }

        // A background wake-only grants direct follow-up execution, but its UI
        // restriction survives unlocking before the acknowledgement finishes.
        reset()
        try! await voice.enable(recordings: workspace)
        voice.setForeground(false)
        XiaolanVoiceAcknowledgement.shared.delay = 120
        IndependentVoiceInput.latest!.wake()
        IndependentVoiceInput.latest!.wakeOnly()
        await waitUntil { !XiaolanVoiceAcknowledgement.shared.inputs.isEmpty }
        voice.setForeground(true)
        await settle()
        XiaolanVoiceAcknowledgement.shared.delay = 10
        runner.behavior = { request in
            precondition(voice.executionGeneration(sessionID: request.sessionId) != nil)
            precondition(voice.navigationGeneration(sessionID: request.sessionId) == nil)
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("查天气")
        await settle()
        precondition(runner.requests.map(\.prompt) == ["查天气"])
        runner.behavior = { request in
            precondition(voice.navigationGeneration(sessionID: request.sessionId) != nil)
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        voice.beginCommand()
        IndependentVoiceInput.latest!.command("点击发起的前台指令")
        await settle()
        precondition(runner.requests.count == 2)

        // Locking an executing foreground Agent preserves its task, generation
        // and reply, while immediately revoking the old navigation binding.
        reset()
        try! await voice.enable(recordings: workspace)
        let foregroundGate = Gate()
        var continuedReplyAccepted: Bool?
        runner.behavior = { request in
            await foregroundGate.wait()
            precondition(voice.executionGeneration(sessionID: request.sessionId) != nil)
            precondition(voice.navigationGeneration(sessionID: request.sessionId) == nil)
            continuedReplyAccepted = await MeetingAnswerUserTool.execute(["text": "熄屏后任务已完成。"],
                                                                         sessionID: request.sessionId, sessionSource: request.source).success
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("前台开始的任务")
        await waitUntil { foregroundGate.waiting }
        let transitionGeneration = voice.responseGeneration
        let transitionStarts = IndependentVoiceInput.starts
        voice.setForeground(false)
        AppNavigationCenter.shared.state.revision += 1
        precondition(voice.isBusy && voice.responseGeneration == transitionGeneration && runner.cancellations.isEmpty)
        precondition(AppNavigationCenter.shared.binding == nil && voice.isCapturingVoice)
        foregroundGate.open()
        await settle()
        precondition(continuedReplyAccepted == true && voice.lastAnswer == "熄屏后任务已完成。")
        precondition(SystemVoiceProvider.inputs == ["熄屏后任务已完成。"] && AVAudioPlayer.played == 1)
        precondition(IndependentVoiceInput.starts == transitionStarts)

        // A timed-out model is not cancelled simply by locking. The next
        // actual wake still cancels and joins its real cleanup before admission.
        reset()
        try! await voice.enable(recordings: workspace)
        let orphanCleanup = Gate()
        runner.behavior = { request in
            let vm = ViewModelCache.shared.get(for: request.sessionId)!
            vm.isProcessing = true
            vm.currentTask = Task { await orphanCleanup.wait() }
            return .init(text: nil, accepted: true, timedOut: true, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("切后台前已超时")
        await settle()
        await waitUntil { orphanCleanup.waiting }
        let orphanSession = voice.sessionID!
        voice.setForeground(false)
        precondition(runner.cancellations.isEmpty && voice.isCapturingVoice)
        IndependentVoiceInput.latest!.wake()
        precondition(runner.cancellations.contains(orphanSession))
        runner.behavior = { request in
            _ = await MeetingAnswerUserTool.execute(["text": "新任务完成。"], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("锁屏时的新任务")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(runner.requests.count == 1)
        orphanCleanup.open()
        await settle()
        precondition(runner.requests.map(\.prompt) == ["切后台前已超时", "锁屏时的新任务"] && voice.lastAnswer == "新任务完成。")

        // Background wake interrupts an in-flight full Agent and rejects its
        // late answer. No new run starts until actual old cleanup is finished.
        reset()
        try! await voice.enable(recordings: workspace)
        voice.setForeground(false)
        let backgroundGate = Gate()
        var supersededReplyAccepted: Bool?
        runner.behavior = { request in
            if request.prompt == "旧后台任务" {
                await backgroundGate.wait()
                supersededReplyAccepted = await MeetingAnswerUserTool.execute(["text": "过期后台结果"],
                                                                             sessionID: request.sessionId, sessionSource: request.source).success
                return .init(text: nil, accepted: true, timedOut: false, cancelled: true)
            }
            _ = await MeetingAnswerUserTool.execute(["text": "新后台结果"], sessionID: request.sessionId, sessionSource: request.source)
            return .init(text: nil, accepted: true, timedOut: false, cancelled: false)
        }
        IndependentVoiceInput.latest!.command("旧后台任务")
        await waitUntil { backgroundGate.waiting }
        let oldBackgroundGeneration = voice.responseGeneration
        IndependentVoiceInput.latest!.wake()
        IndependentVoiceInput.latest!.command("新后台任务")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(voice.responseGeneration != oldBackgroundGeneration && runner.requests.count == 1)
        backgroundGate.open()
        await settle()
        precondition(supersededReplyAccepted == false && voice.lastAnswer == "新后台结果")
        precondition(runner.requests.map(\.prompt) == ["旧后台任务", "新后台任务"] && voice.isCapturingVoice)
        let pausedSession = voice.sessionID!
        voice.pause()
        precondition(voice.isPaused && !voice.isCapturingVoice && !AudioSessionCoordinator.shared.capture)
        precondition(AudioSessionCoordinator.shared.isIndependentVoiceEnabled)
        precondition(voice.executionGeneration(sessionID: pausedSession) == nil)
        let pausedNotice = await manager.replyHooks["xiaolan_voice"]!.prepare(pausedSession)
        precondition(!pausedNotice)
        IndependentVoiceInput.latest!.command("暂停后不能接收")
        await settle()
        precondition(runner.requests.count == 2)
        do { try await voice.resume(recordings: workspace); preconditionFailure("Background resume must remain explicit foreground action") }
        catch {}
        precondition(voice.isPaused)
        voice.setForeground(true)
        precondition(voice.isPaused)
        try! await voice.resume(recordings: workspace)
        voice.setForeground(false)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { voice.isPaused }
        precondition(!voice.isCapturingVoice && !AudioSessionCoordinator.shared.capture
                     && AudioSessionCoordinator.shared.isIndependentVoiceEnabled)
        voice.disable()
        print("PASS: full Agent execution, public answers and delegated replies work across lock/background with one microphone; UI authority, recording exclusion, wake priority and stale-callback rejection remain enforced")
    }
}
