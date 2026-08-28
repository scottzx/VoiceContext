import Testing
@testable import speech_note

struct ASRSentenceSegmenterTests {
    @Test func explicitTerminatorsCreateAcousticallyTimedSentences() {
        let tokens: [ASRSentenceSegmenter.Token] = [
            .init(text: "第一句", startMilliseconds: 100, endMilliseconds: 900),
            .init(text: "。", startMilliseconds: 900, endMilliseconds: 960),
            .init(text: "第二句", startMilliseconds: 1_200, endMilliseconds: 2_000),
            .init(text: "？", startMilliseconds: 2_000, endMilliseconds: 2_060),
            .init(text: "第三句", startMilliseconds: 2_400, endMilliseconds: 3_200),
            .init(text: "！", startMilliseconds: 3_200, endMilliseconds: 3_260),
        ]

        let sentences = ASRSentenceSegmenter.split(
            tokens: tokens,
            fallbackText: "unused",
            fallbackDurationMilliseconds: 5_000
        )

        #expect(sentences == [
            .init(text: "第一句。", startMilliseconds: 100, endMilliseconds: 960),
            .init(text: "第二句？", startMilliseconds: 1_200, endMilliseconds: 2_060),
            .init(text: "第三句！", startMilliseconds: 2_400, endMilliseconds: 3_260),
        ])
    }

    @Test func commasSemicolonsAndConnectorsDoNotSplit() {
        let sentences = ASRSentenceSegmenter.split(
            tokens: [
                .init(text: "前半句，继续；然后结束。", startMilliseconds: 300, endMilliseconds: 2_300),
                .init(text: "尾句", startMilliseconds: 2_500, endMilliseconds: 3_000),
            ],
            fallbackText: "unused",
            fallbackDurationMilliseconds: 4_000
        )

        #expect(sentences == [
            .init(text: "前半句，继续；然后结束。", startMilliseconds: 300, endMilliseconds: 2_300),
            .init(text: "尾句", startMilliseconds: 2_500, endMilliseconds: 3_000),
        ])
    }

    @Test func punctuationRunsStayWithOneSentenceAndDecimalsDoNotSplit() {
        let sentences = ASRSentenceSegmenter.split(
            tokens: [
                .init(text: "真的吗？！", startMilliseconds: 0, endMilliseconds: 800),
                .init(text: "数值3.14。", startMilliseconds: 1_000, endMilliseconds: 2_000),
            ],
            fallbackText: "unused",
            fallbackDurationMilliseconds: 3_000
        )

        #expect(sentences.map(\.text) == ["真的吗？！", "数值3.14。"])
    }

    @Test func missingAlignmentFallsBackToOneVADBoundedResult() {
        let sentences = ASRSentenceSegmenter.split(
            tokens: [],
            fallbackText: "  保留整段文本。  ",
            fallbackDurationMilliseconds: 2_500
        )

        #expect(sentences == [
            .init(text: "保留整段文本。", startMilliseconds: 0, endMilliseconds: 2_500),
        ])
    }
}
