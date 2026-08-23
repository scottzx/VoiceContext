import Foundation
import SherpaOnnxC

/// CPU-only preparation for microphone input. Metal work remains owned by
/// `SenseVoiceInferenceService` and is admitted through its lifecycle gate.
actor SpeechAnalysisService {
    struct SpeechSpan: Codable, Equatable, Sendable {
        /// Absolute 16 kHz sample offsets in the recording, not offsets local
        /// to an AAC chunk or a VAD input buffer.
        let startSample: Int64
        let endSample: Int64

        var duration: TimeInterval {
            Double(endSample - startSample) / Self.sampleRate
        }

        private static let sampleRate = 16_000.0
    }

    struct Utterance: Sendable {
        /// The half-open recording range represented by `samples`.
        let startSample: Int64
        let endSample: Int64
        let samples: [Float]
        /// The exact VAD spans (or bounded portions of one) which formed this
        /// utterance. Downstream transcript segments can retain this link.
        let speechSpans: [SpeechSpan]

        var spanCount: Int { speechSpans.count }

        var duration: TimeInterval {
            Double(samples.count) / 16_000
        }
    }

    /// PCM from one closed or active AAC chunk, retaining the chunk's absolute
    /// position so a VAD result can be assembled across chunk boundaries.
    struct SampleChunk: Sendable {
        let startSample: Int64
        let samples: [Float]

        var endSample: Int64 { startSample + Int64(samples.count) }
    }

    /// Exact provenance for one contiguous portion of an utterance. Absolute
    /// offsets share the Recording's 16 kHz clock; local offsets address the
    /// source AudioChunk without assuming a fixed chunk duration.
    struct UtteranceSourceRange: Codable, Equatable, Sendable {
        let chunkID: UUID
        let chunkSequence: Int
        let localStartSample: Int64
        let localEndSample: Int64
        let startSample: Int64
        let endSample: Int64
    }

    /// Metadata produced by VAD for one closed AudioChunk. PCM remains in the
    /// authoritative AAC and is decoded later from `sourceRanges` by ASR.
    struct AnalyzedAudioChunk: Sendable {
        let id: UUID
        let sequence: Int
        let startSample: Int64
        let endSample: Int64
        let speechSpans: [SpeechSpan]
        let endsWithOpenSpeech: Bool
    }

    enum DiscontinuityKind: String, Codable, Equatable, Sendable {
        case userPause
        case systemInterruption
        case routeChange
        case missingAudio
    }

    /// A point boundary uses equal start/end samples. A non-empty range
    /// represents audio which must never be silently filled or crossed.
    struct UtteranceDiscontinuity: Codable, Equatable, Sendable {
        let kind: DiscontinuityKind
        let startSample: Int64
        let endSample: Int64
    }

    struct OpenUtteranceCarry: Codable, Equatable, Sendable {
        let startSample: Int64
        var endSample: Int64
        var speechSpans: [SpeechSpan]
        var sourceRanges: [UtteranceSourceRange]

        var duration: TimeInterval {
            Double(endSample - startSample) / 16_000
        }
    }

    enum UtteranceTermination: Codable, Equatable, Sendable {
        case naturalPause
        case targetDuration
        case hardLimit
        case discontinuity(DiscontinuityKind)
        case endOfRecording
    }

    struct FinalizedUtterance: Codable, Equatable, Sendable {
        let startSample: Int64
        let endSample: Int64
        let speechSpans: [SpeechSpan]
        let sourceRanges: [UtteranceSourceRange]
        let termination: UtteranceTermination

        var duration: TimeInterval {
            Double(endSample - startSample) / 16_000
        }
    }

    struct IncrementalAssembly: Equatable, Sendable {
        let utterances: [FinalizedUtterance]
        let carry: OpenUtteranceCarry?
    }

    enum IncrementalAssemblyError: Error, Equatable {
        case invalidChunkRange(startSample: Int64, endSample: Int64)
        case invalidDiscontinuity(startSample: Int64, endSample: Int64)
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
        /// Online meeting-local labels for eligible short windows. Invalid or
        /// failed windows are `未知说话人` and never invent a cluster.
        let temporarySpeakerAssignments: [TemporarySpeakerAssignment]
        /// Distinct temporary roster entries such as `说话人 1` for the
        /// transcript document. Unknown is intentionally omitted.
        let temporarySpeakers: [String]
        /// Short-window observations retained so a completed Recording can run
        /// offline re-clustering without inventing embeddings.
        let speakerObservations: [OfflineSpeakerObservation]
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

    func analyze(
        samples: [Float],
        resourceRoot: URL,
        startingAt startSample: Int64 = 0
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try Self.run(
                samples: samples,
                resourceRoot: resourceRoot,
                startingAt: startSample
            )
        }.value
    }

    /// CPU-only short-window observations for offline re-clustering. Empty when
    /// VAD finds no speech; never fabricates embeddings on CAM++ failure.
    nonisolated static func collectSpeakerObservations(
        samples: [Float],
        resourceRoot: URL,
        startingAt startSample: Int64 = 0
    ) throws -> [OfflineSpeakerObservation] {
        do {
            return try run(
                samples: samples,
                resourceRoot: resourceRoot,
                startingAt: startSample
            ).speakerObservations
        } catch let error as AnalysisError {
            if case .noSpeechDetected = error { return [] }
            throw error
        }
    }

    private nonisolated static func run(
        samples: [Float],
        resourceRoot: URL,
        startingAt startSample: Int64
    ) throws -> Result {
        let inputMetrics = AudioInputMetrics.from(samples: samples)
        let vadModel = resourceRoot.appending(path: "silero_vad.onnx")
        let speakerModel = resourceRoot.appending(path: "3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx")
        guard FileManager.default.fileExists(atPath: vadModel.path) else {
            throw AnalysisError.missingResource("silero_vad.onnx")
        }
        guard FileManager.default.fileExists(atPath: speakerModel.path) else {
            throw AnalysisError.missingResource("3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx")
        }

        let vadStartedAt = Date()
        let spans = try detectSpeech(
            in: samples,
            modelURL: vadModel,
            startingAt: startSample
        )
        let vadMilliseconds = Date().timeIntervalSince(vadStartedAt) * 1_000
        guard !spans.isEmpty else { throw AnalysisError.noSpeechDetected(inputMetrics) }

        let utterances = makeUtterances(
            from: spans,
            sourceSamples: samples,
            sourceStartSample: startSample
        )
        guard !utterances.isEmpty else { throw AnalysisError.noSpeechDetected(inputMetrics) }

        let voicedDuration = spans.reduce(0) { $0 + $1.duration }
        let embeddingStartedAt = Date()
        let windows = SpeakerWindowing.makeWindows(from: utterances)
        let windowEmbeddings = CAMPlusShortWindowEmbedder.embed(
            windows: windows,
            modelURL: speakerModel
        )
        var clusterer = OnlineTemporarySpeakerClusterer()
        let temporarySpeakerAssignments = TemporarySpeakerLabeling.assign(
            windows: windows,
            embeddings: windowEmbeddings,
            clusterer: &clusterer
        )
        let temporarySpeakers = TemporarySpeakerLabeling.roster(
            from: temporarySpeakerAssignments
        )
        let speakerObservations = OfflineSpeakerObservationBuilder.make(
            windows: windows,
            embeddings: windowEmbeddings,
            assignments: temporarySpeakerAssignments
        )
        let embedding = representativeEmbedding(from: windowEmbeddings)
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
            embeddingMilliseconds: embeddingMilliseconds,
            temporarySpeakerAssignments: temporarySpeakerAssignments,
            temporarySpeakers: temporarySpeakers,
            speakerObservations: speakerObservations
        )
    }

    private nonisolated static func detectSpeech(
        in samples: [Float],
        modelURL: URL,
        startingAt startSample: Int64
    ) throws -> [SpeechSpan] {
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
                spans.append(SpeechSpan(
                    startSample: startSample + Int64(start),
                    endSample: startSample + Int64(end)
                ))
            }
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return spans
    }

    nonisolated static func makeUtterances(
        from spans: [SpeechSpan],
        sourceSamples: [Float],
        sourceStartSample: Int64 = 0
    ) -> [Utterance] {
        makeUtterances(
            from: spans,
            sourceChunks: [SampleChunk(startSample: sourceStartSample, samples: sourceSamples)]
        )
    }

    /// Combines nearby VAD spans while keeping every position absolute.
    /// These spans support analysis only; production ASR receives the complete
    /// persisted AAC chunk.
    nonisolated static func makeUtterances(
        from spans: [SpeechSpan],
        sourceChunks: [SampleChunk]
    ) -> [Utterance] {
        let maximumMergeGapSamples = Int64(0.75 * 16_000)
        let chunks = sourceChunks
            .filter { !$0.samples.isEmpty }
            .sorted { $0.startSample < $1.startSample }
        guard !chunks.isEmpty else { return [] }

        var utterances: [Utterance] = []
        var currentSpans: [SpeechSpan] = []
        var currentStart: Int64?
        var currentEnd: Int64?

        func resetCurrent() {
            currentSpans = []
            currentStart = nil
            currentEnd = nil
        }

        func appendCurrent() {
            defer { resetCurrent() }
            guard let currentStart, let currentEnd, currentEnd > currentStart,
                  let samples = samples(in: currentStart..<currentEnd, from: chunks) else {
                return
            }
            utterances.append(Utterance(
                startSample: currentStart,
                endSample: currentEnd,
                samples: samples,
                speechSpans: currentSpans
            ))
        }

        for inputSpan in spans.sorted(by: { $0.startSample < $1.startSample }) where inputSpan.endSample > inputSpan.startSample {
            var spanStart = inputSpan.startSample
            while spanStart < inputSpan.endSample {
                if currentStart != nil, let activeEnd = currentEnd {
                    let gap = spanStart - activeEnd
                    guard gap <= maximumMergeGapSamples else {
                        appendCurrent()
                        continue
                    }

                    let spanEnd = inputSpan.endSample
                    currentSpans.append(SpeechSpan(startSample: spanStart, endSample: spanEnd))
                    currentEnd = max(activeEnd, spanEnd)
                    spanStart = spanEnd
                    if spanStart < inputSpan.endSample {
                        appendCurrent()
                    }
                } else {
                    let spanEnd = inputSpan.endSample
                    currentStart = spanStart
                    currentEnd = spanEnd
                    currentSpans = [SpeechSpan(startSample: spanStart, endSample: spanEnd)]
                    spanStart = spanEnd
                    if spanStart < inputSpan.endSample {
                        appendCurrent()
                    }
                }
            }
        }
        appendCurrent()
        return utterances
    }

    nonisolated static let targetMinimumUtteranceSamples: Int64 = 3 * 16_000
    nonisolated static let targetMaximumUtteranceSamples: Int64 = 15 * 16_000
    nonisolated static let hardMaximumUtteranceSamples: Int64 = 25 * 16_000
    private nonisolated static let maximumMergeGapSamples: Int64 = Int64(0.75 * 16_000)

    /// Incrementally assembles utterance metadata from one closed AudioChunk.
    /// The function is intentionally stateless: persisting `carry` and feeding
    /// it back with the next chunk makes retries deterministic without keeping
    /// decoded PCM or rewriting authoritative AAC files.
    nonisolated static func assembleIncrementally(
        chunk: AnalyzedAudioChunk,
        carrying carry: OpenUtteranceCarry? = nil,
        discontinuities: [UtteranceDiscontinuity] = [],
        isFinalChunk: Bool = false
    ) throws -> IncrementalAssembly {
        guard chunk.endSample > chunk.startSample else {
            throw IncrementalAssemblyError.invalidChunkRange(
                startSample: chunk.startSample,
                endSample: chunk.endSample
            )
        }
        for discontinuity in discontinuities where discontinuity.endSample < discontinuity.startSample {
            throw IncrementalAssemblyError.invalidDiscontinuity(
                startSample: discontinuity.startSample,
                endSample: discontinuity.endSample
            )
        }

        let partition = continuousRegions(
            in: chunk.startSample..<chunk.endSample,
            discontinuities: discontinuities
        )
        var utterances: [FinalizedUtterance] = []
        var current = carry

        if let existing = current,
           existing.endSample != chunk.startSample || partition.leadingBoundary != nil {
            utterances.append(finalize(
                existing,
                termination: .discontinuity(partition.leadingBoundary ?? .missingAudio)
            ))
            current = nil
        }

        for region in partition.regions {
            let spans = normalizedSpans(chunk.speechSpans, clippedTo: region.range)
            for span in spans {
                append(
                    span,
                    from: chunk,
                    current: &current,
                    utterances: &utterances
                )
            }
            if let boundary = region.boundaryAfter, let existing = current {
                utterances.append(finalize(existing, termination: .discontinuity(boundary)))
                current = nil
            }
        }

        if let existing = current {
            if isFinalChunk {
                utterances.append(finalize(existing, termination: .endOfRecording))
                current = nil
            } else if !(chunk.endsWithOpenSpeech && existing.endSample == chunk.endSample) {
                utterances.append(finalize(existing, termination: .naturalPause))
                current = nil
            }
        }

        return IncrementalAssembly(utterances: utterances, carry: current)
    }

    private struct ContinuousRegion {
        let range: Range<Int64>
        let boundaryAfter: DiscontinuityKind?
    }

    private nonisolated static func continuousRegions(
        in chunkRange: Range<Int64>,
        discontinuities: [UtteranceDiscontinuity]
    ) -> (regions: [ContinuousRegion], leadingBoundary: DiscontinuityKind?) {
        let relevant = discontinuities
            .filter {
                $0.endSample >= chunkRange.lowerBound
                    && $0.startSample <= chunkRange.upperBound
            }
            .sorted {
                if $0.startSample != $1.startSample {
                    return $0.startSample < $1.startSample
                }
                return $0.endSample < $1.endSample
            }
        var regions: [ContinuousRegion] = []
        var cursor = chunkRange.lowerBound
        var leadingBoundary: DiscontinuityKind?

        for discontinuity in relevant {
            let boundaryStart = min(
                chunkRange.upperBound,
                max(chunkRange.lowerBound, discontinuity.startSample)
            )
            let boundaryEnd = min(
                chunkRange.upperBound,
                max(boundaryStart, discontinuity.endSample)
            )
            if boundaryStart <= cursor {
                if cursor == chunkRange.lowerBound {
                    leadingBoundary = leadingBoundary ?? discontinuity.kind
                }
                cursor = max(cursor, boundaryEnd)
                continue
            }
            regions.append(ContinuousRegion(
                range: cursor..<boundaryStart,
                boundaryAfter: discontinuity.kind
            ))
            cursor = boundaryEnd
        }
        if cursor < chunkRange.upperBound {
            regions.append(ContinuousRegion(range: cursor..<chunkRange.upperBound, boundaryAfter: nil))
        }
        return (regions, leadingBoundary)
    }

    private nonisolated static func normalizedSpans(
        _ spans: [SpeechSpan],
        clippedTo range: Range<Int64>
    ) -> [SpeechSpan] {
        let clipped = spans.compactMap { span -> SpeechSpan? in
            let start = max(span.startSample, range.lowerBound)
            let end = min(span.endSample, range.upperBound)
            guard end > start else { return nil }
            return SpeechSpan(startSample: start, endSample: end)
        }.sorted {
            if $0.startSample != $1.startSample {
                return $0.startSample < $1.startSample
            }
            return $0.endSample < $1.endSample
        }

        var result: [SpeechSpan] = []
        for span in clipped {
            if let last = result.last, span.startSample < last.endSample {
                result[result.count - 1] = SpeechSpan(
                    startSample: last.startSample,
                    endSample: max(last.endSample, span.endSample)
                )
            } else {
                result.append(span)
            }
        }
        return result
    }

    private nonisolated static func append(
        _ span: SpeechSpan,
        from chunk: AnalyzedAudioChunk,
        current: inout OpenUtteranceCarry?,
        utterances: inout [FinalizedUtterance]
    ) {
        var cursor = span.startSample
        while cursor < span.endSample {
            if let existing = current {
                if span.endSample <= existing.endSample {
                    cursor = span.endSample
                    continue
                }
                let gap = cursor - existing.endSample
                if gap > maximumMergeGapSamples {
                    utterances.append(finalize(existing, termination: .naturalPause))
                    current = nil
                    continue
                }

                let proposedEnd = max(existing.endSample, span.endSample)
                // A zero gap may be only a VAD or AudioChunk boundary. It is
                // not a natural cut point, so continuous speech may extend
                // beyond the 15-second target until the 25-second hard cap.
                if gap > 0,
                   existing.endSample - existing.startSample >= targetMinimumUtteranceSamples,
                   proposedEnd - existing.startSample > targetMaximumUtteranceSamples {
                    utterances.append(finalize(existing, termination: .targetDuration))
                    current = nil
                    continue
                }

                let hardEnd = existing.startSample + hardMaximumUtteranceSamples
                if existing.endSample >= hardEnd {
                    utterances.append(finalize(existing, termination: .hardLimit))
                    current = nil
                    continue
                }
                let pieceEnd = min(span.endSample, hardEnd)
                var extended = existing
                let speechStart = max(cursor, existing.endSample)
                if pieceEnd > speechStart {
                    extended.speechSpans.append(SpeechSpan(
                        startSample: speechStart,
                        endSample: pieceEnd
                    ))
                }
                appendSourceCoverage(
                    existing.endSample..<pieceEnd,
                    from: chunk,
                    to: &extended.sourceRanges
                )
                extended.endSample = max(existing.endSample, pieceEnd)
                current = extended
                cursor = pieceEnd
                if extended.endSample - extended.startSample == hardMaximumUtteranceSamples {
                    utterances.append(finalize(extended, termination: .hardLimit))
                    current = nil
                }
            } else {
                let pieceEnd = min(span.endSample, cursor + hardMaximumUtteranceSamples)
                let sourceRange = makeSourceRange(cursor..<pieceEnd, from: chunk)
                let next = OpenUtteranceCarry(
                    startSample: cursor,
                    endSample: pieceEnd,
                    speechSpans: [SpeechSpan(startSample: cursor, endSample: pieceEnd)],
                    sourceRanges: sourceRange.map { [$0] } ?? []
                )
                current = next
                cursor = pieceEnd
                if next.endSample - next.startSample == hardMaximumUtteranceSamples {
                    utterances.append(finalize(next, termination: .hardLimit))
                    current = nil
                }
            }
        }
    }

    private nonisolated static func appendSourceCoverage(
        _ range: Range<Int64>,
        from chunk: AnalyzedAudioChunk,
        to sourceRanges: inout [UtteranceSourceRange]
    ) {
        guard let next = makeSourceRange(range, from: chunk) else { return }
        if let last = sourceRanges.last,
           last.chunkID == next.chunkID,
           last.endSample == next.startSample,
           last.localEndSample == next.localStartSample {
            sourceRanges[sourceRanges.count - 1] = UtteranceSourceRange(
                chunkID: last.chunkID,
                chunkSequence: last.chunkSequence,
                localStartSample: last.localStartSample,
                localEndSample: next.localEndSample,
                startSample: last.startSample,
                endSample: next.endSample
            )
        } else {
            sourceRanges.append(next)
        }
    }

    private nonisolated static func makeSourceRange(
        _ range: Range<Int64>,
        from chunk: AnalyzedAudioChunk
    ) -> UtteranceSourceRange? {
        let start = max(range.lowerBound, chunk.startSample)
        let end = min(range.upperBound, chunk.endSample)
        guard end > start else { return nil }
        return UtteranceSourceRange(
            chunkID: chunk.id,
            chunkSequence: chunk.sequence,
            localStartSample: start - chunk.startSample,
            localEndSample: end - chunk.startSample,
            startSample: start,
            endSample: end
        )
    }

    private nonisolated static func finalize(
        _ carry: OpenUtteranceCarry,
        termination: UtteranceTermination
    ) -> FinalizedUtterance {
        FinalizedUtterance(
            startSample: carry.startSample,
            endSample: carry.endSample,
            speechSpans: carry.speechSpans,
            sourceRanges: carry.sourceRanges,
            termination: termination
        )
    }

    private nonisolated static func samples(
        in range: Range<Int64>,
        from chunks: [SampleChunk]
    ) -> [Float]? {
        var cursor = range.lowerBound
        var result: [Float] = []
        result.reserveCapacity(Int(range.count))

        for chunk in chunks where chunk.endSample > cursor && chunk.startSample < range.upperBound {
            guard chunk.startSample <= cursor else { return nil }
            let end = min(chunk.endSample, range.upperBound)
            let lowerIndex = Int(cursor - chunk.startSample)
            let upperIndex = Int(end - chunk.startSample)
            result.append(contentsOf: chunk.samples[lowerIndex..<upperIndex])
            cursor = end
            if cursor == range.upperBound { return result }
        }
        return nil
    }

    /// Keeps the existing diagnostic embedding fields populated from the first
    /// successful short-window CAM++ vector. Failures stay unavailable.
    private nonisolated static func representativeEmbedding(
        from embeddings: [SpeakerEmbeddingResult]
    ) -> (result: SpeakerEmbeddingResult, dimension: Int?, rawNorm: Float?, norm: Float?) {
        for embedding in embeddings {
            guard let vector = embedding.vector else { continue }
            let normalized = normalizedEmbedding(from: vector)
            if case .embedding = normalized.result {
                return (
                    normalized.result,
                    vector.count,
                    normalized.rawNorm,
                    normalized.norm
                )
            }
        }
        if let unavailable = embeddings.first, case .unavailable = unavailable {
            return (unavailable, nil, nil, nil)
        }
        return (.unavailable(reason: "有效语音时长不足，CAM++ 未就绪"), nil, nil, nil)
    }

    nonisolated static func computeEmbedding(
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
