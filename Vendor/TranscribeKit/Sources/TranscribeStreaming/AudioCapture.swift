import Foundation
import AVFoundation
import TranscribeCore

public enum AudioCaptureError: Error, LocalizedError {
    case noInputNode
    case converterFailed
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputNode: return "未找到可用的麦克风输入"
        case .converterFailed: return "无法创建 16kHz 音频转换器"
        case .engineFailed(let msg): return "AVAudioEngine 异常: \(msg)"
        }
    }
}

/// 跨平台麦克风实时采集与重采样器
public final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var isCapturing = false

    public var isRunning: Bool { engine.isRunning }

    public init() {
        self.targetFormat = AudioResampler.targetFormat
    }

    /// 启动麦克风录制，并通过闭包连续回调 16kHz mono Float32 PCM 块
    public func start(bufferSize: AVAudioFrameCount = 1024, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        if isCapturing {
            stop()
        }

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputNode
        }

        guard let conv = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw AudioCaptureError.converterFailed
        }
        self.converter = conv

        let targetFmt = self.targetFormat
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }

            let ratio = AudioResampler.standardSampleRate / inFormat.sampleRate
            let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: estimatedFrames) else {
                return
            }

            var isProvided = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if !isProvided {
                    isProvided = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if status != .error, error == nil, let channelData = outBuffer.floatChannelData?[0] {
                let count = Int(outBuffer.frameLength)
                if count > 0 {
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
                    onSamples(samples)
                }
            }
        }

        do {
            try engine.start()
            isCapturing = true
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
    }

    /// 停止录制
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        isCapturing = false
    }
}
