import XCTest

#if os(tvOS)
/// Drives the Apple TV app with the remote, on sample data: everything must be reachable by
/// moving focus and pressing Select.
final class RemoteTests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.label
    }

    private func move(_ app: XCUIApplication, _ button: XCUIRemote.Button, until wanted: String, tries: Int = 8) -> Bool {
        for _ in 0..<tries {
            if focused(app).contains(wanted) { return true }
            XCUIRemote.shared.press(button)
            usleep(400_000)
        }
        return focused(app).contains(wanted)
    }

    func testBreatheReviewAndTickWithTheRemote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)"]
        app.launch()
        let remote = XCUIRemote.shared

        // From the tab bar, down to the one button, and press it.
        XCTAssertTrue(move(app, .down, until: "Breathe."), "The orb should take focus: focused is '\(focused(app))'")
        remote.press(.select)

        // The sample scan finishes and the results are listed.
        let duplicates = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Exact duplicates'")).firstMatch
        XCTAssertTrue(duplicates.waitForExistence(timeout: 30), "Results should appear after the breath")

        // Down to the first result and into its review screen.
        XCTAssertTrue(move(app, .down, until: "Exact duplicates"), "A result row should take focus: focused is '\(focused(app))'")
        remote.press(.select)
        let ticked = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ticked'")).firstMatch
        XCTAssertTrue(ticked.waitForExistence(timeout: 10), "The review screen should open")

        // Pictures can be focused and unticked with Select.
        let before = ticked.label
        XCTAssertTrue(move(app, .down, until: "for deletion") || move(app, .right, until: "for deletion"), "A ticked picture should take focus: focused is '\(focused(app))'")
        remote.press(.select)
        usleep(600_000)
        XCTAssertNotEqual(before, ticked.label, "Pressing Select on a picture should change what is ticked")

        // Menu goes back to the results.
        remote.press(.menu)
        XCTAssertTrue(duplicates.waitForExistence(timeout: 10))
    }
}
#endif
