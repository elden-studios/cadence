import XCTest

/// Regression guard for the Settings → About section. v1.4 introduces
/// Developer attribution and a tappable Contact mailto link.
final class SettingsAboutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_settingsAbout_showsDeveloperAttribution() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-marketing"]
        app.launch()

        // Navigate to Settings tab. The tab is identified by its accessibility
        // label "Settings" set on the TabView item in BillableApp.
        app.tabBars.buttons["Settings"].tap()

        // Scroll to bottom to make sure the About section is on screen.
        app.swipeUp()

        // Three assertions: Version row exists; Developer attribution exists;
        // Contact email link exists.
        XCTAssertTrue(
            app.staticTexts["Version"].waitForExistence(timeout: 5),
            "About section must contain a Version row"
        )
        XCTAssertTrue(
            app.staticTexts["Cadence by Elden Studios Company"].exists,
            "About section must contain Developer attribution 'Cadence by Elden Studios Company'"
        )
        XCTAssertTrue(
            app.staticTexts["bazerbashi@elden-studios.com"].exists,
            "About section must contain the contact email"
        )
    }
}
