import XCTest

final class ControlHitTests: XCTestCase {
    @MainActor func testReferenceControlCorners() {
        checkReferences(arguments: ["controls"], ids: ["reference", "plain", "styled.rectangle"])
    }
    @MainActor func testReferenceControlCornersWithoutPictureLayer() {
        checkReferences(arguments: ["controls", "no-picture"], ids: ["reference", "plain", "styled.rectangle"])
    }
    @MainActor func testNativeReferenceControlCorners() {
        checkReferences(arguments: ["controls"], ids: ["native.reference"])
    }
    @MainActor private func checkReferences(arguments: [String], ids: [String]) {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        print("Reference application/window bounds: \(app.frame), \(app.windows.firstMatch.frame)")
        let result = app.staticTexts["control.last"]
        var events = 0
        for id in ids {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            print("Reference bounds \(id): \(button.frame)")
            for point in [CGVector(dx: 0.04, dy: 0.04), CGVector(dx: 0.96, dy: 0.04), CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.04, dy: 0.96), CGVector(dx: 0.96, dy: 0.96)] {
                button.coordinate(withNormalizedOffset: point).tap()
                events += 1
                XCTAssertEqual(result.label, "\(id):\(events)")
            }
        }
    }
    @MainActor func testVisibleControlCornersTriggerTheirOwnAction() {
        let app = XCUIApplication()
        app.launchArguments = ["controls"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        print("Control application/window bounds: \(app.frame), \(app.windows.firstMatch.frame)")
        XCTAssertTrue(app.buttons["top.0"].waitForExistence(timeout: 5))
        let layout = XCTAttachment(screenshot: app.screenshot())
        layout.lifetime = .keepAlways
        add(layout)
        let result = app.staticTexts["control.last"]
        var events = 0
        for id in ["top.0", "top.1", "top.2", "bottom.0", "bottom.1", "bottom.2"] + (0..<6).map({ "dock.\($0)" }) {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(button.frame.height, 48)
            print("Control bounds \(id): \(button.frame)")
            for point in [CGVector(dx: 0.04, dy: 0.04), CGVector(dx: 0.96, dy: 0.04), CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.04, dy: 0.96), CGVector(dx: 0.96, dy: 0.96)] {
                button.coordinate(withNormalizedOffset: point).tap()
                events += 1
                XCTAssertEqual(result.label, "\(id):\(events)", "Every center/corner touch must trigger exactly the selected button")
            }
        }
    }
}
