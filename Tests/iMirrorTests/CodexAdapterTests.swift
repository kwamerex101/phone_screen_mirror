import XCTest
import iMirrorCore
@testable import iMirror

final class CodexAdapterTests: XCTestCase {
    private func entry(command: String = MCPPaths.venvPython.path,
                       args: [String]? = nil, env: [String: String] = [:],
                       enabled: Bool = true) -> String {
        let value: [String: Any] = ["enabled": enabled, "transport": [
            "type": "stdio", "command": command,
            "args": args ?? [MCPPaths.scriptURL()!.path], "env": env]]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    func testStatusParsesExactCommandArgumentsAndEnvironment() {
        var adapter = CodexAdapter(resolveCLI: { "/test/codex" })
        adapter.run = { _, args in
            XCTAssertEqual(args, ["mcp", "get", "imirror-sim", "--json"])
            return (0, self.entry(env: MCPProfile.simulator.env))
        }
        XCTAssertEqual(adapter.status(.simulator), .installed)
        adapter.run = { _, _ in (0, self.entry(command: "/stale/python", env: MCPProfile.simulator.env)) }
        XCTAssertEqual(adapter.status(.simulator), .stale)
        adapter.run = { _, _ in (0, self.entry(args: ["wrong.py"], env: MCPProfile.simulator.env)) }
        XCTAssertEqual(adapter.status(.simulator), .stale)
        adapter.run = { _, _ in (0, self.entry()) }
        XCTAssertEqual(adapter.status(.simulator), .stale)
        adapter.run = { _, _ in (0, self.entry(enabled: false)) }
        XCTAssertEqual(adapter.status(.device), .stale)
        adapter.run = { _, _ in (0, "malformed output") }
        XCTAssertEqual(adapter.status(.device), .stale)
    }

    func testMissingClientAndMissingRegistration() {
        let missing = CodexAdapter(run: { _, _ in XCTFail("must not run"); return (1, "") }, resolveCLI: { nil })
        XCTAssertFalse(missing.detect())
        XCTAssertEqual(missing.status(.device), .notInstalled)
        let unregistered = CodexAdapter(run: { _, _ in (1, "no server") }, resolveCLI: { "/test/codex" })
        XCTAssertEqual(unregistered.status(.device), .notInstalled)
    }

    func testInstallUsesCodexEnvFlagsWithoutRemovingExistingEntry() throws {
        var calls: [[String]] = []
        let adapter = CodexAdapter(run: { _, args in calls.append(args); return (0, "") }, resolveCLI: { "/test/codex" })
        XCTAssertEqual(try adapter.install(.simulator), "Codex (start a new chat)")
        XCTAssertEqual(calls, [["mcp", "add", "imirror-sim",
            "--env", "IMIRROR_TARGET=simulator", "--env", "IMIRROR_WDA=http://127.0.0.1:8201",
            "--", MCPPaths.venvPython.path, MCPPaths.scriptURL()!.path]])
    }

    func testInstallFailureIsReportedAndDoesNotRemoveRegistration() {
        var calls: [[String]] = []
        let adapter = CodexAdapter(run: { _, args in calls.append(args); return (1, "failed") }, resolveCLI: { "/test/codex" })
        XCTAssertThrowsError(try adapter.install(.device))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.prefix(2), ["mcp", "add"])
    }

    func testRemoveOnlyTouchesSelectedProfile() {
        let adapter = CodexAdapter(run: { _, args in
            XCTAssertEqual(args, ["mcp", "remove", "imirror-sim"]); return (0, "")
        }, resolveCLI: { "/test/codex" })
        XCTAssertEqual(adapter.remove(.simulator), "Codex")
    }

    func testInstallerIncludesCodex() {
        XCTAssertTrue(MCPInstaller.allAdapters.contains { $0 is CodexAdapter })
    }
}
