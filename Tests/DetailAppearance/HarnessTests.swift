import XCTest
import UIKit

final class DetailHarnessTests: XCTestCase {
    @MainActor private func launch(orientation: UIDeviceOrientation, accessibility: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        if accessibility { app.launchArguments = ["accessibility"] }
        app.launch()
        let ready = app.staticTexts["fixture.imageStatus"]
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label == %@", "images ready"), evaluatedWith: ready)
        waitForExpectations(timeout: 20)
        XCUIDevice.shared.orientation = orientation
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(8)
        while (window.frame.width > window.frame.height) != orientation.isLandscape, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(window.frame.width > window.frame.height, orientation.isLandscape)
        return app
    }
    @MainActor private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func checkTargets(_ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for name in ["play", "sources", "link", "calendar", "more"] {
            let button = app.buttons["fixture." + name]
            XCTAssertTrue(button.exists && button.isHittable, "Missing visible action: \(name)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, window.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX + 0.5)
        }
    }
    @MainActor func testLandscapeHeaderFitsAndImagesLoad() {
        let app = launch(orientation: .landscapeLeft)
        checkTargets(app)
        XCTAssertLessThan(app.descendants(matching: .any)["fixture.title"].frame.midX, app.buttons["fixture.play"].frame.midX)
        attach("detail-landscape-ipad", app: app)
        app.buttons["fixture.play"].tap()
        XCTAssertEqual(app.staticTexts["fixture.action"].label, "play")
        for name in ["sources", "link", "calendar", "more"] {
            app.buttons["fixture." + name].tap(); XCTAssertEqual(app.staticTexts["fixture.action"].label, name)
        }
    }
    @MainActor func testPortraitHeaderKeepsEveryActionVisible() {
        let app = launch(orientation: .portrait)
        checkTargets(app)
        attach("detail-portrait-ipad", app: app)
    }
    @MainActor func testAccessibilityHeaderStacksWithoutOverflow() {
        let app = launch(orientation: .landscapeLeft, accessibility: true)
        checkTargets(app)
        attach("detail-accessibility-ipad", app: app)
    }
    @MainActor func testCompleteCacheFillsTheTrackAndClearingUpdatesIt() {
        let app = launch(orientation: .landscapeLeft)
        let track = app.otherElements["fixture.cacheTrack"]
        XCTAssertTrue(track.exists)
        let point = CGPoint(x: track.frame.minX + track.frame.width * 0.8, y: track.frame.midY)
        let before = brightness(XCUIScreen.main.screenshot(), at: point, window: app.windows.firstMatch.frame)
        attach("cache-complete-track", app: app)
        app.buttons["fixture.clearCache"].tap()
        XCTAssertEqual(track.value as? String, "partial")
        let after = brightness(XCUIScreen.main.screenshot(), at: point, window: app.windows.firstMatch.frame)
        XCTAssertGreaterThan(before, after + 0.08, "The far end of a complete cache must actually be painted")
        attach("cache-cleared-track", app: app)
        app.buttons["fixture.completeCache"].tap()
        XCTAssertEqual(track.value as? String, "complete")
    }
    @MainActor private func brightness(_ screenshot: XCUIScreenshot, at point: CGPoint, window: CGRect) -> Double {
        let snapshot = screenshot.image
        let image = UIGraphicsImageRenderer(size: snapshot.size).image { _ in snapshot.draw(at: .zero) }.cgImage!
        let scale = CGFloat(image.width) / window.width
        let pixel = image.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(bytes[0]) * 0.2126 + Double(bytes[1]) * 0.7152 + Double(bytes[2]) * 0.0722) / 255
    }
}
