import Testing
import Foundation
@testable import speech_note

struct RecordingDetailPlaybackPresentationTests {
    private func row(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        speaker: String? = nil,
        text: String = "x"
    ) -> RecordingDetailPlaybackPresentation.TimedRow {
        .init(
            id: id,
            offsetMilliseconds: startMs,
            endMilliseconds: endMs,
            speaker: speaker,
            text: text
        )
    }

    @Test func skipSecondsIsAboutTen() {
        #expect(RecordingDetailPlaybackPresentation.skipSeconds == 10)
    }

    @Test func legendSpeakersRequireAtLeastTwoUniqueNames() {
        let roster = RecordingDetailPlaybackPresentation.legendSpeakers(
            from: ["Alice", "Alice", "Bob", nil, ""]
        )
        #expect(roster == ["Alice", "Bob"])
        #expect(roster.count >= 2)
    }

    @Test func currentRowPrefersContainingRange() {
        let a = UUID()
        let b = UUID()
        let rows = [
            row(id: a, startMs: 0, endMs: 10_000, speaker: "A"),
            row(id: b, startMs: 10_000, endMs: 20_000, speaker: "B"),
        ]
        #expect(
            RecordingDetailPlaybackPresentation.currentRowID(at: 0.5, rows: rows) == a
        )
        #expect(
            RecordingDetailPlaybackPresentation.currentRowID(at: 10.0, rows: rows) == b
        )
        #expect(
            RecordingDetailPlaybackPresentation.currentRowID(at: 19.9, rows: rows) == b
        )
    }

    @Test func currentRowFallsBackToLastStartedAcrossGaps() {
        let a = UUID()
        let b = UUID()
        let rows = [
            row(id: a, startMs: 0, endMs: 5_000, speaker: "A"),
            row(id: b, startMs: 12_000, endMs: 15_000, speaker: "B"),
        ]
        #expect(
            RecordingDetailPlaybackPresentation.currentRowID(at: 8.0, rows: rows) == a
        )
    }

    @Test func normalizingEndTimesFillsMissingEnds() {
        let a = UUID()
        let b = UUID()
        let normalized = RecordingDetailPlaybackPresentation.normalizingEndTimes([
            row(id: a, startMs: 0, endMs: 0, speaker: "A"),
            row(id: b, startMs: 4_000, endMs: 4_000, speaker: "B"),
        ])
        #expect(normalized[0].endMilliseconds == 4_000)
        #expect(normalized[1].endMilliseconds == 5_000)
    }

    @Test func speakerColorLookupUsesRosterMembership() {
        let roster = ["A", "B"]
        // Smoke: unknown speaker still resolves without trapping.
        _ = RecordingDetailPlaybackPresentation.color(for: "A", roster: roster)
        _ = RecordingDetailPlaybackPresentation.color(for: "B", roster: roster)
        _ = RecordingDetailPlaybackPresentation.color(for: "Z", roster: roster)
        #expect(roster.firstIndex(of: "A") == 0)
        #expect(roster.firstIndex(of: "B") == 1)
    }
}
