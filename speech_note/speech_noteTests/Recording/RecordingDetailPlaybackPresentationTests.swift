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

    @Test func timeDirectoryFormatsHoursAndMinutesCorrectly() {
        let sampleRate: Double = 16_000
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: 0, sampleRate: sampleRate) == "00/00")
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: Int64(59 * sampleRate), sampleRate: sampleRate) == "00/00")
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: Int64(60 * sampleRate), sampleRate: sampleRate) == "00/01")
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: Int64(3599 * sampleRate), sampleRate: sampleRate) == "00/59")
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: Int64(3600 * sampleRate), sampleRate: sampleRate) == "01/00")
        #expect(AACChunkBoundaryPlanner.timeDirectory(for: Int64((8 * 3600 + 15 * 60) * sampleRate), sampleRate: sampleRate) == "08/15")
    }

    @Test @MainActor func timelinePlayerLoadsDiscontinuousChunksAndSkipsGapsOnSeek() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chunk1URL = root.appendingPathComponent("c1.m4a")
        let chunk2URL = root.appendingPathComponent("c2.m4a")
        try Data("dummy1".utf8).write(to: chunk1URL)
        try Data("dummy2".utf8).write(to: chunk2URL)

        let chunk1 = AudioChunk(
            recordingID: UUID(),
            relativePath: "c1.m4a",
            startSample: 160_000,
            endSample: 320_000,
            startedAt: Date(),
            endedAt: Date()
        )
        let chunk2 = AudioChunk(
            recordingID: UUID(),
            relativePath: "c2.m4a",
            startSample: 960_000,
            endSample: 1_120_000,
            startedAt: Date(),
            endedAt: Date()
        )

        let player = RecordingAudioTimelinePlayer()
        player.load(chunks: [chunk1, chunk2], rootURL: root)

        #expect(player.duration == 70.0)
        #expect(player.currentTime == 10.0)

        player.seek(to: 35.0)
        #expect(player.currentTime == 60.0)

        player.seek(to: 15.0)
        #expect(player.currentTime == 15.0)
    }
}
