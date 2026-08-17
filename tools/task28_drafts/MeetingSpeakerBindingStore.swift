import Foundation

/// Meeting-local speaker identity bindings. Kept beside canonical Transcripts
/// but outside public Meetings/Daily mirrors (FR-ICL-007 / FR-SPK-006).
nonisolated enum MeetingSpeakerBindingStore {
    static let directoryName = "SpeakerBindings"

    static func directoryURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(rootURL: URL, recordingID: UUID) -> URL {
        directoryURL(rootURL: rootURL)
            .appendingPathComponent("\(recordingID.uuidString).json")
    }

    static func load(rootURL: URL, recordingID: UUID) throws -> [MeetingSpeakerBinding] {
        let url = fileURL(rootURL: rootURL, recordingID: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MeetingSpeakerBinding].self, from: data)
    }

    static func save(
        _ bindings: [MeetingSpeakerBinding],
        rootURL: URL,
        recordingID: UUID
    ) throws {
        let directory = directoryURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bindings)
        try data.write(to: fileURL(rootURL: rootURL, recordingID: recordingID), options: .atomic)
    }
}
