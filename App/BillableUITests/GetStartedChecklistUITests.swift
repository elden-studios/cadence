import XCTest

/// UI checks for the get-started block (spec §7a / §16):
///  A. Adding a client advances checklist Row 1 ("Add your first client" → done)
///     and enables Row 2 ("Create a project").
///
/// Launched with --seed-onboarding-needs-setup (onboarded, first-setup
/// unreached, no clients) so Today renders the get-started block on first frame.
final class GetStartedChecklistUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",                       // Wipe the App Group store
            "--seed-onboarding-needs-setup",       // Onboarded; first-setup unreached; no clients
            "--pretend-pro"                        // Remove paywall gates (consistency w/ other UI tests)
        ]
        app.launch()
        return app
    }

    // MARK: B — first-run Today leads with "Add your first client"; no timer quick-start CTA

    func test_firstRun_leadsWithAddClient_andNoTimerCTA() {
        let app = launchedApp()

        // The setup-first checklist row must be the lead CTA.
        XCTAssertTrue(app.buttons["Add your first client"].waitForExistence(timeout: 5),
                      "'Add your first client' must be the lead row on first run. Tree:\n\(app.debugDescription)")

        // The old "Start a timer now" quick-start button must not exist.
        XCTAssertFalse(app.buttons["getStarted.quickStart"].exists,
                       "Timer quick-start button must not appear — that path has been removed")
    }

    // MARK: A — adding a client advances Row 1 + enables Row 2

    func test_addingClient_advancesChecklist_andEnablesProjectRow() throws {
        let app = launchedApp()

        // Row 2 "Create a project" starts disabled (no client). XCUITest reports
        // a disabled SwiftUI Button as isEnabled == false.
        let createProjectRow = app.buttons["Create a project"]
        XCTAssertTrue(createProjectRow.waitForExistence(timeout: 5),
                      "'Create a project' checklist row must be present. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(createProjectRow.isEnabled,
                       "'Create a project' must be disabled until a client exists")

        // Tap Row 1 "Add your first client" → ClientEditorView sheet.
        let addClientRow = app.buttons["Add your first client"]
        XCTAssertTrue(addClientRow.waitForExistence(timeout: 3),
                      "'Add your first client' checklist row must be present")
        addClientRow.tap()

        // Fill the client name. ClientEditorView's first field placeholder is "Client name".
        let nameField = app.textFields["Client name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3),
                      "Client name field must appear in the editor. Tree:\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText("Acme Co")

        // Save the client (ClientEditorView's trailing "Save" button).
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Client editor Save button must exist")
        save.tap()

        // Back on Today: Row 2 must now be enabled (a client exists). The @Query
        // refreshes on the next runloop, so wait dynamically.
        XCTAssertTrue(createProjectRow.waitForExistence(timeout: 5),
                      "'Create a project' row must still be present after returning to Today")
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let exp = expectation(for: enabledPredicate, evaluatedWith: createProjectRow)
        let outcome = XCTWaiter().wait(for: [exp], timeout: 5)
        XCTAssertEqual(outcome, .completed,
                       "'Create a project' must enable once a client exists. Tree:\n\(app.debugDescription)")
    }
}
