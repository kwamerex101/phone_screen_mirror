import XCTest
@testable import iMirrorCore

final class VideoRecoveryClockTests: XCTestCase {
    func testControlFailureDoesNotMakeFreshVideoUnhealthy() {
        var clock = VideoRecoveryClock()
        clock.beginStartup(at: 0)
        clock.receivedFrame(at: 5)
        XCTAssertTrue(clock.hasFreshFrame(at: 6, threshold: 20))
        XCTAssertEqual(clock.noFrameDuration(at: 6, controlConnected: false), 1)
        XCTAssertEqual(clock.noFrameDuration(at: 26, controlConnected: false), 21)
    }

    func testRestartDoesNotInheritPreviousVideoTimeout() {
        var clock = VideoRecoveryClock()
        clock.beginStartup(at: 0)
        clock.receivedFrame(at: 1)
        XCTAssertEqual(clock.noFrameDuration(at: 50, controlConnected: false), 49)
        clock.beginStartup(at: 50)
        XCTAssertFalse(clock.hasFreshFrame(at: 51, threshold: 20))
        XCTAssertNil(clock.noFrameDuration(at: 80, controlConnected: false))
        // Runner preparation took 30 seconds. Its launch gets a fresh budget.
        clock.beginStartup(at: 80)
        XCTAssertEqual(clock.noFrameDuration(at: 81, controlConnected: true), 1)
    }

    func testVideoRecoveryResumesAfterFirstFrameWithoutControl() {
        var clock = VideoRecoveryClock()
        clock.beginStartup(at: 100)
        XCTAssertNil(clock.noFrameDuration(at: 160, controlConnected: false))
        clock.receivedFrame(at: 161)
        XCTAssertEqual(clock.noFrameDuration(at: 182, controlConnected: false), 21)
        clock.receivedFrame(at: 183)
        XCTAssertTrue(clock.hasFreshFrame(at: 184, threshold: 20))
    }

    func testDisabledVideoHasNoRecoveryDeadline() {
        var clock = VideoRecoveryClock()
        clock.receivedFrame(at: 10)
        clock.clear()
        XCTAssertFalse(clock.hasFreshFrame(at: 11, threshold: 20))
        XCTAssertNil(clock.noFrameDuration(at: 100, controlConnected: true))
    }
}
