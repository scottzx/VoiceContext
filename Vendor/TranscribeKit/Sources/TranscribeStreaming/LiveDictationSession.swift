import Foundation
import TranscribeCore

public enum DictationState: Sendable {
    case idle
    case listening
    case processing
}

public struct DictationUpdate: Sendable {
    public let state: DictationState
    public let committedText: String
    public let latestUtterance: String
    public let isSpeaking: Bool

    public init(state: DictationState, committedText: String, latestUtterance: String, isSpeaking: Bool) {
        self.state = state
        self.committedText = committedText
        self.latestUtterance = latestUtterance
        self.isSpeaking = isSpeaking
    }
}

/// 现代异步实时语音听写会话（面向输入法与实时语音录制）
public actor LiveDictationSession {
    private let capture: AudioCapture
    private var vad: StreamVAD
    private let engine: TranscribeEngine
    private let options: TranscribeOptions

    private var state: DictationState = .idle
    private var committedSentences: [String] = []
    private var currentSpeaking = false

    private var continuation: AsyncStream<DictationUpdate>.Continuation?

    public init(
        engine: TranscribeEngine,
        vadConfig: StreamVAD.Config = StreamVAD.Config(),
        options: TranscribeOptions = TranscribeOptions()
    ) {
        self.engine = engine
        self.vad = StreamVAD(config: vadConfig)
        self.capture = AudioCapture()
        self.options = options
    }

    /// 订阅实时状态与文字更新流
    public func updates() -> AsyncStream<DictationUpdate> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// 启动实时听写
    public func start() throws {
        guard state == .idle else { return }
        committedSentences.removeAll()
        state = .listening

        broadcast(latestUtterance: "")

        try capture.start { [weak self] samples in
            Task { [weak self] in
                await self?.handleSamples(samples)
            }
        }
    }

    /// 处理流式样本
    private func handleSamples(_ samples: [Float]) {
        guard state == .listening else { return }

        let events = vad.process(samples: samples)
        for event in events {
            switch event {
            case .speechStarted:
                currentSpeaking = true
                broadcast(latestUtterance: "")
            case .speechContinuing:
                currentSpeaking = true
            case .utteranceCompleted(let pcm, _):
                currentSpeaking = false
                // 对完整句子进行转写
                if let res = try? engine.transcribe(pcm: pcm, options: options) {
                    let cleaned = TextCleanup.clean(res.text)
                    if !cleaned.isEmpty {
                        committedSentences.append(cleaned)
                    }
                    broadcast(latestUtterance: cleaned)
                }
            }
        }
    }

    /// 停止听写，并返回最终合并的全部文本
    public func stop() async throws -> String {
        capture.stop()
        state = .processing

        // 刷新残余音频
        if let flushedPcm = vad.flush(), !flushedPcm.isEmpty {
            if let res = try? engine.transcribe(pcm: flushedPcm, options: options) {
                let cleaned = TextCleanup.clean(res.text)
                if !cleaned.isEmpty {
                    committedSentences.append(cleaned)
                }
            }
        }

        let fullText = committedSentences.joined(separator: "")
        state = .idle
        currentSpeaking = false
        broadcast(latestUtterance: "")
        continuation?.finish()
        continuation = nil

        return fullText
    }

    private func broadcast(latestUtterance: String) {
        let full = committedSentences.joined(separator: "")
        continuation?.yield(DictationUpdate(
            state: state,
            committedText: full,
            latestUtterance: latestUtterance,
            isSpeaking: currentSpeaking
        ))
    }
}
