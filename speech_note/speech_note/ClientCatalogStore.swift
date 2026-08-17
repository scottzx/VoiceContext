import Foundation

enum ClientCatalogError: LocalizedError, Equatable {
    case emptyName
    case clientNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "客户姓名不能为空"
        case .clientNotFound(let id):
            "未找到指定客户档案：\(id.uuidString)"
        }
    }
}

/// Local-first client profile store under Application Support / Documents.
actor ClientCatalogStore {
    let rootURL: URL
    private let fileManager: FileManager
    private var cached: ClientCatalogDocument?

    static let relativeCatalogPath = "Clients/catalog.json"

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var localCatalogURL: URL {
        rootURL.appendingPathComponent(Self.relativeCatalogPath)
    }

    func load() throws -> ClientCatalogDocument {
        if let cached { return cached }
        let url = localCatalogURL
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = ClientCatalogDocument.empty()
            cached = empty
            return empty
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ClientCatalogDocument.self, from: data)
        cached = document
        return document
    }

    @discardableResult
    func save(_ document: ClientCatalogDocument) throws -> ClientCatalogDocument {
        let directory = localCatalogURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: localCatalogURL, options: .atomic)
        cached = document
        return document
    }

    @discardableResult
    func upsertClient(_ client: ClientProfile, now: Date = Date()) throws -> ClientCatalogDocument {
        let trimmed = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientCatalogError.emptyName }
        var document = try load()
        var updatedClient = client
        updatedClient.name = trimmed
        updatedClient.updatedAt = now

        if let index = document.clients.firstIndex(where: { $0.id == client.id }) {
            document.clients[index] = updatedClient
        } else {
            document.clients.append(updatedClient)
        }
        document.clients.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        document.bumpRevision(now: now)
        return try save(document)
    }

    @discardableResult
    func deleteClient(id: UUID, now: Date = Date()) throws -> ClientCatalogDocument {
        var document = try load()
        guard document.clients.contains(where: { $0.id == id }) else {
            throw ClientCatalogError.clientNotFound(id)
        }
        document.clients.removeAll { $0.id == id }
        document.bumpRevision(now: now)
        return try save(document)
    }

    @discardableResult
    func linkVoiceprint(clientID: UUID, voiceprintID: UUID?, now: Date = Date()) throws -> ClientCatalogDocument {
        var document = try load()
        guard let index = document.clients.firstIndex(where: { $0.id == clientID }) else {
            throw ClientCatalogError.clientNotFound(clientID)
        }
        document.clients[index].voiceprintIdentityID = voiceprintID
        document.clients[index].updatedAt = now
        document.bumpRevision(now: now)
        return try save(document)
    }

    func invalidateCache() {
        cached = nil
    }
}
