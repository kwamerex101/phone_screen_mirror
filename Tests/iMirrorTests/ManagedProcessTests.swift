// Real-process tests for ManagedProcess's recovery mechanisms (Transport.swift):
// bounce()'s SIGKILL escalation, and the readiness deadline that catches a
// wedged (never-exiting) child. Kept fast -- short delays, real /bin/sh
// children -- and every test stops its ManagedProcess in tearDown so no
// `sleep 100` children leak past the test run.

import XCTest
@testable import iMirror

final class ManagedProcessTests: XCTestCase {
    private var tempDir: URL!
    private var mp: ManagedProcess?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirrorTests-mp-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // stop() nils out its process reference (and escalates to SIGKILL) only
        // after a 1.5s delay on a background queue -- if this test binary exits
        // before that fires (as it can right after the last test in a run), a
        // SIGTERM-ignoring child leaks past the run. Grab the pid before stop()
        // clears it and back the escalation up with a synchronous kill, spun a
        // few times since `kill -9` on an already-exited pid is a harmless no-op
        // and a respawn racing stop() could still be settling.
        let lastPid = mp?.currentPidForTesting
        mp?.stop()
        if let lastPid {
            for _ in 0..<10 {
                if kill(lastPid, 0) != 0 { break }   // ESRCH: already gone
                kill(lastPid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        mp = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// `bounce()` must escalate to SIGKILL: a SIGTERM-ignoring child would
    /// otherwise survive terminate() and never respawn.
    func testBounceSigkillsAChildThatIgnoresSigterm() {
        // Touch a marker only once the trap is actually registered, so the test
        // waits for that instead of racing terminate() against shell startup --
        // without this, a bounce() called before `trap` runs would SIGTERM-kill
        // the child by ordinary means and never exercise the SIGKILL escalation.
        let marker = tempDir.appendingPathComponent("trap-armed")
        let process = ManagedProcess(binary: URL(fileURLWithPath: "/bin/sh"),
                                     args: ["-c", "trap \"\" TERM; touch \"$1\"; exec sleep 100",
                                            "sh", marker.path],
                                     label: "test-bounce", restartDelay: 0.1, workDir: tempDir)
        mp = process
        process.start()

        let firstPid = waitForPid(process)
        XCTAssertNotNil(firstPid, "child never started")
        XCTAssertTrue(waitForFile(marker, timeout: 2), "child never armed its TERM trap")

        process.bounce()

        let expectation = expectation(description: "respawned with a new pid")
        pollUntil(timeout: 3) {
            if let pid = process.currentPidForTesting, pid != firstPid {
                expectation.fulfill()
                return true
            }
            return false
        }
        wait(for: [expectation], timeout: 3)
    }

    /// A child that never reports ready must be killed at the deadline and
    /// respawn -- proving the readiness poll, not just the exit handler, drives
    /// recovery for a wedge that never exits on its own.
    func testReadinessDeadlineKillsAndRespawnsAnUnreadyChild() {
        let process = ManagedProcess(binary: URL(fileURLWithPath: "/bin/sh"),
                                     args: ["-c", "sleep 100"],
                                     label: "test-unready", restartDelay: 0.1, workDir: tempDir,
                                     readinessCheck: { false }, readyWithin: 0.5,
                                     readinessPollInterval: 0.2)
        mp = process
        process.start()

        let firstPid = waitForPid(process)
        XCTAssertNotNil(firstPid, "child never started")

        let expectation = expectation(description: "killed and respawned after the readiness deadline")
        pollUntil(timeout: 5) {
            if let pid = process.currentPidForTesting, pid != firstPid {
                expectation.fulfill()
                return true
            }
            return false
        }
        wait(for: [expectation], timeout: 5)
    }

    /// Repeated readiness-deadline kills must count as failures even though
    /// each spawn stays "alive" well past `healthyRuntimeSec` in wall-clock
    /// terms -- otherwise a permanently wedged child never trips the give-up
    /// breaker and the app spins on it forever.
    func testRepeatedReadinessDeadlineKillsEventuallyGiveUp() {
        let gaveUp = expectation(description: "onGaveUp fired")
        let process = ManagedProcess(binary: URL(fileURLWithPath: "/bin/sh"),
                                     args: ["-c", "sleep 100"],
                                     label: "test-give-up", restartDelay: 0.05, workDir: tempDir,
                                     readinessCheck: { false }, readyWithin: 0.3,
                                     readinessPollInterval: 0.1)
        process.onGaveUp = { _ in gaveUp.fulfill() }
        mp = process
        process.start()

        wait(for: [gaveUp], timeout: 15)
    }

    /// A readiness check that succeeds immediately must never be killed --
    /// the deadline only fires for a child that stays unready.
    func testReadyBeforeDeadlineIsNeverKilled() {
        let process = ManagedProcess(binary: URL(fileURLWithPath: "/bin/sh"),
                                     args: ["-c", "sleep 100"],
                                     label: "test-ready", restartDelay: 0.1, workDir: tempDir,
                                     readinessCheck: { true }, readyWithin: 1.0,
                                     readinessPollInterval: 0.2)
        mp = process
        process.start()

        let firstPid = waitForPid(process)
        XCTAssertNotNil(firstPid, "child never started")

        // Give the deadline (1.0s) plus margin to prove it does NOT fire: the
        // first poll tick (0.2s) already sees `readinessCheck` return true.
        let stillSame = expectation(description: "pid unchanged after the deadline window")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            XCTAssertEqual(process.currentPidForTesting, firstPid, "readiness-true child was killed anyway")
            stillSame.fulfill()
        }
        wait(for: [stillSame], timeout: 4)
    }

    // MARK: - helpers

    private func waitForPid(_ process: ManagedProcess, timeout: TimeInterval = 2) -> pid_t? {
        var result: pid_t?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = process.currentPidForTesting {
                result = pid
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return result
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Polls `condition` on a background queue until it returns true or the
    /// timeout elapses. `condition` must be safe to call repeatedly and quickly.
    private func pollUntil(timeout: TimeInterval, interval: TimeInterval = 0.1, condition: @escaping () -> Bool) {
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }
}
