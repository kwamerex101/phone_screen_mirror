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
    static let audio      = NSToolbarItem.Identifier("audio")
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
        [.device, .record, .screenshot, .audio, .flexibleSpace, .health, .control, .home]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.device, .record, .screenshot, .audio, .health, .control, .home, .flexibleSpace, .space]
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
        if !controlEnabled { previewView.resetScroll() }
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
