// iMirror — mirror a USB-connected iPhone to a macOS window, take screenshots,
// and control it from the Mac via WebDriverAgent — while the phone stays
// physically usable (unlike Apple's "iPhone Mirroring").
//
// Dependency-free: AppKit + Foundation. The mirror itself is decoded WDA-MJPEG
// frames (plain CGImages), not a local capture session.
//
// UI: a native unified NSToolbar (Liquid Glass on macOS 26) with SF Symbol
// controls and an NSSwitch for control; status shown in the window subtitle.
//
// SECURITY: control talks to WDA over loopback only (no auth on WDA's wire), and
// is OFF by default — you must explicitly connect and flip the Control switch.

import AppKit
import iMirrorCore
import os

/// Unified-logging channel. NSLog output was not reaching `log show`, which made
/// field reports (black mirror on a user's Mac) undiagnosable without a debugger.
let mirrorLog = Logger(subsystem: "com.local.imirror", category: "capture")

// MARK: - Preview view (hosts preview layer + captures mouse/keyboard)

final class PreviewView: NSView {
    /// Displays decoded WDA-MJPEG frames (plain CGImages).
    private let imageLayer = CALayer()

    /// Pixel size of the most recently displayed frame (set by `setFrame`).
    /// AppDelegate uses this to compute the aspect-fit video rect for coordinate
    /// mapping, the same role AVCaptureVideoPreviewLayer's own rect conversion
    /// used to play.
    private(set) var lastFrameSize: CGSize?

    // View-space callbacks (AppDelegate transforms to device coordinates).
    var onTap: ((CGPoint) -> Void)?
    var onDrag: (([CGPoint], _ flick: Bool) -> Void)?   // path + fast-release flag
    var onScroll: ((_ at: CGPoint, _ delta: CGVector) -> Void)?  // trackpad scroll
    var onType: ((String) -> Void)?

