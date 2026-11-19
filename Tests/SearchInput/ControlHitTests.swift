import XCTest

final class ControlHitTests: XCTestCase {
    @MainActor func testVisibleControlCornersTriggerTheirOwnAction() {
        let app = XCUIApplication()
        app.launchArguments = ["controls"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let result = app.staticTexts["control.last"]
        for id in ["top.0", "top.1", "top.2", "bottom.0", "bottom.1", "bottom.2"] + (0..<6).map({ "dock.\($0)" }) {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(button.frame.height, 48)
            for point in [CGVector(dx: 0.04, dy: 0.04), CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.96, dy: 0.96)] {
                button.coordinate(withNormalizedOffset: point).tap()
                XCTAssertEqual(result.label, id, "Touching \(id) must not trigger another button or the picture")
            }
        }
    }
}
