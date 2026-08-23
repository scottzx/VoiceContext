import Foundation

/// Keeps speaker identification failures visible. In particular, callers must
/// not synthesize a vector to make a failed embedding appear valid.
nonisolated enum SpeakerEmbeddingResult: Codable, Equatable, Sendable {
    case embedding([Float])
    case unavailable(reason: String)

    nonisolated var vector: [Float]? {
        guard case .embedding(let vector) = self, !vector.isEmpty else { return nil }
        return vector
    }

    private enum CodingKeys: String, CodingKey {
        case embedding
        case unavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let vector = try container.decodeIfPresent([Float].self, forKey: .embedding) {
            self = .embedding(vector)
        } else if let reason = try container.decodeIfPresent(String.self, forKey: .unavailable) {
            self = .unavailable(reason: reason)
        } else {
            self = .unavailable(reason: "未知")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .embedding(let vector):
            try container.encode(vector, forKey: .embedding)
        case .unavailable(let reason):
            try container.encode(reason, forKey: .unavailable)
        }
    }
}
