import Foundation

nonisolated public enum TranscriptionModelError: LocalizedError {
    case missingManifest
    case invalidManifest
    case notReady
    case insufficientSpace
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .missingManifest: L("找不到语音转文字模型清单。")
        case .invalidManifest: L("语音转文字模型清单不完整。")
        case .notReady: L("请先下载语音转文字模型。音频已保存，下载完成后可继续转写。")
        case .insufficientSpace: L("可用空间不足，请释放空间后重新下载模型。")
        case .httpStatus(let status): String(format: L("模型下载失败（HTTP %lld），请重试。"), Int64(status))
        }
    }
}

/// File signatures only cache a successful SHA check within this process.
/// Every launch verifies the actual files again before any loader sees them.
nonisolated final class ModelInstallation: @unchecked Sendable {
    let root: URL
    let artifacts: [ModelArtifact]
    var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private let lock = NSLock()
    private var verified: [String: FileSignature] = [:]

    private struct FileSignature: Equatable {
        let size: Int64
        let modified: Date
        let inode: UInt64

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw TranscriptionModelError.notReady
            }
            self.size = size.int64Value
            self.modified = modified
            self.inode = inode.uint64Value
        }
    }

    init(root: URL, artifacts: [ModelArtifact]) throws {
        guard !artifacts.isEmpty, Set(artifacts.map(\.id)).count == artifacts.count,
              Set(artifacts.map(\.relativePath)).count == artifacts.count,
              artifacts.allSatisfy({ artifact in
                  !artifact.id.isEmpty && artifact.id != "." && artifact.id != ".."
                  && (artifact.id as NSString).lastPathComponent == artifact.id
                  && !artifact.relativePath.isEmpty && artifact.relativePath != "." && artifact.relativePath != ".."
                  && (artifact.relativePath as NSString).lastPathComponent == artifact.relativePath
                  && artifact.sizeBytes.map { $0 > 0 } == true
                  && artifact.downloadURL?.scheme == "https"
                  && artifact.sha256.count == 64
                  && artifact.sha256.allSatisfy { $0.isHexDigit }
              }) else { throw TranscriptionModelError.invalidManifest }
        self.root = root
        self.artifacts = artifacts
    }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func isVerified(_ artifact: ModelArtifact) -> Bool {
        lock.lock()
        let cached = verified[artifact.id]
        lock.unlock()
        guard let cached,
              let actual = try? FileSignature(url: root.appendingPathComponent(artifact.relativePath)) else { return false }
        return actual == cached
    }

    var isReady: Bool { artifacts.allSatisfy(isVerified) }

    func validateInstalled(_ artifact: ModelArtifact) throws {
        let url = root.appendingPathComponent(artifact.relativePath)
        let before = try FileSignature(url: url)
        try ModelIntegrity.validate(artifact, in: root)
        let after = try FileSignature(url: url)
        guard before == after else { throw TranscriptionModelError.notReady }
        lock.lock()
        verified[artifact.id] = after
        lock.unlock()
    }

    func publishStaged(_ artifact: ModelArtifact) throws {
        try ModelIntegrity.validate(artifact, in: staging)
        let source = staging.appendingPathComponent(artifact.relativePath)
        let destination = root.appendingPathComponent(artifact.relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let signature = try FileSignature(url: destination)
        lock.lock()
        verified[artifact.id] = signature
        lock.unlock()
    }

    func resourceRoot() throws -> URL {
        guard isReady else { throw TranscriptionModelError.notReady }
        return root
    }
}

nonisolated public enum TranscriptionModelStore {
    static let installation: ModelInstallation? = try? makeInstallation()

    private static func makeInstallation() throws -> ModelInstallation {
        let bundle = Bundle.main
        guard let manifest = bundle.url(forResource: "ModelManifest", withExtension: "json")
                ?? bundle.url(forResource: "ModelManifest", withExtension: "json", subdirectory: "ModelResources")
                ?? Bundle(for: TranscriptionModelDownloadService.self).url(forResource: "ModelManifest", withExtension: "json") else {
            throw TranscriptionModelError.missingManifest
        }
        let artifacts = try ModelIntegrity.manifest(from: manifest)
        guard Set(artifacts.map(\.id)) == Set([
            "sensevoice-q8-0", "silero-vad", "cam-plus", "pyannote-segmentation-3-int8"
        ]) else { throw TranscriptionModelError.invalidManifest }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return try ModelInstallation(root: support.appendingPathComponent("TranscriptionModels", isDirectory: true),
                                     artifacts: artifacts)
    }

    /// Safe to query from the scheduler's actor. No network work or hashing.
    public static var isReady: Bool { installation?.isReady == true }

    public static func requiredResourceRoot() throws -> URL {
        guard let installation else { throw TranscriptionModelError.missingManifest }
        return try installation.resourceRoot()
    }

    public static func modelURL(id: String) throws -> URL {
        guard let installation, let artifact = installation.artifacts.first(where: { $0.id == id }) else {
            throw TranscriptionModelError.missingManifest
        }
        return try installation.resourceRoot().appendingPathComponent(artifact.relativePath)
    }
}

extension Notification.Name {
    public static let transcriptionModelsDidBecomeReady = Notification.Name("YimaTranscriptionModelsDidBecomeReady")
}
