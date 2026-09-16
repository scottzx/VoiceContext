@preconcurrency import AVFoundation
import CTranscribe
import Darwin
import Foundation

actor SenseVoiceInferenceService {
    nonisolated static let analysisPurpose = SpeechAnalysisService.AnalysisPurpose.transcription

    struct SentenceResult: Sendable {
        let text: String
        let rawText: String
        let startSample: Int64
        let endSample: Int64
        let offsetMilliseconds: Int
    }

    struct Result: Sendable {
        let text: String
        let rawText: String
        let detectedLanguage: String
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
        let endsWithOpenSpeech: Bool
        let utteranceCount: Int
        let vadMilliseconds: Double
        let speakerEmbedding: SpeakerEmbeddingResult
        let embeddingDimension: Int?
        let embeddingRawNorm: Float?
        let embeddingNorm: Float?
        let embeddingMilliseconds: Double
        /// Meeting-local temporary roster collected during online clustering.
        let temporarySpeakers: [String]
        let physicalFootprintBytes: UInt64
        let thermalState: String
        let submittedMetalWork: Int
        let sentenceResults: [SentenceResult]
        let speakerObservations: [OfflineSpeakerObservation]
    }

    enum InferenceError: LocalizedError {
        case invalidPCMFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case runtime(String)
        case emptyTranscript
        case unreadableAudio
        case abortedForBackground

        var errorDescription: String? {
            switch self {
            case let .invalidPCMFormat(sampleRate, channels):
                "转写输入必须是 16 kHz 单声道 PCM（收到 \(sampleRate) Hz / \(channels) 声道）。"
            case let .runtime(message):
                "SenseVoice 运行失败：\(message)"
            case .emptyTranscript:
                "SenseVoice 返回空文本，保留录音以便重试。"
            case .unreadableAudio:
                "音频分片无法读取，已跳过转写。"
            case .abortedForBackground:
                "App 进入后台，已停止尚未完成的转写。"
            }
        }

        var isSkippableEmptyChunk: Bool {
            switch self {
            case .emptyTranscript, .unreadableAudio: true
            default: false
            }
        }
    }

    private let lifecycleGate: InferenceLifecycleGate
    private let cancellation = InferenceCancellationFlag()
    private let speechAnalysis = SpeechAnalysisService()

    init(lifecycleGate: InferenceLifecycleGate = InferenceLifecycleGate()) {
        self.lifecycleGate = lifecycleGate
    }

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
            await lifecycleGate.endMetalWork()
            rejected = false
        } catch InferenceLifecycleGate.Rejection.appIsBackgrounded,
                InferenceLifecycleGate.Rejection.metalBusy {
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

    func transcribe(
        recordingURL: URL,
        languageMode: TranscriptionLanguageMode = .default
    ) async throws -> Result {
        try await transcribe(
            recordingURLs: [recordingURL],
            startingAt: 0,
            languageMode: languageMode
        )
    }

    /// Decodes adjacent authoritative AAC chunks into one inference input.
    /// The source files remain untouched; this is only the temporary model
    /// input needed when VAD finds speech crossing a minute boundary.
    func transcribe(
        recordingURLs: [URL],
        startingAt: Int64,
        languageMode: TranscriptionLanguageMode = .default
    ) async throws -> Result {
        let samples = try recordingURLs.flatMap { try PCM16KMonoLoader.samples(from: $0) }
        return try await transcribe(
            samples: samples,
            startingAt: startingAt,
            languageMode: languageMode
        )
    }

    /// Runs VAD + SenseVoice on an already-normalized 16 kHz mono window.
    /// Used by Files-import ProcessingRange jobs that decode by range.
    func transcribe(
        samples: [Float],
        startingAt: Int64,
        languageMode: TranscriptionLanguageMode = .default
    ) async throws -> Result {
        let inputMetrics = AudioInputMetrics.from(samples: samples)
        let resourceRoot = try bundledModelResourceRoot()
        cancellation.clearAbort()
        var nativeResults: [NativeResult] = []
        var utteranceDuration: TimeInterval = 0
        var voicedDuration: TimeInterval = 0
        var speechSpanCount = 0
        var utteranceCount = 0
        var vadMilliseconds: Double = 0
        var lastSpeechEndSample: Int64?

        var sentenceResults: [SentenceResult] = []
        for range in Self.analysisRanges(sampleCount: samples.count) {
            let window = Array(samples[range])
            let windowStartSample = startingAt + Int64(range.lowerBound)
            let analysis: SpeechAnalysisService.Result
            do {
                analysis = try await speechAnalysis.analyze(
                    samples: window,
                    resourceRoot: resourceRoot,
                    startingAt: windowStartSample,
                    purpose: Self.analysisPurpose
                )
            } catch let error as SpeechAnalysisService.AnalysisError {
                guard case .noSpeechDetected = error else { throw error }
                continue
            }

            utteranceDuration += analysis.utterances.reduce(0) { $0 + $1.duration }
            voicedDuration += analysis.voicedDuration
            speechSpanCount += analysis.spans.count
            utteranceCount += analysis.utterances.count
            vadMilliseconds += analysis.vadMilliseconds
            lastSpeechEndSample = analysis.spans.last?.endSample ?? lastSpeechEndSample

            for utterance in analysis.utterances {
                guard !utterance.samples.isEmpty else { continue }

                try await lifecycleGate.beginMetalWork()
                let result: NativeResult
                do {
                    result = try await Task.detached(priority: .userInitiated) { [cancellation] in
                        try Self.run(
                            samples: utterance.samples,
                            resourceRoot: resourceRoot,
                            cancellation: cancellation,
                            languageMode: languageMode
                        )
                    }.value
                } catch {
                    await lifecycleGate.endMetalWork()
                    throw error
                }
                await lifecycleGate.endMetalWork()
                nativeResults.append(result)
                let nativeSentences = ASRSentenceSegmenter.split(
                    tokens: result.tokens,
                    fallbackText: result.text,
                    fallbackDurationMilliseconds: Int64(
                        (Double(utterance.samples.count) / 16.0).rounded()
                    )
                )
                for sentence in nativeSentences {
                    let startSample = min(
                        utterance.endSample,
                        utterance.startSample + sentence.startMilliseconds * 16
                    )
                    let endSample = min(
                        utterance.endSample,
                        max(startSample + 1, utterance.startSample + sentence.endMilliseconds * 16)
                    )
                    sentenceResults.append(
                        SentenceResult(
                            text: sentence.text,
                            rawText: sentence.text,
                            startSample: startSample,
                            endSample: endSample,
                            offsetMilliseconds: Int((Double(startSample) / 16.0).rounded())
                        )
                    )
                }
            }
        }
        guard let lastResult = nativeResults.last else {
            throw SpeechAnalysisService.AnalysisError.noSpeechDetected(inputMetrics)
        }

        let text = nativeResults.map(\.text).joined(separator: " ")
        let rawText = nativeResults.map(\.rawText).joined(separator: " ")
        let detectedLanguage = nativeResults
            .map(\.detectedLanguage)
            .first(where: { !$0.isEmpty }) ?? ""
        let loadMilliseconds = nativeResults.reduce(0) { $0 + $1.loadMilliseconds }
        let inferenceMilliseconds = nativeResults.reduce(0) { $0 + $1.inferenceMilliseconds }
        let audioDuration = Double(samples.count) / 16_000

        let metrics = await lifecycleGate.metrics()
        return Result(
            text: text,
            rawText: rawText,
            detectedLanguage: detectedLanguage,
            backend: lastResult.backend,
            audioDuration: audioDuration,
            utteranceDuration: utteranceDuration,
            voicedDuration: voicedDuration,
            loadMilliseconds: loadMilliseconds,
            inferenceMilliseconds: inferenceMilliseconds,
            realtimeFactor: inferenceMilliseconds > 0
                ? audioDuration / Double(inferenceMilliseconds / 1_000)
                : 0,
            inputPowerDecibels: inputMetrics.rmsDecibels,
            inputPeakDecibels: inputMetrics.peakDecibels,
            speechSpanCount: speechSpanCount,
            endsWithOpenSpeech: lastSpeechEndSample ?? 0
                >= startingAt + Int64(samples.count) - Int64(0.75 * 16_000),
            utteranceCount: utteranceCount,
            vadMilliseconds: vadMilliseconds,
            speakerEmbedding: .unavailable(reason: "说话人整理在转写完成后执行"),
            embeddingDimension: nil,
            embeddingRawNorm: nil,
            embeddingNorm: nil,
            embeddingMilliseconds: 0,
            temporarySpeakers: [],
            physicalFootprintBytes: nativeResults.map(\.physicalFootprintBytes).max() ?? 0,
            thermalState: Self.thermalStateDescription(),
            submittedMetalWork: metrics.submittedMetalWork,
            sentenceResults: sentenceResults,
            speakerObservations: []
        )
    }

    /// VAD already produces bounded utterances (15-second target, 25-second
    /// hard cap). Keeping those boundaries for ASR prevents a legacy
    /// multi-minute AudioChunk from becoming one unbounded Metal allocation.
    nonisolated static func inferenceInputs(
        from utterances: [SpeechAnalysisService.Utterance]
    ) -> [[Float]] {
        utterances.flatMap { utterance in
            analysisRanges(
                sampleCount: utterance.samples.count,
                maximumSamples: Int(SpeechAnalysisService.hardMaximumUtteranceSamples)
            ).map { range in
                Array(utterance.samples[range])
            }
        }
    }

    /// Legacy recordings may contain five-minute physical chunks. Bound CPU
    /// analysis to the same one-minute budget used by current capture so VAD
    /// and speaker embedding cannot create an unbounded launch-time peak.
    nonisolated static func analysisRanges(
        sampleCount: Int,
        maximumSamples: Int = Int(AACSegmentRecorder.targetSampleRate * 60)
    ) -> [Range<Int>] {
        guard sampleCount > 0, maximumSamples > 0 else { return [] }
        return stride(from: 0, to: sampleCount, by: maximumSamples).map { start in
            start..<min(start + maximumSamples, sampleCount)
        }
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
        cancellation: InferenceCancellationFlag,
        languageMode: TranscriptionLanguageMode
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
        // SenseVoice couples punctuation output to its ITN prefix. Sentence
        // boundaries therefore require ITN to be explicitly enabled.
        runParams.itn = TRANSCRIBE_ITN_MODE_ON
        // NULL asks SenseVoice to autodetect (zh / yue / en / ja / ko).
        // Explicit settings pass the corresponding LID hint. Do not pass
        // the string "auto": it is not in the model's language list.
        let languageHint = languageMode.senseVoiceLanguageHint
        let runStatus: transcribe_status
        if let languageHint {
            runStatus = languageHint.withCString { languagePointer in
                runParams.language = languagePointer
                return samples.withUnsafeBufferPointer {
                    transcribe_run(session, $0.baseAddress, Int32($0.count), &runParams)
                }
            }
        } else {
            runParams.language = nil
            runStatus = samples.withUnsafeBufferPointer {
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
        guard !text.isEmpty else {
            throw InferenceError.emptyTranscript
        }
        let rawText = String(cString: transcribe_raw_text(session))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = String(cString: transcribe_detected_language(session))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLanguage = detectedLanguage.isEmpty
            ? languageMode.senseVoiceLanguageHint ?? ""
            : detectedLanguage

        var tokens: [ASRSentenceSegmenter.Token] = []
        if transcribe_returned_timestamp_kind(session) == TRANSCRIBE_TIMESTAMPS_TOKEN {
            for index in 0..<Int(transcribe_n_tokens(session)) {
                var token = transcribe_token()
                transcribe_token_init(&token)
                guard transcribe_get_token(session, Int32(index), &token) == TRANSCRIBE_OK,
                      let textPointer = token.text,
                      token.t1_ms > token.t0_ms
                else { continue }
                tokens.append(ASRSentenceSegmenter.Token(
                    text: String(cString: textPointer),
                    startMilliseconds: token.t0_ms,
                    endMilliseconds: token.t1_ms
                ))
            }
        }

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
            rawText: rawText,
            detectedLanguage: effectiveLanguage,
            tokens: tokens,
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
        let rawText: String
        let detectedLanguage: String
        let tokens: [ASRSentenceSegmenter.Token]
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
    nonisolated static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.processingFormat.sampleRate > 0
    }

    nonisolated static func samples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SenseVoiceInferenceService.InferenceError.unreadableAudio
        }
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw SenseVoiceInferenceService.InferenceError.invalidPCMFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }

        var samples: [Float] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!

        do {
            while file.framePosition < file.length {
                let remainingFrames = file.length - file.framePosition
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, remainingFrames)))
                guard let channel = buffer.floatChannelData?[0] else {
                    throw SenseVoiceInferenceService.InferenceError.runtime("无法读取浮点 PCM 音频")
                }

                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        } catch let error as SenseVoiceInferenceService.InferenceError {
            throw error
        } catch {
            throw SenseVoiceInferenceService.InferenceError.unreadableAudio
        }

        guard !samples.isEmpty else {
            throw SenseVoiceInferenceService.InferenceError.unreadableAudio
        }
        return samples
    }
}
