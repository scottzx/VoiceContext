import Foundation

/// One transcript segment plus only the private audio needed to select its
/// acoustic identity anchors. Transcript text is deliberately absent: speaker
/// assignment must remain identical when words are edited or re-translated.
nonisolated struct SegmentSpeakerAudio: Equatable, Sendable {
    let segmentID: UUID
    let startSample: Int64
    let endSample: Int64
    let samples: [Float]
}

nonisolated struct SegmentSpeakerAnchor: Equatable, Sendable {
    let segmentID: UUID
    let window: SpeakerWindow
}

/// Converts existing VAD-derived transcript ranges into at most five CAM++
/// inputs positioned at 0%, 25%, 50%, 75% and 100% of the usable window-start
/// range. Short segments naturally de-duplicate to fewer distinct windows.
nonisolated enum SegmentSpeakerAnchorPlanner {
    static let targetFractions: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static func anchors(for segments: [SegmentSpeakerAudio]) -> [SegmentSpeakerAnchor] {
        segments.flatMap(anchors)
    }

    static func anchors(for segment: SegmentSpeakerAudio) -> [SegmentSpeakerAnchor] {
        guard !segment.samples.isEmpty else { return [] }
        if segment.samples.count < Int(SpeakerWindowing.minimumWindowSamples) {
            guard let window = SpeakerWindowing.makeWholeSegmentWindow(
                samples: segment.samples,
                startingAt: segment.startSample
            ), window.isEligibleForWeakMatching else { return [] }
            return [SegmentSpeakerAnchor(segmentID: segment.segmentID, window: window)]
        }
        let candidates = SpeakerWindowing.makeWindows(
            samples: segment.samples,
            startingAt: segment.startSample
        )
        guard let first = candidates.first, let last = candidates.last else { return [] }
        let span = Double(last.startSample - first.startSample)
        var selectedStarts = Set<Int64>()
        var selected: [SegmentSpeakerAnchor] = []
        for fraction in targetFractions {
            let target = Double(first.startSample) + span * fraction
            guard let candidate = candidates.min(by: { lhs, rhs in
                let leftDistance = abs(Double(lhs.startSample) - target)
                let rightDistance = abs(Double(rhs.startSample) - target)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return lhs.startSample < rhs.startSample
            }),
            selectedStarts.insert(candidate.startSample).inserted,
            candidate.isEligibleForClustering else { continue }
            selected.append(SegmentSpeakerAnchor(
                segmentID: segment.segmentID,
                window: candidate
            ))
        }
        return selected.sorted { $0.window.startSample < $1.window.startSample }
    }
}

