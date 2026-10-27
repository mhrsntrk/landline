import Foundation
import Observation
import StoreKit

struct PurchaseProduct: Equatable {
    let id: String
    let displayPrice: String
    let price: Decimal
}

enum PurchaseOutcome { case purchased, cancelled, pending }

@MainActor protocol PurchaseClient {
    func products() async throws -> [PurchaseProduct]
    func entitlements() async throws -> PurchaseEntitlements
    func purchase(_ id: String) async throws -> PurchaseOutcome
    func restore() async throws
    func listenForUpdates(_ receive: @escaping @MainActor () async -> Void) -> Task<Void, Never>
}

enum PurchaseFailure: LocalizedError {
    case unavailable, unverified
    var errorDescription: String? {
        switch self {
        case .unavailable: "The App Store couldn't load this purchase. Check your connection and try again."
        case .unverified: "The App Store couldn't verify your purchase. Try Restore purchases. Your hosts and settings are safe."
        }
    }
}

@MainActor final class StoreKitPurchaseClient: PurchaseClient {
    private var loaded: [String: Product] = [:]
    func products() async throws -> [PurchaseProduct] {
        let products = try await Product.products(for: LandlineProducts.all)
            .filter { $0.type == .nonConsumable }
        loaded = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products.map { PurchaseProduct(id: $0.id, displayPrice: $0.displayPrice, price: $0.price) }
    }

    func entitlements() async throws -> PurchaseEntitlements {
        var result = PurchaseEntitlements()
        for await verification in Transaction.currentEntitlements {
            guard LandlineProducts.all.contains(verification.unsafePayloadValue.productID) else { continue }
            let transaction = try verified(verification)
            guard transaction.revocationDate == nil, transaction.productType == .nonConsumable else { continue }
            if transaction.productID == LandlineProducts.unlock { result.unlocked = true }
        }
        // A restored or revoked trial remains used. Never restart its seven-day clock.
        if let latest = await Transaction.latest(for: LandlineProducts.trial) {
            let trial = try verified(latest)
            guard trial.productID == LandlineProducts.trial, trial.productType == .nonConsumable else {
                throw PurchaseFailure.unverified
            }
            result.trialStartedAt = trial.originalPurchaseDate
            result.trialRevoked = trial.revocationDate != nil
        }
        if !result.unlocked {
            // Apple's signed app transaction preserves access for everyone who
            // acquired Landline before this model, including the free launch.
            // Never use an install date or a writable defaults flag as proof.
            do {
                let verification = try await AppTransaction.shared
                guard case .verified(let app) = verification,
                      app.bundleID == "com.landlineclient.app" else {
                    throw PurchaseFailure.unverified
                }
                result.unlocked = LandlineAccess.isExistingCustomer(
                    originalAppVersion: app.originalAppVersion,
                    isProduction: app.environment == .production)
            } catch {
                // A verified trial is usable even if the app receipt is temporarily unavailable.
                guard result.trialStartedAt != nil else { throw error }
            }
        }
        return result
    }

    func purchase(_ id: String) async throws -> PurchaseOutcome {
        guard let product = loaded[id], LandlineProducts.all.contains(id),
            id != LandlineProducts.trial || product.price == 0
        else { throw PurchaseFailure.unavailable }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            guard transaction.productID == id, transaction.revocationDate == nil else {
                throw PurchaseFailure.unverified
            }
            // Entitlements live in StoreKit's signed local transaction history, not a defaults flag.
            _ = try await entitlements()
            await transaction.finish()
            return .purchased
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw PurchaseFailure.unavailable
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        _ = try await AppTransaction.refresh()
    }

    func listenForUpdates(_ receive: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task {
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = verification,
                    LandlineProducts.all.contains(transaction.productID)
                else { continue }
                await receive()
                await transaction.finish()
            }
        }
    }

    private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        guard case .verified(let transaction) = result else { throw PurchaseFailure.unverified }
        return transaction
    }
}

@MainActor @Observable
final class Purchases {
    let access: LandlineAccess
    private(set) var products: [PurchaseProduct] = []
    private(set) var isBusy = false
    private(set) var isLoadingProducts = false
    private(set) var message: String?
    @ObservationIgnored private let client: any PurchaseClient
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var refreshRevision = 0

    init(access: LandlineAccess, client: (any PurchaseClient)? = nil) {
        self.access = access
        self.client = client ?? StoreKitPurchaseClient()
    }

    var unlockProduct: PurchaseProduct? { products.first { $0.id == LandlineProducts.unlock } }
    var canStartTrial: Bool {
        access.status() == .trialAvailable && unlockProduct != nil
            && products.contains { $0.id == LandlineProducts.trial && $0.price == 0 }
    }

    func start() {
        guard updates == nil else { return }
        updates = client.listenForUpdates { [weak self] in await self?.refresh() }
    }

    func stop() {
        updates?.cancel()
        updates = nil
    }

    func reload() async {
        await refresh()
        await loadProducts()
    }

    @discardableResult func refresh() async -> Bool {
        refreshRevision += 1
        let revision = refreshRevision
        do {
            let entitlements = try await client.entitlements()
            guard revision == refreshRevision, !Task.isCancelled else { return false }
            access.update(entitlements)
            message = nil
            return true
        } catch {
            guard revision == refreshRevision, !Task.isCancelled else { return false }
            // A transient read failure must not discard an already verified purchase.
            message = error.localizedDescription
            return false
        }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await client.products()
            if unlockProduct == nil {
                message = PurchaseFailure.unavailable.localizedDescription
            }
        } catch { message = error.localizedDescription }
    }

    func startTrial() async {
        guard canStartTrial else { return }
        await purchase(LandlineProducts.trial)
    }

    func unlock() async {
        guard unlockProduct != nil, access.status() != .unlocked, access.status() != .checking else { return }
        await purchase(LandlineProducts.unlock)
    }

    private func purchase(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            switch try await client.purchase(id) {
            case .purchased:
                if await refresh(), access.hasFullAccess() { message = "Landline is ready. Every feature is unlocked." }
            case .pending:
                message = "Waiting for App Store approval. Landline will unlock when the purchase is approved."
            case .cancelled: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await client.restore()
            guard await refresh() else { return }
            switch access.status() {
            case .unlocked: message = "Your purchase is restored. Welcome back."
            case .trial: message = "Your original trial is restored."
            case .expired: message = "Your trial has ended. No full unlock was found for this Apple Account."
            case .trialAvailable: message = "No purchase was found for this Apple Account."
            case .checking: break
            }
        } catch { message = error.localizedDescription }
    }
}
