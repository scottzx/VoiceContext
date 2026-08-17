import Foundation

/// Confirm / deny / rename rules for FR-SPK-005/006.
/// - Matching alone never mutates the long-term archive.
/// - Deny never writes embeddings or creates identities.
/// - Confirm appends only quality-normalized embeddings.
nonisolated enum SpeakerIdentityConfirmation {
    nonisolated enum ActionError: LocalizedError, Equatable, Sendable {
        case unknownTemporaryLabel
        case emptyDisplayName
        case noQualityEmbeddings
        case missingArchiveIdentity

        var errorDescription: String? {
            switch self {
            case .unknownTemporaryLabel:
                "找不到该临时说话人标签。"
            case .emptyDisplayName:
                "显示名称不能为空。"
            case .noQualityEmbeddings:
                "还没有可用于确认的声纹样本。可先用「重命名」做本场标记，或等离线聚类完成后再确认到声纹档案。"
            case .missingArchiveIdentity:
                "声纹档案中找不到对应身份，请重试或改为新建确认。"
            }
        }
    }

    /// Build meeting bindings from offline labels + observations, then apply
    /// suspected matches. Does not mutate `archive`.
    static func makeBindings(
        speakers: [String],
        labels: [String?],
        observations: [OfflineSpeakerObservation],
        archive: VoiceprintArchive
    ) -> [MeetingSpeakerBinding] {
        var embeddingsByLabel: [String: [[Float]]] = [:]
        let count = min(labels.count, observations.count)
        for index in 0..<count {
            guard let label = labels[index],
                  observations[index].isEligibleForClustering,
                  let vector = VoiceprintIdentity.normalizedQualityEmbedding(
                    observations[index].embedding.vector ?? []
                  ) else {
                continue
            }
            embeddingsByLabel[label, default: []].append(vector)
        }

        var bindings = speakers.map { label in
            MeetingSpeakerBinding(
                temporaryLabel: label,
                state: .unknown,
                candidateEmbeddings: embeddingsByLabel[label] ?? []
            )
        }
        applySuspectedMatches(to: &bindings, archive: archive)
        return bindings
    }

    /// Re-evaluate unknown/suspected bindings against the archive. Confirmed
    /// bindings and denied candidates are left alone. Archive is never written.
    static func applySuspectedMatches(
        to bindings: inout [MeetingSpeakerBinding],
        archive: VoiceprintArchive
    ) {
        for index in bindings.indices {
            if case .confirmed = bindings[index].state { continue }
            guard let centroid = SuspectedIdentityMatcher.queryCentroid(
                from: bindings[index].candidateEmbeddings
            ) else {
                bindings[index].state = .unknown
                continue
            }
            let result = SuspectedIdentityMatcher.match(
                query: centroid,
                against: archive,
                excluding: bindings[index].deniedIdentityIDs
            )
            bindings[index].state = result.state
        }
    }

    /// Confirm a temporary speaker as an existing or new archive identity.
    /// Only quality embeddings enter the archive.
    @discardableResult
    static func confirm(
        temporaryLabel: String,
        displayName: String? = nil,
        identityID: UUID? = nil,
        bindings: inout [MeetingSpeakerBinding],
        archive: inout VoiceprintArchive,
        at date: Date = Date()
    ) throws -> VoiceprintIdentity {
        guard let index = bindings.firstIndex(where: { $0.temporaryLabel == temporaryLabel }) else {
            throw ActionError.unknownTemporaryLabel
        }

        let resolvedName = resolvedDisplayName(
            preferred: displayName,
            binding: bindings[index]
        )
        guard !resolvedName.isEmpty else { throw ActionError.emptyDisplayName }

        let quality = bindings[index].candidateEmbeddings.compactMap(
            VoiceprintIdentity.normalizedQualityEmbedding(_:)
        )
        guard !quality.isEmpty else { throw ActionError.noQualityEmbeddings }

        let targetID = identityID ?? bindings[index].state.identityID
        var identity: VoiceprintIdentity
        if let targetID {
            guard var existing = archive.identity(id: targetID) else {
                throw ActionError.missingArchiveIdentity
            }
            existing.rename(resolvedName, at: date)
            existing.appendQualityEmbeddings(quality, at: date)
            identity = existing
        } else {
            identity = VoiceprintIdentity(
                displayName: resolvedName,
                embeddings: quality,
                updatedAt: date
            )
        }

        archive.upsert(identity)
        bindings[index].state = .confirmed(
            identityID: identity.id,
            displayName: identity.displayName
        )
        bindings[index].meetingAlias = nil
        return identity
    }

    /// Deny the current suspected match. Archive is untouched.
    static func deny(
        temporaryLabel: String,
        bindings: inout [MeetingSpeakerBinding]
    ) throws {
        guard let index = bindings.firstIndex(where: { $0.temporaryLabel == temporaryLabel }) else {
            throw ActionError.unknownTemporaryLabel
        }
        if case let .suspected(identityID, _) = bindings[index].state {
            bindings[index].deniedIdentityIDs.insert(identityID)
        }
        bindings[index].state = .unknown
    }

    /// Rename display text. Confirmed identities update the archive name only
    /// (no embedding write). Suspected/unknown stay out of the archive.
    @discardableResult
    static func rename(
        temporaryLabel: String,
        displayName: String,
        bindings: inout [MeetingSpeakerBinding],
        archive: inout VoiceprintArchive,
        at date: Date = Date()
    ) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActionError.emptyDisplayName }
        guard let index = bindings.firstIndex(where: { $0.temporaryLabel == temporaryLabel }) else {
            throw ActionError.unknownTemporaryLabel
        }

        switch bindings[index].state {
        case .unknown:
            bindings[index].meetingAlias = trimmed
            return trimmed
        case let .suspected(identityID, _):
            bindings[index].state = .suspected(identityID: identityID, displayName: trimmed)
            return trimmed
        case let .confirmed(identityID, _):
            archive.rename(id: identityID, displayName: trimmed, at: date)
            let resolved = archive.identity(id: identityID)?.displayName ?? trimmed
            bindings[index].state = .confirmed(identityID: identityID, displayName: resolved)
            return resolved
        }
    }

    private static func resolvedDisplayName(
        preferred: String?,
        binding: MeetingSpeakerBinding
    ) -> String {
        if let preferred {
            let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let linked = binding.state.linkedDisplayName {
            let trimmed = linked.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let alias = binding.meetingAlias {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
