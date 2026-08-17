import SwiftUI

/// Pure helpers for detail playback polish (FR-ADD-PLY-001/002/004).
enum RecordingDetailPlaybackPresentation {
    static let skipSeconds: TimeInterval = 10

    struct TimedRow: Equatable, Identifiable {
        let id: UUID
        let offsetMilliseconds: Int
        let endMilliseconds: Int
        let speaker: String?
        let text: String

        var startTime: TimeInterval { Double(offsetMilliseconds) / 1_000 }
        var endTime: TimeInterval { Double(max(endMilliseconds, offsetMilliseconds)) / 1_000 }
    }

    /// First-seen unique non-empty speaker labels (stable color roster).
    static func legendSpeakers(from speakers: [String?]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for speaker in speakers {
            guard let speaker, !speaker.isEmpty else { continue }
            if seen.insert(speaker).inserted {
                ordered.append(speaker)
            }
        }
        return ordered
    }

    static func color(for speaker: String, roster: [String]) -> Color {
        let palette: [Color] = [
            .blue, .orange, .purple, .teal, .pink, .indigo, .green, .brown
        ]
        guard let index = roster.firstIndex(of: speaker) else {
            return .secondary
        }
        return palette[index % palette.count]
    }

    /// Row under the playhead. Prefers a containing range; otherwise the last
    /// row that has already started (covers gaps / exact end boundaries).
    static func currentRowID(at time: TimeInterval, rows: [TimedRow]) -> UUID? {
        guard !rows.isEmpty else { return nil }
        let t = max(0, time)
        if let containing = rows.first(where: { row in
            let end = max(row.endTime, row.startTime + 0.01)
            return t >= row.startTime && t < end
        }) {
            return containing.id
        }
        return rows.last(where: { $0.startTime <= t })?.id
    }

    static func milliseconds(fromSamples sample: Int64, sampleRate: Double = 16_000) -> Int {
        Int((Double(sample) / sampleRate * 1_000).rounded())
    }

    /// Ensure each row has a usable end bound for playhead matching.
    static func normalizingEndTimes(_ rows: [TimedRow]) -> [TimedRow] {
        guard !rows.isEmpty else { return [] }
        let sorted = rows.sorted { $0.offsetMilliseconds < $1.offsetMilliseconds }
        return sorted.enumerated().map { index, row in
            var end = row.endMilliseconds
            if end <= row.offsetMilliseconds {
                if index + 1 < sorted.count {
                    end = sorted[index + 1].offsetMilliseconds
                } else {
                    end = row.offsetMilliseconds + 1_000
                }
            }
            return TimedRow(
                id: row.id,
                offsetMilliseconds: row.offsetMilliseconds,
                endMilliseconds: end,
                speaker: row.speaker,
                text: row.text
            )
        }
    }
}
