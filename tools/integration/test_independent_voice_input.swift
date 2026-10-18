import Foundation

enum TranscriptionModelStore {
    static var isReady: Bool { true }
    static func modelURL(id: String) throws -> URL { URL(fileURLWithPath: "/test-models/" + id) }
}
enum MeetingWakeModelResources { static var isReady: Bool { true } }
enum MicrophoneAccess {
    enum Permission { case granted }
    static func requestPermissionIfNeeded() async -> Permission { .granted }
}
actor SenseVoiceInferenceService {
    struct Result { let text: String }
    var text = ""
    var holdNext = false
    private var pending: CheckedContinuation<Result, Error>?
    var hasPending: Bool { pending != nil }
    func configure(text: String, hold: Bool = false) { self.text = text; holdNext = hold }
    func transcribe(samples: [Float], startingAt: Int64) async throws -> Result {
        if holdNext {
            holdNext = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return Result(text: text)
    }
    func release(text: String) { let callback = pending; pending = nil; callback?.resume(returning: .init(text: text)) }
    func reject() {
        let callback = pending
        pending = nil
        callback?.resume(throwing: NSError(domain: "TestASR", code: 1))
    }
}
nonisolated final class MeetingWakeAudioWorker: @unchecked Sendable {
    struct Wake: Sendable { let generationID: UUID }
    struct Command: Sendable {
        let generationID: UUID
        let samples: [Float]
        let startSample: Int64
        let endSample: Int64
    }
    struct Activation: Sendable {
        let generation: UUID
        let afterSample: Int64
        let command: @Sendable (Command) -> Void
        let wake: @Sendable (Wake) -> Void
        let timeout: @Sendable () -> Void
        let error: @Sendable (String, Bool) -> Void
        let wakeRequired: Bool
        let finishOnSilence: Bool
        func finish(endSample: Int64? = nil) {
            command(.init(generationID: generation, samples: [1], startSample: afterSample,
                          endSample: endSample ?? afterSample + 16_000))
        }
        func hearWake() { wake(.init(generationID: generation)) }
    }
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        private var activation: Activation?
        var latest: Activation? { get { lock.withLock { activation } } set { lock.withLock { activation = newValue } } }
    }
    static let registry = Registry()
    func activate(generationID: UUID, afterSample: Int64, requiresWakeWord: Bool, finishOnSilence: Bool,
                  onReady: @escaping @Sendable () -> Void, onWake: @escaping @Sendable (Wake) -> Void,
                  onCommand: @escaping @Sendable (Command) -> Void, onTimeout: @escaping @Sendable () -> Void,
                  onError: @escaping @Sendable (String, Bool) -> Void) {
        Self.registry.latest = Activation(generation: generationID, afterSample: afterSample,
                                          command: onCommand, wake: onWake, timeout: onTimeout, error: onError,
                                          wakeRequired: requiresWakeWord, finishOnSilence: finishOnSilence)
        onReady()
    }
    func deactivate() {}
    func enqueue(samples: [Float], startSample: Int64) {}
}
nonisolated final class IndependentMicrophone: @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        private var started = 0
        private var stopped = 0
        private var failureCallback: (@Sendable () -> Void)?
        private var cursor: Int64 = 0
        var counts: (starts: Int, stops: Int) { lock.withLock { (started, stopped) } }
        var currentSampleCursor: Int64 { get { lock.withLock { cursor } } set { lock.withLock { cursor = newValue } } }
        var failure: (@Sendable () -> Void)? { lock.withLock { failureCallback } }
        func start(failure: @escaping @Sendable () -> Void) {
            lock.withLock { started += 1; failureCallback = failure }
        }
        func stop() { lock.withLock { stopped += 1 } }
    }
    static let registry = Registry()
    var currentSampleCursor: Int64 { Self.registry.currentSampleCursor }
    func start(samples: @escaping @Sendable ([Float], Int64) -> Void, failure: @escaping @Sendable () -> Void) throws {
        Self.registry.start(failure: failure)
    }
    func stop() { Self.registry.stop() }
}

