# iOS Simulator + MCP Management — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a source checkout of iMirror, let the user pick an iOS Simulator in Settings, bring up WebDriverAgent on it, and register a dedicated `imirror-sim` MCP server — parallel to the existing device MCP install.

**Architecture:** Pure, testable helpers (`MCPProfile`, `simctl` JSON parsing, `MCPConfig.entryEnv`) live in the `iMirrorCore` target and are TDD'd. The app wiring — `MCPInstaller` profile plumbing, a new `SimulatorController`, and a Settings "iOS Simulator" section — lives in the `iMirror` executable target, which has no unit-test target, so those tasks are verified with `swift build` plus a manual smoke check (matching how `Transport`/`MCPInstaller`/`main.swift` are already verified). Phase 1 delegates the actual WDA build to the existing `scripts/sim-wda-up.sh`, supervised by the app's `ManagedProcess`; Phase 2 (separate plan) replaces that with an in-app build from bundled source.

**Tech Stack:** Swift 6 package (`swift build` / `swift test`), AppKit, XCTest, `xcrun simctl`, `xcodebuild`.

## Global Constraints

- Swift tools version 6.0; targets macOS 14+ (`Package.swift`). Language mode v5.
- Only `iMirrorCore` is unit-tested (`Tests/iMirrorCoreTests`). Put anything you want a unit test for in `iMirrorCore`; never add a test target for `iMirror`.
- The MCP server talks to WDA on **loopback only** — never widen a host. Device WDA is `http://127.0.0.1:8100`; **simulator WDA is `http://127.0.0.1:8201`** so the two coexist.
- Simulator MCP server name is **`imirror-sim`**; its env is exactly `IMIRROR_TARGET=simulator` and `IMIRROR_WDA=http://127.0.0.1:8201`.
- The device MCP path (server name `imirror`, empty env) must remain behavior-for-behavior unchanged.
- Keep the existing code style: explicit AppKit, no new third-party dependencies.
- Commit messages end with the repo's trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

**Create:**
- `Sources/iMirrorCore/MCPProfile.swift` — the `MCPProfile` value type (device/simulator).
- `Sources/iMirrorCore/SimctlParsing.swift` — `SimDevice` + `parseSimulators(_:)` for `simctl … -j`.
- `Sources/iMirror/SimulatorController.swift` — boots a sim, supervises WDA bring-up, polls readiness, exposes state.

**Modify:**
- `Sources/iMirrorCore/MCPConfig.swift` — add `entryEnv(_:name:)`.
- `Sources/iMirror/MCPInstaller.swift` — parameterize `install`/`uninstall`/`status` by `MCPProfile`; register env; env-aware staleness.
- `Sources/iMirror/main.swift` — add the "iOS Simulator" Settings section + handlers.
- `Tests/iMirrorCoreTests/CoreTests.swift` — tests for the three pure additions.

---

## Task 1: `MCPConfig.entryEnv` (read an entry's env back)

