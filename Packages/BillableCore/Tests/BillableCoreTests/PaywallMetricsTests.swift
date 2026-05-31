import Foundation
import Testing
@testable import BillableCore

@Suite("PaywallMetrics funnel keys")
@MainActor
struct PaywallMetricsTests {
    @Test("event key composes variant + trigger + event + tier")
    func keyComposition() {
        #expect(PaywallMetrics.key(variant: "v1", trigger: "reports", event: .tierSelected, tier: "lifetime")
                == "paywall.v1.reports.tier_selected.lifetime")
        #expect(PaywallMetrics.key(variant: "v1", trigger: "settings", event: .paywallView, tier: nil)
                == "paywall.v1.settings.paywall_view")
    }

    @Test("record increments the composed counter in the provided store")
    func recordIncrements() {
        let store = UserDefaults(suiteName: "PaywallMetricsTests")!
        store.removePersistentDomain(forName: "PaywallMetricsTests")
        PaywallMetrics.record(.purchaseSuccess, variant: "v1", trigger: "reports", tier: "yearly", store: store)
        PaywallMetrics.record(.purchaseSuccess, variant: "v1", trigger: "reports", tier: "yearly", store: store)
        #expect(store.integer(forKey: "paywall.v1.reports.purchase_success.yearly") == 2)
    }
}
