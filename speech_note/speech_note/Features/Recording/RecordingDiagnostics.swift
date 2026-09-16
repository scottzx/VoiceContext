@preconcurrency import AVFoundation
import Foundation

nonisolated enum RecordingIntegrityIssue: Codable, Equatable, Sendable {
    case invalidSampleRange(chunkID: UUID, startSample: Int64, endSample: Int64)
    case overlappingChunks(previousChunkID: UUID, nextChunkID: UUID, overlapSamples: Int64)
    case unexplainedMissingSamples(previousChunkID: UUID, nextChunkID: UUID, missingSamples: Int64)
    case missingAudioFile(chunkID: UUID, relativePath: String)
    case unreadableAudioFile(chunkID: UUID, relativePath: String)
    case unindexedAudioFile(relativePath: String)
}

nonisolated struct RecordingDiagnostics: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let isPlayableAudio: @Sendable (URL) -> Bool

    init(
        fileExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        isPlayableAudio: @escaping @Sendable (URL) -> Bool = RecordingDiagnostics.avAudioIsReadable
    ) {
        self.fileExists = fileExists
        self.isPlayableAudio = isPlayableAudio
    }

    func inspect(
        chunks: [AudioChunk],
        gaps: [RecordingGap],
        rootURL: URL
    ) -> [RecordingIntegrityIssue] {
        let chunks = chunks.sorted { $0.startSample < $1.startSample }
        var issues: [RecordingIntegrityIssue] = []

        for chunk in chunks {
            if chunk.endSample <= chunk.startSample {
                issues.append(.invalidSampleRange(
                    chunkID: chunk.id,
                    startSample: chunk.startSample,
                    endSample: chunk.endSample
                ))
            }
            guard chunk.state == .closed else { continue }
            let url = rootURL.appendingPathComponent(chunk.relativePath)
            if !fileExists(url) {
                issues.append(.missingAudioFile(chunkID: chunk.id, relativePath: chunk.relativePath))
            } else if !isPlayableAudio(url) {
                issues.append(.unreadableAudioFile(chunkID: chunk.id, relativePath: chunk.relativePath))
            }
        }

        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            if next.startSample < previous.endSample {
                issues.append(.overlappingChunks(
                    previousChunkID: previous.id,
                    nextChunkID: next.id,
                    overlapSamples: previous.endSample - next.startSample
                ))
            } else if next.startSample > previous.endSample {
                let isExplained = gaps.contains { gap in
                    guard let endSample = gap.endSample else { return false }
                    return gap.startSample <= previous.endSample && endSample >= next.startSample
                }
                if !isExplained {
                    issues.append(.unexplainedMissingSamples(
                        previousChunkID: previous.id,
                        nextChunkID: next.id,
                        missingSamples: next.startSample - previous.endSample
                    ))
                }
            }
        }
        return issues
    }

    func inspect(recordingID: UUID, repository: RecordingRepository) async throws -> [RecordingIntegrityIssue] {
        let chunks = try await repository.chunks(recordingID: recordingID)
        let gaps = try await repository.gaps(recordingID: recordingID)
        var issues = inspect(chunks: chunks, gaps: gaps, rootURL: repository.rootURL)

        let audioDirectory = repository.rootURL
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: audioDirectory.path) else {
            return issues
        }

        let indexedPaths = Set(chunks.map {
            repository.rootURL
                .appendingPathComponent($0.relativePath)
                .standardizedFileURL.path
        })
        let rootPath = repository.rootURL.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "m4a" else { continue }
                if !indexedPaths.contains(url.standardizedFileURL.path) {
                    let path = url.standardizedFileURL.path
                    let relativePath = path.hasPrefix(rootPath + "/")
                        ? String(path.dropFirst(rootPath.count + 1))
                        : url.lastPathComponent
                    issues.append(.unindexedAudioFile(relativePath: relativePath))
                }
            }
        }
        return issues
    }

    private static func avAudioIsReadable(_ url: URL) -> Bool {
        PCM16KMonoLoader.isReadable(url)
    }
}

nonisolated struct RecordingValidationReport: Codable, Equatable, Sendable {
    nonisolated enum Outcome: String, Codable, Sendable {
        case pending
        case passed
        case failed
    }

    nonisolated struct Check: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        var outcome: Outcome
        var notes: String
    }

    var deviceModel: String
    var operatingSystem: String
    var appBuild: String
    var startedAt: Date
    var completedAt: Date?
    var checks: [Check]
    var integrityIssues: [RecordingIntegrityIssue]

    func markdown() -> String {
        let formatter = ISO8601DateFormatter()
        let completed = completedAt.map(formatter.string) ?? "待完成"
        let rows = checks.map { check in
            "| \(check.title) | \(check.outcome.rawValue) | \(check.notes.replacingOccurrences(of: "|", with: "\\|")) |"
        }.joined(separator: "\n")
        let issues = integrityIssues.isEmpty
            ? "- 未发现索引、样本边界、音频可读性或未入索引 AAC 问题。"
            : integrityIssues.map { "- \(String(describing: $0))" }.joined(separator: "\n")
        return """
        # 0.1.0 录音核心验证报告

        - 设备：\(deviceModel)
        - 系统：\(operatingSystem)
        - App 构建：\(appBuild)
        - 开始：\(formatter.string(from: startedAt))
        - 完成：\(completed)

        | 检查项 | 结果 | 记录 |
        | --- | --- | --- |
        \(rows)

        ## 完整性诊断

        \(issues)
        """
    }
}
