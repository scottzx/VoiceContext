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
    var isPlaying = false
    init(data: Data) throws {}
    func prepareToPlay() {}
    func play() -> Bool {
        Self.played += 1
        isPlaying = true
        Task { try? await Task.sleep(for: .milliseconds(10)); isPlaying = false }
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
        precondition(!AudioSessionCoordinator.shared.capture, "Fixed feedback must not enter microphone input")
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
    static func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        return await grantPermission()
    }
    func start(direct: Bool = false, onEvent: @escaping @MainActor (Event) -> Void) throws {
        Self.starts += 1
        if direct { Self.directStarts += 1 }
        Self.latest = self
        handler = onEvent
        onEvent(direct ? .listening : .ready)
    }
    func stop() { handler = nil }
    func command(_ text: String) { handler?(.transcribing); handler?(.command(text)) }
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
        if intent == .xiaolanTTS { ttsReserved = true; capture = false; return isIndependentVoiceEnabled && !rejectTTS }
        capture = isIndependentVoiceEnabled && !ttsReserved
        return capture
    }
    func end(_ intent: Intent) {
        if intent == .xiaolanCapture { capture = false }
        else { ttsReserved = false }
    }
}
enum MeetingAssistantController { static var reason: String?; static func modelUnavailableReason() -> String? { reason } }
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
    var isProcessing = false, isCompacting = false, postCompactDrainPending = false
    var compactTask: Task<Void, Never>?
    var promptQueue: [String] = []
    func loadSession() async {}
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    var models: [String: HostVM] = [:]
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
}

@main struct XiaolanVoiceChecks {
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
        func reset() {
            voice.disable(); voice.setForeground(true)
            workspace.hasUnfinishedRecording = false
            IndependentVoiceInput.grantPermission = { true }
            SystemVoiceProvider.delay = 0
            SystemVoiceProvider.inputs = []
            AVAudioPlayer.played = 0
            VoiceOutputPreferences.isMuted = false
            runner.requests = []
            XiaolanAgent.failure = nil
            XiaolanVoiceAcknowledgement.shared.inputs = []
            XiaolanVoiceAcknowledgement.shared.delay = 10
            AudioSessionCoordinator.shared.rejectTTS = false
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
        print("PASS: independent voice gates unfinished recordings and permission races, reuses sessions, speaks only public tool answers, and rejects late mic/model/TTS callbacks after pause/close")
    }
}
