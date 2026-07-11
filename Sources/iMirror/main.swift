// iMirror — mirror a USB-connected iPhone to a macOS window, record to mp4, take
// screenshots, and (Phase 2) control it from the Mac via WebDriverAgent — while
// the phone stays physically usable (unlike Apple's "iPhone Mirroring").
//
// Dependency-free: AppKit + AVFoundation + CoreImage + CoreMediaIO + Foundation.
//
// UI: a native unified NSToolbar (Liquid Glass on macOS 26) with SF Symbol
// controls and an NSSwitch for control; status shown in the window subtitle.
//
// SECURITY: control talks to WDA over loopback only (no auth on WDA's wire), and
// is OFF by default — you must explicitly connect and flip the Control switch.

import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import iMirrorCore

// MARK: - Enable CoreMediaIO screen-capture (DAL) devices

func enableScreenCaptureDevices() {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    let result = CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &allow)
    if result != kCMIOHardwareNoError {
        NSLog("iMirror: failed to enable screen-capture devices (status \(result))")
    }
}

// MARK: - Preview view (hosts preview layer + captures mouse/keyboard)

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

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
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

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
        previewLayer.addSublayer(ripple)

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

// MARK: - Frame grabber (keeps the latest decoded frame for screenshots)

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "imirror.frames")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; lastFrameAt = Date(); lock.unlock()   // holds one frame; pool keeps the rest
    }

    func snapshot() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return latest
    }

    /// Reset the liveness clock — call when (re)binding a device so the frame
    /// watchdog gives a fresh grace window instead of firing on the stale gap.
    func markActive() { lock.lock(); lastFrameAt = Date(); lock.unlock() }

    /// Seconds since the last delivered frame (or last markActive). The capture
    /// watchdog uses this to detect a silently stalled stream (green WDA, black
    /// mirror) that fires no runtime-error or disconnect notification.
    var secondsSinceLastFrame: TimeInterval {
        lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastFrameAt)
    }
}

// MARK: - Toolbar item identifiers

