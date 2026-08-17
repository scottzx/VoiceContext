import Foundation

enum FolderCatalogError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case folderNotFound(UUID)
    case recordingNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "文件夹名称不能为空"
        case .duplicateName(let name):
            "已存在同名文件夹：\(name)"
        case .folderNotFound(let id):
            "找不到文件夹 \(id.uuidString)"
        case .recordingNotFound(let id):
            "找不到录音 \(id.uuidString)"
        }
    }
}

/// Local-first folder catalog under `VoiceContext/Folders/catalog.json`.
actor FolderCatalogStore {
    let rootURL: URL
    private let fileManager: FileManager
    private var cached: FolderCatalogDocument?

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var catalogRelativePath: String {
        PublicDocumentLayout.folderCatalogRelativePath
    }

    var localCatalogURL: URL {
        rootURL.appendingPathComponent(catalogRelativePath)
    }

    func load() throws -> FolderCatalogDocument {
        if let cached { return cached }
        let url = localCatalogURL
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = FolderCatalogDocument.empty()
            cached = empty
            return empty
        }
        let data = try PublicDocumentFileIO.readCompletedData(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(FolderCatalogDocument.self, from: data)
        cached = document
        return document
    }

    @discardableResult
    func save(_ document: FolderCatalogDocument) throws -> FolderCatalogDocument {
        let directory = localCatalogURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try PublicDocumentFileIO.writeAtomically(data, to: localCatalogURL, fileManager: fileManager)
        cached = document
        return document
    }

    /// Replace in-memory + disk catalog after a sync pull that adopted remote bytes.
    @discardableResult
    func replace(_ document: FolderCatalogDocument) throws -> FolderCatalogDocument {
        try save(document)
    }

    func invalidateCache() {
        cached = nil
    }

    @discardableResult
    func createFolder(name: String, now: Date = Date()) throws -> FolderCatalogDocument {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderCatalogError.emptyName }
        var document = try load()
        if document.folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw FolderCatalogError.duplicateName(trimmed)
        }
        let folder = RecordingFolder(name: trimmed, createdAt: now, updatedAt: now)
        document.folders.append(folder)
        document.folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        document.bumpRevision(now: now)
        return try save(document)
    }

    @discardableResult
    func renameFolder(id: UUID, to name: String, now: Date = Date()) throws -> FolderCatalogDocument {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderCatalogError.emptyName }
        var document = try load()
        guard let index = document.folders.firstIndex(where: { $0.id == id }) else {
            throw FolderCatalogError.folderNotFound(id)
        }
        if document.folders.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw FolderCatalogError.duplicateName(trimmed)
        }
        document.folders[index].name = trimmed
        document.folders[index].updatedAt = now
        document.folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        document.bumpRevision(now: now)
        return try save(document)
    }

    /// Deletes the folder definition and moves memberships to uncategorized.
    /// Never deletes Recording rows or audio (FR-ADD-FLD-001).
    @discardableResult
    func deleteFolder(id: UUID, now: Date = Date()) throws -> FolderCatalogDocument {
        var document = try load()
        guard document.folders.contains(where: { $0.id == id }) else {
            throw FolderCatalogError.folderNotFound(id)
        }
        document.folders.removeAll { $0.id == id }
        let folderKey = id.uuidString
        document.memberships = document.memberships.filter { $0.value != folderKey }
        document.bumpRevision(now: now)
        return try save(document)
    }

    /// `folderID == nil` moves the recording to uncategorized.
    @discardableResult
    func moveRecording(
        _ recordingID: UUID,
        to folderID: UUID?,
        now: Date = Date()
    ) throws -> FolderCatalogDocument {
        var document = try load()
        if let folderID {
            guard document.folders.contains(where: { $0.id == folderID }) else {
                throw FolderCatalogError.folderNotFound(folderID)
            }
            document.memberships[recordingID.uuidString] = folderID.uuidString
        } else {
            document.memberships.removeValue(forKey: recordingID.uuidString)
        }
        document.bumpRevision(now: now)
        return try save(document)
    }

    func pruneMemberships(validRecordingIDs: Set<UUID>, now: Date = Date()) throws -> FolderCatalogDocument {
        var document = try load()
        let before = document.memberships.count
        document.memberships = document.memberships.filter { key, value in
            guard let recordingID = UUID(uuidString: key),
                  validRecordingIDs.contains(recordingID),
                  let folderID = UUID(uuidString: value),
                  document.folders.contains(where: { $0.id == folderID })
            else { return false }
            return true
        }
        guard document.memberships.count != before else { return document }
        document.bumpRevision(now: now)
        return try save(document)
    }
}
