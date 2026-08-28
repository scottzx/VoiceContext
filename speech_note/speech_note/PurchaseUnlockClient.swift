import Foundation
import StoreKit

enum PurchaseUnlockError: LocalizedError, Equatable {
    case productUnavailable
    case purchasePending
    case purchaseCancelled
    case verificationFailed
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "暂时无法获取永久解锁商品，请稍后重试。"
        case .purchasePending:
            "购买待批准，批准后将自动解锁。"
        case .purchaseCancelled:
            "已取消购买。"
        case .verificationFailed:
            "无法验证购买凭证。"
        case let .storeUnavailable(message):
            "App Store 暂不可用：\(message)"
        }
    }
}

/// Abstract StoreKit surface so unit tests can unlock without device signing
/// or a live App Store session.
protocol PurchaseUnlockClient: Sendable {
    func currentEntitlementActive() async -> Bool
    func loadDisplayPrice() async -> String?
    func purchase() async throws -> Bool
    func restore() async throws -> Bool
}

struct StoreKitPurchaseUnlockClient: PurchaseUnlockClient {
    let productID: String

    init(productID: String = TrialQuotaLedger.productID) {
        self.productID = productID
    }

    func currentEntitlementActive() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if (transaction.productID == productID || TrialQuotaLedger.supportedProductIDs.contains(transaction.productID)),
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func loadDisplayPrice() async -> String? {
        do {
            let products = try await Product.products(for: [productID])
            return products.first?.displayPrice
        } catch {
            return nil
        }
    }

    func purchase() async throws -> Bool {
        let products = try await Product.products(for: [productID])
        guard let product = products.first(where: { $0.id == productID }) else {
            throw PurchaseUnlockError.productUnavailable
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw PurchaseUnlockError.storeUnavailable(error.localizedDescription)
        }
        switch result {
        case let .success(verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            return (transaction.productID == productID || TrialQuotaLedger.supportedProductIDs.contains(transaction.productID)) && transaction.revocationDate == nil
        case .userCancelled:
            throw PurchaseUnlockError.purchaseCancelled
        case .pending:
            throw PurchaseUnlockError.purchasePending
        @unknown default:
            throw PurchaseUnlockError.storeUnavailable("未知购买结果")
        }
    }

    func restore() async throws -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            // Sync can fail offline; still inspect local entitlements.
        }
        return await currentEntitlementActive()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseUnlockError.verificationFailed
        case let .verified(safe):
            return safe
        }
    }
}

/// Deterministic stand-in for StoreKit Testing / unit tests.
final class FakePurchaseUnlockClient: PurchaseUnlockClient, @unchecked Sendable {
    private let lock = NSLock()
    private var entitled: Bool
    var shouldFailPurchase: Bool
    var shouldFailRestore: Bool
    private let price: String

    init(
        entitled: Bool = false,
        shouldFailPurchase: Bool = false,
        shouldFailRestore: Bool = false,
        price: String = "¥30"
    ) {
        self.entitled = entitled
        self.shouldFailPurchase = shouldFailPurchase
        self.shouldFailRestore = shouldFailRestore
        self.price = price
    }

    func setEntitled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        entitled = value
    }

    func currentEntitlementActive() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entitled
    }

    func loadDisplayPrice() async -> String? { price }

    func purchase() async throws -> Bool {
        if shouldFailPurchase {
            throw PurchaseUnlockError.storeUnavailable("模拟商店离线")
        }
        setEntitled(true)
        return true
    }

    func restore() async throws -> Bool {
        if shouldFailRestore {
            throw PurchaseUnlockError.storeUnavailable("模拟恢复失败")
        }
        return await currentEntitlementActive()
    }
}
