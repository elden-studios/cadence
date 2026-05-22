import Foundation
import StoreKit

/// Observable hub for Billable Pro subscriptions (StoreKit 2).
///
/// Holds the loaded products, tracks the user's current entitlement, and
/// vends a single `isPro` boolean that views can gate features against.
/// One instance lives in the app target; views read it via `@Environment` or
/// the `.shared` singleton.
@MainActor
@Observable
public final class SubscriptionManager {
    public static let shared = SubscriptionManager()

    /// Product identifiers we ship in v1. Order matters — first is monthly,
    /// second is yearly. Keep in sync with `App/Resources/Billable.storekit`
    /// and App Store Connect when we file the real ones.
    public static let monthlyProductID = "com.eldenstudios.billable.pro.monthly"
    public static let yearlyProductID  = "com.eldenstudios.billable.pro.yearly"

    public private(set) var monthly: Product?
    public private(set) var yearly: Product?
    public private(set) var isPro: Bool = false
    public private(set) var isLoadingProducts: Bool = false
    public private(set) var lastError: String?

    private var transactionListener: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch. Loads products, refreshes entitlements,
    /// and starts the long-lived transaction observer.
    ///
    /// We deliberately don't tear down the listener — the singleton lives for
    /// the whole app lifetime, so a deinit would never fire in normal use, and
    /// Swift 6 strict concurrency would force us to redesign for the rare test
    /// path where it might.
    public func start() {
        // Dev escape hatch: `--pretend-pro` flips entitlement to true without
        // going through StoreKit Testing, so QA can screenshot Pro-gated
        // surfaces (Reports, CSV) without an active sandbox account.
        if CommandLine.arguments.contains("--pretend-pro") {
            isPro = true
        }
        if transactionListener == nil {
            transactionListener = listenForTransactionUpdates()
        }
        Task { await refreshProducts() }
        Task { await refreshEntitlements() }
    }

    /// Override only in tests. Refreshing entitlements after this flip clobbers
    /// it, so use sparingly. The `--pretend-pro` flag handles 99% of dev needs.
    public func _forceIsProForTesting(_ value: Bool) { isPro = value }

    // MARK: - Products

    public func refreshProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [
                Self.monthlyProductID,
                Self.yearlyProductID,
            ])
            monthly = products.first { $0.id == Self.monthlyProductID }
            yearly  = products.first { $0.id == Self.yearlyProductID  }
            lastError = nil
        } catch {
            lastError = "Couldn't load products: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    public enum PurchaseOutcome: Equatable {
        case success
        case pending
        case userCancelled
        case failed(String)
    }

    public func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    return .success
                case .unverified(_, let error):
                    return .failed("Couldn't verify the purchase: \(error.localizedDescription)")
                }
            case .userCancelled:
                return .userCancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("Unknown purchase result.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    public func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            return isPro
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Entitlements

    public func refreshEntitlements() async {
        // Honor the dev override — if a tester set this on purpose, don't clobber it.
        if CommandLine.arguments.contains("--pretend-pro") {
            isPro = true
            return
        }
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // Only auto-renewable subscriptions in v1; treat any verified active
            // entry in our group as Pro.
            if transaction.productType == .autoRenewable,
               transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > .now {
                entitled = true
            }
        }
        isPro = entitled
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }

    // MARK: - Convenience

    /// True when the Yearly product offers a free trial (e.g. our 7-day intro).
    public var yearlyHasFreeTrial: Bool {
        guard let yearly else { return false }
        if let offer = yearly.subscription?.introductoryOffer,
           offer.paymentMode == .freeTrial {
            return true
        }
        return false
    }

    public var yearlyTrialPeriodLabel: String? {
        guard let yearly,
              let offer = yearly.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let unit = offer.period.unit
        let count = offer.period.value
        let unitLabel: String = {
            switch unit {
            case .day: return count == 1 ? "day" : "days"
            case .week: return count == 1 ? "week" : "weeks"
            case .month: return count == 1 ? "month" : "months"
            case .year: return count == 1 ? "year" : "years"
            @unknown default: return ""
            }
        }()
        return "\(count)-\(unitLabel) free trial"
    }
}
