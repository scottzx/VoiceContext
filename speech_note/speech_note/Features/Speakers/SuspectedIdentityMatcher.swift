import Foundation

/// FR-SPK-005: historical identity matching requires both a top-1 cosine
/// threshold and a top-1/top-2 margin before a cluster becomes `suspected`.
/// Exact product thresholds remain a PRD open item; these defaults reuse the
/// online "likely same" floor and demand a clear runner-up gap so near-ties
/// stay `unknown`.
nonisolated enum SuspectedIdentityMatcher {
    static let top1SimilarityThreshold: Float = SpeakerSimilarity.likelySameSpeakerThreshold
    static let top2MarginThreshold: Float = 0.08

    nonisolated struct Candidate: Equatable, Sendable {
        let identityID: UUID
        let displayName: String
        let score: Float
    }

    nonisolated struct MatchResult: Equatable, Sendable {
        let state: SpeakerIdentityState
        let top1: Candidate?
        let top2: Candidate?
        let margin: Float?

        var isSuspected: Bool {
            if case .suspected = state { return true }
            return false
        }
    }

    static func match(
        query: [Float],
        against archive: VoiceprintArchive,
        excluding excludedIDs: Set<UUID> = [],
        top1Threshold: Float = top1SimilarityThreshold,
        top2Margin: Float = top2MarginThreshold
    ) -> MatchResult {
        guard let queryVector = VoiceprintIdentity.normalizedQualityEmbedding(query) else {
            return MatchResult(state: .unknown, top1: nil, top2: nil, margin: nil)
        }

        var scored: [Candidate] = []
        for identity in archive.identities {
            guard !excludedIDs.contains(identity.id),
                  let centroid = identity.centroid,
                  let score = SpeakerSimilarity.cosineSimilarity(queryVector, centroid),
                  score.isFinite else {
                continue
            }
            scored.append(
                Candidate(
                    identityID: identity.id,
                    displayName: identity.displayName,
                    score: score
                )
            )
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.identityID.uuidString < rhs.identityID.uuidString
        }

        let top1 = scored.first
        let top2 = scored.dropFirst().first
        let margin: Float? = {
            guard let top1 else { return nil }
            guard let top2 else { return top1.score - (-1) }
            return top1.score - top2.score
        }()

        guard let top1,
              top1.score >= top1Threshold,
              let margin,
              margin >= top2Margin else {
            return MatchResult(state: .unknown, top1: top1, top2: top2, margin: margin)
        }

        return MatchResult(
            state: .suspected(identityID: top1.identityID, displayName: top1.displayName),
            top1: top1,
            top2: top2,
            margin: margin
        )
    }

    /// Centroid of eligible meeting-cluster embeddings, or nil when none qualify.
    static func queryCentroid(from embeddings: [[Float]]) -> [Float]? {
        VoiceprintIdentity.centroid(of: embeddings)
    }
}
