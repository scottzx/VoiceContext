import CryptoKit
import Foundation

nonisolated struct ModelArtifact: Codable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let sha256: String
    let sourceURL: URL
    let licenseURL: URL
    let sizeBytes: Int64?
    let downloadURL: URL?
    let revision: String?
    let modelSetVersion: String?

    init(id: String, relativePath: String, sha256: String, sourceURL: URL, licenseURL: URL,
         sizeBytes: Int64? = nil, downloadURL: URL? = nil, revision: String? = nil,
         modelSetVersion: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.licenseURL = licenseURL
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.revision = revision
        self.modelSetVersion = modelSetVersion
    }
}

nonisolated enum ModelIntegrityError: LocalizedError, Equatable {
    case missing(String)
    case digestMismatch(id: String, expected: String, actual: String)
    case sizeMismatch(id: String)

    var errorDescription: String? {
        switch self {
        case .missing(let path):
            String(format: L("缺少本地模型资源：%@"), path)
        case .digestMismatch(let id, let expected, let actual):
            String(format: L("模型 %@ 的 SHA-256 不匹配（期望 %@，实际 %@）"), id, expected, actual)
        case .sizeMismatch(let id):
            String(format: L("模型 %@ 的文件大小不符，请重新下载。"), id)
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

        if let expected = artifact.sizeBytes,
           (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize != Int(expected) {
            throw ModelIntegrityError.sizeMismatch(id: artifact.id)
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
