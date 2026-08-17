import Foundation

/// A persistent client or participant profile in VoiceContext.
/// Links to a VoiceprintIdentity for speaker recognition across meetings.
struct ClientProfile: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    var organization: String
    var roleOrTitle: String
    var phoneOrEmail: String
    var notes: String
    var tags: [String]
    /// UUID of the linked long-term VoiceprintIdentity in VoiceprintArchive.
    var voiceprintIdentityID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        organization: String = "",
        roleOrTitle: String = "",
        phoneOrEmail: String = "",
        notes: String = "",
        tags: [String] = [],
        voiceprintIdentityID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        self.roleOrTitle = roleOrTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phoneOrEmail = phoneOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.voiceprintIdentityID = voiceprintIdentityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displaySubtitle: String {
        var parts: [String] = []
        if !organization.isEmpty { parts.append(organization) }
        if !roleOrTitle.isEmpty { parts.append(roleOrTitle) }
        return parts.joined(separator: " · ")
    }

    var hasVoiceprint: Bool {
        voiceprintIdentityID != nil
    }
}

/// Root catalog document for client profiles.
struct ClientCatalogDocument: Equatable, Sendable, Codable {
    var version: Int
    var revision: Int
    var clients: [ClientProfile]
    var updatedAt: Date

    init(
        version: Int = 1,
        revision: Int = 1,
        clients: [ClientProfile] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.revision = revision
        self.clients = clients
        self.updatedAt = updatedAt
    }

    static func empty() -> ClientCatalogDocument {
        ClientCatalogDocument(clients: [])
    }

    mutating func bumpRevision(now: Date = Date()) {
        revision += 1
        updatedAt = now
    }
}
