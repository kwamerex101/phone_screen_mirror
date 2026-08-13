// Registers iMirror's MCP server with Claude Desktop by merging an entry
// into its `claude_desktop_config.json` — ported verbatim from the
// pre-adapter MCPInstaller. The JSON merge/remove logic lives in
// iMirrorCore.MCPConfig (pure, already unit-tested); this adapter only owns
// the file location and the directory-exists gate on install.

import Foundation
import iMirrorCore

struct ClaudeDesktopAdapter: MCPClientAdapter {
    let displayName = "Claude Desktop"
    let installProgressMessage = "Updating Claude Desktop config…"

    /// Injectable seam: production points at the real Claude Desktop config
    /// path; tests point this at a temp file so the merge/status/remove logic
    /// runs against a real (throwaway) file without touching the user's config.
    var configURL: URL = MCPPaths.claudeDesktopConfig

    /// True only if the Claude Desktop app's config directory exists — i.e.
    /// it's actually installed. iMirror must never create this directory
    /// itself: an empty dir it created would then read back as "Claude
    /// Desktop found" on the next check. This gates install only; status()
    /// makes its own determination independently (see below).
    func detect() -> Bool {
        FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }

    /// Installed only if the config already contains a real entry for this
    /// server — not gated by `detect()`, so a directory with no config file
    /// (or no entry) reads as not-installed regardless of whether the
    /// directory exists.
    func status(_ profile: MCPProfile) -> MCPClientStatus {
        guard let data = try? Data(contentsOf: configURL),
              let entry = MCPConfig.entry(data, name: profile.serverName) else { return .notInstalled }
        var stale = false
        if entry.command != MCPPaths.venvPython.path || entry.args.first != MCPPaths.scriptURL()?.path {
            stale = true
        }
        if MCPConfig.entryEnv(data, name: profile.serverName) != profile.env { stale = true }
        return stale ? .stale : .installed
    }

    func install(_ profile: MCPProfile) throws -> String? {
        guard detect(), let script = MCPPaths.scriptURL() else { return nil }
        do {
            let existing = try? Data(contentsOf: configURL)
            let merged = try MCPConfig.merged(into: existing, name: profile.serverName,
                                              command: MCPPaths.venvPython.path,
                                              args: [script.path], env: profile.env)
            try merged.write(to: configURL)
            return "\(displayName) (restart it)"
        } catch {
            throw AdapterInstallError(message: "Claude Desktop config write failed: \(error.localizedDescription)")
        }
    }

    func remove(_ profile: MCPProfile) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let out = try? MCPConfig.removed(from: data, name: profile.serverName) else { return nil }
        try? out.write(to: configURL)
        return displayName
    }
}
