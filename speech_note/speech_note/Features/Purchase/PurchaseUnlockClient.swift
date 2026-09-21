import Foundation
import StoreKit
import UIKit

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

    /// Maps StoreKit / SKError / Task cancellation into the surface the paywall
    /// shows. User cancellation must not appear as a store failure — App Review
    /// treated that banner as a purchase bug on iPad.
    static func fromStoreFailure(_ error: Error) -> PurchaseUnlockError {
        if error is CancellationError {
            return .purchaseCancelled
        }
        if let storeKit = error as? StoreKitError {
            switch storeKit {
            case .userCancelled:
                return .purchaseCancelled
            case .notAvailableInStorefront:
                return .productUnavailable
            default:
                return .storeUnavailable(storeKit.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == SKError.errorDomain,
           nsError.code == SKError.Code.paymentCancelled.rawValue {
            return .purchaseCancelled
        }
        return .storeUnavailable(error.localizedDescription)
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
    private let sharedKeychain: any SharedKeychainEntitlementStoring

    init(
        productID: String = TrialQuotaLedger.productID,
        sharedKeychain: any SharedKeychainEntitlementStoring = SharedKeychainEntitlementStore.shared
    ) {
        self.productID = productID
        self.sharedKeychain = sharedKeychain
    }

    func currentEntitlementActive() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if (transaction.productID == productID || TrialQuotaLedger.supportedProductIDs.contains(transaction.productID)),
               transaction.revocationDate == nil {
                return true
            }
        }
        if let shared = try? sharedKeychain.loadSharedUnlock(), !shared.productID.isEmpty {
            return true
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
        let product = try await loadProduct()
        let result: Product.PurchaseResult
        do {
            result = try await purchaseConfirmingInActiveScene(product)
        } catch {
            throw PurchaseUnlockError.fromStoreFailure(error)
        }
        switch result {
        case let .success(verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            let isEntitled = (transaction.productID == productID || TrialQuotaLedger.supportedProductIDs.contains(transaction.productID)) && transaction.revocationDate == nil
            if isEntitled {
                try? sharedKeychain.saveSharedUnlock(SharedUnlockRecord(productID: transaction.productID))
            }
            return isEntitled
        case .userCancelled:
            throw PurchaseUnlockError.purchaseCancelled
        case .pending:
            throw PurchaseUnlockError.purchasePending
        @unknown default:
            throw PurchaseUnlockError.storeUnavailable("未知购买结果")
        }
    }

    private func loadProduct() async throws -> Product {
        var lastError: Error?
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(400))
            }
            do {
                let products = try await Product.products(for: [productID])
                if let product = products.first(where: { $0.id == productID }) {
                    return product
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw PurchaseUnlockError.fromStoreFailure(lastError)
        }
        throw PurchaseUnlockError.productUnavailable
    }

    /// iPhone apps running on iPad often fail `product.purchase()` unless the
    /// confirmation sheet is anchored to the active window scene.
    @MainActor
    private func purchaseConfirmingInActiveScene(_ product: Product) async throws -> Product.PurchaseResult {
        if let scene = Self.activeWindowScene() {
            return try await product.purchase(confirmIn: scene)
        }
        return try await product.purchase()
    }

    @MainActor
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
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
    var shouldCancelPurchase: Bool
    var shouldFailRestore: Bool
    private let price: String
    private let sharedKeychain: (any SharedKeychainEntitlementStoring)?

    init(
        entitled: Bool = false,
        shouldFailPurchase: Bool = false,
        shouldCancelPurchase: Bool = false,
        shouldFailRestore: Bool = false,
        price: String = "¥30",
        sharedKeychain: (any SharedKeychainEntitlementStoring)? = nil
    ) {
        self.entitled = entitled
        self.shouldFailPurchase = shouldFailPurchase
        self.shouldCancelPurchase = shouldCancelPurchase
        self.shouldFailRestore = shouldFailRestore
        self.price = price
        self.sharedKeychain = sharedKeychain
    }

    func setEntitled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        entitled = value
        if value {
            try? sharedKeychain?.saveSharedUnlock(SharedUnlockRecord(productID: TrialQuotaLedger.productID))
        }
    }

    func currentEntitlementActive() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entitled { return true }
        if let shared = try? sharedKeychain?.loadSharedUnlock(), !shared.productID.isEmpty {
            return true
        }
        return false
    }

    func loadDisplayPrice() async -> String? { price }

    func purchase() async throws -> Bool {
        if shouldCancelPurchase {
            throw PurchaseUnlockError.purchaseCancelled
        }
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
