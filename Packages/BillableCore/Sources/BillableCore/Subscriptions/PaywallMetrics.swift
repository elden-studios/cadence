import Foundation

/// On-device-only, privacy-pure paywall funnel counters (no SDK, no network,
/// no identifiers). Every counter is stamped with the pricing/layout variant id
/// so a future price/layout change keeps pre-change data sliceable.
/// `@MainActor` (matching `ReportsConversionMetrics`) serializes the non-atomic
/// UserDefaults read-modify-write — all callers (PaywallView) are already main-actor.
@MainActor
public enum PaywallMetrics {
    public enum Event: String {
        case paywallView = "paywall_view"
        case tierSelected = "tier_selected"
        case purchaseStart = "purchase_start"
        case purchaseSuccess = "purchase_success"
        case purchaseFailure = "purchase_failure"
        case trialStart = "trial_start"
        case restoreTapped = "restore_tapped"
        case lifetimeOwnedView = "lifetime_owned_view"
    }

    public static func key(variant: String, trigger: String, event: Event, tier: String?) -> String {
        var k = "paywall.\(variant).\(trigger).\(event.rawValue)"
        if let tier { k += ".\(tier)" }
        return k
    }

    public static func record(_ event: Event, variant: String, trigger: String,
                              tier: String? = nil, store: UserDefaults = .standard) {
        let k = key(variant: variant, trigger: trigger, event: event, tier: tier)
        store.set(store.integer(forKey: k) + 1, forKey: k)
    }
}
