import Foundation

nonisolated enum TranscriptRFC3339DateCoding {
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

    /// Exact provenance for one contiguous portion of a segment. Absolute
    /// samples share the Recording's 16 kHz clock. `source_kind` distinguishes
    /// microphone AudioChunk ranges from Files-imported assets.
    struct SourceRange: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case audioChunk = "audio_chunk"
            case importedAsset = "imported_asset"
        }

        let sourceKind: Kind
        let sourceID: UUID
        let startSample: Int64
        let endSample: Int64

        private enum CodingKeys: String, CodingKey {
            case sourceKind = "source_kind"
            case sourceID = "source_id"
            case startSample = "start_sample"
            case endSample = "end_sample"
            // Older carry / analysis payloads used chunk_id. Accept it when
            // normalizing a single legacy value into one SourceRange.
            case legacyChunkID = "chunk_id"
        }

        init(
            sourceKind: Kind = .audioChunk,
            sourceID: UUID,
            startSample: Int64,
            endSample: Int64
        ) {
            self.sourceKind = sourceKind
            self.sourceID = sourceID
            self.startSample = startSample
            self.endSample = endSample
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceKind = try container.decodeIfPresent(Kind.self, forKey: .sourceKind) ?? .audioChunk
            if let id = try container.decodeIfPresent(UUID.self, forKey: .sourceID) {
                sourceID = id
            } else {
                sourceID = try container.decode(UUID.self, forKey: .legacyChunkID)
            }
            startSample = try container.decode(Int64.self, forKey: .startSample)
            endSample = try container.decode(Int64.self, forKey: .endSample)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sourceKind, forKey: .sourceKind)
            try container.encode(sourceID, forKey: .sourceID)
            try container.encode(startSample, forKey: .startSample)
            try container.encode(endSample, forKey: .endSample)
        }

        var sampleCount: Int64 { max(0, endSample - startSample) }
    }

    /// One completed transcript unit. Absolute `[startSample, endSample)` and
    /// ordered `sourceRanges` are the authoritative provenance; a dual-written
    /// `source_chunk_id` remains for rollback readers of transcript@1.
    struct Segment: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let sequence: Int
        let startedAt: Date
        let offsetMilliseconds: Int
        let text: String
        let startSample: Int64
        let endSample: Int64
        let sourceRanges: [SourceRange]
        let speechSpanIDs: [UUID]
        let isManuallyEdited: Bool
        let editedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case sequence
            case startedAt = "started_at"
            case offsetMilliseconds = "offset_milliseconds"
            case text
            case startSample = "start_sample"
            case endSample = "end_sample"
            case sourceRanges = "source_ranges"
            case sourceChunkID = "source_chunk_id"
            case speechSpanIDs = "speech_span_ids"
            case isManuallyEdited = "is_manually_edited"
            case editedAt = "edited_at"
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
            startSample: Int64,
            endSample: Int64,
            sourceRanges: [SourceRange],
            speechSpanIDs: [UUID],
            isManuallyEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            precondition(!sourceRanges.isEmpty, "segments require at least one source range")
            self.id = id
            self.sequence = sequence
            self.startedAt = startedAt
            self.offsetMilliseconds = offsetMilliseconds
            self.text = text
            self.startSample = startSample
            self.endSample = endSample
            self.sourceRanges = sourceRanges
            self.speechSpanIDs = speechSpanIDs
            self.isManuallyEdited = isManuallyEdited
            self.editedAt = editedAt
        }

        /// Compatibility initializer used by existing single-chunk call sites.
        init(
            id: UUID,
            sequence: Int,
            startedAt: Date,
            offsetMilliseconds: Int,
            text: String,
            sourceChunkID: UUID,
            speechSpanIDs: [UUID],
            startSample: Int64? = nil,
            endSample: Int64? = nil
        ) {
            let start = startSample ?? Int64(offsetMilliseconds) * 16
            let end = endSample ?? start
            self.init(
                id: id,
                sequence: sequence,
                startedAt: startedAt,
                offsetMilliseconds: offsetMilliseconds,
                text: text,
                startSample: start,
                endSample: end,
                sourceRanges: [
                    SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: sourceChunkID,
                        startSample: start,
                        endSample: end
                    )
                ],
                speechSpanIDs: speechSpanIDs
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sequence = try container.decode(Int.self, forKey: .sequence)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            offsetMilliseconds = try container.decode(Int.self, forKey: .offsetMilliseconds)
            text = try container.decode(String.self, forKey: .text)
            speechSpanIDs = try container.decodeIfPresent([UUID].self, forKey: .speechSpanIDs)
                ?? container.decodeIfPresent([UUID].self, forKey: .legacySpeechSpanIDs)
                ?? []

            let decodedRanges = try container.decodeIfPresent([SourceRange].self, forKey: .sourceRanges) ?? []
            let legacyChunkID = try container.decodeIfPresent(UUID.self, forKey: .sourceChunkID)
            let decodedStart = try container.decodeIfPresent(Int64.self, forKey: .startSample)
            let decodedEnd = try container.decodeIfPresent(Int64.self, forKey: .endSample)

            if !decodedRanges.isEmpty {
                sourceRanges = Self.normalized(ranges: decodedRanges)
            } else if let legacyChunkID {
                // FR-DOC-002 migration: a bare source_chunk_id becomes one range.
                let start = decodedStart ?? Int64(offsetMilliseconds) * 16
                let end = decodedEnd ?? start
                sourceRanges = [
                    SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: legacyChunkID,
                        startSample: start,
                        endSample: end
                    )
                ]
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sourceRanges,
                    in: container,
                    debugDescription: "Segment requires source_ranges or legacy source_chunk_id."
                )
            }

            startSample = decodedStart ?? sourceRanges.first!.startSample
            endSample = decodedEnd ?? sourceRanges.last!.endSample
            isManuallyEdited = try container.decodeIfPresent(Bool.self, forKey: .isManuallyEdited) ?? false
            editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(sequence, forKey: .sequence)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(offsetMilliseconds, forKey: .offsetMilliseconds)
            try container.encode(text, forKey: .text)
            try container.encode(startSample, forKey: .startSample)
            try container.encode(endSample, forKey: .endSample)
            try container.encode(sourceRanges, forKey: .sourceRanges)
            try container.encode(isManuallyEdited, forKey: .isManuallyEdited)
            try container.encodeIfPresent(editedAt, forKey: .editedAt)
            // Dual-write the primary audio_chunk id so transcript@1 rollback
            // readers that still require source_chunk_id keep working.
            if let primary = primarySourceChunkID {
                try container.encode(primary, forKey: .sourceChunkID)
            }
            try container.encode(speechSpanIDs, forKey: .speechSpanIDs)
        }

        /// Primary microphone chunk for legacy APIs and rollback dual-write.
        var sourceChunkID: UUID {
            primarySourceChunkID ?? sourceRanges[0].sourceID
        }

        var primarySourceChunkID: UUID? {
            sourceRanges.first(where: { $0.sourceKind == .audioChunk })?.sourceID
        }

        var sourceIDs: [UUID] {
            sourceRanges.map(\.sourceID)
        }

        /// Global timeline position used by playback seek and error locate.
        var playbackStartTime: TimeInterval {
            Double(startSample) / 16_000
        }

        var playbackEndTime: TimeInterval {
            Double(endSample) / 16_000
        }

        func references(sourceID: UUID) -> Bool {
            sourceRanges.contains { $0.sourceID == sourceID }
        }

        private static func normalized(ranges: [SourceRange]) -> [SourceRange] {
            ranges.sorted { lhs, rhs in
                if lhs.startSample != rhs.startSample {
                    return lhs.startSample < rhs.startSample
                }
                return lhs.sourceID.uuidString < rhs.sourceID.uuidString
            }
        }
    }

    /// Input used when incrementally committing one completed utterance/segment.
    struct SegmentDraft: Equatable, Sendable {
        let text: String
        let startSample: Int64
        let endSample: Int64
        let sourceRanges: [SourceRange]
        let speechSpanIDs: [UUID]
        let isManuallyEdited: Bool
        let editedAt: Date?

        init(
            text: String,
            startSample: Int64,
            endSample: Int64,
            sourceRanges: [SourceRange],
            speechSpanIDs: [UUID] = [],
            isManuallyEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            self.text = text
            self.startSample = startSample
            self.endSample = endSample
            self.sourceRanges = sourceRanges
            self.speechSpanIDs = speechSpanIDs
            self.isManuallyEdited = isManuallyEdited
            self.editedAt = editedAt
        }

        /// Whole-chunk draft used by the current per-chunk transcription path.
        init(
            text: String,
            chunk: AudioChunk,
            speechSpanIDs: [UUID] = [],
            isManuallyEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            self.init(
                text: text,
                startSample: chunk.startSample,
                endSample: chunk.endSample,
                sourceRanges: [
                    SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: chunk.id,
                        startSample: chunk.startSample,
                        endSample: chunk.endSample
                    )
                ],
                speechSpanIDs: speechSpanIDs,
                isManuallyEdited: isManuallyEdited,
                editedAt: editedAt
            )
        }

        /// Cross-chunk draft with ordered exact ranges.
        init(
            text: String,
            sourceRanges: [SourceRange],
            speechSpanIDs: [UUID] = [],
            isManuallyEdited: Bool = false,
            editedAt: Date? = nil
        ) {
            let ordered = sourceRanges.sorted { lhs, rhs in
                if lhs.startSample != rhs.startSample {
                    return lhs.startSample < rhs.startSample
                }
                return lhs.sourceID.uuidString < rhs.sourceID.uuidString
            }
            self.init(
                text: text,
                startSample: ordered.first?.startSample ?? 0,
                endSample: ordered.last?.endSample ?? 0,
                sourceRanges: ordered,
                speechSpanIDs: speechSpanIDs,
                isManuallyEdited: isManuallyEdited,
                editedAt: editedAt
            )
        }
    }

    let schema: String
    let recordingID: UUID
    let kind: String
    var state: String
    var revision: Int
    var title: String?
    var tags: [String]
    let startedAt: Date
    let endedAt: Date?
    let timezone: String
    let language: String
    /// SenseVoice language mode used when this transcript was produced.
    let languageMode: TranscriptionLanguageMode
    var audio: Audio
    let speechSpans: [String]
    /// Stable meeting-local roster after offline recluster when available;
    /// otherwise the online temporary labels collected during capture.
    var speakers: [String]
    /// Contiguous speaker turns from FR-SPK-004 offline recluster. Absent in
    /// older documents and while recording is still using temporary labels.
    var speakerTurns: [SpeakerTurn]
    var segments: [Segment]
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
        case languageMode = "language_mode"
        case audio
        case speechSpans = "speech_spans"
        case speakers
        case speakerTurns = "speaker_turns"
        case segments
        case gaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(String.self, forKey: .state)
        revision = try container.decode(Int.self, forKey: .revision)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        timezone = try container.decode(String.self, forKey: .timezone)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        languageMode = try container.decodeIfPresent(TranscriptionLanguageMode.self, forKey: .languageMode)
            ?? .zhEnBilingual
        audio = try container.decode(Audio.self, forKey: .audio)
        speechSpans = try container.decodeIfPresent([String].self, forKey: .speechSpans) ?? []
        speakers = try container.decodeIfPresent([String].self, forKey: .speakers) ?? []
        speakerTurns = try container.decodeIfPresent([SpeakerTurn].self, forKey: .speakerTurns) ?? []
        segments = try container.decode([Segment].self, forKey: .segments)
        gaps = try container.decodeIfPresent([String].self, forKey: .gaps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(recordingID, forKey: .recordingID)
        try container.encode(kind, forKey: .kind)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(tags, forKey: .tags)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(language, forKey: .language)
        try container.encode(languageMode, forKey: .languageMode)
        try container.encode(audio, forKey: .audio)
        try container.encode(speechSpans, forKey: .speechSpans)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(speakerTurns, forKey: .speakerTurns)
        try container.encode(segments, forKey: .segments)
        try container.encode(gaps, forKey: .gaps)
    }

    init(
        recording: Recording,
        chunks: [AudioChunk],
        segmentTexts: [(chunkID: UUID, text: String)],
        timezone: String = TimeZone.current.identifier,
        language: String = "",
        state: RecordingState = .complete,
        revision: Int = 1,
        speakers: [String] = []
    ) {
        self.schema = Self.schema
        recordingID = recording.id
        kind = recording.isMeeting ? "meeting" : "recording"
        // The document is written only by a successful transcription executor,
        // immediately before the Recording state machine advances to complete.
        self.state = state.rawValue
        self.revision = max(1, revision)
        title = recording.title
        tags = []
        let normalizedStartedAt = TranscriptRFC3339DateCoding.normalizedToMilliseconds(recording.startedAt)
        startedAt = normalizedStartedAt
        endedAt = recording.endedAt.map(TranscriptRFC3339DateCoding.normalizedToMilliseconds)
        self.timezone = timezone
        self.language = language
        self.languageMode = recording.languageMode
        audio = Audio(
            localOnly: true,
            availableOnThisDevice: chunks.contains { $0.state == .closed },
            retention: recording.retention.isPinned ? "keep" : "seven_days"
        )
        speechSpans = []
        // Additive FR-SPK-003 online temporary roster. Unknown is omitted.
        self.speakers = TemporarySpeakerLabeling.mergeRosters([], speakers)
        self.speakerTurns = []
        gaps = []

        let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let drafts = segmentTexts.compactMap { value -> SegmentDraft? in
            let normalized = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, let chunk = chunkByID[value.chunkID] else { return nil }
            return SegmentDraft(text: normalized, chunk: chunk)
        }
        segments = Self.makeSegments(
            recordingID: recording.id,
            recordingStartedAt: normalizedStartedAt,
            drafts: drafts
        )
    }

    init(
        recording: Recording,
        chunks: [AudioChunk],
        segmentDrafts: [SegmentDraft],
        timezone: String = TimeZone.current.identifier,
        language: String = "",
        state: RecordingState = .complete,
        revision: Int = 1,
        speakers: [String] = []
    ) {
        self.schema = Self.schema
        recordingID = recording.id
        kind = recording.isMeeting ? "meeting" : "recording"
        self.state = state.rawValue
        self.revision = max(1, revision)
        title = recording.title
        tags = []
        let normalizedStartedAt = TranscriptRFC3339DateCoding.normalizedToMilliseconds(recording.startedAt)
        startedAt = normalizedStartedAt
        endedAt = recording.endedAt.map(TranscriptRFC3339DateCoding.normalizedToMilliseconds)
        self.timezone = timezone
        self.language = language
        self.languageMode = recording.languageMode
        audio = Audio(
            localOnly: true,
            availableOnThisDevice: chunks.contains { $0.state == .closed && $0.audioRemovedAt == nil },
            retention: recording.retention.isPinned ? "keep" : "seven_days"
        )
        speechSpans = []
        self.speakers = TemporarySpeakerLabeling.mergeRosters([], speakers)
        self.speakerTurns = []
        gaps = []
        segments = Self.makeSegments(
            recordingID: recording.id,
            recordingStartedAt: normalizedStartedAt,
            drafts: segmentDrafts
        )
    }

    init(
        recording: Recording,
        audioAvailableOnThisDevice: Bool,
        segmentDrafts: [SegmentDraft],
        timezone: String = TimeZone.current.identifier,
        language: String = "",
        state: RecordingState = .complete,
        revision: Int = 1,
        speakers: [String] = []
    ) {
        self.schema = Self.schema
        recordingID = recording.id
        kind = recording.isMeeting ? "meeting" : "recording"
        self.state = state.rawValue
        self.revision = max(1, revision)
        title = recording.title
        tags = []
        let normalizedStartedAt = TranscriptRFC3339DateCoding.normalizedToMilliseconds(recording.startedAt)
        startedAt = normalizedStartedAt
        endedAt = recording.endedAt.map(TranscriptRFC3339DateCoding.normalizedToMilliseconds)
        self.timezone = timezone
        self.language = language
        self.languageMode = recording.languageMode
        audio = Audio(
            localOnly: true,
            availableOnThisDevice: audioAvailableOnThisDevice,
            retention: recording.retention.isPinned ? "keep" : "seven_days"
        )
        speechSpans = []
        self.speakers = TemporarySpeakerLabeling.mergeRosters([], speakers)
        self.speakerTurns = []
        gaps = []
        segments = Self.makeSegments(
            recordingID: recording.id,
            recordingStartedAt: normalizedStartedAt,
            drafts: segmentDrafts
        )
    }

    /// Adds one independently completed segment. Retries are idempotent by
    /// absolute sample identity and by overlapping source IDs, so reprocessing
    /// a cross-chunk utterance replaces the prior segment instead of appending
    /// a duplicate.
    func appending(
        recording: Recording,
        chunks: [AudioChunk],
        draft: SegmentDraft,
        replacingSourceIDs: [UUID] = [],
        speakers: [String] = []
    ) -> TranscriptDocumentV1 {
        let previousDrafts = Self.retainedDrafts(
            existing: segments,
            draft: draft,
            replacingSourceIDs: replacingSourceIDs
        )
        return TranscriptDocumentV1(
            recording: recording,
            chunks: chunks,
            segmentDrafts: previousDrafts + [draft],
            timezone: timezone,
            language: language,
            state: .processing,
            revision: revision + 1,
            speakers: TemporarySpeakerLabeling.mergeRosters(self.speakers, speakers)
        )
    }

    func appending(
        recording: Recording,
        chunks: [AudioChunk],
        drafts: [SegmentDraft],
        replacingSourceIDs: [UUID] = [],
        speakers: [String] = []
    ) -> TranscriptDocumentV1 {
        guard !drafts.isEmpty else { return self }
        let replacedSources = Set(replacingSourceIDs)
        var retained = segments.compactMap { segment -> SegmentDraft? in
            if segment.isManuallyEdited {
                return SegmentDraft(
                    text: segment.text,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    sourceRanges: segment.sourceRanges,
                    speechSpanIDs: segment.speechSpanIDs,
                    isManuallyEdited: true,
                    editedAt: segment.editedAt
                )
            }
            if !replacedSources.isEmpty {
                let matchesReplacedSource = segment.sourceRanges.contains { replacedSources.contains($0.sourceID) }
                if matchesReplacedSource { return nil }
            }
            let isOverlapped = drafts.contains { d in
                let maxStart = max(segment.startSample, d.startSample)
                let minEnd = min(segment.endSample, d.endSample)
                return maxStart < minEnd
            }
            if isOverlapped { return nil }
            return SegmentDraft(
                text: segment.text,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sourceRanges: segment.sourceRanges,
                speechSpanIDs: segment.speechSpanIDs,
                isManuallyEdited: false
            )
        }
        return TranscriptDocumentV1(
            recording: recording,
            chunks: chunks,
            segmentDrafts: retained + drafts,
            timezone: timezone,
            language: language,
            state: .processing,
            revision: revision + 1,
            speakers: TemporarySpeakerLabeling.mergeRosters(self.speakers, speakers)
        )
    }

    /// Import path: one private asset, many logical ranges. Replacement uses
    /// sample overlap for `imported_asset` so the shared asset ID cannot wipe
    /// sibling ranges.
    func appendingImported(
        recording: Recording,
        audioAvailableOnThisDevice: Bool,
        draft: SegmentDraft,
        speakers: [String] = []
    ) -> TranscriptDocumentV1 {
        let previousDrafts = Self.retainedDrafts(
            existing: segments,
            draft: draft,
            replacingSourceIDs: []
        )
        return TranscriptDocumentV1(
            recording: recording,
            audioAvailableOnThisDevice: audioAvailableOnThisDevice,
            segmentDrafts: previousDrafts + [draft],
            timezone: timezone,
            language: language,
            state: .processing,
            revision: revision + 1,
            speakers: TemporarySpeakerLabeling.mergeRosters(self.speakers, speakers)
        )
    }

    func appendingImported(
        recording: Recording,
        audioAvailableOnThisDevice: Bool,
        drafts: [SegmentDraft],
        speakers: [String] = []
    ) -> TranscriptDocumentV1 {
        guard !drafts.isEmpty else { return self }
        var retained = segments.compactMap { segment -> SegmentDraft? in
            if segment.isManuallyEdited {
                return SegmentDraft(
                    text: segment.text,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    sourceRanges: segment.sourceRanges,
                    speechSpanIDs: segment.speechSpanIDs,
                    isManuallyEdited: true,
                    editedAt: segment.editedAt
                )
            }
            let isOverlapped = drafts.contains { d in
                let maxStart = max(segment.startSample, d.startSample)
                let minEnd = min(segment.endSample, d.endSample)
                return maxStart < minEnd
            }
            if isOverlapped { return nil }
            return SegmentDraft(
                text: segment.text,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sourceRanges: segment.sourceRanges,
                speechSpanIDs: segment.speechSpanIDs,
                isManuallyEdited: false
            )
        }
        return TranscriptDocumentV1(
            recording: recording,
            audioAvailableOnThisDevice: audioAvailableOnThisDevice,
            segmentDrafts: retained + drafts,
            timezone: timezone,
            language: language,
            state: .processing,
            revision: revision + 1,
            speakers: TemporarySpeakerLabeling.mergeRosters(self.speakers, speakers)
        )
    }

    private static func retainedDrafts(
        existing: [Segment],
        draft: SegmentDraft,
        replacingSourceIDs: [UUID]
    ) -> [SegmentDraft] {
        let replacedSources = Set(replacingSourceIDs)
        return existing.compactMap { segment -> SegmentDraft? in
            if segment.isManuallyEdited {
                // User manually edited / confirmed this segment: NEVER overwrite with auto ASR
                return SegmentDraft(
                    text: segment.text,
                    startSample: segment.startSample,
                    endSample: segment.endSample,
                    sourceRanges: segment.sourceRanges,
                    speechSpanIDs: segment.speechSpanIDs,
                    isManuallyEdited: true,
                    editedAt: segment.editedAt
                )
            }
            let overlapsIdentity =
                segment.startSample == draft.startSample && segment.endSample == draft.endSample
            let overlapsSource = segment.sourceRanges.contains { existingRange in
                draft.sourceRanges.contains { draftRange in
                    guard existingRange.sourceKind == draftRange.sourceKind,
                          existingRange.sourceID == draftRange.sourceID
                    else { return false }
                    if existingRange.sourceKind == .importedAsset {
                        return existingRange.startSample < draftRange.endSample
                            && draftRange.startSample < existingRange.endSample
                    }
                    return replacedSources.contains(existingRange.sourceID)
                        || true
                }
            }
            if overlapsIdentity || overlapsSource { return nil }
            return SegmentDraft(
                text: segment.text,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sourceRanges: segment.sourceRanges,
                speechSpanIDs: segment.speechSpanIDs,
                isManuallyEdited: segment.isManuallyEdited,
                editedAt: segment.editedAt
            )
        }
    }

    /// Compatibility wrapper for the pre-source_ranges per-chunk commit path.
    func appending(
        recording: Recording,
        chunks: [AudioChunk],
        text: String,
        sourceChunkID: UUID,
        replacingSourceChunkIDs: [UUID] = [],
        speakers: [String] = []
    ) -> TranscriptDocumentV1 {
        let chunk = chunks.first(where: { $0.id == sourceChunkID })
        let draft: SegmentDraft
        if let chunk {
            draft = SegmentDraft(text: text, chunk: chunk)
        } else {
            let start = segments.first(where: { $0.sourceChunkID == sourceChunkID })?.startSample ?? 0
            draft = SegmentDraft(
                text: text,
                startSample: start,
                endSample: start,
                sourceRanges: [
                    SourceRange(
                        sourceKind: .audioChunk,
                        sourceID: sourceChunkID,
                        startSample: start,
                        endSample: start
                    )
                ]
            )
        }
        return appending(
            recording: recording,
            chunks: chunks,
            draft: draft,
            replacingSourceIDs: replacingSourceChunkIDs,
            speakers: speakers
        )
    }

    func updatingState(_ state: RecordingState) -> TranscriptDocumentV1 {
        var copy = self
        copy.state = state.rawValue
        copy.revision += 1
        return copy
    }

    /// Replaces the online temporary roster with stable offline speakers/turns.
    /// Revision advances so public mirrors and Skill inputs observe the change.
    func applyingOfflineRecluster(
        speakers: [String],
        speakerTurns: [SpeakerTurn]
    ) -> TranscriptDocumentV1 {
        var copy = self
        copy.speakers = TemporarySpeakerLabeling.mergeRosters([], speakers)
        copy.speakerTurns = speakerTurns.sorted {
            if $0.startSample != $1.startSample {
                return $0.startSample < $1.startSample
            }
            return ($0.speaker ?? "") < ($1.speaker ?? "")
        }
        copy.revision += 1
        return copy
    }

    /// Stable identity for retries: recording + absolute sample window. Sequence
    /// remains a derived display/order field and may renumber after rebuilds.
    private static func stableSegmentID(
        recordingID: UUID,
        startSample: Int64,
        endSample: Int64
    ) -> UUID {
        let material =
            "voice-context.segment.v1|\(recordingID.uuidString.lowercased())|\(startSample)|\(endSample)"
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a 64-bit offset
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        var bytes = recordingID.uuid
        // Mix the hash into the low 8 bytes while preserving UUID variant bits.
        bytes.8 = UInt8(truncatingIfNeeded: hash >> 56)
        bytes.9 = UInt8(truncatingIfNeeded: hash >> 48)
        bytes.10 = UInt8(truncatingIfNeeded: hash >> 40)
        bytes.11 = UInt8(truncatingIfNeeded: hash >> 32)
        bytes.12 = UInt8(truncatingIfNeeded: hash >> 24)
        bytes.13 = UInt8(truncatingIfNeeded: hash >> 16)
        bytes.14 = UInt8(truncatingIfNeeded: hash >> 8)
        bytes.15 = UInt8(truncatingIfNeeded: hash)
        bytes.6 = (bytes.6 & 0x0F) | 0x50
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }

    private static func makeSegments(
        recordingID: UUID,
        recordingStartedAt: Date,
        drafts: [SegmentDraft]
    ) -> [Segment] {
        // Sequence is derived from absolute audio time, never submission order.
        let ordered = drafts.compactMap { draft -> SegmentDraft? in
            let normalized = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !draft.sourceRanges.isEmpty else { return nil }
            return SegmentDraft(
                text: normalized,
                startSample: draft.startSample,
                endSample: draft.endSample,
                sourceRanges: draft.sourceRanges,
                speechSpanIDs: draft.speechSpanIDs,
                isManuallyEdited: draft.isManuallyEdited,
                editedAt: draft.editedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.startSample != rhs.startSample {
                return lhs.startSample < rhs.startSample
            }
            if lhs.endSample != rhs.endSample {
                return lhs.endSample < rhs.endSample
            }
            return (lhs.sourceRanges.first?.sourceID.uuidString ?? "")
                < (rhs.sourceRanges.first?.sourceID.uuidString ?? "")
        }

        return ordered.enumerated().map { offset, draft in
            let sequence = offset + 1
            let milliseconds = Int((Double(draft.startSample) / 16_000 * 1_000).rounded())
            return Segment(
                id: stableSegmentID(
                    recordingID: recordingID,
                    startSample: draft.startSample,
                    endSample: draft.endSample
                ),
                sequence: sequence,
                startedAt: TranscriptRFC3339DateCoding.normalizedToMilliseconds(
                    recordingStartedAt.addingTimeInterval(Double(milliseconds) / 1_000)
                ),
                offsetMilliseconds: milliseconds,
                text: draft.text,
                startSample: draft.startSample,
                endSample: draft.endSample,
                sourceRanges: draft.sourceRanges,
                speechSpanIDs: draft.speechSpanIDs,
                isManuallyEdited: draft.isManuallyEdited,
                editedAt: draft.editedAt
            )
        }
    }

    func requireContent() throws {
        guard !segments.isEmpty else { throw DocumentError.emptyTranscript }
    }

    // MARK: - Multi-range consumers (timeline / export / delete / errors)

    func segment(atPlaybackTime time: TimeInterval) -> Segment? {
        let sample = Int64((time * 16_000).rounded(.down))
        return segments.last { $0.startSample <= sample && sample < max($0.endSample, $0.startSample + 1) }
            ?? segments.last { $0.startSample <= sample }
    }

    func segmentsReferencing(sourceID: UUID) -> [Segment] {
        segments.filter { $0.references(sourceID: sourceID) }
    }

    /// Ordered unique source IDs for export / share packaging.
    func exportSourceIDs() -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for segment in segments {
            for range in segment.sourceRanges {
                if seen.insert(range.sourceID).inserted {
                    ordered.append(range.sourceID)
                }
            }
        }
        return ordered
    }

    /// Locate the segment tied to a failed job's chunk/source identity.
    func segmentForErrorLocation(sourceID: UUID) -> Segment? {
        segmentsReferencing(sourceID: sourceID).first
    }

    /// Audio deletion keeps transcript text but updates availability when none
    /// of the referenced sources remain on device.
    func updatingAudioAvailability(availableSourceIDs: Set<UUID>) -> TranscriptDocumentV1 {
        let anySourceAvailable = segments.contains { segment in
            segment.sourceIDs.contains { availableSourceIDs.contains($0) }
        }
        var copy = self
        copy.audio = Audio(
            localOnly: audio.localOnly,
            availableOnThisDevice: anySourceAvailable,
            retention: audio.retention
        )
        copy.revision += 1
        return copy
    }

    /// Rollback view: same document with only legacy source_chunk_id fields
    /// materialised for readers that do not understand source_ranges yet.
    func legacyRollbackSegments() -> [(id: UUID, sourceChunkID: UUID, text: String, offsetMilliseconds: Int)] {
        segments.map {
            ($0.id, $0.sourceChunkID, $0.text, $0.offsetMilliseconds)
        }
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
            "language_mode: \(document.languageMode.rawValue)",
            "---",
            ""
        ]

        for segment in document.segments {
            let offset = offsetString(segment.offsetMilliseconds)
            lines.append("[\(segment.startedAt.standardTimeWithSecondsString) · +\(offset)]")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ value: Date) -> String {
        TranscriptRFC3339DateCoding.string(from: value)
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
    /// Offline full-text index over titles + transcript plain text (FR-ADD-SRCH-*).
    let searchIndex: TranscriptSearchIndex
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.appendingPathComponent("Transcripts", isDirectory: true)
        self.searchIndex = try TranscriptSearchIndex(rootURL: rootURL)
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

    enum StoreError: LocalizedError, Equatable {
        case markdownEncodingFailed

        var errorDescription: String? {
            switch self {
            case .markdownEncodingFailed:
                "无法将 Markdown 文稿编码为 UTF-8。"
            }
        }
    }

    /// Writes JSON and Markdown as a prepared pair. Both payloads are fully
    /// encoded before any destination is mutated, and each file is replaced
    /// with `Data.WritingOptions.atomic` so an interrupt cannot leave a
    /// truncated final JSON/Markdown file. Leftover `*.writing` staging names
    /// from a previous crash are removed first.
    func write(_ document: TranscriptDocumentV1) throws {
        let jsonData = try encoder.encode(document)
        let markdown = TranscriptMarkdownRenderer.render(document)
        guard let markdownData = markdown.data(using: .utf8) else {
            throw StoreError.markdownEncodingFailed
        }

        let jsonDestination = jsonURL(for: document.recordingID)
        let markdownDestination = markdownURL(for: document.recordingID)
        removeIfPresent(stagingURL(for: jsonDestination))
        removeIfPresent(stagingURL(for: markdownDestination))

        try jsonData.write(to: jsonDestination, options: .atomic)
        try markdownData.write(to: markdownDestination, options: .atomic)
        // Keep the local search index in sync after durable JSON/Markdown land.
        try searchIndex.upsert(document: document)
    }

    /// Search titles + transcript plain text (+ speakers/tags). Empty query yields [].
    func search(query: String) throws -> [TranscriptSearchHit] {
        try searchIndex.search(query: query)
    }

    /// Repair the offline index from recordings and on-disk transcripts.
    func reconcileSearchIndex(recordings: [Recording]) throws {
        var keep = Set<UUID>()
        for recording in recordings {
            keep.insert(recording.id)
            if let document = try document(recordingID: recording.id) {
                try searchIndex.upsert(document: document)
            } else {
                try searchIndex.upsertTitleOnly(
                    recordingID: recording.id,
                    title: recording.title,
                    updatedAt: recording.updatedAt
                )
            }
        }
        try searchIndex.removeAll(except: keep)
    }

    private func stagingURL(for destination: URL) -> URL {
        destination.appendingPathExtension("writing")
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func delete(recordingID: UUID) throws {
        removeIfPresent(jsonURL(for: recordingID))
        removeIfPresent(markdownURL(for: recordingID))
        try? searchIndex.remove(recordingID: recordingID)
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
