import Foundation
import Accelerate

/// 流式能量 VAD 输出事件
public enum StreamVADEvent: Sendable, Equatable {
    case speechStarted
    case speechContinuing(currentDurationMs: Int64)
    case utteranceCompleted(pcm: [Float], durationMs: Int64)
}

/// 针对近实时语音输入的流式能量 VAD（带预滚 preRoll、滞后 hangover 与底噪自适应）
public struct StreamVAD: Sendable {
    public struct Config: Sendable, Equatable {
        public var sampleRate: Int
        public var frameMs: Int
        public var preRollMs: Int
        public var minSpeechMs: Int
        public var hangoverMs: Int
        public var maxUtteranceMs: Int
        public var minUtteranceMs: Int
        public var startMultiplier: Float
        public var endMultiplier: Float
        public var absStart: Float
        public var absEnd: Float
        public var noiseAttack: Float
        public var noiseRelease: Float

        public init(
            sampleRate: Int = 16_000,
            frameMs: Int = 20,
            preRollMs: Int = 280,
            minSpeechMs: Int = 180,
            hangoverMs: Int = 550,
            maxUtteranceMs: Int = 28_000,
            minUtteranceMs: Int = 280,
            startMultiplier: Float = 3.6,
            endMultiplier: Float = 2.2,
            absStart: Float = 0.012,
            absEnd: Float = 0.006,
            noiseAttack: Float = 0.04,
            noiseRelease: Float = 0.004
        ) {
            self.sampleRate = sampleRate
            self.frameMs = frameMs
            self.preRollMs = preRollMs
            self.minSpeechMs = minSpeechMs
            self.hangoverMs = hangoverMs
            self.maxUtteranceMs = maxUtteranceMs
            self.minUtteranceMs = minUtteranceMs
            self.startMultiplier = startMultiplier
            self.endMultiplier = endMultiplier
            self.absStart = absStart
            self.absEnd = absEnd
            self.noiseAttack = noiseAttack
            self.noiseRelease = noiseRelease
        }

        public var frameSamples: Int { max(1, sampleRate * frameMs / 1000) }
        public var preRollSamples: Int { sampleRate * preRollMs / 1000 }
        public var minSpeechFrames: Int { max(1, minSpeechMs / frameMs) }
        public var hangoverFrames: Int { max(1, hangoverMs / frameMs) }
        public var maxUtteranceSamples: Int { sampleRate * maxUtteranceMs / 1000 }
        public var minUtteranceSamples: Int { sampleRate * minUtteranceMs / 1000 }
    }

    public let config: Config
    private var noiseFloor: Float = 0.005
    private var inSpeech = false
    private var speechFrameCount = 0
    private var silenceFrameCount = 0

    private var preRoll: [Float] = []
    private var currentUtterance: [Float] = []
    private var leftover: [Float] = []

    public init(config: Config = Config()) {
        self.config = config
        self.preRoll.reserveCapacity(config.preRollSamples * 2)
    }

    public var isSpeaking: Bool { inSpeech }

    /// 流式推入音频采样片段（16kHz mono Float32）
    public mutating func process(samples: [Float]) -> [StreamVADEvent] {
        var input: [Float]
        if leftover.isEmpty {
            input = samples
        } else {
            input = leftover + samples
            leftover.removeAll(keepingCapacity: true)
        }

        let frameSamples = config.frameSamples
        let totalFrames = input.count / frameSamples
        var events: [StreamVADEvent] = []

        for frameIdx in 0..<totalFrames {
            let start = frameIdx * frameSamples
            let frame = Array(input[start..<(start + frameSamples)])

            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))

            let startThresh = max(config.absStart, noiseFloor * config.startMultiplier)
            let endThresh = max(config.absEnd, noiseFloor * config.endMultiplier)

            // 动态底噪追踪：仅在确信为静音时才平滑更新底噪
            if !inSpeech && rms <= startThresh {
                if rms < noiseFloor {
                    noiseFloor += (rms - noiseFloor) * config.noiseRelease
                } else {
                    noiseFloor += (rms - noiseFloor) * config.noiseAttack
                }
                noiseFloor = max(0.0005, min(noiseFloor, 0.1))
            }

            if !inSpeech {
                preRoll.append(contentsOf: frame)
                if preRoll.count > config.preRollSamples {
                    preRoll.removeFirst(preRoll.count - config.preRollSamples)
                }

                if rms > startThresh {
                    speechFrameCount += 1
                    if speechFrameCount >= config.minSpeechFrames {
                        inSpeech = true
                        speechFrameCount = 0
                        silenceFrameCount = 0

                        currentUtterance.removeAll(keepingCapacity: true)
                        currentUtterance.append(contentsOf: preRoll)
                        events.append(.speechStarted)
                    }
                } else {
                    speechFrameCount = 0
                }
            } else {
                currentUtterance.append(contentsOf: frame)

                if rms < endThresh {
                    silenceFrameCount += 1
                } else {
                    silenceFrameCount = 0
                }

                let durationMs = Int64(Double(currentUtterance.count) / Double(config.sampleRate) * 1000.0)
                events.append(.speechContinuing(currentDurationMs: durationMs))

                let hitHangover = silenceFrameCount >= config.hangoverFrames
                let hitMax = currentUtterance.count >= config.maxUtteranceSamples

                if hitHangover || hitMax {
                    if currentUtterance.count >= config.minUtteranceSamples {
                        events.append(.utteranceCompleted(pcm: currentUtterance, durationMs: durationMs))
                    }
                    inSpeech = false
                    speechFrameCount = 0
                    silenceFrameCount = 0
                    currentUtterance.removeAll(keepingCapacity: true)
                    preRoll.removeAll(keepingCapacity: true)
                }
            }
        }

        let processedSamples = totalFrames * frameSamples
        if processedSamples < input.count {
            leftover = Array(input[processedSamples..<input.count])
        }

        return events
    }

    /// 强制终止当前句子（如用户松开按键），若有未闭合的有效人声则输出
    public mutating func flush() -> [Float]? {
        let pcm = currentUtterance
        inSpeech = false
        speechFrameCount = 0
        silenceFrameCount = 0
        currentUtterance.removeAll()
        preRoll.removeAll()
        leftover.removeAll()

        return pcm.count >= config.minUtteranceSamples ? pcm : nil
    }
}
