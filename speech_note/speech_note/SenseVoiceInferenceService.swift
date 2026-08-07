@preconcurrency import AVFoundation
import CTranscribe
import Darwin
import Foundation

actor SenseVoiceInferenceService {
    struct Result: Sendable {
        let text: String
        let backend: String
        let audioDuration: TimeInterval
        let utteranceDuration: TimeInterval
        let voicedDuration: TimeInterval
        let loadMilliseconds: Float
        let inferenceMilliseconds: Float
        let realtimeFactor: Double
        let inputPowerDecibels: Float
        let inputPeakDecibels: Float
        let speechSpanCount: Int
        let utteranceCount: Int
        let vadMilliseconds: Double
        let speakerEmbedding: SpeakerEmbeddingResult
        let embeddingDimension: Int?
        let embeddingRawNorm: Float?
        let embeddingNorm: Float?
        let embeddingMilliseconds: Double
        let physicalFootprintBytes: UInt64
        let thermalState: String
        let submittedMetalWork: Int
    }

    enum InferenceError: LocalizedError {
        case invalidPCMFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case runtime(String)
        case abortedForBackground

        var errorDescription: String? {
            switch self {
            case let .invalidPCMFormat(sampleRate, channels):
                "转写输入必须是 16 kHz 单声道 PCM（收到 \(sampleRate) Hz / \(channels) 声道）。"
            case let .runtime(message):
                "SenseVoice 运行失败：\(message)"
            case .abortedForBackground:
                "App 进入后台，已停止尚未完成的转写。"
            }
        }
    }

    private let lifecycleGate = InferenceLifecycleGate()
    private let cancellation = InferenceCancellationFlag()
    private let speechAnalysis = SpeechAnalysisService()

    struct BackgroundGateProbe: Sendable {
        let rejected: Bool
        let submissionsBefore: Int
        let submissionsAfter: Int
    }

    func enteredBackground() async -> BackgroundGateProbe {
        cancellation.requestAbort()
        await lifecycleGate.enteredBackground()

        let before = await lifecycleGate.metrics().submittedMetalWork
        let rejected: Bool
        do {
            try await lifecycleGate.beginMetalWork()
            rejected = false
        } catch InferenceLifecycleGate.Rejection.appIsBackgrounded {
            rejected = true
        } catch {
            rejected = false
        }
        let after = await lifecycleGate.metrics().submittedMetalWork
        return BackgroundGateProbe(
            rejected: rejected,
            submissionsBefore: before,
            submissionsAfter: after
        )
    }

    func enteredForeground() async {
        cancellation.clearAbort()
        await lifecycleGate.enteredForeground()
    }

    func transcribe(recordingURL: URL) async throws -> Result {
        let samples = try PCM16KMonoLoader.samples(from: recordingURL)
        let inputMetrics = AudioInputMetrics.from(samples: samples)
        let resourceRoot = try bundledModelResourceRoot()
        let analysis = try await speechAnalysis.analyze(samples: samples, resourceRoot: resourceRoot)
        try await lifecycleGate.beginMetalWork()
        cancellation.clearAbort()
        let result = try await Task.detached(priority: .userInitiated) { [cancellation] in
            try Self.run(samples: samples, resourceRoot: resourceRoot, cancellation: cancellation)
        }.value

        let metrics = await lifecycleGate.metrics()
        return Result(
            text: result.text,
            backend: result.backend,
            audioDuration: Double(samples.count) / 16_000,
            utteranceDuration: analysis.utterances.reduce(0) { $0 + $1.duration },
            voicedDuration: analysis.voicedDuration,
            loadMilliseconds: result.loadMilliseconds,
            inferenceMilliseconds: result.inferenceMilliseconds,
            realtimeFactor: result.realtimeFactor,
            inputPowerDecibels: inputMetrics.rmsDecibels,
            inputPeakDecibels: inputMetrics.peakDecibels,
            speechSpanCount: analysis.spans.count,
            utteranceCount: analysis.utterances.count,
            vadMilliseconds: analysis.vadMilliseconds,
            speakerEmbedding: analysis.speakerEmbedding,
            embeddingDimension: analysis.embeddingDimension,
            embeddingRawNorm: analysis.embeddingRawNorm,
            embeddingNorm: analysis.embeddingNorm,
            embeddingMilliseconds: analysis.embeddingMilliseconds,
            physicalFootprintBytes: result.physicalFootprintBytes,
            thermalState: Self.thermalStateDescription(),
            submittedMetalWork: metrics.submittedMetalWork
        )
    }

    func metrics() async -> InferenceLifecycleGate.Metrics {
        await lifecycleGate.metrics()
    }

    private func bundledModelResourceRoot() throws -> URL {
        guard let manifestURL = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            throw InferenceError.runtime("找不到 ModelManifest.json")
        }

        let resourceRoot = manifestURL.deletingLastPathComponent()
        let artifacts = try ModelIntegrity.manifest(from: manifestURL)
        let requiredModels = ["sensevoice-q8-0", "silero-vad", "cam-plus"]
        for id in requiredModels {
            guard let artifact = artifacts.first(where: { $0.id == id }) else {
                throw InferenceError.runtime("ModelManifest.json 中缺少 \(id)")
            }
            try ModelIntegrity.validate(artifact, in: resourceRoot)
        }
        return resourceRoot
    }

    nonisolated private static func run(
        samples: [Float],
        resourceRoot: URL,
        cancellation: InferenceCancellationFlag
    ) throws -> NativeResult {
        let modelURL = resourceRoot.appending(path: "SenseVoiceSmall-Q8_0.gguf")
        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = TRANSCRIBE_BACKEND_METAL

        var session: OpaquePointer?
        let openStatus = modelURL.path.withCString {
            transcribe_open($0, &loadParams, nil, &session)
        }
        guard openStatus == TRANSCRIBE_OK, let session else {
            throw InferenceError.runtime(statusDescription(openStatus))
        }
        defer { transcribe_session_free(session) }

        let cancellationPointer = Unmanaged.passUnretained(cancellation).toOpaque()
        transcribe_set_abort_callback(session, { userData in
            guard let userData else { return false }
            return Unmanaged<InferenceCancellationFlag>.fromOpaque(userData).takeUnretainedValue().shouldAbort
        }, cancellationPointer)
        guard !cancellation.shouldAbort else {
            throw InferenceError.abortedForBackground
        }

        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)
        let runStatus = "zh".withCString { language in
            runParams.language = language
            return samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &runParams)
            }
        }
        if runStatus == TRANSCRIBE_ERR_ABORTED || cancellation.shouldAbort {
            throw InferenceError.abortedForBackground
        }
        guard runStatus == TRANSCRIBE_OK else {
            throw InferenceError.runtime(statusDescription(runStatus))
        }
        let text = String(cString: transcribe_full_text(session))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var timings = transcribe_timings()
        transcribe_timings_init(&timings)
        let timingStatus = transcribe_get_timings(session, &timings)
        guard timingStatus == TRANSCRIBE_OK else {
            throw InferenceError.runtime(statusDescription(timingStatus))
        }

        let backend = String(cString: transcribe_model_backend(transcribe_get_model(session)))
        let inferenceMilliseconds = timings.mel_ms + timings.encode_ms + timings.decode_ms
        let audioDuration = Double(samples.count) / 16_000

        return NativeResult(
            text: text,
            backend: backend,
            loadMilliseconds: timings.load_ms,
            inferenceMilliseconds: inferenceMilliseconds,
            realtimeFactor: inferenceMilliseconds > 0 ? audioDuration / Double(inferenceMilliseconds / 1_000) : 0,
            physicalFootprintBytes: physicalFootprintBytes()
        )
    }

    nonisolated private static func statusDescription(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }

    nonisolated private static func thermalStateDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private struct NativeResult: Sendable {
        let text: String
        let backend: String
        let loadMilliseconds: Float
        let inferenceMilliseconds: Float
        let realtimeFactor: Double
        let physicalFootprintBytes: UInt64
    }
}

private final class InferenceCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var abortRequested = false

    nonisolated init() {}

    nonisolated var shouldAbort: Bool {
        lock.withLock { abortRequested }
    }

    nonisolated func requestAbort() {
        lock.withLock { abortRequested = true }
    }

    nonisolated func clearAbort() {
        lock.withLock { abortRequested = false }
    }
}

enum PCM16KMonoLoader {
    nonisolated static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw SenseVoiceInferenceService.InferenceError.invalidPCMFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }

        var samples: [Float] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!

        while file.framePosition < file.length {
            let remainingFrames = file.length - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, remainingFrames)))
            guard let channel = buffer.floatChannelData?[0] else {
                throw SenseVoiceInferenceService.InferenceError.runtime("无法读取浮点 PCM 音频")
            }

            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        guard !samples.isEmpty else {
            throw SenseVoiceInferenceService.InferenceError.runtime("录音没有可转写的 PCM 样本")
        }
        return samples
    }
}
