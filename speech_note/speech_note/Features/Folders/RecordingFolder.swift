import Foundation

/// User-created folder for organizing recordings (FR-ADD-FLD-*).
/// Folder definitions and Recording→folder membership sync as JSON metadata only.
nonisolated struct RecordingFolder: Codable, Equatable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// Local / iCloud-isomorphic catalog document. Never embeds audio or voiceprints.
nonisolated struct FolderCatalogDocument: Codable, Equatable, Sendable {
    static let schema = "voice-context/folders@1"

    var schema: String
    var revision: Int
    var updatedAt: Date
    var folders: [RecordingFolder]
    /// `recordingID.uuidString` → `folderID.uuidString`. Missing key = uncategorized.
    var memberships: [String: String]

    static func empty(now: Date = Date()) -> FolderCatalogDocument {
        FolderCatalogDocument(
            schema: schema,
            revision: 1,
            updatedAt: now,
            folders: [],
            memberships: [:]
        )
    }

    func folder(id: UUID) -> RecordingFolder? {
        folders.first { $0.id == id }
    }

    func folderID(for recordingID: UUID) -> UUID? {
        guard let raw = memberships[recordingID.uuidString] else { return nil }
        return UUID(uuidString: raw)
    }

    func folderName(for recordingID: UUID) -> String? {
        guard let folderID = folderID(for: recordingID) else { return nil }
        return folder(id: folderID)?.name
    }

    mutating func bumpRevision(now: Date = Date()) {
        revision += 1
        updatedAt = now
    }
}

/// List filter. Selecting a concrete folder (or uncategorized) takes precedence
/// over the implicit “全部” folder scope; time/calendar filters still compose
/// on top (FR-ADD-FLD-003).
nonisolated enum FolderListFilter: Equatable, Hashable, Sendable {
    case all
    case uncategorized
    case folder(UUID)

    func includes(recordingID: UUID, catalog: FolderCatalogDocument) -> Bool {
        switch self {
        case .all:
            return true
        case .uncategorized:
            return catalog.folderID(for: recordingID) == nil
        case .folder(let id):
            return catalog.folderID(for: recordingID) == id
        }
    }
}
