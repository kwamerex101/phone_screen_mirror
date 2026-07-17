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

final class RunnerInstallTests: XCTestCase {
    func testClassifyNotProvisioned() {
        // go-ios surfaces the underlying MobileInstallation / signing text.
        for s in [
            "ApplicationVerificationFailed: no valid provisioning profile found",
            "The executable was signed with invalid entitlements",
            "This device is not eligible for the installed profile",
            "install failed: 0xe8008015 (A valid provisioning profile was not found)",
        ] {
            guard case .notProvisioned = classifyInstallError(s) else {
                return XCTFail("expected .notProvisioned for: \(s)")
            }
        }
    }

    func testClassifyDeviceLocked() {
        for s in ["The device is locked.", "Please unlock the device with your passcode"] {
            guard case .deviceLocked = classifyInstallError(s) else {
                return XCTFail("expected .deviceLocked for: \(s)")
            }
        }
    }

    func testClassifyOtherKeepsRaw() {
        guard case .other(let raw) = classifyInstallError("  something weird happened  ") else {
            return XCTFail("expected .other")
        }
        XCTAssertEqual(raw, "something weird happened")   // trimmed
    }

    func testClassifyCapsLongRaw() {
        let long = String(repeating: "x", count: 1000)
        guard case .other(let raw) = classifyInstallError(long) else { return XCTFail() }
        XCTAssertLessThanOrEqual(raw.count, 301)          // capped (+ ellipsis)
    }

    func testShouldSpawnRunwda() {
        XCTAssertTrue(shouldSpawnRunwda(after: .alreadyPresent))
        XCTAssertTrue(shouldSpawnRunwda(after: .installed))
        XCTAssertTrue(shouldSpawnRunwda(after: .noBundle))
        XCTAssertFalse(shouldSpawnRunwda(after: .failed(.deviceLocked(raw: "x"))))
        XCTAssertFalse(shouldSpawnRunwda(after: .failed(.other(raw: "x"))))
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

    func testEntryReadsCommandAndArgs() {
        let cfg = #"{"mcpServers":{"imirror":{"command":"/venv/python","args":["/old/x.py"]}}}"#.data(using: .utf8)
        let e = MCPConfig.entry(cfg, name: "imirror")
        XCTAssertEqual(e?.command, "/venv/python")
        XCTAssertEqual(e?.args, ["/old/x.py"])          // used to detect a stale registration
        XCTAssertNil(MCPConfig.entry(cfg, name: "nope"))
    }

    func testEntryEnvReadsEnvBack() throws {
        let out = try MCPConfig.merged(into: nil, name: "imirror-sim",
                                       command: "/py", args: ["/s.py"],
                                       env: ["IMIRROR_TARGET": "simulator",
                                             "IMIRROR_WDA": "http://127.0.0.1:8201"])
        let env = MCPConfig.entryEnv(out, name: "imirror-sim")
        XCTAssertEqual(env["IMIRROR_TARGET"], "simulator")
        XCTAssertEqual(env["IMIRROR_WDA"], "http://127.0.0.1:8201")
    }

    func testEntryEnvEmptyWhenNoEnvOrAbsent() throws {
        let out = try MCPConfig.merged(into: nil, name: "imirror",
                                       command: "/py", args: ["/s.py"])
        XCTAssertEqual(MCPConfig.entryEnv(out, name: "imirror"), [:])
        XCTAssertEqual(MCPConfig.entryEnv(out, name: "nope"), [:])
        XCTAssertEqual(MCPConfig.entryEnv(nil, name: "imirror"), [:])
    }
}

final class MCPProfileTests: XCTestCase {
    func testDeviceProfile() {
        XCTAssertEqual(MCPProfile.device.serverName, "imirror")
        XCTAssertTrue(MCPProfile.device.env.isEmpty)
    }

