import Foundation
import Security

/// Durable 72-hour wall-clock trial ledger. No business server.
///
/// Trial starts on the first app foreground open, persists start time via
/// local file + Keychain dual-write (reinstall resistance), and does **not**
/// deduct ASR voice-seconds. Unlock is a local flag mirrored from StoreKit 2
/// non-consumable entitlement.
nonisolated final class TrialQuotaLedger: @unchecked Sendable {
    /// 72-hour (3-day) trial enabled with StoreKit 2 integration.
    static let isManualTrialEnabled = true
    static let trialDuration: TimeInterval = 72 * 60 * 60
    static let productID = "YiJie.speech-note.lifetimeUnlock"
    static let subscriptionProductID = "YiJie.speech-note.subscription.yearly"
    static let supportedProductIDs: Set<String> = [productID, subscriptionProductID]
    static let currentSchemaVersion = 2

    struct Snapshot: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var trialStartedAt: Date?
        /// Monotonic-ish elapsed watermark so clock rollback cannot extend trial.
        var maxObservedElapsed: TimeInterval
        var isUnlocked: Bool
        /// Preserved from the v1 60-minute voice-seconds ledger for audit only.
        var legacyUsedSeconds: TimeInterval?
        var legacyBilledJobIDs: [String]?

        static let empty = Snapshot(
            schemaVersion: TrialQuotaLedger.currentSchemaVersion,
            trialStartedAt: nil,
            maxObservedElapsed: 0,
            isUnlocked: false,
            legacyUsedSeconds: nil,
            legacyBilledJobIDs: nil
        )
    }

    /// Decodes both v2 clock snapshots and legacy v1 voice-seconds quota files.
    private struct FlexibleSnapshotDecoder {
        static func decode(_ data: Data) throws -> Snapshot {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                return .empty
            }

            let isUnlocked = dict["isUnlocked"] as? Bool ?? false
            if dict["trialStartedAt"] != nil || dict["schemaVersion"] as? Int == TrialQuotaLedger.currentSchemaVersion {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = try? decoder.decode(Snapshot.self, from: data) {
                    return decoded
                }
            }

            // Legacy v1: { usedSeconds, billedJobIDs, isUnlocked }
            let used = dict["usedSeconds"] as? Double ?? 0
            let billed = dict["billedJobIDs"] as? [String]
            return Snapshot(
                schemaVersion: TrialQuotaLedger.currentSchemaVersion,
                trialStartedAt: nil,
                maxObservedElapsed: 0,
                isUnlocked: isUnlocked,
                legacyUsedSeconds: used,
                legacyBilledJobIDs: billed
            )
        }
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let keychain: any TrialStartTimestampStoring
    private let now: @Sendable () -> Date
    private var snapshot: Snapshot

    init(
        fileURL: URL,
        keychain: any TrialStartTimestampStoring = KeychainTrialStartTimestampStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.now = now

        var loaded = Snapshot.empty
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? FlexibleSnapshotDecoder.decode(data) {
            loaded = decoded
        }

        // Prefer the earlier of file / Keychain start stamps (FR-ADD-TRL-001 dual-write).
        if let keychainStart = try? keychain.load() {
            if let fileStart = loaded.trialStartedAt {
                loaded.trialStartedAt = min(fileStart, keychainStart)
            } else {
                loaded.trialStartedAt = keychainStart
            }
        }

        loaded.schemaVersion = Self.currentSchemaVersion
        snapshot = loaded
        // Persist migrated shape so subsequent boots are v2-native.
        persistLocked()
        syncKeychainLocked()
    }

    convenience init(applicationSupportBase: URL = TrialQuotaLedger.defaultApplicationSupportBase()) {
        let directory = applicationSupportBase.appendingPathComponent("Trial", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(fileURL: directory.appendingPathComponent("quota.json"))
    }

    static func defaultApplicationSupportBase() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("VoiceContext", isDirectory: true)
    }

    /// First foreground open after install/upgrade starts the 72h clock once.
    @discardableResult
    func ensureTrialStarted(at date: Date? = nil) -> Date {
        let instant = date ?? now()
        lock.lock()
        defer { lock.unlock() }
        if let existing = snapshot.trialStartedAt {
            refreshElapsedLocked(at: instant)
            persistLocked()
            return existing
        }
        snapshot.trialStartedAt = instant
        snapshot.maxObservedElapsed = 0
        persistLocked()
        syncKeychainLocked()
        return instant
    }

    var trialStartedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.trialStartedAt
    }

    var remainingSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return remainingSecondsLocked(at: now())
    }

    var elapsedSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsedSecondsLocked(at: now())
    }

    var isUnlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.isUnlocked
    }

    /// Admission gate sample — safe to call from any executor.
    var isPurchaseLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        if snapshot.isUnlocked { return false }
        guard snapshot.trialStartedAt != nil else {
            // Clock not started yet (pre-first-open); admit so cold start can proceed
            // until scenePhase active seals the start stamp.
            return false
        }
        return remainingSecondsLocked(at: now()) <= 0
    }

    func currentSnapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        refreshElapsedLocked(at: now())
        return snapshot
    }

    /// Voice-seconds billing removed (FR-ADD-TRL-002). Kept as a no-op so older
    /// call sites compile until fully deleted.
    @discardableResult
    func recordUsage(jobID: UUID, seconds: TimeInterval) -> Bool {
        _ = jobID
        _ = seconds
        return false
    }

    func markUnlocked() {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshot.isUnlocked else { return }
        snapshot.isUnlocked = true
        persistLocked()
    }

    func setUnlocked(_ unlocked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.isUnlocked != unlocked else { return }
        snapshot.isUnlocked = unlocked
        persistLocked()
    }

    /// Test helper: force trial start into the past so the lock boundary trips.
    func replaceTrialStartedAtForTesting(_ date: Date?) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.trialStartedAt = date
        snapshot.maxObservedElapsed = 0
        if let date {
            snapshot.maxObservedElapsed = max(0, now().timeIntervalSince(date))
        }
        persistLocked()
        syncKeychainLocked()
    }

    /// Test helper: expire the trial immediately without inventing ASR usage.
    func expireTrialForTesting() {
        replaceTrialStartedAtForTesting(now().addingTimeInterval(-(Self.trialDuration + 1)))
    }

    /// Test helper: reset the trial to start right now and wipe old Keychain timestamps.
    func resetTrialForTesting(at date: Date? = nil) {
        let start = date ?? now()
        lock.lock()
        defer { lock.unlock() }
        try? keychain.clear()
        try? keychain.save(start)
        snapshot.trialStartedAt = start
        snapshot.maxObservedElapsed = 0
        snapshot.isUnlocked = false
        persistLocked()
    }

    private func remainingSecondsLocked(at date: Date) -> TimeInterval {
        if snapshot.isUnlocked { return .infinity }
        guard snapshot.trialStartedAt != nil else {
            return Self.trialDuration
        }
        return max(0, Self.trialDuration - elapsedSecondsLocked(at: date))
    }

    private func elapsedSecondsLocked(at date: Date) -> TimeInterval {
        guard let start = snapshot.trialStartedAt else { return 0 }
        let wall = max(0, date.timeIntervalSince(start))
        // Clock moved backwards: keep the watermark so trial cannot be extended.
        let elapsed = max(wall, snapshot.maxObservedElapsed)
        if elapsed > snapshot.maxObservedElapsed {
            snapshot.maxObservedElapsed = elapsed
        }
        return min(elapsed, Self.trialDuration + 1)
    }

    private func refreshElapsedLocked(at date: Date) {
        _ = elapsedSecondsLocked(at: date)
    }

    private func persistLocked() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    private func syncKeychainLocked() {
        guard let start = snapshot.trialStartedAt else { return }
        try? keychain.save(start)
    }
}

