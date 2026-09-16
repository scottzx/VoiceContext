import Foundation
import Security

struct SharedUnlockRecord: Codable, Equatable, Sendable {
    let productID: String
    let unlockedAt: Date
    let sourceBundleID: String

    init(
        productID: String = TrialQuotaLedger.productID,
        unlockedAt: Date = Date(),
        sourceBundleID: String = Bundle.main.bundleIdentifier ?? "unknown"
    ) {
        self.productID = productID
        self.unlockedAt = unlockedAt
        self.sourceBundleID = sourceBundleID
    }
}

protocol SharedKeychainEntitlementStoring: Sendable {
    func loadSharedUnlock() throws -> SharedUnlockRecord?
    func saveSharedUnlock(_ record: SharedUnlockRecord) throws
    func clearSharedUnlock() throws
}

struct SharedKeychainEntitlementStore: SharedKeychainEntitlementStoring {
    static let shared = SharedKeychainEntitlementStore()

    static let defaultService = "YiJie.shared.entitlements"
    static let defaultAccount = "lifetimeUnlock"
    static let defaultAccessGroup = "3HJ3R6SXAL.com.yijie.shared_entitlements"

    private let service: String
    private let account: String
    private let accessGroup: String?

    init(
        service: String = defaultService,
        account: String = defaultAccount,
        accessGroup: String? = defaultAccessGroup
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func loadSharedUnlock() throws -> SharedUnlockRecord? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedUnlockRecord.self, from: data)
    }

    func saveSharedUnlock(_ record: SharedUnlockRecord) throws {
        try? clearSharedUnlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            return
        }
        guard status == errSecSuccess else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
    }

    func clearSharedUnlock() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
    }
}

final class InMemorySharedKeychainEntitlementStore: SharedKeychainEntitlementStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: SharedUnlockRecord?

    init(record: SharedUnlockRecord? = nil) {
        self.record = record
    }

    func loadSharedUnlock() throws -> SharedUnlockRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    func saveSharedUnlock(_ record: SharedUnlockRecord) throws {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }

    func clearSharedUnlock() throws {
        lock.lock(); defer { lock.unlock() }
        self.record = nil
    }
}

enum SharedKeychainStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Shared Keychain error: \(status)"
        }
    }
}