/// Sentence-local acoustic gate. All clean positional anchors are compared
/// before meeting-wide clustering. Only a sentence with at least two anchors
/// forming one local cluster contributes one averaged representative vector.
/// Two supported local clusters are multiple speakers; an isolated conflict
/// remains unknown until it can match two established global speakers. Neither
/// state can contaminate the global roster.
nonisolated enum SegmentSpeakerSentenceGate {
    struct Result: Equatable, Sendable {
        let attributions: [UUID: SpeakerTurn.Attribution]
        let representatives: [OfflineSpeakerObservation]
    }

    struct FinalCleanupResult: Equatable, Sendable {
        let attributions: [UUID: SpeakerTurn.Attribution]
        let supplementalLabels: [UUID: String]
    }

    static func evaluate(
        segmentIDs: [UUID],
        observations: [OfflineSpeakerObservation],
        mergeSimilarityThreshold: Float = 0.65
    ) -> Result {
        let grouped = Dictionary(grouping: observations) { observation in
            observation.onlineTemporaryLabel.flatMap(UUID.init(uuidString:))
        }
        var attributions: [UUID: SpeakerTurn.Attribution] = [:]
        var representatives: [OfflineSpeakerObservation] = []

        for segmentID in segmentIDs {
            let eligible = (grouped[segmentID] ?? [])
                .filter(\.isEligibleForClustering)
                .sorted { $0.startSample < $1.startSample }
            guard eligible.count >= 2 else {
                attributions[segmentID] = .unknown
                continue
            }
            let local = OfflineSpeakerReclustering.recluster(
                eligible,
                mergeSimilarityThreshold: mergeSimilarityThreshold,
                shortJumpMaxWindows: 0
            )
            guard local.speakers.count == 1 else {
                let support = Dictionary(grouping: local.labels.compactMap { $0 }, by: { $0 })
                    .values.map(\.count)
                attributions[segmentID] = support.filter { $0 >= 2 }.count >= 2
                    ? .multiple
                    : .unknown
                continue
            }
            guard let vector = averagedVector(eligible) else {
                attributions[segmentID] = .unknown
                continue
            }
            attributions[segmentID] = .single
            representatives.append(OfflineSpeakerObservation(
                startSample: eligible.first!.startSample,
                endSample: eligible.last!.endSample,
                embedding: .embedding(vector),
                exclusionReasons: [],
                onlineTemporaryLabel: segmentID.uuidString.lowercased()
            ))
        }
        return Result(attributions: attributions, representatives: representatives)
    }

    /// Resolves isolated local disagreements only after the meeting-wide
    /// single-sentence clusters exist. Raw anchors never create or move those
    /// clusters; they may only prove that one sentence matches two established
    /// speakers. Unmatched acoustic outliers remain unknown.
    static func validatingUnknowns(
        _ result: Result,
        observations: [OfflineSpeakerObservation],
        representativeLabels: [String?],
        mergeSimilarityThreshold: Float = 0.65
    ) -> [UUID: SpeakerTurn.Attribution] {
        let labeledRepresentatives = zip(result.representatives, representativeLabels)
            .compactMap { observation, label -> (String, [Float])? in
                guard let label, let vector = observation.embedding.vector else { return nil }
                return (label, vector)
            }
        let centroids = Dictionary(grouping: labeledRepresentatives, by: \.0)
            .compactMapValues { values in
                averagedVectors(values.map(\.1))
            }
        guard centroids.count >= 2 else { return result.attributions }

        let grouped = Dictionary(grouping: observations) { observation in
            observation.onlineTemporaryLabel.flatMap(UUID.init(uuidString:))
        }
        var validated = result.attributions
        for (segmentID, attribution) in result.attributions where attribution == .unknown {
            let matched = (grouped[segmentID] ?? []).compactMap { observation -> String? in
                guard observation.isEligibleForClustering,
                      let vector = observation.embedding.vector else { return nil }
                let best = centroids.compactMap { label, centroid -> (String, Float)? in
                    guard let score = SpeakerSimilarity.cosineSimilarity(vector, centroid) else {
                        return nil
                    }
                    return (label, score)
                }.max { $0.1 < $1.1 }
                guard let best, best.1 >= mergeSimilarityThreshold else { return nil }
                return best.0
            }
            if Set(matched).count >= 2 {
                validated[segmentID] = .multiple
            }
        }
        return validated
    }

    /// Final cleanup only: a sentence with exactly one usable anchor may match
    /// an already-established meeting speaker. It never creates a cluster or
    /// changes a centroid, and ambiguous matches remain unknown.
    static func matchingSingleAnchorUnknowns(
        attributions: [UUID: SpeakerTurn.Attribution],
        observations: [OfflineSpeakerObservation],
        representatives: [OfflineSpeakerObservation],
        representativeLabels: [String?],
        minimumSimilarity: Float = 0.70,
        minimumMargin: Float = 0.05
    ) -> FinalCleanupResult {
        let labeledRepresentatives = zip(representatives, representativeLabels)
            .compactMap { observation, label -> (String, [Float])? in
                guard let label, let vector = observation.embedding.vector else { return nil }
                return (label, vector)
            }
        let centroids = Dictionary(grouping: labeledRepresentatives, by: \.0)
            .compactMapValues { values in averagedVectors(values.map(\.1)) }
        guard !centroids.isEmpty else {
            return FinalCleanupResult(attributions: attributions, supplementalLabels: [:])
        }

        let grouped = Dictionary(grouping: observations) { observation in
            observation.onlineTemporaryLabel.flatMap(UUID.init(uuidString:))
        }
        var cleaned = attributions
        var supplementalLabels: [UUID: String] = [:]
        for (segmentID, attribution) in attributions where attribution == .unknown {
            let anchors = (grouped[segmentID] ?? []).filter(\.isEligibleForWeakMatching)
            guard anchors.count == 1,
                  let vector = anchors[0].embedding.vector else { continue }
            let scored = centroids.compactMap { label, centroid -> (String, Float)? in
                guard let score = SpeakerSimilarity.cosineSimilarity(vector, centroid) else {
                    return nil
                }
                return (label, score)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0 < $1.0
            }
            guard let best = scored.first, best.1 >= minimumSimilarity else { continue }
            if scored.count > 1 {
                guard best.1 - scored[1].1 >= minimumMargin else { continue }
            }
            cleaned[segmentID] = .single
            supplementalLabels[segmentID] = best.0
        }
        return FinalCleanupResult(
            attributions: cleaned,
            supplementalLabels: supplementalLabels
        )
    }

    private static func averagedVector(
        _ observations: [OfflineSpeakerObservation]
    ) -> [Float]? {
        let vectors = observations.compactMap(\.embedding.vector)
        guard vectors.count == observations.count else { return nil }
        return averagedVectors(vectors)
    }

    private static func averagedVectors(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count,
              dimension > 0,
              vectors.allSatisfy({ $0.count == dimension }) else { return nil }
        var average = Array(repeating: Float.zero, count: dimension)
        for vector in vectors {
            for index in vector.indices {
                average[index] += vector[index]
            }
        }
        let divisor = Float(vectors.count)
        for index in average.indices {
            average[index] /= divisor
        }
        return average.allSatisfy(\.isFinite) ? average : nil
    }
}

