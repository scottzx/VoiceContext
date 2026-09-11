import Foundation

/// Meeting / archive identity lifecycle for FR-SPK-005/006.
/// `suspected` is never displayed as a confirmed name.
nonisolated enum SpeakerIdentityState: Equatable, Sendable, Codable {
    case unknown
    case suspected(identityID: UUID, displayName: String)
    case confirmed(identityID: UUID, displayName: String)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    var isSuspected: Bool {
        if case .suspected = self { return true }
        return false
    }

    var identityID: UUID? {
        switch self {
        case .unknown:
            nil
        case let .suspected(identityID, _), let .confirmed(identityID, _):
            identityID
        }
    }

    var linkedDisplayName: String? {
        switch self {
        case .unknown:
            nil
        case let .suspected(_, displayName), let .confirmed(_, displayName):
            displayName
        }
    }
}

nonisolated enum SpeakerIdentityLabeling {
    static let suspectedPrefix = "疑似："

    /// UI / transcript chip text. Suspected always keeps an explicit marker.
    static func chipText(
        temporaryLabel: String,
        state: SpeakerIdentityState,
        meetingAlias: String? = nil
    ) -> String {
        switch state {
        case .unknown:
            let alias = meetingAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return alias.isEmpty ? temporaryLabel : alias
        case let .suspected(_, displayName):
            return "\(suspectedPrefix)\(displayName)"
        case let .confirmed(_, displayName):
            return displayName
        }
    }
}

/// One meeting-local speaker after offline recluster, optionally matched to a
/// historical archive identity. Candidate embeddings stay processing-only until
/// the user confirms.
nonisolated struct MeetingSpeakerBinding: Equatable, Sendable, Codable, Identifiable {
    public var id: String { temporaryLabel }
    let temporaryLabel: String
    var state: SpeakerIdentityState
    /// Eligible, L2-normalized embeddings for this meeting cluster.
    var candidateEmbeddings: [[Float]]
    /// Identities the user denied for this temporary label in the current session.
    var deniedIdentityIDs: Set<UUID>
    /// Optional meeting-local alias for `.unknown` after rename; never implies
    /// archive membership.
    var meetingAlias: String?

    init(
        temporaryLabel: String,
        state: SpeakerIdentityState = .unknown,
        candidateEmbeddings: [[Float]] = [],
        deniedIdentityIDs: Set<UUID> = [],
        meetingAlias: String? = nil
    ) {
        self.temporaryLabel = temporaryLabel
        self.state = state
        self.candidateEmbeddings = candidateEmbeddings
        self.deniedIdentityIDs = deniedIdentityIDs
        self.meetingAlias = meetingAlias
    }

    var chipText: String {
        SpeakerIdentityLabeling.chipText(
            temporaryLabel: temporaryLabel,
            state: state,
            meetingAlias: meetingAlias
        )
    }
}
