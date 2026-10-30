import XCTest
@testable import iMirror

final class CallbackScopeTests: XCTestCase {
    func testDisablingAutomationRejectsAlreadyQueuedSuccess() {
        let scope = MainQueueCallbackScope()
        var connected = false
        let complete = scope.delivering { (_: Bool) in connected = true }
        complete(true)
        scope.invalidate()
        drainMainQueue()
        XCTAssertFalse(connected)
    }

    func testOldCompletionCannotClearNewProbeOrReplaceNewHealth() {
        let scope = MainQueueCallbackScope()
        var health = "down"
        var probing = true
        let old = scope.delivering { (_: Bool) in probing = false; health = "old" }
        scope.invalidate()
        let current = scope.delivering { (_: Bool) in health = "new" }
        current(true)
        old(true)
        drainMainQueue()
        XCTAssertEqual(health, "new")
        XCTAssertTrue(probing)
    }

    func testCurrentCallbackStillDelivers() {
        let scope = MainQueueCallbackScope()
        var delivered = false
        scope.delivering { (_: Bool) in delivered = true }(true)
        drainMainQueue()
        XCTAssertTrue(delivered)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
