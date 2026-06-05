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
    var onDrag: (([CGPoint]) -> Void)?      // full drag path, view coords
    var onType: ((String) -> Void)?

    private var downPoint: CGPoint?
    private var dragPath: [CGPoint] = []

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

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        dragPath = [p]
    }

    override func mouseDragged(with event: NSEvent) {
        dragPath.append(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let up = convert(event.locationInWindow, from: nil)
        guard let down = downPoint else { return }
        downPoint = nil
        let dx = up.x - down.x, dy = up.y - down.y
        if (dx * dx + dy * dy).squareRoot() > 6 {
            onDrag?(dragPath)              // follow the actual path (scroll/swipe)
        } else {
            onTap?(up)
        }
        dragPath = []
    }

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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; lock.unlock()   // holds one frame; pool keeps the rest
    }

    func snapshot() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return latest
    }
}

// MARK: - Toolbar item identifiers

private extension NSToolbarItem.Identifier {
    static let device     = NSToolbarItem.Identifier("device")
    static let record     = NSToolbarItem.Identifier("record")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let health     = NSToolbarItem.Identifier("health")
    static let control    = NSToolbarItem.Identifier("control")
    static let home       = NSToolbarItem.Identifier("home")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate,
                         AVCaptureFileOutputRecordingDelegate {
    private var window: NSWindow!
    private var previewView: PreviewView!
    private var statusLabel: NSTextField!

    // Toolbar controls
    private let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let controlSwitch = NSSwitch()
    private let healthButton = NSButton()
    private var recordItem: NSToolbarItem!
    private var screenshotItem: NSToolbarItem!
    private var controlItem: NSToolbarItem!
    private var homeItem: NSToolbarItem!

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
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
    private var health: Health = .down
    private var healthTimer: Timer?
    private var probing = false
    private var creatingSession = false
    private var downSince: Date?
    private var lastWDARestart: Date?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        enableScreenCaptureDevices()
        buildWindow()
        requestCameraAccessThenStart()
        observeDeviceChanges()
        transport.start()        // spawn go-ios forward + in-process loopback relay
        startHealthMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        transport.stop()
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "iMirror"
        window.titleVisibility = .hidden   // free the unified toolbar for the controls
        window.center()
        window.setFrameAutosaveName("iMirrorMain")

        // Container: preview fills it; a click-through glass HUD shows status at
        // the bottom so the toolbar stays clean.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 880))

        previewView = PreviewView(frame: container.bounds)
        previewView.previewLayer.session = session
        previewView.autoresizingMask = [.width, .height]
        wireInput()
        container.addSubview(previewView)

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

        // Control switch (iOS-style toggle)
        controlSwitch.target = self
        controlSwitch.action = #selector(toggleControl)
        controlSwitch.isEnabled = false

        // Health dot — colored status, click to force a re-check
        healthButton.isBordered = false
        healthButton.bezelStyle = .toolbar
        healthButton.imagePosition = .imageOnly
        healthButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "WDA status")
        healthButton.contentTintColor = .systemGray
        healthButton.target = self
        healthButton.action = #selector(forceProbe)
        healthButton.toolTip = "WDA status — click to re-check"

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
        [.device, .record, .screenshot, .flexibleSpace, .health, .control, .home]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.device, .record, .screenshot, .health, .control, .home, .flexibleSpace, .space]
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
            return controlItem

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
                    else { self?.setStatus("Camera access denied — enable in System Settings ▸ Privacy") }
                }
            }
        default:
            setStatus("Camera access denied — enable in System Settings ▸ Privacy ▸ Camera")
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(frameGrabber, queue: frameGrabber.queue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
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
    }

    @objc private func deviceChanged(_ note: Notification) { refreshDevices() }

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
                    setStatus("Mirroring \(device.localizedName) — phone stays usable.")
                    recordItem?.isEnabled = true
                    screenshotItem?.isEnabled = true
                } else {
                    setStatus("Cannot add \(device.localizedName) to session.")
                }
            } catch {
                setStatus("Failed to open device: \(error.localizedDescription)")
            }
        }
        session.commitConfiguration()
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
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            setStatus("Screenshot failed (could not render frame).")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            setStatus("Screenshot failed (could not encode PNG).")
            return
        }
        let name = "iMirror_\(timestamp()).png"
        let url = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        do {
            try png.write(to: url)
            setStatus("Saved \(url.lastPathComponent) → ~/Pictures")
        } catch {
            setStatus("Screenshot save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Control (WDA)

    private func wireInput() {
        previewView.onTap = { [weak self] viewPoint in
            guard let self, self.controlEnabled, let p = self.devicePoint(fromViewPoint: viewPoint) else { return }
            self.wda?.tap(at: p)
        }
        previewView.onDrag = { [weak self] viewPath in
            guard let self, self.controlEnabled else { return }
            let devicePath = self.downsample(viewPath, max: 24)
                .compactMap { self.devicePoint(fromViewPoint: $0) }
            guard devicePath.count >= 2 else { return }
            self.wda?.drag(path: devicePath)
        }
        previewView.onType = { [weak self] text in
            guard let self, self.controlEnabled else { return }
            self.wda?.typeText(text)
        }
    }

    /// Evenly thin a path to at most `max` points (keeps first + last) so a long
    /// drag doesn't produce an oversized WDA action payload.
    private func downsample(_ points: [CGPoint], max: Int) -> [CGPoint] {
        guard points.count > max, max >= 2 else { return points }
        let stride = Double(points.count - 1) / Double(max - 1)
        var out: [CGPoint] = []
        for i in 0..<max { out.append(points[Int((Double(i) * stride).rounded())]) }
        return out
    }

    /// Map a click in the preview (view coords, y-up) to a device point in WDA
    /// logical points (y-down). Uses the preview layer's own rect conversion so
    /// letterboxing and orientation are handled by AVFoundation.
    private func devicePoint(fromViewPoint p: CGPoint) -> CGPoint? {
        guard let size = wda?.deviceSize else { return nil }
        let videoRect = previewView.previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard videoRect.width > 1, videoRect.height > 1 else { return nil }
        let nx = (p.x - videoRect.minX) / videoRect.width
        let nyUp = (p.y - videoRect.minY) / videoRect.height
        guard nx >= 0, nx <= 1, nyUp >= 0, nyUp <= 1 else { return nil }   // outside video
        let ny = 1 - nyUp   // view is y-up, device is y-down
        return CGPoint(x: nx * size.width, y: ny * size.height)
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
        guard !probing else { return }
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
        guard transport.canSelfManage, health == .down, let since = downSince else { return }
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

    private func setHealth(_ new: Health) {
        let changed = (new != health)
        health = new
        updateHealthDot()

        switch new {
        case .connected:
            downSince = nil
            controlSwitch.isEnabled = true
            homeItem?.isEnabled = true
            if changed {
                let s = wda?.deviceSize ?? .zero
                setStatus("WDA connected — \(Int(s.width))×\(Int(s.height)) pts. Flip Control to drive.")
            }
        case .connecting:
            if changed { setStatus("Connecting to WDA…") }
        case .down:
            if downSince == nil { downSince = Date() }
            // Lost the connection — disarm control so stray clicks can't fire.
            if controlEnabled {
                controlEnabled = false
                controlSwitch.state = .off
            }
            controlSwitch.isEnabled = false
            homeItem?.isEnabled = false
            if changed {
                setStatus(transport.canSelfManage
                    ? "Starting WebDriverAgent… (first launch can take ~20s)"
                    : "WDA unreachable — run ./scripts/wda-up.sh")
            }
        }
    }

    private func updateHealthDot() {
        switch health {
        case .connected:
            healthButton.contentTintColor = .systemGreen
            healthButton.toolTip = "WDA connected — click to re-check"
        case .connecting:
            healthButton.contentTintColor = .systemYellow
            healthButton.toolTip = "Connecting to WDA…"
        case .down:
            healthButton.contentTintColor = .systemRed
            healthButton.toolTip = "WDA unreachable — click to re-check"
        }
    }

    @objc private func toggleControl() {
        // Only allow arming control when actually connected.
        guard health == .connected else {
            controlSwitch.state = .off
            controlEnabled = false
            setStatus("Can't enable control — WDA not connected (dot is not green).")
            return
        }
        controlEnabled = (controlSwitch.state == .on)
        setStatus(controlEnabled
            ? "Control ON — clicks/keys drive the phone."
            : "Control off — mirror only.")
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
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
