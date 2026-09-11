import AVFoundation
import Foundation

/// Probes whether an imported private copy supports stable random-access
/// decode, and when it does not, materializes **one** standardized private
/// asset (16 kHz mono CAF PCM). ProcessingRange still owns no media files.
nonisolated enum ImportAudioStandardizer: Sendable {
    nonisolated enum StandardizerError: LocalizedError, Equatable {
        case unreadable
        case exportFailed(String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "音频文件无法读取，原文件未被修改"
            case let .exportFailed(message):
                "无法生成标准化私有音频：\(message)"
            case .emptyAudio:
                "音频没有可处理的时长"
            }
        }
    }

    /// File name used for the unique standardized private media asset.
    nonisolated static let standardizedFileName = "standardized.caf"
    nonisolated static let targetSampleRate = ProcessingRangePlanner.sampleRate
    private nonisolated static let bufferFrames: AVAudioFrameCount = 4_096

    /// Returns true when mid/end seeks plus short reads succeed. Failure means
    /// callers may generate one standardized private asset.
    nonisolated static func supportsRandomAccess(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.processingFormat.sampleRate > 0 else { return false }
            let probes: [AVAudioFramePosition] = [
                0,
                max(0, file.length / 2),
                max(0, file.length - Int64(bufferFrames)),
            ]
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames) else {
                return false
            }
            for position in Set(probes) {
                file.framePosition = position
                let remaining = file.length - file.framePosition
                guard remaining > 0 else { continue }
                try file.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(min(Int64(bufferFrames), remaining))
                )
                if buffer.frameLength == 0 { return false }
            }
            // Also exercise the same range decoder used by transcription /
            // offline recluster so "opens but cannot window-decode" fails here.
            let total = ProcessingRangePlanner.totalSamples(
                duration: Double(file.length) / file.fileFormat.sampleRate
            )
            guard total > 0 else { return false }
            let start = min(total / 2, max(0, total - 1_600))
            let end = min(total, start + 1_600)
            _ = try ImportAudioRangeDecoder.samples(from: url, startSample: start, endSample: end)
            return true
        } catch {
            return false
        }
    }

    /// Streams `sourceURL` into a single 16 kHz mono CAF PCM file.
    /// Never materializes the whole source as one contiguous PCM array.
    @discardableResult
    nonisolated static func standardize(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw StandardizerError.unreadable
        }
        guard source.length > 0, source.processingFormat.sampleRate > 0 else {
            throw StandardizerError.emptyAudio
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw StandardizerError.exportFailed("无法创建 16 kHz 单声道目标格式")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let destination: AVAudioFile
        do {
            destination = try AVAudioFile(
                forWriting: destinationURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw StandardizerError.exportFailed(error.localizedDescription)
        }

        let sourceFormat = source.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw StandardizerError.exportFailed("无法创建音频转换器")
        }

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: bufferFrames)!
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(bufferFrames) * ratio) + 32
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(outputCapacity, 1)
        )!

        final class InputFlag: @unchecked Sendable {
            var consumed = false
        }

        source.framePosition = 0
        var wroteFrames: AVAudioFramePosition = 0
        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(bufferFrames), remaining))
            do {
                try source.read(into: inputBuffer, frameCount: framesToRead)
            } catch {
                throw StandardizerError.exportFailed(error.localizedDescription)
            }
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
                throw StandardizerError.exportFailed(error?.localizedDescription ?? "convert error")
            }
            if outputBuffer.frameLength > 0 {
                do {
                    try destination.write(from: outputBuffer)
                } catch {
                    throw StandardizerError.exportFailed(error.localizedDescription)
                }
                wroteFrames += AVAudioFramePosition(outputBuffer.frameLength)
            }
            if status == .endOfStream { break }
        }

        guard wroteFrames > 0 else { throw StandardizerError.emptyAudio }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var destinationMutable = destinationURL
        try? destinationMutable.setResourceValues(values)
        return destinationURL
    }

    /// Replaces the asset's private media with one standardized file, deletes
    /// the previous private copy when it differs, and returns the updated model.
    nonisolated static func replaceWithStandardized(
        asset: ImportedAudioAsset,
        rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportedAudioAsset {
        let sourceURL = rootURL.appendingPathComponent(asset.relativePath)
        let directory = sourceURL.deletingLastPathComponent()
        let destinationURL = directory.appendingPathComponent(standardizedFileName)
        _ = try standardize(from: sourceURL, to: destinationURL, fileManager: fileManager)

        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
           fileManager.fileExists(atPath: sourceURL.path) {
            try? fileManager.removeItem(at: sourceURL)
        }

        let metadata = try ImportAudioImporter.readMetadata(from: destinationURL)
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let destPath = destinationURL.resolvingSymlinksInPath().path
        let stableRelative: String = {
            if destPath.hasPrefix(rootPath) {
                var suffix = String(destPath.dropFirst(rootPath.count))
                if suffix.hasPrefix("/") { suffix.removeFirst() }
                return suffix
            }
            return "ImportedAudio/\(asset.recordingID.uuidString)/\(standardizedFileName)"
        }()

        return ImportedAudioAsset(
            id: asset.id,
            recordingID: asset.recordingID,
            relativePath: stableRelative,
            sourceFilename: asset.sourceFilename,
            sourceUTType: metadata.utTypeIdentifier,
            durationSeconds: metadata.durationSeconds,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            byteCount: metadata.byteCount,
            totalSamples: metadata.totalSamples,
            importedAt: asset.importedAt,
            audioRemovedAt: asset.audioRemovedAt,
            isStandardized: true
        )
    }
}
