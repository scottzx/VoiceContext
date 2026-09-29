import Foundation

nonisolated struct PublicDocumentPublishResult: Equatable, Sendable {
    let meetingDirectoryRelativePath: String?
    let dailyDirectoryRelativePath: String
    let jsonRelativePath: String
    let markdownRelativePath: String
    let timeline: DailyTimelineDocument
    /// Present after a best-effort iCloud mirror pass (nil when mirroring is disabled in tests).
    let iCloudMirror: PublicDocumentMirrorResult?
}

/// Publishes Meetings/Daily open documents beside the canonical Transcripts
/// store. Local Documents remain the Files-visible source when iCloud is off;
/// completed revisions are optionally mirrored into the public ubiquity container.
actor PublicDocumentPublisher {
    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let iCloudMirror: PublicDocumentiCloudMirror?

    enum PublishError: LocalizedError, Equatable {
        case markdownEncodingFailed
        case unresolvedRelativePath(String)

        var errorDescription: String? {
            switch self {
            case .markdownEncodingFailed:
                "无法将公开文档编码为 UTF-8。"
            case .unresolvedRelativePath(let path):
                "公开文档相对路径无效：\(path)"
            }
        }
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        iCloudMirror: PublicDocumentiCloudMirror? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.iCloudMirror = iCloudMirror
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.dateEncodingStrategy = .custom { value, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TranscriptRFC3339DateCoding.string(from: value))
        }
    }

    /// Convenience that attaches the default iCloud mirror for app runtime use.
    convenience init(rootURL: URL, enableDefaultiCloudMirror: Bool, fileManager: FileManager = .default) {
        let mirror: PublicDocumentiCloudMirror? = enableDefaultiCloudMirror
            ? PublicDocumentiCloudMirror(localRootURL: rootURL, fileManager: fileManager)
            : nil
        self.init(rootURL: rootURL, fileManager: fileManager, iCloudMirror: mirror)
    }

    /// Writes/replaces the meeting directory (when needed) and rebuilds the
    /// calendar-day timeline from the provided peer transcripts.
    @discardableResult
    func publish(
        document: TranscriptDocumentV1,
        dayDocuments: [TranscriptDocumentV1]
    ) async throws -> PublicDocumentPublishResult {
        var meetingDirectory: String?
        if document.kind == "meeting" {
            meetingDirectory = try publishMeetingDirectory(document)
        }

        let dayDocs = dayDocuments.contains(where: { $0.recordingID == document.recordingID })
            ? dayDocuments
            : dayDocuments + [document]
        let timeline = try publishDailyTimeline(
            focusing: document,
            dayDocuments: dayDocs
        )

        var result = PublicDocumentPublishResult(
            meetingDirectoryRelativePath: meetingDirectory,
            dailyDirectoryRelativePath: PublicDocumentLayout.dailyDirectoryRelativePath(
                date: document.startedAt,
                timezoneIdentifier: document.timezone
            ),
            jsonRelativePath: PublicDocumentLayout.publicTranscriptJSONRelativePath(for: document),
            markdownRelativePath: PublicDocumentLayout.publicTranscriptMarkdownRelativePath(for: document),
            timeline: timeline,
            iCloudMirror: nil
        )

        if let iCloudMirror {
            // Best-effort: iCloud failures must not undo the local publish (FR-ICL-003).
            // `mirror` never throws; space/network/conflict become attention on the result.
            let mirrorResult = await iCloudMirror.mirror(
                publishResult: result,
                documentState: document.state
            )
            result = PublicDocumentPublishResult(
                meetingDirectoryRelativePath: result.meetingDirectoryRelativePath,
                dailyDirectoryRelativePath: result.dailyDirectoryRelativePath,
                jsonRelativePath: result.jsonRelativePath,
                markdownRelativePath: result.markdownRelativePath,
                timeline: result.timeline,
                iCloudMirror: mirrorResult
            )
            let captured = mirrorResult
            await MainActor.run {
                DocumentSyncStatusCenter.shared.record(publicMirror: captured)
            }
        }
        NotificationCenter.default.post(name: Notification.Name("VoiceContext.documentsChanged"), object: nil)
        return result
    }

    func resolveURL(relativePath: String) throws -> URL {
        do {
            return try PublicDocumentFileIO.resolveURL(rootURL: rootURL, relativePath: relativePath)
        } catch {
            throw PublishError.unresolvedRelativePath(relativePath)
        }
    }

    private func publishMeetingDirectory(_ document: TranscriptDocumentV1) throws -> String {
        let relativeDirectory = PublicDocumentLayout.meetingDirectoryRelativePath(
            recordingID: document.recordingID,
            startedAt: document.startedAt,
            timezoneIdentifier: document.timezone
        )
        let directoryURL = try resolveURL(relativePath: relativeDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: directoryURL.appendingPathComponent(PublicDocumentLayout.generatedDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        let jsonData = try encoder.encode(document)
        let markdown = TranscriptMarkdownRenderer.render(document)
        guard let markdownData = markdown.data(using: .utf8) else {
            throw PublishError.markdownEncodingFailed
        }

        let jsonURL = directoryURL.appendingPathComponent(PublicDocumentLayout.transcriptJSONName)
        let markdownURL = directoryURL.appendingPathComponent(PublicDocumentLayout.transcriptMarkdownName)
        try atomicWrite(jsonData, to: jsonURL)
        try atomicWrite(markdownData, to: markdownURL)
        return relativeDirectory
    }

    private func publishDailyTimeline(
        focusing document: TranscriptDocumentV1,
        dayDocuments: [TranscriptDocumentV1]
    ) throws -> DailyTimelineDocument {
        let timezone = document.timezone
        let peers = dayDocuments.filter {
            PublicDocumentLayout.isSameLocalDay(
                $0.startedAt,
                document.startedAt,
                timezoneIdentifier: timezone
            )
        }
        let entries = peers
            .map(DailyTimelineDocument.entry(from:))
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.recordingID.uuidString < rhs.recordingID.uuidString
            }
        let timeline = DailyTimelineDocument(
            date: PublicDocumentLayout.localDayString(document.startedAt, timezoneIdentifier: timezone),
            timezone: timezone,
            entries: entries
        )

        let relativeDirectory = PublicDocumentLayout.dailyDirectoryRelativePath(
            date: document.startedAt,
            timezoneIdentifier: timezone
        )
        let directoryURL = try resolveURL(relativePath: relativeDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let jsonData = try encoder.encode(timeline)
        let markdown = DailyTimelineMarkdownRenderer.render(timeline)
        guard let markdownData = markdown.data(using: .utf8) else {
            throw PublishError.markdownEncodingFailed
        }
        try atomicWrite(
            jsonData,
            to: directoryURL.appendingPathComponent(PublicDocumentLayout.timelineJSONName)
        )
        try atomicWrite(
            markdownData,
            to: directoryURL.appendingPathComponent(PublicDocumentLayout.timelineMarkdownName)
        )
        return timeline
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try PublicDocumentFileIO.writeAtomically(data, to: destination, fileManager: fileManager)
    }
}
