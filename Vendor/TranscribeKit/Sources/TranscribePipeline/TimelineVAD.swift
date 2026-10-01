import Foundation
import Accelerate

/// 表达从长音频时间轴上依据人声能量切分出的一段有效语音片段
public struct AudioTimelineSegment: Sendable {
    public let startTimeMs: Int64
    public let endTimeMs: Int64
    public let pcm: [Float]

    public init(startTimeMs: Int64, endTimeMs: Int64, pcm: [Float]) {
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.pcm = pcm
    }

    public var durationMs: Int64 {
        max(0, endTimeMs - startTimeMs)
    }
}

/// 时间轴能量 VAD：将长音频/视频的 16kHz mono Float32 PCM 流按人声和停顿切片，精确计算每段的时间起点与终点。
public final class TimelineVAD: @unchecked Sendable {
    public struct Config: Sendable {
        public var sampleRate: Int = 16_000
        public var frameMs: Int = 20
        public var preRollMs: Int = 280
        public var minSpeechMs: Int = 260
        public var hangoverMs: Int = 450
        public var maxSegmentMs: Int = 25_000 // SenseVoice 建议在 30 秒以内
        public var minSegmentMs: Int = 300
        public var startMultiplier: Float = 3.2
        public var endMultiplier: Float = 2.0
        public var absStart: Float = 0.012
        public var absEnd: Float = 0.006
        public var noiseAttack: Float = 0.04
        public var noiseRelease: Float = 0.004

        public init() {}
    }

    public let config: Config
    private let frameSamples: Int
    private let preRollSamples: Int
    private let minSpeechFrames: Int
    private let hangoverFrames: Int
    private let maxSegmentSamples: Int
    private let minSegmentSamples: Int

    public init(config: Config = Config()) {
        self.config = config
        self.frameSamples = max(1, config.sampleRate * config.frameMs / 1000)
        self.preRollSamples = config.sampleRate * config.preRollMs / 1000
        self.minSpeechFrames = max(1, config.minSpeechMs / config.frameMs)
        self.hangoverFrames = max(1, config.hangoverMs / config.frameMs)
        self.maxSegmentSamples = config.sampleRate * config.maxSegmentMs / 1000
        self.minSegmentSamples = config.sampleRate * config.minSegmentMs / 1000
    }

    /// 对完整的 PCM 音频进行离线分段
    public func segment(pcm: [Float]) -> [AudioTimelineSegment] {
        guard !pcm.isEmpty else { return [] }

        var segments: [AudioTimelineSegment] = []
        var noiseFloor: Float = 0.005
        var inSpeech = false
        var speechFrameCount = 0
        var silenceFrameCount = 0

        var speechStartSample = 0
        var currentUtterance: [Float] = []
        var preRollRing = [Float]()
        preRollRing.reserveCapacity(preRollSamples * 2)

        let totalFrames = pcm.count / frameSamples

        for frameIdx in 0..<totalFrames {
            let start = frameIdx * frameSamples
            let end = min(start + frameSamples, pcm.count)
            let frame = Array(pcm[start..<end])

            // 计算该帧 RMS 能量
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))

            let startThresh = max(config.absStart, noiseFloor * config.startMultiplier)
            let endThresh = max(config.absEnd, noiseFloor * config.endMultiplier)

            // 动态底噪追踪：仅在确信为静音时才平滑更新底噪，避免大音量语音抬高底噪导致漏检
            if !inSpeech && rms <= startThresh {
                if rms < noiseFloor {
                    noiseFloor += (rms - noiseFloor) * config.noiseRelease
                } else {
                    noiseFloor += (rms - noiseFloor) * config.noiseAttack
                }
                noiseFloor = max(0.0005, min(noiseFloor, 0.1))
            }

            if !inSpeech {
                preRollRing.append(contentsOf: frame)
                if preRollRing.count > preRollSamples {
                    preRollRing.removeFirst(preRollRing.count - preRollSamples)
                }

                if rms > startThresh {
                    speechFrameCount += 1
                    if speechFrameCount >= minSpeechFrames {
                        inSpeech = true
                        speechFrameCount = 0
                        silenceFrameCount = 0

                        let actualPreRollCount = preRollRing.count
                        let preRollStart = max(0, start - actualPreRollCount)
                        speechStartSample = preRollStart

                        currentUtterance.removeAll(keepingCapacity: true)
                        currentUtterance.append(contentsOf: preRollRing)
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

                let currentDurationSamples = currentUtterance.count
                let hitHangover = silenceFrameCount >= hangoverFrames
                let hitMaxDuration = currentDurationSamples >= maxSegmentSamples

                if hitHangover || hitMaxDuration {
                    let endSample = speechStartSample + currentDurationSamples
                    if currentUtterance.count >= minSegmentSamples {
                        let startMs = Int64(Double(speechStartSample) / Double(config.sampleRate) * 1000.0)
                        let endMs = Int64(Double(endSample) / Double(config.sampleRate) * 1000.0)
                        segments.append(AudioTimelineSegment(
                            startTimeMs: startMs,
                            endTimeMs: endMs,
                            pcm: currentUtterance
                        ))
                    }

                    inSpeech = false
                    silenceFrameCount = 0
                    speechFrameCount = 0
                    currentUtterance.removeAll(keepingCapacity: true)
                    preRollRing.removeAll(keepingCapacity: true)
                }
            }
        }

        // 处理尾部未关闭的语音段
        if inSpeech && currentUtterance.count >= minSegmentSamples {
            let endSample = speechStartSample + currentUtterance.count
            let startMs = Int64(Double(speechStartSample) / Double(config.sampleRate) * 1000.0)
            let endMs = Int64(Double(endSample) / Double(config.sampleRate) * 1000.0)
            segments.append(AudioTimelineSegment(
                startTimeMs: startMs,
                endTimeMs: endMs,
                pcm: currentUtterance
            ))
        }

        return segments
    }
}
