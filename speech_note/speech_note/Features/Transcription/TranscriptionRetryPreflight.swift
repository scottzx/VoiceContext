import AVFoundation
import Foundation

/// Transient retry scope. Availability requires decoding, rather than merely
/// finding a file; this never changes retention or the saved transcript.
nonisolated enum TranscriptionRetryPreflight {
    struct Plan: Sendable {
        let chunks: [AudioChunk]
        let ranges: [ProcessingRange]
        let unavailableSourceCount: Int

        var hasReadableAudio: Bool { !chunks.isEmpty || !ranges.isEmpty }
    }

    static func evaluate(
        chunks: [AudioChunk],
        ranges: [ProcessingRange],
        asset: ImportedAudioAsset?,
        rootURL: URL
    ) -> Plan {
        if let asset {
            let readable = ranges.filter { range in
                guard asset.audioRemovedAt == nil else { return false }
                return isReadable(
                    url: rootURL.appendingPathComponent(asset.relativePath),
                    startSample: range.startSample,
                    endSample: range.endSample
                )
            }
            return Plan(chunks: [], ranges: readable, unavailableSourceCount: ranges.count - readable.count)
        }
        let sources = chunks.filter { $0.state != .writing }
        let readable = sources.filter { chunk in
            guard chunk.state == .closed, chunk.audioRemovedAt == nil else { return false }
            return isReadable(
                url: rootURL.appendingPathComponent(chunk.relativePath),
                startSample: 0,
                endSample: chunk.endSample - chunk.startSample
            )
        }
        return Plan(chunks: readable, ranges: [], unavailableSourceCount: sources.count - readable.count)
    }

    private static func isReadable(url: URL, startSample: Int64, endSample: Int64) -> Bool {
        guard startSample >= 0, endSample > startSample,
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return false }
        let availableSamples = Int64((Double(file.length) / file.processingFormat.sampleRate
            * ProcessingRangePlanner.sampleRate).rounded(.down))
        // The decoder pads some short reads. Do not count that synthesized
        // silence as evidence that a truncated source covers the retry window.
        guard endSample <= availableSamples,
              let samples = try? ImportAudioRangeDecoder.samples(
                  from: url, startSample: startSample, endSample: endSample
              ) else { return false }
        return samples.count >= Int(endSample - startSample)
    }
}
