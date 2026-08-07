import Foundation
import SherpaOnnxC

/// A transient, meeting-local speaker window. These values are processing
/// inputs only: callers must not persist their samples or embeddings in the
/// public recording document.
nonisolated struct SpeakerWindow: Equatable, Sendable {
    let startSample: Int64
    let endSample: Int64
    let samples: [Float]
    let exclusionReasons: [ExclusionReason]

    nonisolated enum ExclusionReason: Equatable, Sendable {
        case tooShort
        case lowEnergy
        case lowQuality
        case suspectedOverlappingSpeech
    }

    var isEligibleForClustering: Bool { exclusionReasons.isEmpty }

    var duration: TimeInterval {
        Double(endSample - startSample) / SpeakerWindowing.sampleRate
    }
}

/// Produces the 1.5–3 second, overlapping CAM++ inputs required for online
/// meeting labels. The quality checks intentionally err toward `unknown`:
/// only clean, sufficiently audible, non-overlap windows reach clustering.
nonisolated enum SpeakerWindowing {
    static let sampleRate = 16_000.0
    static let targetWindowSamples = Int64(2 * sampleRate)
    static let hopSamples = Int64(1 * sampleRate)
    static let minimumWindowSamples = Int64(1.5 * sampleRate)
    static let minimumRMSDecibels: Float = -45
    static let maximumClippedSampleRatio: Float = 0.02

    static func makeWindows(
        from utterances: [SpeechAnalysisService.Utterance],
        suspectedOverlapRanges: [Range<Int64>] = []
    ) -> [SpeakerWindow] {
        utterances.flatMap { utterance in
            makeWindows(
                samples: utterance.samples,
                startingAt: utterance.startSample,
                suspectedOverlapRanges: suspectedOverlapRanges
            )
        }
    }

    static func makeWindows(
        samples: [Float],
        startingAt startSample: Int64 = 0,
        suspectedOverlapRanges: [Range<Int64>] = []
    ) -> [SpeakerWindow] {
        let endSample = startSample + Int64(samples.count)
        var windowStart = startSample
        var windows: [SpeakerWindow] = []

        while endSample - windowStart >= minimumWindowSamples {
            let windowEnd = min(windowStart + targetWindowSamples, endSample)
            let lowerIndex = Int(windowStart - startSample)
            let upperIndex = Int(windowEnd - startSample)
            let windowSamples = Array(samples[lowerIndex..<upperIndex])
            let range = windowStart..<windowEnd
            windows.append(SpeakerWindow(
                startSample: windowStart,
                endSample: windowEnd,
                samples: windowSamples,
                exclusionReasons: exclusionReasons(
                    for: windowSamples,
                    range: range,
                    suspectedOverlapRanges: suspectedOverlapRanges
                )
            ))
            windowStart += hopSamples
        }
        return windows
    }

    private static func exclusionReasons(
        for samples: [Float],
        range: Range<Int64>,
        suspectedOverlapRanges: [Range<Int64>]
    ) -> [SpeakerWindow.ExclusionReason] {
        var reasons: [SpeakerWindow.ExclusionReason] = []
        if samples.count < Int(minimumWindowSamples) {
            reasons.append(.tooShort)
        }

        let metrics = AudioInputMetrics.from(samples: samples)
        if metrics.rmsDecibels < minimumRMSDecibels {
            reasons.append(.lowEnergy)
        }

        let clippedSampleCount = samples.lazy.filter { abs($0) >= 0.99 }.count
        if !samples.allSatisfy(\.isFinite) ||
            Float(clippedSampleCount) / Float(max(samples.count, 1)) > maximumClippedSampleRatio {
            reasons.append(.lowQuality)
        }

        if suspectedOverlapRanges.contains(where: { $0.overlaps(range) }) {
            reasons.append(.suspectedOverlappingSpeech)
        }
        return reasons
    }
}

