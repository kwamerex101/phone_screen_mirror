// One-click install of the iMirror MCP server into the user's MCP client(s).
//
// "Install" means: (1) make a Python venv with `mcp[cli]`, (2) register the server
// with Claude Code (`claude mcp add`) and/or Claude Desktop (merge into
// claude_desktop_config.json). Both are auto-detected; whichever is present is set
// up. The JSON merge itself lives in iMirrorCore.MCPConfig (unit-tested).
//
// The server script is taken from this repo checkout when running from source, else
// from the copy bundled into iMirror.app (see scripts/package.sh). The venv lives in
// ~/Library/Application Support/iMirror/mcp so it's writable in both cases.

import Foundation
import iMirrorCore

enum MCPInstaller {
    struct Result { let ok: Bool; let message: String }

    static let serverName = "imirror"

    // MARK: Paths

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror", isDirectory: true)
    }
    private static var venvDir: URL { appSupport.appendingPathComponent("mcp/.venv", isDirectory: true) }
    private static var venvPython: URL { venvDir.appendingPathComponent("bin/python") }

    private static var claudeDesktopConfig: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// The MCP server script: prefer this repo checkout (dev), else the bundled copy.
    static func scriptURL() -> URL? {
        let repo = URL(fileURLWithPath: #filePath)            // Sources/iMirror/MCPInstaller.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mcp-server/imirror_mcp.py")
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mcp-server/imirror_mcp.py"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }

    // MARK: Executable discovery (the GUI app's PATH is minimal)

    private static func resolve(_ tool: String, _ fallbacks: [String]) -> String? {
        for p in fallbacks where FileManager.default.isExecutableFile(atPath: p) { return p }
        let r = run("/bin/bash", ["-lc", "command -v \(tool)"])   // login-shell PATH
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0 && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }
    private static func python3() -> String? {
        resolve("python3", ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
    }
    private static func claudeCLI() -> String? {
        let home = NSHomeDirectory()
        return resolve("claude", ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    // MARK: Status

    struct Status {
        let clients: [String]      // which MCP clients have it registered
        let version: String?       // current server __version__
        let upToDate: Bool         // registration points at the current script + a working venv
        var installed: Bool { !clients.isEmpty }
    }

    /// Where things stand right now — used to show installed/version/update state
    /// when the user opens Settings. Runs off the main thread (it may shell out).
    static func status() -> Status {
        let desiredScript = scriptURL()?.path
        let venvOK = FileManager.default.isExecutableFile(atPath: venvPython.path)
        var clients: [String] = []
        var stale = false

        if let data = try? Data(contentsOf: claudeDesktopConfig),
           let e = MCPConfig.entry(data, name: serverName) {
            clients.append("Claude Desktop")
            if e.command != venvPython.path || e.args.first != desiredScript { stale = true }
        }
        if let claude = claudeCLI() {
            let r = run(claude, ["mcp", "get", serverName])
            if r.code == 0, r.out.contains(serverName) {
                clients.append("Claude Code")
                if let s = desiredScript, !r.out.contains(s) { stale = true }
            }
        }
        return Status(clients: clients, version: currentVersion(),
                      upToDate: !clients.isEmpty && venvOK && !stale)
    }

    static func isInstalled() -> Bool { status().installed }

    /// The `__version__` of the current (repo or bundled) server script.
    static func currentVersion() -> String? {
        guard let s = scriptURL(), let txt = try? String(contentsOf: s, encoding: .utf8) else { return nil }
        let re = try? NSRegularExpression(pattern: #"__version__\s*=\s*["']([^"']+)["']"#)
        let range = NSRange(txt.startIndex..., in: txt)
        guard let m = re?.firstMatch(in: txt, range: range), let r = Range(m.range(at: 1), in: txt)
        else { return nil }
        return String(txt[r])
    }

    // MARK: Install / uninstall

    static func install(update: Bool = false,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = doInstall(update: update, progress: progress)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func doInstall(update: Bool, progress: @escaping (String) -> Void) -> Result {
        guard let script = scriptURL() else {
            return Result(ok: false, message: "Couldn't find imirror_mcp.py (repo or bundle).")
        }
        guard let py = python3() else {
            return Result(ok: false, message: "python3 not found — install Xcode Command Line Tools.")
        }

        // 1. venv + deps. Create the venv if missing; (re)install deps on first
        //    setup or when updating (then with --upgrade to pull newer mcp[cli]).
        let needVenv = !FileManager.default.isExecutableFile(atPath: venvPython.path)
        if needVenv {
            progress("Creating Python environment…")
            try? FileManager.default.createDirectory(at: venvDir.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let mk = run(py, ["-m", "venv", venvDir.path])
            guard mk.code == 0 else {
                return Result(ok: false, message: "venv creation failed: \(mk.out.suffix(160))")
            }
        }
        if needVenv || update {
            progress(update ? "Updating dependencies…" : "Installing dependencies (mcp)…")
            let reqs = script.deletingLastPathComponent().appendingPathComponent("requirements.txt")
            var pipArgs = ["-m", "pip", "install", "--quiet"]
            if update { pipArgs.append("--upgrade") }
            if FileManager.default.fileExists(atPath: reqs.path) { pipArgs += ["-r", reqs.path] }
            else { pipArgs.append("mcp[cli]") }
            let pip = run(venvPython.path, pipArgs)
            guard pip.code == 0 else {
                return Result(ok: false, message: "pip install failed: \(pip.out.suffix(160))")
            }
        }

        var registered: [String] = []

        // 2. Claude Code (idempotent: remove any stale entry, then add).
        if let claude = claudeCLI() {
            progress("Registering with Claude Code…")
            _ = run(claude, ["mcp", "remove", serverName, "--scope", "user"])
            let add = run(claude, ["mcp", "add", serverName, "--scope", "user",
                                   "--", venvPython.path, script.path])
            if add.code == 0 { registered.append("Claude Code") }
        }

        // 3. Claude Desktop (only if the app dir exists — i.e. it's installed).
        let claudeDir = claudeDesktopConfig.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            progress("Updating Claude Desktop config…")
            do {
                let existing = try? Data(contentsOf: claudeDesktopConfig)
                let merged = try MCPConfig.merged(into: existing, name: serverName,
                                                  command: venvPython.path, args: [script.path])
                try merged.write(to: claudeDesktopConfig)
                registered.append("Claude Desktop (restart it)")
            } catch {
                return Result(ok: false, message: "Claude Desktop config write failed: \(error.localizedDescription)")
            }
        }

        guard !registered.isEmpty else {
            return Result(ok: false, message: "No MCP client found (Claude Code CLI or Claude Desktop).")
        }
        return Result(ok: true, message: "Installed ✓ — " + registered.joined(separator: ", "))
    }

    static func uninstall(completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var removed: [String] = []
            if let claude = claudeCLI() {
                if run(claude, ["mcp", "remove", serverName, "--scope", "user"]).code == 0 {
                    removed.append("Claude Code")
                }
            }
            if let data = try? Data(contentsOf: claudeDesktopConfig),
               let out = try? MCPConfig.removed(from: data, name: serverName) {
                try? out.write(to: claudeDesktopConfig)
                removed.append("Claude Desktop")
            }
            let msg = removed.isEmpty ? "Nothing to remove." : "Removed from " + removed.joined(separator: ", ")
            DispatchQueue.main.async { completion(Result(ok: true, message: msg)) }
        }
    }

    // MARK: Process helper

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
