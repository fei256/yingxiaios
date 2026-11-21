import XCTest
import SwiftUI
@testable import SearchInputChecks

final class PictureGestureHitTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testOverlappingControlAndRowRegionsStayExcluded() {
        let shape = PictureGestureHitShape(excludedHitRegions: [
            CGRect(x: 30, y: 20, width: 200, height: 60),
            CGRect(x: 50, y: 30, width: 48, height: 48),
            CGRect(x: 160, y: 50, width: 120, height: 60)
        ], globalOrigin: .zero)
        let path = shape.path(in: bounds)
        for point in [CGPoint(x: 52, y: 32), CGPoint(x: 96, y: 76), CGPoint(x: 200, y: 60), CGPoint(x: 270, y: 100)] {
            XCTAssertFalse(path.contains(point), "Overlapping exclusions must never restore picture touches")
        }
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 50)))
        XCTAssertTrue(path.contains(CGPoint(x: 240, y: 30)))
        XCTAssertTrue(path.contains(CGPoint(x: 200, y: 200)))
    }

    func testWindowAndSafeAreaOffsetsMapToLocalPictureCoordinates() {
        let shape = PictureGestureHitShape(excludedHitRegions: [
            CGRect(x: 112, y: 144, width: 48, height: 48)
        ], globalOrigin: CGPoint(x: 100, y: 120))
        let path = shape.path(in: bounds)
        XCTAssertFalse(path.contains(CGPoint(x: 14, y: 26)))
        XCTAssertFalse(path.contains(CGPoint(x: 58, y: 70)))
        XCTAssertTrue(path.contains(CGPoint(x: 114, y: 146)))
    }

    func testOffscreenAndInvalidRegionsDoNotExpandPictureHitArea() {
        let shape = PictureGestureHitShape(excludedHitRegions: [
            .null, .infinite, .zero, CGRect(x: -20, y: -20, width: 50, height: 50),
            CGRect(x: 450, y: 350, width: 48, height: 48)
        ], globalOrigin: .zero)
        let path = shape.path(in: bounds)
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 40, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: -10, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: 420, y: 200)))
    }

    func testClearedControlsRestoreWholePicture() {
        let shape = PictureGestureHitShape(excludedHitRegions: [], globalOrigin: CGPoint(x: 40, y: 24))
        let path = shape.path(in: bounds)
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(path.contains(CGPoint(x: 398, y: 298)))
    }
}