@main struct IndependentInputChecks {
    @MainActor static func main() async {
        let asr = SenseVoiceInferenceService()
        let input = IndependentVoiceInput(inferenceService: asr)
        var events: [String] = []
        func collect(_ event: IndependentVoiceInput.Event) {
            switch event {
            case .ready: events.append("ready")
            case .listening: events.append("listening")
            case .transcribing: events.append("transcribing")
            case .wakeOnly: events.append("wakeOnly")
            case .command(let text): events.append("command:" + text)
            case .timeout: events.append("timeout")
            case .failure: events.append("failure")
            }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
        for (text, expected, direct) in [
            ("小蓝同学。", "wakeOnly", false),
            ("小兰同学", "wakeOnly", false),
            ("小蓝同学，回", "command:回", false),
            ("小蓝同学停", "command:停", false),
            ("小蓝同学，打开今天的日程", "command:打开今天的日程", false),
            ("，。 ", "failure", false),
            ("小蓝同学", "wakeOnly", true),
            ("返回", "command:返回", true)
        ] {
            await asr.configure(text: text)
            events = []
            try! input.start(direct: direct, onEvent: collect)
            let activation = MeetingWakeAudioWorker.registry.latest!
            precondition(activation.finishOnSilence && activation.wakeRequired == !direct)
            activation.finish()
            await settle()
            precondition(events.last == expected, "\(text): \(events)")
            precondition(events.filter { $0 == expected }.count == 1)
            precondition(input.isRunning, "ASR completion must keep the microphone running")
            let rearmed = MeetingWakeAudioWorker.registry.latest!
            precondition(rearmed.generation != activation.generation && rearmed.afterSample == 16_000)
            precondition(rearmed.wakeRequired, "Direct collection must rearm with the keyword required")
            precondition(events.filter { $0 == "ready" }.count == (direct ? 0 : 1), "Rearming must not emit ready")
        }
        events = []
        try! input.start(direct: true, onEvent: collect)
        let timeoutMicrophoneCounts = IndependentMicrophone.registry.counts
        MeetingWakeAudioWorker.registry.latest!.timeout()
        await settle()
        precondition(events.contains("timeout") && !events.contains("wakeOnly"), "A silent direct tap has no wake-only authorization")
        precondition(MeetingWakeAudioWorker.registry.latest!.wakeRequired)
        precondition(IndependentMicrophone.registry.counts == timeoutMicrophoneCounts)

        // A single microphone remains open for consecutive wake/command rounds.
        // While ASR ignores cancellation, the next acoustic wake still wins.
        events = []
        await asr.configure(text: "unused", hold: true)
        try! input.start(onEvent: collect)
        await settle()
        let microphoneCounts = IndependentMicrophone.registry.counts
        let first = MeetingWakeAudioWorker.registry.latest!
        first.hearWake()
        first.finish(endSample: 32_000)
        while !(await asr.hasPending) { await Task.yield() }
        let second = MeetingWakeAudioWorker.registry.latest!
        precondition(second.afterSample == 32_000)
        let beforeWake = events.count
        second.hearWake()
        await settle()
        precondition(events.count == beforeWake + 1 && events.last == "listening",
                     "A new wake must interrupt ASR before the old request returns")
        await asr.configure(text: "小蓝同学，暂停故事")
        second.finish(endSample: 64_000)
        await settle()
        precondition(events.last == "command:暂停故事")
        let deliveredWhileOldASRPending = events
        await asr.release(text: "小蓝同学，播放旧故事")
        first.hearWake()
        first.finish()
        first.timeout()
        first.error("stale error", true)
        await settle()
        precondition(events == deliveredWhileOldASRPending && input.isRunning,
                     "Superseded ASR and capture callbacks must be ignored")
        let third = MeetingWakeAudioWorker.registry.latest!
        precondition(third.afterSample == 64_000 && third.wakeRequired)
        await asr.configure(text: "小蓝同学，换一个故事")
        third.hearWake()
        third.finish(endSample: 96_000)
        await settle()
        precondition(events.last == "command:换一个故事")
        precondition(MeetingWakeAudioWorker.registry.latest!.afterSample == 96_000)
        precondition(IndependentMicrophone.registry.counts == microphoneCounts,
                     "Consecutive commands and ASR must never restart or stop the microphone")
        precondition(events.filter { $0 == "ready" }.count == 1)

        // A wake-only follow-up or tap uses the current cursor without ever
        // reopening capture, which would not be allowed after locking iOS.
        IndependentMicrophone.registry.currentSampleCursor = 112_000
        input.beginCommand()
        await settle()
        let directFollowUp = MeetingWakeAudioWorker.registry.latest!
        precondition(!directFollowUp.wakeRequired && directFollowUp.afterSample == 112_000)
        precondition(events.last == "listening")
        precondition(IndependentMicrophone.registry.counts == microphoneCounts)
        await asr.configure(text: "继续播放")
        directFollowUp.finish(endSample: 128_000)
        await settle()
        precondition(events.last == "command:继续播放")
        precondition(MeetingWakeAudioWorker.registry.latest!.wakeRequired)
        precondition(IndependentMicrophone.registry.counts == microphoneCounts)
        input.beginCommand()
        await settle()
        MeetingWakeAudioWorker.registry.latest!.timeout()
        await settle()
        precondition(events.last == "timeout" && MeetingWakeAudioWorker.registry.latest!.wakeRequired,
                     "In-place direct follow-up timeout must restore keyword detection itself")
        precondition(IndependentMicrophone.registry.counts == microphoneCounts)

        // Backends can throw a non-cancellation error after their request was
        // superseded. That error must not terminate the new listening turn.
        await asr.configure(text: "unused", hold: true)
        MeetingWakeAudioWorker.registry.latest!.finish()
        while !(await asr.hasPending) { await Task.yield() }
        MeetingWakeAudioWorker.registry.latest!.hearWake()
        await settle()
        let beforeStaleFailure = events
        await asr.reject()
        await settle()
        precondition(events == beforeStaleFailure && events.last == "listening")

        // A superseded generation cannot deliver its queued PCM/ASR result
        // into a newly opened input, even if ASR ignores task cancellation.
        events = []
        await asr.configure(text: "小蓝同学", hold: true)
        try! input.start(onEvent: collect)
        let old = MeetingWakeAudioWorker.registry.latest!
        old.finish()
        while !(await asr.hasPending) { await Task.yield() }
        let stoppedCapture = MeetingWakeAudioWorker.registry.latest!
        let stoppedMicrophoneFailure = IndependentMicrophone.registry.failure!
        input.stop()
        precondition(!input.isRunning)
        let stoppedMicrophoneCounts = IndependentMicrophone.registry.counts
        input.beginCommand()
        precondition(!input.isRunning && IndependentMicrophone.registry.counts == stoppedMicrophoneCounts)
        let stoppedEvents = events
        stoppedCapture.hearWake()
        stoppedCapture.finish()
        stoppedCapture.timeout()
        stoppedCapture.error("stale error", true)
        stoppedMicrophoneFailure()
        await settle()
        precondition(events == stoppedEvents, "Stopping input must reject every late capture callback")
        await asr.release(text: "小蓝同学，停止前的旧指令")
        await settle()
        precondition(events == stoppedEvents, "Stopping input must reject a late ASR result before any restart")
        await asr.configure(text: "unused", hold: true)
        try! input.start(onEvent: collect)
        MeetingWakeAudioWorker.registry.latest!.finish()
        while !(await asr.hasPending) { await Task.yield() }
        input.stop()
        await asr.configure(text: "小蓝同学，打开日程")
        events = []
        try! input.start(onEvent: collect)
        MeetingWakeAudioWorker.registry.latest!.finish()
        await settle()
        let delivered = events
        await asr.release(text: "小蓝同学")
        old.finish()
        await settle()
        precondition(events == delivered && events.last == "command:打开日程" && !events.contains("wakeOnly"))
        MeetingWakeAudioWorker.registry.latest!.error("fatal", true)
        await settle()
        precondition(!input.isRunning && events.last == "failure", "Fatal failures must close input before delivery")
        input.stop()
        print("PASS: independent input keeps one microphone across command rounds, rearms from continuous PCM offsets, interrupts in-flight ASR on wake, preserves command classification, and rejects every stale capture/ASR callback")
    }
}
