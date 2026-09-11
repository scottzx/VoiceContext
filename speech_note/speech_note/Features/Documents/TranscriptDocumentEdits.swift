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
    /// Labels that can be assigned to an individual sentence. System fallback
    /// labels describe attribution state rather than a person, so never offer
    /// them as an assignment target.
    var editableSpeakerLabels: [String] {
        let candidates = speakers + speakerTurns.compactMap { turn in
            turn.attribution == .single ? turn.speaker : nil
        }
        var seen = Set<String>()
        return candidates.compactMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isEditableSpeakerLabel(trimmed), seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    /// The attribution turn that determines a sentence's displayed label.
    func speakerTurn(for segment: Segment) -> SpeakerTurn? {
        let midpoint = (segment.startSample + segment.endSample) / 2
        return speakerTurns.first(where: {
            $0.startSample <= midpoint && midpoint < max($0.endSample, $0.startSample + 1)
        })
    }

    /// Reassigns one single-speaker or unknown sentence without relabeling the
    /// rest of its surrounding turn. The existing turn is split around the
    /// sentence so neighbouring sentences retain their original attribution.
    func applyingSpeakerAssignment(
        segmentID: UUID,
        speaker: String
    ) -> TranscriptDocumentV1 {
        let label = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEditableSpeakerLabel(label),
              editableSpeakerLabels.contains(label),
              let segment = segments.first(where: { $0.id == segmentID }),
              let turnIndex = speakerTurns.firstIndex(where: { turn in
                  let midpoint = (segment.startSample + segment.endSample) / 2
                  return (turn.attribution == .single || turn.attribution == .unknown) &&
                      turn.startSample <= midpoint &&
                      midpoint < max(turn.endSample, turn.startSample + 1)
              }) else {
            return self
        }

        let turn = speakerTurns[turnIndex]
        guard turn.speaker != label else { return self }

        let assignmentStart = max(segment.startSample, turn.startSample)
        let assignmentEnd = min(segment.endSample, turn.endSample)
        guard assignmentStart < assignmentEnd else { return self }

        var replacements: [SpeakerTurn] = []
        if turn.startSample < assignmentStart {
            replacements.append(SpeakerTurn(
                speaker: turn.speaker,
                attribution: turn.attribution,
                startSample: turn.startSample,
                endSample: assignmentStart,
                onlineTemporaryLabels: turn.onlineTemporaryLabels
            ))
        }
        replacements.append(SpeakerTurn(
            speaker: label,
            attribution: .single,
            startSample: assignmentStart,
            endSample: assignmentEnd,
            onlineTemporaryLabels: turn.onlineTemporaryLabels
        ))
        if assignmentEnd < turn.endSample {
            replacements.append(SpeakerTurn(
                speaker: turn.speaker,
                attribution: turn.attribution,
                startSample: assignmentEnd,
                endSample: turn.endSample,
                onlineTemporaryLabels: turn.onlineTemporaryLabels
            ))
        }

        var copy = self
        copy.speakerTurns.replaceSubrange(turnIndex...turnIndex, with: replacements)
        copy.revision += 1
        return copy
    }

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

    private static func isEditableSpeakerLabel(_ label: String) -> Bool {
        !label.isEmpty &&
            label != "说话人不确定" &&
            label != "多人对话" &&
            label != "多人会话"
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
