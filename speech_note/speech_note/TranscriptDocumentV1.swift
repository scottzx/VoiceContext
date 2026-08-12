import Foundation

private nonisolated enum TranscriptRFC3339DateCoding {
    static func normalizedToMilliseconds(_ value: Date) -> Date {
        let milliseconds = (value.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    static func string(from value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: normalizedToMilliseconds(value))
    }

    static func date(from value: String) -> Date? {
        let millisecondsFormatter = ISO8601DateFormatter()
        millisecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = millisecondsFormatter.date(from: value) {
            return normalizedToMilliseconds(date)
        }

        // Transcript files written before millisecond precision used
        // JSONEncoder's `.iso8601` strategy and therefore omitted fractions.
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        return legacyFormatter.date(from: value)
    }
}

/// The canonical, local-first representation of a completed Recording.
/// Markdown is always derived from this value; callers must not treat the
/// rendered file as editable source data.
nonisolated struct TranscriptDocumentV1: Codable, Equatable, Sendable {
    static let schema = "voice-context/transcript@1"

    enum DocumentError: LocalizedError, Equatable {
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .emptyTranscript:
                "未识别到可保存的文本，录音保留，可重新处理。"
            }
        }
    }

    struct Audio: Codable, Equatable, Sendable {
        let localOnly: Bool
        let availableOnThisDevice: Bool
        let retention: String

        private enum CodingKeys: String, CodingKey {
            case localOnly = "local_only"
            case availableOnThisDevice = "available_on_this_device"
            case retention
        }
    }

    struct Segment: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let sequence: Int
        let startedAt: Date
        let offsetMilliseconds: Int
        let text: String
        let sourceChunkID: UUID
        let speechSpanIDs: [UUID]

        private enum CodingKeys: String, CodingKey {
            case id
            case sequence
            case startedAt = "started_at"
            case offsetMilliseconds = "offset_milliseconds"
            case text
            case sourceChunkID = "source_chunk_id"
            case speechSpanIDs = "speech_span_ids"
            // Files written before the explicit ID mapping used the
            // encoder's acronym split. Keep them readable locally.
            case legacySpeechSpanIDs = "speech_span_i_ds"
        }

        init(
            id: UUID,
            sequence: Int,
            startedAt: Date,
            offsetMilliseconds: Int,
            text: String,
            sourceChunkID: UUID,
            speechSpanIDs: [UUID]
        ) {
            self.id = id
            self.sequence = sequence
            self.startedAt = startedAt
            self.offsetMilliseconds = offsetMilliseconds
            self.text = text
            self.sourceChunkID = sourceChunkID
            self.speechSpanIDs = speechSpanIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sequence = try container.decode(Int.self, forKey: .sequence)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            offsetMilliseconds = try container.decode(Int.self, forKey: .offsetMilliseconds)
            text = try container.decode(String.self, forKey: .text)
            sourceChunkID = try container.decode(UUID.self, forKey: .sourceChunkID)
            speechSpanIDs = try container.decodeIfPresent([UUID].self, forKey: .speechSpanIDs)
                ?? container.decodeIfPresent([UUID].self, forKey: .legacySpeechSpanIDs)
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sequence, forKey: .sequence)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(offsetMilliseconds, forKey: .offsetMilliseconds)
            try container.encode(text, forKey: .text)
            try container.encode(sourceChunkID, forKey: .sourceChunkID)
            try container.encode(speechSpanIDs, forKey: .speechSpanIDs)
        }
    }

    let schema: String
    let recordingID: UUID
    let kind: String
    var state: String
    var revision: Int
    let title: String?
    let tags: [String]
    let startedAt: Date
    let endedAt: Date?
    let timezone: String
    let language: String
    let audio: Audio
    let speechSpans: [String]
    let speakers: [String]
    let segments: [Segment]
    let gaps: [String]

    private enum CodingKeys: String, CodingKey {
        case schema
        case recordingID = "recording_id"
        case kind
        case state
        case revision
        case title
        case tags
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case timezone
        case language
        case audio
        case speechSpans = "speech_spans"
        case speakers
        case segments
        case gaps
    }

    init(
        recording: Recording,
        chunks: [AudioChunk],
        segmentTexts: [(chunkID: UUID, text: String)],
        timezone: String = TimeZone.current.identifier,
        state: RecordingState = .complete
    ) {
        self.schema = Self.schema
        recordingID = recording.id
        kind = recording.isMeeting ? "meeting" : "recording"
        // The document is written only by a successful transcription executor,
        // immediately before the Recording state machine advances to complete.
        self.state = state.rawValue
        revision = 1
        title = recording.title
        tags = []
        let normalizedStartedAt = TranscriptRFC3339DateCoding.normalizedToMilliseconds(recording.startedAt)
        startedAt = normalizedStartedAt
        endedAt = recording.endedAt.map(TranscriptRFC3339DateCoding.normalizedToMilliseconds)
        self.timezone = timezone
        language = "zh"
        audio = Audio(
            localOnly: true,
            availableOnThisDevice: chunks.contains { $0.state == .closed },
            retention: recording.retention.isPinned ? "keep" : "seven_days"
        )
        speechSpans = []
        speakers = []
        gaps = []

        let chunkStarts = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0.startSample) })
        segments = segmentTexts.enumerated().compactMap { offset, value in
            let normalized = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, let sample = chunkStarts[value.chunkID] else { return nil }
            let milliseconds = Int((Double(sample) / 16_000 * 1_000).rounded())
            return Segment(
                id: Self.stableSegmentID(recordingID: recording.id, sequence: offset + 1),
                sequence: offset + 1,
                startedAt: TranscriptRFC3339DateCoding.normalizedToMilliseconds(
                    normalizedStartedAt.addingTimeInterval(Double(milliseconds) / 1_000)
                ),
                offsetMilliseconds: milliseconds,
                text: normalized,
                sourceChunkID: value.chunkID,
                speechSpanIDs: []
            )
        }
    }

    /// Adds one independently completed chunk to the existing local document.
    /// Replacing source chunks makes retries idempotent, including the case
    /// where a VAD boundary requires two adjacent chunks to be reprocessed.
    func appending(
        recording: Recording,
        chunks: [AudioChunk],
        text: String,
        sourceChunkID: UUID,
        replacingSourceChunkIDs: [UUID] = []
    ) -> TranscriptDocumentV1 {
        let replaced = Set(replacingSourceChunkIDs + [sourceChunkID])
        let previous = segments
            .filter { !replaced.contains($0.sourceChunkID) }
            .map { ($0.sourceChunkID, $0.text) }
        return TranscriptDocumentV1(
            recording: recording,
            chunks: chunks,
            segmentTexts: previous + [(sourceChunkID, text)],
            timezone: timezone,
            state: .processing
        )
    }

    func updatingState(_ state: RecordingState) -> TranscriptDocumentV1 {
        var copy = self
        copy.state = state.rawValue
        copy.revision += 1
        return copy
    }

    /// A deterministic ID keeps a regenerated first revision linkable before
    /// user editing/revision support is added by the editing task.
    private static func stableSegmentID(recordingID: UUID, sequence: Int) -> UUID {
        let prefix = recordingID.uuidString.dropLast(8)
        return UUID(uuidString: "\(prefix)\(String(format: "%08X", sequence))") ?? UUID()
    }

    func requireContent() throws {
        guard !segments.isEmpty else { throw DocumentError.emptyTranscript }
    }
}

