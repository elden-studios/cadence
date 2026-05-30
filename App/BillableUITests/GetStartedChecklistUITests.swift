import XCTest

/// UI checks for the get-started block (spec §7a / §16):
///  A. Double-tapping "Start a timer now" creates exactly ONE General project
///     and ONE running timer (the `startingQuickTimer` debounce holds), and the
///     block header reframes to "Timer running".
///  B. Adding a client advances checklist Row 1 ("Add a client" → done) and
///     enables Row 2 ("Create a project").
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

    // MARK: A — quick-start double-tap creates exactly one General + one timer

    func test_quickStart_doubleTap_createsOneGeneral_andRunningTimer() throws {
        let app = launchedApp()

        // Today tab is the default; the get-started block shows on first frame.
        let quickStart = app.buttons["getStarted.quickStart"]
        XCTAssertTrue(quickStart.waitForExistence(timeout: 5),
                      "Get-started quick-start button must be visible on Today. Tree:\n\(app.debugDescription)")

        // Double-tap as fast as possible to race the debounce.
        quickStart.tap()
        quickStart.tap()

        // The header reframes to "Timer running" once the timer starts — wait for it.
        let runningHeader = app.staticTexts["Timer running"]
        XCTAssertTrue(runningHeader.waitForExistence(timeout: 5),
                      "Block header must reframe to 'Timer running' after quick-start. Tree:\n\(app.debugDescription)")

        // Verify exactly ONE "General" project exists by navigating to Work and
        // counting rows whose label is exactly "General". (Two would mean the
        // debounce failed and we double-inserted.)
        let workTab = app.tabBars.buttons["Work"]
        XCTAssertTrue(workTab.waitForExistence(timeout: 3), "Work tab must exist")
        workTab.tap()

        let generalCells = app.staticTexts.matching(NSPredicate(format: "label == 'General'"))
        // Allow the list to populate.
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5),
                      "A 'General' project must appear in Work after quick-start. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(generalCells.count, 1,
                       "Exactly ONE 'General' project must exist (debounce must prevent a double-insert). Found \(generalCells.count). Tree:\n\(app.debugDescription)")
    }

    // MARK: B — adding a client advances Row 1 + enables Row 2

    func test_addingClient_advancesChecklist_andEnablesProjectRow() throws {
        let app = launchedApp()

        // Row 2 "Create a project" starts disabled (no client). XCUITest reports
        // a disabled SwiftData Button as isEnabled == false.
        let createProjectRow = app.buttons["Create a project"]
        XCTAssertTrue(createProjectRow.waitForExistence(timeout: 5),
                      "'Create a project' checklist row must be present. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(createProjectRow.isEnabled,
                       "'Create a project' must be disabled until a client exists")

        // Tap Row 1 "Add a client" → ClientEditorView sheet.
        let addClientRow = app.buttons["Add a client"]
        XCTAssertTrue(addClientRow.waitForExistence(timeout: 3),
                      "'Add a client' checklist row must be present")
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
