import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation

enum USBVideoUpdate: Equatable {
    case frame(CGSize)
    case unavailable(String)
}

/// The phone's USB video stream. Frames stay as pixel buffers; the preview
/// layer displays the capture session directly, and PNG conversion is on demand.
final class USBVideoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CGSize) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private let queue = DispatchQueue(label: "imirror.usb.capture", qos: .userInitiated)
    private let frames = USBVideoFrames()
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var timer: Timer?
    private var requested = false // main thread
    private var running = false // capture queue
    private var startedAt: TimeInterval = 0
    private var announcedUnavailable = false
    private var notifiedSize: CGSize?
    private var lastNotification: TimeInterval = 0
    private var lastStats: TimeInterval = 0
    private var captureStartedAt: TimeInterval = 0

    private var wdaFallback: Bool

    init(wdaFallback: Bool = true) {
        self.wdaFallback = wdaFallback
        super.init()
    }

    func setWDAFallback(_ enabled: Bool) {
        queue.async { [self] in wdaFallback = enabled }
    }

    var hasFrame: Bool { frames.hasFrame }
    func screenshot() -> CGImage? { frames.screenshot() }

    func start() {
        guard !requested else { return }
        requested = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginDiscovery()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.requested else { return }
                    if allowed { self.beginDiscovery() }
                    else { self.onUnavailable?("Camera permission is needed for USB video.") }
                }
            }
        default:
            onUnavailable?("Enable Camera for iMirror in System Settings to use USB video.")
        }
    }

    private func beginDiscovery() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let code = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                            0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        guard code == 0 else { onUnavailable?("USB screen discovery failed (\(code))."); return }
        // CMIO publishes the device asynchronously through the main run loop.
        discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                      position: .unspecified)
        startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scan()
    }

    private func scan() {
        guard requested else { return }
        let devices = discovery?.devices ?? []
        queue.async { [weak self] in
            guard let self else { return }
            guard devices.count <= 1 else {
                self.notifyUnavailable(self.wdaFallback ? "Multiple iPhones connected. Using WDA video to match the control target." : "Disconnect other iPhones to use USB video.")
                if self.input != nil { self.detach() }
                return
            }
            if let input = self.input {
                if !devices.contains(where: { $0.uniqueID == input.device.uniqueID }) {
                    self.notifyUnavailable(self.wdaFallback ? "USB video disconnected. Using WDA video while reconnecting." : "USB video disconnected. Reconnect and unlock the iPhone.")
                    self.detach()
                } else if self.frames.age > 6 || (!self.frames.hasFrame &&
                             ProcessInfo.processInfo.systemUptime - self.captureStartedAt > 8) {
                    // Keep the WDA fallback usable instead of repeatedly cycling
                    // USB (which re-enumerates the device and disrupts control).
                    self.notifyUnavailable(self.wdaFallback ? "USB video paused. Using WDA video while waiting." : "USB video paused. Unlock the iPhone to resume.")
                }
                return
            }
            guard let device = devices.first else {
                if ProcessInfo.processInfo.systemUptime - self.startedAt > 8 {
                    self.notifyUnavailable(self.wdaFallback ? "USB video unavailable. Using WDA video." : "USB video unavailable. Connect and unlock the iPhone, then tap Trust.")
                }
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    self.notifyUnavailable(self.wdaFallback ? "Cannot open USB video. Using WDA video." : "Cannot open USB video. Reconnect and unlock the iPhone.")
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                self.session.commitConfiguration()
                self.input = input
                self.output = output
                self.notifiedSize = nil
                self.frames.reset()
                self.running = true
                self.captureStartedAt = ProcessInfo.processInfo.systemUptime
                self.announcedUnavailable = false
                self.session.startRunning()
                NSLog("iMirror: USB video capture started")
            } catch {
                self.notifyUnavailable("USB video failed: \(error.localizedDescription)")
            }
        }
    }

    private func notifyUnavailable(_ reason: String) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        frames.clearImage()
        // Both callbacks originate on this queue and share one UI delivery slot.
        // A main-queue trampoline here could reorder a later resumed frame.
        onUnavailable?(reason)
    }

    private func detach() {
        running = false
        session.stopRunning()
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if let output { output.setSampleBufferDelegate(nil, queue: nil); session.removeOutput(output) }
        session.commitConfiguration()
        input = nil
        output = nil
        frames.reset()
    }

    func stop() {
        requested = false
        timer?.invalidate()
        timer = nil
        discovery = nil
        queue.async { [self] in detach() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        frames.receive(image, at: now)
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        if size != notifiedSize || now - lastNotification >= 0.1 || announcedUnavailable {
            notifiedSize = size
            lastNotification = now
            announcedUnavailable = false
            onFrame?(size)
        }
        if now - lastStats >= 10 {
            lastStats = now
            NSLog("iMirror: USB video \(frames.statistics)")
        }
    }
}

/// One retained frame, shared between capture and screenshot queues.
final class USBVideoFrames {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var image: CVPixelBuffer?
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval?
    private var count = 0

    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return image != nil }
    var age: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return lastAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    }
    var statistics: String {
        lock.lock(); defer { lock.unlock() }
        let duration = (lastAt ?? 0) - (firstAt ?? 0)
        let fps = duration > 0 ? Double(max(0, count - 1)) / duration : 0
        return String(format: "%.1f FPS (%d frames)", fps, count)
    }
    func receive(_ image: CVPixelBuffer, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.image = image
        if firstAt == nil { firstAt = now }
        lastAt = now
        count += 1
    }
    func clearImage() { lock.lock(); image = nil; lock.unlock() }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        image = nil; firstAt = nil; lastAt = nil; count = 0
    }
    func screenshot() -> CGImage? {
        lock.lock(); let buffer = image; lock.unlock()
        guard let buffer else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ci, from: ci.extent)
    }
}
