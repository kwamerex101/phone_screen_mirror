// iMirror — mirror a USB-connected iPhone to a macOS window, take screenshots,
// and control it from the Mac via WebDriverAgent — while the phone stays
// physically usable (unlike Apple's "iPhone Mirroring").
//
// USB capture supplies the fast preview; WDA-MJPEG is the video fallback.
//
// UI: a native unified NSToolbar (Liquid Glass on macOS 26) with SF Symbol
// controls and an NSSwitch for control; status shown in the window subtitle.
//
// SECURITY: control talks to WDA over loopback only (no auth on WDA's wire), and
// is OFF by default — you must explicitly connect and flip the Control switch.

import AppKit
import AVFoundation
import iMirrorCore
import os

/// Unified-logging channel. NSLog output was not reaching `log show`, which made
/// field reports (black mirror on a user's Mac) undiagnosable without a debugger.
let mirrorLog = Logger(subsystem: "com.local.imirror", category: "capture")

/// Shared ease-out curve for the app's micro-animations (strong deceleration).
let iMirrorEaseOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

/// True when the user asked macOS to minimize motion; animations drop their
/// movement and keep opacity changes only.
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - Preview view (hosts preview layer + captures mouse/keyboard)

final class PreviewView: NSView {
    /// Displays decoded WDA-MJPEG frames (plain CGImages).
    private let imageLayer = CALayer()
    private let captureLayer = AVCaptureVideoPreviewLayer()

    /// Accent ring shown while Control is armed. Non-interactive, sits above
    /// the image and below tap ripples (added later as sublayers).
    private let controlRing = CAShapeLayer()

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
        captureLayer.videoGravity = .resizeAspect
        captureLayer.frame = bounds
        captureLayer.isHidden = true
        layer?.addSublayer(captureLayer)

        controlRing.fillColor = nil
        controlRing.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        controlRing.lineWidth = 2
        controlRing.opacity = 0
        layer?.addSublayer(controlRing)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        captureLayer.frame = bounds
        controlRing.frame = bounds
        controlRing.path = CGPath(rect: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
    }

    /// Displays a freshly decoded MJPEG frame. Main-thread only: the MJPEG
    /// client delivers frames on its own queue, so callers must hop to main
    /// before calling this.
    func setFrame(_ image: CGImage) {
        captureLayer.isHidden = true
        imageLayer.isHidden = false
        imageLayer.contents = image
        lastFrameSize = CGSize(width: image.width, height: image.height)
    }

    func setCaptureSession(_ session: AVCaptureSession?) { captureLayer.session = session }

