import XCTest

#if os(iOS)

/// Runs Aerilo against a real photo library in the simulator, with no demo data.
/// `scripts/test-ios.sh` loads the library first: one picture saved twice, three near-identical
/// shots a second apart, three unrelated pictures, one wide and five tall pictures under WhatsApp names, one old screenshot and one large video.
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
        // The picture pair, and the video with its true copy. A third video of the same length and size but
        // different contents must not be counted: that would make 5.
        XCTAssertTrue(duplicates.label.contains("4 items"), "One picture pair and one video pair: \(duplicates.label)")

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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 ticked'")).firstMatch.waitForExistence(timeout: 10),
                      "One copy of each pair should be ticked, the other kept")
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Moved 2 items to Recently Deleted'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Looked through'")).firstMatch.exists)
    }

    /// Tall pictures must stay inside their own square, and every one of them must be tickable, the left column included.
    func testTallPicturesStayInTheirSquares() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breathe.'")).firstMatch.tap()
        allowIfAsked(["Allow Full Access", "Allow Access to All Photos"])
        let whatsapp = app.buttons.matching(NSPredicate(format: "label CONTAINS 'From WhatsApp'")).firstMatch
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 90))
        XCTAssertTrue(whatsapp.label.contains("6 items"), "One wide and five tall pictures: \(whatsapp.label)")
        sleep(2) // the results slide into place; tap once they are still
        whatsapp.tap()
        let tiles = app.buttons.matching(NSPredicate(format: "label == 'Not ticked'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "The review screen should open with nothing ticked")
        sleep(2) // thumbnails arrive
        XCTAssertEqual(tiles.count, 6)
        let frames = (0..<6).map { tiles.element(boundBy: $0).frame }
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(f.width, f.height, accuracy: 2, "Tile \(i) should be square: \(f)")
            for (j, g) in frames.enumerated() where j > i {
                XCTAssertFalse(f.insetBy(dx: 1, dy: 1).intersects(g), "Tiles \(i) and \(j) overlap: \(f) \(g)")
            }
        }
        // Tick each one by tapping its centre; the count must go up every time.
        let order = frames.enumerated().sorted { ($0.element.minY, $0.element.minX) < ($1.element.minY, $1.element.minX) }
        for (n, entry) in order.enumerated() {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: entry.element.midX, dy: entry.element.midY)).tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(n + 1) ticked'")).firstMatch.waitForExistence(timeout: 5),
                          "Tapping tile \(entry.offset) at \(entry.element) should tick it")
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }

    /// "Delete all" removes every item of a kind in one go, after the system's own confirmation. Runs last (the Z).
    func testZDeleteAllEmptiesTheList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breathe.'")).firstMatch.tap()
        allowIfAsked(["Allow Full Access", "Allow Access to All Photos"])
        let whatsapp = app.buttons.matching(NSPredicate(format: "label CONTAINS 'From WhatsApp'")).firstMatch
        XCTAssertTrue(whatsapp.waitForExistence(timeout: 90))
        sleep(2) // the results slide into place; tap once they are still
        whatsapp.tap()
        XCTAssertTrue(app.staticTexts["Nothing ticked"].waitForExistence(timeout: 10), "Nothing is ticked on arrival")
        XCTAssertFalse(app.buttons["Delete"].isEnabled, "With nothing ticked, plain Delete is off")
        app.buttons["Delete all"].tap()
        let confirm = springboard.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "iOS should ask to confirm the deletion")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Nothing left here."].waitForExistence(timeout: 20), "Every item should be gone")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Moved 6 items to Recently Deleted'")).firstMatch.waitForExistence(timeout: 10))
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
