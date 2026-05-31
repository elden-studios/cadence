import Foundation

/// Single source of truth for the paywall's variant identity + tier-order +
/// copy that used to be scattered literals. Stamped into every funnel metric so
/// a future price/layout test is a config flip, not a re-instrumentation.
enum PricingConfig {
    /// Bump when prices, tier order, or layout change — keeps metrics sliceable.
    static let variant = "ladder_2026_05_v1"
    static let layout = "yearly_hero_lifetime_below"

    static let lifetimeAffordanceTitle = "Prefer to pay once?"
    static let lifetimeAffordanceSubtitle = "Own Cadence Pro forever"
    static let trialReassurance = "No charge today. We'll remind you before your trial ends. Cancel anytime."
    static let ownedTitle = "You own Cadence Pro forever ✓"
}
