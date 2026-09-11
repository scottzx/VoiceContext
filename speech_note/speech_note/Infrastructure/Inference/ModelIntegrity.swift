import CryptoKit
import Foundation

struct ModelArtifact: Codable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let sha256: String
    let sourceURL: URL
    let licenseURL: URL
}

enum ModelIntegrityError: LocalizedError, Equatable {
    case missing(String)
    case digestMismatch(id: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missing(let path):
            "缺少本地模型资源：\(path)"
        case .digestMismatch(let id, let expected, let actual):
            "模型 \(id) 的 SHA-256 不匹配（期望 \(expected)，实际 \(actual)）"
        }
    }
}

enum ModelIntegrity {
    nonisolated static func manifest(from url: URL) throws -> [ModelArtifact] {
        try JSONDecoder().decode([ModelArtifact].self, from: Data(contentsOf: url))
    }

    nonisolated static func validate(_ artifact: ModelArtifact, in root: URL) throws {
        let fileURL = root.appending(path: artifact.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ModelIntegrityError.missing(artifact.relativePath)
        }

        let actual = try sha256(of: fileURL)
        guard actual.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw ModelIntegrityError.digestMismatch(id: artifact.id, expected: artifact.sha256, actual: actual)
        }
    }

    nonisolated static func validateAll(_ artifacts: [ModelArtifact], in root: URL) throws {
        try artifacts.forEach { try validate($0, in: root) }
    }

    nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
