import CryptoKit
import Foundation

/// One user-confirmed long-term identity. Embeddings are never written from
/// automatic matching — only from an explicit confirm of quality samples.
nonisolated struct VoiceprintIdentity: Equatable, Sendable, Codable {
    let id: UUID
    var displayName: String
    private(set) var embeddings: [[Float]]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        embeddings: [[Float]] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.embeddings = embeddings
        self.updatedAt = updatedAt
    }

    /// Mean of stored embeddings, re-normalized. Nil when the identity has no
    /// usable vectors yet.
    var centroid: [Float]? {
        Self.centroid(of: embeddings)
    }

    mutating func appendQualityEmbeddings(_ vectors: [[Float]], at date: Date = Date()) {
        let accepted = vectors.compactMap(Self.normalizedQualityEmbedding(_:))
        guard !accepted.isEmpty else { return }
        embeddings.append(contentsOf: accepted)
        updatedAt = date
    }

    mutating func rename(_ name: String, at date: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = trimmed
        updatedAt = date
    }

    static func centroid(of embeddings: [[Float]]) -> [Float]? {
        let normalized = embeddings.compactMap(normalizedQualityEmbedding(_:))
        guard let first = normalized.first else { return nil }
        var sums = Array(repeating: Float.zero, count: first.count)
        var count = 0
        for vector in normalized {
            guard vector.count == first.count else { continue }
            for index in sums.indices {
                sums[index] += vector[index]
            }
            count += 1
        }
        guard count > 0 else { return nil }
        let mean = sums.map { $0 / Float(count) }
        return normalizedQualityEmbedding(mean)
    }

    /// Rejects empty, non-finite, or zero vectors. Returns an L2 unit vector.
    static func normalizedQualityEmbedding(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let squared = vector.reduce(Float.zero) { $0 + $1 * $1 }
        let norm = sqrt(squared)
        guard norm.isFinite, norm > 0 else { return nil }
        let values = vector.map { $0 / norm }
        guard values.allSatisfy(\.isFinite) else { return nil }
        return values
    }
}

/// Local long-term voiceprint archive. Must not be written into the public
/// iCloud / Documents transcript tree (FR-ICL-007 / FR-SPK-006).
nonisolated struct VoiceprintArchive: Equatable, Sendable, Codable {
    var identities: [VoiceprintIdentity]

    init(identities: [VoiceprintIdentity] = []) {
        self.identities = identities
    }

    func identity(id: UUID) -> VoiceprintIdentity? {
        identities.first { $0.id == id }
    }

    mutating func upsert(_ identity: VoiceprintIdentity) {
        if let index = identities.firstIndex(where: { $0.id == identity.id }) {
            identities[index] = identity
        } else {
            identities.append(identity)
        }
    }

    mutating func rename(id: UUID, displayName: String, at date: Date = Date()) {
        guard let index = identities.firstIndex(where: { $0.id == id }) else { return }
        identities[index].rename(displayName, at: date)
    }
}

/// AES-GCM encrypted archive I/O under Application Support (never public Docs).
nonisolated enum VoiceprintArchiveStorage {
    static let fileName = "voiceprint-archive.aesgcm"
    static let legacyPlaintextFileName = "voiceprint-archive.json"

    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VoiceContext", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(fileName)
    }

    static func legacyPlaintextURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VoiceContext", isDirectory: true)
        return root.appendingPathComponent(legacyPlaintextFileName)
    }

    /// Loads the encrypted archive. Missing file → empty archive.
    /// Missing key with existing ciphertext → safe failure.
    /// Legacy plaintext JSON is accepted once and re-saved encrypted by callers.
    static func load(
        from url: URL,
        keyProvider: any VoiceprintArchiveKeyProviding = VoiceprintArchiveKeyStore.shared,
        fileManager: FileManager = .default
    ) throws -> VoiceprintArchive {
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if VoiceprintArchiveCrypto.looksLikeLegacyPlaintextArchive(data) {
                return try JSONDecoder().decode(VoiceprintArchive.self, from: data)
            }
            let existingKey: SymmetricKey?
            do {
                existingKey = try keyProvider.loadExistingKey()
            } catch {
                existingKey = nil
            }
            guard let key = existingKey else {
                let backupURL = url.deletingPathExtension().appendingPathExtension("orphaned-\(Int(Date().timeIntervalSince1970)).aesgcm")
                try? fileManager.moveItem(at: url, to: backupURL)
                return VoiceprintArchive()
            }
            do {
                let envelope = try VoiceprintArchiveCrypto.decodeEnvelope(from: data)
                return try VoiceprintArchiveCrypto.open(envelope, using: key)
            } catch {
                let backupURL = url.deletingPathExtension().appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970)).aesgcm")
                try? fileManager.moveItem(at: url, to: backupURL)
                return VoiceprintArchive()
            }
        }

        // Migrate #27 plaintext file if present beside the new encrypted name.
        let legacy = url.deletingLastPathComponent()
            .appendingPathComponent(legacyPlaintextFileName)
        if fileManager.fileExists(atPath: legacy.path) {
            let data = try Data(contentsOf: legacy)
            return try JSONDecoder().decode(VoiceprintArchive.self, from: data)
        }

        return VoiceprintArchive()
    }

    /// Seals the archive with AES-GCM and atomically writes the envelope.
    static func save(
        _ archive: VoiceprintArchive,
        to url: URL,
        keyProvider: any VoiceprintArchiveKeyProviding = VoiceprintArchiveKeyStore.shared,
        synchronizableKey: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        let key = try keyProvider.loadOrCreateKey(synchronizable: synchronizableKey)
        let envelope = try VoiceprintArchiveCrypto.seal(archive, using: key)
        let data = try VoiceprintArchiveCrypto.encodeEnvelope(envelope)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)

        // Drop legacy plaintext once encrypted bytes are durable.
        let legacy = directory.appendingPathComponent(legacyPlaintextFileName)
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.removeItem(at: legacy)
        }
    }

    /// Convenience: save locally then optionally mirror to private iCloud.
    /// Local seal always completes before mirror; mirror failures become
    /// `localOnly` + attention and never roll back the on-device envelope.
    @discardableResult
    static func saveAndSync(
        _ archive: VoiceprintArchive,
        to url: URL,
        keyProvider: any VoiceprintArchiveKeyProviding = VoiceprintArchiveKeyStore.shared,
        synchronizableKey: Bool = false,
        syncConfiguration: EncryptedVoiceprintiCloudMirror.Configuration = .init(),
        fileManager: FileManager = .default
    ) throws -> EncryptedVoiceprintSyncResult {
        try save(
            archive,
            to: url,
            keyProvider: keyProvider,
            synchronizableKey: synchronizableKey,
            fileManager: fileManager
        )
        return EncryptedVoiceprintiCloudMirror.publish(
            localEncryptedURL: url,
            fileManager: fileManager,
            configuration: syncConfiguration
        )
    }
}