**Files:**
- Modify: `Sources/iMirrorCore/MCPConfig.swift`
- Test: `Tests/iMirrorCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `MCPConfig.entryEnv(_ existing: Data?, name: String) -> [String: String]` — the `env` dict a named server is registered with in a Claude-Desktop-style config, or `[:]` if absent/none.

- [ ] **Step 1: Write the failing tests** — add to the existing `MCPConfigTests` class in `Tests/iMirrorCoreTests/CoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPConfigTests/testEntryEnvReadsEnvBack`
Expected: FAIL to build with "type 'MCPConfig' has no member 'entryEnv'".

- [ ] **Step 3: Implement `entryEnv`** — add this method to `public enum MCPConfig` in `Sources/iMirrorCore/MCPConfig.swift`, right after `entry(_:name:)`:

```swift
    /// The `env` dict a named server is registered with, or `[:]` if it has none.
    /// Lets the installer detect a stale/missing environment (not just a stale path).
    public static func entryEnv(_ existing: Data?, name: String) -> [String: String] {
        guard let servers = object(from: existing)["mcpServers"] as? [String: Any],
              let e = servers[name] as? [String: Any],
              let env = e["env"] as? [String: String] else { return [:] }
        return env
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCPConfigTests`
Expected: PASS (all `MCPConfigTests`, old and new).

- [ ] **Step 5: Commit**

```bash
git add Sources/iMirrorCore/MCPConfig.swift Tests/iMirrorCoreTests/CoreTests.swift
git commit -m "feat(core): MCPConfig.entryEnv to read a server entry's env

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `MCPProfile` value type

**Files:**
- Create: `Sources/iMirrorCore/MCPProfile.swift`
- Test: `Tests/iMirrorCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct MCPProfile { public let serverName: String; public let env: [String: String]; static let device: MCPProfile; static let simulator: MCPProfile }`. `.device` = name `"imirror"`, env `[:]`. `.simulator` = name `"imirror-sim"`, env `IMIRROR_TARGET=simulator`, `IMIRROR_WDA=http://127.0.0.1:8201`.

- [ ] **Step 1: Write the failing tests** — add a new class at the end of `Tests/iMirrorCoreTests/CoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPProfileTests`
Expected: FAIL to build with "cannot find 'MCPProfile' in scope".

- [ ] **Step 3: Implement the type** — create `Sources/iMirrorCore/MCPProfile.swift`:

```swift
// Which MCP server the installer is acting on. `device` drives a physical iPhone
// (WDA on 8100, no env); `simulator` drives a booted Simulator (WDA on 8201, with
// IMIRROR_TARGET=simulator so the server takes its simulator code paths). Kept in
// iMirrorCore so the profile/env values are unit-testable.

import Foundation

public struct MCPProfile: Sendable, Equatable {
    public let serverName: String
    public let env: [String: String]

    public init(serverName: String, env: [String: String]) {
        self.serverName = serverName
        self.env = env
    }

    public static let device = MCPProfile(serverName: "imirror", env: [:])
    public static let simulator = MCPProfile(
        serverName: "imirror-sim",
        env: ["IMIRROR_TARGET": "simulator",
              "IMIRROR_WDA": "http://127.0.0.1:8201"])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCPProfileTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iMirrorCore/MCPProfile.swift Tests/iMirrorCoreTests/CoreTests.swift
git commit -m "feat(core): MCPProfile value type for device vs simulator MCP

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `simctl` JSON parsing → `[SimDevice]`

**Files:**
- Create: `Sources/iMirrorCore/SimctlParsing.swift`
- Test: `Tests/iMirrorCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct SimDevice: Equatable { public let udid: String; public let name: String; public let runtime: String; public let isBooted: Bool }`
  - `public enum SimctlParsing { public static func parseSimulators(_ data: Data) -> [SimDevice] }` — parses `xcrun simctl list devices available -j` output. Only real devices are returned; entries are sorted booted-first, then by name. `runtime` is the human tail of the runtime key (e.g. `iOS-26-5` → `iOS 26.5`).

- [ ] **Step 1: Write the failing tests** — add a new class at the end of `Tests/iMirrorCoreTests/CoreTests.swift`:

```swift
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
        XCTAssertEqual(sims.map(\.udid), ["AAA", "BBB", "WWW"])
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SimctlParsingTests`
Expected: FAIL to build with "cannot find 'SimctlParsing' in scope".

- [ ] **Step 3: Implement the parser** — create `Sources/iMirrorCore/SimctlParsing.swift`:

```swift
// Parse `xcrun simctl list devices available -j` into a flat, display-ready list.
// Pure (no shell-out) so it unit-tests against canned JSON. The controller in the
// app target does the actual shell-out and hands the bytes here.

import Foundation

public struct SimDevice: Equatable, Sendable {
    public let udid: String
    public let name: String
    public let runtime: String   // humanized, e.g. "iOS 26.5"
    public let isBooted: Bool

    public init(udid: String, name: String, runtime: String, isBooted: Bool) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.isBooted = isBooted
    }
}

