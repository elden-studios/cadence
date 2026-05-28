import XCTest

/// UI smoke test for the A8 editable-description flow on InvoicePreviewView.
///
/// 1. Launch with --reset-store + --seed-marketing so the App Group
///    container is wiped and re-seeded on every run (the seeder is gated
///    on clientCount == 0; without the reset, prior runs would leave it a
///    no-op). Seeding clients also skips onboarding. --pretend-pro removes
///    paywall gates so the path Invoices → Preview is unblocked.
/// 2. Open the Invoices tab, tap +, pick Northwind, switch the period to
///    "This week" (the seed places billable entries on the current day),
///    tap Preview.
/// 3. Preview shows a LINE ITEMS card above the PDF.
/// 4. Edit one description, confirm Finalize stays enabled.
/// 5. Clear the description, confirm Finalize disables (validation fires
///    within the 200ms debounce window plus a small cushion).
final class InvoicePreviewLineItemEditUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_invoicePreview_descriptionEdit_andValidation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",                       // Wipe the App Group store so seeding always runs
            "--seed-marketing",                    // Seeds Northwind + projects + today's entries
            "--pretend-pro",                       // Bypass paywall gates so we reach Preview
            "--ui-test-skip-onboarding"            // No-op today; reserved for future use
        ]
        app.launch()

        // ── Navigate Invoices tab → New invoice → Preview ──────────────────

        // The tab bar exposes tabs by their tabItem label.
        let invoicesTab = app.tabBars.buttons["Invoices"]
        XCTAssertTrue(invoicesTab.waitForExistence(timeout: 5),
                      "Invoices tab must exist after launch")
        invoicesTab.tap()

        // Tap the "+" plus toolbar item. InvoicesView sets an explicit
        // accessibilityLabel of "New invoice" on the trailing toolbar Button.
        let addButton = app.navigationBars.buttons["New invoice"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3),
                      "Invoices toolbar must expose a 'New invoice' button")
        addButton.tap()

        // ── InvoiceGeneratorView: pick a client + a range with entries ─────

        // The Client picker is a Menu whose label hstack composes
        //   Text("Client") + Spacer() + Text("Choose") + chevron.
        // SwiftUI exposes the whole row as a button whose accessibility label
        // is the concatenation, e.g. "Client, Choose" or "Client, <name>".
        // Pin to the form area (not the tab bar) by matching the navbar title.
        XCTAssertTrue(
            app.navigationBars["New invoice"].waitForExistence(timeout: 3),
            "InvoiceGeneratorView must show 'New invoice' navigation title"
        )
        // Locate the Client menu by its scope (other.elements named "Client"
        // come from the form section header; we want the actionable menu).
        let clientMenu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Client,' OR label == 'Client, Choose'")
        ).firstMatch
        XCTAssertTrue(clientMenu.waitForExistence(timeout: 3),
                      "Client picker (Menu) must be visible on the generator screen")
        clientMenu.tap()

        // The Menu surface should now show every client. --seed-marketing
        // seeds Northwind (preferred for the App Store demo). If the App
        // Group already has seed data from a previous --seed-demo run, the
        // seeder is a no-op (it's gated on clientCount == 0) and SampleData
        // clients (Acme Corp, Zen Garden) appear instead — both seed sets
        // include billable entries for the current day, so either client
        // satisfies the Preview gate.
        let candidates = ["Northwind Design", "Acme Corp", "Zen Garden",
                          "Apex Analytics", "Helio Labs", "Pinecone Studio"]
        var pickedClient: XCUIElement?
        for label in candidates {
            let candidate = app.buttons[label]
            if candidate.waitForExistence(timeout: 1) {
                pickedClient = candidate
                break
            }
        }
        guard let clientToTap = pickedClient else {
            XCTFail("No known seed client appeared in the picker. Tree:\n\(app.debugDescription)")
            return
        }
        clientToTap.tap()

        // Default preset is .lastMonth — seed entries (both marketing + demo)
        // live in the current day/week, so switch to "This week". The Range
        // row exposes its current value via accessibility label, so match by
        // prefix.
        let rangeRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Range,'")
        ).firstMatch
        XCTAssertTrue(rangeRow.waitForExistence(timeout: 3),
                      "Range picker row must exist on the generator screen")
        rangeRow.tap()
        let thisWeek = app.buttons["This week"]
        XCTAssertTrue(thisWeek.waitForExistence(timeout: 2),
                      "'This week' must appear in the range menu")
        thisWeek.tap()

        // Tap Preview. Disabled until eligibleEntries > 0 AND a business
        // profile name is set. SwiftData/@Query refresh on the next runloop,
        // so give the button up to 5s to become enabled.
        let previewButton = app.buttons["Preview"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 3),
                      "Preview button must exist on the generator screen")
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = expectation(for: enabledPredicate,
                                             evaluatedWith: previewButton)
        let outcome = XCTWaiter().wait(for: [enabledExpectation], timeout: 5)
        XCTAssertEqual(outcome, .completed,
                       "Preview must enable once a client with eligible entries is chosen. Tree:\n\(app.debugDescription)")
        previewButton.tap()

        // ── Preview screen: LINE ITEMS header + first description field ────

        let lineItemsHeader = app.staticTexts["LINE ITEMS"]
        XCTAssertTrue(lineItemsHeader.waitForExistence(timeout: 5),
                      "LINE ITEMS header must be visible above the PDF")

        // First Description TextField in the editor. Once the field has a
        // value (which it does — the InvoiceBuilder always pre-fills the
        // description), iOS no longer exposes the placeholder as the field's
        // accessibility label. The line-item editor is the first set of
        // TextFields in the Preview ScrollView, so `boundBy: 0` reliably
        // targets the first line-item description.
        let firstDescription = app.textFields.element(boundBy: 0)
        XCTAssertTrue(firstDescription.waitForExistence(timeout: 3),
                      "First line-item Description field must exist")

        // ── Edit the first description ──────────────────────────────────────

        firstDescription.tap()
        // Long-press surfaces the Select All / Cut / Copy / Paste menu so
        // we can wipe the existing text before typing.
        firstDescription.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1.5) {
            selectAll.tap()
        }
        firstDescription.typeText("Edited description")

        // Finalize should remain enabled — the field still has content.
        // The primary trailing toolbar button is "Finalize & email"; the
        // overflow menu also exposes "Finalize & share", but both bind to
        // the same hasInvalidDescriptions disable.
        let finalize = app.buttons["Finalize & email"]
        XCTAssertTrue(finalize.waitForExistence(timeout: 2),
                      "Finalize button must exist on the preview screen")
        XCTAssertTrue(finalize.isEnabled,
                      "Finalize must be enabled when all descriptions are non-empty")

        // ── Clear the description, expect Finalize to disable ──────────────

        firstDescription.tap()
        firstDescription.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 1.5) {
            app.menuItems["Select All"].tap()
        }
        // typeText with the delete key clears the selection.
        firstDescription.typeText(XCUIKeyboardKey.delete.rawValue)

        // Validation reads directly from pendingDescriptionEdits + lineItems,
        // so the disable should propagate within the 200ms debounce window.
        // Wait dynamically (vs Thread.sleep) to avoid flake on slow simulator runs.
        let disabledPredicate = NSPredicate(format: "isEnabled == false")
        let disabledExpectation = expectation(for: disabledPredicate, evaluatedWith: finalize)
        let waitOutcome = XCTWaiter().wait(for: [disabledExpectation], timeout: 2.0)
        XCTAssertEqual(waitOutcome, .completed,
                       "Finalize must be disabled when any description is empty")
    }
}
