import XCTest

/// Smoke test for the notification-tap → screen handoff infrastructure.
///
/// A true UNNotificationCenter-driven test requires the `simctl push` workflow
/// (brittle, needs an APS-shaped payload + bundle ID matching). For v1.1 we
/// validate the same routing path by launching the app with a custom argument
/// that pre-seeds `NotificationRouter.pendingDestination` — the same property
/// that `AppDelegate.didReceive(response:)` sets when an actual notification
/// is tapped. The downstream behavior (RootView.onChange switching tab + pushing
/// the target) is identical.
///
/// The assertion checks that the **Invoices tab is selected** after launch — the
/// `NavigationBar` with identifier "Invoices" is only present when the Invoices
/// tab is the active tab. This is sufficient to verify the routing fired:
/// `RootView.onChange(.recurringList)` sets `selectedTab = 2` (Invoices).
///
/// The segmented "Recurring" picker is intentionally not asserted here: it only
/// renders when invoices exist, and the test container is always empty. Richer
/// assertions (segment selection, RecurringRulesView presence) are v1.2 work.
final class NotificationTapFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_recurrenceNotificationRoutesToRecurringList() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--pretend-pro",                 // Bypass IAP gating for the deep route
            "--ui-test-route-recurring"      // Seed pendingDestination = .recurringList
        ]
        app.launch()

        // RootView.onChange(.recurringList) sets selectedTab = 2 (Invoices).
        // The Invoices NavigationBar is identified by the "Invoices" identifier;
        // it is only present when the Invoices tab is active.
        XCTAssertTrue(
            app.navigationBars["Invoices"].waitForExistence(timeout: 5),
            "Expected to land on the Invoices tab (NavigationBar 'Invoices' not found)"
        )
    }
}