public enum SimctlParsing {
    public static func parseSimulators(_ data: Data) -> [SimDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }
        var out: [SimDevice] = []
        for (runtimeKey, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            let runtime = humanizeRuntime(runtimeKey)
            for d in list {
                guard let udid = d["udid"] as? String,
                      let name = d["name"] as? String else { continue }
                let booted = (d["state"] as? String) == "Booted"
                out.append(SimDevice(udid: udid, name: name, runtime: runtime, isBooted: booted))
            }
        }
        // Booted first, then by name — stable, useful default for a picker.
        return out.sorted {
            $0.isBooted != $1.isBooted ? $0.isBooted : $0.name < $1.name
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5".
    private static func humanizeRuntime(_ key: String) -> String {
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        let parts = tail.split(separator: "-")
        guard let os = parts.first else { return tail }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(os) : "\(os) \(version)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SimctlParsingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iMirrorCore/SimctlParsing.swift Tests/iMirrorCoreTests/CoreTests.swift
git commit -m "feat(core): parse simctl device list into [SimDevice]

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `MCPInstaller` — parameterize by `MCPProfile`

**Files:**
- Modify: `Sources/iMirror/MCPInstaller.swift`

**Interfaces:**
- Consumes: `MCPProfile` (Task 2), `MCPConfig.entryEnv` (Task 1), `MCPConfig.merged(…, env:)` (existing).
- Produces (all keep a `profile: MCPProfile = .device` default so existing device call sites are unchanged):
  - `MCPInstaller.status(profile: MCPProfile = .device) -> Status`
  - `MCPInstaller.isInstalled(profile: MCPProfile = .device) -> Bool`
  - `MCPInstaller.install(profile: MCPProfile = .device, update: Bool, progress: @escaping (String) -> Void, completion: @escaping (Result) -> Void)`
  - `MCPInstaller.uninstall(profile: MCPProfile = .device, completion: @escaping (Result) -> Void)`

**Note:** No unit-test target covers `iMirror`. Verify with `swift build` and a manual CLI smoke test (below). The pure env/registration values this depends on are already covered by Tasks 1–2.

- [ ] **Step 1: Remove the hard-coded name and thread the profile through status**

In `Sources/iMirror/MCPInstaller.swift`, delete the line `static let serverName = "imirror"` and replace the `status()` / `isInstalled()` methods with profile-aware versions:

```swift
    static func isInstalled(profile: MCPProfile = .device) -> Bool { status(profile: profile).installed }

    /// Where things stand right now for one profile — installed/version/staleness.
    static func status(profile: MCPProfile = .device) -> Status {
        let name = profile.serverName
        let desiredScript = scriptURL()?.path
        let venvOK = FileManager.default.isExecutableFile(atPath: venvPython.path)
        var clients: [String] = []
        var stale = false

        if let data = try? Data(contentsOf: claudeDesktopConfig),
           let e = MCPConfig.entry(data, name: name) {
            clients.append("Claude Desktop")
            if e.command != venvPython.path || e.args.first != desiredScript { stale = true }
            if MCPConfig.entryEnv(data, name: name) != profile.env { stale = true }
        }
        if let claude = claudeCLI() {
            let r = run(claude, ["mcp", "get", name])
            if r.code == 0, r.out.contains(name) {
                clients.append("Claude Code")
                if let s = desiredScript, !r.out.contains(s) { stale = true }
                for (k, v) in profile.env where !r.out.contains("\(k)=\(v)") { stale = true }
            }
        }
        return Status(clients: clients, version: currentVersion(),
                      upToDate: !clients.isEmpty && venvOK && !stale)
    }
```

- [ ] **Step 2: Thread the profile through install**

Replace the `install(update:…)` and `doInstall(update:)` signatures/bodies. `install`:

```swift
    static func install(profile: MCPProfile = .device, update: Bool = false,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = doInstall(profile: profile, update: update, progress: progress)
            DispatchQueue.main.async { completion(result) }
        }
    }
```

In `doInstall`, change the signature to `private static func doInstall(profile: MCPProfile, update: Bool, progress: @escaping (String) -> Void) -> Result` and replace the two registration blocks (Claude Code + Claude Desktop) with env-aware versions. The venv/deps portion above them is unchanged:

```swift
        var registered: [String] = []
        let name = profile.serverName

        // 2. Claude Code (idempotent: remove any stale entry, then add with env).
        if let claude = claudeCLI() {
            progress("Registering with Claude Code…")
            _ = run(claude, ["mcp", "remove", name, "--scope", "user"])
            var addArgs = ["mcp", "add", name, "--scope", "user"]
            for (k, v) in profile.env { addArgs += ["-e", "\(k)=\(v)"] }
            addArgs += ["--", venvPython.path, script.path]
            if run(claude, addArgs).code == 0 { registered.append("Claude Code") }
        }

        // 3. Claude Desktop (only if the app dir exists — i.e. it's installed).
        let claudeDir = claudeDesktopConfig.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            progress("Updating Claude Desktop config…")
            do {
                let existing = try? Data(contentsOf: claudeDesktopConfig)
                let merged = try MCPConfig.merged(into: existing, name: name,
                                                  command: venvPython.path,
                                                  args: [script.path], env: profile.env)
                try merged.write(to: claudeDesktopConfig)
                registered.append("Claude Desktop (restart it)")
            } catch {
                return Result(ok: false, message: "Claude Desktop config write failed: \(error.localizedDescription)")
            }
        }
```

- [ ] **Step 3: Thread the profile through uninstall**

Replace `uninstall(completion:)`:

```swift
    static func uninstall(profile: MCPProfile = .device, completion: @escaping (Result) -> Void) {
        let name = profile.serverName
        DispatchQueue.global(qos: .userInitiated).async {
            var removed: [String] = []
            if let claude = claudeCLI() {
                if run(claude, ["mcp", "remove", name, "--scope", "user"]).code == 0 {
                    removed.append("Claude Code")
                }
            }
            if let data = try? Data(contentsOf: claudeDesktopConfig),
               let out = try? MCPConfig.removed(from: data, name: name) {
                try? out.write(to: claudeDesktopConfig)
                removed.append("Claude Desktop")
            }
            let msg = removed.isEmpty ? "Nothing to remove." : "Removed from " + removed.joined(separator: ", ")
            DispatchQueue.main.async { completion(Result(ok: true, message: msg)) }
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build complete, no errors. (Existing device call sites in `main.swift` — `MCPInstaller.status()`, `.install(update:…)`, `.uninstall { }` — still compile because `profile` defaults to `.device`.)

- [ ] **Step 5: Manual smoke test of the simulator profile registration**

Run:
```bash
swift build
.build/debug/iMirror >/dev/null 2>&1 &   # launch, open Settings later; or use the CLI check below
claude mcp remove imirror-sim -s user 2>/dev/null; true
```
Then, from a Swift REPL is overkill — instead verify indirectly after Task 6 wires the button. For now confirm the device server is untouched:

Run: `claude mcp get imirror`
Expected: still present, command = the app venv python, args = the repo `imirror_mcp.py`, no env.

- [ ] **Step 6: Commit**

```bash
git add Sources/iMirror/MCPInstaller.swift
git commit -m "feat(app): parameterize MCPInstaller by MCPProfile (device|simulator)

Registers the imirror-sim server with IMIRROR_TARGET/IMIRROR_WDA env, and makes
status() treat a stale/missing env as out-of-date. Device path unchanged via a
.device default.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `SimulatorController` — boot + supervised WDA bring-up

**Files:**
- Create: `Sources/iMirror/SimulatorController.swift`

**Interfaces:**
- Consumes: `SimctlParsing`/`SimDevice` (Task 3), `ManagedProcess` (existing in `Transport.swift`: `init(binary: URL, args: [String], label: String, restartDelay: TimeInterval, workDir: URL)`, `.start()`, `.stop()`).
- Produces:
  - `enum SimState: Equatable { case idle, booting, building, starting, ready, failed(String) }`
  - `final class SimulatorController` with:
    - `var onState: ((SimState) -> Void)?`
    - `func xcodeAvailable() -> Bool`
    - `func listSimulators() -> [SimDevice]`
    - `func enable(udid: String)` — boots the sim and supervises WDA on port 8201, driving `onState`.
    - `func disable()` — tears the supervised runner down, state → `.idle`.
    - `static let port = 8201`

**Note:** app target, no unit tests. Verify with `swift build`, then a manual integration run (needs Xcode + a sim + the repo checkout).

- [ ] **Step 1: Create the controller with sim listing + Xcode gating**

Create `Sources/iMirror/SimulatorController.swift`:

```swift
// Boots an iOS Simulator and brings up WebDriverAgent on it (loopback :8201), so
// the imirror-sim MCP server can drive it. Phase 1 delegates the actual WDA build
// to scripts/sim-wda-up.sh (present in a source checkout) and supervises it with
// ManagedProcess; Phase 2 will build in-process from bundled source. Viewing is via
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
    private var poll: Timer?
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
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build complete. (`SimulatorController` is unused so far — that's fine.)

- [ ] **Step 3: Add script resolution + enable/disable**

Add these members to `SimulatorController` (before the closing brace). `scriptURL()` mirrors `MCPInstaller.scriptURL()` — repo checkout in Phase 1; `wdaProjectURL()` finds the vendored WDA project:

```swift
    // MARK: Bring-up (Phase 1: delegate to scripts/sim-wda-up.sh)

    /// Repo `scripts/sim-wda-up.sh` (source checkout only in Phase 1).
    private func scriptURL() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)          // Sources/iMirror/SimulatorController.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/sim-wda-up.sh")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Repo `tools/WebDriverAgent/WebDriverAgent.xcodeproj` for the script's WDA_PROJECT.
    private func wdaProjectURL() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/WebDriverAgent/WebDriverAgent.xcodeproj")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    func enable(udid: String) {
        guard xcodeAvailable() else { return emit(.failed("Requires Xcode.")) }
        guard let script = scriptURL(), let proj = wdaProjectURL() else {
            return emit(.failed("Simulator bring-up needs a source checkout (Phase 1)."))
        }
        emit(.booting)
        _ = run("/usr/bin/xcrun", ["simctl", "boot", udid])   // no-op if already booted
        _ = run("/usr/bin/open", ["-a", "Simulator"])

        // Supervise: PORT + WDA_PROJECT as env, the chosen sim as the arg. The script
        // builds (branding/sign) then execs `xcodebuild test-without-building`, so the
        // child stays alive as long as WDA runs; ManagedProcess restarts it if it dies.
        emit(.building)
        let cmd = "PORT=\(Self.port) WDA_PROJECT='\(proj.path)' '\(script.path)' '\(udid)'"
        let proc = ManagedProcess(binary: URL(fileURLWithPath: "/bin/bash"),
                                  args: ["-lc", cmd],
                                  label: "sim-wda", restartDelay: 6, workDir: workDir)
        wda = proc
        proc.start()
        startPolling()
    }

