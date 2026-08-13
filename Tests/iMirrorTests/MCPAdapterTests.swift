// Unit tests for the MCP client adapters introduced to replace MCPInstaller's
// two hardcoded blocks (I10, behavior-preserving half). These adapters shell
// out / touch the filesystem, so each test drives them through their
// injection seam (a stub `run` closure for Claude Code, a temp-file
// `configURL` for Claude Desktop) rather than a real `claude` CLI or the
// user's real config file.

import Foundation
import XCTest
import iMirrorCore
@testable import iMirror

private let deviceProfile = MCPProfile.device
private let simProfile = MCPProfile.simulator

final class ClaudeDesktopAdapterTests: XCTestCase {
    private var tempDir: URL!
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configURL = tempDir.appendingPathComponent("claude_desktop_config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDetectTrueWhenConfigDirectoryExists() {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        XCTAssertTrue(adapter.detect())
    }

    func testDetectFalseWhenConfigDirectoryMissing() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
        let adapter = ClaudeDesktopAdapter(configURL: missing)
        XCTAssertFalse(adapter.detect())
    }

    func testStatusNotInstalledWhenFileMissing() {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        XCTAssertEqual(adapter.status(deviceProfile), .notInstalled)
    }

    func testInstallWritesEntryAndReturnsRestartLabel() throws {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        let label = try adapter.install(deviceProfile)
        XCTAssertEqual(label, "Claude Desktop (restart it)")

        let data = try Data(contentsOf: configURL)
        let entry = MCPConfig.entry(data, name: deviceProfile.serverName)
        XCTAssertEqual(entry?.command, MCPPaths.venvPython.path)
        XCTAssertEqual(entry?.args.first, MCPPaths.scriptURL()?.path)
    }

    /// The directory-exists gate only affects install, never status — a
    /// directory iMirror never created must never self-confirm as installed.
    func testInstallSkippedWhenDirectoryMissing() throws {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
        let adapter = ClaudeDesktopAdapter(configURL: missing)
        let label = try adapter.install(deviceProfile)
        XCTAssertNil(label)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testStatusInstalledAfterInstall() throws {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        _ = try adapter.install(deviceProfile)
        XCTAssertEqual(adapter.status(deviceProfile), .installed)
    }

    func testStatusStaleWhenCommandDiffers() throws {
        let data = try MCPConfig.merged(into: nil, name: deviceProfile.serverName,
                                        command: "/old/python", args: [MCPPaths.scriptURL()!.path],
                                        env: deviceProfile.env)
        try data.write(to: configURL)
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        XCTAssertEqual(adapter.status(deviceProfile), .stale)
    }

    func testStatusStaleWhenEnvDiffers() throws {
        let data = try MCPConfig.merged(into: nil, name: simProfile.serverName,
                                        command: MCPPaths.venvPython.path,
                                        args: [MCPPaths.scriptURL()!.path],
                                        env: ["WRONG": "1"])
        try data.write(to: configURL)
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        XCTAssertEqual(adapter.status(simProfile), .stale)
    }

    func testRemoveDeletesEntryReturnsLabel() throws {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        _ = try adapter.install(deviceProfile)
        let label = adapter.remove(deviceProfile)
        XCTAssertEqual(label, "Claude Desktop")
        let data = try Data(contentsOf: configURL)
        XCTAssertFalse(MCPConfig.contains(data, name: deviceProfile.serverName))
    }

    func testRemoveReturnsNilWhenNothingToRemove() {
        let adapter = ClaudeDesktopAdapter(configURL: configURL)
        XCTAssertNil(adapter.remove(deviceProfile))
    }
}

