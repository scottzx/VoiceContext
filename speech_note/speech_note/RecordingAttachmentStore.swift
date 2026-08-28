import Foundation
import UniformTypeIdentifiers

nonisolated struct RecordingAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let originalFilename: String
    let relativePath: String
    let utTypeIdentifier: String?
    let fileSize: Int64
    let addedAt: Date
}

actor RecordingAttachmentStore {
    enum StoreError: LocalizedError {
        case invalidFilename
        case fileUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidFilename:
                "文件名无效"
            case let .fileUnavailable(name):
                "无法读取文件：\(name)"
            }
        }
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func attachments(recordingID: UUID) throws -> [RecordingAttachment] {
        guard fileManager.fileExists(atPath: indexURL(recordingID: recordingID).path) else {
            return []
        }
        return try decoder.decode(
            [RecordingAttachment].self,
            from: Data(contentsOf: indexURL(recordingID: recordingID))
        ).sorted { $0.addedAt < $1.addedAt }
    }

    func add(_ sourceURLs: [URL], recordingID: UUID) throws -> [RecordingAttachment] {
        var current = try attachments(recordingID: recordingID)
        var added: [RecordingAttachment] = []
        let filesURL = recordingDirectory(recordingID: recordingID)
            .appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)

        for sourceURL in sourceURLs {
            let filename = Self.safeDisplayFilename(sourceURL.lastPathComponent)
            guard !filename.isEmpty else { throw StoreError.invalidFilename }
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw StoreError.fileUnavailable(filename)
            }

            let id = UUID()
            let ext = sourceURL.pathExtension
            let storedName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
            let destination = filesURL.appendingPathComponent(storedName)
            let staging = filesURL.appendingPathComponent(".\(id.uuidString).staging")
            do {
                try fileManager.copyItem(at: sourceURL, to: staging)
                try fileManager.moveItem(at: staging, to: destination)
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                let item = RecordingAttachment(
                    id: id,
                    recordingID: recordingID,
                    originalFilename: filename,
                    relativePath: destination.path.replacingOccurrences(
                        of: rootURL.path + "/",
                        with: ""
                    ),
                    utTypeIdentifier: values.contentType?.identifier,
                    fileSize: Int64(values.fileSize ?? 0),
                    addedAt: Date()
                )
                current.append(item)
                try writeIndex(current, recordingID: recordingID)
                added.append(item)
            } catch {
                try? fileManager.removeItem(at: staging)
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        return added
    }

    func remove(id: UUID, recordingID: UUID) throws {
        var current = try attachments(recordingID: recordingID)
        guard let item = current.first(where: { $0.id == id }) else { return }
        current.removeAll { $0.id == id }
        try writeIndex(current, recordingID: recordingID)
        try? fileManager.removeItem(at: url(for: item))
    }

    func url(for attachment: RecordingAttachment) -> URL {
        rootURL.appendingPathComponent(attachment.relativePath)
    }

    func removeAll(recordingID: UUID) throws {
        let directory = recordingDirectory(recordingID: recordingID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func writeIndex(_ attachments: [RecordingAttachment], recordingID: UUID) throws {
        let directory = recordingDirectory(recordingID: recordingID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(attachments).write(
            to: indexURL(recordingID: recordingID),
            options: .atomic
        )
    }

    private func recordingDirectory(recordingID: UUID) -> URL {
        rootURL
            .appendingPathComponent("RecordingAttachments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    private func indexURL(recordingID: UUID) -> URL {
        recordingDirectory(recordingID: recordingID).appendingPathComponent("index.json")
    }

    nonisolated static func safeDisplayFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
