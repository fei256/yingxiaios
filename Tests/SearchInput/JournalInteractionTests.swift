import XCTest

final class JournalInteractionTests: XCTestCase {
    @MainActor func testPortraitJournalLayoutFitsAndScreenshot() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["journal"]
        app.launch()
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("The journal window did not appear")
            return
        }
        let deadline = Date().addingTimeInterval(5)
        var windowFrame = window.frame
        while (windowFrame.width <= 0 || windowFrame.width >= windowFrame.height), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            windowFrame = window.frame
        }
        XCTAssertGreaterThan(windowFrame.width, 0)
        XCTAssertLessThan(windowFrame.width, windowFrame.height, "The journal must settle in portrait before capture")
        let bounds = windowFrame.insetBy(dx: -0.5, dy: -0.5)
        let identifiers = (15...21).map { "journal.day.2026-11-\($0)" }
            + ["history", "favorites", "later", "watching"].map { "journal.section.\($0)" }
        for identifier in identifiers {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, identifier)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, identifier)
            XCTAssertTrue(bounds.contains(button.frame), "\(identifier) must fit inside \(windowFrame); actual \(button.frame)")
        }
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "journal-portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
    }

    @MainActor func testDatesAndAllFourLibraryDestinations() {
        let app = XCUIApplication()
        app.launchArguments = ["journal"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["journal.day.2026-11-21"].waitForExistence(timeout: 5))
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "journal-landscape"
        initial.lifetime = .keepAlways
        add(initial)
        for day in 15...21 {
            let button = app.buttons["journal.day.2026-11-\(day)"]
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
            XCTAssertTrue(app.staticTexts["journal.selection"].label == "2026-11-\(day)")
        }
        for section in ["history", "favorites", "later", "watching"] {
            let link = app.buttons["journal.section." + section]
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.tap()
            XCTAssertTrue(app.staticTexts["journal.list." + section].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
}