nonisolated enum TranscriptMarkdownRenderer {
    static func render(_ document: TranscriptDocumentV1) -> String {
        var lines = [
            "---",
            "schema: \(document.schema)",
            "recording_id: \(document.recordingID.uuidString)",
            "revision: \(document.revision)",
            "kind: \(document.kind)",
            "state: \(document.state)",
            "title: \(yamlString(document.title ?? ""))",
            "tags: \(yamlList(document.tags))",
            "started_at: \(timestamp(document.startedAt))",
            "ended_at: \(document.endedAt.map(timestamp) ?? "")",
            "timezone: \(yamlString(document.timezone))",
            "language: \(document.language)",
            "---",
            ""
        ]

        for segment in document.segments {
            let offset = offsetString(segment.offsetMilliseconds)
            lines.append("[\(segment.startedAt.formatted(date: .omitted, time: .standard)) · +\(offset)]")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func offsetString(_ milliseconds: Int) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, remainder)
    }

    private static func yamlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\\"", with: "\\\\\""))\""
    }

    private static func yamlList(_ values: [String]) -> String {
        "[\(values.map(yamlString).joined(separator: ", "))]"
    }
}

/// Stores per-recording canonical JSON and its deterministic Markdown view.
/// Both are local Documents assets; public iCloud publication belongs to #29.
actor TranscriptDocumentStore {
    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.appendingPathComponent("Transcripts", isDirectory: true)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Acronyms such as `recordingID` do not round-trip through
        // Foundation's automatic snake-case conversion (`recording_id`
        // becomes `recordingId`). Each wire key is declared explicitly above.
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.dateEncodingStrategy = .custom { value, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TranscriptRFC3339DateCoding.string(from: value))
        }
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = TranscriptRFC3339DateCoding.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 timestamp."
                )
            }
            return date
        }
    }

    func write(_ document: TranscriptDocumentV1) throws {
        try encoder.encode(document).write(to: jsonURL(for: document.recordingID), options: .atomic)
        let markdown = TranscriptMarkdownRenderer.render(document)
        guard let data = markdown.data(using: .utf8) else { return }
        try data.write(to: markdownURL(for: document.recordingID), options: .atomic)
    }

    func document(recordingID: UUID) throws -> TranscriptDocumentV1? {
        let url = jsonURL(for: recordingID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(TranscriptDocumentV1.self, from: Data(contentsOf: url))
    }

    func markdown(recordingID: UUID) throws -> String? {
        let url = markdownURL(for: recordingID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func jsonURL(for recordingID: UUID) -> URL {
        rootURL.appendingPathComponent("\(recordingID.uuidString).json")
    }

    func markdownURL(for recordingID: UUID) -> URL {
        rootURL.appendingPathComponent("\(recordingID.uuidString).md")
    }
}
