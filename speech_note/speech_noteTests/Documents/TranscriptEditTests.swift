import Foundation
import Testing
@testable import speech_note

struct TranscriptEditTests {
    @Test func userEditsBumpRevisionOnceAndKeepJSONMarkdownInSync() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            title: "初稿",
            isMeeting: true,
            state: .processing
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let initial = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "原始句子")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .processing,
            speakers: ["说话人 1"]
        )
        #expect(initial.state == RecordingState.processing.rawValue)
        #expect(initial.revision == 1)

        let segmentID = try #require(initial.segments.first?.id)
        let sourceRanges = try #require(initial.segments.first?.sourceRanges)
        let edited = initial.applyingUserEdits(
            title: "修订标题",
            tags: ["产品", "周会", "产品"],
            segmentTexts: [segmentID: "纠正后的句子"],
            speakers: ["说话人 1", "说话人 2"]
        )
        #expect(edited.revision == 2)
        #expect(edited.state == RecordingState.processing.rawValue)
        #expect(edited.title == "修订标题")
        #expect(edited.tags == ["产品", "周会"])
        #expect(edited.segments.count == 1)
        #expect(edited.segments[0].text == "纠正后的句子")
        #expect(edited.segments[0].sourceRanges == sourceRanges)
        #expect(edited.segments[0].startSample == 0)
        #expect(edited.segments[0].endSample == 16_000)
        #expect(edited.speakers == ["说话人 1", "说话人 2"])

        let again = edited.applyingUserEdits(title: "再次修订", tags: edited.tags, segmentTexts: [:])
        #expect(again.revision == 3)
        #expect(again.state == RecordingState.processing.rawValue)

        let store = try TranscriptDocumentStore(rootURL: root)
        try await store.write(again)
        let loaded = try #require(await store.document(recordingID: recording.id))
        #expect(loaded.revision == 3)
        #expect(loaded.title == "再次修订")
        let markdown = try #require(await store.markdown(recordingID: recording.id))
        #expect(markdown.contains("revision: 3"))
        #expect(markdown.contains("title: \"再次修订\""))
        #expect(markdown.contains("tags: [\"产品\", \"周会\"]"))
        #expect(markdown.contains("纠正后的句子"))
        #expect(!markdown.contains("原始句子"))
    }

    @Test func confirmedSpeakerNamesRewriteRosterAndTurnsWithoutTouchingSources() {
        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            title: nil,
            isMeeting: true,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 32_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        var document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "你好")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete,
            speakers: ["说话人 1", "说话人 2"]
        )
        document = document.applyingOfflineRecluster(
            speakers: ["说话人 1", "说话人 2"],
            speakerTurns: [
                SpeakerTurn(
                    speaker: "说话人 1",
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: ["说话人 1"]
                ),
                SpeakerTurn(
                    speaker: "说话人 2",
                    startSample: 16_000,
                    endSample: 32_000,
                    onlineTemporaryLabels: ["说话人 2"]
                ),
            ]
        )
        let beforeRevision = document.revision
        let sourceRanges = document.segments[0].sourceRanges

        let bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                state: .confirmed(identityID: UUID(), displayName: "Alice")
            ),
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 2",
                state: .suspected(identityID: UUID(), displayName: "Bob")
            ),
        ]
        let mapping = TranscriptDocumentV1.speakerDisplayMapping(from: bindings)
        #expect(mapping == ["说话人 1": "Alice"])

        let updated = document.applyingSpeakerLabelMapping(mapping)
        #expect(updated.revision == beforeRevision + 1)
        #expect(updated.speakers == ["Alice", "说话人 2"])
        #expect(updated.speakerTurns.map(\.speaker) == ["Alice", "说话人 2"])
        #expect(updated.segments[0].sourceRanges == sourceRanges)
        #expect(updated.segments[0].text == "你好")
    }

    @Test func singleSpeakerSentenceAssignmentOnlySplitsItsOwnTurn() throws {
        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            isMeeting: true,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 48_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        var document = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentDrafts: [
                .init(
                    text: "第一句。",
                    startSample: 0,
                    endSample: 16_000,
                    sourceRanges: [.init(sourceID: chunk.id, startSample: 0, endSample: 16_000)]
                ),
                .init(
                    text: "第二句。",
                    startSample: 16_000,
                    endSample: 32_000,
                    sourceRanges: [.init(sourceID: chunk.id, startSample: 16_000, endSample: 32_000)]
                ),
                .init(
                    text: "第三句。",
                    startSample: 32_000,
                    endSample: 48_000,
                    sourceRanges: [.init(sourceID: chunk.id, startSample: 32_000, endSample: 48_000)]
                ),
            ],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete,
            speakers: ["Alice", "Bob", "说话人不确定", "多人对话"]
        )
        document = document.applyingOfflineRecluster(
            speakers: document.speakers,
            speakerTurns: [
                SpeakerTurn(speaker: "Alice", startSample: 0, endSample: 48_000, onlineTemporaryLabels: ["说话人 1"])
            ]
        )
        let segment = try #require(document.segments.dropFirst().first)
        let assigned = document.applyingSpeakerAssignment(segmentID: segment.id, speaker: "Bob")

        #expect(assigned.revision == document.revision + 1)
        #expect(assigned.speakerTurn(for: segment)?.speaker == "Bob")
        #expect(assigned.speakerTurns.map(\.speaker) == ["Alice", "Bob", "Alice"])
        #expect(assigned.editableSpeakerLabels == ["Alice", "Bob"])
    }

    @Test func unknownSentenceCanBeAssignedButMultipleSpeakerSentenceCannot() throws {
        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            isMeeting: true,
            state: .complete
        )
        let chunk = AudioChunk(
            recordingID: recording.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt!
        )
        let initial = TranscriptDocumentV1(
            recording: recording,
            chunks: [chunk],
            segmentTexts: [(chunkID: chunk.id, text: "一句话")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete,
            speakers: ["Alice", "Bob"]
        )
        let segment = try #require(initial.segments.first)
        let unknown = initial.applyingOfflineRecluster(
            speakers: initial.speakers,
            speakerTurns: [
                SpeakerTurn(
                    speaker: nil,
                    attribution: .unknown,
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: []
                )
            ]
        )
        let assigned = unknown.applyingSpeakerAssignment(segmentID: segment.id, speaker: "Bob")
        #expect(assigned.speakerTurn(for: segment)?.speaker == "Bob")
        #expect(assigned.speakerTurn(for: segment)?.attribution == .single)

        let multiple = initial.applyingOfflineRecluster(
            speakers: initial.speakers,
            speakerTurns: [
                SpeakerTurn(
                    speaker: nil,
                    attribution: .multiple,
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: []
                )
            ]
        )
        #expect(multiple.applyingSpeakerAssignment(segmentID: segment.id, speaker: "Bob") == multiple)
    }

    @Test func bindingStoreRoundTripStaysOutOfPublicTrees() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = UUID()
        let bindings = [
            MeetingSpeakerBinding(
                temporaryLabel: "说话人 1",
                state: .suspected(identityID: UUID(), displayName: "Alice"),
                candidateEmbeddings: [[1, 0]],
                deniedIdentityIDs: [],
                meetingAlias: nil
            )
        ]
        try MeetingSpeakerBindingStore.save(bindings, rootURL: root, recordingID: recordingID)
        let loaded = try MeetingSpeakerBindingStore.load(rootURL: root, recordingID: recordingID)
        #expect(loaded == bindings)
        let path = MeetingSpeakerBindingStore.fileURL(rootURL: root, recordingID: recordingID).path
        #expect(path.contains("/SpeakerBindings/"))
        #expect(!path.contains("/Meetings/"))
        #expect(!path.contains("/Daily/"))
        #expect(!path.contains("/Transcripts/"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptEditTests-\(UUID().uuidString)", isDirectory: true)
    }
}