nonisolated enum SegmentSpeakerAssignmentResolver {
    struct Segment: Equatable, Sendable {
        let id: UUID
        let startSample: Int64
        let endSample: Int64
    }

    struct Result: Equatable, Sendable {
        let speakers: [String]
        let turns: [SpeakerTurn]
        let unknownSegmentCount: Int
        let multipleSegmentCount: Int
    }

    static func resolve(
        segments: [Segment],
        attributions: [UUID: SpeakerTurn.Attribution],
        representativeSegmentIDs: [UUID?],
        representativeLabels: [String?],
        supplementalLabels: [UUID: String] = [:]
    ) -> Result {
        let ordered = segments.sorted {
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return $0.endSample < $1.endSample
        }
        let resolved = ordered.map { segment -> (speaker: String?, attribution: SpeakerTurn.Attribution) in
            let requested = attributions[segment.id] ?? .unknown
            guard requested == .single else { return (nil, requested) }
            var valid = zip(representativeSegmentIDs, representativeLabels).compactMap { id, label in
                id == segment.id ? label : nil
            }
            if let supplemental = supplementalLabels[segment.id] {
                valid.append(supplemental)
            }
            let distinct = Array(Set(valid))
            guard distinct.count == 1 else { return (nil, .unknown) }
            return (distinct[0], .single)
        }

        var turns: [SpeakerTurn] = []
        for (segment, item) in zip(ordered, resolved) {
            if item.attribution == .single,
               let previous = turns.last,
               previous.attribution == .single,
               previous.speaker == item.speaker {
                turns.removeLast()
                turns.append(SpeakerTurn(
                    speaker: item.speaker,
                    attribution: .single,
                    startSample: previous.startSample,
                    endSample: max(previous.endSample, segment.endSample),
                    onlineTemporaryLabels: previous.onlineTemporaryLabels
                ))
            } else {
                turns.append(SpeakerTurn(
                    speaker: item.speaker,
                    attribution: item.attribution,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    onlineTemporaryLabels: []
                ))
            }
        }
        let speakers = resolved.compactMap(\.speaker).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return Result(
            speakers: speakers,
            turns: turns,
            unknownSegmentCount: resolved.filter { $0.attribution == .unknown }.count,
            multipleSegmentCount: resolved.filter { $0.attribution == .multiple }.count
        )
    }
}
