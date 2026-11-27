import XCTest
import UIKit

final class ControlHitTests: XCTestCase {
    @MainActor private func requireAction(_ result: XCUIElement, id: String, events: Int, point: CGVector,
                                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let expected = "\(id):\(events)"
        let started = ProcessInfo.processInfo.systemUptime
        let initial = result.label
        if initial == expected { return true }
        let response = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: result)
        let status = XCTWaiter.wait(for: [response], timeout: 2)
        let observed = result.label
        let receipt = XCTAttachment(string: "expected=\(expected)\ninitial=\(initial)\nobserved=\(observed)\npoint=\(point)\nwait=\(status)\nelapsed=\(ProcessInfo.processInfo.systemUptime - started)")
        receipt.name = "control-action-receipt"
        receipt.lifetime = .keepAlways
        add(receipt)
        guard observed == expected else {
            XCTFail("Single touch at \(point) expected \(expected), observed \(observed) after waiting for the accessibility update", file: file, line: line)
            return false
        }
        return true
    }

    @MainActor func testPictureRemainsInteractiveOutsideControlFrames() {
        let app = XCUIApplication()
        app.launchArguments = ["controls"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["top.0"].waitForExistence(timeout: 5))
        let point = CGVector(dx: 0.1, dy: 0.5)
        app.coordinate(withNormalizedOffset: point).tap()
        _ = requireAction(app.staticTexts["control.last"], id: "picture", events: 1, point: point)
    }
    @MainActor func testDoubleTapAcrossPictureFiresOnceWithoutTogglingControls() {
        let app = XCUIApplication()
        app.launchArguments = ["controls"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let bottom = app.buttons["bottom.0"]
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        let pictureY = (app.buttons["plain"].frame.maxY + bottom.frame.minY) / 2
        let y = (pictureY - app.frame.minY) / app.frame.height
        let result = app.staticTexts["control.last"]
        for (index, x) in [CGFloat(0.1), 0.5, 0.9].enumerated() {
            let point = CGVector(dx: x, dy: y)
            app.coordinate(withNormalizedOffset: point).doubleTap()
            guard requireAction(result, id: "playback", events: index + 1, point: point) else { return }
        }
    }

    @MainActor func testReferenceControlCorners() {
        checkReferences(arguments: ["controls"], ids: ["reference", "plain", "styled.rectangle"])
    }
    @MainActor func testReferenceControlCornersWithoutPictureLayer() {
        checkReferences(arguments: ["controls", "no-picture"], ids: ["reference", "plain", "styled.rectangle"])
    }
    @MainActor func testNativeReferenceControlCorners() {
        checkReferences(arguments: ["controls"], ids: ["native.reference"])
    }
    @MainActor func testControlCornersAfterPortraitAndOppositeLandscapeRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["controls"]
        app.launch()
        let result = app.staticTexts["control.last"]
        var events = 0
        for orientation in [UIDeviceOrientation.portrait, .landscapeRight, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for id in ["plain", "dock.2"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                for point in [CGVector(dx: 0.04, dy: 0.04), CGVector(dx: 0.96, dy: 0.04), CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.04, dy: 0.96), CGVector(dx: 0.96, dy: 0.96)] {
                    button.coordinate(withNormalizedOffset: point).tap()
                    events += 1
                    guard requireAction(result, id: id, events: events, point: point) else { return }
                }
            }
        }
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
                guard requireAction(result, id: id, events: events, point: point) else { return }
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
                guard requireAction(result, id: id, events: events, point: point) else { return }
            }
        }
    }
}
