// One MCP-server row in Settings — the Install/Reinstall/Update button, an
// Uninstall button, a spinner, and a status line — bound to an MCPProfile. The
// device and simulator sections are identical apart from the profile and the
// button's label suffix, so they share this instead of duplicating the outlets
// and three near-identical handlers per section.

import AppKit
import iMirrorCore

final class MCPSectionUI: NSObject {
    private let profile: MCPProfile
    private let noun: String            // "" for device, " (sim)" for simulator

    let button = NSButton()
    let uninstallButton = NSButton()
    let spinner = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    private var installed = false

    init(profile: MCPProfile, noun: String) {
        self.profile = profile
        self.noun = noun
        super.init()

        button.bezelStyle = .rounded
        button.title = "Install MCP server\(noun)"
        button.target = self
        button.action = #selector(primary)

        uninstallButton.bezelStyle = .rounded
        uninstallButton.title = "Uninstall"
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstallAction)
        uninstallButton.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false   // invisible until an op runs

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 268
        statusLabel.lineBreakMode = .byWordWrapping   // wrap, don't clip long status
        statusLabel.maximumNumberOfLines = 0
        statusLabel.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.cell?.isScrollable = false
    }

    /// The button row + status label to drop into the Settings stack, in order.
    func views() -> [NSView] {
        let row = NSStackView(views: [button, uninstallButton, spinner])
        row.orientation = .horizontal
        row.spacing = 8
        return [row, statusLabel]
    }

    /// Reflect installed/version/staleness in the button; on `updateLabel`, the
    /// status line too. Shells out off the main thread.
    func refresh(updateLabel: Bool) {
        if updateLabel { statusLabel.stringValue = "Checking…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MCPInstaller.status(profile: self.profile)
            DispatchQueue.main.async {
                self.installed = s.installed
                self.uninstallButton.isHidden = !s.installed
                self.button.title = !s.installed ? "Install MCP server\(self.noun)"
                                  : (s.upToDate ? "Reinstall" : "Update MCP server\(self.noun)")
                if updateLabel {
                    let ver = s.version.map { " · v\($0)" } ?? ""
                    self.statusLabel.stringValue = !s.installed
                        ? "Not installed."
                        : "Installed · \(s.clients.joined(separator: ", "))\(ver) · "
                          + (s.upToDate ? "up to date." : "update available.")
                }
            }
        }
    }

    @objc private func primary() {
        button.isEnabled = false; uninstallButton.isEnabled = false
        spinner.startAnimation(nil)
        let updating = installed             // reinstall/update re-points paths + refreshes deps
        statusLabel.stringValue = updating
            ? "Updating…" : "Installing… (first run sets up Python — up to ~30s)"
        MCPInstaller.install(profile: profile, update: updating, progress: { [weak self] msg in
            self?.statusLabel.stringValue = msg
        }, completion: { [weak self] r in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.statusLabel.stringValue = r.message
            self.button.isEnabled = true; self.uninstallButton.isEnabled = true
            self.refresh(updateLabel: false)
        })
    }

    @objc private func uninstallAction() {
        button.isEnabled = false; uninstallButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Removing…"
        MCPInstaller.uninstall(profile: profile) { [weak self] r in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.statusLabel.stringValue = r.message
            self.button.isEnabled = true; self.uninstallButton.isEnabled = true
            self.refresh(updateLabel: false)
        }
    }
}
