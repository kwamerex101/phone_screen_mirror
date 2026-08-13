// One-click install of the iMirror MCP server into the user's MCP client(s).
//
// "Install" means: (1) make a Python venv with `mcp[cli]`, (2) register the
// server with each detected MCP client — Claude Code (`claude mcp add`) and
// Claude Desktop (merge into claude_desktop_config.json) today, via the
// MCPClientAdapter in ClaudeCodeAdapter.swift / ClaudeDesktopAdapter.swift.
// The JSON merge itself lives in iMirrorCore.MCPConfig (unit-tested).
//
// The server script is taken from this repo checkout when running from source, else
// from the copy bundled into iMirror.app (see scripts/package.sh). The venv lives in
// ~/Library/Application Support/iMirror/mcp so it's writable in both cases.

import Foundation
import iMirrorCore

enum MCPInstaller {
    struct Result { let ok: Bool; let message: String }

    /// Every MCP client iMirror knows how to register itself with, in the
    /// order install/uninstall act on them (Claude Code, then Claude
    /// Desktop — unchanged from before the adapter split).
    static let allAdapters: [MCPClientAdapter] = [ClaudeCodeAdapter(), ClaudeDesktopAdapter()]

    // MARK: Python interpreter discovery (the GUI app's PATH is minimal)

    /// A Python interpreter that is 3.10+ (mcp requires it; the system
    /// /usr/bin/python3 is 3.9 and can't install mcp). Prefers Homebrew's pythons.
    private static func pythonInterpreter() -> String? {
        var candidates: [String] = []
        for base in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for v in ["3.13", "3.12", "3.11", "3.10"] { candidates.append("\(base)/python\(v)") }
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for v in ["3.13", "3.12", "3.11", "3.10", "3"] {          // login-shell PATH lookups
            let p = ProcessRunner.spawn("/bin/bash", ["-lc", "command -v python\(v)"])
                .out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { candidates.append(p) }
        }
        return candidates.first(where: isPython310Plus)
    }

    private static func isPython310Plus(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let r = ProcessRunner.spawn(path, ["-c", "import sys; print(sys.version_info[:2] >= (3, 10))"])
        return r.code == 0 && r.out.contains("True")
    }

    /// The meaningful line(s) of a pip/venv failure — the real ERROR is usually at
    /// the top, above pip's "consider upgrading pip" notice (which .suffix() would show).
    private static func firstError(_ out: String) -> String {
        let errs = out.split(whereSeparator: \.isNewline)
            .filter { $0.contains("ERROR") || $0.lowercased().contains("error:") }
        return String((errs.isEmpty ? Substring(out) : Substring(errs.joined(separator: " "))).prefix(220))
    }

    // MARK: Status

    struct Status {
        let clients: [String]      // which MCP clients have it registered
        let version: String?       // current server __version__
        let upToDate: Bool         // registration points at the current script + a working venv
        var installed: Bool { !clients.isEmpty }
    }

    static func isInstalled(profile: MCPProfile = .device) -> Bool { status(profile: profile).installed }

    /// Where things stand right now for one profile — installed/version/staleness.
    static func status(profile: MCPProfile = .device) -> Status {
        var clients: [String] = []
        var stale = false
        // `allAdapters.reversed()` preserves the pre-adapter check order
        // (Claude Desktop, then Claude Code) so status lines read exactly as
        // they did before the split, even though install/uninstall act on
        // them in the opposite order.
        for adapter in allAdapters.reversed() {
            switch adapter.status(profile) {
            case .notInstalled:
                break
            case .installed:
                clients.append(adapter.displayName)
            case .stale:
                clients.append(adapter.displayName)
                stale = true
            }
        }
        let venvOK = FileManager.default.isExecutableFile(atPath: MCPPaths.venvPython.path)
        return Status(clients: clients, version: currentVersion(),
                      upToDate: !clients.isEmpty && venvOK && !stale)
    }

