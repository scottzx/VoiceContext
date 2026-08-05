import Foundation

/// Keeps speaker identification failures visible. In particular, callers must
/// not synthesize a vector to make a failed embedding appear valid.
enum SpeakerEmbeddingResult: Equatable, Sendable {
    case embedding([Float])
    case unavailable(reason: String)

    var vector: [Float]? {
        guard case .embedding(let vector) = self, !vector.isEmpty else { return nil }
        return vector
    }
}
