import Foundation
import Testing
@testable import speech_note

struct ReadableClauseSegmenterTests {
    @Test func punctuationCreatesReadableClausesWithoutChangingText() throws {
        let sourceID = UUID()
        let parent = draft(
            text: "甲方提出需求。然后乙方解释方案！最后确认下一步。",
            start: 1_000,
            end: 49_000,
            sourceID: sourceID
        )

        let clauses = ReadableClauseSegmenter.split(parent)

        #expect(clauses.map(\.text) == ["甲方提出需求。", "然后乙方解释方案！", "最后确认下一步。"])
        #expect(clauses.map(\.text).joined() == parent.text)
        #expect(zip(clauses, clauses.dropFirst()).allSatisfy { $0.endSample == $1.startSample })
        #expect(clauses.first?.startSample == parent.startSample)
        #expect(clauses.last?.endSample == parent.endSample)
    }

    @Test func longTextPrefersWhitespaceAndConnectorBeforeHardLimit() throws {
        let parent = draft(
            text: "alpha beta gamma但是我们还需要继续确认",
            start: 0,
            end: 32_000,
            sourceID: UUID()
        )

        let clauses = ReadableClauseSegmenter.split(parent, maximumCharacters: 10)

        #expect(clauses.map(\.text).joined() == parent.text)
        #expect(clauses.allSatisfy { $0.text.count <= 10 })
        #expect(clauses.first?.text == "alpha ")
        #expect(clauses.contains { $0.text.hasSuffix("但是") == false && $0.text.hasPrefix("但是") })
    }

    @Test func childrenNeverCrossAParentSourceBoundary() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let parent = TranscriptDocumentV1.SegmentDraft(
            text: "甲乙丙丁戊己庚辛壬癸",
            startSample: 100,
            endSample: 1_600,
            sourceRanges: [
                .init(sourceID: firstID, startSample: 100, endSample: 500),
                .init(sourceID: secondID, startSample: 1_000, endSample: 1_600),
            ]
        )

        let clauses = ReadableClauseSegmenter.split(parent, maximumCharacters: 3)

        #expect(clauses.map(\.text).joined() == parent.text)
        #expect(clauses.allSatisfy { $0.sourceRanges.count == 1 })
        #expect(clauses.allSatisfy { clause in
            let source = clause.sourceRanges[0]
            return source.sourceID == firstID
                ? 100 <= clause.startSample && clause.endSample <= 500
                : source.sourceID == secondID
                    && 1_000 <= clause.startSample && clause.endSample <= 1_600
        })
        #expect(zip(clauses, clauses.dropFirst()).allSatisfy { $0.endSample <= $1.startSample })
    }

    @Test func connectorSplitsReadableTextEvenBelowTheHardLimit() throws {
        let parent = draft(
            text: "我们已经确认前面的需求然后接下来讨论交付时间",
            start: 0,
            end: 48_000,
            sourceID: UUID()
        )

        let clauses = ReadableClauseSegmenter.split(parent)

        #expect(clauses.map(\.text) == ["我们已经确认前面的需求", "然后接下来讨论交付时间"])
        #expect(clauses.map(\.text).joined() == parent.text)
    }

    @Test func thirtySecondUnpunctuatedTextIsLimitedToFifteenSecondClauses() throws {
        let parent = draft(
            text: String(repeating: "甲", count: 60),
            start: 0,
            end: 30 * 16_000,
            sourceID: UUID()
        )

        let clauses = ReadableClauseSegmenter.split(parent)

        #expect(clauses.count == 2)
        #expect(clauses.map(\.text).joined() == parent.text)
        #expect(clauses.allSatisfy { $0.text.count <= 80 })
        #expect(clauses.allSatisfy {
            $0.endSample - $0.startSample <= ReadableClauseSegmenter.maximumDisplayDurationSamples
        })
        #expect(zip(clauses, clauses.dropFirst()).allSatisfy { $0.endSample == $1.startSample })
        #expect(clauses.first?.startSample == parent.startSample)
        #expect(clauses.last?.endSample == parent.endSample)
    }

    @Test func splittingAnAlreadySplitClauseIsIdempotent() throws {
        let parent = draft(
            text: "这是第一句。这是第二句，它会继续。",
            start: 400,
            end: 40_400,
            sourceID: UUID()
        )
        let once = ReadableClauseSegmenter.split(parent, maximumCharacters: 8)
        let twice = once.flatMap {
            ReadableClauseSegmenter.split($0, maximumCharacters: 8)
        }

        #expect(twice == once)
        #expect(once.map(\.text).joined() == parent.text)
    }

    private func draft(
        text: String,
        start: Int64,
        end: Int64,
        sourceID: UUID
    ) -> TranscriptDocumentV1.SegmentDraft {
        TranscriptDocumentV1.SegmentDraft(
            text: text,
            startSample: start,
            endSample: end,
            sourceRanges: [
                .init(sourceID: sourceID, startSample: start, endSample: end),
            ]
        )
    }
}
