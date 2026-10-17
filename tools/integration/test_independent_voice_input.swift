import Foundation

enum TranscriptionModelStore { static var isReady: Bool { true } }
enum MeetingWakeModelResources { static var isReady: Bool { true } }
enum MicrophoneAccess {
    enum Permission { case granted }
    static func requestPermissionIfNeeded() async -> Permission { .granted }
}
actor SenseVoiceInferenceService {
    struct Result { let text: String }
    var text = ""
    var holdNext = false
    private var pending: CheckedContinuation<Result, Never>?
    var hasPending: Bool { pending != nil }
    func configure(text: String, hold: Bool = false) { self.text = text; holdNext = hold }
    func transcribe(samples: [Float], startingAt: Int64, waitForMetal: Bool) async throws -> Result {
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { pending = $0 }
        }
        return Result(text: text)
    }
    func release(text: String) { let callback = pending; pending = nil; callback?.resume(returning: .init(text: text)) }
}
nonisolated final class MeetingWakeAudioWorker: @unchecked Sendable {
    struct Wake: Sendable { let generationID: UUID }
    struct Command: Sendable {
        let generationID: UUID
        let samples: [Float]
        let startSample: Int64
    }
    struct Activation: Sendable {
        let generation: UUID
        let command: @Sendable (Command) -> Void
        let timeout: @Sendable () -> Void
        let wakeRequired: Bool
        let finishOnSilence: Bool
        func finish() { command(.init(generationID: generation, samples: [1], startSample: 0)) }
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
        Self.registry.latest = Activation(generation: generationID, command: onCommand, timeout: onTimeout,
                                          wakeRequired: requiresWakeWord, finishOnSilence: finishOnSilence)
        onReady()
    }
    func deactivate() {}
    func enqueue(samples: [Float], startSample: Int64) {}
}
nonisolated final class IndependentMicrophone: @unchecked Sendable {
    func start(samples: @escaping @Sendable ([Float], Int64) -> Void, failure: @escaping @Sendable () -> Void) throws {}
    func stop() {}
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
        }
        events = []
        try! input.start(direct: true, onEvent: collect)
        MeetingWakeAudioWorker.registry.latest!.timeout()
        await settle()
        precondition(events.contains("timeout") && !events.contains("wakeOnly"), "A silent direct tap has no wake-only authorization")

        // A superseded generation cannot deliver its queued PCM/ASR result
        // into a newly opened input, even if ASR ignores task cancellation.
        events = []
        await asr.configure(text: "小蓝同学", hold: true)
        try! input.start(onEvent: collect)
        let old = MeetingWakeAudioWorker.registry.latest!
        old.finish()
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
        input.stop()
        print("PASS: production independent input classifies wake-only/short commands/empty ASR, opts into utterance endpoints, keeps silent taps quiet, and rejects stale PCM/ASR generations")
    }
}
