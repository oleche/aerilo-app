import XCTest

#if os(iOS)

/// Runs Aerilo against a real photo library in the simulator, with no demo data.
/// `scripts/test-ios.sh` loads the library first: one picture saved twice, three near-identical
/// shots a second apart, three unrelated pictures, one old screenshot and one large video.
final class RealLibraryTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func allowIfAsked(_ titles: [String], timeout: TimeInterval = 4) {
        for title in titles {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: timeout) { button.tap(); return }
        }
    }

    func testScanReviewAndDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()

        // The one button.
        let breathe = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breathe.'")).firstMatch
        XCTAssertTrue(breathe.waitForExistence(timeout: 15), "The Breathe button should be on screen")
        breathe.tap()
        allowIfAsked(["Allow Full Access", "Allow Access to All Photos"])

        // Results: what the scan must find in the prepared library.
        let duplicates = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Exact duplicates'")).firstMatch
        XCTAssertTrue(duplicates.waitForExistence(timeout: 90), "The scan should finish and list exact duplicates")
        XCTAssertTrue(duplicates.label.contains("2 items"), "One picture saved twice is one pair: \(duplicates.label)")

        let similar = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Similar shots'")).firstMatch
        XCTAssertTrue(similar.exists, "Three near-identical shots should be grouped")
        XCTAssertTrue(similar.label.contains("3 items"), "Only the three alike shots, not the unrelated ones: \(similar.label)")

        let videos = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Largest videos'")).firstMatch
        XCTAssertTrue(videos.exists, "The large video should be listed")
        XCTAssertFalse(videos.label.contains("suggested"), "Videos are never ticked for the user")

        let whatsapp = app.buttons.matching(NSPredicate(format: "label CONTAINS 'From WhatsApp'")).firstMatch
        XCTAssertTrue(whatsapp.exists, "The picture saved under a WhatsApp name should be listed")
        XCTAssertFalse(whatsapp.label.contains("suggested"), "Nothing from a conversation is ticked for the user")

        let screenshots = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Old screenshots'")).firstMatch
        XCTContext.runActivity(named: "Old screenshots listed: \(screenshots.exists)") { _ in }

        // Review the duplicates and delete the suggested copy.
        sleep(2) // the results slide into place; tap once they are still
        duplicates.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1 ticked'")).firstMatch.waitForExistence(timeout: 10),
                      "One of the two copies should be ticked, the other kept")
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 10))
        app.buttons["Delete"].tap()
        // iOS itself asks before anything leaves the library.
        let confirm = springboard.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "iOS should ask to confirm the deletion")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Nothing left here."].waitForExistence(timeout: 20), "The pair should be gone after deleting")

        // Back on the home screen the freed amount is shown and the pair is no longer listed.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'freed'")).firstMatch.waitForExistence(timeout: 10), "The orb should show what was freed")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Exact duplicates'")).firstMatch.exists)

        // The log has the scan and the deletion.
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Moved 1 item to Recently Deleted'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Looked through'")).firstMatch.exists)
    }

    /// Declining the system's confirmation must leave the library untouched.
    func testCancelledDeleteKeepsEverything() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breathe.'")).firstMatch.tap()
        allowIfAsked(["Allow Full Access", "Allow Access to All Photos"])
        let similar = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Similar shots'")).firstMatch
        XCTAssertTrue(similar.waitForExistence(timeout: 90))
        sleep(2) // the results slide into place; tap once they are still
        similar.tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 10), "The review screen should open")
        app.buttons["Delete"].tap()
        let decline = springboard.buttons["Don’t Allow"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        decline.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 ticked'")).firstMatch.waitForExistence(timeout: 10),
                      "After declining, the same two shots should still be there and ticked")
    }
}
#endif
