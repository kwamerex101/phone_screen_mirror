// The behavior-shaped seam between MCPInstaller and one MCP client.
//
// This is deliberately behavior-shaped (detect / status / install / remove),
// not config-path/write-shaped: Claude Code is CLI-driven (`claude mcp
// add/remove/get`) and writes no config file at all, so a config-path
// abstraction couldn't represent it without changing its behavior. Claude
// Desktop, by contrast, is a JSON file merge (see iMirrorCore.MCPConfig).
// Both fit behind this one protocol; a future editor adapter (Cursor, VS
// Code, ...) is a separate change on top of this seam.

import Foundation
import iMirrorCore

/// One MCP client's install status, at the granularity MCPInstaller has
/// always reported: present-and-current, present-but-pointing-somewhere-stale
/// (old script path, missing/changed env), or not present at all.
enum MCPClientStatus: Equatable {
    case notInstalled
    case installed
    case stale
}

/// A failure from `MCPClientAdapter.install` that should abort the whole
/// install with `message` — as opposed to a client simply not being present,
/// which `install` reports by returning nil, not by throwing.
struct AdapterInstallError: Error {
    let message: String
}

protocol MCPClientAdapter {
    /// Shown in status lines and in the uninstall confirmation message.
    var displayName: String { get }

    /// Progress text shown while this client's install step runs.
    var installProgressMessage: String { get }

    /// Is this client present on this machine at all? Used only to gate
    /// install (a client is only acted on if it's actually there) — status()
    /// makes its own installed/stale determination independently of this.
    func detect() -> Bool

    /// Installed / stale / not-installed for this profile's server name.
    func status(_ profile: MCPProfile) -> MCPClientStatus

    /// Registers the server for this profile. Returns the label to report on
    /// success (may differ from `displayName`, e.g. Claude Desktop's "restart
    /// it" reminder), or nil if nothing was registered (client not present,
    /// or the registration attempt itself failed without it being a fatal
    /// error). Throws `AdapterInstallError` only for a failure serious enough
    /// to abort the whole install.
    func install(_ profile: MCPProfile) throws -> String?

    /// Removes the server registration for this profile, if any. Returns the
    /// label to report, or nil if there was nothing to remove.
    func remove(_ profile: MCPProfile) -> String?
}
