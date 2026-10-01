import Foundation
import AVFoundation
import Accelerate

public enum AudioResamplerError: Error, LocalizedError {
    case unsupportedFormat(String)
    case conversionFailed(String)
    case invalidWavData(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let msg): return "不支持的音频格式: \(msg)"
        case .conversionFailed(let msg): return "音频重采样转换失败: \(msg)"
        case .invalidWavData(let msg): return "无效的 WAV 数据: \(msg)"
        }
    }
}

/// 统一的高性能音频重采样与归一化工具（统一输出 16kHz, 单声道, 32-bit Float PCM）
public enum AudioResampler {
    public static let standardSampleRate: Double = 16_000.0

    /// 标准 16kHz 单声道 Float32 音频格式
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: standardSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// 将 AVAudioPCMBuffer 重采样转换为 16kHz mono Float32 数组
    public static func resample(buffer: AVAudioPCMBuffer) throws -> [Float] {
        let inFormat = buffer.format
        if inFormat.sampleRate == standardSampleRate && inFormat.channelCount == 1 && inFormat.commonFormat == .pcmFormatFloat32 {
            guard let channelData = buffer.floatChannelData?[0] else { return [] }
            let frameLength = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        }

        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw AudioResamplerError.unsupportedFormat("无法创建从 \(inFormat) 到 \(targetFormat) 的转换器")
        }

        let ratio = standardSampleRate / inFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw AudioResamplerError.conversionFailed("创建目标 AVAudioPCMBuffer 失败")
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
        if let error = error {
            throw AudioResamplerError.conversionFailed(error.localizedDescription)
        }

        guard status != .error, let channelData = outBuffer.floatChannelData?[0] else {
            throw AudioResamplerError.conversionFailed("转换器状态异常: \(status.rawValue)")
        }

        let frameLength = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: frameLength))
    }

    /// 将任意原生采样率的单声道 [Float] 线性重采样至 16kHz
    public static func resample(samples: [Float], fromSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if abs(fromSampleRate - standardSampleRate) < 1.0 {
            return samples
        }

        let ratio = standardSampleRate / fromSampleRate
        let targetLength = Int(Double(samples.count) * ratio)
        guard targetLength > 0 else { return [] }

        var output = [Float](repeating: 0, count: targetLength)
        let step = (Double(samples.count) - 1.0) / Double(max(1, targetLength - 1))

        for i in 0..<targetLength {
            let srcIndex = Double(i) * step
            let i0 = Int(srcIndex)
            let i1 = min(i0 + 1, samples.count - 1)
            let frac = Float(srcIndex - Double(i0))
            output[i] = samples[i0] * (1.0 - frac) + samples[i1] * frac
        }

        return output
    }

    /// 从原始 WAV 容器 Data 解析并提取 16kHz mono Float32 采样
    public static func parseWavData(_ data: Data) throws -> [Float] {
        guard data.count >= 44 else {
            throw AudioResamplerError.invalidWavData("数据长度不足 44 字节 WAV 头")
        }

        // RIFF 校验
        let riff = data.prefix(4)
        guard let riffStr = String(data: riff, encoding: .ascii), riffStr == "RIFF" else {
            throw AudioResamplerError.invalidWavData("不是标准的 RIFF/WAV 格式")
        }

        // 查找 fmt chunk 与 data chunk
        var offset = 12
        var channels: UInt16 = 1
        var sampleRate: UInt32 = 16000
        var bitsPerSample: UInt16 = 16
        var audioFormat: UInt16 = 1 // 1: PCM, 3: IEEE Float
        var pcmData: Data?

        while offset + 8 <= data.count {
            let chunkId = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset + 4, as: UInt32.self)
            }
            let nextOffset = offset + 8 + Int(chunkSize)

            if chunkId == "fmt " && offset + 8 + 16 <= data.count {
                audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt16.self) }
                channels = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt16.self) }
                sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self) }
                bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 22, as: UInt16.self) }
            } else if chunkId == "data" {
                let dataStart = offset + 8
                let dataEnd = min(dataStart + Int(chunkSize), data.count)
                pcmData = data.subdata(in: dataStart..<dataEnd)
                break
            }

            offset = nextOffset
        }

        guard let rawPcm = pcmData else {
            throw AudioResamplerError.invalidWavData("未找到 data 数据块")
        }

        // 转为 [Float]
        var floatSamples: [Float] = []
        if audioFormat == 1 && bitsPerSample == 16 {
            let count = rawPcm.count / 2
            floatSamples = [Float](repeating: 0, count: count)
            rawPcm.withUnsafeBytes { ptr in
                let int16Ptr = ptr.bindMemory(to: Int16.self)
                for i in 0..<count {
                    floatSamples[i] = Float(int16Ptr[i]) / 32768.0
                }
            }
        } else if audioFormat == 3 && bitsPerSample == 32 {
            let count = rawPcm.count / 4
            floatSamples = [Float](repeating: 0, count: count)
            rawPcm.withUnsafeBytes { ptr in
                let floatPtr = ptr.bindMemory(to: Float.self)
                for i in 0..<count {
                    floatSamples[i] = floatPtr[i]
                }
            }
        } else {
            throw AudioResamplerError.unsupportedFormat("暂不支持的 WAV PCM 格式: format=\(audioFormat), bits=\(bitsPerSample)")
        }

        // 多声道转单声道 (平均)
        if channels > 1 {
            let frames = floatSamples.count / Int(channels)
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<Int(channels) {
                    sum += floatSamples[f * Int(channels) + c]
                }
                mono[f] = sum / Float(channels)
            }
            floatSamples = mono
        }

        // 重采样至 16kHz
        return resample(samples: floatSamples, fromSampleRate: Double(sampleRate))
    }
}
