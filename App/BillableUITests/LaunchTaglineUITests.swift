import XCTest

/// Regression guard for the launch screen tagline. The v1.1.2 work
/// explicitly removed "Get paid" from the tagline; this test fails if
/// the third line reappears OR the first two lines drift.
final class LaunchTaglineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_launchScreen_showsTrackHoursAndSendInvoicesTagline() {
        let app = XCUIApplication()
        // Force-show the onboarding screen regardless of prior simulator state.
        // The --ui-test-show-onboarding flag bypasses the UserDefaults guard in
        // RootView so this test is deterministic across clean and dirty simulators.
        app.launchArguments = ["--ui-test-show-onboarding"]
        app.launch()

        // The tagline is a single Text with newline-joined lines:
        //   Text("Track hours.\nSend invoices.")
        // XCUI exposes it as a single staticTexts element whose label
        // matches that string with a real newline character.
        let tagline = app.staticTexts["Track hours.\nSend invoices."]
        XCTAssertTrue(
            tagline.waitForExistence(timeout: 5),
            "Launch screen must show 'Track hours.\\nSend invoices.' tagline"
        )
    }

    func test_launchScreen_doesNotShowGetPaid() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-show-onboarding"]
        app.launch()

        // Negative assertion: no visible text contains "get paid" anywhere on
        // the launch screen. Catches a future regression that reintroduces
        // the v1.1 'Get paid.' third line.
        let getPaidText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "get paid")
        )
        XCTAssertEqual(
            getPaidText.count, 0,
            "Launch screen must NOT contain 'get paid' copy (removed in v1.1.2)"
        )
    }
}
