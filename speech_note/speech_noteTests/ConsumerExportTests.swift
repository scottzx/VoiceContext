import Foundation
import Testing
@testable import speech_note

struct ConsumerExportTests {
    @Test func plainTextIncludesSpeakerLabelsAndSimpleTimecodesWithoutYAML() {
        let document = makeDocument(
            title: "周会",
            segments: [
                (start: 0, end: 16_000, text: "大家好"),
                (start: 16_000, end: 48_000, text: "今天先看验收标准"),
            ],
            turns: [
                SpeakerTurn(
                    speaker: "说话人 1",
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: ["说话人 1"]
                ),
                SpeakerTurn(
                    speaker: "说话人 2",
                    startSample: 16_000,
                    endSample: 48_000,
                    onlineTemporaryLabels: ["说话人 2"]
                ),
            ]
        )

        let text = TranscriptPlainTextRenderer.render(document)
        #expect(text.hasPrefix("周会\n"))
        #expect(text.contains("[+00:00:00] 说话人 1\n大家好"))
        #expect(text.contains("[+00:00:01] 说话人 2\n今天先看验收标准"))
        #expect(!text.contains("---"))
        #expect(!text.contains("schema:"))
        #expect(!text.contains("recording_id:"))
    }

    @Test func srtTimestampsAlignToSegmentSampleWindow() {
        let document = makeDocument(
            title: "字幕",
            segments: [
                (start: 0, end: 16_000, text: "第一句"),
                (start: 16_000, end: 40_000, text: "第二句"),
            ],
            turns: [
                SpeakerTurn(
                    speaker: "说话人 1",
                    startSample: 0,
                    endSample: 16_000,
                    onlineTemporaryLabels: ["说话人 1"]
                ),
            ]
        )

        let srt = TranscriptSRTRenderer.render(document)
        #expect(
            srt.contains(
                """
                1
                00:00:00,000 --> 00:00:01,000
                说话人 1: 第一句
                """
            )
        )
        #expect(
            srt.contains(
                """
                2
                00:00:01,000 --> 00:00:02,500
                第二句
                """
            )
        )
        #expect(TranscriptSRTRenderer.formatTimestamp(2.5) == "00:00:02,500")
        #expect(TranscriptSRTRenderer.formatTimestamp(3661.234) == "01:01:01,234")
    }

    @Test func multipleSpeakerSegmentExportsWithoutFalseSingleAttribution() {
        let document = makeDocument(
            title: "讨论",
            segments: [(start: 0, end: 32_000, text: "两个人连续发言")],
            turns: [
                SpeakerTurn(
                    speaker: nil,
                    attribution: .multiple,
                    startSample: 0,
                    endSample: 32_000,
                    onlineTemporaryLabels: []
                ),
            ]
        )

        #expect(TranscriptPlainTextRenderer.render(document).contains("多人对话"))
        #expect(TranscriptSRTRenderer.render(document).contains("多人对话: 两个人连续发言"))
        #expect(!document.speakers.contains("多人对话"))
    }

    @Test func srtBumpsDegenerateZeroLengthCue() {
        let document = makeDocument(
            title: nil,
            segments: [
                (start: 8_000, end: 8_000, text: "零时长"),
                (start: 32_000, end: 48_000, text: "有效"),
            ],
            turns: []
        )

        let srt = TranscriptSRTRenderer.render(document)
        #expect(
            srt.contains(
                """
                1
                00:00:00,500 --> 00:00:00,501
                零时长
                """
            )
        )
        #expect(
            srt.contains(
                """
                2
                00:00:02,000 --> 00:00:03,000
                有效
                """
            )
        )
        #expect(!srt.contains("\n3\n"))
    }

    @Test func emptySegmentsYieldEmptyPlainTextAndEmptySRT() {
        let document = makeDocument(title: "空", segments: [], turns: [])
        #expect(TranscriptPlainTextRenderer.render(document) == "")
        #expect(TranscriptSRTRenderer.render(document) == "")
    }

    @Test func fileNameSanitizesPathCharacters() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let name = ConsumerExportFileNaming.baseName(
            title: "  周会/纪要:草稿  ",
            recordingID: id
        )
        #expect(name == "周会-纪要-草稿")
        let fallback = ConsumerExportFileNaming.baseName(title: "   ", recordingID: id)
        #expect(fallback == "recording-aaaaaaaa")
    }

    private func makeDocument(
        title: String?,
        segments: [(start: Int64, end: Int64, text: String)],
        turns: [SpeakerTurn]
    ) -> TranscriptDocumentV1 {
        let recording = Recording(
            startedAt: Date(timeIntervalSince1970: 1_786_501_800),
            endedAt: Date(timeIntervalSince1970: 1_786_501_860),
            title: title,
            isMeeting: true,
            state: .complete
        )
        let drafts = segments.map { item in
            TranscriptDocumentV1.SegmentDraft(
                text: item.text,
                startSample: item.start,
                endSample: item.end,
                sourceRanges: [
                    TranscriptDocumentV1.SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: UUID(),
                        startSample: item.start,
                        endSample: item.end
                    ),
                ]
            )
        }
        var document = TranscriptDocumentV1(
            recording: recording,
            audioAvailableOnThisDevice: true,
            segmentDrafts: drafts,
            timezone: "Asia/Shanghai",
            language: "zh",
            state: .complete,
            speakers: turns.compactMap(\.speaker)
        )
        if !turns.isEmpty {
            document = document.applyingOfflineRecluster(
                speakers: turns.compactMap(\.speaker),
                speakerTurns: turns
            )
        }
        return document
    }
}
