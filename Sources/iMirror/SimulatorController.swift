// Boots an iOS Simulator and brings up WebDriverAgent on it (loopback :8201), so
// the imirror-sim MCP server can drive it. Phase 1 delegates the actual WDA build
// to scripts/sim-wda-up.sh and supervises it with ManagedProcess. The script comes
// from the repo checkout (dev) or a copy of the app's bundled tools/+scripts/ staged
// into Application Support (packaged). Viewing is via
// Apple's Simulator.app — this type manages lifecycle + status only.

import Foundation
import iMirrorCore

enum SimState: Equatable {
    case idle, booting, building, starting, ready
    case failed(String)
}

final class SimulatorController {
    static let port = 8201
    var onState: ((SimState) -> Void)?

    private var wda: ManagedProcess?
    private let queue = DispatchQueue(label: "com.imirror.sim", qos: .userInitiated)
    private var polling = false
    private let workDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror/sim", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: Discovery

    /// True when full Xcode (not just Command Line Tools) is present — needed to
    /// build/launch the XCUITest runner. Gates the whole feature in the UI.
    func xcodeAvailable() -> Bool {
        run("/usr/bin/xcrun", ["xcodebuild", "-version"]).code == 0
    }

    func listSimulators() -> [SimDevice] {
        let r = run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"])
        guard r.code == 0, let data = r.out.data(using: .utf8) else { return [] }
        return SimctlParsing.parseSimulators(data)
    }

    // MARK: Process helper

    @discardableResult
    private func run(_ launch: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Bring-up (Phase 1: delegate to scripts/sim-wda-up.sh)

    private var stageDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror/wda-stage", isDirectory: true)
    }

    /// The directory to run `scripts/sim-wda-up.sh` from: the repo checkout when
    /// running from source (Phase 1 behavior), otherwise a staged copy of the app's
    /// bundled `tools/`+`scripts/`. Returns nil when neither is available. Runs on
    /// `queue` (the stage copy can take a moment); never on the main thread.
    private func resolvedRoot() -> URL? {
        let fm = FileManager.default
        // 1. Dev checkout — the repo tree next to this source file.
        let repo = URL(fileURLWithPath: #filePath)          // Sources/iMirror/SimulatorController.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if fm.fileExists(atPath: repo.appendingPathComponent("scripts/sim-wda-up.sh").path) {
            return repo
        }
        // 2. Packaged — stage the bundled copy into a writable dir, once per app build.
        guard let res = Bundle.main.resourceURL,
              fm.fileExists(atPath: res.appendingPathComponent("scripts/sim-wda-up.sh").path)
        else { return nil }
        return stageBundledResources(from: res)
    }

    /// Copy the bundled `tools/`+`scripts/` into `stageDir` when missing or stale
    /// (marker != current app build), then return `stageDir`. nil on copy failure.
    private func stageBundledResources(from res: URL) -> URL? {
        let fm = FileManager.default
        let dir = stageDir
        let marker = dir.appendingPathComponent(".app-build")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let current = try? String(contentsOf: marker, encoding: .utf8)
        let present = fm.fileExists(atPath: dir.appendingPathComponent("scripts/sim-wda-up.sh").path)
        if !present || !StageMarker.isCurrent(marker: current, appBuild: build) {
            try? fm.removeItem(at: dir)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: res.appendingPathComponent("tools"),
                                to: dir.appendingPathComponent("tools"))
                try fm.copyItem(at: res.appendingPathComponent("scripts"),
                                to: dir.appendingPathComponent("scripts"))
                try build.write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return dir
    }

    /// Boot `udid` and bring up WDA on :8201. Safe to call from the main thread —
    /// all blocking work (shell-outs, readiness polling) runs on a background queue;
    /// state is reported back via `onState` on the main thread.
    func enable(udid: String) {
        emit(.booting)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.xcodeAvailable() else { return self.emit(.failed("Requires Xcode.")) }
            guard let root = self.resolvedRoot() else {
                return self.emit(.failed("Simulator support isn't available in this build."))
            }
            let script = root.appendingPathComponent("scripts/sim-wda-up.sh")
            let proj = root.appendingPathComponent("tools/WebDriverAgent/WebDriverAgent.xcodeproj")
            _ = self.run("/usr/bin/xcrun", ["simctl", "boot", udid])   // no-op if already booted
            _ = self.run("/usr/bin/open", ["-a", "Simulator"])

            // The script builds (branding/sign) then execs `xcodebuild test-without-building`,
            // so the child stays alive as long as WDA runs; ManagedProcess restarts it if it dies.
            self.emit(.building)
            let cmd = "PORT=\(Self.port)"
                + " WDA_PROJECT='\(self.shellEscape(proj.path))'"
                + " '\(self.shellEscape(script.path))' '\(self.shellEscape(udid))'"
            let proc = ManagedProcess(binary: URL(fileURLWithPath: "/bin/bash"),
                                      args: ["-lc", cmd],
                                      label: "sim-wda", restartDelay: 6, workDir: self.workDir)
            self.wda?.stop()   // never leak a prior runner on a repeated enable
            self.wda = proc
            proc.start()
            self.startPolling()
        }
    }

    func disable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.polling = false
            self.wda?.stop(); self.wda = nil
            self.emit(.idle)
        }
    }

    // MARK: Readiness

    // Poll on the background queue so the ~4s readiness check never blocks the UI.
    private func startPolling() {
        guard !polling else { return }
        emit(.starting)
        polling = true
        pollTick()
    }

    private func pollTick() {
        guard polling else { return }
        if wdaReady() { polling = false; emit(.ready); return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pollTick() }
    }

    /// Escape a string for safe embedding inside single quotes in a `bash -lc` command.
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func wdaReady() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/status") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { ok = s.contains("\"ready\" : true") || s.contains("\"ready\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return ok
    }

    private func emit(_ s: SimState) { DispatchQueue.main.async { self.onState?(s) } }
}
