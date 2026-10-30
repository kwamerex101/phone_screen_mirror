import XCTest
@testable import iMirror

final class SimulatorHealthMonitorTests: XCTestCase {
    func testReadinessIsRevokedAndRestoredAfterRunnerDrops() {
        let queue = DispatchQueue(label: "sim-health-test")
        let recovered = expectation(description: "ready, disconnected, ready")
        var checks = 0
        var states: [SimState] = []
        let monitor = SimulatorHealthMonitor(queue: queue, interval: 0.01,
            check: { checks += 1; return checks != 2 },
            onState: { state in
                states.append(state)
                if states.count == 3 { recovered.fulfill() }
            })
        queue.async { monitor.start() }
        wait(for: [recovered], timeout: 1)
        queue.sync { monitor.stop() }
        XCTAssertEqual(states, [.ready, .starting, .ready])
    }

    func testStartupHasAFiniteDeadline() {
        let queue = DispatchQueue(label: "sim-startup-test")
        let failed = expectation(description: "startup failed")
        let monitor = SimulatorHealthMonitor(queue: queue, interval: 0.01, startupTimeout: 0.03,
            check: { false }, onState: { if case .failed = $0 { failed.fulfill() } })
        queue.async { monitor.start() }
        wait(for: [failed], timeout: 1)
        queue.sync { monitor.stop() }
    }

    func testRecoveryHasItsOwnDeadline() {
        let queue = DispatchQueue(label: "sim-recovery-test")
        let failed = expectation(description: "lost connection failed")
        var checks = 0
        let monitor = SimulatorHealthMonitor(queue: queue, interval: 0.01,
            startupTimeout: 5, recoveryTimeout: 0.03,
            check: { checks += 1; return checks == 1 },
            onState: { if case .failed = $0 { failed.fulfill() } })
        queue.async { monitor.start() }
        wait(for: [failed], timeout: 1)
        queue.sync { monitor.stop() }
    }

    func testStopInvalidatesScheduledPolls() {
        let queue = DispatchQueue(label: "sim-stop-test")
        let polledAfterStop = expectation(description: "no stale polling")
        polledAfterStop.isInverted = true
        var checks = 0
        let monitor = SimulatorHealthMonitor(queue: queue, interval: 0.01,
            check: { checks += 1; if checks > 1 { polledAfterStop.fulfill() }; return true },
            onState: { _ in })
        queue.sync { monitor.start(); monitor.stop() }
        wait(for: [polledAfterStop], timeout: 0.08)
        XCTAssertEqual(checks, 1)
    }
}
