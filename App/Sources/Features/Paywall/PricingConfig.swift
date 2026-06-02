import Foundation

/// Single source of truth for the paywall's variant identity + tier-order +
/// copy that used to be scattered literals. Stamped into every funnel metric so
/// a future price/layout test is a config flip, not a re-instrumentation.
enum PricingConfig {
    /// Bump when prices, tier order, or layout change — keeps metrics sliceable.
    /// `three_equal_tiers` = Monthly / Yearly / Lifetime as co-equal rows (B1),
    /// superseding the prior "yearly_hero_lifetime_below" demoted-Lifetime layout.
    static let variant = "ladder_2026_06_v2"
    static let layout = "three_equal_tiers"

    // Tier-row copy (B1 three-equal-tiers layout).
    /// Pill on the Yearly hero row.
    static let bestValueBadge = "BEST VALUE"
    /// Pill on the Lifetime peer row.
    static let payOnceBadge = "PAY ONCE"
    /// Trailing word on the Lifetime price, e.g. "$99.99 once".
    static let lifetimeOnceSuffix = "once"
    /// Sub-line under the Lifetime row title.
    static let lifetimePeerSubtitle = "Own Cadence Pro forever"

    // Retained for the owned-state collapse + remaining copy.
    static let trialReassurance = "No charge today. We'll remind you before your trial ends. Cancel anytime."
    static let ownedTitle = "You own Cadence Pro forever ✓"
}
