import CoreGraphics
import XCTest
@testable import iMirrorCore

final class GeometryTests: XCTestCase {
    func testMapCenter() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 200)
        let p = mapToDevice(viewPoint: CGPoint(x: 50, y: 100),
                            videoRect: rect, deviceSize: CGSize(width: 430, height: 932))
        XCTAssertEqual(p!.x, 215, accuracy: 0.01)
        XCTAssertEqual(p!.y, 466, accuracy: 0.01)   // center maps to center
    }

    func testYFlip() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 200)
        // Top of the view (y-up max) → top of the device (y == 0).
        let top = mapToDevice(viewPoint: CGPoint(x: 50, y: 200), videoRect: rect,
                              deviceSize: CGSize(width: 430, height: 932))
        XCTAssertEqual(top!.y, 0, accuracy: 0.01)
        // Bottom of the view (y == 0) → bottom of the device (y == height).
        let bottom = mapToDevice(viewPoint: CGPoint(x: 50, y: 0), videoRect: rect,
                                 deviceSize: CGSize(width: 430, height: 932))
        XCTAssertEqual(bottom!.y, 932, accuracy: 0.01)
    }

    func testLetterboxOffset() {
        // Video centered in a wider view with 20pt side bars.
        let rect = CGRect(x: 20, y: 0, width: 100, height: 200)
        XCTAssertNil(mapToDevice(viewPoint: CGPoint(x: 10, y: 100), videoRect: rect,
                                 deviceSize: CGSize(width: 430, height: 932)))  // in the bar
        let edge = mapToDevice(viewPoint: CGPoint(x: 20, y: 100), videoRect: rect,
                               deviceSize: CGSize(width: 430, height: 932))
        XCTAssertEqual(edge!.x, 0, accuracy: 0.01)   // left edge of video
    }

    func testOutsideReturnsNil() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 200)
        XCTAssertNil(mapToDevice(viewPoint: CGPoint(x: -1, y: 100), videoRect: rect,
                                 deviceSize: CGSize(width: 430, height: 932)))
    }

    func testEmptyVideoRect() {
        XCTAssertNil(mapToDevice(viewPoint: .zero, videoRect: .zero,
                                 deviceSize: CGSize(width: 430, height: 932)))
    }

    func testDownsampleCapsCount() {
        let pts = (0..<100).map { CGPoint(x: Double($0), y: 0) }
        let out = downsample(pts, max: 24)
        XCTAssertEqual(out.count, 24)
        XCTAssertEqual(out.first, pts.first)   // keeps endpoints
        XCTAssertEqual(out.last, pts.last)
    }

    func testDownsampleShortPathUnchanged() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(downsample(pts, max: 24), pts)
    }
}

final class WDAParseTests: XCTestCase {
    func testSessionIdWrapped() {
        XCTAssertEqual(WDAParse.sessionId(["value": ["sessionId": "abc"]]), "abc")
    }
    func testSessionIdTopLevel() {
        XCTAssertEqual(WDAParse.sessionId(["sessionId": "xyz"]), "xyz")
    }
    func testSessionIdMissing() {
        XCTAssertNil(WDAParse.sessionId(["value": [:]]))
    }
    func testWindowSize() {
        let s = WDAParse.windowSize(["value": ["width": 430, "height": 932]])
        XCTAssertEqual(s, CGSize(width: 430, height: 932))
    }
    func testWindowSizeMissing() {
        XCTAssertNil(WDAParse.windowSize(["value": ["width": 430]]))
    }
    func testReady() {
        XCTAssertTrue(WDAParse.ready(["value": ["ready": true]]))
        XCTAssertFalse(WDAParse.ready(["value": ["ready": false]]))
        XCTAssertFalse(WDAParse.ready(nil))
    }
}
