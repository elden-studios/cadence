import Testing
@testable import BillableCore

@Suite("Lifetime entitlement resolution")
@MainActor
struct SubscriptionManagerLifetimeTests {
    typealias E = SubscriptionManager.Entitlement

    @Test("lifetime owned wins over every subscription state")
    func lifetimeWins() {
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: nil) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .free) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .trial(daysRemaining: 3)) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .pro) == .pro)
    }

    @Test("without lifetime, the subscription state passes through")
    func noLifetime() {
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: nil) == .free)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .free) == .free)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .trial(daysRemaining: 5)) == .trial(daysRemaining: 5))
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .pro) == .pro)
    }

    @Test("lifetime product ID is the agreed string")
    func productID() {
        #expect(SubscriptionManager.lifetimeProductID == "com.eldenstudios.billable.pro.lifetime")
    }
}