    /// The `__version__` of the current (repo or bundled) server script.
    static func currentVersion() -> String? {
        guard let s = MCPPaths.scriptURL(), let txt = try? String(contentsOf: s, encoding: .utf8) else { return nil }
        let re = try? NSRegularExpression(pattern: #"__version__\s*=\s*["']([^"']+)["']"#)
        let range = NSRange(txt.startIndex..., in: txt)
        guard let m = re?.firstMatch(in: txt, range: range), let r = Range(m.range(at: 1), in: txt)
        else { return nil }
        return String(txt[r])
    }

    // MARK: Install / uninstall

    static func install(profile: MCPProfile = .device, update: Bool = false,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = doInstall(profile: profile, update: update, progress: progress)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func doInstall(profile: MCPProfile, update: Bool, progress: @escaping (String) -> Void) -> Result {
        guard let script = MCPPaths.scriptURL() else {
            return Result(ok: false, message: "Couldn't find imirror_mcp.py (repo or bundle).")
        }
        // 1. venv + deps. mcp needs Python 3.10+, so (re)create the venv when it's
        //    missing OR was built with an older Python (e.g. the system 3.9).
        let venvUsable = isPython310Plus(MCPPaths.venvPython.path)
        if !venvUsable {
            guard let interp = pythonInterpreter() else {
                return Result(ok: false,
                    message: "Need Python 3.10+ for mcp — install it (e.g. `brew install python`) and retry.")
            }
            progress("Creating Python environment (\(URL(fileURLWithPath: interp).lastPathComponent))…")
            try? FileManager.default.removeItem(at: MCPPaths.venvDir)          // clear any old/broken venv
            try? FileManager.default.createDirectory(at: MCPPaths.venvDir.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let mk = ProcessRunner.spawn(interp, ["-m", "venv", MCPPaths.venvDir.path])
            guard mk.code == 0 else {
                return Result(ok: false, message: "venv creation failed: \(firstError(mk.out))")
            }
        }
        if !venvUsable || update {
            progress(update ? "Updating dependencies…" : "Installing dependencies (mcp)…")
            _ = ProcessRunner.spawn(MCPPaths.venvPython.path, ["-m", "pip", "install", "--upgrade", "pip"])  // old pip can't resolve mcp
            let reqs = script.deletingLastPathComponent().appendingPathComponent("requirements.txt")
            var pipArgs = ["-m", "pip", "install", "--upgrade"]
            if FileManager.default.fileExists(atPath: reqs.path) { pipArgs += ["-r", reqs.path] }
            else { pipArgs.append("mcp[cli]") }
            let pip = ProcessRunner.spawn(MCPPaths.venvPython.path, pipArgs)
            guard pip.code == 0 else {
                return Result(ok: false, message: "pip install failed: \(firstError(pip.out))")
            }
        }

        // 2. Register with every detected client, in order.
        var registered: [String] = []
        for adapter in allAdapters {
            guard adapter.detect() else { continue }
            progress(adapter.installProgressMessage)
            do {
                if let label = try adapter.install(profile) { registered.append(label) }
            } catch let error as AdapterInstallError {
                return Result(ok: false, message: error.message)
            } catch {
                return Result(ok: false, message: error.localizedDescription)
            }
        }

        guard !registered.isEmpty else {
            return Result(ok: false, message: "No MCP client found (Claude Code CLI or Claude Desktop).")
        }
        return Result(ok: true, message: "Installed ✓ — " + registered.joined(separator: ", "))
    }

    static func uninstall(profile: MCPProfile = .device, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var removed: [String] = []
            for adapter in allAdapters {
                if let label = adapter.remove(profile) { removed.append(label) }
            }
            let msg = removed.isEmpty ? "Nothing to remove." : "Removed from " + removed.joined(separator: ", ")
            DispatchQueue.main.async { completion(Result(ok: true, message: msg)) }
        }
    }
}
