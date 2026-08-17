import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Extracts an audio-only private media file from a Photos/Files video so the
/// existing ImportedAudioAsset / ProcessingRange pipeline can import it.
/// There is **no product-level duration cap** (FR-ADD-IMP-007); long media is
/// handled by streaming export + standardize/windows/queue downstream.
nonisolated enum ImportVideoAudioExtractor: Sendable {
    nonisolated enum ExtractError: LocalizedError, Equatable {
        case noAudioTrack
        case unreadable
        case unsupportedFormat
        case emptyAudio
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "该视频没有可导入的音轨"
            case .unreadable:
                "视频无法读取，原文件未被修改"
            case .unsupportedFormat:
                "无法读取此视频或音频格式"
            case .emptyAudio:
                "视频音轨没有可处理的时长"
            case let .exportFailed(message):
                "抽取音轨失败：\(message)"
            case .cancelled:
                "已取消音轨抽取"
            }
        }
    }

    /// Writes AAC `.m4a` containing only the source video's audio track.
    /// Reports `progressHandler` on the calling task's executor (0...1).
    @discardableResult
    static func extractAudioTrack(
        from videoURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let accessing = videoURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                videoURL.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: videoURL)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ExtractError.unreadable
        }
        guard !audioTracks.isEmpty else { throw ExtractError.noAudioTrack }

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ExtractError.unreadable
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw ExtractError.emptyAudio }
        // Intentionally no max-duration gate (FR-ADD-IMP-007).

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExtractError.unsupportedFormat
        }
        session.outputURL = destinationURL
        session.outputFileType = .m4a

        progressHandler?(0)
        let progressReporter = Task { @Sendable in
            while !Task.isCancelled {
                progressHandler?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        progressReporter.cancel()
        progressHandler?(1)

        switch session.status {
        case .completed:
            guard fileManager.fileExists(atPath: destinationURL.path) else {
                throw ExtractError.exportFailed("导出文件不存在")
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDestination = destinationURL
            try? mutableDestination.setResourceValues(values)
            return destinationURL
        case .cancelled:
            try? fileManager.removeItem(at: destinationURL)
            throw ExtractError.cancelled
        case .failed:
            try? fileManager.removeItem(at: destinationURL)
            throw ExtractError.exportFailed(
                session.error?.localizedDescription ?? "unknown export failure"
            )
        default:
            try? fileManager.removeItem(at: destinationURL)
            throw ExtractError.exportFailed("unexpected export status")
        }
    }
}

/// PhotosPicker transferable that materializes a local temp copy of a movie
/// without requiring full Photo Library entitlement access.
struct ImportPickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceived(received)
        }
        FileRepresentation(contentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceived(received)
        }
        FileRepresentation(contentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceived(received)
        }
        FileRepresentation(contentType: .audiovisualContent) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceived(received)
        }
    }

    private static func importReceived(_ received: ReceivedTransferredFile) throws -> ImportPickedMovie {
        let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceContext-PickedVideo-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: received.file, to: destination)
        return ImportPickedMovie(url: destination)
    }
}
