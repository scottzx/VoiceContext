import Foundation
import SherpaOnnxC

/// CPU-only preparation for microphone input. Metal work remains owned by
/// `SenseVoiceInferenceService` and is admitted through its lifecycle gate.
actor SpeechAnalysisService {
    struct SpeechSpan: Equatable, Sendable {
        let startSample: Int
        let endSample: Int

        var duration: TimeInterval {
            Double(endSample - startSample) / Self.sampleRate
        }

        private static let sampleRate = 16_000.0
    }

    struct Utterance: Sendable {
        let samples: [Float]
        let spanCount: Int

        var duration: TimeInterval {
            Double(samples.count) / 16_000
        }
    }

    struct Result: Sendable {
        let spans: [SpeechSpan]
        let utterances: [Utterance]
        let voicedDuration: TimeInterval
        let vadMilliseconds: Double
        let speakerEmbedding: SpeakerEmbeddingResult
        let embeddingDimension: Int?
        let embeddingRawNorm: Float?
        let embeddingNorm: Float?
        let embeddingMilliseconds: Double
    }

    enum AnalysisError: LocalizedError {
        case missingResource(String)
        case vadInitializationFailed
        case noSpeechDetected(AudioInputMetrics)

        var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "缺少语音分析模型：\(name)。"
            case .vadInitializationFailed:
                "Silero VAD 初始化失败。"
            case let .noSpeechDetected(metrics):
                String(
                    format: "Silero VAD 未形成语音片段（平均 %.1f dBFS，峰值 %.1f dBFS）。这不是“语音是否清晰”的结论；请查看输入波形，并确认说话持续至少 0.3 秒。",
                    metrics.rmsDecibels,
                    metrics.peakDecibels
                )
            }
        }
    }

    func analyze(samples: [Float], resourceRoot: URL) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try Self.run(samples: samples, resourceRoot: resourceRoot)
        }.value
    }

    private nonisolated static func run(samples: [Float], resourceRoot: URL) throws -> Result {
        let inputMetrics = AudioInputMetrics.from(samples: samples)
        let vadModel = resourceRoot.appending(path: "silero_vad.onnx")
        let speakerModel = resourceRoot.appending(path: "3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx")
        guard FileManager.default.fileExists(atPath: vadModel.path) else {
            throw AnalysisError.missingResource("silero_vad.onnx")
        }
        guard FileManager.default.fileExists(atPath: speakerModel.path) else {
            throw AnalysisError.missingResource("CAM++")
        }

        let vadStartedAt = Date()
        let spans = try detectSpeech(in: samples, modelURL: vadModel)
        let vadMilliseconds = Date().timeIntervalSince(vadStartedAt) * 1_000
        guard !spans.isEmpty else { throw AnalysisError.noSpeechDetected(inputMetrics) }

        let utterances = makeUtterances(from: spans, sourceSamples: samples)
        guard !utterances.isEmpty else { throw AnalysisError.noSpeechDetected(inputMetrics) }

        let voicedDuration = spans.reduce(0) { $0 + $1.duration }
        let embeddingStartedAt = Date()
        let embedding = computeEmbedding(
            from: utterances.flatMap(\.samples),
            modelURL: speakerModel
        )
        let embeddingMilliseconds = Date().timeIntervalSince(embeddingStartedAt) * 1_000

        return Result(
            spans: spans,
            utterances: utterances,
            voicedDuration: voicedDuration,
            vadMilliseconds: vadMilliseconds,
            speakerEmbedding: embedding.result,
            embeddingDimension: embedding.dimension,
            embeddingRawNorm: embedding.rawNorm,
            embeddingNorm: embedding.norm,
            embeddingMilliseconds: embeddingMilliseconds
        )
    }

    private nonisolated static func detectSpeech(in samples: [Float], modelURL: URL) throws -> [SpeechSpan] {
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.threshold = 0.25
        config.silero_vad.min_silence_duration = 0.5
        config.silero_vad.min_speech_duration = 0.3
        config.silero_vad.window_size = 512
        config.silero_vad.max_speech_duration = 15
        config.sample_rate = 16_000
        config.num_threads = 1
        config.debug = 0

        let detector = modelURL.path.withCString { modelPath in
            "cpu".withCString { provider in
                config.silero_vad.model = modelPath
                config.provider = provider
                return SherpaOnnxCreateVoiceActivityDetector(&config, 30)
            }
        }
        guard let detector else { throw AnalysisError.vadInitializationFailed }
        defer { SherpaOnnxDestroyVoiceActivityDetector(detector) }

        let windowSize = Int(config.silero_vad.window_size)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + windowSize, samples.count)
            var frame = Array(samples[offset..<end])
            if frame.count < windowSize {
                frame.append(contentsOf: repeatElement(0, count: windowSize - frame.count))
            }
            frame.withUnsafeBufferPointer { buffer in
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buffer.baseAddress, Int32(buffer.count))
            }
            offset = end
        }
        SherpaOnnxVoiceActivityDetectorFlush(detector)

        var spans: [SpeechSpan] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let start = max(0, Int(segment.pointee.start))
            let end = min(samples.count, start + Int(segment.pointee.n))
            if end > start {
                spans.append(SpeechSpan(startSample: start, endSample: end))
            }
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return spans
    }

    nonisolated static func makeUtterances(
        from spans: [SpeechSpan],
        sourceSamples: [Float]
    ) -> [Utterance] {
        let maximumDurationSamples = 15 * 16_000
        let maximumMergeGapSamples = Int(0.75 * 16_000)
        var utterances: [Utterance] = []
        var start = spans[0].startSample
        var end = spans[0].endSample
        var spanCount = 1

        func appendCurrent() {
            guard end > start else { return }
            utterances.append(Utterance(
                samples: Array(sourceSamples[start..<end]),
                spanCount: spanCount
            ))
        }

        for span in spans.dropFirst() {
            let gap = span.startSample - end
            let candidateLength = span.endSample - start
            if gap <= maximumMergeGapSamples && candidateLength <= maximumDurationSamples {
                end = span.endSample
                spanCount += 1
            } else {
                appendCurrent()
                start = span.startSample
                end = span.endSample
                spanCount = 1
            }
        }
        appendCurrent()
        return utterances
    }

    private nonisolated static func computeEmbedding(
        from samples: [Float],
        modelURL: URL
    ) -> (result: SpeakerEmbeddingResult, dimension: Int?, rawNorm: Float?, norm: Float?) {
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.num_threads = 1
        config.debug = 0

        let extractor = modelURL.path.withCString { modelPath in
            "cpu".withCString { provider in
                config.model = modelPath
                config.provider = provider
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }
        guard let extractor else {
            return (.unavailable(reason: "CAM++ 初始化失败"), nil, nil, nil)
        }
        defer { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }

        let dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        guard dimension > 0 else {
            return (.unavailable(reason: "CAM++ 返回了无效向量维度"), nil, nil, nil)
        }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else {
            return (.unavailable(reason: "CAM++ 无法创建输入流"), dimension, nil, nil)
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1 else {
            return (.unavailable(reason: "有效语音时长不足，CAM++ 未就绪"), dimension, nil, nil)
        }
        guard let values = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else {
            return (.unavailable(reason: "CAM++ 未返回 embedding"), dimension, nil, nil)
        }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(values) }

        let vector = Array(UnsafeBufferPointer(start: values, count: dimension))
        let normalized = normalizedEmbedding(from: vector)
        return (normalized.result, dimension, normalized.rawNorm, normalized.norm)
    }

    /// CAM++ returns a raw feature vector. Speaker comparison must always use
    /// its L2-normalized form, otherwise vector magnitude biases a cosine
    /// threshold. Invalid output remains an explicit unavailable result.
    nonisolated static func normalizedEmbedding(
        from vector: [Float]
    ) -> (result: SpeakerEmbeddingResult, rawNorm: Float?, norm: Float?) {
        let rawNorm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard vector.allSatisfy(\.isFinite), rawNorm.isFinite, rawNorm > 0 else {
            return (.unavailable(reason: "CAM++ 返回了无效 embedding"), nil, nil)
        }

        let unitVector = vector.map { $0 / rawNorm }
        let norm = sqrt(unitVector.reduce(Float.zero) { $0 + $1 * $1 })
        guard unitVector.allSatisfy(\.isFinite), norm.isFinite else {
            return (.unavailable(reason: "CAM++ 归一化失败"), rawNorm, nil)
        }
        return (.embedding(unitVector), rawNorm, norm)
    }
}
