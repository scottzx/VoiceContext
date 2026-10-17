import Foundation

@MainActor
final class AppArtifactStore {
    static let shared = AppArtifactStore()

    func save(_ artifact: AppArtifact) throws {
        try artifact.validate()
        let url = try manifestURL(id: artifact.id, create: true)
        try JSONEncoder().encode(artifact).write(to: url, options: .atomic)
    }

    func load(id: String) throws -> AppArtifact {
        let url = try manifestURL(id: id, create: false)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 1_048_576 else { throw AppArtifactError.invalid("内容清单过大。") }
        let artifact = try JSONDecoder().decode(AppArtifact.self, from: Data(contentsOf: url))
        try artifact.validate()
        let expected = try AppArtifact.identifier(id)
        let actual = try AppArtifact.identifier(artifact.id)
        guard expected == actual else { throw AppArtifactError.invalid("内容清单与请求不匹配。") }
        return artifact
    }

    func fileURL(for artifact: AppArtifact) throws -> URL {
        try artifact.validate()
        guard let file = artifact.file else { throw AppArtifactError.invalid("此产物没有文件。") }
        let root = AIChatViewModel.minisWorkspacePersistentDir(for: artifact.sourceSessionID).deletingLastPathComponent()
        return try file.resolve(sessionRoot: root, maximumBytes: artifact.kind == .html ? 2_097_152 : 33_554_432)
    }

    func validateSource(_ artifact: AppArtifact) async throws {
        try artifact.validate()
        guard await ChatStore.shared.getSession(artifact.sessionID) != nil else {
            throw AppArtifactError.invalid("内容所属会话已不存在。")
        }
        if artifact.sourceSessionID != artifact.sessionID {
            guard let child = await ChatStore.shared.getSession(artifact.sourceSessionID), child.parentSessionId == artifact.sessionID else {
                throw AppArtifactError.invalid("内容来源不属于当前会话或其已分派子会话。")
            }
        }
    }

    private func manifestURL(id: String, create: Bool) throws -> URL {
        let identity = try AppArtifact.identifier(id)
        let workspace = AIChatViewModel.minisWorkspacePersistentDir(for: identity.session)
        let session = workspace.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("AppPresentations", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(session.path + "/"), directory.path.hasPrefix(root.path + "/") else {
            throw AppArtifactError.invalid("内容清单目录越过会话范围。")
        }
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let url = directory.appendingPathComponent(identity.file + ".json").resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else { throw AppArtifactError.invalid("内容清单路径无效。") }
        return url
    }
}
