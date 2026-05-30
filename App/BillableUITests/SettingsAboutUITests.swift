import XCTest

/// Regression guard for the Settings → About section. v1.4 introduces
/// Developer attribution and a tappable Contact mailto link.
final class SettingsAboutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_settingsAbout_showsDeveloperAttribution() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",                       // Wipe the App Group store so seeding always runs
            "--seed-marketing",                    // Seeds a profile so the About section renders
            "--ui-test-skip-onboarding"            // Bypass the redesigned onboarding so the tab bar is reachable
        ]
        app.launch()

        // Navigate to Settings tab. The tab is identified by its accessibility
        // label "Settings" set on the TabView item in BillableApp. Wait for the
        // tab bar to appear: the onboarding-gate onAppear adds a beat before the
        // main shell (and its TabView) renders.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15),
                      "Settings tab must exist after launch")
        settingsTab.tap()

        // Scroll to bottom to make sure the About section is on screen.
        app.swipeUp()

        // Three assertions: Version row exists; Developer attribution exists;
        // Contact email link exists.
        XCTAssertTrue(
            app.staticTexts["Version"].waitForExistence(timeout: 5),
            "About section must contain a Version row"
        )
        XCTAssertTrue(
            app.staticTexts["Elden Studios Company"].exists,
            "About section must contain Developer attribution 'Elden Studios Company'"
        )
        XCTAssertTrue(
            app.staticTexts["bazerbashi@elden-studios.com"].exists,
            "About section must contain the contact email"
        )
    }
}