    private var downPoint: CGPoint?
    private var dragSamples: [(p: CGPoint, t: TimeInterval)] = []
    private var wheelAccum = CGVector(dx: 0, dy: 0)
    private let kFlickWindowSec: TimeInterval = 0.08    // trailing window for flick velocity

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// Displays a freshly decoded MJPEG frame. Main-thread only: the MJPEG
    /// client delivers frames on its own queue, so callers must hop to main
    /// before calling this.
    func setFrame(_ image: CGImage) {
        imageLayer.contents = image
        lastFrameSize = CGSize(width: image.width, height: image.height)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True while Control is armed. Drives the cursor (a pointing hand signals the
    /// mirror is interactive) so a click while Control is off isn't a silent no-op.
    var controlActive = false {
        didSet {
            guard controlActive != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        if controlActive { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// Brief local ripple at a tap point — acknowledges the tap the instant it's
    /// dispatched, independent of WDA's network round-trip, so a slow response
    /// reads differently from a dropped one.
    func flashTap(at point: CGPoint) {
        let d: CGFloat = 46
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        ripple.position = point
        ripple.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        ripple.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        ripple.lineWidth = 2
        ripple.opacity = 0
        layer?.addSublayer(ripple)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "tapFlash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak ripple] in
            ripple?.removeFromSuperlayer()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        dragSamples = [(p, event.timestamp)]
    }

    override func mouseDragged(with event: NSEvent) {
        dragSamples.append((convert(event.locationInWindow, from: nil), event.timestamp))
    }

    override func mouseUp(with event: NSEvent) {
        let up = convert(event.locationInWindow, from: nil)
        guard let down = downPoint else { return }
        downPoint = nil
        dragSamples.append((up, event.timestamp))           // release point in the window + path
        let dx = up.x - down.x, dy = up.y - down.y
        if (dx * dx + dy * dy).squareRoot() > 6 {
            let flick = releaseIsFlick()
            onDrag?(gesturePath(flick: flick), flick)
        } else {
            onTap?(up)
        }
        dragSamples = []
    }

    /// True when the trailing ~80ms of travel is fast enough to read as a flick — so
    /// the gesture is sent as one quick swipe (snappy scroll jump) rather than a
    /// faithful 1:1 path replay (precise drag). The 80ms window survives a single
    /// coalesced (~16ms) event. (WDA can't produce inertial momentum — see
    /// WDAClient.drag — so a flick just scrolls fast, it doesn't coast.)
    private func releaseIsFlick() -> Bool {
        guard let b = dragSamples.last, dragSamples.count >= 2 else { return false }
        var i = dragSamples.count - 1
        while i > 0 && b.t - dragSamples[i - 1].t < kFlickWindowSec { i -= 1 }
        guard dragSamples.count - i >= 3 else { return false }   // too few samples → velocity unreliable
        let a = dragSamples[i]
        let dt = Swift.max(b.t - a.t, 1.0 / 240)            // guard against /0
        let dist = ((b.p.x - a.p.x) * (b.p.x - a.p.x)
                  + (b.p.y - a.p.y) * (b.p.y - a.p.y)).squareRoot()
        return dist > 25 && dist / dt > 800                // view points/sec (tune)
    }

    /// Points to send for the gesture. For a flick, only the last ~100ms of travel,
    /// so the swipe's origin is where the flick actually started — not an earlier
    /// slow wander, which would encode the wrong angle and distance.
    private func gesturePath(flick: Bool) -> [CGPoint] {
        guard flick, let b = dragSamples.last else { return dragSamples.map { $0.p } }
        var start = 0
        for i in stride(from: dragSamples.count - 1, through: 0, by: -1)
        where b.t - dragSamples[i].t >= kFlickWindowSec { start = i; break }
        return dragSamples[start...].map { $0.p }
    }

    /// Two-finger trackpad scroll. Accumulate the finger distance and emit one quick
    /// swipe when the user lifts (phase .ended); the Mac's own inertial frames are
    /// ignored (the phone can't reproduce momentum, so a coasting tail would just be
    /// extra 1:1 swipes). A legacy mouse wheel (no precise deltas, no phase) instead
    /// emits an immediate nudge per tick. Direction is normalised via
    /// isDirectionInvertedFromDevice (the authoritative Natural-Scroll flag): dy > 0
    /// means the finger moved up, dx > 0 means it moved right.
    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase != [] { return }                       // iOS supplies the tail
        if event.phase.contains(.cancelled) { wheelAccum = .zero; return }
        if event.phase.contains(.began) { wheelAccum = .zero }        // drop any stale partial gesture
        let at = convert(event.locationInWindow, from: nil)
        let inv = event.isDirectionInvertedFromDevice
        let dx = inv ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inv ? event.scrollingDeltaY : -event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Legacy wheel: discrete ticks, no phase. Emit an immediate nudge.
            let nudge = CGVector(dx: dx * 30, dy: dy * 30)
            if (nudge.dx * nudge.dx + nudge.dy * nudge.dy).squareRoot() >= 8 { onScroll?(at, nudge) }
            return
        }
        wheelAccum.dx += dx
        wheelAccum.dy += dy
        if event.phase.contains(.ended) {
            var d = wheelAccum
            wheelAccum = .zero
            // Dominant-axis dead zone: a near-vertical scroll shouldn't smear the
            // content sideways (and vice-versa). Drop the minor axis when it's < 30%
            // of the major; true diagonals (both axes comparable) pass through.
            if abs(d.dx) < abs(d.dy) * 0.3 { d.dx = 0 }
            else if abs(d.dy) < abs(d.dx) * 0.3 { d.dy = 0 }
            if (d.dx * d.dx + d.dy * d.dy).squareRoot() > 4 { onScroll?(at, d) }
        }
    }

    /// Clear any buffered trackpad delta — call when control is disarmed so a stale
    /// partial gesture can't fire a phantom swipe on re-enable.
    func resetScroll() { wheelAccum = .zero }

    override func keyDown(with event: NSEvent) {
        // Map special keys to the characters XCUITest's typeText understands.
        switch event.keyCode {
        case 51:        onType?("\u{8}")   // delete / backspace
        case 117:       onType?("\u{7F}")  // forward delete
        case 36, 76:    onType?("\n")      // return / enter
        case 48:        onType?("\t")      // tab
        default:
            if let chars = event.characters, !chars.isEmpty { onType?(chars) }
        }
    }
}

// MARK: - Click-through glass strip (status HUD that doesn't block the preview)

final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Toolbar item identifiers

private extension NSToolbarItem.Identifier {
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let health     = NSToolbarItem.Identifier("health")
    static let control    = NSToolbarItem.Identifier("control")
    static let settings   = NSToolbarItem.Identifier("settings")
    static let home       = NSToolbarItem.Identifier("home")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var window: NSWindow!
    private var previewView: PreviewView!
    private var emptyStateView: NSView!
    private var statusLabel: NSTextField!

    // Toolbar controls
    private let controlSwitch = NSSwitch()
    private let automationSwitch = NSSwitch()
    private let settingsButton = NSButton()
    private let settingsPopover = NSPopover()
    private var settingsBuilt = false
    private let deviceMCP = MCPSectionUI(profile: .device, noun: "")
    private let simMCP = MCPSectionUI(profile: .simulator, noun: " (sim)")
    private let simController = SimulatorController()
    private var simDevices: [SimDevice] = []
    private let simPicker = NSPopUpButton()
    private let simEnableButton = NSButton()
    private let simStatusLabel = NSTextField(labelWithString: "")
    private var simEnabled = false
    private let iosRunnerLabel = NSTextField(labelWithString: "")
    private var lastRunnerInstall: RunnerInstall?
    private let healthButton = NSButton()
    private var screenshotItem: NSToolbarItem!
    private var controlItem: NSToolbarItem!
    private var homeItem: NSToolbarItem!

    private var mjpeg: MJPEGClient?
    /// True once WDA-MJPEG frames are actually flowing. Distinct from `health`,
    /// which only reflects the WDA HTTP session — the MJPEG socket can connect,
    /// drop, and reconnect independently of that session.
    private var mirroring = false
    /// Latest decoded WDA-MJPEG frame (updated on main by the mjpeg.onFrame handler).
    /// Screenshot now saves this instead of the (now-unused) capture pixel buffer.
    private var lastFrame: CGImage?

    // Control + health monitor
    private enum Health { case down, connecting, connected }
    private let transport = Transport()
    private var wda: WDAClient?
    private var controlEnabled = false
    private var automationEnabled = false
    private var health: Health = .down
    private var healthTimer: Timer?
    private var probing = false
    // True while the runner ipa is installing on the device. Pauses health probing
    // and pins the dot to "connecting" so the install progress isn't fought by the
    // probe loop (WDA legitimately isn't up yet during an install).
    private var installingRunner = false
    private var creatingSession = false
    private var downSince: Date?

    // Chain-level recovery ladder (see nextChainRecoveryAction in iMirrorCore):
    // ManagedProcess's own readiness deadline already recovers a wedged
    // runwda; this is the layer above that, for when even those respawns
    // aren't bringing WDA back.
    //
    // Monotonic (systemUptime, never Date()) so a Mac sleep can't skew it.
    // Seeded when automation turns on and whenever health first drops to
    // .down; cleared once health reconnects — see setAutomation/setHealth.
    private var chainWedgeSince: TimeInterval?
    private var chainRecoveryStage = 0
    /// Set once a full chain restart still hasn't recovered WDA. While set,
    /// runWatchdog stops trying automatically — only the user tapping the WDA
    /// dot (forceProbe) re-arms it. Product decision: no silent background
    /// retries after a confirmed give-up.
    private var wdaHardStopped = false
    /// How long each stage of the ladder gets before escalating: one
    /// ManagedProcess readiness cycle (40s) plus WDA's own boot time.
    private let chainRecoveryGraceSec: TimeInterval = 55

    // MJPEG partial-wedge watchdog (see nextMjpegRecoveryAction in
    // iMirrorCore): WDA's /status can stay healthy while the MJPEG stream has
    // silently died, so `health == .connected` alone isn't proof frames are
    // still arriving.
    private var mjpegLastFrameAt: TimeInterval?
    private var mjpegBounced = false
    private let mjpegNoFrameThresholdSec: TimeInterval = 20

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        // Surface a terminal-looking state if the WDA runner just can't start
        // (bad signing / unsupported device) rather than looping silently on red.
        transport.onWDAUnrecoverable = { [weak self] in
            guard let self, self.automationEnabled, self.health == .down else { return }
            self.setStatus("WebDriverAgent installed but won't start — trust the developer "
                         + "on the phone: Settings ▸ General ▸ VPN & Device Management.")
        }
        // Reflect the runner check/install (progress + outcome) in the UI. Invoked
        // on the main thread by Transport.
        transport.onRunnerInstall = { [weak self] event in
            guard let self, self.automationEnabled else { return }
            switch event {
            case .checking:
                break                           // fast; no need to flash the status
            case .installing:
                self.installingRunner = true
                self.updateHealthDot()          // pin dot to connecting (pulse)
                self.setStatus("Installing WebDriverAgent on iPhone… (first time can take ~30s)")
            case .done(let result):
                self.installingRunner = false
                self.lastRunnerInstall = result
                self.updateRunnerStatusLabel()
                switch result {
                case .installed:
                    self.setStatus("WebDriverAgent installed — starting…")
                case .alreadyPresent, .noBundle:
                    break                       // normal boot; health monitor takes over
                case .failed(let err):
                    self.setHealth(.down)
                    // Cancel the generic 6s "Starting WebDriverAgent…" text so our
                    // specific, actionable failure message isn't overwritten.
                    self.downStatusWorkItem?.cancel(); self.downStatusWorkItem = nil
                    self.setStatus(self.installFailureMessage(err))
                }
                self.updateHealthDot()
            }
        }
        updateHealthDot()        // grey — automation off
        // Automation now drives the entire mirror (WDA-MJPEG frames replace camera
        // capture), so it always starts on launch instead of waiting for an opt-in.
        automationSwitch.state = .on
        setAutomation(true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        transport.stop()
        mjpeg?.stop()
    }

    // MARK: UI

    /// A plain SPM executable ships no MainMenu nib, so build one: the standard App
    /// and Window menus (Quit/Hide/Minimize a Mac user expects) plus a Controls
    /// menu that gives the toolbar actions real keyboard shortcuts.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About iMirror",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iMirror",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iMirror",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let ctrlItem = NSMenuItem()
        mainMenu.addItem(ctrlItem)
        let ctrlMenu = NSMenu(title: "Controls")
        ctrlItem.submenu = ctrlMenu
        let shot = ctrlMenu.addItem(withTitle: "Screenshot", action: #selector(takeScreenshot), keyEquivalent: "s")
        shot.target = self
        let home = ctrlMenu.addItem(withTitle: "Home", action: #selector(pressHome), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        home.target = self

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iMirror"
        window.titleVisibility = .hidden   // free the unified toolbar for the controls
        window.center()
        window.setFrameAutosaveName("iMirrorMain")
        // Stop the window shrinking into a degenerate size that clips the toolbar;
        // the content aspect ratio is locked to the phone once its size is known.
        window.contentMinSize = NSSize(width: 260, height: 480)

        // Container: preview fills it; a click-through glass HUD shows status at
        // the bottom so the toolbar stays clean.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 880))

        previewView = PreviewView(frame: container.bounds)
        previewView.autoresizingMask = [.width, .height]
        wireInput()
        container.addSubview(previewView)

        // Minimal empty state over the (black) preview when no iPhone is connected.
        emptyStateView = makeEmptyStateView()
        container.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -24),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        let hud = PassthroughEffectView()
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)

        statusLabel = NSTextField(labelWithString: "Looking for iPhone…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: hud.topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -5),
        ])

        window.contentView = container

        // Control switch (iOS-style toggle) — arms sending taps; needs WDA connected.
        controlSwitch.target = self
        controlSwitch.action = #selector(toggleControl)
        controlSwitch.isEnabled = false
        controlSwitch.setAccessibilityLabel("Control — drive the phone from the preview")

        // Automation switch — starts/stops WebDriverAgent (and iOS's on-phone
        // "Automation Running" overlay). Off by default: view-only until you opt in.
        automationSwitch.target = self
        automationSwitch.action = #selector(toggleAutomation)
        automationSwitch.state = .off
        automationSwitch.setAccessibilityLabel("Automation — start or stop WebDriverAgent")

        // Health dot — colored status, click to force a re-check
        healthButton.isBordered = false
        healthButton.bezelStyle = .toolbar
        healthButton.imagePosition = .imageOnly
        healthButton.wantsLayer = true   // for the tint cross-fade + connecting pulse
        healthButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "WDA status")
        healthButton.contentTintColor = .systemGray
        healthButton.target = self
        healthButton.action = #selector(forceProbe)
        healthButton.toolTip = "WDA status — click to re-check"

        // Settings gear — opens the settings popover (automation, scroll speed, …).
        settingsButton.isBordered = true
        settingsButton.bezelStyle = .toolbar
        settingsButton.imagePosition = .imageOnly
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.toolTip = "iMirror settings"

        let toolbar = NSToolbar(identifier: "iMirrorToolbar")
        toolbar.delegate = self
        // Icon-only keeps the bar compact for the narrow (portrait) window;
        // each item carries a tooltip for discoverability.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(previewView)
    }

