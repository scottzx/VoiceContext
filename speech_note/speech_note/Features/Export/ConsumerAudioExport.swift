import AVFoundation
import Foundation

/// FR-ADD-EXP-003 / FR-ADD-EXP-004: prepare a Share Sheet audio payload.
///
/// Strategy (must not corrupt source Recording media):
/// - Imported assets: always copy the private asset into a temp export file.
/// - Microphone recordings with one closed chunk: copy that chunk file.
/// - Microphone recordings with multiple closed chunks: concatenate into a
///   temporary AAC (`.m4a`) via `AVMutableComposition` / `AVAssetExportSession`.
/// - Sources under the repository root are never truncated, renamed, or
///   overwritten by this path.
enum ConsumerAudioExport {
    enum Prepared: Equatable, Sendable {
        case available(URL)
        case unavailable(String)
    }

    @MainActor
    static func prepareShareableAudio(
        rootURL: URL,
        title: String?,
        recordingID: UUID,
        chunks: [AudioChunk],
        importedAsset: ImportedAudioAsset?,
        fileManager: FileManager = .default
    ) async -> Prepared {
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("VoiceContextConsumerExports", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        } catch {
            return .unavailable("无法准备音频导出目录。")
        }

        let baseName = ConsumerExportFileNaming.baseName(title: title, recordingID: recordingID)

        if let importedAsset {
            guard importedAsset.audioRemovedAt == nil else {
                return .unavailable("导入音频已在本机清理。")
            }
            let source = rootURL.appendingPathComponent(importedAsset.relativePath)
            guard fileManager.fileExists(atPath: source.path) else {
                return .unavailable("导入音频暂不可用。")
            }
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let destination = exportRoot.appendingPathComponent("\(baseName).\(ext)")
            do {
                try copyReplacing(from: source, to: destination, fileManager: fileManager)
                return .available(destination)
            } catch {
                return .unavailable("无法复制导入音频供分享。")
            }
        }

        let playable = chunks
            .filter { $0.state == .closed && $0.audioRemovedAt == nil }
            .sorted { $0.startSample < $1.startSample }
            .compactMap { chunk -> (AudioChunk, URL)? in
                let url = rootURL.appendingPathComponent(chunk.relativePath)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return (chunk, url)
            }

        guard !playable.isEmpty else {
            return .unavailable("没有可分享的音频。")
        }

        if playable.count == 1, let only = playable.first {
            let ext = only.1.pathExtension.isEmpty ? "m4a" : only.1.pathExtension
            let destination = exportRoot.appendingPathComponent("\(baseName).\(ext)")
            do {
                try copyReplacing(from: only.1, to: destination, fileManager: fileManager)
                return .available(destination)
            } catch {
                return .unavailable("无法复制录音音频供分享。")
            }
        }

        let destination = exportRoot.appendingPathComponent("\(baseName).m4a")
        do {
            try await concatenate(urls: playable.map(\.1), to: destination, fileManager: fileManager)
            return .available(destination)
        } catch {
            return .unavailable("无法拼接录音分片供分享。")
        }
    }

    private static func copyReplacing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    @MainActor
    private static func concatenate(
        urls: [URL],
        to destination: URL,
        fileManager: FileManager
    ) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionFailed
        }

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let assetTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = assetTracks.first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: cursor
            )
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > .zero else {
            throw ExportError.emptyComposition
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.exportSessionUnavailable
        }
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    private enum ExportError: Error {
        case compositionFailed
        case emptyComposition
        case exportSessionUnavailable
        case exportFailed(String)
    }
}