    func disable() {
        poll?.invalidate(); poll = nil
        wda?.stop(); wda = nil
        emit(.idle)
    }

    // MARK: Readiness

    private func startPolling() {
        emit(.starting)
        poll?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.wdaReady() { self.poll?.invalidate(); self.poll = nil; self.emit(.ready) }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
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
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Manual integration check (needs Xcode + a booted sim + source checkout)**

This exercises the real bring-up outside the UI. In a scratch Swift file or via the app after Task 6, calling `enable(udid:)` should progress `booting → building → starting → ready` and leave WDA answering:

Run (after the controller is wired in Task 6, or ad hoc):
```bash
# with the app running and a sim enabled from Settings:
curl -s -m 4 http://127.0.0.1:8201/status | grep -o '"ready" : true'
```
Expected: `"ready" : true` within a few minutes of first enable (first build is slow).

- [ ] **Step 6: Commit**

```bash
git add Sources/iMirror/SimulatorController.swift
git commit -m "feat(app): SimulatorController — boot sim + supervise WDA on :8201

Phase 1 delegates the WDA build to scripts/sim-wda-up.sh under ManagedProcess
supervision, polls :8201/status for readiness, and gates on full Xcode. Viewing
is via Simulator.app.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Settings "iOS Simulator" section

**Files:**
- Modify: `Sources/iMirror/main.swift`

**Interfaces:**
- Consumes: `SimulatorController` (Task 5), `MCPInstaller` profile methods (Task 4), `SimDevice` (Task 3).
- Produces: a new Settings section with a sim picker, an Enable/Disable button, a status label, and MCP Install/Uninstall buttons that act on `.simulator`.

**Note:** Locate the window-controller class that builds the Settings popover — it's the class containing `mcpButton`, `primaryMCP()`, and `buildSettingsPopover`-style code around `Sources/iMirror/main.swift:281` and `:1431`. Add the new members and handlers to that same class.

- [ ] **Step 1: Add outlets + controller**

Near the existing `private let mcpButton = NSButton()` group (around `main.swift:281`), add:

```swift
    private let simController = SimulatorController()
    private var simDevices: [SimDevice] = []
    private let simPicker = NSPopUpButton()
    private let simEnableButton = NSButton()
    private let simStatusLabel = NSTextField(labelWithString: "")
    private let mcpSimButton = NSButton()
    private let mcpSimUninstallButton = NSButton()
    private let mcpSimSpinner = NSProgressIndicator()
    private let mcpSimStatusLabel = NSTextField(labelWithString: "")
    private var mcpSimInstalled = false
    private var simEnabled = false
```

- [ ] **Step 2: Build the section UI**

In the settings-popover builder, immediately **before** the "Version footer" block (the `verSep` separator around `main.swift:1478`), insert:

```swift
        // iOS Simulator section — pick a sim, bring up WDA on :8201, install imirror-sim.
        let simSep = NSBox(); simSep.boxType = .separator
        simSep.translatesAutoresizingMaskIntoConstraints = false
        simSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(simSep)

        let simTitle = NSTextField(labelWithString: "iOS Simulator")
        simTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(simTitle)

        let simCap = NSTextField(wrappingLabelWithString:
            "Boot a Simulator and drive it from Claude. Enable brings up WebDriverAgent "
          + "on it (port 8201); view the sim in Apple's Simulator app. Requires Xcode.")
        simCap.font = .systemFont(ofSize: 11)
        simCap.textColor = .secondaryLabelColor
        simCap.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(simCap)

        simPicker.target = self
        simPicker.action = #selector(simPicked)
        stack.addArrangedSubview(simPicker)

        simEnableButton.bezelStyle = .rounded
        simEnableButton.title = "Enable"
        simEnableButton.target = self
        simEnableButton.action = #selector(toggleSimEnable)
        stack.addArrangedSubview(simEnableButton)

        simStatusLabel.font = .systemFont(ofSize: 11)
        simStatusLabel.textColor = .secondaryLabelColor
        simStatusLabel.preferredMaxLayoutWidth = 268
        simStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(simStatusLabel)

        mcpSimButton.bezelStyle = .rounded
        mcpSimButton.title = "Install MCP server (sim)"
        mcpSimButton.target = self
        mcpSimButton.action = #selector(primaryMCPSim)
        mcpSimUninstallButton.bezelStyle = .rounded
        mcpSimUninstallButton.title = "Uninstall"
        mcpSimUninstallButton.target = self
        mcpSimUninstallButton.action = #selector(uninstallMCPSim)
        mcpSimUninstallButton.isHidden = true
        mcpSimSpinner.style = .spinning
        mcpSimSpinner.controlSize = .small
        mcpSimSpinner.isDisplayedWhenStopped = false
        let mcpSimButtons = NSStackView(views: [mcpSimButton, mcpSimUninstallButton, mcpSimSpinner])
        mcpSimButtons.orientation = .horizontal
        mcpSimButtons.spacing = 8
        stack.addArrangedSubview(mcpSimButtons)

        mcpSimStatusLabel.font = .systemFont(ofSize: 11)
        mcpSimStatusLabel.textColor = .secondaryLabelColor
        mcpSimStatusLabel.preferredMaxLayoutWidth = 268
        mcpSimStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(mcpSimStatusLabel)

        simController.onState = { [weak self] state in self?.renderSimState(state) }
        refreshSimulators()
        refreshMCPSim(updateLabel: true)
```

- [ ] **Step 3: Add the handlers**

Add these methods to the same class (near `refreshMCP`/`primaryMCP`, around `main.swift:1540`):

```swift
    private func refreshSimulators() {
        let hasXcode = simController.xcodeAvailable()
        simPicker.isEnabled = hasXcode
        simEnableButton.isEnabled = hasXcode
        if !hasXcode { simStatusLabel.stringValue = "Requires Xcode."; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let sims = self.simController.listSimulators()
            DispatchQueue.main.async {
                self.simDevices = sims
                self.simPicker.removeAllItems()
                for s in sims {
                    self.simPicker.addItem(withTitle: "\(s.name) — \(s.runtime)"
                                           + (s.isBooted ? " (booted)" : ""))
                }
                if sims.isEmpty { self.simStatusLabel.stringValue = "No simulators found." }
            }
        }
    }

    @objc private func simPicked() { /* selection stored implicitly via indexOfSelectedItem */ }

    @objc private func toggleSimEnable() {
        if simEnabled {
            simController.disable()
            return
        }
        let idx = simPicker.indexOfSelectedItem
        guard idx >= 0, idx < simDevices.count else {
            simStatusLabel.stringValue = "Pick a simulator first."; return
        }
        simController.enable(udid: simDevices[idx].udid)
    }

    private func renderSimState(_ state: SimState) {
        switch state {
        case .idle:
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Off."
        case .booting:  simEnabled = true; simEnableButton.title = "Disable"; simStatusLabel.stringValue = "Booting simulator…"
        case .building: simStatusLabel.stringValue = "Building WebDriverAgent (first run ~2–3 min)…"
        case .starting: simStatusLabel.stringValue = "Starting WebDriverAgent…"
        case .ready:    simStatusLabel.stringValue = "WebDriverAgent ready on :8201 ✓"
        case .failed(let m):
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Failed: \(m)"
        }
    }

    private func refreshMCPSim(updateLabel: Bool) {
        if updateLabel { mcpSimStatusLabel.stringValue = "Checking…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MCPInstaller.status(profile: .simulator)
            DispatchQueue.main.async {
                self.mcpSimInstalled = s.installed
                self.mcpSimUninstallButton.isHidden = !s.installed
                self.mcpSimButton.title = !s.installed ? "Install MCP server (sim)"
                                        : (s.upToDate ? "Reinstall" : "Update MCP server (sim)")
                if updateLabel {
                    let ver = s.version.map { " · v\($0)" } ?? ""
                    self.mcpSimStatusLabel.stringValue = !s.installed
                        ? "Not installed."
                        : "Installed · \(s.clients.joined(separator: ", "))\(ver) · "
                          + (s.upToDate ? "up to date." : "update available.")
                }
            }
        }
    }

    @objc private func primaryMCPSim() {
        mcpSimButton.isEnabled = false; mcpSimUninstallButton.isEnabled = false
        mcpSimSpinner.startAnimation(nil)
        let updating = mcpSimInstalled
        mcpSimStatusLabel.stringValue = updating ? "Updating…" : "Installing… (first run sets up Python — up to ~30s)"
        MCPInstaller.install(profile: .simulator, update: updating, progress: { [weak self] msg in
            self?.mcpSimStatusLabel.stringValue = msg
        }, completion: { [weak self] r in
            guard let self else { return }
            self.mcpSimSpinner.stopAnimation(nil)
            self.mcpSimStatusLabel.stringValue = r.message
            self.mcpSimButton.isEnabled = true; self.mcpSimUninstallButton.isEnabled = true
            self.refreshMCPSim(updateLabel: false)
        })
    }

    @objc private func uninstallMCPSim() {
        mcpSimButton.isEnabled = false; mcpSimUninstallButton.isEnabled = false
        mcpSimSpinner.startAnimation(nil)
        mcpSimStatusLabel.stringValue = "Removing…"
        MCPInstaller.uninstall(profile: .simulator) { [weak self] r in
            guard let self else { return }
            self.mcpSimSpinner.stopAnimation(nil)
            self.mcpSimStatusLabel.stringValue = r.message
            self.mcpSimButton.isEnabled = true; self.mcpSimUninstallButton.isEnabled = true
            self.refreshMCPSim(updateLabel: false)
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Manual UI smoke test**

Run:
```bash
swift build && .build/debug/iMirror
```
Then open Settings (gear/toolbar). Expected:
- An "iOS Simulator" section shows a populated picker (or "Requires Xcode." if absent).
- Pick a sim → **Enable** → status walks `Booting… → Building… → Starting… → WebDriverAgent ready on :8201 ✓`.
- **Install MCP server (sim)** → status shows `Installed · Claude Code…`. Verify: `claude mcp get imirror-sim` shows env `IMIRROR_TARGET=simulator`, `IMIRROR_WDA=http://127.0.0.1:8201`.
- **Uninstall** removes it. The device MCP section still works unchanged.

- [ ] **Step 6: Run the full Swift test suite (regression)**

Run: `swift test`
Expected: all tests pass (the Task 1–3 additions plus the pre-existing suite).

- [ ] **Step 7: Commit**

```bash
git add Sources/iMirror/main.swift
git commit -m "feat(app): Settings iOS Simulator section (pick, enable, install MCP)

Boots a chosen sim, brings up WDA on :8201 via SimulatorController, and installs
the imirror-sim MCP server. Device section unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Phase 1 rows of the design):**
- `MCPInstaller.Profile` + env registration + env-aware staleness → Tasks 2, 4. ✓
- `MCPConfig` env round-trip / `entryEnv` → Task 1. ✓
- `simctl` JSON → `[Simulator]` (picker source) → Task 3. ✓
- `SimulatorController` (list, boot, bring-up on 8201, supervision, state, Xcode gate) → Task 5. ✓
- Settings "iOS Simulator" section (picker, Enable, status, MCP install/uninstall) → Task 6. ✓
- Ports: device 8100 / sim 8201 coexist → `MCPProfile.simulator` + `SimulatorController.port` (Tasks 2, 5). ✓
- Manage-only (view via Simulator.app) → Task 5 opens Simulator.app; no capture path. ✓
- Phase-2-only items (bundle WDA source, in-app build, `package.sh`) are **intentionally excluded** — a separate plan.

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. The `simPicked` handler is intentionally a no-op (selection is read on Enable via `indexOfSelectedItem`) — documented inline, not a placeholder.

**Type consistency:** `MCPProfile.serverName`/`.env`, `SimDevice.udid/name/runtime/isBooted`, `SimState` cases, `SimulatorController.port`/`enable(udid:)`/`disable()`/`onState`, and `MCPInstaller.status/install/uninstall(profile:…)` names match across Tasks 1–6. `MCPConfig.merged(…, env:)` and `.entryEnv` match Task 1 and the existing signature.

**Known deviation from the spec (recorded):** the spec suggested refactoring the existing device MCP section into a shared profile-parameterized builder. To keep Phase 1 low-risk, this plan adds a **separate** sim section and leaves the working device section untouched; folding both into one builder is a safe follow-up cleanup (candidate for Phase 2). This trades a little duplication for not disturbing shipping UI.
