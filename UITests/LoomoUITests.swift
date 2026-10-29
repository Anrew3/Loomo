import XCTest

/// End-to-end checks through the real UI: start a harness, insert from the keyboard, undo, browse pages.
/// Run with the LoomoUI test plan (they need the screen unlocked and take a minute).
final class LoomoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // No restored windows, no tips, no setup assistant; each test starts from a new, empty harness.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-UITests", "-setup.completed", "YES"]
        app.launch()
        app.activate()
        let newHarness = app.buttons["welcome.New Harness"].firstMatch
        XCTAssertTrue(newHarness.waitForExistence(timeout: 10),
                      "The welcome window didn't appear. App state \(app.state.rawValue), windows: \(app.windows.count)\n\(app.debugDescription.prefix(1500))")
        newHarness.click()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.Wires"].firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func sidebarCount(_ title: String) -> String {
        let row = app.descendants(matching: .any)["sidebar.\(title)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No sidebar row \(title)")
        return row.value as? String ?? ""
    }

    func testANewHarnessIsEmpty() {
        XCTAssertEqual(sidebarCount("Connectors & Pinouts"), "0")
        XCTAssertEqual(sidebarCount("Wires"), "0")
    }

    func testInsertSpliceThenUndo() {
        XCTAssertEqual(sidebarCount("Splices"), "0")
        // S inserts a splice on the drawing; ⌘Z takes it back.
        app.windows.firstMatch.click()
        app.typeKey("s", modifierFlags: [])
        XCTAssertEqual(sidebarCount("Splices"), "1")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(sidebarCount("Splices"), "0")
    }

    func testBillOfMaterialsOpens() {
        app.descendants(matching: .any)["sidebar.Bill of Materials"].firstMatch.click()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 5))
    }

    func testRuleCheckerOpens() {
        app.descendants(matching: .any)["sidebar.Rule Checker"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Rule Checker"].firstMatch.waitForExistence(timeout: 5))
    }
}