    func testSimulatorProfile() {
        XCTAssertEqual(MCPProfile.simulator.serverName, "imirror-sim")
        XCTAssertEqual(MCPProfile.simulator.env["IMIRROR_TARGET"], "simulator")
        XCTAssertEqual(MCPProfile.simulator.env["IMIRROR_WDA"], "http://127.0.0.1:8201")
    }
}

final class SimctlParsingTests: XCTestCase {
    private let json = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
        {"udid":"AAA","name":"iPhone 17 Pro","state":"Booted","isAvailable":true},
        {"udid":"BBB","name":"iPhone 17","state":"Shutdown","isAvailable":true}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[
        {"udid":"WWW","name":"Apple Watch","state":"Shutdown","isAvailable":true}
      ]
    }}
    """.data(using: .utf8)!

    func testParsesAndSortsBootedFirst() {
        let sims = SimctlParsing.parseSimulators(json)
        XCTAssertEqual(sims.map(\.udid), ["AAA", "WWW", "BBB"])
        XCTAssertEqual(sims[0], SimDevice(udid: "AAA", name: "iPhone 17 Pro",
                                          runtime: "iOS 26.5", isBooted: true))
    }

    func testRuntimeHumanized() {
        let sims = SimctlParsing.parseSimulators(json)
        XCTAssertEqual(sims.first(where: { $0.udid == "WWW" })?.runtime, "watchOS 11.0")
    }

    func testEmptyOnGarbage() {
        XCTAssertEqual(SimctlParsing.parseSimulators(Data("nonsense".utf8)), [])
    }
}

final class StageMarkerTests: XCTestCase {
    func testCurrentWhenMarkerMatches() {
        XCTAssertTrue(StageMarker.isCurrent(marker: "20260708", appBuild: "20260708"))
    }
    func testStaleWhenMarkerDiffers() {
        XCTAssertFalse(StageMarker.isCurrent(marker: "20260101", appBuild: "20260708"))
    }
    func testStaleWhenMarkerNil() {
        XCTAssertFalse(StageMarker.isCurrent(marker: nil, appBuild: "20260708"))
    }
}

// MARK: - Capture watchdog liveness
//
// Regression cover for the 2026-07-17 livelock: after the iPhone's CMIO device
// re-enumerated (Dying 46 -> Publishing 48), each recovery's producer teardown
// took ~12.2s. markActive() reset the liveness clock *before* that blocking
// teardown, so by the time StartStream landed the clock already read ~12s --
// past the 5s stall threshold. The watchdog then killed the stream ~2.8s later,
// before the phone could deliver its first frame, and looped forever.
//
// Measured from the real log:
//   11:15:38.787 StopStream  -> 12.19s teardown
//   11:15:50.977 StartStream -> stream alive
//   11:15:53.790 StopStream  (killed 2.81s in, no frame yet)
final class CaptureLivenessTests: XCTestCase {

    private func state(visible: Bool = true,
                       hasInput: Bool = true,
                       sessionRunning: Bool = true,
                       secondsSinceLastFrame: TimeInterval,
                       secondsSinceRecoveryStarted: TimeInterval?,
                       consecutiveFailedRecoveries: Int = 0) -> CaptureWatchdogState {
        CaptureWatchdogState(visible: visible,
                             hasInput: hasInput,
                             sessionRunning: sessionRunning,
                             secondsSinceLastFrame: secondsSinceLastFrame,
                             secondsSinceRecoveryStarted: secondsSinceRecoveryStarted,
                             consecutiveFailedRecoveries: consecutiveFailedRecoveries)
    }

    /// The exact failing cycle: a recovery began 15s ago, its 12.2s teardown ate
    /// the clock, and the freshly started stream has not delivered a frame yet.
    /// The watchdog must NOT kill it -- that is what made the loop permanent.
    func testDoesNotPreemptAnInFlightRecovery() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 15, secondsSinceRecoveryStarted: 15))
        XCTAssertEqual(d.action, .idle,
                       "watchdog preempted its own recovery before the first frame could land")
    }

    /// A stream still frameless past the grace window is genuinely stuck --
    /// recovery must still fire, or a real stall would never heal.
    func testRecoversWhenStalledPastGrace() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 30, secondsSinceRecoveryStarted: 30))
        XCTAssertEqual(d.action, .recover(reason: "no frames >5s"))
    }

    /// First stall of a session (no prior recovery) must fire immediately.
    func testRecoversOnFirstStallWithNoPriorRecovery() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 6, secondsSinceRecoveryStarted: nil))
        XCTAssertEqual(d.action, .recover(reason: "no frames >5s"))
    }

    /// A healthy stream is left alone and reported healthy.
    func testHealthyStreamIsIdle() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 1, secondsSinceRecoveryStarted: nil))
        XCTAssertEqual(d.action, .idle)
        XCTAssertTrue(d.sourceHealthy)
        XCTAssertFalse(d.sourceLikelyDead)
    }

    /// Hidden window pauses frame delivery -- never recover, never call it dead.
    func testHiddenWindowIsIdle() {
        let d = captureWatchdogDecision(state(visible: false,
                                              secondsSinceLastFrame: 99,
                                              secondsSinceRecoveryStarted: nil,
                                              consecutiveFailedRecoveries: 9))
        XCTAssertEqual(d.action, .idle)
        XCTAssertFalse(d.sourceHealthy)
        XCTAssertFalse(d.sourceLikelyDead)
    }

    // MARK: dead-source detection (issue #31)

    /// After deadAfterFailedRecoveries frameless recoveries, the source is dead:
    /// surface replug guidance instead of claiming to mirror.
    func testDeclaresSourceDeadAfterThreshold() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 40,
                                              secondsSinceRecoveryStarted: 100,
                                              consecutiveFailedRecoveries: 3))
        XCTAssertTrue(d.sourceLikelyDead)
    }

    /// Just below the threshold is NOT dead yet -- still ordinary recovery.
    func testNotDeadJustBelowThreshold() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 40,
                                              secondsSinceRecoveryStarted: 100,
                                              consecutiveFailedRecoveries: 2))
        XCTAssertFalse(d.sourceLikelyDead)
        XCTAssertEqual(d.action, .recover(reason: "no frames >5s"))
    }

    /// A dead source retries slowly: within deadRetryInterval it stays idle (no
    /// thrash) but keeps reporting dead so the message stays up.
    func testDeadSourceRetriesSlowly() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 40,
                                              secondsSinceRecoveryStarted: 30,
                                              consecutiveFailedRecoveries: 5))
        XCTAssertEqual(d.action, .idle, "dead source should not rebind every grace window")
        XCTAssertTrue(d.sourceLikelyDead)
    }

    /// Past deadRetryInterval a dead source DOES retry once -- so a replug that
    /// re-inits the endpoint heals on its own without an app restart.
    func testDeadSourceRetriesAfterInterval() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 40,
                                              secondsSinceRecoveryStarted: 65,
                                              consecutiveFailedRecoveries: 5))
        XCTAssertEqual(d.action, .recover(reason: "no frames >5s"))
        XCTAssertTrue(d.sourceLikelyDead)
    }

    /// The false-alarm guard: a transient stall recovers within the grace window,
    /// so the counter never climbs to the dead threshold. A frame arriving after
    /// even many prior failures reports healthy, so the caller resets to 0.
    func testFrameArrivalReportsHealthyRegardlessOfHistory() {
        let d = captureWatchdogDecision(state(secondsSinceLastFrame: 1,
                                              secondsSinceRecoveryStarted: 2,
                                              consecutiveFailedRecoveries: 5))
        XCTAssertTrue(d.sourceHealthy)
        XCTAssertFalse(d.sourceLikelyDead)
        XCTAssertEqual(d.action, .idle)
    }

    /// A stopped session (not merely frameless) still recovers, with its own reason.
    func testStoppedSessionRecovers() {
        let d = captureWatchdogDecision(state(sessionRunning: false,
                                              secondsSinceLastFrame: 1,
                                              secondsSinceRecoveryStarted: nil))
        XCTAssertEqual(d.action, .recover(reason: "session stopped"))
    }
}
