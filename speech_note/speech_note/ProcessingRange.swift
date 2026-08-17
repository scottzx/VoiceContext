import Foundation

/// Default logical processing window for Files-imported audio. Matches the
/// microphone AudioChunk budget so SenseVoice / VAD stay bounded, without
/// cutting the private media asset into many 60-second files.
nonisolated enum ProcessingRangePlanner: Sendable {
    static let sampleRate: Double = 16_000
    static let defaultDurationSamples: Int64 = 960_000
    static let pipelineVersion = 1

    /// Builds contiguous half-open `[startSample, endSample)` ranges covering
    /// `totalSamples`. The final range may be shorter than 60 seconds.
    nonisolated static func plan(
        totalSamples: Int64,
        rangeDurationSamples: Int64 = defaultDurationSamples
    ) -> [(sequence: Int, startSample: Int64, endSample: Int64)] {
        guard totalSamples > 0 else { return [] }
        let duration = max(1, rangeDurationSamples)
        var result: [(Int, Int64, Int64)] = []
        var start: Int64 = 0
        var sequence = 0
        while start < totalSamples {
            let end = min(totalSamples, start + duration)
            result.append((sequence, start, end))
            sequence += 1
            start = end
        }
        return result
    }

    nonisolated static func totalSamples(duration: TimeInterval) -> Int64 {
        Int64((duration * sampleRate).rounded(.down))
    }
}

/// Walks multi-hop open-speech continuation so decode windows and commits cover
/// the full carried chain, not only the immediate predecessor.
nonisolated enum SampleWindowContinuation: Sendable {
    /// Ranges immediately before `current` that still require continuation,
    /// oldest-first. Stops at the first break in the half-open sample chain.
    nonisolated static func leadingProcessingRanges(
        endingAt current: ProcessingRange,
        among ranges: [ProcessingRange]
    ) -> [ProcessingRange] {
        leading(
            currentStart: current.startSample,
            items: ranges,
            start: \.startSample,
            end: \.endSample,
            requiresContinuation: \.requiresContinuation
        )
    }

    /// Microphone chunks immediately before `current` that still require
    /// continuation, oldest-first.
    nonisolated static func leadingAudioChunks(
        endingAt current: AudioChunk,
        among chunks: [AudioChunk]
    ) -> [AudioChunk] {
        leading(
            currentStart: current.startSample,
            items: chunks,
            start: \.startSample,
            end: \.endSample,
            requiresContinuation: \.requiresContinuation
        )
    }

    nonisolated private static func leading<T>(
        currentStart: Int64,
        items: [T],
        start: KeyPath<T, Int64>,
        end: KeyPath<T, Int64>,
        requiresContinuation: KeyPath<T, Bool>
    ) -> [T] {
        var chain: [T] = []
        var cursor = currentStart
        var guardCount = 0
        while guardCount <= items.count {
            guardCount += 1
            guard let previous = items.first(where: {
                $0[keyPath: end] == cursor && $0[keyPath: requiresContinuation]
            }) else {
                break
            }
            chain.insert(previous, at: 0)
            cursor = previous[keyPath: start]
        }
        return chain
    }
}

nonisolated enum ProcessingRangeState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

/// Logical 60-second processing unit over one ImportedAudioAsset. It is not a
/// media file: playback always uses the complete private asset.
nonisolated struct ProcessingRange: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let assetID: UUID
    let sequence: Int
    let startSample: Int64
    let endSample: Int64
    var state: ProcessingRangeState
    var requiresContinuation: Bool
    var attemptCount: Int
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        assetID: UUID,
        sequence: Int,
        startSample: Int64,
        endSample: Int64,
        state: ProcessingRangeState = .pending,
        requiresContinuation: Bool = false,
        attemptCount: Int = 0,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.recordingID = recordingID
        self.assetID = assetID
        self.sequence = sequence
        self.startSample = startSample
        self.endSample = endSample
        self.state = state
        self.requiresContinuation = requiresContinuation
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var sampleCount: Int64 { max(0, endSample - startSample) }

    /// Stable idempotency key for range jobs (design: recording + range + pipeline).
    var jobIdempotencyKey: String {
        "\(recordingID.uuidString)|\(id.uuidString)|v\(ProcessingRangePlanner.pipelineVersion)"
    }
}
