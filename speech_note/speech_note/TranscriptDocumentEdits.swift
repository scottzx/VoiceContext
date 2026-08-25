import Foundation

extension TranscriptDocumentV1.Segment {
    /// Text-only correction. Timing, samples, and source_ranges stay untouched.
    func withText(_ text: String, isManuallyEdited: Bool = true, editedAt: Date? = Date()) -> TranscriptDocumentV1.Segment {
        TranscriptDocumentV1.Segment(
            id: id,
            sequence: sequence,
            startedAt: startedAt,
            offsetMilliseconds: offsetMilliseconds,
            text: text,
            startSample: startSample,
            endSample: endSample,
            sourceRanges: sourceRanges,
            speechSpanIDs: speechSpanIDs,
            isManuallyEdited: isManuallyEdited,
            editedAt: editedAt
        )
    }
}

extension TranscriptDocumentV1 {
    /// User-facing metadata / segment text edits for FR-DOC-004.
    /// Always bumps revision exactly once. Never changes `state`, so an
    /// incomplete Recording cannot be mislabeled complete by saving edits.
    /// Does not alter sample windows or source_ranges (no waveform cutting).
    func applyingUserEdits(
        title: String?,
        tags: [String],
        segmentTexts: [UUID: String],
        speakers: [String]? = nil,
        speakerTurns: [SpeakerTurn]? = nil
    ) -> TranscriptDocumentV1 {
        var copy = self
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        copy.tags = Self.normalizedTags(tags)
        if !segmentTexts.isEmpty {
            copy.segments = segments.map { segment in
                guard let replacement = segmentTexts[segment.id] else { return segment }
                return segment.withText(replacement)
            }
        }
        if let speakers {
            copy.speakers = TemporarySpeakerLabeling.mergeRosters([], speakers)
        }
        if let speakerTurns {
            copy.speakerTurns = speakerTurns.sorted {
                if $0.startSample != $1.startSample {
                    return $0.startSample < $1.startSample
                }
                return ($0.speaker ?? "") < ($1.speaker ?? "")
            }
        }
        copy.revision += 1
        return copy
    }

    /// Rewrites roster / turn labels using temporaryLabel → displayName.
    /// Source ranges and segment text are preserved. Revision advances once.
    func applyingSpeakerLabelMapping(_ mapping: [String: String]) -> TranscriptDocumentV1 {
        guard !mapping.isEmpty else { return self }
        let normalized = mapping.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            result[key] = value
        }
        guard !normalized.isEmpty else { return self }

        func mapLabel(_ label: String?) -> String? {
            guard let label else { return nil }
            return normalized[label] ?? label
        }

        var copy = self
        // Preserve first-appearance roster order. Display names are not
        // temporary IDs, so TemporarySpeakerLabeling.mergeRosters would
        // push confirmed names after numbered labels.
        var seen = Set<String>()
        var remapped: [String] = []
        for label in speakers {
            let next = normalized[label] ?? label
            if seen.insert(next).inserted {
                remapped.append(next)
            }
        }
        copy.speakers = remapped
        copy.speakerTurns = speakerTurns.map { turn in
            SpeakerTurn(
                speaker: mapLabel(turn.speaker),
                attribution: turn.attribution,
                startSample: turn.startSample,
                endSample: turn.endSample,
                onlineTemporaryLabels: turn.onlineTemporaryLabels
            )
        }
        copy.revision += 1
        return copy
    }

    /// Display names that should appear in the public transcript after confirm
    /// or a meeting-local rename. Suspected matches stay out of the document.
    static func speakerDisplayMapping(
        from bindings: [MeetingSpeakerBinding]
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for binding in bindings {
            switch binding.state {
            case let .confirmed(_, displayName):
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    mapping[binding.temporaryLabel] = trimmed
                }
            case .unknown:
                if let alias = binding.meetingAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alias.isEmpty {
                    mapping[binding.temporaryLabel] = alias
                }
            case .suspected:
                break
            }
        }
        return mapping
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }
}
