import CryptoKit
import Foundation
import Testing
@testable import speech_note

struct EncryptedVoiceprintArchiveTests {
    @Test func correctKeyDecryptsRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Alice", embeddings: [[1, 0, 0]]),
        ])
        let envelope = try VoiceprintArchiveCrypto.seal(archive, using: key)
        let opened = try VoiceprintArchiveCrypto.open(envelope, using: key)
        #expect(opened == archive)
        #expect(envelope.format == EncryptedVoiceprintEnvelope.currentFormat)
        #expect(!envelope.sealedBox.isEmpty)
    }

    @Test func wrongOrMissingKeyFailsSafely() throws {
        let good = SymmetricKey(size: .bits256)
        let bad = SymmetricKey(size: .bits256)
        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Bob", embeddings: [[0, 1]]),
        ])
        let envelope = try VoiceprintArchiveCrypto.seal(archive, using: good)

        #expect(throws: VoiceprintArchiveCryptoError.authenticationFailed) {
            _ = try VoiceprintArchiveCrypto.open(envelope, using: bad)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-missing-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(VoiceprintArchiveStorage.fileName)
        let provider = InMemoryVoiceprintArchiveKeyStore(key: good)
        try VoiceprintArchiveStorage.save(archive, to: url, keyProvider: provider)

        let missing = InMemoryVoiceprintArchiveKeyStore(missing: true)
        #expect(throws: VoiceprintArchiveCryptoError.missingKey) {
            _ = try VoiceprintArchiveStorage.load(from: url, keyProvider: missing)
        }
    }

    @Test func ciphertextTamperingIsDetected() throws {
        let key = SymmetricKey(size: .bits256)
        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Eve", embeddings: [[0, 0, 1]]),
        ])
        var envelope = try VoiceprintArchiveCrypto.seal(archive, using: key)
        #expect(!envelope.sealedBox.isEmpty)
        // Flip a byte inside the sealed box (AES-GCM auth tag must reject).
        var bytes = [UInt8](envelope.sealedBox)
        let index = bytes.count / 2
        bytes[index] ^= 0x5A
        envelope.sealedBox = Data(bytes)

        #expect(throws: VoiceprintArchiveCryptoError.authenticationFailed) {
            _ = try VoiceprintArchiveCrypto.open(envelope, using: key)
        }
    }

    @Test func syncDisabledLeavesNoCloudArchive() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("vp-sync-\(UUID().uuidString)", isDirectory: true)
        let localDir = root.appendingPathComponent("local", isDirectory: true)
        let cloudRoot = root.appendingPathComponent("ubiquity", isDirectory: true)
        try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let localURL = localDir.appendingPathComponent(VoiceprintArchiveStorage.fileName)
        let keyStore = InMemoryVoiceprintArchiveKeyStore()
        let archive = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Carol", embeddings: [[1, 0]]),
        ])

        // First publish with sync ON → cloud file exists.
        let enabledConfig = EncryptedVoiceprintiCloudMirror.Configuration(
            isEncryptedVoiceprintSyncEnabled: { true },
            ubiquityContainerURL: { cloudRoot }
        )
        let enabled = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: localURL,
            keyProvider: keyStore,
            synchronizableKey: true,
            syncConfiguration: enabledConfig,
            fileManager: fileManager
        )
        #expect(enabled.destination == .iCloud)
        #expect(EncryptedVoiceprintiCloudMirror.cloudArchiveExists(
            fileManager: fileManager,
            configuration: enabledConfig
        ))

        // Sync OFF → remove cloud archive; local encrypted file remains.
        let disabledConfig = EncryptedVoiceprintiCloudMirror.Configuration(
            isEncryptedVoiceprintSyncEnabled: { false },
            ubiquityContainerURL: { cloudRoot }
        )
        let disabled = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: localURL,
            keyProvider: keyStore,
            synchronizableKey: false,
            syncConfiguration: disabledConfig,
            fileManager: fileManager
        )
        #expect(disabled.destination == .removed || disabled.destination == .localOnly)
        #expect(disabled.fallbackReason == "encryptedVoiceprintSyncDisabled")
        #expect(!EncryptedVoiceprintiCloudMirror.cloudArchiveExists(
            fileManager: fileManager,
            configuration: disabledConfig
        ))
        #expect(fileManager.fileExists(atPath: localURL.path))

        let loaded = try VoiceprintArchiveStorage.load(from: localURL, keyProvider: keyStore)
        #expect(loaded.identities.first?.displayName == "Carol")
    }

    @Test func ubiquityUnavailableKeepsEncryptedArchiveLocalOnly() throws {
        let fileManager = FileManager.default
        let localDir = fileManager.temporaryDirectory
            .appendingPathComponent("vp-local-only-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: localDir) }

        let localURL = localDir.appendingPathComponent(VoiceprintArchiveStorage.fileName)
        let keyStore = InMemoryVoiceprintArchiveKeyStore()
        var archive = VoiceprintArchive()
        archive.upsert(VoiceprintIdentity(displayName: "Dana", embeddings: [[0, 1]]))

        let result = try VoiceprintArchiveStorage.saveAndSync(
            archive,
            to: localURL,
            keyProvider: keyStore,
            synchronizableKey: true,
            syncConfiguration: EncryptedVoiceprintiCloudMirror.Configuration(
                isEncryptedVoiceprintSyncEnabled: { true },
                ubiquityContainerURL: { nil }
            ),
            fileManager: fileManager
        )
        #expect(result.destination == .localOnly)
        #expect(
            result.fallbackReason == "ubiquityContainerUnavailable"
                || result.fallbackReason == "icloudAccountUnavailable"
        )
        #expect(fileManager.fileExists(atPath: localURL.path))

        // Local bytes are an envelope, not plaintext identities JSON.
        let data = try Data(contentsOf: localURL)
        #expect(!VoiceprintArchiveCrypto.looksLikeLegacyPlaintextArchive(data))
        let envelope = try VoiceprintArchiveCrypto.decodeEnvelope(from: data)
        #expect(envelope.format == EncryptedVoiceprintEnvelope.currentFormat)
    }

    @Test func legacyPlaintextMigratesOnSave() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("vp-migrate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent(VoiceprintArchiveStorage.legacyPlaintextFileName)
        let encryptedURL = directory.appendingPathComponent(VoiceprintArchiveStorage.fileName)
        let original = VoiceprintArchive(identities: [
            VoiceprintIdentity(displayName: "Legacy", embeddings: [[1, 0]]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(original).write(to: legacyURL, options: .atomic)

        let keyStore = InMemoryVoiceprintArchiveKeyStore()
        let loaded = try VoiceprintArchiveStorage.load(from: encryptedURL, keyProvider: keyStore)
        #expect(loaded.identities.first?.displayName == "Legacy")

        try VoiceprintArchiveStorage.save(loaded, to: encryptedURL, keyProvider: keyStore)
        #expect(fileManager.fileExists(atPath: encryptedURL.path))
        #expect(!fileManager.fileExists(atPath: legacyURL.path))
    }

    @Test func cloudPathIsPrivateNotPublicVoiceContextRoot() {
        #expect(EncryptedVoiceprintiCloudMirror.cloudRelativePath.hasPrefix("Private/"))
        #expect(!PublicDocumentContainer.isAllowedPublicRelativePath(
            EncryptedVoiceprintiCloudMirror.cloudRelativePath
        ))
    }
}
