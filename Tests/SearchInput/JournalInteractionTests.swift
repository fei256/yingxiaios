import XCTest

final class JournalInteractionTests: XCTestCase {
    @MainActor func testDayShortcutsAndStatisticsPickTheirOwnValues() {
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
            XCTAssertTrue(app.staticTexts["journal.selection"].label.hasPrefix("2026-11-\(day)|"))
        }
        app.buttons["journal.section.watching"].tap()
        XCTAssertTrue(app.staticTexts["journal.selection"].label.contains("|watching|"))
        let month = app.buttons["journal.statistics.month"]
        for _ in 0..<3 where !month.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(month.isHittable)
        month.tap()
        XCTAssertTrue(app.staticTexts["journal.selection"].label.hasSuffix("|month"))
        XCTAssertEqual(app.descendants(matching: .any)["journal.statistics.duration"].firstMatch.label, "0 小时 40 分钟")
        let statistics = XCTAttachment(screenshot: app.screenshot())
        statistics.name = "journal-statistics"
        statistics.lifetime = .keepAlways
        add(statistics)
        app.buttons["journal.statistics.today"].tap()
        XCTAssertTrue(app.staticTexts["journal.selection"].label.hasSuffix("|today"))
    }
}
