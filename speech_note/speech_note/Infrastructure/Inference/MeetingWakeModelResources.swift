import Foundation

/// Small keyword-spotting weights ship with the app, independently of downloaded ASR models.
public nonisolated enum MeetingWakeModelResources {
    private static let requiredFiles: Set<String> = [
        "encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt", "keywords.txt"
    ]

    private static let bundledRoot: Result<URL, Error> = Result {
        guard let resources = Bundle.main.resourceURL else {
            throw ModelIntegrityError.missing("MeetingWakeModels")
        }
        let root = resources.appending(path: "MeetingWakeModels", directoryHint: .isDirectory)
        try validate(in: root)
        return root
    }

    public static var isReady: Bool {
        (try? requiredResourceRoot()) != nil
    }

    /// The signed bundle is immutable; validate its manifest and hashes once per process.
    public static func requiredResourceRoot() throws -> URL {
        try bundledRoot.get()
    }

    static func validate(in root: URL) throws {
        let manifestURL = root.appending(path: "MeetingWakeManifest.json")
        let artifacts = try ModelIntegrity.manifest(from: manifestURL)
        guard artifacts.count == requiredFiles.count,
              Set(artifacts.map(\.relativePath)) == requiredFiles else {
            throw ModelIntegrityError.missing("MeetingWakeManifest.json: required KWS artifacts")
        }
        try ModelIntegrity.validateAll(artifacts, in: root)
    }
}
