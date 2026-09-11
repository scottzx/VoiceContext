import Foundation
import Testing
@testable import speech_note

struct TranscriptSearchTests {
    @Test func engineHitsTitleAndBodyAndMissesUnknownQuery() {
        let segmentID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let document = TranscriptSearchEngine.Document(
            recordingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "产品周会纪要",
            body: "今天讨论了离线转写搜索与导出字幕。",
            speakers: "Alice Bob",
            tags: "产品 周会",
            segments: [
                .init(id: segmentID, text: "今天讨论了离线转写搜索与导出字幕。")
            ],
            revision: 2
        )

        let hit = TranscriptSearchEngine.hit(from: document, query: "离线转写")
        #expect(hit != nil)
        #expect(hit?.recordingID == document.recordingID)
        #expect(hit?.excerpt.contains("离线转写") == true)
        #expect(hit?.firstMatchingSegmentID == segmentID)

        let titleHit = TranscriptSearchEngine.hit(from: document, query: "周会纪要")
        #expect(titleHit != nil)
        #expect(titleHit?.excerpt == "产品周会纪要")

        let speakerHit = TranscriptSearchEngine.hit(from: document, query: "Alice")
        #expect(speakerHit != nil)

        let tagHit = TranscriptSearchEngine.hit(from: document, query: "产品")
        #expect(tagHit != nil)

        let miss = TranscriptSearchEngine.hit(from: document, query: "量子纠缠")
        #expect(miss == nil)

        #expect(TranscriptSearchEngine.hit(from: document, query: "   ") == nil)
    }

    @Test func durableIndexSurvivesReopenAndSupportsHitMiss() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingA = Recording(
            id: UUID(uuidString: "10000000-0000-0000-0000-0000000000a1")!,
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            title: "会议室讨论",
            isMeeting: true,
            state: .complete
        )
        let recordingB = Recording(
            id: UUID(uuidString: "10000000-0000-0000-0000-0000000000b2")!,
            startedAt: Date(timeIntervalSince1970: 1_786_502_800),
            endedAt: Date(timeIntervalSince1970: 1_786_502_860),
            title: "散步随记",
            state: .complete
        )
        let chunkA = AudioChunk(
            recordingID: recordingA.id,
            relativePath: "Recordings/a.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recordingA.startedAt,
            endedAt: recordingA.endedAt!
        )
        let chunkB = AudioChunk(
            recordingID: recordingB.id,
            relativePath: "Recordings/b.m4a",
            startSample: 0,
            endSample: 16_000,
            startedAt: recordingB.startedAt,
            endedAt: recordingB.endedAt!
        )
        let docA = TranscriptDocumentV1(
            recording: recordingA,
            chunks: [chunkA],
            segmentTexts: [(chunkID: chunkA.id, text: "请把声纹归档做到本地优先")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete,
            speakers: ["说话人 1"]
        )
        let docB = TranscriptDocumentV1(
            recording: recordingB,
            chunks: [chunkB],
            segmentTexts: [(chunkID: chunkB.id, text: "今天天气不错适合散步")],
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete
        )

        do {
            let store = try TranscriptDocumentStore(rootURL: root)
            try await store.write(docA)
            try await store.write(docB)
            let hits = try await store.search(query: "声纹归档")
            #expect(hits.count == 1)
            #expect(hits[0].recordingID == recordingA.id)
            #expect(hits[0].excerpt.contains("声纹归档"))
            #expect(hits[0].firstMatchingSegmentID == docA.segments.first?.id)

            let misses = try await store.search(query: "火星移民")
            #expect(misses.isEmpty)
        }

        // Kill / reopen process: a new store must still find the same hit.
        let reopened = try TranscriptDocumentStore(rootURL: root)
        let again = try await reopened.search(query: "声纹归档")
        #expect(again.count == 1)
        #expect(again[0].recordingID == recordingA.id)

        try await reopened.reconcileSearchIndex(recordings: [recordingA, recordingB])
        let afterReconcile = try await reopened.search(query: "散步")
        #expect(afterReconcile.contains(where: { $0.recordingID == recordingB.id }))
    }

    @Test func emptyQueryReturnsNoHitsForCallerToShowNormalList() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try TranscriptSearchIndex(rootURL: root)
        try index.upsertTitleOnly(recordingID: UUID(), title: "任意标题")
        #expect(try index.search(query: "").isEmpty)
        #expect(try index.search(query: "\n\t ").isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearchTests-\(UUID().uuidString)", isDirectory: true)
    }
}
