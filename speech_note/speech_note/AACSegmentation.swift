import Foundation

nonisolated struct AACChunkBoundaryPlanner: Sendable {
    nonisolated struct Slice: Equatable, Sendable {
        let sourceOffset: Int64
        let frameCount: Int64
        let segmentStartSample: Int64
        let endSample: Int64
        let closesSegment: Bool
    }

    let segmentLengthSamples: Int64
    private(set) var currentSample: Int64 = 0
    private(set) var currentSegmentStartSample: Int64 = 0

    init(segmentLengthSamples: Int64) {
        precondition(segmentLengthSamples > 0)
        self.segmentLengthSamples = segmentLengthSamples
    }

    mutating func slices(for frameCount: Int64) -> [Slice] {
        guard frameCount > 0 else { return [] }
        var sourceOffset: Int64 = 0
        var remaining = frameCount
        var result: [Slice] = []

        while remaining > 0 {
            let usedInSegment = currentSample - currentSegmentStartSample
            let availableInSegment = segmentLengthSamples - usedInSegment
            let count = min(remaining, availableInSegment)
            currentSample += count
            remaining -= count
            let closes = currentSample - currentSegmentStartSample == segmentLengthSamples
            result.append(Slice(
                sourceOffset: sourceOffset,
                frameCount: count,
                segmentStartSample: currentSegmentStartSample,
                endSample: currentSample,
                closesSegment: closes
            ))
            sourceOffset += count
            if closes {
                currentSegmentStartSample = currentSample
            }
        }
        return result
    }
}
