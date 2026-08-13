// Shared filesystem locations for the MCP installer and its client adapters.
// Kept as pure data (no side effects beyond reading the filesystem to locate
// the server script) so MCPInstaller.swift and the per-client adapters in
// this directory agree on where the venv, script, and Claude Desktop config
// live, instead of each recomputing it.

import Foundation

enum MCPPaths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror", isDirectory: true)
    }
    static var venvDir: URL { appSupport.appendingPathComponent("mcp/.venv", isDirectory: true) }
    static var venvPython: URL { venvDir.appendingPathComponent("bin/python") }

    static var claudeDesktopConfig: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// The MCP server script: prefer this repo checkout (dev), else the copy
    /// bundled into iMirror.app (see scripts/package.sh).
    static func scriptURL() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)            // Sources/iMirror/MCPPaths.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mcp-server/imirror_mcp.py")
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mcp-server/imirror_mcp.py"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }
}
