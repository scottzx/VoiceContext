import Foundation
import SherpaOnnxC

nonisolated struct SpeakerDiarizationInput: Sendable {
    /// Absolute start on the recording's 16 kHz clock. Samples remain local
    /// to this bounded window; results are translated back to this clock.
    let startSample: Int64
    let samples: [Float]
    let observations: [OfflineSpeakerObservation]

    init(
        startSample: Int64 = 0,
        samples: [Float],
        observations: [OfflineSpeakerObservation]
    ) {
        self.startSample = startSample
        self.samples = samples
        self.observations = observations
    }
}

nonisolated struct SpeakerDiarizationOutput: Equatable, Sendable {
    let engineID: String
    let result: OfflineSpeakerReclustering.Result
}

/// Phase-3 seam: text/observation commits do not depend on one diarization
/// implementation. Engines may be benchmarked or rolled back independently.
protocol SpeakerDiarizationEngine: Sendable {
    var id: String { get }
    func diarize(_ input: SpeakerDiarizationInput) async throws -> SpeakerDiarizationOutput
}

nonisolated struct CAMPlusObservationDiarizationEngine: SpeakerDiarizationEngine {
    let id = "cam-plus-observation-clustering-v1"

    func diarize(_ input: SpeakerDiarizationInput) async throws -> SpeakerDiarizationOutput {
        SpeakerDiarizationOutput(
            engineID: id,
            result: OfflineSpeakerReclustering.recluster(input.observations)
        )
    }
}

/// Sherpa offline diarization using pyannote segmentation + the existing CAM++
/// embedding model. Construction is only possible through the manifest gate
/// below; an unreviewed file merely copied into the bundle is never activated.
nonisolated struct SherpaOfflineSpeakerDiarizationEngine: SpeakerDiarizationEngine {
    enum EngineError: LocalizedError {
        case emptyAudio
        case initializationFailed
        case processingFailed
        case invalidResult

        var errorDescription: String? {
            switch self {
            case .emptyAudio: "Sherpa 说话人分离没有可处理的音频。"
            case .initializationFailed: "Sherpa 说话人分离初始化失败。"
            case .processingFailed: "Sherpa 说话人分离未返回结果。"
            case .invalidResult: "Sherpa 说话人分离返回了无效时间段。"
            }
        }
    }

    let id = "sherpa-pyannote3-int8-cam-plus-v1"
    let segmentationModelURL: URL
    let embeddingModelURL: URL
    let numThreads: Int32

    init(
        segmentationModelURL: URL,
        embeddingModelURL: URL,
        numThreads: Int32 = 2
    ) {
        self.segmentationModelURL = segmentationModelURL
        self.embeddingModelURL = embeddingModelURL
        self.numThreads = max(1, numThreads)
    }

    func diarize(_ input: SpeakerDiarizationInput) async throws -> SpeakerDiarizationOutput {
        guard !input.samples.isEmpty else { throw EngineError.emptyAudio }
        return try await makeSession().diarize(input)
    }

    /// Finalization creates one session and reuses its loaded models for every
    /// bounded window. The coordinator consumes the handle serially.
    func makeSession() throws -> Session {
        try Session(engine: self)
    }

    final class Session: @unchecked Sendable {
        private let engine: SherpaOfflineSpeakerDiarizationEngine
        private let diarizer: OpaquePointer

        fileprivate init(engine: SherpaOfflineSpeakerDiarizationEngine) throws {
            self.engine = engine
            guard let diarizer = engine.createDiarizer() else {
                throw EngineError.initializationFailed
            }
            self.diarizer = diarizer
        }

        deinit {
            SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer)
        }

        func diarize(_ input: SpeakerDiarizationInput) async throws -> SpeakerDiarizationOutput {
            guard !input.samples.isEmpty else { throw EngineError.emptyAudio }
            return try await Task.detached(priority: .userInitiated) { [engine, diarizer] in
                try engine.process(input, diarizer: diarizer)
            }.value
        }
    }

    private func createDiarizer() -> OpaquePointer? {
        var config = configuration()
        return segmentationModelURL.path.withCString { segmentationPath in
            embeddingModelURL.path.withCString { embeddingPath in
                "cpu".withCString { provider in
                    config.segmentation.pyannote.model = segmentationPath
                    config.segmentation.provider = provider
                    config.embedding.model = embeddingPath
                    config.embedding.provider = provider
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }
    }

    private func configuration() -> SherpaOnnxOfflineSpeakerDiarizationConfig {
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.num_threads = numThreads
        config.segmentation.debug = 0
        config.embedding.num_threads = numThreads
        config.embedding.debug = 0
        // Unknown speaker count: threshold clustering remains active.
        config.clustering.num_clusters = 0
        config.clustering.threshold = 0.5
        config.min_duration_on = 0.3
        config.min_duration_off = 0.2
        return config
    }

    private func process(
        _ input: SpeakerDiarizationInput,
        diarizer: OpaquePointer
    ) throws -> SpeakerDiarizationOutput {
        let rawResult = input.samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeakerDiarizationProcess(
                diarizer,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard let rawResult else { throw EngineError.processingFailed }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(rawResult) }

        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(rawResult))
        guard count >= 0 else {
            throw EngineError.invalidResult
        }
        if count == 0 {
            return SpeakerDiarizationOutput(
                engineID: id,
                result: .init(
                    speakers: [],
                    turns: [],
                    labels: Array(repeating: nil, count: input.observations.count)
                )
            )
        }
        guard let rawSegments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(rawResult) else {
            throw EngineError.invalidResult
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(rawSegments) }

        let segments = (0..<count).compactMap { index -> Segment? in
            let raw = rawSegments.advanced(by: index).pointee
            let start = input.startSample + Int64((Double(raw.start) * 16_000).rounded())
            let end = input.startSample + Int64((Double(raw.end) * 16_000).rounded())
            guard raw.speaker >= 0, end > start else { return nil }
            return Segment(
                startSample: start,
                endSample: end,
                speaker: "说话人 \(raw.speaker + 1)"
            )
        }
        let result = makeResult(segments: segments, observations: input.observations)
        return SpeakerDiarizationOutput(engineID: id, result: result)
    }

    private struct Segment {
        let startSample: Int64
        let endSample: Int64
        let speaker: String
    }

    private func makeResult(
        segments: [Segment],
        observations: [OfflineSpeakerObservation]
    ) -> OfflineSpeakerReclustering.Result {
        var speakers: [String] = []
        let turns = segments.map { segment in
            if !speakers.contains(segment.speaker) { speakers.append(segment.speaker) }
            let provenance = observations.compactMap { observation -> String? in
                guard overlap(
                    segment.startSample,
                    segment.endSample,
                    observation.startSample,
                    observation.endSample
                ) > 0 else { return nil }
                return observation.onlineTemporaryLabel
            }
            return SpeakerTurn(
                speaker: segment.speaker,
                startSample: segment.startSample,
                endSample: segment.endSample,
                onlineTemporaryLabels: Array(Set(provenance)).sorted()
            )
        }
        let labels = observations.map { observation in
            segments.max { lhs, rhs in
                overlap(lhs.startSample, lhs.endSample, observation.startSample, observation.endSample)
                    < overlap(rhs.startSample, rhs.endSample, observation.startSample, observation.endSample)
            }.flatMap { segment in
                overlap(segment.startSample, segment.endSample, observation.startSample, observation.endSample) > 0
                    ? segment.speaker
                    : nil
            }
        }
        return OfflineSpeakerReclustering.Result(
            speakers: speakers,
            turns: turns,
            labels: labels
        )
    }

    private func overlap(_ lhsStart: Int64, _ lhsEnd: Int64, _ rhsStart: Int64, _ rhsEnd: Int64) -> Int64 {
        max(0, min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart))
    }
}