    var captureVideoRect: CGRect? {
        guard !captureLayer.isHidden else { return nil }
        return captureLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func showCaptureFrame(size: CGSize) {
        captureLayer.isHidden = false
        imageLayer.isHidden = true
        imageLayer.contents = nil
        if lastFrameSize != size {
            downPoint = nil
            dragSamples = []
            resetScroll()
        }
        lastFrameSize = size
    }

    func clearFrame() {
        captureLayer.isHidden = true
        imageLayer.contents = nil
        lastFrameSize = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True while Control is armed. Drives the cursor (a pointing hand signals the
    /// mirror is interactive) so a click while Control is off isn't a silent no-op.
    var controlActive = false {
        didSet {
            guard controlActive != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            let target: Float = controlActive ? 1 : 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = controlRing.presentation()?.opacity ?? controlRing.opacity
            fade.toValue = target
            fade.duration = controlActive ? 0.2 : 0.15
            fade.timingFunction = controlActive ? iMirrorEaseOut : CAMediaTimingFunction(name: .easeIn)
            controlRing.opacity = target
            controlRing.add(fade, forKey: "ringFade")
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

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        if reduceMotion {
            group.animations = [fade]
        } else {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.0
            group.animations = [scale, fade]
        }
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

/// Multi-line label that wraps at its current width. Auto Layout needs the wrap
/// width up front to compute the height, so keep it in sync on every resize.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private var window: NSWindow!
    private let screenshotThumbnail = ScreenshotThumbnail()
    private var previewView: PreviewView!
    private var emptyStateView: NSView!
    private let emptyStateTitle = NSTextField(wrappingLabelWithString: "No iPhone connected")
    private let emptyStateHint = NSTextField(wrappingLabelWithString: "Plug in via USB, unlock, and tap “Trust.”")
    private var statusLabel: NSTextField!

    // Toolbar controls
    private let controlSwitch = NSSwitch()
    private enum ControlMode: String { case wired, wda }
    private var controlMode = ControlMode(rawValue: UserDefaults.standard.string(forKey: "imirror.controlMode") ?? "") ?? .wired
    private let modeCards = ControlModeCards(width: 382)
    private let previewStatusLabel = NSTextField(labelWithString: "")
    private let modeRequirementsLabel = NSTextField(wrappingLabelWithString: "")
    private let wiredSetupButton = NSButton()
    private var settingUpWired = false
    private var wiredSetupError: String?
    private let wiredControl = CoreDeviceControl()
    private var wiredState = CoreDeviceControl.State.unavailable("Checking the USB connection…")
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
    private var simHasBeenReady = false
    private let iosRunnerLabel = NSTextField(labelWithString: "")
    private var lastRunnerInstall: RunnerInstall?
    private let healthButton = NSButton()
    private var screenshotItem: NSToolbarItem!
    private var controlItem: NSToolbarItem!
    private var homeItem: NSToolbarItem!

    private var mjpeg: MJPEGClient?
    private var usbCapture: USBVideoCapture?
    private var hasVideoFrame: Bool { lastFrame != nil || usbCapture?.hasFrame == true }
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
    private let automationCallbacks = MainQueueCallbackScope()
    private let videoCallbacks = MainQueueCallbackScope()
    private var waitingForDevice = false
    private lazy var devicePresence = DevicePresenceMonitor(
        discover: { [weak self] completion in self?.transport.discoverDevicePresence(completion: completion) },
        onChange: { [weak self] presence, reattached in self?.handleDevicePresence(presence, reattached: reattached) })
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
    // Seeded at the point `runwda` actually starts (Transport.onRunwdaStarted
    // — not automation-on, which would also count tunnel bring-up and the
    // runner install against WDA's own boot grace) and, for a mid-session
    // outage after a real prior connection, the moment health first drops to
    // .down (a hung-but-still-running runwda never triggers a fresh spawn,
    // so onRunwdaStarted alone would never catch it). Cleared once health
    // reconnects — see setHealth.
    private var chainRecovery = ChainRecoveryClock()
    /// Set once a full chain restart still hasn't recovered WDA. While set,
    /// runWatchdog stops trying automatically — only the user tapping the WDA
    /// dot (forceProbe) re-arms it. Product decision: no silent background
    /// retries after a confirmed give-up.
    private var wdaHardStopped = false

    // MJPEG partial-wedge watchdog (see nextMjpegRecoveryAction in
    // iMirrorCore): WDA's /status can stay healthy while the MJPEG stream has
    // silently died, so `health == .connected` alone isn't proof frames are
    // still arriving.
    private var videoClock = VideoRecoveryClock()
    private var mjpegBounced = false
    private let mjpegNoFrameThresholdSec: TimeInterval = 20
    /// Counts `.escalate` outcomes for the current connected session, reset
    /// ONLY when a real frame arrives (not on every `setHealth(.connected)`,
    /// which fires on every probe tick once connected). Past 2, a chain
    /// restart clearly isn't bringing the stream back — stop looping and
    /// surface a terminal state instead of restarting forever.
    private var mjpegEscalationCount = 0

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
        // Seed the chain-recovery ladder's clock at the point runwda actually
        // starts, not at automation-on (see the recovery clock comment).
        // Fires on every chain bring-up, including a restartChain() — that's
        // fine, and load-bearing: it must NOT reset the recovery stage, or
        // the ladder would never advance past stage 0 and would never give up.
        transport.onRunwdaStarted = { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.chainRecovery.runwdaStarted(at: now)
            self.videoClock.beginStartup(at: now)
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
                    self.wdaHardStopped = true // make the WDA button retry installation
                    self.setHealth(.down)
                    // Cancel the generic 6s "Starting WebDriverAgent…" text so our
                    // specific, actionable failure message isn't overwritten.
                    self.downStatusWorkItem?.cancel(); self.downStatusWorkItem = nil
                    self.setStatus(self.installFailureMessage(err))
                }
                self.updateHealthDot()
            }
        }
        applyControlMode()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        automationEnabled = false
        wiredControl.reset()
        automationCallbacks.invalidate()
        videoCallbacks.invalidate()
        devicePresence.reset()
        downStatusWorkItem?.cancel()
        downStatusWorkItem = nil
        healthTimer?.invalidate()
        transport.stop()
        mjpeg?.stop()
        usbCapture?.stop()
        simController.shutdown()
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
        window = makeMainWindow()
        window.title = "iMirror"
        window.titleVisibility = .hidden   // free the unified toolbar for the controls
        window.center()
        window.setFrameAutosaveName("iMirrorMain")
        // Stop the window shrinking into a degenerate size that clips the toolbar;
        // the content aspect ratio is locked to the phone once its size is known.
        window.contentMinSize = NSSize(width: 260, height: 200)

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

        statusLabel = WrappingLabel(wrappingLabelWithString: "Looking for iPhone…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.wantsLayer = true   // for the text cross-fade in setStatus
        // Long status lines wrap onto more lines (the HUD grows upward) instead
        // of being cut off; low compression resistance keeps the text from
        // widening the window.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        modeCards.onSelection = { [weak self] mode in self?.controlModeChanged(mode) }

        // Health dot — colored status, click to force a re-check
        healthButton.isBordered = false
        healthButton.bezelStyle = .toolbar
        healthButton.imagePosition = .imageOnly
        healthButton.wantsLayer = true   // for the tint cross-fade + connecting pulse
        healthButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "iPhone control status")
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
        let title = emptyStateTitle
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.isSelectable = false
        title.preferredMaxLayoutWidth = 300

        let hint = emptyStateHint
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
            item.label = "Connection"
            item.toolTip = "iPhone connection status"
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
            item.toolTip = "iPhone mode, scroll speed, and agent settings"
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
        guard hasVideoFrame else {
            setStatus("No frame yet — wait for the mirror to start.")
            return
        }
        let name = "iMirror_\(timestamp()).png"
        let url = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        let capture = usbCapture
        let fallback = lastFrame
        // PNG-encode + write off the main thread: a blocking file write (to a possibly
        // iCloud-synced ~/Pictures) would otherwise hitch the UI on a click that should
        // feel instant. Only the status update hops back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let cgImage = capture?.screenshot() ?? fallback else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async { self.setStatus("Screenshot failed (could not encode PNG).") }
                return
            }
            do {
                try png.write(to: url)
                DispatchQueue.main.async {
                    self.setStatus("Saved \(url.lastPathComponent) → ~/Pictures")
                    self.screenshotThumbnail.show(image: cgImage, fileURL: url, over: self.window)
                }
            } catch {
                DispatchQueue.main.async { self.setStatus("Screenshot save failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Preview input

    private func wireInput() {
        previewView.onTap = { [weak self] viewPoint in
            guard let self, self.controlEnabled, let p = self.devicePoint(fromViewPoint: viewPoint) else { return }
            if let size = self.wiredInputSize {
                self.sendWired([["tap"] + CoreDeviceControl.pointArguments(p, size: size)])
            } else if self.automationEnabled {
                self.wda?.tap(at: p)
            }
            self.previewView.flashTap(at: viewPoint)   // local acknowledgment
        }
        previewView.onDrag = { [weak self] viewPath, flick in
            guard let self, self.controlEnabled else { return }
            let devicePath = downsample(viewPath, max: 24)
                .compactMap { self.devicePoint(fromViewPoint: $0) }
            guard devicePath.count >= 2 else { return }
            self.sendDrag(devicePath, flick: flick)
        }
        previewView.onScroll = { [weak self] viewPoint, viewDelta in
            guard let self, self.controlEnabled,
                  let size = self.inputSize,
                  let start = self.devicePoint(fromViewPoint: viewPoint) else { return }
            guard let frameSize = self.previewView.lastFrameSize else { return }
            let videoRect = self.previewView.captureVideoRect
                ?? self.displayedImageRect(in: self.previewView.bounds, imageSize: frameSize)
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
            self.sendDrag([start, end], flick: true)
        }
        previewView.onType = { [weak self] text in
            guard let self, self.controlEnabled else { return }
            if self.controlMode == .wired {
                self.sendWired(CoreDeviceControl.typing(text))
            } else {
                self.wda?.typeText(text)
            }
        }
    }

    private var wiredInputSize: CGSize? {
        guard controlMode == .wired, mirroring, usbCapture?.hasFrame == true else { return nil }
        return previewView.lastFrameSize
    }

    private var inputSize: CGSize? { controlMode == .wired ? wiredInputSize : wda?.deviceSize }

    private func sendDrag(_ path: [CGPoint], flick: Bool) {
        if let size = wiredInputSize, let first = path.first, let last = path.last {
            let start = CoreDeviceControl.pointArguments(first, size: size)
            let end = CoreDeviceControl.pointArguments(last, size: size)
            sendWired([["swipe"] + start + end + [flick ? "0.18" : "0.3"]])
        } else if automationEnabled {
            wda?.drag(path: path, flick: flick)
        }
    }

    private func sendWired(_ commands: [[String]]) {
        guard let frameSize = wiredInputSize, case .ready(let id) = wiredState else { return }
        wiredControl.send(commands, to: id, frameSize: frameSize) { [weak self] reason in
            guard let self, self.controlMode == .wired else { return }
            self.setWiredState(.unavailable(reason))
            self.probeWired()
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
        guard let size = inputSize, let frameSize = previewView.lastFrameSize else { return nil }
        let videoRect: CGRect
        if let captureRect = previewView.captureVideoRect {
            // USB video can contain padding and non-square pixel metadata. Let
            // AVFoundation account for that instead of comparing encoded pixels
            // to WDA points. Still reject an out-of-date rotation.
            guard (frameSize.width > frameSize.height) == (size.width > size.height) else { return nil }
            videoRect = captureRect
        } else {
            guard displayShapesMatch(frame: frameSize, logical: size) else { return nil }
            videoRect = displayedImageRect(in: previewView.bounds, imageSize: frameSize)
        }
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
        if controlMode == .wired { probeWired(); return }
        if waitingForDevice {
            devicePresence.sampleIfDue(force: true)
            return
        }
        guard wdaHardStopped || (usbCapture?.hasFrame == true && health == .down) else { probeNow(); return }
        wdaHardStopped = false
        chainRecovery.reset()
        chainRecovery.connectionLost(at: ProcessInfo.processInfo.systemUptime)
        mjpegEscalationCount = 0     // give the user's retry its own two-strike allowance
        mjpegBounced = false
        setStatus("Retrying WebDriverAgent…")
        restartWDAChain()
    }

    private func probeNow() {
        guard automationEnabled else { return }   // no WDA to probe when automation is off
        if health == .down || waitingForDevice { devicePresence.sampleIfDue() }
        guard !waitingForDevice else { return }
        guard !installingRunner else { return }   // WDA legitimately down mid-install
        guard !probing else { return }
        // Don't probe mid-gesture: a probe GET contends with the in-flight /actions
        // on WDA's single XCUITest queue and can time out into a false .down.
        // gestureInFlight is set/cleared only on DispatchQueue.main — main-thread safe.
        if wda?.isGestureInFlight == true { return }
        probing = true
        wda?.probe(completion: automationCallbacks.delivering { [weak self] result in
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
        })
    }

    /// Rearm only after USB discovery has actually observed a detach and a
    /// later attach. A still-present phone that exhausts recovery stays stopped.
    private func handleDevicePresence(_ presence: DevicePresence, reattached: Bool) {
        guard automationEnabled, health != .connected else { return }
        switch presence {
        case .absent:
            if !waitingForDevice {
                automationCallbacks.invalidate()
                probing = false
                creatingSession = false
                installingRunner = false
                transport.stopChain()
                chainRecovery.reset()
                hadSuccessfulConnection = false
                wdaHardStopped = false
                wda = WDAClient()
                waitingForDevice = true
                setHealth(.down)
            }
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            emptyStateTitle.stringValue = "No iPhone connected"
            emptyStateHint.stringValue = "Plug in via USB, unlock, and tap “Trust.”"
            setStatus("Waiting for iPhone. Plug in via USB and unlock it.")
        case .present:
            guard reattached else { return }
            waitingForDevice = false
            videoClock.beginStartup(at: ProcessInfo.processInfo.systemUptime)
            automationCallbacks.invalidate()
            probing = false
            creatingSession = false
            installingRunner = false
            wda = WDAClient()
            wdaHardStopped = false
            chainRecovery.reset()
            hadSuccessfulConnection = false
            mjpegEscalationCount = 0
            mjpegBounced = false
            emptyStateTitle.stringValue = "Connecting to iPhone"
            emptyStateHint.stringValue = "Unlock your iPhone and tap Trust if prompted."
            setStatus("iPhone connected. Starting WebDriverAgent…")
            // The launch callback starts the boot clock once preparation ends.
            restartWDAChain()
            probeNow()
        case .unavailable:
            if waitingForDevice {
                setStatus("Waiting for iPhone. Connection check unavailable; retrying automatically.")
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
        // Restarting a healthy video service because XCTest is busy interrupts
        // the mirror and the foreground app's debugging session.
        let now = ProcessInfo.processInfo.systemUptime
        if usbCapture?.hasFrame != true, mirroring,
           videoClock.hasFreshFrame(at: now, threshold: mjpegNoFrameThresholdSec) { return }
        switch chainRecovery.action(at: now, postConnectionOutage: hadSuccessfulConnection) {
        case .wait:
            break
        case .restartChain:
            // Preparation gets a fresh budget immediately. WDA launch will
            // reseed its boot budget without resetting the ladder's stage.
            chainRecovery.beginRestart(at: now)
            setStatus("WebDriverAgent is taking longer than usual, resetting the connection…")
            restartWDAChain()
        case .giveUp:
            wdaHardStopped = true
            // F1: stop the chain outright — otherwise runwda keeps
            // respawning (and getting SIGKILLed by its own readiness
            // deadline) forever after a "give up," which defeats the point.
            // The relay stays up, so forceProbe()'s restartChain() re-arm
            // below still works.
            transport.stopChain()
            setStatus("WebDriverAgent won't start. Tap WDA to retry.")
        }
    }

    /// MJPEG partial-wedge watchdog: WDA's HTTP session can be perfectly
    /// healthy while the video stream underneath it has silently died, so a
    /// green dot with no picture needs its own check. Cheapest fix first
    /// (bounce just the `forward` child carrying the MJPEG port); only
    /// escalate to a full chain restart if that didn't bring frames back.
    private func checkMjpegWatchdog() {
        guard automationEnabled, !waitingForDevice, mjpeg != nil,
              let noFrameFor = videoClock.noFrameDuration(at: ProcessInfo.processInfo.systemUptime,
                                                         controlConnected: health == .connected) else { return }
        // With an external WDA (canSelfManage == false) there's no chain to
        // bounce or restart — bouncing/escalating would be a no-op at best
        // and a misleading status flash at worst. Once hard-stopped, this
        // watchdog goes quiet too until the user retries via forceProbe().
        guard transport.canSelfManage, !wdaHardStopped else { return }
        switch nextMjpegRecoveryAction(noFrameForSec: noFrameFor, alreadyBounced: mjpegBounced, thresholdSec: mjpegNoFrameThresholdSec) {
        case .wait:
            break
        case .bounceForward:
            mjpegBounced = true
            NSLog("iMirror: no MJPEG frames for \(Int(noFrameFor))s — bouncing the MJPEG forward")
            transport.bounceMJPEGForward()
        case .escalate:
            mjpegEscalationCount += 1
            if mjpegEscalationCount >= 2 {
                // Two escalations with no real frame delivered in between:
                // restarting the chain clearly isn't fixing this. Stop
                // looping and surface a terminal state, same as the
                // chain-recovery ladder's own give-up.
                NSLog("iMirror: MJPEG still stalled after \(mjpegEscalationCount) chain restarts — giving up")
                wdaHardStopped = true
                transport.stopChain()
                setStatus("No video from WebDriverAgent. Tap WDA to retry.")
                return
            }
            NSLog("iMirror: MJPEG still stalled after a forward bounce — escalating to a chain restart")
            // Restart the no-frame clock so this doesn't fire again on the next
            // tick before health actually flips to .down (which is what really
            // resets this state, below).
            mjpegBounced = false
            setStatus("Video stalled — resetting the connection…")
            chainRecovery.beginRestart(at: ProcessInfo.processInfo.systemUptime)
            restartWDAChain()
        }
    }

    private func restartWDAChain() {
        videoClock.beginStartup(at: ProcessInfo.processInfo.systemUptime)
        mjpegBounced = false
        transport.restartChain()
    }

    /// Video uses WDA's independent MJPEG service, not its XCTest session.
    /// A foreground app can block window-size and input requests while video
    /// keeps flowing, so control health must never tear down this stream.
    private func startVideo() {
        guard usbCapture == nil else { return }
        if automationEnabled, ProcessInfo.processInfo.environment["IMIRROR_VIDEO_MODE"] == "mjpeg" {
            startMJPEGVideo()
            return
        }
        let capture = USBVideoCapture(wdaFallback: automationEnabled)
        usbCapture = capture
        previewView.setCaptureSession(capture.session)
        let deliverUSB = videoCallbacks.deliveringLatest { [weak self] (update: USBVideoUpdate) in
            guard let self else { return }
            guard case .frame(let size) = update else {
                guard case .unavailable(let reason) = update else { return }
                self.previewView.clearFrame()
                self.mirroring = false
                self.screenshotItem?.isEnabled = false
                self.updateRunnerStatusLabel()
                if self.controlMode == .wired {
                    self.wiredControl.reset()
                    self.setWiredState(.unavailable(reason))
                    self.emptyStateTitle.stringValue = "Waiting for USB video"
                    self.emptyStateHint.stringValue = reason
                    self.setEmptyState(hidden: false)
                } else {
                    self.setStatus(reason)
                    self.startMJPEGVideo()
                }
                return
            }
            self.videoClock.receivedFrame(at: ProcessInfo.processInfo.systemUptime)
            self.mjpeg?.stop()
            self.mjpeg = nil
            self.lastFrame = nil
            let previous = self.previewView.lastFrameSize
            self.previewView.showCaptureFrame(size: size)
            self.screenshotItem?.isEnabled = true
            if !self.mirroring { self.updateRunnerStatusLabel() }
            self.mjpegEscalationCount = 0
            if previous != size {
                self.wda?.refreshDisplayGeometry()
                adaptPreviewWindow(self.window, to: size)
            }
            if !self.mirroring {
                self.mirroring = true
                self.setEmptyState(hidden: true)
                self.updateHealthDot()
                if self.controlMode == .wired {
                    self.probeWired()
                } else {
                    self.setStatus("Mirroring via USB video — phone stays usable.")
                }
            }
        }
        capture.onFrame = { deliverUSB(.frame($0)) }
        capture.onUnavailable = { deliverUSB(.unavailable($0)) }
        capture.start()
        startMJPEGVideo() // keeps a preview available during USB discovery
    }

    private func startMJPEGVideo() {
        guard automationEnabled, mjpeg == nil else { return }
        // Host port 9110 forwards to the device's fixed WDA mjpegServerPort 9100, chosen to avoid colliding with other local services that commonly use 9100.
        let client = MJPEGClient(port: 9110)
        let deliverVideo = videoCallbacks.deliveringLatest { [weak self] (cg: CGImage?) in
            guard let self else { return }
            guard self.usbCapture?.hasFrame != true else { return }
            guard let cg else {
                self.mirroring = false
                self.updateHealthDot()
                self.lastFrame = nil
                self.previewView.clearFrame()
                self.updateRunnerStatusLabel()
                self.screenshotItem?.isEnabled = false
                self.setEmptyState(hidden: false)
                // Keep installation progress and errors visible during retries.
                if self.installingRunner { return }
                if case .failed = self.lastRunnerInstall { return }
                self.setStatus("Waiting for video from iPhone…")
                return
            }
            self.videoClock.receivedFrame(at: ProcessInfo.processInfo.systemUptime)
            // A real frame arrived — the stream is actually
            // delivering, so any earlier escalations no longer
            // count toward the two-strike give-up.
            self.mjpegEscalationCount = 0
            self.chainRecovery.reset()
            let wasMirroring = self.mirroring
            self.lastFrame = cg
            if !wasMirroring { self.updateRunnerStatusLabel() }
            self.screenshotItem?.isEnabled = true
            let previousSize = self.previewView.lastFrameSize
            self.previewView.setFrame(cg)
            // Frame dimensions establish the preview's aspect ratio even when
            // XCTest cannot obtain a logical window size. Never use pixels as
            // touch coordinates; control still requires WDA's point dimensions.
            let aspect = NSSize(width: cg.width, height: cg.height)
            if previousSize != aspect {
                self.wda?.refreshDisplayGeometry()
                adaptPreviewWindow(self.window, to: aspect)
            }
            if !self.mirroring {
                self.mirroring = true
                self.setEmptyState(hidden: true)
                self.updateHealthDot()
                self.setStatus("Mirroring — phone stays usable.")
            }
        }
        // Frames and disconnects share one slot so a queued old disconnect can
        // never clear a newer frame after the UI thread catches up.
        client.onFrame = { deliverVideo($0) }
        client.onStateChange = { connected in if !connected { deliverVideo(nil) } }
        mjpeg = client
        // Seed the no-frame clock at start so the watchdog measures
        // from "stream just opened," not from a nil baseline that
        // would otherwise read as an already-ancient last frame.
        videoClock.beginStartup(at: ProcessInfo.processInfo.systemUptime)
        mjpegBounced = false
        client.start()
    }

    private func createSession() {
        guard !creatingSession else { return }
        creatingSession = true
        setHealth(.connecting)
        wda?.connect(completion: automationCallbacks.delivering { [weak self] result in
            guard let self else { return }
            self.creatingSession = false
            if case .success = result { self.setHealth(.connected) }
            else {
                self.setHealth(.down)
                // /status can answer while XCTest session commands are stuck.
                // Run recovery here: the next probe can start another session
                // and change health to .connecting before its watchdog runs.
                self.runWatchdog()
            }
        })
    }

    private var downStatusWorkItem: DispatchWorkItem?
    private var hadSuccessfulConnection = false

    private func setHealth(_ new: Health) {
        let changed = (new != health)
        health = new
        updateHealthDot()                       // dot colour is always instant
        updateRunnerStatusLabel()

        switch new {
        case .connected:
            if changed, !videoClock.hasReceivedFrame {
                videoClock.beginStartup(at: ProcessInfo.processInfo.systemUptime)
            }
            devicePresence.markConnected()
            waitingForDevice = false
            downSince = nil
            // Back to healthy — clear the chain-recovery ladder so the next
            // outage (if any) starts a fresh stage-0 grace window instead of
            // inheriting whatever was left over from this one.
            chainRecovery.reset()
            wdaHardStopped = false
            hadSuccessfulConnection = true
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            controlSwitch.isEnabled = true
            homeItem?.isEnabled = true
            screenshotItem?.isEnabled = hasVideoFrame
            if changed {
                let s = wda?.deviceSize ?? .zero
                // Video is authoritative for preview shape. WDA supplies points
                // for input and can lag behind a rotation or display change.
                if !mirroring {
                    setStatus("WDA connected — \(Int(s.width))×\(Int(s.height)) pts. Flip Control to drive.")
                }
            }
            startVideo()
        case .connecting:
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            if changed, !mirroring { setStatus("Connecting to WDA…") }
        case .down:
            if downSince == nil { downSince = Date() }
            // Seed the ladder's monotonic clock right here ONLY for a
            // mid-session wedge after a real prior connection: a
            // hung-but-still-running runwda never exits, so it never
            // triggers a fresh spawn and Transport.onRunwdaStarted would
            // never fire to seed the clock on its own. During initial boot
            // (no prior connection yet), leave it nil and let
            // onRunwdaStarted seed it once runwda actually starts — seeding
            // it here too would count tunnel/install time against WDA's own
            // boot grace, which is exactly what onRunwdaStarted exists to
            // avoid.
            if hadSuccessfulConnection {
                chainRecovery.connectionLost(at: ProcessInfo.processInfo.systemUptime)
            }
            // Lost the connection — disarm control so stray clicks can't fire.
            if controlEnabled {
                controlEnabled = false
                controlSwitch.state = .off
                previewView.controlActive = false
                previewView.resetScroll()
            }
            controlSwitch.isEnabled = false
            homeItem?.isEnabled = false
            // Control failure does not imply video failure. The stream's own
            // disconnect callback clears the preview when video actually drops.
            screenshotItem?.isEnabled = hasVideoFrame
            if !mirroring { setEmptyState(hidden: false) }
            if !waitingForDevice {
                emptyStateTitle.stringValue = "Connecting to iPhone"
                emptyStateHint.stringValue = "Unlock your iPhone and tap Trust if prompted."
            }
            // Debounce the *status text* by 6s: a brief probe blip during heavy
            // scrolling flips health to .down for one cycle, and flashing
            // "Starting WebDriverAgent…" on every scroll is alarming and wrong.
            // The red dot already shows instantly above; only the text waits.
            if changed {
                downStatusWorkItem?.cancel()
                let canManage = transport.canSelfManage
                let reconnecting = hadSuccessfulConnection
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.health == .down, !self.mirroring else { return }
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
        if controlMode == .wired {
            let detail: String
            switch wiredState {
            case .unavailable(let reason): detail = reason
            case .ready: detail = wiredReady ? "Wired Control ready" : "Waiting for the USB screen"
            }
            setHealthDot(wiredReady ? .systemGreen : .systemGray, tip: detail, a11y: detail, pulsing: false)
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
            if mirroring {
                setHealthDot(.systemYellow, tip: "Video connected. Controls unavailable. Click to re-check.",
                             a11y: "mirroring, controls unavailable", pulsing: false)
            } else {
                setHealthDot(.systemRed, tip: "WDA unreachable — click to re-check",
                             a11y: "unreachable", pulsing: false)
            }
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
        if pulsing && reduceMotion {
            // No looping pulse: hold a dimmed dot so "in progress" still reads.
            healthButton.layer?.removeAnimation(forKey: key)
            healthButton.alphaValue = 0.6
        } else if pulsing {
            healthButton.alphaValue = 1.0
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
            healthButton.alphaValue = 1.0
        }
    }

    @objc private func toggleControl() {
        // Only allow arming control when actually connected.
        guard controlMode == .wired ? wiredReady : health == .connected else {
            controlSwitch.state = .off
            controlEnabled = false
            previewView.controlActive = false
            setStatus("Control is unavailable. Check the iPhone connection status.")
            return
        }
        controlEnabled = (controlSwitch.state == .on)
        previewView.controlActive = controlEnabled
        if !controlEnabled { previewView.resetScroll() }
        setStatus(controlEnabled
            ? "Control ON — clicks/keys drive the phone."
            : "Control off — mirror only.")
    }

    private func controlModeChanged(_ mode: ControlModeCards.Mode) {
        let selected: ControlMode = mode == .webDriverAgent ? .wda : .wired
        guard selected != controlMode else { return }
        controlMode = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "imirror.controlMode")
        applyControlMode()
    }

    private func disarmControl() {
        controlEnabled = false
        controlSwitch.state = .off
        controlSwitch.isEnabled = false
        previewView.controlActive = false
        previewView.resetScroll()
        homeItem?.isEnabled = false
    }

    private func applyControlMode() {
        modeCards.showSelection(controlMode == .wired ? .directUSB : .webDriverAgent)
        modeRequirementsLabel.stringValue = controlMode == .wired
            ? "For Mac control, use macOS 27, Xcode 27, and iOS 27 or later. Connect by USB, unlock and trust the Mac, then enable Developer Mode on the iPhone."
            : "Use a runner signed for this iPhone. iMirror starts it automatically and can install a compatible bundled runner. iOS may show an Automation Running overlay."
        automationCallbacks.invalidate()
        wiredControl.reset()
        disarmControl()
        healthTimer?.invalidate()
        healthTimer = nil
        devicePresence.reset()
        waitingForDevice = false
        hadSuccessfulConnection = false
        probing = false
        creatingSession = false
        installingRunner = false
        downStatusWorkItem?.cancel()
        downStatusWorkItem = nil
        health = .down
        downSince = nil
        wda = nil
        automationEnabled = controlMode == .wda
        usbCapture?.setWDAFallback(automationEnabled)
        chainRecovery.reset()
        wdaHardStopped = false
        videoClock.clear()
        mjpegBounced = false
        mjpegEscalationCount = 0

        if automationEnabled {
            if ProcessInfo.processInfo.environment["IMIRROR_VIDEO_MODE"] == "mjpeg", let capture = usbCapture {
                videoCallbacks.invalidate()
                capture.stop()
                usbCapture = nil
                previewView.setCaptureSession(nil)
                previewView.clearFrame()
                screenshotItem?.isEnabled = false
                mirroring = false
            }
            setStatus("Starting WebDriverAgent… iOS may show an Automation Running overlay.")
            transport.start()
            startVideo()
            if usbCapture?.hasFrame != true { startMJPEGVideo() }
            startHealthMonitor()
        } else {
            transport.stop()
            mjpeg?.stop()
            mjpeg = nil
            lastFrame = nil
            if usbCapture?.hasFrame != true {
                previewView.clearFrame()
                mirroring = false
                screenshotItem?.isEnabled = false
                emptyStateTitle.stringValue = "Waiting for USB video"
                emptyStateHint.stringValue = "Plug in one iPhone, unlock it, and tap Trust."
                setEmptyState(hidden: false)
            }
            setWiredState(.unavailable("Checking Wired Control…"))
            startVideo()
            probeWired()
            let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.probeWired() }
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        }
        updateRunnerStatusLabel()
        updateHealthDot()
        updateWiredSetupButton()
    }

    private func probeWired() {
        guard controlMode == .wired, !settingUpWired else { return }
        wiredControl.probe { [weak self] state in
            guard let self, self.controlMode == .wired, !self.settingUpWired else { return }
            let next = self.wiredSetupError.map(CoreDeviceControl.State.unavailable) ?? state
            if next != self.wiredState || self.controlSwitch.isEnabled != self.wiredReady {
                self.setWiredState(next)
            }
        }
    }

    private var wiredReady: Bool {
        guard case .ready = wiredState else { return false }
        return wiredInputSize != nil
    }

    private func setWiredState(_ state: CoreDeviceControl.State) {
        if state != wiredState {
            if case .ready = wiredState { wiredControl.reset() }
            disarmControl()
        }
        wiredState = state
        controlSwitch.isEnabled = wiredReady
        homeItem?.isEnabled = wiredReady
        updateHealthDot()
        updateRunnerStatusLabel()
        updateWiredSetupButton()
        switch state {
        case .unavailable(let reason): setStatus(reason)
        case .ready:
            setStatus(wiredReady ? "Wired Control ready. Turn on Control to drive the iPhone."
                                 : "Wired input ready. Waiting for the USB screen.")
        }
    }

    @objc private func setUpWiredControl() {
        guard !settingUpWired, controlMode == .wired else { return }
        settingUpWired = true
        wiredSetupError = nil
        updateWiredSetupButton()
        setStatus("Downloading and building the Wired Control bridge…")
        CoreDeviceControl.setup { [weak self] error in
            guard let self else { return }
            self.settingUpWired = false
            self.wiredSetupError = error
            self.updateWiredSetupButton()
            guard self.controlMode == .wired else { return }
            if let error { self.setWiredState(.unavailable(error)) }
            else { self.probeWired() }
        }
    }

    private func updateWiredSetupButton() {
        wiredSetupButton.isHidden = controlMode != .wired || !CoreDeviceControl.supported
            || CoreDeviceControl.executable != nil
        wiredSetupButton.isEnabled = !settingUpWired
        wiredSetupButton.title = settingUpWired ? "Setting Up…" : "Set Up Wired Control"
    }

    /// Drive the Control switch from its overflow-menu form (custom-view toolbar
    /// items are non-interactive in the narrow-window `»` menu on their own).
    @objc private func toggleControlFromMenu() {
        controlSwitch.state = (controlSwitch.state == .on) ? .off : .on
        toggleControl()
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(takeScreenshot) { return hasVideoFrame }
        if item.action == #selector(pressHome) { return controlMode == .wired ? wiredReady : health == .connected }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(takeScreenshot) { return hasVideoFrame }
        if menuItem.action == #selector(pressHome) { return controlMode == .wired ? wiredReady : health == .connected }
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
        let panelWidth: CGFloat = 430
        let columnWidth: CGFloat = 382
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "iPhone mode")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(labelWithString: "Choose how iMirror connects and controls your iPhone.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(modeCards)

        for label in [previewStatusLabel, iosRunnerLabel, modeRequirementsLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.usesSingleLineMode = false
            label.cell?.wraps = true
            label.preferredMaxLayoutWidth = columnWidth
        }
        let details = NSStackView(views: [previewStatusView(width: columnWidth), iosRunnerLabel, modeRequirementsLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 5
        stack.addArrangedSubview(details)

        wiredSetupButton.bezelStyle = .rounded
        wiredSetupButton.target = self
        wiredSetupButton.action = #selector(setUpWiredControl)
        wiredSetupButton.toolTip = "Downloads and builds the pinned ipb bridge. Requires internet on first setup."
        stack.addArrangedSubview(wiredSetupButton)
        updateWiredSetupButton()
        updateRunnerStatusLabel()

        let scrollRow = NSStackView()
        scrollRow.orientation = .horizontal
        scrollRow.spacing = 8
        scrollRow.addArrangedSubview(NSTextField(labelWithString: "Scroll speed"))
        let slider = NSSlider(value: UserDefaults.standard.object(forKey: "imirror.scrollGain") as? Double ?? 3.5,
                              minValue: 0.5, maxValue: 6.0, target: self, action: #selector(scrollGainChanged(_:)))
        slider.setAccessibilityLabel("Scroll speed")
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        scrollRow.addArrangedSubview(slider)
        stack.addArrangedSubview(scrollRow)

        // MCP server section — one-click register with Claude Code / Claude Desktop.
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        stack.addArrangedSubview(sep)

        let mcpTitle = NSTextField(labelWithString: "MCP server (AI control)")
        mcpTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(mcpTitle)

        let mcpCap = NSTextField(wrappingLabelWithString:
            "Register iMirror’s WebDriverAgent tools with Codex, Claude Code, and Claude Desktop. Select WebDriverAgent to use these tools.")
        mcpCap.font = .systemFont(ofSize: 11)
        mcpCap.textColor = .secondaryLabelColor
        mcpCap.preferredMaxLayoutWidth = columnWidth
        stack.addArrangedSubview(mcpCap)

        for v in deviceMCP.views() { stack.addArrangedSubview(v) }
        deviceMCP.refresh(updateLabel: true)

        // iOS Simulator section — pick a sim, bring up WDA on :8201, install imirror-sim.
        let simSep = NSBox(); simSep.boxType = .separator
        simSep.translatesAutoresizingMaskIntoConstraints = false
        simSep.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        stack.addArrangedSubview(simSep)

        let simTitle = NSTextField(labelWithString: "iOS Simulator")
        simTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(simTitle)

        let simCap = NSTextField(wrappingLabelWithString:
            "Boot a Simulator and drive it from an AI agent. Enable starts WebDriverAgent "
          + "on it (port 8201); view the sim in Apple's Simulator app. Requires Xcode.")
        simCap.font = .systemFont(ofSize: 11)
        simCap.textColor = .secondaryLabelColor
        simCap.preferredMaxLayoutWidth = columnWidth
        stack.addArrangedSubview(simCap)

        simPicker.target = self
        simPicker.action = #selector(simPicked)
        // Fixed to the column width so a long sim name truncates instead of
        // widening the popup past the popover's side margins.
        simPicker.translatesAutoresizingMaskIntoConstraints = false
        simPicker.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        (simPicker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(simPicker)

        simEnableButton.bezelStyle = .rounded
        simEnableButton.title = "Enable"
        simEnableButton.target = self
        simEnableButton.action = #selector(toggleSimEnable)
        stack.addArrangedSubview(simEnableButton)

        simStatusLabel.font = .systemFont(ofSize: 11)
        simStatusLabel.textColor = .secondaryLabelColor
        simStatusLabel.preferredMaxLayoutWidth = columnWidth
        simStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(simStatusLabel)

        for v in simMCP.views() { stack.addArrangedSubview(v) }

        simController.onState = { [weak self] state in self?.renderSimState(state) }
        refreshSimulators()
        simMCP.refresh(updateLabel: true)

        // Version footer.
        let verSep = NSBox(); verSep.boxType = .separator
        verSep.translatesAutoresizingMaskIntoConstraints = false
        verSep.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        stack.addArrangedSubview(verSep)

        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "iMirror \(ver) (build \(build))")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = scroll
        vc.preferredContentSize = NSSize(width: panelWidth, height: min(670, (window.screen?.visibleFrame.height ?? 850) - 90))
        settingsPopover.contentViewController = vc
        settingsPopover.behavior = .transient
    }

    private func previewStatusView(width: CGFloat) -> NSView {
        guard #available(macOS 26, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            return previewStatusLabel
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.style = .regular
        let content = NSView()
        glass.contentView = content
        previewStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewStatusLabel)
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: width),
            glass.heightAnchor.constraint(equalToConstant: 32),
            previewStatusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            previewStatusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return glass
    }

    @objc private func scrollGainChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "imirror.scrollGain")
    }

    /// Reflect whether the WebDriverAgent runner is on the connected iPhone. A live
    /// WDA connection is proof it's installed and running; otherwise fall back to
    /// the last install outcome, or a prompt to turn Automation on.
    private func updateRunnerStatusLabel() {
        previewStatusLabel.stringValue = hasVideoFrame ? (usbCapture?.hasFrame == true
            ? "Preview: live over USB" : "Preview: live via WebDriverAgent") : "Preview: waiting for video"
        if controlMode == .wired {
            switch wiredState {
            case .unavailable(let reason): iosRunnerLabel.stringValue = "Control: " + reason
            case .ready:
                iosRunnerLabel.stringValue = wiredReady
                    ? "Control: ready. Composed characters use paste and replace the iPhone clipboard."
                    : "Control: waiting for the USB preview."
            }
            return
        }
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
                    : "WebDriverAgent app: select WebDriverAgent to check or install"
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
                self.simPicker.isEnabled = hasXcode && !self.simEnabled
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
            simHasBeenReady = false
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Off."
        case .booting:
            simHasBeenReady = false
            simEnabled = true; simEnableButton.title = "Disable"; simStatusLabel.stringValue = "Booting simulator…"
        case .building: simStatusLabel.stringValue = "Building WebDriverAgent (first run ~2–3 min)…"
        case .starting:
            simStatusLabel.stringValue = simHasBeenReady ? "Reconnecting to simulator…" : "Starting WebDriverAgent…"
        case .ready:
            simHasBeenReady = true
            simStatusLabel.stringValue = "WebDriverAgent ready on :8201 ✓"
        case .failed(let m):
            simHasBeenReady = false
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Failed: \(m)"
        }
        simPicker.isEnabled = !simEnabled && simEnableButton.isEnabled
    }

    @objc private func pressHome() {
        if controlMode == .wired { sendWired([["home"]]) }
        else { wda?.home() }
    }

    // MARK: Helpers

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func setStatus(_ text: String) {
        NSLog("iMirror: \(text)")
        guard statusLabel.stringValue != text else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        statusLabel.layer?.add(fade, forKey: "statusText")
        statusLabel.stringValue = text
        // The HUD grows or shrinks with the wrapped text; animate that height change.
        guard let content = window.contentView else { return }
        if reduceMotion {
            content.layoutSubtreeIfNeeded()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = iMirrorEaseOut
                ctx.allowsImplicitAnimation = true
                content.layoutSubtreeIfNeeded()
            }
        }
    }

    /// Actionable, per-cause message for a failed runner install.
    private func installFailureMessage(_ err: RunnerInstallError) -> String {
        switch err {
        case .notProvisioned:
            return "Couldn’t install WebDriverAgent — it isn’t signed for this iPhone. "
                 + "Re-sign it for this device, then select WebDriverAgent again: "
                 + "WDA_DESTINATION=<your-udid> ./scripts/build-wda.sh"
        case .deviceLocked:
            return "Couldn’t install WebDriverAgent — unlock your iPhone, then turn "
                 + "the status indicator to retry."
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
