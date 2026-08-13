// Registers iMirror's MCP server with Claude Code via its own CLI
// (`claude mcp add/remove/get`). Claude Code owns its config file itself, so
// this adapter shells out instead of touching JSON — ported verbatim from
// the pre-adapter MCPInstaller (same subcommands, same candidate-path/PATH
// detection), just with the Process spawn and CLI lookup made injectable so
// the command construction and status mapping are unit-testable.

import Foundation
import iMirrorCore

struct ClaudeCodeAdapter: MCPClientAdapter {
    let displayName = "Claude Code"
    let installProgressMessage = "Registering with Claude Code…"

    /// Injectable seams for tests: `run` replaces the real Process spawn,
    /// `resolveCLI` replaces the PATH/candidate-list lookup of `claude`.
    var run: (_ launch: String, _ args: [String]) -> (code: Int32, out: String) = ProcessRunner.live.run
    var resolveCLI: () -> String? = ClaudeCodeAdapter.defaultCLIResolver

    func detect() -> Bool { resolveCLI() != nil }

    func status(_ profile: MCPProfile) -> MCPClientStatus {
        guard let claude = resolveCLI() else { return .notInstalled }
        let r = run(claude, ["mcp", "get", profile.serverName])
        guard r.code == 0, r.out.contains(profile.serverName) else { return .notInstalled }
        var stale = false
        if let script = MCPPaths.scriptURL()?.path, !r.out.contains(script) { stale = true }
        for (k, v) in profile.env where !r.out.contains("\(k)=\(v)") { stale = true }
        return stale ? .stale : .installed
    }

    /// Idempotent: remove any stale entry, then add fresh with the current
    /// script path + env. A failed `claude mcp add` is reported as "nothing
    /// registered" (nil), not as a fatal error — matches the original
    /// behavior, where the whole install still succeeded via Claude Desktop
    /// even if the Claude Code CLI call failed.
    func install(_ profile: MCPProfile) throws -> String? {
        guard let claude = resolveCLI(), let script = MCPPaths.scriptURL() else { return nil }
        _ = run(claude, ["mcp", "remove", profile.serverName, "--scope", "user"])
        var addArgs = ["mcp", "add", profile.serverName, "--scope", "user"]
        for (k, v) in profile.env { addArgs += ["-e", "\(k)=\(v)"] }
        addArgs += ["--", MCPPaths.venvPython.path, script.path]
        guard run(claude, addArgs).code == 0 else { return nil }
        return displayName
    }

    func remove(_ profile: MCPProfile) -> String? {
        guard let claude = resolveCLI() else { return nil }
        guard run(claude, ["mcp", "remove", profile.serverName, "--scope", "user"]).code == 0 else { return nil }
        return displayName
    }

    // MARK: Executable discovery (the GUI app's PATH is minimal)

    private static func resolve(_ tool: String, _ fallbacks: [String]) -> String? {
        for p in fallbacks where FileManager.default.isExecutableFile(atPath: p) { return p }
        let r = ProcessRunner.spawn("/bin/bash", ["-lc", "command -v \(tool)"])   // login-shell PATH
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0 && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    static func defaultCLIResolver() -> String? {
        let home = NSHomeDirectory()
        return resolve("claude", ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }
}
