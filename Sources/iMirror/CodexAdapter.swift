import Foundation
import iMirrorCore

/// Registers through Codex's CLI so Codex owns its TOML format and writes.
struct CodexAdapter: MCPClientAdapter {
    let displayName = "Codex"
    let installProgressMessage = "Registering with Codex…"
    var run: (_ launch: String, _ args: [String]) -> (code: Int32, out: String) = ProcessRunner.live.run
    var resolveCLI: () -> String? = CodexAdapter.defaultCLIResolver

    func detect() -> Bool { resolveCLI() != nil }

    func status(_ profile: MCPProfile) -> MCPClientStatus {
        guard let cli = resolveCLI() else { return .notInstalled }
        let result = run(cli, ["mcp", "get", profile.serverName, "--json"])
        guard result.code == 0 else { return .notInstalled }
        guard let data = result.out.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transport = entry["transport"] as? [String: Any],
              let script = MCPPaths.scriptURL()?.path else { return .stale }
        let environment = transport["env"] as? [String: String] ?? [:]
        let current = entry["enabled"] as? Bool != false
            && transport["type"] as? String == "stdio"
            && transport["command"] as? String == MCPPaths.venvPython.path
            && transport["args"] as? [String] == [script]
            && profile.env.allSatisfy { environment[$0.key] == $0.value }
        return current ? .installed : .stale
    }

    func install(_ profile: MCPProfile) throws -> String? {
        guard let cli = resolveCLI(), let script = MCPPaths.scriptURL() else { return nil }
        var args = ["mcp", "add", profile.serverName]
        for key in profile.env.keys.sorted() { args += ["--env", "\(key)=\(profile.env[key]!)"] }
        args += ["--", MCPPaths.venvPython.path, script.path]
        let result = run(cli, args)
        guard result.code == 0 else {
            throw AdapterInstallError(message: "Couldn’t register with Codex. Check `codex mcp add --help` and retry.")
        }
        return "Codex (start a new chat)"
    }

    func remove(_ profile: MCPProfile) -> String? {
        guard let cli = resolveCLI(), run(cli, ["mcp", "remove", profile.serverName]).code == 0 else { return nil }
        return displayName
    }

    static func defaultCLIResolver() -> String? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        let result = ProcessRunner.spawn("/bin/bash", ["-lc", "command -v codex"])
        let path = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.code == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
