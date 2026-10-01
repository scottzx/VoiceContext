import Foundation
import TranscribeCore

public enum MediaSubtitlePipelineError: Error, LocalizedError {
    case emptyAudio
    case noSegmentsFound

    public var errorDescription: String? {
        switch self {
        case .emptyAudio: return "提取的音轨为空"
        case .noSegmentsFound: return "未在音频中检测到人声音段"
        }
    }
}

/// 媒体字幕生成进度通知
public struct MediaPipelineProgress: Sendable {
    public enum Stage: Sendable {
        case extractingAudio
        case detectingSpeech
        case transcribing(current: Int, total: Int)
        case completed
    }

    public let stage: Stage
    public let fractionCompleted: Double
    public let message: String
}

/// 统一的高级长媒体音视频字幕处理管线
public final class MediaSubtitlePipeline: Sendable {
    private let extractor: MediaAudioExtractor
    private let vad: TimelineVAD

    public init(extractor: MediaAudioExtractor = MediaAudioExtractor(), vad: TimelineVAD = TimelineVAD()) {
        self.extractor = extractor
        self.vad = vad
    }

    /// 一键从媒体文件提取并生成字幕条目
    public func process(
        mediaURL: URL,
        engine: TranscribeEngine,
        options: TranscribeOptions = TranscribeOptions(),
        onProgress: (@Sendable (MediaPipelineProgress) -> Void)? = nil
    ) async throws -> [SubtitleItem] {
        // 1. 抽取 16kHz mono Float32 PCM
        onProgress?(MediaPipelineProgress(stage: .extractingAudio, fractionCompleted: 0.1, message: "正在抽取视频音轨..."))
        let pcm = try await extractor.extractAudio(from: mediaURL) { extractProg in
            onProgress?(MediaPipelineProgress(
                stage: .extractingAudio,
                fractionCompleted: 0.1 + extractProg * 0.2,
                message: "抽取音轨中 (\(Int(extractProg * 100))%)..."
            ))
        }

        guard !pcm.isEmpty else {
            throw MediaSubtitlePipelineError.emptyAudio
        }

        // 2. 时间轴能量切片
        onProgress?(MediaPipelineProgress(stage: .detectingSpeech, fractionCompleted: 0.35, message: "正在分析人声时间轴..."))
        let segments = vad.segment(pcm: pcm)

        guard !segments.isEmpty else {
            throw MediaSubtitlePipelineError.noSegmentsFound
        }

        // 3. 逐段批处理 ASR 推理
        var items: [SubtitleItem] = []
        items.reserveCapacity(segments.count)

        let total = segments.count
        for (index, seg) in segments.enumerated() {
            try Task.checkCancellation()

            let currentProg = 0.35 + (Double(index) / Double(total)) * 0.60
            onProgress?(MediaPipelineProgress(
                stage: .transcribing(current: index + 1, total: total),
                fractionCompleted: currentProg,
                message: "正在转写字幕 (\(index + 1)/\(total))..."
            ))

            let result = try engine.transcribe(pcm: seg.pcm, options: options)
            let text = TextCleanup.subtitleLine(result.text)

            if !text.isEmpty {
                let sentenceItems = SubtitleItem.splitIntoSentenceItems(
                    text: text,
                    startTimeMs: seg.startTimeMs,
                    endTimeMs: seg.endTimeMs
                )
                items.append(contentsOf: sentenceItems)
            }
        }

        onProgress?(MediaPipelineProgress(stage: .completed, fractionCompleted: 1.0, message: "字幕生成完成"))
        return items
    }
}
