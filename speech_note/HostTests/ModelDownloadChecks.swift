import CryptoKit
import Foundation

@main
struct ModelDownloadChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yima-model-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = [Data("first model".utf8), Data("second model".utf8)]
        let artifacts = bytes.enumerated().map { index, data in
            ModelArtifact(id: "fixture-\(index)", relativePath: "fixture-\(index).onnx",
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                          sourceURL: URL(string: "https://example.com/source")!,
                          licenseURL: URL(string: "https://example.com/license")!,
                          sizeBytes: Int64(data.count), downloadURL: URL(string: "https://example.com/file-\(index)")!)
        }
        let installation = try ModelInstallation(root: root, artifacts: artifacts)
        try installation.prepareDirectories()
        precondition(!installation.isReady, "Missing files must not become ready")

        try bytes[0].write(to: installation.staging.appendingPathComponent(artifacts[0].relativePath))
        try installation.publishStaged(artifacts[0])
        precondition(installation.isVerified(artifacts[0]) && !installation.isReady,
                     "One verified file must not unlock the whole model set")
        do {
            _ = try installation.resourceRoot()
            preconditionFailure("Partial model set was admitted")
        } catch TranscriptionModelError.notReady {}

        let staged = installation.staging.appendingPathComponent(artifacts[1].relativePath)
        try Data(repeating: 0, count: bytes[1].count).write(to: staged)
        do {
            try installation.publishStaged(artifacts[1])
            preconditionFailure("Same-size corrupt staged file was accepted")
        } catch ModelIntegrityError.digestMismatch {}
        precondition(!installation.isReady)

        // A process can end between download completion and validation. A new
        // installation sees no cached receipt and can finish the staged file.
        try bytes[1].write(to: staged)
        let reopened = try ModelInstallation(root: root, artifacts: artifacts)
        precondition(!reopened.isReady, "Restart must verify files again")
        try reopened.validateInstalled(artifacts[0])
        try reopened.publishStaged(artifacts[1])
        precondition(reopened.isReady)
        let readyRoot = try reopened.resourceRoot()
        precondition(readyRoot == root)
        precondition(!FileManager.default.fileExists(atPath: staged.path))

        // Replacing an existing bad installation publishes only the validated
        // staged bytes. Changing a verified file invalidates the memory cache.
        let installed = root.appendingPathComponent(artifacts[0].relativePath)
        try Data("bad".utf8).write(to: installed)
        precondition(!reopened.isReady)
        try bytes[0].write(to: reopened.staging.appendingPathComponent(artifacts[0].relativePath))
        try reopened.publishStaged(artifacts[0])
        precondition(reopened.isReady)
        try FileManager.default.removeItem(at: installed)
        precondition(!reopened.isReady, "Deleting a verified file must invalidate readiness")

        var unsafe = artifacts[0]
        unsafe = ModelArtifact(id: unsafe.id, relativePath: "../outside.onnx", sha256: unsafe.sha256,
                               sourceURL: unsafe.sourceURL, licenseURL: unsafe.licenseURL,
                               sizeBytes: unsafe.sizeBytes, downloadURL: unsafe.downloadURL)
        do {
            _ = try ModelInstallation(root: root, artifacts: [unsafe])
            preconditionFailure("Manifest path traversal was accepted")
        } catch TranscriptionModelError.invalidManifest {}

        let resume = Data("resume fixture".utf8)
        let cellular = ModelDownloadResumeRecord(data: resume, allowCellular: true)
        precondition(cellular.data(forCellularChoice: false) == nil,
                     "A cellular resume request must not override a new Wi-Fi choice")
        let wifi = ModelDownloadResumeRecord(data: resume, allowCellular: false)
        precondition(wifi.data(forCellularChoice: true) == nil)
        precondition(wifi.data(forCellularChoice: false) == resume)
        precondition(ModelDownloadResumeRecord(data: resume, allowCellular: nil).data(forCellularChoice: false) == nil)
        print("Model download checks passed: integrity, partial admission, staged recovery, replacement, network policy")
    }
}
