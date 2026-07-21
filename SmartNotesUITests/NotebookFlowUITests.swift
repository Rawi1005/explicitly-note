import XCTest

/// Smoke test for the Goodnotes-style notebook flow: create a blank notebook,
/// verify the editor opens with live tool controls, draw a stroke, undo it,
/// then navigate back and reopen the same notebook. A regression of the
/// render-loop bug makes the app never idle, which fails these waits.
final class NotebookFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateOpenDrawAndReopenNotebook() throws {
        let app = XCUIApplication()
        app.launch()

        // Create a blank notebook from the empty state or the toolbar.
        let emptyStateButton = app.buttons["New Blank"]
        let toolbarButton = app.buttons["New Blank Notebook"]
        if emptyStateButton.waitForExistence(timeout: 10) {
            emptyStateButton.tap()
        } else {
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5))
            toolbarButton.tap()
        }

        // The editor must appear and stay responsive.
        let penButton = app.buttons["Pen"]
        XCTAssertTrue(penButton.waitForExistence(timeout: 10), "Editor did not open")

        // Exercise the tool buttons.
        app.buttons["Highlighter"].tap()
        app.buttons["Eraser"].tap()
        penButton.tap()
        XCTAssertTrue(app.buttons["Ruler"].exists)
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)

        // Draw a stroke on the canvas, then undo/redo it.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: end)

        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { undoButton.isEnabled },
            "Undo did not become available after drawing"
        )
        undoButton.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) { app.buttons["Redo"].isEnabled },
            "Redo did not become available after undo"
        )

        // Add a second page from the page rail.
        let addPage = app.buttons["Add Page"]
        if addPage.exists {
            addPage.tap()
        }

        // Go back to the library and reopen the same notebook.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let card = app.staticTexts.matching(NSPredicate(format: "label == 'Untitled Notebook'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Notebook card missing in library")
        card.tap()
        XCTAssertTrue(penButton.waitForExistence(timeout: 10), "Editor did not reopen")
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