final class ClaudeCodeAdapterTests: XCTestCase {
    private func adapter(cliPath: String? = "/usr/bin/claude",
                         run: @escaping (String, [String]) -> (code: Int32, out: String)) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(run: run, resolveCLI: { cliPath })
    }

    func testDetectFalseWhenCLIMissing() {
        let a = adapter(cliPath: nil) { _, _ in (0, "") }
        XCTAssertFalse(a.detect())
    }

    func testDetectTrueWhenCLIResolved() {
        let a = adapter { _, _ in (0, "") }
        XCTAssertTrue(a.detect())
    }

    func testStatusNotInstalledWhenGetFails() {
        let a = adapter { _, _ in (1, "") }
        XCTAssertEqual(a.status(deviceProfile), .notInstalled)
    }

    func testStatusNotInstalledWhenCLIMissing() {
        let a = adapter(cliPath: nil) { _, _ in (0, deviceProfile.serverName) }
        XCTAssertEqual(a.status(deviceProfile), .notInstalled)
    }

    func testStatusInstalledWhenOutputMatchesCurrentScriptAndEnv() {
        let script = MCPPaths.scriptURL()!.path
        let a = adapter { launch, args in
            XCTAssertEqual(launch, "/usr/bin/claude")
            XCTAssertEqual(args, ["mcp", "get", deviceProfile.serverName])
            return (0, "\(deviceProfile.serverName)\ncommand: \(script)")
        }
        XCTAssertEqual(a.status(deviceProfile), .installed)
    }

    func testStatusStaleWhenScriptPathMissingFromOutput() {
        let a = adapter { _, _ in (0, "\(deviceProfile.serverName)\ncommand: /old/script.py") }
        XCTAssertEqual(a.status(deviceProfile), .stale)
    }

    func testStatusStaleWhenEnvMissingFromOutput() {
        let script = MCPPaths.scriptURL()!.path
        let a = adapter { _, _ in (0, "\(simProfile.serverName)\ncommand: \(script)") }
        XCTAssertEqual(a.status(simProfile), .stale)
    }

    func testInstallSendsRemoveThenAddWithScriptAndEnvArgs() throws {
        var calls: [[String]] = []
        let script = MCPPaths.scriptURL()!.path
        let a = adapter { _, args in
            calls.append(args)
            return (0, "")
        }
        let label = try a.install(simProfile)
        XCTAssertEqual(label, "Claude Code")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], ["mcp", "remove", "imirror-sim", "--scope", "user"])

        let addArgs = calls[1]
        XCTAssertEqual(Array(addArgs.prefix(4)), ["mcp", "add", "imirror-sim", "--scope"])
        XCTAssertEqual(addArgs[4], "user")
        XCTAssertEqual(addArgs[addArgs.count - 3], "--")
        XCTAssertEqual(Array(addArgs.suffix(2)), [MCPPaths.venvPython.path, script])
        XCTAssertEqual(addArgs.filter { $0 == "-e" }.count, simProfile.env.count)
        for (k, v) in simProfile.env {
            XCTAssertTrue(addArgs.contains("\(k)=\(v)"))
        }
    }

    /// A failed `claude mcp add` is not a fatal install error — it just
    /// registers nothing, matching the pre-adapter behavior where the whole
    /// install could still succeed via Claude Desktop alone.
    func testInstallReturnsNilWhenAddFails() throws {
        var callIndex = 0
        let a = adapter { _, _ in
            defer { callIndex += 1 }
            return callIndex == 0 ? (0, "") : (1, "add failed")
        }
        let label = try a.install(deviceProfile)
        XCTAssertNil(label)
    }

    func testInstallReturnsNilWhenCLIMissing() throws {
        let a = adapter(cliPath: nil) { _, _ in (0, "") }
        let label = try a.install(deviceProfile)
        XCTAssertNil(label)
    }

    func testRemoveReturnsLabelOnSuccess() {
        let a = adapter { _, args in
            XCTAssertEqual(args, ["mcp", "remove", deviceProfile.serverName, "--scope", "user"])
            return (0, "")
        }
        XCTAssertEqual(a.remove(deviceProfile), "Claude Code")
    }

    func testRemoveReturnsNilOnFailure() {
        let a = adapter { _, _ in (1, "") }
        XCTAssertNil(a.remove(deviceProfile))
    }

    func testRemoveReturnsNilWhenCLIMissing() {
        let a = adapter(cliPath: nil) { _, _ in (0, "") }
        XCTAssertNil(a.remove(deviceProfile))
    }
}

final class MCPInstallerAdapterOrderingTests: XCTestCase {
    /// install/uninstall act on Claude Code before Claude Desktop (unchanged
    /// order from before the split); status checks them in the opposite
    /// order (Desktop before Code) to preserve the exact pre-adapter status
    /// line ordering.
    func testAllAdaptersOrderIsCodeThenDesktop() {
        XCTAssertTrue(MCPInstaller.allAdapters[0] is ClaudeCodeAdapter)
        XCTAssertTrue(MCPInstaller.allAdapters[1] is ClaudeDesktopAdapter)
    }
}