/// The native CAM++ call for an already quality-filtered short window. Model
/// failures deliberately preserve an unavailable result instead of providing
/// a synthetic stand-in vector.
nonisolated enum CAMPlusShortWindowEmbedder {
    static func embed(
        windows: [SpeakerWindow],
        modelURL: URL
    ) -> [SpeakerEmbeddingResult] {
        windows.map { window in
            guard window.isEligibleForClustering else {
                return .unavailable(reason: "该短窗未通过说话人聚类质量检查")
            }
            return embedding(from: window.samples, modelURL: modelURL)
        }
    }

    private static func embedding(
        from samples: [Float],
        modelURL: URL
    ) -> SpeakerEmbeddingResult {
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
            return .unavailable(reason: "CAM++ 初始化失败")
        }
        defer { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }

        let dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        guard dimension > 0,
              let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else {
            return .unavailable(reason: "CAM++ 无法创建短窗 embedding 输入")
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1,
              let values = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else {
            return .unavailable(reason: "CAM++ 短窗 embedding 未就绪")
        }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(values) }

        let vector = Array(UnsafeBufferPointer(start: values, count: dimension))
        return normalizedEmbedding(vector)
    }

    private static func normalizedEmbedding(_ vector: [Float]) -> SpeakerEmbeddingResult {
        let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard vector.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else {
            return .unavailable(reason: "CAM++ 返回了无效短窗 embedding")
        }
        let normalized = vector.map { $0 / norm }
        guard normalized.allSatisfy(\.isFinite) else {
            return .unavailable(reason: "CAM++ 短窗 embedding 归一化失败")
        }
        return .embedding(normalized)
    }
}

nonisolated struct TemporarySpeakerCluster: Equatable, Sendable {
    let id: Int
    private(set) var centroid: [Float]
    private(set) var windowCount: Int

    init(id: Int, centroid: [Float], windowCount: Int = 1) {
        self.id = id
        self.centroid = centroid
        self.windowCount = windowCount
    }

    mutating func append(_ vector: [Float]) {
        let accumulated = zip(centroid, vector).map { $0 + $1 }
        let norm = sqrt(accumulated.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return }
        centroid = accumulated.map { $0 / norm }
        windowCount += 1
    }
}

/// A deliberately non-persistent online clusterer. It only offers temporary
/// labels during one recording; it never reads or writes confirmed voiceprint
/// archives. Ambiguous similarities stay `unknown` until offline re-clustering
/// and explicit confirmation are available.
nonisolated struct OnlineTemporarySpeakerClusterer: Sendable {
    nonisolated enum Assignment: Equatable, Sendable {
        case temporaryCluster(id: Int)
        case unknown(reason: UnknownReason)
    }

    nonisolated enum UnknownReason: Equatable, Sendable {
        case ineligibleWindow([SpeakerWindow.ExclusionReason])
        case embeddingUnavailable
        case ambiguousSimilarity
        case invalidEmbedding
    }

    private(set) var clusters: [TemporarySpeakerCluster] = []
    private var nextClusterID = 1

    mutating func assign(
        window: SpeakerWindow,
        embedding: SpeakerEmbeddingResult
    ) -> Assignment {
        guard window.isEligibleForClustering else {
            return .unknown(reason: .ineligibleWindow(window.exclusionReasons))
        }
        guard let rawVector = embedding.vector else {
            return .unknown(reason: .embeddingUnavailable)
        }
        let squaredMagnitude = rawVector.reduce(Float.zero) { $0 + $1 * $1 }
        guard rawVector.allSatisfy(\.isFinite), squaredMagnitude.isFinite, squaredMagnitude > 0 else {
            return .unknown(reason: .invalidEmbedding)
        }
        let magnitude = sqrt(squaredMagnitude)
        let vector = rawVector.map { $0 / magnitude }

        guard !clusters.isEmpty else { return createCluster(with: vector) }
        let candidates = clusters.enumerated().compactMap { index, cluster -> (index: Int, similarity: Float)? in
            guard let similarity = SpeakerSimilarity.cosineSimilarity(vector, cluster.centroid) else {
                return nil
            }
            return (index, similarity)
        }
        guard let closest = candidates.max(by: { $0.similarity < $1.similarity }) else {
            return .unknown(reason: .invalidEmbedding)
        }

        switch SpeakerSimilarity.decision(for: closest.similarity) {
        case .likelySameSpeaker:
            clusters[closest.index].append(vector)
            return .temporaryCluster(id: clusters[closest.index].id)
        case .likelyDifferentSpeaker:
            return createCluster(with: vector)
        case .uncertain, .none:
            return .unknown(reason: .ambiguousSimilarity)
        }
    }

    private mutating func createCluster(with vector: [Float]) -> Assignment {
        let id = nextClusterID
        nextClusterID += 1
        clusters.append(TemporarySpeakerCluster(
            id: id,
            centroid: vector
        ))
        return .temporaryCluster(id: id)
    }
}
