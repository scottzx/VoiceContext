import Foundation

typealias AVAudioChannelCount = UInt32
nonisolated enum TranscriptionLanguageMode: Sendable {
    case `default`
    var senseVoiceLanguageHint: String? { nil }
}
nonisolated enum TranscriptionModelStore {
    static func requiredResourceRoot() throws -> URL { URL(fileURLWithPath: "/test-models") }
}
nonisolated struct AudioInputMetrics {
    let rmsDecibels: Float = -20
    let peakDecibels: Float = -10
    static func from(samples: [Float]) -> Self { .init() }
}
nonisolated enum SpeakerEmbeddingResult { case unavailable(reason: String) }
nonisolated struct OfflineSpeakerObservation {}
nonisolated enum AACSegmentRecorder { static let targetSampleRate: Double = 16_000 }
nonisolated enum ASRSentenceSegmenter {
    struct Token: Sendable { let text: String; let startMilliseconds: Int64; let endMilliseconds: Int64 }
    static func split(tokens: [Token], fallbackText: String, fallbackDurationMilliseconds: Int64) -> [Token] {
        [.init(text: fallbackText, startMilliseconds: 0, endMilliseconds: fallbackDurationMilliseconds)]
    }
}
nonisolated enum PCM16KMonoLoader {
    static func samples(from url: URL) throws -> [Float] { preconditionFailure("Commands must stay in memory") }
}
actor SpeechAnalysisService {
    enum AnalysisPurpose { case transcription }
    enum AnalysisError: Error { case noSpeechDetected(AudioInputMetrics) }
    struct Span { let endSample: Int64 }
    struct Utterance {
        let samples: [Float]
        let startSample: Int64
        var endSample: Int64 { startSample + Int64(samples.count) }
        var duration: Double { Double(samples.count) / 16_000 }
    }
    struct Result {
        let utterances: [Utterance]
        let spans: [Span]
        let voicedDuration: Double
        let vadMilliseconds: Double = 0
    }
    static let hardMaximumUtteranceSamples = 400_000
    func analyze(samples: [Float], resourceRoot: URL, startingAt: Int64, purpose: AnalysisPurpose) throws -> Result {
        .init(utterances: [.init(samples: samples, startSample: startingAt)],
              spans: [.init(endSample: startingAt + Int64(samples.count))],
              voicedDuration: Double(samples.count) / 16_000)
    }
}

// Only the native model boundary is replaced. The production lifecycle gate,
// CPU queue, cancellation handler and full transcribe orchestration run below.
nonisolated final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}
nonisolated enum TranscribeError: Error { case aborted }
nonisolated enum Backend: String, Sendable { case cpu, metal }
nonisolated struct ModelOptions { let backend: Backend }
nonisolated struct RunOptions { enum Itn { case on }; let itn: Itn; let language: String? }
nonisolated struct Transcript {
    enum TimestampKind { case none, token }
    struct Token { let text: String; let t0Ms: Int64; let t1Ms: Int64 }
    struct Timings { let melMs: Float = 1; let encodeMs: Float = 1; let decodeMs: Float = 1; let loadMs: Float = 1 }
    let text = "继续播放"
    let rawText = "继续播放"
    let language: String? = "zh"
    let timestampKind = TimestampKind.none
    let tokens: [Token] = []
    let timings = Timings()
}
nonisolated final class NativeProbe: @unchecked Sendable {
    static let shared = NativeProbe()
    private let lock = NSLock()
    private var held = false
    private var started = 0
    private var active = 0
    private var peak = 0
    private var backends: [Backend] = []
    var snapshot: (started: Int, active: Int, peak: Int, backends: [Backend]) {
        lock.withLock { (started, active, peak, backends) }
    }
    func hold(_ value: Bool) { lock.withLock { held = value } }
    func run(backend: Backend, cancellation: CancellationToken) throws -> Transcript {
        lock.withLock { started += 1; active += 1; peak = max(peak, active); backends.append(backend) }
        defer { lock.withLock { active -= 1 } }
        while lock.withLock({ held }) {
            if cancellation.isCancelled { throw TranscribeError.aborted }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if cancellation.isCancelled { throw TranscribeError.aborted }
        return .init()
    }
}
nonisolated final class Model: @unchecked Sendable {
    let backend: String
    init(path: String, options: ModelOptions) throws { backend = options.backend.rawValue }
    func session() throws -> Session { Session(backend: Backend(rawValue: backend)!) }
}
nonisolated final class Session {
    let backend: Backend
    var cancellation = CancellationToken()
    init(backend: Backend) { self.backend = backend }
    func setCancellationToken(_ token: CancellationToken) { cancellation = token }
    func run(_ samples: [Float], options: RunOptions) throws -> Transcript {
        try NativeProbe.shared.run(backend: backend, cancellation: cancellation)
    }
}

@main struct IndependentCommandASRChecks {
    static func main() async throws {
        let recordingGate = InferenceLifecycleGate()
        let recording = SenseVoiceInferenceService(lifecycleGate: recordingGate)
        let commandGate = InferenceLifecycleGate()
        let command = SenseVoiceInferenceService(lifecycleGate: commandGate, execution: .independentVoiceCommand)
        let samples = Array(repeating: Float(0.5), count: 1_600)
        _ = await recording.enteredBackground()
        _ = await command.enteredBackground()
        let cpu = try await command.transcribe(samples: samples, startingAt: 0)
        precondition(cpu.text == "继续播放" && cpu.backend == "cpu")
        precondition(cpu.submittedMetalWork == 0)
        let commandMetrics = await commandGate.metrics()
        precondition(!commandMetrics.acceptsMetalWork && commandMetrics.submittedMetalWork == 0,
                     "CPU commands must not reopen or submit work to the background Metal gate")
        do {
            _ = try await recording.transcribe(samples: samples, startingAt: 0, waitForMetal: true)
            preconditionFailure("Recording ASR must still reject background Metal work")
        } catch InferenceLifecycleGate.Rejection.appIsBackgrounded {}
        await recording.enteredForeground()
        let metal = try await recording.transcribe(samples: samples, startingAt: 0)
        precondition(metal.backend == "metal" && metal.submittedMetalWork == 1)

        NativeProbe.shared.hold(true)
        let startedBefore = NativeProbe.shared.snapshot.started
        let old = Task { try await command.transcribe(samples: samples, startingAt: 1_600) }
        for _ in 0..<1_000 {
            if NativeProbe.shared.snapshot.started > startedBefore { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(NativeProbe.shared.snapshot.active == 1)
        let next = Task { try await command.transcribe(samples: samples, startingAt: 3_200) }
        try await Task.sleep(for: .milliseconds(20))
        precondition(NativeProbe.shared.snapshot.started == startedBefore + 1,
                     "A second command must wait for the previous native CPU run")
        old.cancel()
        do { _ = try await old.value; preconditionFailure("Native CPU inference must observe cancellation") }
        catch is CancellationError {}
        NativeProbe.shared.hold(false)
        let latest = try await next.value
        precondition(latest.backend == "cpu", "New requests must have a fresh native cancellation token")
        precondition(NativeProbe.shared.snapshot.peak == 1, "CPU commands must execute serially")
        print("PASS: production command ASR selects CPU with the Metal gate closed, preserves recording Metal admission, cancels native work and gives each request a fresh token")
    }
}
