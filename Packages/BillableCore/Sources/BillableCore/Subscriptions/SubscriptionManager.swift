import Foundation
import os
import StoreKit

/// Tri-state availability of the Lifetime (non-consumable) tier, derived purely from
/// load state + which products resolved. Lets the paywall distinguish "still loading"
/// from "the store genuinely has no transactable lifetime product" without ever
/// surfacing a price the store can't transact.
public enum LifetimeAvailability: Equatable, Sendable {
    /// Products are still being fetched (or the whole fetch came back empty / failed).
    case loading
    /// The lifetime product resolved and is transactable.
    case available
    /// Other products resolved but lifetime did NOT — a real gap (e.g. ASC product
    /// not yet approved). The paywall must hide the buy affordance for this tier.
    case unavailable
}

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
    public nonisolated static let monthlyProductID = "com.eldenstudios.billable.pro.monthly"
    public nonisolated static let yearlyProductID  = "com.eldenstudios.billable.pro.yearly"

    /// Non-consumable Lifetime IAP. Owning this grants Pro permanently and is
    /// terminal — it always wins over any subscription state. Keep in sync with
    /// `App/Resources/Billable.storekit` and App Store Connect.
    public nonisolated static let lifetimeProductID = "com.eldenstudios.billable.pro.lifetime"

    nonisolated static let logger = Logger(subsystem: "com.eldenstudios.billable", category: "Subscriptions")

    // MARK: - Load state

    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// User's current subscription state. Derived from StoreKit transactions.
    public enum Entitlement: Equatable, Sendable {
        case free
        case trial(daysRemaining: Int)
        case pro
    }

    public private(set) var loadState: LoadState = .idle {
        didSet { _onLoadStateChange?(loadState) }
    }

    public private(set) var monthly: Product?
    public private(set) var yearly: Product?
    public private(set) var lifetime: Product?
    /// True when the non-consumable lifetime entitlement is owned (terminal Pro).
    public private(set) var ownsLifetime: Bool = false

    /// The user's current entitlement. Drives all feature gates.
    public private(set) var entitlement: Entitlement = .free

    /// Back-compat: existing callers (RootView, SettingsView, etc.) still read
    /// this boolean. Derived from `entitlement`.
    public var isPro: Bool {
        switch entitlement {
        case .free: return false
        case .trial, .pro: return true
        }
    }

    /// Free users see a "Sent with Cadence" watermark on invoice PDFs.
    /// Trial + Pro users do not.
    public var canRemoveWatermark: Bool { isPro }

    /// Free users can't open Reports or export CSV.
    public var canAccessReports: Bool { isPro }

    /// Whether the user is eligible for the 7-day intro offer.
    /// Populated asynchronously in `refreshProducts()` after products load.
    /// Defaults to false until products are ready — button falls back to
    /// "Subscribe" until the eligibility check completes, which is correct UX.
    public private(set) var eligibleForIntroOffer: Bool = false

    private var transactionListener: Task<Void, Never>?

    // MARK: - Testability hooks

    /// Injected product fetcher; defaults to the real StoreKit call.
    /// Override in tests to control what products are returned (or to throw).
    /// Marked `internal` — not part of the public API.
    var _fetchProducts: @Sendable ([String]) async throws -> [Product] = { ids in
        try await Product.products(for: ids)
    }

    /// Timeout duration for `withTimeout`. Expose as `internal` so tests can
    /// reduce it (e.g. 0.5 s) to avoid multi-second waits.
    var _timeoutSeconds: TimeInterval = 5

    /// Called (on the main actor) every time `loadState` changes. Useful in
    /// tests that need to observe intermediate states (e.g. assert the manager
    /// passes through `.loading`). Leave `nil` in production — it is never set
    /// by production code. Marked `internal`.
    @MainActor var _onLoadStateChange: (@MainActor (LoadState) -> Void)?

    init() {}

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
            entitlement = .pro
        }
        if transactionListener == nil {
            transactionListener = listenForTransactionUpdates()
        }
        Task { await refreshProducts() }
        Task { await refreshEntitlements() }
    }

    /// Test-only. Sets `entitlement` directly. Not part of the public API.
    @MainActor
    public func _setEntitlementForTesting(_ value: Entitlement) {
        entitlement = value
    }

    /// Reset `loadState` to a known value. Call in test `defer` blocks to avoid
    /// state leakage between tests. Marked `internal`.
    func _resetLoadStateForTesting(_ state: LoadState = .idle) { loadState = state }

    // MARK: - Products

    /// Public alias so views can call `await manager.reloadProducts()` on retry.
    public func reloadProducts() async {
        await refreshProducts()
    }

    public func refreshProducts() async {
        loadState = .loading
        do {
            let fetcher = _fetchProducts
            let timeout = _timeoutSeconds
            let products = try await withTimeout(seconds: timeout) {
                try await fetcher([
                    Self.monthlyProductID,
                    Self.yearlyProductID,
                    Self.lifetimeProductID,
                ])
            }
            if products.isEmpty {
                loadState = .failed("Pricing unavailable. Pull to retry.")
                return
            }
            monthly = products.first { $0.id == Self.monthlyProductID }
            yearly  = products.first { $0.id == Self.yearlyProductID  }
            lifetime = products.first { $0.id == Self.lifetimeProductID }
            #if DEBUG
            if let diagnostic = Self.lifetimeDiagnostic(
                hasLifetimeProduct: lifetime != nil,
                hasAnySubscriptionProduct: monthly != nil || yearly != nil
            ) {
                Self.logger.warning("\(diagnostic, privacy: .public)")
            }
            #endif
            // Cache intro-offer eligibility. `isEligibleForIntroOffer` is async
            // (Apple checks per-Apple-ID, per subscription group), so we query
            // both products and store the result synchronously for the UI.
            let mEligible = await monthly?.subscription?.isEligibleForIntroOffer ?? false
            let yEligible = await yearly?.subscription?.isEligibleForIntroOffer ?? false
            eligibleForIntroOffer = Self.computeIntroEligibility(monthly: mEligible, yearly: yEligible)
            loadState = .ready
        } catch {
            loadState = .failed("Couldn't load products: \(error.localizedDescription)")
        }
    }

    /// Policy: user is eligible for the 7-day intro offer if EITHER product
    /// (monthly OR yearly) reports eligibility. Pure helper so the OR-logic is
    /// unit-testable independently of StoreKit (Product has no public init).
    static func computeIntroEligibility(monthly: Bool, yearly: Bool) -> Bool {
        monthly || yearly
    }

    /// Pure entitlement resolution: lifetime ownership is terminal and always
    /// wins over any subscription state; otherwise the subscription-derived
    /// state passes through (nil → .free). Unit-testable without StoreKit.
    static func resolveEntitlement(ownsLifetime: Bool, subscription: Entitlement?) -> Entitlement {
        if ownsLifetime { return .pro }
        return subscription ?? .free
    }

    /// Pure guard: decide whether the Lifetime tier should render as available,
    /// still-loading, or genuinely unavailable. We only declare `.unavailable` when
    /// the catalog is `.ready` AND at least one OTHER product resolved AND lifetime is
    /// absent — that isolates "lifetime product missing" from "the whole fetch is empty
    /// / still in flight / failed" (those stay `.loading`, owned by the existing
    /// idle/loading/failed UI). Never returns `.available` without a real product, so
    /// the caller can guarantee it never shows an untransactable price.
    ///
    /// `nonisolated` — pure computation over value types; no actor hop needed.
    public nonisolated static func lifetimeAvailability(
        loadState: LoadState,
        hasLifetimeProduct: Bool,
        hasAnySubscriptionProduct: Bool
    ) -> LifetimeAvailability {
        guard loadState == .ready else { return .loading }
        if hasLifetimeProduct { return .available }
        return hasAnySubscriptionProduct ? .unavailable : .loading
    }

    /// Pure DEBUG diagnostic message builder. Returns a non-nil string ONLY when at
    /// least one subscription resolved but the lifetime non-consumable did not — the
    /// exact "silent blank tier" condition (typically the ASC non-consumable
    /// `com.eldenstudios.billable.pro.lifetime` is not yet created/approved). Returns
    /// nil otherwise so callers never log spurious warnings during a normal empty/
    /// in-flight/failed fetch.
    public nonisolated static func lifetimeDiagnostic(
        hasLifetimeProduct: Bool,
        hasAnySubscriptionProduct: Bool
    ) -> String? {
        guard hasAnySubscriptionProduct, !hasLifetimeProduct else { return nil }
        return "Lifetime product \(lifetimeProductID) failed to resolve while subscriptions loaded. "
            + "Verify the App Store Connect non-consumable exists and is Approved/Ready to Submit. "
            + "Lifetime tier will be hidden until it resolves."
    }

    /// Race the operation against a sleep task. First to finish wins.
    ///
    /// Note: StoreKit 2's `Product.products(for:)` does NOT reliably honour Task
    /// cancellation — when the timeout fires, the operation task may continue
    /// executing on Apple's StoreKit queue until it completes naturally. This is
    /// an accepted StoreKit limitation; cancellation here is best-effort for
    /// resource cleanup, not a hard guarantee.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }   // runs on every exit (success, throw, cancel)
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
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
            // TODO: Propagate restore errors when the restore flow is redesigned
            // (tracked: clean up in a dedicated restore-flow refactor). For now we
            // swallow the error here — the caller gets `false` as the signal.
            return false
        }
    }

    // MARK: - Entitlements

    /// Trial period length in seconds. Matches the introductoryOffer P1W in
    /// Billable.storekit. Keep these in sync — if the StoreKit Config changes
    /// to P2W, update this constant too.
    private static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Returns the number of days remaining in the 7-day intro offer for the
    /// given transaction, or nil if the transaction isn't in the intro period.
    ///
    /// `Transaction.offer` requires iOS 17.2 / macOS 14.2. On older OS versions
    /// we fall back to a purchase-date heuristic: if the transaction is less than
    /// 7 days old, assume the intro offer is still active.
    private func introOfferDaysRemaining(transaction: StoreKit.Transaction) -> Int? {
        let isIntroductory: Bool
        if #available(iOS 17.2, macOS 14.2, *) {
            isIntroductory = transaction.offer?.type == .introductory
        } else {
            // Heuristic for older OS: treat purchases within the last 7 days
            // as potentially in-trial. This path is rarely hit in practice since
            // the app ships targeting iOS 17.
            let age = Date.now.timeIntervalSince(transaction.purchaseDate)
            isIntroductory = age < Self.trialDuration
        }
        guard isIntroductory else { return nil }
        let trialEndDate = transaction.purchaseDate.addingTimeInterval(Self.trialDuration)
        let now = Date.now
        guard now < trialEndDate else { return nil }
        let secondsRemaining = trialEndDate.timeIntervalSince(now)
        let daysRemaining = max(1, Int(ceil(secondsRemaining / 86_400)))
        return daysRemaining
    }

    public func refreshEntitlements() async {
        // Honor the dev override — if a tester set this on purpose, don't clobber it.
        if CommandLine.arguments.contains("--pretend-pro") {
            entitlement = .pro
            return
        }
        var foundLifetime = false
        var subscriptionState: Entitlement? = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }

            if transaction.productID == Self.lifetimeProductID,
               transaction.productType == .nonConsumable {
                foundLifetime = true
                continue
            }
            guard transaction.productType == .autoRenewable,
                  (transaction.expirationDate ?? .distantFuture) > .now,
                  transaction.productID == Self.monthlyProductID ||
                  transaction.productID == Self.yearlyProductID else { continue }
            if let days = introOfferDaysRemaining(transaction: transaction) {
                subscriptionState = .trial(daysRemaining: days)
            } else {
                subscriptionState = .pro
            }
        }
        ownsLifetime = foundLifetime
        entitlement = Self.resolveEntitlement(ownsLifetime: foundLifetime, subscription: subscriptionState)
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

}
