import Testing
@testable import BillableCore

@Suite("Lifetime availability resolution")
struct LifetimeAvailabilityTests {

    @Test("Products not yet loaded -> .loading (never .unavailable prematurely)")
    func loadingWhileProductsPending() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .loading,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .idle,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
    }

    @Test("Products ready and lifetime present -> .available")
    func availableWhenLifetimeLoaded() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: true,
                hasAnySubscriptionProduct: true
            ) == .available
        )
    }

    @Test("Ready with lifetime present but NO subscriptions -> .available (non-consumable-only catalog)")
    func availableWhenOnlyLifetimeLoaded() {
        // A catalog that resolved only the non-consumable Lifetime (no subscription
        // products) must still treat Lifetime as transactable — `hasLifetimeProduct`
        // wins regardless of whether any subscription resolved.
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: true,
                hasAnySubscriptionProduct: false
            ) == .available
        )
    }

    @Test("Products ready, subscriptions present, lifetime nil -> .unavailable (the silent-blank guard)")
    func unavailableWhenOnlyLifetimeMissing() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: true
            ) == .unavailable
        )
    }

    @Test("Ready but NOTHING loaded -> .loading (do not flag lifetime as the culprit when the whole fetch is empty)")
    func loadingWhenReadyButEmpty() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
    }

    @Test("Failed load -> .loading (the .failed branch already owns retry UI; lifetime is not singled out)")
    func loadingWhenFailed() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .failed("Pricing unavailable"),
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: true
            ) == .loading
        )
    }
}

@Suite("Lifetime diagnostic message")
struct LifetimeDiagnosticTests {

    @Test("Subscriptions loaded but lifetime nil -> returns a diagnostic naming the product id")
    func diagnosticWhenLifetimeMissing() {
        let msg = SubscriptionManager.lifetimeDiagnostic(
            hasLifetimeProduct: false,
            hasAnySubscriptionProduct: true
        )
        #expect(msg != nil)
        #expect(msg?.contains(SubscriptionManager.lifetimeProductID) == true)
    }

    @Test("Lifetime present -> no diagnostic")
    func noDiagnosticWhenLifetimePresent() {
        #expect(
            SubscriptionManager.lifetimeDiagnostic(
                hasLifetimeProduct: true,
                hasAnySubscriptionProduct: true
            ) == nil
        )
    }

    @Test("Nothing loaded -> no diagnostic (empty fetch is the .failed path's problem, not a lifetime gap)")
    func noDiagnosticWhenNothingLoaded() {
        #expect(
            SubscriptionManager.lifetimeDiagnostic(
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == nil
        )
    }
}
