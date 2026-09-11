import Foundation

nonisolated enum SpeakerSimilarity {
    nonisolated enum Decision: Equatable {
        case likelySameSpeaker
        case likelyDifferentSpeaker
        case uncertain
    }

    static let likelySameSpeakerThreshold: Float = 0.65
    static let likelyDifferentSpeakerThreshold: Float = 0.55

    /// Returns cosine similarity only for two complete, finite vectors.
    /// Embeddings are already L2-normalized at the native boundary, but this
    /// calculation remains valid if a caller supplies an unnormalized vector.
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else {
            return nil
        }

        let dot = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let lhsNorm = sqrt(lhs.reduce(Float.zero) { $0 + $1 * $1 })
        let rhsNorm = sqrt(rhs.reduce(Float.zero) { $0 + $1 * $1 })
        guard lhsNorm.isFinite, rhsNorm.isFinite, lhsNorm > 0, rhsNorm > 0 else {
            return nil
        }

        let similarity = dot / (lhsNorm * rhsNorm)
        guard similarity.isFinite else { return nil }
        return min(1, max(-1, similarity))
    }

    /// The current device samples overlap near 0.60, so a guard band is safer
    /// than pretending that one hard threshold separates the two speakers.
    static func decision(for similarity: Float) -> Decision? {
        guard similarity.isFinite, (-1 ... 1).contains(similarity) else { return nil }
        if similarity >= likelySameSpeakerThreshold {
            return .likelySameSpeaker
        }
        if similarity <= likelyDifferentSpeakerThreshold {
            return .likelyDifferentSpeaker
        }
        return .uncertain
    }
}