/// Plans a bounded stream and maps per-window Sherpa cluster IDs back onto the
/// meeting-wide CAM++ labels. Sherpa is allowed to restart local IDs in every
/// window; only the global labels leave finalization.
nonisolated enum SpeakerDiarizationWindowing {
    static let maximumSamples: Int64 = 60 * 16_000

    static func ranges(totalSamples: Int64) -> [(startSample: Int64, endSample: Int64)] {
        ProcessingRangePlanner.plan(
            totalSamples: totalSamples,
            rangeDurationSamples: maximumSamples
        ).map { ($0.startSample, $0.endSample) }
    }

    static func align(
        baseline: OfflineSpeakerReclustering.Result,
        observations: [OfflineSpeakerObservation],
        windowResults: [OfflineSpeakerReclustering.Result]
    ) -> OfflineSpeakerReclustering.Result {
        guard !baseline.speakers.isEmpty, !windowResults.isEmpty else { return baseline }

        var alignedTurns: [SpeakerTurn] = []
        for result in windowResults {
            let mapping = mappingForWindow(
                result,
                baseline: baseline,
                observations: observations
            )
            alignedTurns.append(contentsOf: result.turns.compactMap { turn in
                guard let local = turn.speaker,
                      let global = mapping[local] else { return nil }
                return SpeakerTurn(
                    speaker: global,
                    startSample: turn.startSample,
                    endSample: turn.endSample,
                    onlineTemporaryLabels: turn.onlineTemporaryLabels
                )
            })
        }
        guard !alignedTurns.isEmpty else { return baseline }
        return OfflineSpeakerReclustering.Result(
            speakers: baseline.speakers,
            turns: mergeAdjacent(alignedTurns),
            labels: baseline.labels
        )
    }

    private struct SpeakerPair: Hashable {
        let local: String
        let global: String
    }

    private struct PairScore {
        let pair: SpeakerPair
        let samples: Int64
    }

    private static func mappingForWindow(
        _ result: OfflineSpeakerReclustering.Result,
        baseline: OfflineSpeakerReclustering.Result,
        observations: [OfflineSpeakerObservation]
    ) -> [String: String] {
        var scores: [SpeakerPair: Int64] = [:]
        for turn in result.turns {
            guard let local = turn.speaker else { continue }
            for (index, observation) in observations.enumerated() {
                guard index < baseline.labels.count,
                      let global = baseline.labels[index] else { continue }
                let shared = overlap(
                    turn.startSample,
                    turn.endSample,
                    observation.startSample,
                    observation.endSample
                )
                if shared > 0 {
                    scores[SpeakerPair(local: local, global: global), default: 0] += shared
                }
            }
        }

        let ranked = scores.map { PairScore(pair: $0.key, samples: $0.value) }.sorted {
            if $0.samples != $1.samples { return $0.samples > $1.samples }
            if $0.pair.local != $1.pair.local { return $0.pair.local < $1.pair.local }
            return $0.pair.global < $1.pair.global
        }
        var mapping: [String: String] = [:]
        var usedGlobal: Set<String> = []
        for score in ranked where mapping[score.pair.local] == nil && !usedGlobal.contains(score.pair.global) {
            mapping[score.pair.local] = score.pair.global
            usedGlobal.insert(score.pair.global)
        }

        let localSpeakers = result.turns.compactMap(\.speaker).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for local in localSpeakers where mapping[local] == nil {
            if let strongest = ranked.first(where: { $0.pair.local == local }) {
                mapping[local] = strongest.pair.global
            } else if let nearest = nearestGlobalSpeaker(
                for: local,
                localTurns: result.turns,
                baselineTurns: baseline.turns
            ) {
                mapping[local] = nearest
            } else {
                mapping[local] = baseline.speakers.first
            }
        }
        return mapping
    }

    private static func nearestGlobalSpeaker(
        for local: String,
        localTurns: [SpeakerTurn],
        baselineTurns: [SpeakerTurn]
    ) -> String? {
        var best: (speaker: String, distance: Int64)?
        for localTurn in localTurns where localTurn.speaker == local {
            for baselineTurn in baselineTurns {
                guard let speaker = baselineTurn.speaker else { continue }
                let distance: Int64
                if overlap(
                    localTurn.startSample,
                    localTurn.endSample,
                    baselineTurn.startSample,
                    baselineTurn.endSample
                ) > 0 {
                    distance = 0
                } else {
                    distance = min(
                        abs(localTurn.startSample - baselineTurn.endSample),
                        abs(baselineTurn.startSample - localTurn.endSample)
                    )
                }
                if best == nil || distance < best!.distance {
                    best = (speaker, distance)
                }
            }
        }
        return best?.speaker
    }

    private static func mergeAdjacent(_ input: [SpeakerTurn]) -> [SpeakerTurn] {
        let ordered = input.sorted {
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return $0.endSample < $1.endSample
        }
        var merged: [SpeakerTurn] = []
        for turn in ordered {
            if let previous = merged.last,
               previous.speaker == turn.speaker,
               turn.startSample <= previous.endSample {
                merged.removeLast()
                merged.append(
                    SpeakerTurn(
                        speaker: previous.speaker,
                        startSample: previous.startSample,
                        endSample: max(previous.endSample, turn.endSample),
                        onlineTemporaryLabels: Array(Set(
                            previous.onlineTemporaryLabels + turn.onlineTemporaryLabels
                        )).sorted()
                    )
                )
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    private static func overlap(
        _ lhsStart: Int64,
        _ lhsEnd: Int64,
        _ rhsStart: Int64,
        _ rhsEnd: Int64
    ) -> Int64 {
        max(0, min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart))
    }
}

nonisolated enum SpeakerDiarizationEngineFactory {
    static let segmentationArtifactID = "pyannote-segmentation-3-int8"
    static let embeddingArtifactID = "cam-plus"

    /// Returns nil unless both model artifacts are explicitly listed in the
    /// reviewed manifest and their SHA-256 digests match the bundle.
    static func approvedSherpaEngine(bundle: Bundle = .main) -> SherpaOfflineSpeakerDiarizationEngine? {
        guard let manifestURL = bundle.url(forResource: "ModelManifest", withExtension: "json"),
              let artifacts = try? ModelIntegrity.manifest(from: manifestURL),
              let segmentation = artifacts.first(where: { $0.id == segmentationArtifactID }),
              let embedding = artifacts.first(where: { $0.id == embeddingArtifactID }) else {
            return nil
        }
        let root = manifestURL.deletingLastPathComponent()
        guard (try? ModelIntegrity.validate(segmentation, in: root)) != nil,
              (try? ModelIntegrity.validate(embedding, in: root)) != nil else {
            return nil
        }
        return SherpaOfflineSpeakerDiarizationEngine(
            segmentationModelURL: root.appending(path: segmentation.relativePath),
            embeddingModelURL: root.appending(path: embedding.relativePath)
        )
    }
}