    // SF Symbol helper
    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }

    /// Quiet, centered empty state shown over the black preview when no iPhone is
    /// connected. A thin phone glyph + a title + a one-line hint — nothing loud.
    private func makeEmptyStateView() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "No iPhone")?
            .withSymbolConfiguration(.init(pointSize: 52, weight: .ultraLight))
        icon.contentTintColor = .tertiaryLabelColor

        // Wrapping labels so longer copy (e.g. the camera-permission guidance)
        // wraps to multiple centered lines instead of clipping.
        let title = NSTextField(wrappingLabelWithString: "No iPhone connected")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.isSelectable = false
        title.preferredMaxLayoutWidth = 300

        let hint = NSTextField(wrappingLabelWithString: "Plug in via USB, unlock, and tap “Trust.”")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = 300

        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(14, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true                    // layer-backed so alphaValue animates
        return stack
    }

    /// Cross-fade the empty state instead of snapping it — the first mirror frame
    /// otherwise pops in abruptly the instant a device binds.
    private func setEmptyState(hidden: Bool) {
        guard let v = emptyStateView else { return }
        if hidden {
            guard !v.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                v.animator().alphaValue = 0
            }, completionHandler: { v.isHidden = true })
        } else {
            v.isHidden = false
            v.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                v.animator().alphaValue = 1
            }
        }
    }

    private func actionItem(_ id: NSToolbarItem.Identifier, _ label: String,
                            _ symbolName: String, _ action: Selector,
                            enabled: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = symbol(symbolName, label)
        item.target = self
        item.action = action
        item.isBordered = true
        item.isEnabled = enabled
        return item
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.screenshot, .flexibleSpace, .health, .control, .settings, .home]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.screenshot, .health, .control, .settings, .home, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .screenshot:
            // enabled starts false and flips on via setHealth's .connected/.down
            // branches now that there's no device-bind step to gate it on.
            screenshotItem = actionItem(.screenshot, "Screenshot", "camera.viewfinder",
                                        #selector(takeScreenshot), enabled: false)
            return screenshotItem

        case .health:
            let item = NSToolbarItem(itemIdentifier: .health)
            item.label = "WDA"
            item.toolTip = "WDA connection status"
            item.view = healthButton
            return item

        case .control:
            controlItem = NSToolbarItem(itemIdentifier: .control)
            controlItem.label = "Control"
            controlItem.toolTip = "Drive the phone from the preview (taps, swipes, typing)"
            controlItem.view = controlSwitch
            // A custom-view toolbar item is dead in the narrow-window overflow menu;
            // this menu form makes Control work there too.
            let cmenu = NSMenuItem(title: "Control", action: #selector(toggleControlFromMenu), keyEquivalent: "")
            cmenu.target = self
            controlItem.menuFormRepresentation = cmenu
            return controlItem

        case .settings:
            let item = NSToolbarItem(itemIdentifier: .settings)
            item.label = "Settings"
            item.toolTip = "iMirror settings — automation (WDA), scroll speed, …"
            item.view = settingsButton
            let smenu = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
            smenu.target = self
            item.menuFormRepresentation = smenu
            return item

        case .home:
            homeItem = actionItem(.home, "Home", "house",
                                  #selector(pressHome), enabled: false)
            return homeItem

        default:
            return nil
        }
    }

    // MARK: Screenshot

    @objc private func takeScreenshot() {
        guard let cgImage = lastFrame else {
            setStatus("No frame yet — wait for the mirror to start.")
            return
        }
        let name = "iMirror_\(timestamp()).png"
        let url = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        // PNG-encode + write off the main thread: a blocking file write (to a possibly
        // iCloud-synced ~/Pictures) would otherwise hitch the UI on a click that should
        // feel instant. Only the status update hops back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async { self.setStatus("Screenshot failed (could not encode PNG).") }
                return
            }
            do {
                try png.write(to: url)
                DispatchQueue.main.async { self.setStatus("Saved \(url.lastPathComponent) → ~/Pictures") }
            } catch {
                DispatchQueue.main.async { self.setStatus("Screenshot save failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Control (WDA)

    private func wireInput() {
        previewView.onTap = { [weak self] viewPoint in
            guard let self, self.controlEnabled, let p = self.devicePoint(fromViewPoint: viewPoint) else { return }
            self.wda?.tap(at: p)
            self.previewView.flashTap(at: viewPoint)   // local acknowledgment
        }
        previewView.onDrag = { [weak self] viewPath, flick in
            guard let self, self.controlEnabled else { return }
            let devicePath = downsample(viewPath, max: 24)
                .compactMap { self.devicePoint(fromViewPoint: $0) }
            guard devicePath.count >= 2 else { return }
            self.wda?.drag(path: devicePath, flick: flick)
        }
        previewView.onScroll = { [weak self] viewPoint, viewDelta in
            guard let self, self.controlEnabled,
                  let size = self.wda?.deviceSize,
                  let start = self.devicePoint(fromViewPoint: viewPoint) else { return }
            guard let frameSize = self.previewView.lastFrameSize else { return }
            let videoRect = self.displayedImageRect(in: self.previewView.bounds, imageSize: frameSize)
            guard videoRect.width > 1, videoRect.height > 1 else { return }
            // Scale view-space scroll distance into device points and send one fast
            // swipe. Since the phone can't add inertia, `gain` amplifies the swipe
            // length so a small trackpad push still travels a useful distance — it
            // stacks on the view→device scale (~2.4x) and is live-tunable via the
            // UserDefaults key "imirror.scrollGain".
            let gain = Swift.max(0.2, UserDefaults.standard.object(forKey: "imirror.scrollGain") as? Double ?? 3.5)
            // viewDelta normalised: dy>0 = finger up = device pointer moves up (y down).
            var end = CGPoint(x: start.x + viewDelta.dx * gain * (size.width / videoRect.width),
                              y: start.y - viewDelta.dy * gain * (size.height / videoRect.height))
            end.x = Swift.min(Swift.max(end.x, 0), size.width)
            end.y = Swift.min(Swift.max(end.y, 0), size.height)
            let moved = ((end.x - start.x) * (end.x - start.x)
                       + (end.y - start.y) * (end.y - start.y)).squareRoot()
            guard moved >= 20 else { return }          // skip imperceptible swipes
            self.wda?.drag(path: [start, end], flick: true)
        }
        previewView.onType = { [weak self] text in
            guard let self, self.controlEnabled else { return }
            self.wda?.typeText(text)
        }
    }

    /// Aspect-fit rect of `imageSize` centered within `bounds` (both in the view's
    /// own y-up coordinate space) — the CALayer analogue of what
    /// AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:) used
    /// to compute automatically when the preview was capture-backed.
    private func displayedImageRect(in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let x = bounds.minX + (bounds.width - w) / 2
        let y = bounds.minY + (bounds.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Map a click in the preview to a device point. The aspect-fit rect of the
    /// latest MJPEG frame within the view handles letterboxing + orientation;
    /// mapToDevice (in iMirrorCore) does the normalize + y-flip and is unit-tested.
    private func devicePoint(fromViewPoint p: CGPoint) -> CGPoint? {
        guard let size = wda?.deviceSize, let frameSize = previewView.lastFrameSize else { return nil }
        let videoRect = displayedImageRect(in: previewView.bounds, imageSize: frameSize)
        return mapToDevice(viewPoint: p, videoRect: videoRect, deviceSize: size)
    }

    // MARK: WDA health monitor (auto-connect + auto-reconnect)

    /// Loopback only — WDA has no auth on the wire (see SECURITY-AUDIT.md).
    private func startHealthMonitor() {
        wda = WDAClient()   // defaults to http://127.0.0.1:8100
        probeNow()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.probeNow() }
        RunLoop.main.add(timer, forMode: .common)   // keep firing during UI tracking
        healthTimer = timer
    }

    /// The WDA toolbar dot's click handler. Normally just forces a probe; but
    /// once the recovery ladder has hard-stopped (see runWatchdog), a plain
    /// probe would never re-arm it — WDA is actually down and a probe alone
    /// changes nothing. In that state, a tap is the user explicitly asking to
    /// retry, so re-arm the ladder and kick a chain restart directly.
    @objc private func forceProbe() {
        guard wdaHardStopped else { probeNow(); return }
        wdaHardStopped = false
        chainRecoveryStage = 0
        chainWedgeSince = ProcessInfo.processInfo.systemUptime
        setStatus("Retrying WebDriverAgent…")
        transport.restartChain()
    }

    private func probeNow() {
        guard automationEnabled else { return }   // no WDA to probe when automation is off
        guard !installingRunner else { return }   // WDA legitimately down mid-install
        guard !probing else { return }
        // Don't probe mid-gesture: a probe GET contends with the in-flight /actions
        // on WDA's single XCUITest queue and can time out into a false .down.
        // gestureInFlight is set/cleared only on DispatchQueue.main — main-thread safe.
        if wda?.isGestureInFlight == true { return }
        probing = true
        wda?.probe { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                switch result {
                case .alive:
                    self.setHealth(.connected)
                case .down:
                    self.setHealth(.down)
                case .needsSession:
                    self.createSession()
                }
                self.runWatchdog()
                self.checkMjpegWatchdog()
            }
        }
    }

    /// Chain-level recovery ladder. `ManagedProcess`'s own readiness deadline
    /// (see Transport.swift) already kills and respawns a wedged `runwda` on
    /// its own — this only needs to cover what's above that: escalate to a
    /// full chain restart if those respawns still aren't recovering WDA, then
    /// hard-stop automatic recovery once even that hasn't worked, so a
    /// genuinely stuck device doesn't restart-loop forever in the background.
    /// Pure decision in `nextChainRecoveryAction` (iMirrorCore); this just
    /// drives it off the monotonic down-duration and current stage.
    private func runWatchdog() {
        guard automationEnabled, transport.canSelfManage else { return }
        guard health == .down, !wdaHardStopped else { return }
        guard let wedgeSince = chainWedgeSince else { return }
        let downFor = ProcessInfo.processInfo.systemUptime - wedgeSince
        switch nextChainRecoveryAction(downForSec: downFor, stage: chainRecoveryStage, graceSec: chainRecoveryGraceSec) {
        case .wait:
            break
        case .restartChain:
            chainRecoveryStage = 1
            chainWedgeSince = ProcessInfo.processInfo.systemUptime   // restart the clock for the next stage
            setStatus("WebDriverAgent is taking longer than usual, resetting the connection…")
            transport.restartChain()
        case .giveUp:
            wdaHardStopped = true
            setStatus("WebDriverAgent won't start. Tap WDA to retry.")
        }
    }

    /// MJPEG partial-wedge watchdog: WDA's HTTP session can be perfectly
    /// healthy while the video stream underneath it has silently died, so a
    /// green dot with no picture needs its own check. Cheapest fix first
    /// (bounce just the `forward` child carrying the MJPEG port); only
    /// escalate to a full chain restart if that didn't bring frames back.
    private func checkMjpegWatchdog() {
        guard health == .connected, mjpeg != nil, let lastFrame = mjpegLastFrameAt else { return }
        let noFrameFor = ProcessInfo.processInfo.systemUptime - lastFrame
        switch nextMjpegRecoveryAction(noFrameForSec: noFrameFor, alreadyBounced: mjpegBounced, thresholdSec: mjpegNoFrameThresholdSec) {
        case .wait:
            break
        case .bounceForward:
            mjpegBounced = true
            NSLog("iMirror: no MJPEG frames for \(Int(noFrameFor))s — bouncing the MJPEG forward")
            transport.bounceMJPEGForward()
        case .escalate:
            NSLog("iMirror: MJPEG still stalled after a forward bounce — escalating to a chain restart")
            // Restart the no-frame clock so this doesn't fire again on the next
            // tick before health actually flips to .down (which is what really
            // resets this state, below).
            mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
            mjpegBounced = false
            setStatus("Video stalled — resetting the connection…")
            chainRecoveryStage = 1
            chainWedgeSince = ProcessInfo.processInfo.systemUptime
            transport.restartChain()
        }
    }

    private func createSession() {
        guard !creatingSession else { return }
        creatingSession = true
        setHealth(.connecting)
        wda?.connect { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.creatingSession = false
                if case .success = result { self.setHealth(.connected) }
                else { self.setHealth(.down) }
            }
        }
    }

    private var downStatusWorkItem: DispatchWorkItem?
    private var hadSuccessfulConnection = false

    private func setHealth(_ new: Health) {
        let changed = (new != health)
        health = new
        updateHealthDot()                       // dot colour is always instant

        switch new {
        case .connected:
            downSince = nil
            // Back to healthy — clear the chain-recovery ladder so the next
            // outage (if any) starts a fresh stage-0 grace window instead of
            // inheriting whatever was left over from this one.
            chainWedgeSince = nil
            chainRecoveryStage = 0
            wdaHardStopped = false
            hadSuccessfulConnection = true
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            controlSwitch.isEnabled = true
            homeItem?.isEnabled = true
            screenshotItem?.isEnabled = true
            if changed {
                let s = wda?.deviceSize ?? .zero
                // Lock resizing to the phone's proportions so the mirror fills the
                // window without letterboxing (portrait points; landscape just
                // shows bars until the next connect).
                if s.width > 0, s.height > 0 {
                    window.contentAspectRatio = NSSize(width: s.width, height: s.height)
                }
                setStatus("WDA connected — \(Int(s.width))×\(Int(s.height)) pts. Flip Control to drive.")
            }
            // Start the MJPEG mirror the moment WDA is healthy. Guarded against
            // double-start: setHealth(.connected) can fire on every probe tick
            // once connected, and MJPEGClient.start() would otherwise tear down
            // and reopen a perfectly good stream each time.
            if mjpeg == nil {
                // Host port 9110 forwards to the device's fixed WDA mjpegServerPort 9100, chosen to avoid colliding with other local services that commonly use 9100.
                let client = MJPEGClient(port: 9110)
                client.onFrame = { [weak self] cg in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
                        self.lastFrame = cg
                        self.previewView.setFrame(cg)
                        if !self.mirroring {
                            self.mirroring = true
                            self.setEmptyState(hidden: true)
                            self.setStatus("Mirroring — phone stays usable.")
                        }
                    }
                }
                client.onStateChange = { [weak self] connected in
                    DispatchQueue.main.async {
                        guard let self, !connected else { return }
                        // MJPEG socket dropped independently of the WDA HTTP session — show
                        // the waiting state until frames resume.
                        self.mirroring = false
                        self.setEmptyState(hidden: false)
                        self.setStatus("Waiting for video from iPhone…")
                    }
                }
                mjpeg = client
                // Seed the no-frame clock at start so the watchdog measures
                // from "stream just opened," not from a nil baseline that
                // would otherwise read as an already-ancient last frame.
                mjpegLastFrameAt = ProcessInfo.processInfo.systemUptime
                mjpegBounced = false
                client.start()
            }
        case .connecting:
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            if changed { setStatus("Connecting to WDA…") }
        case .down:
            if downSince == nil { downSince = Date() }
            // Seed the ladder's monotonic clock the first time this outage
            // shows up (it's also seeded at automation-on and reset at each
            // restartChain — see setAutomation/runWatchdog). Without this, an
            // outage that starts after a prior .connected (which clears it)
            // would never start timing again.
            if chainWedgeSince == nil { chainWedgeSince = ProcessInfo.processInfo.systemUptime }
            // Lost the connection — disarm control so stray clicks can't fire.
            if controlEnabled {
                controlEnabled = false
                controlSwitch.state = .off
                previewView.controlActive = false
                previewView.resetScroll()
            }
            controlSwitch.isEnabled = false
            homeItem?.isEnabled = false
            screenshotItem?.isEnabled = false
            mjpeg?.stop()
            mjpeg = nil
            mirroring = false
            setEmptyState(hidden: false)
            // Debounce the *status text* by 6s: a brief probe blip during heavy
            // scrolling flips health to .down for one cycle, and flashing
            // "Starting WebDriverAgent…" on every scroll is alarming and wrong.
            // The red dot already shows instantly above; only the text waits.
            if changed {
                downStatusWorkItem?.cancel()
                let canManage = transport.canSelfManage
                let reconnecting = hadSuccessfulConnection
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.health == .down else { return }
                    self.setStatus(reconnecting ? "WDA reconnecting…"
                        : (canManage ? "Starting WebDriverAgent… (first launch can take ~20s)"
                                     : "WDA unreachable — run ./scripts/wda-up.sh"))
                }
                downStatusWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
            }
        }
    }

    private var healthDotColor: NSColor?

    private func updateHealthDot() {
        guard automationEnabled else {
            setHealthDot(.systemGray, tip: "Automation off — flip Automation on to control the phone",
                         a11y: "automation off", pulsing: false)
            return
        }
        if installingRunner {
            setHealthDot(.systemYellow, tip: "Installing WebDriverAgent on iPhone…",
                         a11y: "installing runner", pulsing: true)
            return
        }
        switch health {
        case .connected:
            setHealthDot(.systemGreen, tip: "WDA connected — click to re-check",
                         a11y: "connected", pulsing: false)
        case .connecting:
            setHealthDot(.systemYellow, tip: "Connecting to WDA…",
                         a11y: "connecting", pulsing: true)
        case .down:
            setHealthDot(.systemRed, tip: "WDA unreachable — click to re-check",
                         a11y: "unreachable", pulsing: false)
        }
    }

    /// Apply the health dot's colour/tooltip/label. Cross-fades the tint only when
    /// it actually changes (so a steady state doesn't flicker every probe), and
    /// runs a gentle opacity pulse while connecting so "in progress" reads
    /// differently from a stuck yellow. Also updates the VoiceOver label so status
    /// isn't communicated by hue alone.
    private func setHealthDot(_ color: NSColor, tip: String, a11y: String, pulsing: Bool) {
        healthButton.toolTip = tip
        healthButton.setAccessibilityLabel("WDA status: \(a11y)")
        if color != healthDotColor {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            healthButton.layer?.add(fade, forKey: "tint")
            healthButton.contentTintColor = color
            healthDotColor = color
        }
        let key = "connectingPulse"
        if pulsing {
            if healthButton.layer?.animation(forKey: key) == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = 0.7
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                healthButton.layer?.add(pulse, forKey: key)
            }
        } else {
            healthButton.layer?.removeAnimation(forKey: key)
        }
    }

    @objc private func toggleControl() {
        // Only allow arming control when actually connected.
        guard health == .connected else {
            controlSwitch.state = .off
            controlEnabled = false
            previewView.controlActive = false
            setStatus("Can't enable control — WDA not connected (dot is not green).")
            return
        }
        controlEnabled = (controlSwitch.state == .on)
        previewView.controlActive = controlEnabled
        if !controlEnabled { previewView.resetScroll() }
        setStatus(controlEnabled
            ? "Control ON — clicks/keys drive the phone."
            : "Control off — mirror only.")
    }

    /// Start or stop WebDriverAgent on demand. Off (default) = pure view-only
    /// mirroring: no go-ios children, no XCUITest session, and no iOS "Automation
    /// Running" overlay on the phone. On = bring the control channel up.
    @objc private func toggleAutomation() { setAutomation(automationSwitch.state == .on) }

    /// Enable/disable the WDA control channel and remember the choice across launches.
    private func setAutomation(_ on: Bool) {
        automationEnabled = on
        UserDefaults.standard.set(on, forKey: "imirror.automationEnabled")
        // Fresh run: the ladder and the MJPEG watchdog start clean either way,
        // whether we're arming automation or tearing it down.
        chainWedgeSince = nil
        chainRecoveryStage = 0
        wdaHardStopped = false
        mjpegLastFrameAt = nil
        mjpegBounced = false
        if on {
            setStatus("Automation ON — starting WebDriverAgent… "
                    + "(iOS shows an \"Automation Running\" overlay on the phone).")
            // Seed the ladder's clock now: WDA is down from the moment
            // automation turns on, and its own boot time counts against the
            // stage-0 grace window just like a mid-session outage would.
            chainWedgeSince = ProcessInfo.processInfo.systemUptime
            transport.start()        // spawn tunnel + runwda + forward + relay
            startHealthMonitor()     // begin probing; dot goes yellow → green
        } else {
            // Tear everything down so nothing runs on the phone (the overlay clears).
            controlEnabled = false
            controlSwitch.state = .off
            controlSwitch.isEnabled = false
            previewView.controlActive = false
            previewView.resetScroll()
            homeItem?.isEnabled = false
            healthTimer?.invalidate(); healthTimer = nil
            installingRunner = false
            wda = nil
            transport.stop()
            mjpeg?.stop()
            mjpeg = nil
            mirroring = false
            health = .down; downSince = nil
            updateHealthDot()        // grey — automation off
            setStatus("Automation off — mirror only (no control, no on-phone overlay).")
        }
    }

    /// Drive the Control switch from its overflow-menu form (custom-view toolbar
    /// items are non-interactive in the narrow-window `»` menu on their own).
    @objc private func toggleControlFromMenu() {
        controlSwitch.state = (controlSwitch.state == .on) ? .off : .on
        toggleControl()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleControlFromMenu) {
            menuItem.state = controlEnabled ? .on : .off
            return controlSwitch.isEnabled          // only armable once WDA is connected
        }
        return true
    }

    // MARK: Settings popover

    @objc private func showSettings() {
        if !settingsBuilt { buildSettingsPopover(); settingsBuilt = true }
        updateRunnerStatusLabel()   // refresh device/runner status each time it opens
        if settingsPopover.isShown { settingsPopover.close(); return }
        // Anchor to the gear when it's on screen; if it overflowed into the `»` menu
        // its view is detached (no window), so fall back to the window content view.
        let anchor: NSView = settingsButton.window != nil ? settingsButton : (window.contentView ?? settingsButton)
        let edge: NSRectEdge = anchor === settingsButton ? .maxY : .minY
        settingsPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    private func buildSettingsPopover() {
        let pad: CGFloat = 16
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "iMirror Settings")
        title.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(title)

        let autoRow = NSStackView()
        autoRow.orientation = .horizontal
        autoRow.spacing = 8
        autoRow.addArrangedSubview(NSTextField(labelWithString: "Automation (WebDriverAgent)"))
        autoRow.addArrangedSubview(automationSwitch)
        stack.addArrangedSubview(autoRow)

        let cap = NSTextField(wrappingLabelWithString:
            "On starts the control channel; iOS shows an “Automation Running” overlay on the phone. Off = view-only mirroring.")
        cap.font = .systemFont(ofSize: 11)
        cap.textColor = .secondaryLabelColor
        cap.preferredMaxLayoutWidth = 260
        stack.addArrangedSubview(cap)

        let scrollRow = NSStackView()
        scrollRow.orientation = .horizontal
        scrollRow.spacing = 8
        scrollRow.addArrangedSubview(NSTextField(labelWithString: "Scroll speed"))
        let slider = NSSlider(value: UserDefaults.standard.object(forKey: "imirror.scrollGain") as? Double ?? 3.5,
                              minValue: 0.5, maxValue: 6.0, target: self, action: #selector(scrollGainChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        scrollRow.addArrangedSubview(slider)
        stack.addArrangedSubview(scrollRow)

        // iPhone section — whether the WebDriverAgent runner is on the device.
        let devSep = NSBox(); devSep.boxType = .separator
        devSep.translatesAutoresizingMaskIntoConstraints = false
        devSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(devSep)

        let devTitle = NSTextField(labelWithString: "iPhone")
        devTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(devTitle)

        iosRunnerLabel.font = .systemFont(ofSize: 11)
        iosRunnerLabel.textColor = .secondaryLabelColor
        iosRunnerLabel.preferredMaxLayoutWidth = 268
        iosRunnerLabel.lineBreakMode = .byWordWrapping
        iosRunnerLabel.maximumNumberOfLines = 0
        iosRunnerLabel.usesSingleLineMode = false
        iosRunnerLabel.cell?.wraps = true
        stack.addArrangedSubview(iosRunnerLabel)
        updateRunnerStatusLabel()

        // MCP server section — one-click register with Claude Code / Claude Desktop.
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(sep)

        let mcpTitle = NSTextField(labelWithString: "MCP server (drive from Claude)")
        mcpTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(mcpTitle)

        let mcpCap = NSTextField(wrappingLabelWithString:
            "Register the iMirror MCP server with Claude Code and Claude Desktop so an "
          + "agent can drive the phone. (Turn Automation on for it to connect.)")
        mcpCap.font = .systemFont(ofSize: 11)
        mcpCap.textColor = .secondaryLabelColor
        mcpCap.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(mcpCap)

        for v in deviceMCP.views() { stack.addArrangedSubview(v) }
        deviceMCP.refresh(updateLabel: true)

        // iOS Simulator section — pick a sim, bring up WDA on :8201, install imirror-sim.
        let simSep = NSBox(); simSep.boxType = .separator
        simSep.translatesAutoresizingMaskIntoConstraints = false
        simSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(simSep)

        let simTitle = NSTextField(labelWithString: "iOS Simulator")
        simTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(simTitle)

        let simCap = NSTextField(wrappingLabelWithString:
            "Boot a Simulator and drive it from Claude. Enable brings up WebDriverAgent "
          + "on it (port 8201); view the sim in Apple's Simulator app. Requires Xcode.")
        simCap.font = .systemFont(ofSize: 11)
        simCap.textColor = .secondaryLabelColor
        simCap.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(simCap)

        simPicker.target = self
        simPicker.action = #selector(simPicked)
        stack.addArrangedSubview(simPicker)

        simEnableButton.bezelStyle = .rounded
        simEnableButton.title = "Enable"
        simEnableButton.target = self
        simEnableButton.action = #selector(toggleSimEnable)
        stack.addArrangedSubview(simEnableButton)

        simStatusLabel.font = .systemFont(ofSize: 11)
        simStatusLabel.textColor = .secondaryLabelColor
        simStatusLabel.preferredMaxLayoutWidth = 268
        simStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(simStatusLabel)

        for v in simMCP.views() { stack.addArrangedSubview(v) }

        simController.onState = { [weak self] state in self?.renderSimState(state) }
        refreshSimulators()
        simMCP.refresh(updateLabel: true)

        // Version footer.
        let verSep = NSBox(); verSep.boxType = .separator
        verSep.translatesAutoresizingMaskIntoConstraints = false
        verSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(verSep)

        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "iMirror \(ver) (build \(build))")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 300),
        ])
        let vc = NSViewController()
        vc.view = container
        settingsPopover.contentViewController = vc
        settingsPopover.behavior = .transient
    }

    @objc private func scrollGainChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "imirror.scrollGain")
    }

    /// Reflect whether the WebDriverAgent runner is on the connected iPhone. A live
    /// WDA connection is proof it's installed and running; otherwise fall back to
    /// the last install outcome, or a prompt to turn Automation on.
    private func updateRunnerStatusLabel() {
        let text: String
        if health == .connected {
            text = "WebDriverAgent app: installed and running ✓"
        } else {
            switch lastRunnerInstall {
            case .alreadyPresent, .installed:
                text = "WebDriverAgent app: installed"
            case .failed(.notProvisioned):
                text = "WebDriverAgent app: not signed for this iPhone — re-sign it for this device"
            case .failed(.deviceLocked):
                text = "WebDriverAgent app: unlock the iPhone, then retry"
            case .failed(.other):
                text = "WebDriverAgent app: install failed"
            case .noBundle:
                text = "WebDriverAgent app: status unknown (no bundled installer)"
            case nil:
                text = automationEnabled
                    ? "WebDriverAgent app: checking…"
                    : "WebDriverAgent app: turn Automation on to check / install"
            }
        }
        iosRunnerLabel.stringValue = text
    }

    /// Check installed state / version / staleness off the main thread (it shells
    /// out) and reflect it in the buttons — and the status line when `updateLabel`.

    private func refreshSimulators() {
        DispatchQueue.global(qos: .userInitiated).async {
            let hasXcode = self.simController.xcodeAvailable()
            let sims = hasXcode ? self.simController.listSimulators() : []
            DispatchQueue.main.async {
                self.simPicker.isEnabled = hasXcode
                self.simEnableButton.isEnabled = hasXcode
                guard hasXcode else { self.simStatusLabel.stringValue = "Requires Xcode."; return }
                self.simDevices = sims
                self.simPicker.removeAllItems()
                for s in sims {
                    self.simPicker.addItem(withTitle: "\(s.name) — \(s.runtime)"
                                           + (s.isBooted ? " (booted)" : ""))
                }
                if sims.isEmpty { self.simStatusLabel.stringValue = "No simulators found." }
            }
        }
    }

    @objc private func simPicked() { /* selection stored implicitly via indexOfSelectedItem */ }

    @objc private func toggleSimEnable() {
        if simEnabled {
            simController.disable()
            return
        }
        let idx = simPicker.indexOfSelectedItem
        guard idx >= 0, idx < simDevices.count else {
            simStatusLabel.stringValue = "Pick a simulator first."; return
        }
        simController.enable(udid: simDevices[idx].udid)
    }

    private func renderSimState(_ state: SimState) {
        switch state {
        case .idle:
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Off."
        case .booting:  simEnabled = true; simEnableButton.title = "Disable"; simStatusLabel.stringValue = "Booting simulator…"
        case .building: simStatusLabel.stringValue = "Building WebDriverAgent (first run ~2–3 min)…"
        case .starting: simStatusLabel.stringValue = "Starting WebDriverAgent…"
        case .ready:    simStatusLabel.stringValue = "WebDriverAgent ready on :8201 ✓"
        case .failed(let m):
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Failed: \(m)"
        }
    }

    @objc private func pressHome() {
        wda?.home()
    }

    // MARK: Helpers

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        NSLog("iMirror: \(text)")
    }

    /// Actionable, per-cause message for a failed runner install.
    private func installFailureMessage(_ err: RunnerInstallError) -> String {
        switch err {
        case .notProvisioned:
            return "Couldn’t install WebDriverAgent — it isn’t signed for this iPhone. "
                 + "Re-sign it for this device, then turn Automation off and on: "
                 + "WDA_DESTINATION=<your-udid> ./scripts/build-wda.sh"
        case .deviceLocked:
            return "Couldn’t install WebDriverAgent — unlock your iPhone, then turn "
                 + "Automation off and on to retry."
        case .other(let raw):
            return "WebDriverAgent install failed: \(raw)"
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