// MARK: - Keychain dual-write

nonisolated protocol TrialStartTimestampStoring: Sendable {
    func load() throws -> Date?
    func save(_ date: Date) throws
    func clear() throws
}

/// In-memory store for unit tests (no Keychain side effects).
nonisolated final class InMemoryTrialStartTimestampStore: TrialStartTimestampStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    init(value: Date? = nil) {
        self.value = value
    }

    func load() throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func save(_ date: Date) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = value {
            value = min(existing, date)
        } else {
            value = date
        }
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}

nonisolated struct KeychainTrialStartTimestampStore: TrialStartTimestampStoring {
    static let service = "YiJie.speech-note.trial"
    static let account = "first-open-v1"

    private let service: String
    private let account: String

    init(
        service: String = KeychainTrialStartTimestampStore.service,
        account: String = KeychainTrialStartTimestampStore.account
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> Date? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TrialStartTimestampStoreError.unexpectedStatus(status)
        }
        guard let string = String(data: data, encoding: .utf8),
              let interval = TimeInterval(string) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func save(_ date: Date) throws {
        // Keep the earliest stamp if one already exists.
        if let existing = try load(), existing <= date {
            return
        }
        try? clear()
        let payload = String(date.timeIntervalSince1970).data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecValueData as String: payload,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TrialStartTimestampStoreError.unexpectedStatus(status)
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrialStartTimestampStoreError.unexpectedStatus(status)
        }
    }
}

nonisolated enum TrialStartTimestampStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "试用起点 Keychain 操作失败（status \(status)）。"
        }
    }
}
