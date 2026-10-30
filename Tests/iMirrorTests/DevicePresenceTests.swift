import XCTest
@testable import iMirror

final class DevicePresenceTests: XCTestCase {
    func testUSBDiscoveryDistinguishesAbsenceNetworkAndFailure() {
        XCTAssertEqual(DevicePresence.parse("{\"deviceList\":[]}", exitCode: 0), .absent)
        XCTAssertEqual(DevicePresence.parse("{\"deviceList\":[{\"Udid\":\"phone\",\"ConnectionType\":\"USB\"}]}", exitCode: 0), .present)
        XCTAssertEqual(DevicePresence.parse("{\"deviceList\":[{\"Udid\":\"phone\",\"ConnectionType\":\"Network\"}]}", exitCode: 0), .absent)
        XCTAssertEqual(DevicePresence.parse("{\"deviceList\":[]}", exitCode: 1), .unavailable)
        XCTAssertEqual(DevicePresence.parse("{\"deviceList\":[{}]}", exitCode: 0), .unavailable)
        XCTAssertEqual(DevicePresence.parse("not JSON", exitCode: 0), .unavailable)
    }

    func testOnlyVerifiedAbsentToPresentRearmsRecovery() {
        var pending: ((DevicePresence) -> Void)?
        var transitions: [Bool] = []
        let monitor = DevicePresenceMonitor(interval: 0, discover: { pending = $0 },
                                            onChange: { _, reattached in transitions.append(reattached) })
        for presence: DevicePresence in [.present, .unavailable, .present, .absent, .unavailable, .present, .present] {
            monitor.sampleIfDue()
            pending?(presence)
            drainMainQueue()
        }
        XCTAssertEqual(transitions, [false, false, false, false, false, true, false])
    }

    func testDiscoveryIsRateLimitedAndNeverOverlaps() {
        var now: TimeInterval = 0
        var requests = 0
        var complete: ((DevicePresence) -> Void)?
        let monitor = DevicePresenceMonitor(now: { now }, discover: { requests += 1; complete = $0 }, onChange: { _, _ in })
        monitor.sampleIfDue()
        now = 20
        monitor.sampleIfDue(force: true)
        XCTAssertEqual(requests, 1)
        complete?(.absent)
        drainMainQueue()
        monitor.sampleIfDue()
        XCTAssertEqual(requests, 2)
        complete?(.present)
        drainMainQueue()
        now = 25
        monitor.sampleIfDue()
        XCTAssertEqual(requests, 2)
        now = 26
        monitor.sampleIfDue()
        XCTAssertEqual(requests, 3)
    }

    func testResetDropsStaleDiscoveryAndConnectedDropsOldAbsence() {
        var complete: ((DevicePresence) -> Void)?
        var states: [DevicePresence] = []
        let monitor = DevicePresenceMonitor(discover: { complete = $0 }, onChange: { state, _ in states.append(state) })
        monitor.sampleIfDue()
        complete?(.absent)
        monitor.reset()
        drainMainQueue()
        XCTAssertTrue(states.isEmpty)
        monitor.sampleIfDue()
        complete?(.absent)
        monitor.markConnected()
        drainMainQueue()
        XCTAssertTrue(states.isEmpty)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "discovery delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}

final class BoundedProcessRunnerTests: XCTestCase {
    func testHangingCommandIsKilledAtDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = BoundedProcessRunner.run("/bin/sleep", ["10"], timeout: 0.05)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.code, -1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testCapturesFailureAndBoundsReturnedOutput() {
        let result = BoundedProcessRunner.run("/bin/sh", ["-c", "printf 123456789; exit 7"], maxOutputBytes: 4)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.code, 7)
        XCTAssertEqual(result.out, "1234")
    }

    func testSpawnFailureIsDistinctFromTimeout() {
        let result = BoundedProcessRunner.run("/no/such/imirror-command", [])
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.code, -1)
    }
}


final class DeviceDiscoveryIntegrationTests: XCTestCase {
    func testStderrWarningDoesNotHideSuccessfulAbsentDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-ios")
        let script = """
        #!/bin/sh
        printf '%s\n' '{"level":"warning","msg":"tunnel agent unavailable"}' >&2
        printf '%s\n' '{"deviceList":[]}'
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let transport = Transport(goios: binary)
        let discovered = expectation(description: "stdout discovery parsed")
        transport.discoverDevicePresence { presence in
            XCTAssertEqual(presence, .absent)
            discovered.fulfill()
        }
        wait(for: [discovered], timeout: 2)
    }
}
