import Foundation
import StoreKit
import Observation

/// Observable trial + StoreKit unlock facade for Settings / detail UI.
/// Admission reads `ledger.isPurchaseLocked` directly (lock-safe, no MainActor).
@MainActor
@Observable
final class TrialEntitlementController {
    let ledger: TrialQuotaLedger
    private let client: any PurchaseUnlockClient
    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?
    nonisolated(unsafe) private var refreshTicker: Task<Void, Never>?

    private(set) var displayPrice: String?
    private(set) var statusMessage: String?
    private(set) var isBusy = false
    private(set) var remainingSeconds: TimeInterval
    private(set) var isUnlocked: Bool
    private(set) var trialStartedAt: Date?

    /// Invoked on the main actor after a successful unlock so the scheduler can resume.
    var onUnlocked: (@MainActor () async -> Void)?

    init(
        ledger: TrialQuotaLedger,
        client: any PurchaseUnlockClient = StoreKitPurchaseUnlockClient()
    ) {
        self.ledger = ledger
        self.client = client
        let snap = ledger.currentSnapshot()
        isUnlocked = snap.isUnlocked
        trialStartedAt = snap.trialStartedAt
        remainingSeconds = ledger.remainingSeconds
    }

    deinit {
        updatesTask?.cancel()
        refreshTicker?.cancel()
    }

    var isPurchaseLocked: Bool {
        ledger.isPurchaseLocked
    }

    /// Remaining trial as "X 小时 Y 分钟" (or minutes only when under 1 hour).
    var remainingTimeText: String {
        if isUnlocked { return "已永久解锁" }
        if trialStartedAt == nil {
            return "首次打开后 72 小时"
        }
        let total = max(0, Int(remainingSeconds.rounded(.down)))
        if total <= 0 {
            return "已到期"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            if minutes > 0 {
                return "剩余 \(hours) 小时 \(minutes) 分钟"
            }
            return "剩余 \(hours) 小时"
        }
        let shownMinutes = max(1, minutes)
        return "剩余 \(shownMinutes) 分钟"
    }

    var progressFraction: Double {
        if isUnlocked { return 1 }
        guard trialStartedAt != nil else { return 0 }
        let elapsed = TrialQuotaLedger.trialDuration - max(0, remainingSeconds)
        return min(1, max(0, elapsed / TrialQuotaLedger.trialDuration))
    }

    var availabilityCaption: String {
        if isUnlocked {
            return "已永久解锁，转写不再受试用时间限制。"
        }
        if isPurchaseLocked {
            return "音频已保存，转写等待解锁。"
        }
        if trialStartedAt == nil {
            return "首次打开应用后开始 72 小时试用；试用期内不按语音秒扣减。"
        }
        if progressFraction >= 0.9 {
            return "试用即将到期。"
        }
        return "首次打开后 72 小时内可试用，到期后可永久解锁。"
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshFromStore()
            // Only StoreKit needs the Transaction.updates listener; fakes would hang.
            if self.client is StoreKitPurchaseUnlockClient {
                await self.listenForTransactions()
            }
        }
        startRefreshTickerIfNeeded()
    }

    /// Call on every foreground active transition (FR-ADD-TRL-001).
    func noteAppBecameActive() {
        _ = ledger.ensureTrialStarted()
        publishLedger()
        startRefreshTickerIfNeeded()
    }

    func refreshFromStore() async {
        let entitled = await client.currentEntitlementActive()
        applyEntitlement(entitled)
        displayPrice = await client.loadDisplayPrice()
        publishLedger()
    }

    func purchase() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let unlocked = try await client.purchase()
            applyEntitlement(unlocked)
            if unlocked {
                statusMessage = "已永久解锁，正在继续处理。"
                await onUnlocked?()
            } else {
                statusMessage = "未检测到有效购买。"
            }
        } catch let error as PurchaseUnlockError where error == .purchaseCancelled {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
        publishLedger()
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let unlocked = try await client.restore()
            applyEntitlement(unlocked)
            if unlocked {
                statusMessage = "已恢复购买，正在继续处理。"
                await onUnlocked?()
            } else {
                statusMessage = "没有可恢复的购买。"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        publishLedger()
    }

    /// Voice-seconds billing removed; kept as a no-op for transitional call sites.
    func recordSuccessfulSubmission(jobID: UUID, utteranceSeconds: TimeInterval) {
        _ = jobID
        _ = utteranceSeconds
        publishLedger()
    }

    /// Test / DEBUG helper to force the expired boundary without waiting 72h.
    func simulateExhaustionForTesting() {
        ledger.expireTrialForTesting()
        publishLedger()
    }

    private func applyEntitlement(_ entitled: Bool) {
        ledger.setUnlocked(entitled)
        isUnlocked = entitled
    }

    private func publishLedger() {
        let snap = ledger.currentSnapshot()
        trialStartedAt = snap.trialStartedAt
        isUnlocked = snap.isUnlocked
        remainingSeconds = ledger.remainingSeconds
    }

    private func startRefreshTickerIfNeeded() {
        guard refreshTicker == nil else { return }
        refreshTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if self.isUnlocked { return }
                self.publishLedger()
            }
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case let .verified(transaction) = result else { continue }
            guard transaction.productID == TrialQuotaLedger.productID else {
                await transaction.finish()
                continue
            }
            let active = transaction.revocationDate == nil
            applyEntitlement(active)
            await transaction.finish()
            publishLedger()
            if active {
                statusMessage = "已永久解锁，正在继续处理。"
                await onUnlocked?()
            }
        }
    }
}
