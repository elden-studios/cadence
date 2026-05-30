import XCTest

/// Covers the redesigned onboarding identity screen (spec §5):
///  1. The name field's label tracks the selected entity type (Freelancer → "Your
///     name"; Organization → "Business name"), proving the shared
///     EntityType+Presentation mapping is wired in.
///  2. Finishing setup lands on Today WITHOUT starting a timer — the new finish()
///     creates no Client/Project/TimeEntry (the core behavior change vs. the old
///     "start your first timer" flow).
final class OnboardingEntityTypeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",               // wipe the App Group store → from-empty onboarding
            "--ui-test-show-onboarding",   // force-show onboarding regardless of latch state
        ]
        app.launch()
        return app
    }

    /// Advance welcome → identity by tapping the primary CTA.
    private func goToIdentity(_ app: XCUIApplication) {
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5), "Welcome CTA missing")
        getStarted.tap()
        XCTAssertTrue(
            app.staticTexts["How do you bill?"].waitForExistence(timeout: 3),
            "Identity screen did not appear"
        )
    }

    func test_nameFieldLabel_tracksEntityType() {
        let app = launchedApp()
        goToIdentity(app)

        let nameField = app.textFields["onboarding.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Name field missing")

        // The TextField's own `.label` reports empty on this OS (empty title +
        // prompt-only placeholder), so anchor on the caps field label rendered by
        // fieldLabel(entityType.issuerNameLabel.uppercased()) right above the field
        // — that is the visible, entity-driven label proving the mapping is wired.
        // Freelancer is pre-selected → "YOUR NAME".
        XCTAssertTrue(
            app.staticTexts["YOUR NAME"].waitForExistence(timeout: 3),
            "Freelancer name field must be labelled 'Your name'"
        )
        XCTAssertFalse(
            app.staticTexts["BUSINESS NAME"].exists,
            "Organization label must not show while Freelancer is selected"
        )

        // Switch to Organization → label flips to "BUSINESS NAME".
        app.buttons["Organization. A team — we bill under one company name."].tap()
        XCTAssertTrue(
            app.staticTexts["BUSINESS NAME"].waitForExistence(timeout: 3),
            "Organization name field must be labelled 'Business name'"
        )
        XCTAssertFalse(
            app.staticTexts["YOUR NAME"].exists,
            "Freelancer label must not show while Organization is selected"
        )
    }

    func test_finish_landsOnToday_withNoRunningTimer() {
        let app = launchedApp()
        goToIdentity(app)

        let nameField = app.textFields["onboarding.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Name field missing")
        nameField.tap()
        nameField.typeText("Jane Doe")

        app.buttons["Finish setup"].tap()

        // Lands on Today: the Today tab / navigation bar is present.
        XCTAssertTrue(
            app.navigationBars["Today"].waitForExistence(timeout: 5),
            "Finishing setup must land on the Today screen"
        )

        // No auto-timer: the running-timer affordance (a "Running" labelled control
        // in Jump-back-in) must NOT exist, because finish() creates no TimeEntry.
        XCTAssertFalse(
            app.buttons["Running"].exists,
            "Finishing setup must NOT start a timer (no 'Running' control on Today)"
        )
    }
}
