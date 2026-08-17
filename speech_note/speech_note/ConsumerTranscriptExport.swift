import Foundation

/// Safe file-name stem for Share Sheet / Files handoff of consumer exports.
nonisolated enum ConsumerExportFileNaming {
    static func baseName(title: String?, recordingID: UUID) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = trimmed.isEmpty
            ? "recording-\(recordingID.uuidString.lowercased().prefix(8))"
            : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        let stem = collapsed.isEmpty
            ? "recording-\(recordingID.uuidString.lowercased().prefix(8))"
            : collapsed
        return String(stem.prefix(80))
    }
}

/// FR-ADD-EXP-001: readable plain text without YAML front matter.
nonisolated enum TranscriptPlainTextRenderer {
    static func render(_ document: TranscriptDocumentV1) -> String {
        var body: [String] = []
        for segment in document.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offset = offsetString(segment.offsetMilliseconds)
            if let speaker = speakerLabel(for: segment, in: document) {
                body.append("[+\(offset)] \(speaker)")
            } else {
                body.append("[+\(offset)]")
            }
            body.append(text)
            body.append("")
        }
        while body.last?.isEmpty == true {
            body.removeLast()
        }
        guard !body.isEmpty else { return "" }

        var lines: [String] = []
        let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            lines.append(title)
            lines.append("")
        }
        lines.append(contentsOf: body)
        return lines.joined(separator: "\n") + "\n"
    }

    static func speakerLabel(
        for segment: TranscriptDocumentV1.Segment,
        in document: TranscriptDocumentV1
    ) -> String? {
        let mid = (segment.startSample + segment.endSample) / 2
        guard let turn = document.speakerTurns.first(where: {
            $0.startSample <= mid && mid < max($0.endSample, $0.startSample + 1)
        }) else {
            return nil
        }
        let label = turn.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? nil : label
    }

    static func offsetString(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = value / 60_000 % 60
        let seconds = value / 1_000 % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

/// FR-ADD-EXP-002: SRT cues aligned to segment start/end on the 16 kHz timeline.
nonisolated enum TranscriptSRTRenderer {
    static func render(_ document: TranscriptDocumentV1) -> String {
        var blocks: [String] = []
        var index = 1
        for segment in document.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = max(0, segment.playbackStartTime)
            var end = max(start, segment.playbackEndTime)
            if end <= start {
                end = start + 0.001
            }
            let body: String
            if let speaker = TranscriptPlainTextRenderer.speakerLabel(for: segment, in: document) {
                body = "\(speaker): \(text)"
            } else {
                body = text
            }
            blocks.append(
                """
                \(index)
                \(formatTimestamp(start)) --> \(formatTimestamp(end))
                \(body)
                """
            )
            index += 1
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let secs = totalMilliseconds / 1_000 % 60
        let millis = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
