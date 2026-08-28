import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Copies a Files-picked audio into the private VoiceContext tree, plans
/// logical ProcessingRanges, and creates the durable Recording + range jobs.
nonisolated struct ImportAudioImporter: Sendable {
    nonisolated enum ImportError: LocalizedError, Equatable {
        case unsupportedFormat
        case unreadable
        case insufficientStorage(availableBytes: Int64, minimumBytes: Int64)
        case copyFailed(String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "无法读取此音频或视频格式"
            case .unreadable:
                "音频文件无法读取，原文件未被修改"
            case let .insufficientStorage(available, minimum):
                "剩余存储空间不足（\(available) bytes）；至少需要 \(minimum) bytes。"
            case let .copyFailed(message):
                "导入复制失败：\(message)"
            case .emptyAudio:
                "音频没有可处理的时长"
            }
        }
    }

    nonisolated struct Result: Equatable, Sendable {
        let recording: Recording
        let asset: ImportedAudioAsset
        let ranges: [ProcessingRange]
    }

    nonisolated struct SourceMetadata: Equatable, Sendable {
        let durationSeconds: TimeInterval
        let sampleRate: Double?
        let channelCount: Int?
        let byteCount: Int64?
        let totalSamples: Int64
        let utTypeIdentifier: String
    }

    private let fileManager: FileManager
    private let storageGuard: LowStorageGuard

    init(
        fileManager: FileManager = .default,
        storageGuard: LowStorageGuard = LowStorageGuard()
    ) {
        self.fileManager = fileManager
        self.storageGuard = storageGuard
    }

    /// Validates `sourceURL`, privately copies it, and returns durable models.
    /// Does not enqueue transcription; the caller owns scheduler interaction.
    /// When the private copy cannot stably random-access decode (or
    /// `forceStandardize` is set), replaces it with one standardized AAC asset.
    func importAudio(
        from sourceURL: URL,
        into rootURL: URL,
        recordingID: UUID = UUID(),
        assetID: UUID = UUID(),
        now: Date = Date(),
        title: String? = nil,
        isMeeting: Bool = false,
        forceStandardize: Bool = false,
        sourceFilenameOverride: String? = nil,
        sourceUTTypeOverride: String? = nil
    ) throws -> Result {
        try Self.rejectClearlyUnsupported(sourceURL)
        try storageGuard.validateCanStartRecording(at: rootURL)

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try readMetadata(from: sourceURL)
        guard metadata.totalSamples > 0, metadata.durationSeconds > 0 else {
            throw ImportError.emptyAudio
        }

        let filename: String = {
            if let override = sourceFilenameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                return override
            }
            return sourceURL.lastPathComponent
        }()
        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let relativePath = "ImportedAudio/\(recordingID.uuidString)/source.\(ext)"
        let destination = rootURL.appendingPathComponent(relativePath)
        let privateDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: privateDirectory)
            throw ImportError.copyFailed(error.localizedDescription)
        }
        // Private copy only — never mutate the Files/Photos original.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var destinationURL = destination
        try? destinationURL.setResourceValues(values)

        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = (filename as NSString).deletingPathExtension
        let utType = sourceUTTypeOverride ?? metadata.utTypeIdentifier
        let recording = Recording(
            id: recordingID,
            startedAt: now,
            endedAt: now.addingTimeInterval(metadata.durationSeconds),
            title: (displayTitle?.isEmpty == false) ? displayTitle : fallbackTitle,
            isMeeting: isMeeting,
            state: .processing,
            updatedAt: now,
            origin: .importedAudio,
            sourceFilename: filename,
            sourceUTType: utType,
            languageMode: TranscriptionLanguageMode.current
        )
        var asset = ImportedAudioAsset(
            id: assetID,
            recordingID: recordingID,
            relativePath: relativePath,
            sourceFilename: filename,
            sourceUTType: utType,
            durationSeconds: metadata.durationSeconds,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            byteCount: metadata.byteCount,
            totalSamples: metadata.totalSamples,
            importedAt: now
        )
        do {
            if forceStandardize || !ImportAudioStandardizer.supportsRandomAccess(at: destination) {
                do {
                    asset = try ImportAudioStandardizer.replaceWithStandardized(
                        asset: asset,
                        rootURL: rootURL,
                        fileManager: fileManager
                    )
                } catch let error as ImportAudioStandardizer.StandardizerError {
                    switch error {
                    case .unreadable, .emptyAudio:
                        throw ImportError.unreadable
                    case let .exportFailed(message):
                        throw ImportError.copyFailed(message)
                    }
                }
            }
            let planned = ProcessingRangePlanner.plan(totalSamples: asset.totalSamples)
            let ranges = planned.map { item in
                ProcessingRange(
                    recordingID: recordingID,
                    assetID: assetID,
                    sequence: item.sequence,
                    startSample: item.startSample,
                    endSample: item.endSample,
                    createdAt: now
                )
            }
            return Result(recording: recording, asset: asset, ranges: ranges)
        } catch {
            // Never leave a half Recording; also drop orphaned private media.
            try? fileManager.removeItem(at: privateDirectory)
            throw error
        }
    }

    /// Pure helper for tests: privately copy bytes and return the destination.
    func copyPrivately(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        return destinationURL
    }

    /// Rejects image/PDF/other clearly non-audio types before decode so callers
    /// can show a readable unsupported-format error without creating records.
    nonisolated static func rejectClearlyUnsupported(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "webp", "tiff"]
        let docExts: Set<String> = ["pdf", "txt", "rtf", "doc", "docx", "pages", "zip"]
        if imageExts.contains(ext) || docExts.contains(ext) {
            throw ImportError.unsupportedFormat
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text) {
                throw ImportError.unsupportedFormat
            }
        }
    }

    nonisolated static func readMetadata(from url: URL) throws -> SourceMetadata {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // Video containers and unknown codecs surface as unsupported rather
            // than a generic IO failure when the extension looks audiovisual.
            let ext = url.pathExtension.lowercased()
            let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv"]
            if videoExts.contains(ext) {
                throw ImportError.unsupportedFormat
            }
            throw ImportError.unreadable
        }
        let format = file.fileFormat
        guard format.sampleRate > 0, file.length > 0 else {
            throw ImportError.unreadable
        }
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0 else { throw ImportError.emptyAudio }
        let totalSamples = ProcessingRangePlanner.totalSamples(duration: duration)
        guard totalSamples > 0 else { throw ImportError.emptyAudio }

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        let utType = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.audio.identifier

        return SourceMetadata(
            durationSeconds: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            byteCount: byteCount,
            totalSamples: totalSamples,
            utTypeIdentifier: utType
        )
    }

    private func readMetadata(from url: URL) throws -> SourceMetadata {
        try Self.readMetadata(from: url)
    }
}
