// Pure helpers for editing a Claude-Desktop-style MCP client config
// (`claude_desktop_config.json`). Kept side-effect-free and in iMirrorCore so the
// merge logic — the part that must never clobber the user's other servers — is
// unit-tested without touching the filesystem.

import Foundation

public enum MCPConfig {
    /// Merge/replace one MCP server entry into an existing config JSON, preserving
    /// every other key. `existing` may be nil or empty (a fresh config is created).
    /// Returns pretty-printed JSON data.
    public static func merged(into existing: Data?, name: String,
                              command: String, args: [String],
                              env: [String: String] = [:]) throws -> Data {
        var root = object(from: existing)
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        var entry: [String: Any] = ["command": command, "args": args]
        if !env.isEmpty { entry["env"] = env }
        servers[name] = entry
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Remove a server entry. Returns nil when there was nothing to remove (so the
    /// caller can skip rewriting the file).
    public static func removed(from existing: Data?, name: String) throws -> Data? {
        var root = object(from: existing)
        guard var servers = root["mcpServers"] as? [String: Any], servers[name] != nil
        else { return nil }
        servers[name] = nil
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// True if the config already contains a server with this name.
    public static func contains(_ existing: Data?, name: String) -> Bool {
        (object(from: existing)["mcpServers"] as? [String: Any])?[name] != nil
    }

    /// The (command, args) a named server is registered with, or nil if absent.
    /// Lets the installer detect a stale registration (path no longer current).
    public static func entry(_ existing: Data?, name: String) -> (command: String, args: [String])? {
        guard let servers = object(from: existing)["mcpServers"] as? [String: Any],
              let e = servers[name] as? [String: Any],
              let cmd = e["command"] as? String else { return nil }
        return (cmd, (e["args"] as? [String]) ?? [])
    }

    private static func object(from data: Data?) -> [String: Any] {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
