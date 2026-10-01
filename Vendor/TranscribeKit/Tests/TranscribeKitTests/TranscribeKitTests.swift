import XCTest
@testable import TranscribeKit

final class TranscribeKitTests: XCTestCase {

    func testModelRegistry() {
        XCTAssertEqual(ModelRegistry.senseVoice.id, "sensevoice-small-q8")
        XCTAssertEqual(ModelRegistry.whisperTiny.id, "whisper-tiny-q8")
        XCTAssertEqual(ModelRegistry.standardModels.count, 3)

        // 验证候选解析逻辑（即便文件尚未下载也不崩溃）
        _ = ModelRegistry.resolveModelURL(for: ModelRegistry.senseVoice)
    }

    func testTextCleanup() {
        let raw = "<|zh|><|NEUTRAL|><|HAPPY|> 你 好 ， 世 界 ！ <|withitn|>"
        let cleaned = TextCleanup.clean(raw)
        XCTAssertEqual(cleaned, "你好，世界！")

        let line = "，这是行首有标点的句子。"
        let lineCleaned = TextCleanup.subtitleLine(line)
        XCTAssertEqual(lineCleaned, "这是行首有标点的句子。")
    }

    func testAudioResamplerLinear() {
        // 创建 1 秒 8kHz 正弦/常数信号
        let sampleCount = 8000
        let original = [Float](repeating: 0.5, count: sampleCount)
        let resampled = AudioResampler.resample(samples: original, fromSampleRate: 8000.0)

        // 重采样至 16kHz 后长度应约为 16000
        XCTAssertEqual(resampled.count, 16000)
        if let first = resampled.first {
            XCTAssertEqual(first, 0.5, accuracy: 0.001)
        }
    }

    func testSubtitleItemAndExporter() {
        let item1 = SubtitleItem(
            startTimeMs: 1500, // 00:00:01,500
            endTimeMs: 3800,   // 00:00:03,800
            originalText: "Hello world",
            translatedText: "你好世界"
        )

        let srt = item1.toSRTChunk(index: 1, includeTranslation: true)
        XCTAssertTrue(srt.contains("00:00:01,500 --> 00:00:03,800"))
        XCTAssertTrue(srt.contains("Hello world"))
        XCTAssertTrue(srt.contains("你好世界"))

        let allSRT = SubtitleExporter.toSRT([item1])
        XCTAssertTrue(allSRT.hasPrefix("1\n00:00:01,500 --> 00:00:03,800"))

        let allVTT = SubtitleExporter.toVTT([item1])
        XCTAssertTrue(allVTT.hasPrefix("WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.800"))
    }

    func testSplitIntoSentenceItems() {
        let text = "有问题啊，没事，问题不大。我们试一下，看一下今天广告吧。"
        let items = SubtitleItem.splitIntoSentenceItems(text: text, startTimeMs: 1000, endTimeMs: 7000)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].originalText, "有问题啊，没事，问题不大。")
        XCTAssertEqual(items[1].originalText, "我们试一下，看一下今天广告吧。")
        XCTAssertEqual(items[0].startTimeMs, 1000)
        XCTAssertEqual(items[1].endTimeMs, 7000)
        XCTAssertTrue(items[0].endTimeMs <= items[1].startTimeMs)

        // 测试长句逗号分割
        let longClause = "小傻二郎背着书包上学堂，我们看一下这个视频怎么样。"
        let longItems = SubtitleItem.splitIntoSentenceItems(text: longClause, startTimeMs: 0, endTimeMs: 10000, maxCharsPerCue: 15)
        XCTAssertEqual(longItems.count, 2)
        XCTAssertEqual(longItems[0].originalText, "小傻二郎背着书包上学堂，")
        XCTAssertEqual(longItems[1].originalText, "我们看一下这个视频怎么样。")
    }

    func testTimelineVAD() {
        let vad = TimelineVAD()
        // 空音频返回空
        XCTAssertTrue(vad.segment(pcm: []).isEmpty)

        // 构造 1 秒静音音频，应该切不出任何有效段
        let silence = [Float](repeating: 0.0001, count: 16000)
        let segments = vad.segment(pcm: silence)
        XCTAssertTrue(segments.isEmpty)
    }

    func testStreamVAD() {
        var vad = StreamVAD()
        XCTAssertFalse(vad.isSpeaking)

        // 喂入静音
        let silence = [Float](repeating: 0.0001, count: 3200)
        let events = vad.process(samples: silence)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(vad.isSpeaking)
    }
}
