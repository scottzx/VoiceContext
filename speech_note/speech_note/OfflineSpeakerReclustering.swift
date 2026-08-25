import Accelerate
import Foundation

/// One short window retained for post-meeting re-clustering. Embeddings stay
/// in this processing-only value; the public transcript stores turns/labels,
/// never raw vectors.
nonisolated struct OfflineSpeakerObservation: Codable, Equatable, Sendable {
    let startSample: Int64
    let endSample: Int64
    let embedding: SpeakerEmbeddingResult
    let exclusionReasons: [SpeakerWindow.ExclusionReason]
    /// Meeting-local online label when one was assigned; used only as provenance
    /// when offline re-clustering renumbers speakers.
    let onlineTemporaryLabel: String?

    var isEligibleForClustering: Bool {
        exclusionReasons.isEmpty && embedding.vector != nil
    }

    var isEligibleForWeakMatching: Bool {
        exclusionReasons.allSatisfy { $0 == .tooShort } && embedding.vector != nil
    }

    private enum CodingKeys: String, CodingKey {
        case startSample = "start_sample"
        case endSample = "end_sample"
        case embedding
        case exclusionReasons = "exclusion_reasons"
        case onlineTemporaryLabel = "online_temporary_label"
    }
}

/// Incremental, processing-only storage for sentence-level CAM++ observations.
///
/// New recordings use one atomically replaced JSON batch per AudioChunk or
/// ProcessingRange. A retry therefore rewrites only its own minute instead of
/// reading and rewriting the meeting's complete embedding history. The legacy
/// whole-recording JSON is still read so existing recordings can finish after
/// an app update.
nonisolated enum SpeakerObservationStore {
    private static let batchDirectoryName = "Batches"

    /// Legacy whole-recording file used by builds before the incremental store.
    static func storageURL(rootURL: URL, recordingID: UUID) -> URL {
        rootURL
            .appendingPathComponent("SpeakerObservations", isDirectory: true)
            .appendingPathComponent("\(recordingID.uuidString.uppercased()).json", isDirectory: false)
    }

    static func batchDirectoryURL(rootURL: URL, recordingID: UUID) -> URL {
        rootURL
            .appendingPathComponent("SpeakerObservations", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString.uppercased(), isDirectory: true)
            .appendingPathComponent(batchDirectoryName, isDirectory: true)
    }

    static func batchURL(rootURL: URL, recordingID: UUID, batchID: UUID) -> URL {
        batchDirectoryURL(rootURL: rootURL, recordingID: recordingID)
            .appendingPathComponent("\(batchID.uuidString.uppercased()).json", isDirectory: false)
    }

    static func load(rootURL: URL, recordingID: UUID) -> [OfflineSpeakerObservation] {
        let decoder = JSONDecoder()
        var observations: [OfflineSpeakerObservation] = []

        let legacyURL = storageURL(rootURL: rootURL, recordingID: recordingID)
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? decoder.decode([OfflineSpeakerObservation].self, from: data) {
            observations.append(contentsOf: legacy)
        }

        let directory = batchDirectoryURL(rootURL: rootURL, recordingID: recordingID)
        let batchURLs = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in batchURLs {
            guard let data = try? Data(contentsOf: url),
                  let batch = try? decoder.decode([OfflineSpeakerObservation].self, from: data) else {
                continue
            }
            for observation in batch {
                observations.removeAll { existing in
                    max(existing.startSample, observation.startSample)
                        < min(existing.endSample, observation.endSample)
                }
                observations.append(observation)
            }
        }

        observations.sort {
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return $0.endSample < $1.endSample
        }
        return observations
    }

    /// Compatibility writer for a one-time legacy/backfill pass. Hot-path
    /// callers must use `replaceBatch` instead.
    static func save(_ observations: [OfflineSpeakerObservation], rootURL: URL, recordingID: UUID) {
        let url = storageURL(rootURL: rootURL, recordingID: recordingID)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(observations) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(rootURL: URL, recordingID: UUID) {
        try? FileManager.default.removeItem(at: storageURL(rootURL: rootURL, recordingID: recordingID))
        try? FileManager.default.removeItem(
            at: batchDirectoryURL(rootURL: rootURL, recordingID: recordingID)
                .deletingLastPathComponent()
        )
    }

    /// Atomically replaces observations for one stable source target. This is
    /// idempotent across retries and never rewrites another minute's vectors.
    static func replaceBatch(
        _ observations: [OfflineSpeakerObservation],
        rootURL: URL,
        recordingID: UUID,
        batchID: UUID
    ) throws {
        let directory = batchDirectoryURL(rootURL: rootURL, recordingID: recordingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(observations.sorted {
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return $0.endSample < $1.endSample
        })
        try data.write(
            to: batchURL(rootURL: rootURL, recordingID: recordingID, batchID: batchID),
            options: .atomic
        )
    }
}

/// Stable, meeting-local turn after offline cosine agglomerative clustering.
/// `speaker` is nil for unknown/unreliable windows (overlap, low quality, or
/// failed embeddings). Online temporary labels are retained for audit only.
nonisolated struct SpeakerTurn: Codable, Equatable, Sendable {
    enum Attribution: String, Codable, Equatable, Sendable {
        case single
        case multiple
        case unknown
    }

    let speaker: String?
    let attribution: Attribution
    let startSample: Int64
    let endSample: Int64
    let onlineTemporaryLabels: [String]

    var isUnknown: Bool { attribution == .unknown }

    init(
        speaker: String?,
        attribution: Attribution? = nil,
        startSample: Int64,
        endSample: Int64,
        onlineTemporaryLabels: [String]
    ) {
        self.speaker = speaker
        self.attribution = attribution ?? (speaker == nil ? .unknown : .single)
        self.startSample = startSample
        self.endSample = endSample
        self.onlineTemporaryLabels = onlineTemporaryLabels
    }

    private enum CodingKeys: String, CodingKey {
        case speaker
        case attribution
        case startSample = "start_sample"
        case endSample = "end_sample"
        case onlineTemporaryLabels = "online_temporary_labels"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        attribution = try container.decodeIfPresent(Attribution.self, forKey: .attribution)
            ?? (speaker == nil ? .unknown : .single)
        startSample = try container.decode(Int64.self, forKey: .startSample)
        endSample = try container.decode(Int64.self, forKey: .endSample)
        onlineTemporaryLabels = try container.decodeIfPresent(
            [String].self,
            forKey: .onlineTemporaryLabels
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(speaker, forKey: .speaker)
        try container.encode(attribution, forKey: .attribution)
        try container.encode(startSample, forKey: .startSample)
        try container.encode(endSample, forKey: .endSample)
        try container.encode(onlineTemporaryLabels, forKey: .onlineTemporaryLabels)
    }
}

/// FR-SPK-004: after capture ends, re-cluster every eligible short window with
/// cosine-distance agglomerative clustering. No speaker count is required.
/// Short singleton jumps are smoothed, adjacent same-speaker windows collapse
/// into turns, and IDs are renumbered by first appearance while keeping the
/// online temporary labels as provenance.
nonisolated enum OfflineSpeakerReclustering {
    struct Result: Equatable, Sendable {
        let speakers: [String]
        let turns: [SpeakerTurn]
        /// Per-observation offline labels (`nil` = unknown), aligned with input.
        let labels: [String?]
    }

    /// Minimum cosine similarity required to merge two clusters. Matches the
    /// online "likely same speaker" floor so uncertain similarities do not
    /// force a merge without presetting a speaker count.
    static let mergeSimilarityThreshold = SpeakerSimilarity.likelySameSpeakerThreshold

    /// A run this short that disagrees with both temporal neighbors is treated
    /// as a labeling jump and reassigned to the surrounding speaker.
    static let shortJumpMaxWindows = 1

    static func recluster(
        _ observations: [OfflineSpeakerObservation],
        mergeSimilarityThreshold: Float = mergeSimilarityThreshold,
        shortJumpMaxWindows: Int = shortJumpMaxWindows
    ) -> Result {
        guard !observations.isEmpty else {
            return Result(speakers: [], turns: [], labels: [])
        }

        let ordered = observations.enumerated().sorted { lhs, rhs in
            if lhs.element.startSample != rhs.element.startSample {
                return lhs.element.startSample < rhs.element.startSample
            }
            return lhs.offset < rhs.offset
        }

        var clusterOfObservation = Array(repeating: -1, count: observations.count)
        var clusters: [Cluster] = []

        // Seed every eligible window as its own cluster; merges below discover
        // the speaker count without a preset k.
        for item in ordered {
            let observation = item.element
            guard observation.isEligibleForClustering,
                  let vector = normalized(observation.embedding.vector!) else {
                continue
            }
            let id = clusters.count
            clusters.append(Cluster(centroid: vector, memberCount: 1))
            clusterOfObservation[item.offset] = id
        }

        agglomerate(
            clusters: &clusters,
            clusterOfObservation: &clusterOfObservation,
            mergeSimilarityThreshold: mergeSimilarityThreshold
        )

        var rawLabels: [String?] = observations.indices.map { index in
            let clusterID = clusterOfObservation[index]
            guard clusterID >= 0 else { return nil }
            return TemporarySpeakerLabeling.temporaryLabel(id: clusterID + 1)
        }

        smoothShortJumps(
            labels: &rawLabels,
            observations: observations,
            maxJumpWindows: shortJumpMaxWindows
        )

        let (speakers, remapped) = renumberByFirstAppearance(labels: rawLabels)
        let turns = makeTurns(
            observations: observations,
            labels: remapped
        )
        return Result(speakers: speakers, turns: turns, labels: remapped)
    }

    // MARK: - Agglomerative clustering

    private struct Cluster {
        var centroid: [Float]
        var memberCount: Int
    }

    private struct SimilarityCandidate {
        let lhs: Int
        let rhs: Int
        let lhsGeneration: Int
        let rhsGeneration: Int
        let similarity: Float
    }

    private static func agglomerate(
        clusters: inout [Cluster],
        clusterOfObservation: inout [Int],
        mergeSimilarityThreshold: Float
    ) {
        guard clusters.count > 1 else { return }

        // Keep stable cluster slots and a versioned max-heap. A merge changes
        // only one centroid, so unchanged pairs stay valid in the heap and
        // only the merged cluster's candidates are recomputed.
        let capacity = clusters.count
        var active = Array(repeating: true, count: capacity)
        var generations = Array(repeating: 0, count: capacity)
        var heap: [SimilarityCandidate] = []
        heap.reserveCapacity(capacity * max(0, capacity - 1) / 2)
        for i in 0..<capacity {
            for j in (i + 1)..<capacity {
                guard let similarity = normalizedCosineSimilarity(
                    clusters[i].centroid,
                    clusters[j].centroid
                ) else { continue }
                push(SimilarityCandidate(
                    lhs: i,
                    rhs: j,
                    lhsGeneration: 0,
                    rhsGeneration: 0,
                    similarity: similarity
                ), onto: &heap)
            }
        }

        while let best = popValid(
            from: &heap,
            active: active,
            generations: generations
        ) {
            guard best.similarity >= mergeSimilarityThreshold else { break }

            let keep = best.lhs
            let drop = best.rhs
            clusters[keep] = merge(clusters[keep], clusters[drop])
            active[drop] = false
            generations[keep] += 1
            generations[drop] += 1

            for index in clusterOfObservation.indices {
                if clusterOfObservation[index] == drop {
                    clusterOfObservation[index] = keep
                }
            }
            for other in 0..<capacity where active[other] && other != keep {
                guard let similarity = normalizedCosineSimilarity(
                    clusters[keep].centroid,
                    clusters[other].centroid
                ) else { continue }
                let lhs = min(keep, other)
                let rhs = max(keep, other)
                push(SimilarityCandidate(
                    lhs: lhs,
                    rhs: rhs,
                    lhsGeneration: generations[lhs],
                    rhsGeneration: generations[rhs],
                    similarity: similarity
                ), onto: &heap)
            }
        }
    }

    private static func candidatePrecedes(
        _ lhs: SimilarityCandidate,
        _ rhs: SimilarityCandidate
    ) -> Bool {
        if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
        if lhs.lhs != rhs.lhs { return lhs.lhs < rhs.lhs }
        return lhs.rhs < rhs.rhs
    }

    private static func push(
        _ candidate: SimilarityCandidate,
        onto heap: inout [SimilarityCandidate]
    ) {
        heap.append(candidate)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard candidatePrecedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func pop(
        from heap: inout [SimilarityCandidate]
    ) -> SimilarityCandidate? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let result = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            let child = right < heap.count && candidatePrecedes(heap[right], heap[left])
                ? right
                : left
            guard candidatePrecedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            parent = child
        }
        return result
    }

    private static func popValid(
        from heap: inout [SimilarityCandidate],
        active: [Bool],
        generations: [Int]
    ) -> SimilarityCandidate? {
        while let candidate = pop(from: &heap) {
            guard active[candidate.lhs], active[candidate.rhs],
                  generations[candidate.lhs] == candidate.lhsGeneration,
                  generations[candidate.rhs] == candidate.rhsGeneration else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func merge(_ lhs: Cluster, _ rhs: Cluster) -> Cluster {
        let total = lhs.memberCount + rhs.memberCount
        guard total > 0 else { return lhs }
        let weighted = zip(lhs.centroid, rhs.centroid).map { left, right in
            (left * Float(lhs.memberCount) + right * Float(rhs.memberCount)) / Float(total)
        }
        guard let centroid = normalized(weighted) else { return lhs }
        return Cluster(centroid: centroid, memberCount: total)
    }

    /// Reclustering normalizes every observation and every merged centroid.
    /// Accelerate can therefore compute cosine similarity as one vector dot
    /// product instead of rechecking and renormalizing both 512-D vectors for
    /// every hierarchy candidate.
    private static func normalizedCosineSimilarity(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot: Float = 0
        vDSP_dotpr(
            lhs,
            1,
            rhs,
            1,
            &dot,
            vDSP_Length(lhs.count)
        )
        guard dot.isFinite else { return nil }
        return min(1, max(-1, dot))
    }

    // MARK: - Smoothing / turns / renumber

    private static func smoothShortJumps(
        labels: inout [String?],
        observations: [OfflineSpeakerObservation],
        maxJumpWindows: Int
    ) {
        guard maxJumpWindows > 0, labels.count == observations.count else { return }
        let order = observations.indices.sorted {
            if observations[$0].startSample != observations[$1].startSample {
                return observations[$0].startSample < observations[$1].startSample
            }
            return $0 < $1
        }
        guard order.count >= 3 else { return }

        var index = 1
        while index < order.count - 1 {
            let currentLabel = labels[order[index]]
            guard let currentLabel else {
                index += 1
                continue
            }

            var runEnd = index
            while runEnd + 1 < order.count,
                  labels[order[runEnd + 1]] == currentLabel {
                runEnd += 1
            }
            let runLength = runEnd - index + 1
            let leftLabel = labels[order[index - 1]]
            let rightIndex = runEnd + 1
            let rightLabel = rightIndex < order.count ? labels[order[rightIndex]] : nil

            if runLength <= maxJumpWindows,
               let leftLabel,
               leftLabel == rightLabel,
               leftLabel != currentLabel {
                for offset in index...runEnd {
                    labels[order[offset]] = leftLabel
                }
            }
            index = runEnd + 1
        }
    }

    private static func renumberByFirstAppearance(
        labels: [String?]
    ) -> (speakers: [String], remapped: [String?]) {
        var map: [String: String] = [:]
        var speakers: [String] = []
        var nextID = 1
        let remapped: [String?] = labels.map { label in
            guard let label else { return nil }
            if let existing = map[label] { return existing }
            let stable = TemporarySpeakerLabeling.temporaryLabel(id: nextID)
            nextID += 1
            map[label] = stable
            speakers.append(stable)
            return stable
        }
        return (speakers, remapped)
    }

    private static func makeTurns(
        observations: [OfflineSpeakerObservation],
        labels: [String?]
    ) -> [SpeakerTurn] {
        let order = observations.indices.sorted {
            if observations[$0].startSample != observations[$1].startSample {
                return observations[$0].startSample < observations[$1].startSample
            }
            return $0 < $1
        }
        guard let first = order.first else { return [] }

        var turns: [SpeakerTurn] = []
        var runLabel = labels[first]
        var runStart = observations[first].startSample
        var runEnd = observations[first].endSample
        var provenance = Set(observations[first].onlineTemporaryLabel.map { [$0] } ?? [])

        for index in order.dropFirst() {
            let label = labels[index]
            let observation = observations[index]
            if label == runLabel {
                runEnd = max(runEnd, observation.endSample)
                if let online = observation.onlineTemporaryLabel {
                    provenance.insert(online)
                }
                continue
            }
            turns.append(
                SpeakerTurn(
                    speaker: runLabel,
                    startSample: runStart,
                    endSample: runEnd,
                    onlineTemporaryLabels: provenance.sorted()
                )
            )
            runLabel = label
            runStart = observation.startSample
            runEnd = observation.endSample
            provenance = Set(observation.onlineTemporaryLabel.map { [$0] } ?? [])
        }
        turns.append(
            SpeakerTurn(
                speaker: runLabel,
                startSample: runStart,
                endSample: runEnd,
                onlineTemporaryLabels: provenance.sorted()
            )
        )
        return turns
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        let squared = vector.reduce(Float.zero) { $0 + $1 * $1 }
        let norm = sqrt(squared)
        guard vector.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else { return nil }
        let values = vector.map { $0 / norm }
        guard values.allSatisfy(\.isFinite) else { return nil }
        return values
    }
}

/// Builds offline observations from short windows + online assignments. Used by
/// analysis and by the post-recording recluster pass.
nonisolated enum OfflineSpeakerObservationBuilder {
    static func make(
        windows: [SpeakerWindow],
        embeddings: [SpeakerEmbeddingResult],
        assignments: [TemporarySpeakerAssignment]
    ) -> [OfflineSpeakerObservation] {
        let count = min(windows.count, min(embeddings.count, assignments.count))
        return (0..<count).map { index in
            OfflineSpeakerObservation(
                startSample: windows[index].startSample,
                endSample: windows[index].endSample,
                embedding: embeddings[index],
                exclusionReasons: windows[index].exclusionReasons,
                onlineTemporaryLabel: assignments[index].temporarySpeakerLabel
            )
        }
    }
}

/// Post-meeting pass: decode closed chunks, collect short-window embeddings on
/// CPU (CAM++), then replace the online temporary roster with stable turns.
/// Does not submit SenseVoice / Metal work.
enum OfflineSpeakerReclusterPass {
    struct PassResult: Equatable, Sendable {
        let recluster: OfflineSpeakerReclustering.Result
        let observations: [OfflineSpeakerObservation]
    }

    enum PassError: LocalizedError {
        case missingResource(String)
        case missingManifest

        var errorDescription: String? {
            switch self {
            case let .missingResource(name):
                "离线重聚类缺少模型：\(name)。"
            case .missingManifest:
                "离线重聚类找不到 ModelManifest.json。"
            }
        }
    }

    nonisolated static func bundledResourceRoot(bundle: Bundle = .main) throws -> URL {
        guard let manifestURL = bundle.url(forResource: "ModelManifest", withExtension: "json") else {
            throw PassError.missingManifest
        }
        return manifestURL.deletingLastPathComponent()
    }

    static func run(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) async throws -> PassResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(chunkURLs: chunkURLs, resourceRoot: resourceRoot)
        }.value
    }

    /// Files-import path: decode the private asset in 60s windows (same budget
    /// as ProcessingRange) so multi-minute imports recluster without loading
    /// the whole file as one array when possible.
    static func runImportedAsset(
        url: URL,
        totalSamples: Int64,
        resourceRoot: URL
    ) async throws -> PassResult {
        try await Task.detached(priority: .userInitiated) {
            try runImportedAssetSync(
                url: url,
                totalSamples: totalSamples,
                resourceRoot: resourceRoot
            )
        }.value
    }

    /// Shared with ProcessingRange planning so offline recluster covers every
    /// imported logical window (20s / 81s / 5min) without a second policy.
    nonisolated static func importWindows(
        totalSamples: Int64
    ) -> [(startSample: Int64, endSample: Int64)] {
        ProcessingRangePlanner.plan(totalSamples: totalSamples).map {
            (startSample: $0.startSample, endSample: $0.endSample)
        }
    }

    nonisolated private static func runSync(
        chunkURLs: [(url: URL, startSample: Int64)],
        resourceRoot: URL
    ) throws -> PassResult {
        try ensureSpeakerModels(resourceRoot: resourceRoot)

        var observations: [OfflineSpeakerObservation] = []
        for chunk in chunkURLs {
            let samples = try PCM16KMonoLoader.samples(from: chunk.url)
            guard !samples.isEmpty else { continue }
            // Fresh online clusterer per chunk mirrors the live path so
            // provenance shows the unstable temporary IDs offline corrects.
            let analysis = try SpeechAnalysisService.collectSpeakerObservations(
                samples: samples,
                resourceRoot: resourceRoot,
                startingAt: chunk.startSample
            )
            observations.append(contentsOf: analysis)
        }
        let recluster = OfflineSpeakerReclustering.recluster(observations)
        return PassResult(recluster: recluster, observations: observations)
    }

    nonisolated private static func runImportedAssetSync(
        url: URL,
        totalSamples: Int64,
        resourceRoot: URL
    ) throws -> PassResult {
        try ensureSpeakerModels(resourceRoot: resourceRoot)
        guard totalSamples > 0 else {
            return PassResult(recluster: .init(speakers: [], turns: [], labels: []), observations: [])
        }

        var observations: [OfflineSpeakerObservation] = []
        let windows = importWindows(totalSamples: totalSamples)
        for window in windows {
            let samples = try ImportAudioRangeDecoder.samples(
                from: url,
                startSample: window.startSample,
                endSample: window.endSample
            )
            guard !samples.isEmpty else { continue }
            let analysis = try SpeechAnalysisService.collectSpeakerObservations(
                samples: samples,
                resourceRoot: resourceRoot,
                startingAt: window.startSample
            )
            observations.append(contentsOf: analysis)
        }
        let recluster = OfflineSpeakerReclustering.recluster(observations)
        return PassResult(recluster: recluster, observations: observations)
    }

    nonisolated private static func ensureSpeakerModels(resourceRoot: URL) throws {
        let speakerModel = resourceRoot.appending(path: "3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx")
        let vadModel = resourceRoot.appending(path: "silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: speakerModel.path) else {
            throw PassError.missingResource(speakerModel.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: vadModel.path) else {
            throw PassError.missingResource(vadModel.lastPathComponent)
        }
    }
}
