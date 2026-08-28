import Foundation
import Testing
@testable import speech_note

struct RecordingAttachmentTests {
    @Test func attachmentStoreCopiesPrivatelyAndRemovesOnlyItsCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("agenda.pdf")
        let original = Data("meeting agenda".utf8)
        try original.write(to: source)
        let store = RecordingAttachmentStore(rootURL: root)
        let recordingID = UUID()

        let added = try await store.add([source], recordingID: recordingID)
        let attachment = try #require(added.first)
        let privateURL = await store.url(for: attachment)

        #expect(attachment.originalFilename == "agenda.pdf")
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: privateURL) == original)
        #expect(try await store.attachments(recordingID: recordingID) == [attachment])

        try await store.remove(id: attachment.id, recordingID: recordingID)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: privateURL.path))
        #expect(try await store.attachments(recordingID: recordingID).isEmpty)
    }

    @Test func streamingArchiveRoundTripsNestedFilesAndSanitizesTraversal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.txt")
        let agenda = root.appendingPathComponent("agenda.pdf")
        try Data("hello".utf8).write(to: transcript)
        try Data("agenda".utf8).write(to: agenda)
        let archive = root.appendingPathComponent("package.zip")

        try StreamingZipWriter.write(entries: [
            .init(sourceURL: transcript, archivePath: "transcript.txt"),
            .init(sourceURL: agenda, archivePath: "../related/agenda.pdf"),
        ], to: archive)

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try StoredZipExtractor.extract(zipURL: archive, to: extracted)
        #expect(try String(contentsOf: extracted.appendingPathComponent("transcript.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: extracted.appendingPathComponent("related/agenda.pdf"), encoding: .utf8) == "agenda")
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingAttachmentTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