private extension NSToolbarItem.Identifier {
    static let device     = NSToolbarItem.Identifier("device")
    static let record     = NSToolbarItem.Identifier("record")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let audio      = NSToolbarItem.Identifier("audio")
    static let health     = NSToolbarItem.Identifier("health")
    static let control    = NSToolbarItem.Identifier("control")
    static let settings   = NSToolbarItem.Identifier("settings")
    static let home       = NSToolbarItem.Identifier("home")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate,
                         AVCaptureFileOutputRecordingDelegate {
    private var window: NSWindow!
    private var previewView: PreviewView!
    private var emptyStateView: NSView!
    private var emptyStateTitle: NSTextField!
    private var emptyStateHint: NSTextField!
    private let cameraActionButton = NSButton()
    private var statusLabel: NSTextField!

    // Toolbar controls
    private let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let controlSwitch = NSSwitch()
    private let automationSwitch = NSSwitch()
    private let settingsButton = NSButton()
    private let settingsPopover = NSPopover()
    private var settingsBuilt = false
    private let mcpButton = NSButton()
    private let mcpUninstallButton = NSButton()
    private let mcpSpinner = NSProgressIndicator()
    private let mcpStatusLabel = NSTextField(labelWithString: "")
    private let simController = SimulatorController()
    private var simDevices: [SimDevice] = []
    private let simPicker = NSPopUpButton()
    private let simEnableButton = NSButton()
    private let simStatusLabel = NSTextField(labelWithString: "")
    private let mcpSimButton = NSButton()
    private let mcpSimUninstallButton = NSButton()
    private let mcpSimSpinner = NSProgressIndicator()
    private let mcpSimStatusLabel = NSTextField(labelWithString: "")
    private var mcpSimInstalled = false
    private var simEnabled = false
    private let iosRunnerLabel = NSTextField(labelWithString: "")
    private var lastRunnerInstall: RunnerInstall?
    private var mcpInstalled = false
    private let healthButton = NSButton()
    private var recordItem: NSToolbarItem!
    private var screenshotItem: NSToolbarItem!
    private var audioItem: NSToolbarItem!
    private var controlItem: NSToolbarItem!
    private var homeItem: NSToolbarItem!

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private var audioOn = false                 // muted by default (avoid echo with the phone)
    private let frameGrabber = FrameGrabber()
    private let ciContext = CIContext()
    private var currentInput: AVCaptureDeviceInput?

    private var discovery: AVCaptureDevice.DiscoverySession!
    private var devices: [AVCaptureDevice] = []

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
    private var lastWDARestart: Date?

    // Capture-pipe recovery (separate from WDA: the mirror is a CoreMediaIO/AVFoundation
    // stream that can stall on USB churn without disconnecting the device, leaving a
    // green WDA dot over a black screen).
    private var captureWatchdogTimer: Timer?
    private var lastCaptureRecovery: Date?

    // True while the window shows any pixels. When it's fully hidden (miniaturized
    // or occluded) we pause the screenshot frame-grabber and the capture watchdog
    // so a hidden window costs no continuous decode/probe work.
    private var appVisible = true

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableScreenCaptureDevices()
        buildMainMenu()
        buildWindow()
        requestCameraAccessThenStart()
        observeDeviceChanges()
        // Automation (WebDriverAgent) is OFF by default: opening the app is pure
        // view-only mirroring, so nothing runs on the phone and iOS shows no
        // "Automation Running" overlay. Flip the Automation toggle to bring WDA up.
        startCaptureWatchdog()
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
        // Restore the last Automation choice (default off = view-only mirroring).
        if UserDefaults.standard.bool(forKey: "imirror.automationEnabled") {
            automationSwitch.state = .on
            setAutomation(true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        captureWatchdogTimer?.invalidate()
        transport.stop()
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
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
        let rec = ctrlMenu.addItem(withTitle: "Record", action: #selector(toggleRecord), keyEquivalent: "r")
        rec.target = self
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
        previewView.previewLayer.session = session
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

        // Device picker styling
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceSelected)
        devicePopUp.controlSize = .large
        devicePopUp.bezelStyle = .toolbar

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
        emptyStateTitle = title

        let hint = NSTextField(wrappingLabelWithString: "Plug in via USB, unlock, and tap “Trust.”")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = 300
        emptyStateHint = hint

        // Actionable button, shown only for the camera-permission empty state.
        cameraActionButton.bezelStyle = .rounded
        cameraActionButton.title = "Allow Camera Access"
        cameraActionButton.target = self
        cameraActionButton.action = #selector(cameraActionTapped)
        cameraActionButton.isHidden = true

        let stack = NSStackView(views: [icon, title, hint, cameraActionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(14, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true                    // layer-backed so alphaValue animates
        return stack
    }

    /// Tapped from the camera-permission empty state. If access was never decided,
    /// this triggers the system prompt (accept/decline). Once the user has denied,
    /// macOS won't show that prompt again, so open the Camera privacy pane instead.
    @objc private func cameraActionTapped() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.cameraActionButton.isHidden = true
                        self?.setStatus("Camera access granted.")
                        self?.configureSession()
                    } else {
                        self?.showCameraDenied()
                    }
                }
            }
        default:  // denied / restricted — the system prompt can't be reshown
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
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

    /// Update the empty-state copy to match the real reason there's no mirror, so
    /// a permission failure doesn't show the generic "plug in via USB" guidance.
    private func setEmptyStateReason(title: String, hint: String) {
        emptyStateTitle?.stringValue = title
        emptyStateHint?.stringValue = hint
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
        [.device, .record, .screenshot, .audio, .flexibleSpace, .health, .control, .settings, .home]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.device, .record, .screenshot, .audio, .health, .control, .settings, .home, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .device:
            let item = NSToolbarItem(itemIdentifier: .device)
            item.label = "Device"
            item.view = devicePopUp
            return item

        case .record:
            recordItem = actionItem(.record, "Record", "record.circle",
                                    #selector(toggleRecord), enabled: false)
            return recordItem

        case .screenshot:
            screenshotItem = actionItem(.screenshot, "Screenshot", "camera.viewfinder",
                                        #selector(takeScreenshot), enabled: false)
            return screenshotItem

        case .audio:
            audioItem = actionItem(.audio, "Sound", "speaker.slash.fill",
                                   #selector(toggleAudio), enabled: false)
            return audioItem

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

    // MARK: Permissions + session start

    private func requestCameraAccessThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureSession() }
                    else { self?.showCameraDenied() }
                }
            }
        default:
            showCameraDenied()
        }
    }

    /// Camera access is what feeds the mirror; without it there's nothing to show.
    /// Say so in the primary empty state (not just the footer HUD) and offer a
    /// button: a fresh prompt if the choice was never made, otherwise a shortcut
    /// to the Camera privacy pane (macOS won't reshow the prompt after a denial).
    private func showCameraDenied() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            setEmptyStateReason(title: "Camera access needed",
                hint: "iMirror uses your Mac’s camera permission to show the iPhone’s screen. Allow access to start mirroring.")
            cameraActionButton.title = "Allow Camera Access"
        } else {
            setEmptyStateReason(title: "Camera access needed",
                hint: "Turn on Camera for iMirror in System Settings ▸ Privacy & Security ▸ Camera.")
            cameraActionButton.title = "Open Camera Settings"
        }
        cameraActionButton.isHidden = false
        setEmptyState(hidden: false)
        setStatus("Camera access needed — grant it to start mirroring.")
    }

    private func configureSession() {
        session.beginConfiguration()
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(frameGrabber, queue: frameGrabber.queue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
        audioPreview.volume = 0   // muted until the user enables sound
        if session.canAddOutput(audioPreview) { session.addOutput(audioPreview) }
        session.commitConfiguration()
        refreshDevices()
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    // MARK: Device discovery

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceChanged),
            name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceChanged),
            name: .AVCaptureDeviceWasDisconnected, object: nil)
        // The capture session can fail or be interrupted without the device ever
        // "disconnecting" (USB renegotiation, media services reset). Without these
        // the mirror goes black and never recovers until the app is relaunched.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterrupted),
            name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded, object: session)
        // Pause per-frame work + the capture watchdog while the window is hidden.
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func occlusionChanged() {
        let visible = window.occlusionState.contains(.visible)
        guard visible != appVisible else { return }
        appVisible = visible
        // Stop delivering frames to the screenshot grabber while hidden (the live
        // preview layer is driven separately and unaffected). On reveal, reset the
        // liveness clock so the watchdog doesn't fire on the hidden gap.
        videoDataOutput.connection(with: .video)?.isEnabled = visible
        if visible { frameGrabber.markActive() }
    }

    @objc private func deviceChanged(_ note: Notification) {
        refreshDevices()
        // Fast replug recovery: when a phone (re)appears while automation is on but
        // WDA is down, the go-ios chain has likely backed off — kick a clean chain
        // restart now instead of waiting out the slow down-watchdog. Rate-limited
        // (and shares lastWDARestart) so it can't storm if the device flaps.
        // Gated on a prior successful connect so this only ever fires on a genuine
        // replug, never during the initial bring-up (health starts .down).
        guard automationEnabled, transport.canSelfManage, hadSuccessfulConnection,
              !devices.isEmpty, health == .down else { return }
        if let last = lastWDARestart, Date().timeIntervalSince(last) < 30 { return }
        lastWDARestart = Date()
        downSince = Date()
        setStatus("iPhone reconnected — restarting WebDriverAgent…")
        transport.restartChain()
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        NSLog("[iMirror] AVCaptureSession runtime error: \(err?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async { [weak self] in self?.recoverCapture("runtime error") }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.setStatus("Mirror paused — capture interrupted.") }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.recoverCapture("interruption ended") }
    }

    // MARK: Capture-pipe recovery

    private func startCaptureWatchdog() {
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.checkCaptureLiveness() }
        RunLoop.main.add(t, forMode: .common)
        captureWatchdogTimer = t
    }

    /// Detects a stalled mirror that fires no notification: a device is bound but
    /// frames stopped arriving (or the session quietly stopped running). Rebinds
    /// the input to restart the CoreMediaIO stream. Rate-limited so a device that
    /// can't deliver (e.g. truly unplugged) isn't bounced every tick.
    private func checkCaptureLiveness() {
        guard appVisible else { return }                        // hidden — frame delivery is paused
        guard currentInput != nil else { return }               // no device selected — nothing to recover
        let stalled = frameGrabber.secondsSinceLastFrame > 5
        let stopped = !session.isRunning
        guard stalled || stopped else { return }
        if let last = lastCaptureRecovery, Date().timeIntervalSince(last) < 8 { return }
        recoverCapture(stopped ? "session stopped" : "no frames >5s")
    }

    /// Rebuild the current device's input (a fresh AVCaptureDeviceInput forces the
    /// CMIO stream to re-establish) and ensure the session is running. Covers both
    /// a stopped session (runtime error) and a silently dead stream (USB churn).
    private func recoverCapture(_ reason: String) {
        guard let device = currentInput?.device else { refreshDevices(); return }
        lastCaptureRecovery = Date()
        NSLog("[iMirror] recovering capture (\(reason)) on \(device.localizedName)")
        switchToDevice(device)                                  // begin/commit config on main; rebinds input
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func refreshDevices() {
        discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        devices = discovery.devices

        let previouslySelected = currentInput?.device.uniqueID
        devicePopUp.removeAllItems()

        if devices.isEmpty {
            setStatus("No iPhone found — plug in via USB, unlock, tap “Trust”.")
            devicePopUp.addItem(withTitle: "No device")
            devicePopUp.isEnabled = false
            recordItem?.isEnabled = false
            screenshotItem?.isEnabled = false
            audioItem?.isEnabled = false
            switchToDevice(nil)
            return
        }

        devicePopUp.isEnabled = true
        for device in devices { devicePopUp.addItem(withTitle: device.localizedName) }

        if let prev = previouslySelected,
           let device = devices.first(where: { $0.uniqueID == prev }) {
            devicePopUp.selectItem(withTitle: device.localizedName)
        } else {
            devicePopUp.selectItem(at: 0)
            switchToDevice(devices[0])
        }
    }

    @objc private func deviceSelected() {
        let index = devicePopUp.indexOfSelectedItem
        guard index >= 0, index < devices.count else { return }
        switchToDevice(devices[index])
    }

    private func switchToDevice(_ device: AVCaptureDevice?) {
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        if let device {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    currentInput = input
                    frameGrabber.markActive()   // start the watchdog's grace window from this bind
                    setStatus("Mirroring \(device.localizedName) — phone stays usable.")
                    recordItem?.isEnabled = true
                    screenshotItem?.isEnabled = true
                    audioItem?.isEnabled = true
                } else {
                    setStatus("Cannot add \(device.localizedName) to session.")
                }
            } catch {
                setStatus("Failed to open device: \(error.localizedDescription)")
            }
        }
        session.commitConfiguration()
        if currentInput == nil {
            // Back to no-device: restore the default guidance (a prior failure may
            // have changed it) unless the camera itself is blocked.
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                cameraActionButton.isHidden = true       // camera fine — no button here
                setEmptyStateReason(title: "No iPhone connected",
                                    hint: "Plug in via USB, unlock, and tap “Trust.”")
            }
        }
        setEmptyState(hidden: currentInput != nil)         // fade out once a phone is bound
    }

    // MARK: Recording

    @objc private func toggleRecord() {
        if movieOutput.isRecording { movieOutput.stopRecording(); return }
        guard currentInput != nil else { return }
        let name = "iMirror_\(timestamp()).mp4"
        let url = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        movieOutput.startRecording(to: url, recordingDelegate: self)
        recordItem?.image = symbol("stop.circle.fill", "Stop")
        recordItem?.label = "Stop"
        setStatus("Recording → \(url.path)")
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recordItem?.image = self.symbol("record.circle", "Record")
            self.recordItem?.label = "Record"
            if let error { self.setStatus("Recording error: \(error.localizedDescription)") }
            else { self.setStatus("Saved \(outputFileURL.lastPathComponent) → ~/Movies") }
        }
    }

    // MARK: Screenshot

    @objc private func takeScreenshot() {
        guard let pixelBuffer = frameGrabber.snapshot() else {
            setStatus("No frame yet — wait for the mirror to start.")
            return
        }
        let name = "iMirror_\(timestamp()).png"
        let url = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        // Render + PNG-encode + write off the main thread: a CIContext render and a
        // blocking file write (to a possibly iCloud-synced ~/Pictures) would
        // otherwise hitch the UI on a click that should feel instant. Only the
        // status update hops back to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ciImage = CIImage(cvImageBuffer: pixelBuffer)
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                DispatchQueue.main.async { self.setStatus("Screenshot failed (could not render frame).") }
                return
            }
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

    // MARK: Audio

    @objc private func toggleAudio() {
        audioOn.toggle()
        audioPreview.volume = audioOn ? 1 : 0
        audioItem?.image = symbol(audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                  audioOn ? "Sound on" : "Sound off")
        setStatus(audioOn
            ? "Sound on — phone audio plays through this Mac."
            : "Sound muted.")
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
            let videoRect = self.previewView.previewLayer.layerRectConverted(
                fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
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

    /// Map a click in the preview to a device point. The preview layer's own rect
    /// conversion handles letterboxing + orientation; mapToDevice (in iMirrorCore)
    /// does the normalize + y-flip and is unit-tested.
    private func devicePoint(fromViewPoint p: CGPoint) -> CGPoint? {
        guard let size = wda?.deviceSize else { return nil }
        let videoRect = previewView.previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
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

    @objc private func forceProbe() { probeNow() }

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
            }
        }
    }

    /// If WDA has been unreachable too long while we manage it, the runwda child
    /// is probably hung (it never exits, so the crash-restart can't fire). Bounce
    /// it — rate-limited so rapid restarts can't wedge the device's testmanagerd.
    private func runWatchdog() {
        guard automationEnabled, transport.canSelfManage, health == .down, let since = downSince else { return }
        guard Date().timeIntervalSince(since) >= 60 else { return }   // past normal boot time
        if let last = lastWDARestart, Date().timeIntervalSince(last) < 100 { return }
        lastWDARestart = Date()
        downSince = Date()   // restart the clock; full reset + boot takes ~40s
        setStatus("WebDriverAgent stuck — resetting the connection…")
        transport.restartChain()
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
            hadSuccessfulConnection = true
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            controlSwitch.isEnabled = true
            homeItem?.isEnabled = true
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
        case .connecting:
            downStatusWorkItem?.cancel(); downStatusWorkItem = nil
            if changed { setStatus("Connecting to WDA…") }
        case .down:
            if downSince == nil { downSince = Date() }
            // Lost the connection — disarm control so stray clicks can't fire.
            if controlEnabled {
                controlEnabled = false
                controlSwitch.state = .off
                previewView.controlActive = false
                previewView.resetScroll()
            }
            controlSwitch.isEnabled = false
            homeItem?.isEnabled = false
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
        if on {
            setStatus("Automation ON — starting WebDriverAgent… "
                    + "(iOS shows an \"Automation Running\" overlay on the phone).")
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

        mcpButton.bezelStyle = .rounded
        mcpButton.title = "Install MCP server"
        mcpButton.target = self
        mcpButton.action = #selector(primaryMCP)
        mcpUninstallButton.bezelStyle = .rounded
        mcpUninstallButton.title = "Uninstall"
        mcpUninstallButton.target = self
        mcpUninstallButton.action = #selector(uninstallMCP)
        mcpUninstallButton.isHidden = true
        mcpSpinner.style = .spinning
        mcpSpinner.controlSize = .small
        mcpSpinner.isDisplayedWhenStopped = false   // invisible until an op runs
        let mcpButtons = NSStackView(views: [mcpButton, mcpUninstallButton, mcpSpinner])
        mcpButtons.orientation = .horizontal
        mcpButtons.spacing = 8
        stack.addArrangedSubview(mcpButtons)

        mcpStatusLabel.font = .systemFont(ofSize: 11)
        mcpStatusLabel.textColor = .secondaryLabelColor
        mcpStatusLabel.preferredMaxLayoutWidth = 268
        mcpStatusLabel.lineBreakMode = .byWordWrapping   // wrap, don't clip long status
        mcpStatusLabel.maximumNumberOfLines = 0
        mcpStatusLabel.usesSingleLineMode = false
        mcpStatusLabel.cell?.wraps = true
        mcpStatusLabel.cell?.isScrollable = false
        stack.addArrangedSubview(mcpStatusLabel)
        refreshMCP(updateLabel: true)

        // iOS Simulator section — pick a sim, bring up WDA on :8101, install imirror-sim.
        let simSep = NSBox(); simSep.boxType = .separator
        simSep.translatesAutoresizingMaskIntoConstraints = false
        simSep.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(simSep)

        let simTitle = NSTextField(labelWithString: "iOS Simulator")
        simTitle.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(simTitle)

        let simCap = NSTextField(wrappingLabelWithString:
            "Boot a Simulator and drive it from Claude. Enable brings up WebDriverAgent "
          + "on it (port 8101); view the sim in Apple's Simulator app. Requires Xcode.")
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

        mcpSimButton.bezelStyle = .rounded
        mcpSimButton.title = "Install MCP server (sim)"
        mcpSimButton.target = self
        mcpSimButton.action = #selector(primaryMCPSim)
        mcpSimUninstallButton.bezelStyle = .rounded
        mcpSimUninstallButton.title = "Uninstall"
        mcpSimUninstallButton.target = self
        mcpSimUninstallButton.action = #selector(uninstallMCPSim)
        mcpSimUninstallButton.isHidden = true
        mcpSimSpinner.style = .spinning
        mcpSimSpinner.controlSize = .small
        mcpSimSpinner.isDisplayedWhenStopped = false
        let mcpSimButtons = NSStackView(views: [mcpSimButton, mcpSimUninstallButton, mcpSimSpinner])
        mcpSimButtons.orientation = .horizontal
        mcpSimButtons.spacing = 8
        stack.addArrangedSubview(mcpSimButtons)

        mcpSimStatusLabel.font = .systemFont(ofSize: 11)
        mcpSimStatusLabel.textColor = .secondaryLabelColor
        mcpSimStatusLabel.preferredMaxLayoutWidth = 268
        mcpSimStatusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(mcpSimStatusLabel)

        simController.onState = { [weak self] state in self?.renderSimState(state) }
        refreshSimulators()
        refreshMCPSim(updateLabel: true)

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
    private func refreshMCP(updateLabel: Bool) {
        if updateLabel { mcpStatusLabel.stringValue = "Checking…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MCPInstaller.status()
            DispatchQueue.main.async {
                self.mcpInstalled = s.installed
                self.mcpUninstallButton.isHidden = !s.installed
                self.mcpButton.title = !s.installed ? "Install MCP server"
                                     : (s.upToDate ? "Reinstall" : "Update MCP server")
                if updateLabel {
                    let ver = s.version.map { " · v\($0)" } ?? ""
                    self.mcpStatusLabel.stringValue = !s.installed
                        ? "Not installed."
                        : "Installed · \(s.clients.joined(separator: ", "))\(ver) · "
                          + (s.upToDate ? "up to date." : "update available.")
                }
            }
        }
    }

    @objc private func primaryMCP() {
        mcpButton.isEnabled = false; mcpUninstallButton.isEnabled = false
        mcpSpinner.startAnimation(nil)
        let updating = mcpInstalled          // reinstall/update re-points paths + refreshes deps
        mcpStatusLabel.stringValue = updating
            ? "Updating…" : "Installing… (first run sets up Python — up to ~30s)"
        MCPInstaller.install(update: updating, progress: { [weak self] msg in
            self?.mcpStatusLabel.stringValue = msg
        }, completion: { [weak self] r in
            guard let self else { return }
            self.mcpSpinner.stopAnimation(nil)
            self.mcpStatusLabel.stringValue = r.message
            self.mcpButton.isEnabled = true; self.mcpUninstallButton.isEnabled = true
            self.refreshMCP(updateLabel: false)
        })
    }

    @objc private func uninstallMCP() {
        mcpButton.isEnabled = false; mcpUninstallButton.isEnabled = false
        mcpSpinner.startAnimation(nil)
        mcpStatusLabel.stringValue = "Removing…"
        MCPInstaller.uninstall { [weak self] r in
            guard let self else { return }
            self.mcpSpinner.stopAnimation(nil)
            self.mcpStatusLabel.stringValue = r.message
            self.mcpButton.isEnabled = true; self.mcpUninstallButton.isEnabled = true
            self.refreshMCP(updateLabel: false)
        }
    }

    private func refreshSimulators() {
        let hasXcode = simController.xcodeAvailable()
        simPicker.isEnabled = hasXcode
        simEnableButton.isEnabled = hasXcode
        if !hasXcode { simStatusLabel.stringValue = "Requires Xcode."; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let sims = self.simController.listSimulators()
            DispatchQueue.main.async {
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
        case .ready:    simStatusLabel.stringValue = "WebDriverAgent ready on :8101 ✓"
        case .failed(let m):
            simEnabled = false; simEnableButton.title = "Enable"
            simStatusLabel.stringValue = "Failed: \(m)"
        }
    }

    private func refreshMCPSim(updateLabel: Bool) {
        if updateLabel { mcpSimStatusLabel.stringValue = "Checking…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MCPInstaller.status(profile: .simulator)
            DispatchQueue.main.async {
                self.mcpSimInstalled = s.installed
                self.mcpSimUninstallButton.isHidden = !s.installed
                self.mcpSimButton.title = !s.installed ? "Install MCP server (sim)"
                                        : (s.upToDate ? "Reinstall" : "Update MCP server (sim)")
                if updateLabel {
                    let ver = s.version.map { " · v\($0)" } ?? ""
                    self.mcpSimStatusLabel.stringValue = !s.installed
                        ? "Not installed."
                        : "Installed · \(s.clients.joined(separator: ", "))\(ver) · "
                          + (s.upToDate ? "up to date." : "update available.")
                }
            }
        }
    }

    @objc private func primaryMCPSim() {
        mcpSimButton.isEnabled = false; mcpSimUninstallButton.isEnabled = false
        mcpSimSpinner.startAnimation(nil)
        let updating = mcpSimInstalled
        mcpSimStatusLabel.stringValue = updating ? "Updating…" : "Installing… (first run sets up Python — up to ~30s)"
        MCPInstaller.install(profile: .simulator, update: updating, progress: { [weak self] msg in
            self?.mcpSimStatusLabel.stringValue = msg
        }, completion: { [weak self] r in
            guard let self else { return }
            self.mcpSimSpinner.stopAnimation(nil)
            self.mcpSimStatusLabel.stringValue = r.message
            self.mcpSimButton.isEnabled = true; self.mcpSimUninstallButton.isEnabled = true
            self.refreshMCPSim(updateLabel: false)
        })
    }

    @objc private func uninstallMCPSim() {
        mcpSimButton.isEnabled = false; mcpSimUninstallButton.isEnabled = false
        mcpSimSpinner.startAnimation(nil)
        mcpSimStatusLabel.stringValue = "Removing…"
        MCPInstaller.uninstall(profile: .simulator) { [weak self] r in
            guard let self else { return }
            self.mcpSimSpinner.stopAnimation(nil)
            self.mcpSimStatusLabel.stringValue = r.message
            self.mcpSimButton.isEnabled = true; self.mcpSimUninstallButton.isEnabled = true
            self.refreshMCPSim(updateLabel: false)
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
