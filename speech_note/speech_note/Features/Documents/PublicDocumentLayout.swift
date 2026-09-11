import Foundation

/// Relative layout for the public `VoiceContext/` tree (local Documents and the
/// isomorphic iCloud Drive document-scope container). Absolute device paths
/// never appear in public JSON; raw audio stays outside this layout.
nonisolated enum PublicDocumentLayout {
    static let meetingsRoot = "Meetings"
    static let dailyRoot = "Daily"
    static let transcriptsRoot = "Transcripts"
    static let templatesRoot = "Templates"
    static let skillRoot = "Skill"
    static let foldersRoot = "Folders"
    static let folderCatalogFileName = "catalog.json"
    static let skillPackName = "generate-meeting-minutes"
    static let defaultTemplateFileName = "default-meeting-minutes.md"
    static let generatedDirectoryName = "generated"
    static let transcriptJSONName = "transcript.json"
    static let transcriptMarkdownName = "transcript.md"
    static let timelineJSONName = "timeline.json"
    static let timelineMarkdownName = "timeline.md"


    static var folderCatalogRelativePath: String {
        "\(foldersRoot)/\(folderCatalogFileName)"
    }

    /// Sortable, stable meeting directory:
    /// `Meetings/YYYY/MM/yyyy-MM-dd_HH-mm-ss_<id8>/`
    static func meetingDirectoryRelativePath(
        recordingID: UUID,
        startedAt: Date,
        timezoneIdentifier: String
    ) -> String {
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let parts = localDateParts(startedAt, timeZone: timeZone)
        let stamp = String(
            format: "%04d-%02d-%02d_%02d-%02d-%02d",
            parts.year,
            parts.month,
            parts.day,
            parts.hour,
            parts.minute,
            parts.second
        )
        let shortID = String(recordingID.uuidString.prefix(8)).uppercased()
        return "\(meetingsRoot)/\(String(format: "%04d", parts.year))/\(String(format: "%02d", parts.month))/\(stamp)_\(shortID)"
    }

    static func dailyDirectoryRelativePath(
        date: Date,
        timezoneIdentifier: String
    ) -> String {
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let parts = localDateParts(date, timeZone: timeZone)
        return "\(dailyRoot)/\(String(format: "%04d", parts.year))/\(String(format: "%02d", parts.month))/\(String(format: "%02d", parts.day))"
    }

    static func canonicalTranscriptJSONRelativePath(recordingID: UUID) -> String {
        "\(transcriptsRoot)/\(recordingID.uuidString).json"
    }

    static func canonicalTranscriptMarkdownRelativePath(recordingID: UUID) -> String {
        "\(transcriptsRoot)/\(recordingID.uuidString).md"
    }

    /// Public export path for a session: meeting directory transcript, otherwise
    /// the canonical Transcripts document.
    static func publicTranscriptJSONRelativePath(for document: TranscriptDocumentV1) -> String {
        if document.kind == "meeting" {
            return meetingDirectoryRelativePath(
                recordingID: document.recordingID,
                startedAt: document.startedAt,
                timezoneIdentifier: document.timezone
            ) + "/\(transcriptJSONName)"
        }
        return canonicalTranscriptJSONRelativePath(recordingID: document.recordingID)
    }

    static func publicTranscriptMarkdownRelativePath(for document: TranscriptDocumentV1) -> String {
        if document.kind == "meeting" {
            return meetingDirectoryRelativePath(
                recordingID: document.recordingID,
                startedAt: document.startedAt,
                timezoneIdentifier: document.timezone
            ) + "/\(transcriptMarkdownName)"
        }
        return canonicalTranscriptMarkdownRelativePath(recordingID: document.recordingID)
    }

    static func isSameLocalDay(
        _ lhs: Date,
        _ rhs: Date,
        timezoneIdentifier: String
    ) -> Bool {
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let left = localDateParts(lhs, timeZone: timeZone)
        let right = localDateParts(rhs, timeZone: timeZone)
        return left.year == right.year && left.month == right.month && left.day == right.day
    }

    static func localDayString(_ date: Date, timezoneIdentifier: String) -> String {
        let timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let parts = localDateParts(date, timeZone: timeZone)
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    private struct LocalDateParts {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    private static func localDateParts(_ date: Date, timeZone: TimeZone) -> LocalDateParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return LocalDateParts(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0
        )
    }
}
