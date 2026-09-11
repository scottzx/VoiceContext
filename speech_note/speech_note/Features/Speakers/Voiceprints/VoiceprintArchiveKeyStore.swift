import CryptoKit
import Foundation
import Security

/// Provides the AES-GCM key for the voiceprint archive.
/// Production keys live in Keychain; tests inject an in-memory provider.
nonisolated protocol VoiceprintArchiveKeyProviding: Sendable {
    /// Existing key only — never creates. Missing key returns nil.
    func loadExistingKey() throws -> SymmetricKey?

    /// Loads or creates a 256-bit key. `synchronizable` requests iCloud Keychain
    /// sync when the user enables encrypted voiceprint sync.
    func loadOrCreateKey(synchronizable: Bool) throws -> SymmetricKey
}

/// Deterministic in-memory key for unit tests (no Keychain side effects).
nonisolated struct InMemoryVoiceprintArchiveKeyStore: VoiceprintArchiveKeyProviding {
    private let key: SymmetricKey
    private let shouldReportMissing: Bool

    init(key: SymmetricKey = SymmetricKey(size: .bits256), missing: Bool = false) {
        self.key = key
        self.shouldReportMissing = missing
    }

    func loadExistingKey() throws -> SymmetricKey? {
        shouldReportMissing ? nil : key
    }

    func loadOrCreateKey(synchronizable: Bool) throws -> SymmetricKey {
        _ = synchronizable
        if shouldReportMissing {
            throw VoiceprintArchiveCryptoError.missingKey
        }
        return key
    }
}

nonisolated struct VoiceprintArchiveKeyStore: VoiceprintArchiveKeyProviding {
    static let shared = VoiceprintArchiveKeyStore()

    static let service = "YiJie.speech_note.voiceprint-archive"
    static let account = "aes-gcm-v1"

    private let service: String
    private let account: String

    init(
        service: String = VoiceprintArchiveKeyStore.service,
        account: String = VoiceprintArchiveKeyStore.account
    ) {
        self.service = service
        self.account = account
    }

    func loadExistingKey() throws -> SymmetricKey? {
        // Prefer synchronizable item, then local-only fallback.
        if let data = try readKeyData(synchronizable: true) {
            return try makeKey(from: data)
        }
        if let data = try readKeyData(synchronizable: false) {
            return try makeKey(from: data)
        }
        return nil
    }

    func loadOrCreateKey(synchronizable: Bool) throws -> SymmetricKey {
        if let existing = try loadExistingKey() {
            // Best-effort re-persist with the requested sync flag when enabling sync.
            if synchronizable {
                try? persist(existing, synchronizable: true)
            }
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        try persist(key, synchronizable: synchronizable)
        return key
    }

    private func makeKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else {
            throw VoiceprintArchiveCryptoError.missingKey
        }
        return SymmetricKey(data: data)
    }

    private func persist(_ key: SymmetricKey, synchronizable: Bool) throws {
        let data = key.withUnsafeBytes { Data($0) }
        // Replace any prior item (local or sync) to avoid duplicates.
        try? deleteKey(synchronizable: false)
        try? deleteKey(synchronizable: true)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceprintArchiveKeyStoreError.unexpectedStatus(status)
        }
    }

    private func readKeyData(synchronizable: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw VoiceprintArchiveKeyStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return data
    }

    private func deleteKey(synchronizable: Bool) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceprintArchiveKeyStoreError.unexpectedStatus(status)
        }
    }
}

nonisolated enum VoiceprintArchiveKeyStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "声纹档案密钥 Keychain 操作失败（status \(status)）。"
        }
    }
}
