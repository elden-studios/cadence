import Testing
import Foundation
@testable import BillableCore

@Suite("Paywall trial eligibility")
@MainActor
struct PaywallEligibilityTests {

    @Test("Eligible is false when products haven't loaded")
    func eligibleFalseWithoutProducts() {
        let manager = SubscriptionManager()
        #expect(manager.eligibleForIntroOffer == false)
    }
}
