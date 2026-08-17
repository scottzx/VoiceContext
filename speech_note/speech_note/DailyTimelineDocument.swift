import Foundation

/// Calendar-day index of Recording sessions. Entries reference canonical public
/// transcript paths and never embed a full transcript copy (FR-DOC-005).
nonisolated struct DailyTimelineDocument: Codable, Equatable, Sendable {
    static let schema = "voice-context/timeline@1"

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let recordingID: UUID
        let kind: String
        let state: String
        let revision: Int
        let title: String?
        let startedAt: Date
        let endedAt: Date?
        /// Path relative to the VoiceContext root (no absolute device paths).
        let relativePath: String

        var id: UUID { recordingID }

        private enum CodingKeys: String, CodingKey {
            case recordingID = "recording_id"
            case kind
            case state
            case revision
            case title
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case relativePath = "relative_path"
        }
    }

    let schema: String
    let date: String
    let timezone: String
    let revision: Int
    let entries: [Entry]

    private enum CodingKeys: String, CodingKey {
        case schema
        case date
        case timezone
        case revision
        case entries
    }

    init(date: String, timezone: String, entries: [Entry]) {
        schema = Self.schema
        self.date = date
        self.timezone = timezone
        // Derived index: revision tracks the peer transcript revisions so a
        // day file changes whenever any referenced session advances.
        revision = max(1, entries.map(\.revision).reduce(0, +))
        self.entries = entries.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.recordingID.uuidString < rhs.recordingID.uuidString
        }
    }

    static func entry(from document: TranscriptDocumentV1) -> Entry {
        Entry(
            recordingID: document.recordingID,
            kind: document.kind,
            state: document.state,
            revision: document.revision,
            title: document.title,
            startedAt: document.startedAt,
            endedAt: document.endedAt,
            relativePath: PublicDocumentLayout.publicTranscriptJSONRelativePath(for: document)
        )
    }
}

nonisolated enum DailyTimelineMarkdownRenderer {
    static func render(_ document: DailyTimelineDocument) -> String {
        var lines = [
            "---",
            "schema: \(document.schema)",
            "date: \(document.date)",
            "timezone: \(yamlString(document.timezone))",
            "revision: \(document.revision)",
            "---",
            ""
        ]

        if document.entries.isEmpty {
            lines.append("_当日暂无已生成的逐字稿。_")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for entry in document.entries {
            let time = entry.startedAt.formatted(date: .omitted, time: .shortened)
            let title = entry.title?.isEmpty == false ? entry.title! : defaultTitle(for: entry.kind)
            lines.append("## \(time) · \(title)")
            lines.append("- recording_id: \(entry.recordingID.uuidString)")
            lines.append("- kind: \(entry.kind)")
            lines.append("- state: \(entry.state)")
            lines.append("- revision: \(entry.revision)")
            lines.append("- path: \(entry.relativePath)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func defaultTitle(for kind: String) -> String {
        kind == "meeting" ? "未命名会议" : "未命名录音"
    }

    private static func yamlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
