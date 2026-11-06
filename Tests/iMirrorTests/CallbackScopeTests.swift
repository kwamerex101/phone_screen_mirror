import XCTest
@testable import iMirror

final class CallbackScopeTests: XCTestCase {
    func testUSBResumeSupersedesPendingUnavailableEvent() {
        let scope = MainQueueCallbackScope()
        var updates: [USBVideoUpdate] = []
        let deliver = scope.deliveringLatest { updates.append($0) }
        deliver(.unavailable("stalled"))
        deliver(.frame(CGSize(width: 1200, height: 800)))
        drainMainQueue()
        XCTAssertEqual(updates, [.frame(CGSize(width: 1200, height: 800))])
        deliver(.frame(CGSize(width: 800, height: 1200)))
        deliver(.unavailable("unplugged"))
        drainMainQueue()
        XCTAssertEqual(updates.last, .unavailable("unplugged"))
    }

    func testVideoBurstDeliversOnlyNewestPendingUpdate() {
        let scope = MainQueueCallbackScope()
        var values: [Int?] = []
        let frame = scope.deliveringLatest { (value: Int?) in values.append(value) }
        for index in 0..<1000 { frame(index) }
        drainMainQueue()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.last!, 999)
        frame(1000)
        frame(nil) // a disconnect supersedes a pending frame
        drainMainQueue()
        XCTAssertEqual(values.count, 2)
        XCTAssertNil(values.last!)
        frame(1001)
        scope.invalidate()
        drainMainQueue()
        XCTAssertEqual(values.count, 2)
    }

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
