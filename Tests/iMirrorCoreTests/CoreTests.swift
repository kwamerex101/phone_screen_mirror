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

final class MCPConfigTests: XCTestCase {
    private func parse(_ d: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    func testMergeIntoEmptyCreatesEntry() throws {
        let out = try MCPConfig.merged(into: nil, name: "imirror",
                                       command: "/venv/python", args: ["/x/imirror_mcp.py"])
        let servers = parse(out)["mcpServers"] as! [String: Any]
        let entry = servers["imirror"] as! [String: Any]
        XCTAssertEqual(entry["command"] as? String, "/venv/python")
        XCTAssertEqual(entry["args"] as? [String], ["/x/imirror_mcp.py"])
    }

    func testMergePreservesExistingServers() throws {
        let existing = #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.data(using: .utf8)
        let out = try MCPConfig.merged(into: existing, name: "imirror",
                                       command: "/venv/python", args: ["/s.py"])
        let root = parse(out)
        XCTAssertEqual(root["theme"] as? String, "dark")             // unrelated key kept
        let servers = root["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"])                            // other server kept
        XCTAssertNotNil(servers["imirror"])                          // ours added
    }

    func testMergeReplacesOwnEntry() throws {
        let first = try MCPConfig.merged(into: nil, name: "imirror", command: "/old", args: [])
        let second = try MCPConfig.merged(into: first, name: "imirror", command: "/new", args: ["/s.py"])
        let entry = (parse(second)["mcpServers"] as! [String: Any])["imirror"] as! [String: Any]
        XCTAssertEqual(entry["command"] as? String, "/new")          // updated in place, not duplicated
    }

    func testRemovedDropsEntryAndKeepsOthers() throws {
        let existing = #"{"mcpServers":{"other":{"command":"x"},"imirror":{"command":"y"}}}"#.data(using: .utf8)
        let out = try MCPConfig.removed(from: existing, name: "imirror")
        XCTAssertNotNil(out)
        let servers = parse(out!)["mcpServers"] as! [String: Any]
        XCTAssertNil(servers["imirror"])
        XCTAssertNotNil(servers["other"])
    }

    func testRemovedReturnsNilWhenAbsent() throws {
        XCTAssertNil(try MCPConfig.removed(from: nil, name: "imirror"))
        let noneOfOurs = #"{"mcpServers":{"other":{}}}"#.data(using: .utf8)
        XCTAssertNil(try MCPConfig.removed(from: noneOfOurs, name: "imirror"))
    }

    func testContains() {
        let has = #"{"mcpServers":{"imirror":{}}}"#.data(using: .utf8)
        XCTAssertTrue(MCPConfig.contains(has, name: "imirror"))
        XCTAssertFalse(MCPConfig.contains(#"{}"#.data(using: .utf8), name: "imirror"))
        XCTAssertFalse(MCPConfig.contains(nil, name: "imirror"))
    }
}
