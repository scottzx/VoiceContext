import AVFoundation
import Foundation

/// Decodes only the requested absolute 16 kHz sample window from an imported
/// asset. Conversion streams through a fixed-size buffer so multi-minute files
/// are never materialized as one contiguous PCM array.
nonisolated enum ImportAudioRangeDecoder: Sendable {
    nonisolated enum DecoderError: LocalizedError, Equatable {
        case unreadable
        case emptyRange
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "音频文件无法读取，原文件未被修改"
            case .emptyRange:
                "处理范围没有可解码的音频样本"
            case .conversionFailed:
                "无法将导入音频规范化为 16 kHz 单声道 PCM"
            }
        }
    }

    nonisolated static let targetSampleRate = ProcessingRangePlanner.sampleRate
    private nonisolated static let bufferFrames: AVAudioFrameCount = 4_096

    /// Returns float32 mono PCM for `[startSample, endSample)` on the Recording
    /// 16 kHz clock. Source media may use any AVFoundation-decodable rate.
    nonisolated static func samples(
        from url: URL,
        startSample: Int64,
        endSample: Int64
    ) throws -> [Float] {
        guard endSample > startSample else { throw DecoderError.emptyRange }
        let needed = Int(endSample - startSample)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecoderError.unreadable
        }

        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw DecoderError.unreadable
        }

        let sourceStart = AVAudioFramePosition(
            (Double(startSample) * sourceFormat.sampleRate / targetSampleRate).rounded(.down)
        )
        let clampedStart = max(0, min(sourceStart, file.length))
        file.framePosition = clampedStart

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let targetFormat else { throw DecoderError.conversionFailed }

        if sourceFormat.sampleRate == targetSampleRate, sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32
        {
            return try readNativeMono(file: file, needed: needed)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw DecoderError.conversionFailed
        }

        var output: [Float] = []
        output.reserveCapacity(needed)
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: bufferFrames)!
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(bufferFrames) * ratio) + 32
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outputCapacity, 1))!
        final class InputFlag: @unchecked Sendable {
            var consumed = false
        }

        while output.count < needed, file.framePosition < file.length {
            let remainingSource = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(bufferFrames), remainingSource))
            try file.read(into: inputBuffer, frameCount: framesToRead)
            if inputBuffer.frameLength == 0 { break }

            let flag = InputFlag()
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if flag.consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                flag.consumed = true
                status.pointee = .haveData
                return inputBuffer
            }

            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            if status == .error || error != nil {
                throw DecoderError.conversionFailed
            }
            guard let channel = outputBuffer.floatChannelData?[0] else {
                throw DecoderError.conversionFailed
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 {
                let remaining = needed - output.count
                output.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: min(produced, remaining))
                )
            }
            if status == .endOfStream { break }
        }

        guard !output.isEmpty else { throw DecoderError.emptyRange }
        if output.count < needed {
            output.append(contentsOf: repeatElement(0, count: needed - output.count))
        }
        return output
    }

    private nonisolated static func readNativeMono(file: AVAudioFile, needed: Int) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(needed)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferFrames)!
        while output.count < needed, file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(bufferFrames), remaining)))
            guard let channel = buffer.floatChannelData?[0] else {
                throw DecoderError.conversionFailed
            }
            let produced = Int(buffer.frameLength)
            let take = min(produced, needed - output.count)
            output.append(contentsOf: UnsafeBufferPointer(start: channel, count: take))
        }
        guard !output.isEmpty else { throw DecoderError.emptyRange }
        return output
    }
}
