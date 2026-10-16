import Foundation

nonisolated func L(_ text: String) -> String { text }

@main
struct MeetingWakeModelChecks {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try MeetingWakeModelResources.validate(in: source)
        precondition(MeetingWakeModelResources.isReady)
        let bundleRoot = try MeetingWakeModelResources.requiredResourceRoot()
        precondition(bundleRoot.lastPathComponent == "MeetingWakeModels")
        let cachedRoot = try MeetingWakeModelResources.requiredResourceRoot()
        precondition(cachedRoot == bundleRoot)

        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let keywordURL = temporary.appending(path: "keywords.txt")
        var keywordData = try Data(contentsOf: keywordURL)
        keywordData[0] = 121 // same byte count, different hash
        try keywordData.write(to: keywordURL)
        do {
            try MeetingWakeModelResources.validate(in: temporary)
            preconditionFailure("A modified keyword file must not pass integrity validation")
        } catch ModelIntegrityError.digestMismatch(let id, _, _) {
            precondition(id == "meeting-wake-keywords")
        }

        try FileManager.default.removeItem(at: temporary.appending(path: "encoder.onnx"))
        do {
            try MeetingWakeModelResources.validate(in: temporary)
            preconditionFailure("Missing preinstalled weights must be reported")
        } catch ModelIntegrityError.missing(let path) {
            precondition(path == "encoder.onnx")
        }

        try Data("[]".utf8).write(to: temporary.appending(path: "MeetingWakeManifest.json"))
        do {
            try MeetingWakeModelResources.validate(in: temporary)
            preconditionFailure("An incomplete manifest must not report ready")
        } catch ModelIntegrityError.missing { }
        print("Meeting wake model bundle/integrity checks passed")
    }
}
