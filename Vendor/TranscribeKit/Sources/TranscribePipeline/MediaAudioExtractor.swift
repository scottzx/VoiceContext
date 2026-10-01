import Foundation
import AVFoundation
import TranscribeCore

public enum MediaAudioExtractorError: Error, LocalizedError {
    case noAudioTrack
    case cannotReadTrack
    case readerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "未在多媒体文件中找到音频轨道"
        case .cannotReadTrack: return "无法读取该多媒体音频轨"
        case .readerFailed(let msg): return "音频解包失败: \(msg)"
        case .cancelled: return "音轨抽取已取消"
        }
    }
}

/// 视频与多媒体音频极速解封装抽取器：基于 AVAssetReader 直出 16kHz mono Float32 PCM
public final class MediaAudioExtractor: Sendable {
    public init() {}

    /// 异步提取媒体音轨并直接转换为 16kHz mono Float32 采样数组
    public func extractAudio(
        from mediaURL: URL,
        targetSampleRate: Double = 16000.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: mediaURL)

        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        if #available(macOS 13.0, iOS 16.0, *) {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } else {
            audioTracks = asset.tracks(withMediaType: .audio)
            duration = asset.duration
        }

        guard let audioTrack = audioTracks.first else {
            throw MediaAudioExtractorError.noAudioTrack
        }

        let totalDurationSeconds = max(0.1, CMTimeGetSeconds(duration))

        // 配置 AVAssetReaderTrackOutput 输出为标准的 16kHz 单声道 Float32 PCM
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw MediaAudioExtractorError.cannotReadTrack
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw MediaAudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "未知启动失败")
        }

        // 预估采样点数量，减少动态扩容
        let estimatedSamples = Int(totalDurationSeconds * targetSampleRate)
        var pcmBuffer: [Float] = []
        pcmBuffer.reserveCapacity(estimatedSamples + 16000)

        var lastReportedProgress: Double = 0.0

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var temp = [Float](repeating: 0, count: floatCount)
            let copyStatus = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &temp)
            if copyStatus == kCMBlockBufferNoErr {
                pcmBuffer.append(contentsOf: temp)
            }

            // 计算进度
            let currentSeconds = Double(pcmBuffer.count) / targetSampleRate
            let currentProgress = min(1.0, currentSeconds / totalDurationSeconds)
            if currentProgress - lastReportedProgress >= 0.05 {
                lastReportedProgress = currentProgress
                progress?(currentProgress)
            }
        }

        if reader.status == .failed {
            throw MediaAudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
        }

        if reader.status == .cancelled {
            throw MediaAudioExtractorError.cancelled
        }

        progress?(1.0)
        return pcmBuffer
    }
}
