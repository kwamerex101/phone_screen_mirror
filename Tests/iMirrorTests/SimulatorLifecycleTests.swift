import XCTest
@testable import iMirror

final class SimulatorLifecycleTests: XCTestCase {
    func testShutdownCancelsStartupBeforeBootingOrLaunchingSimulator() {
        let enteredXcodeCheck = expectation(description: "checking Xcode")
        let releaseCheck = DispatchSemaphore(value: 0)
        let staleUI = expectation(description: "cancelled startup must not report ready")
        staleUI.isInverted = true
        let controller = SimulatorController(runCommand: { _, args in
            XCTAssertEqual(args, ["xcodebuild", "-version"], "cancelled startup still booted or opened a simulator")
            enteredXcodeCheck.fulfill()
            _ = releaseCheck.wait(timeout: .now() + 1)
            return (0, "Xcode")
        })
        controller.onState = { state in if state != .booting { staleUI.fulfill() } }
        controller.enable(udid: "cancelled-device")
        wait(for: [enteredXcodeCheck], timeout: 1)
        controller.shutdown()
        releaseCheck.signal()
        wait(for: [staleUI], timeout: 0.1)
    }

    func testDisableCancelsStartupAndReportsIdle() {
        let enteredXcodeCheck = expectation(description: "checking Xcode")
        let idle = expectation(description: "disabled")
        let releaseCheck = DispatchSemaphore(value: 0)
        let controller = SimulatorController(runCommand: { _, args in
            XCTAssertEqual(args, ["xcodebuild", "-version"])
            enteredXcodeCheck.fulfill()
            _ = releaseCheck.wait(timeout: .now() + 1)
            return (0, "Xcode")
        })
        controller.onState = { if $0 == .idle { idle.fulfill() } }
        controller.enable(udid: "cancelled-device")
        wait(for: [enteredXcodeCheck], timeout: 1)
        controller.disable()
        releaseCheck.signal()
        wait(for: [idle], timeout: 1)
    }
}
