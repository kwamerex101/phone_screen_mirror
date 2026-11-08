import Foundation
import iMirrorCore

/// The wired iPhone input path. The bridge is pinned by the setup script and
/// commands always carry the exact CoreDevice identifier selected at discovery.
final class CoreDeviceControl {
    enum State: Equatable {
        case unavailable(String)
        case ready(String)
    }

    private let queue = DispatchQueue(label: "imirror.coredevice", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var pending = 0
    private var lastProbe: (id: String, time: TimeInterval)?
    private var probing = false
    private var lease: Process?
    private var touchscreenServices: [String: String] = [:]
    private var touchscreenDevice: String?

    static let unsupported = "Wired Control requires an Apple silicon Mac with macOS 27, Xcode 27, and an iPhone on iOS 27 or later."

    static var supported: Bool {
        #if arch(arm64)
        if #available(macOS 27, *) { return true }
        #endif
        return false
    }

    private static var installDir: URL { MCPPaths.appSupport.appendingPathComponent("ipb", isDirectory: true) }

    static var executable: String? {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["IMIRROR_IPB_BIN"],
            installDir.appendingPathComponent("bin/ipb").path,
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func setup(completion: @escaping (String?) -> Void) {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/setup-coredevice.sh")
        let scripts: [URL?] = [Bundle.main.resourceURL?.appendingPathComponent("scripts/setup-coredevice.sh"), source]
        guard supported, let script = scripts.compactMap({ $0 }).first(where: {
            FileManager.default.isReadableFile(atPath: $0.path)
        }) else {
            completion(supported ? "Wired Control setup script is missing." : unsupported)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BoundedProcessRunner.run("/bin/bash", [script.path, installDir.path], timeout: 180)
            let error = result.code == 0 ? nil : (result.timedOut
                ? "Wired Control setup timed out. Check your internet connection and retry."
                : result.out.split(separator: "\n").last.map(String.init) ?? "Wired Control setup failed.")
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Invalidates queued input and discovery results after leaving the mode or losing video.
    func reset() {
        lock.withLock { generation += 1 }
        queue.async { [self] in
            lastProbe = nil
            touchscreenDevice = nil
            touchscreenServices = [:]
            stopLease()
        }
    }

    func probe(completion: @escaping (State) -> Void) {
        guard !probing else { return }
        probing = true
        let ticket = lock.withLock { generation }
        queue.async { [self] in
            let state = discover()
            if case .unavailable = state {
                lastProbe = nil
                stopLease()
            }
            DispatchQueue.main.async { [self] in
                probing = false
                if isCurrent(ticket) { completion(state) }
            }
        }
    }

    private func discover() -> State {
        guard Self.supported else { return .unavailable(Self.unsupported) }
        guard let executable = Self.executable else {
            return .unavailable("Open Settings and choose Set Up Wired Control.")
        }
        let list = BoundedProcessRunner.run(executable, ["devices"], timeout: 5, captureStandardError: false)
        guard list.code == 0 else {
            return .unavailable("Open Xcode once to finish setup and select Xcode 27 or later for command-line tools.")
        }
        let phones = list.out.split(separator: "\n").compactMap { line -> (String, Int)? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[3] == "wired", fields[5].hasPrefix("iPhone"),
                  UUID(uuidString: String(fields[0])) != nil else { return nil }
            let version = fields[2].prefix(while: { $0.isNumber })
            return (String(fields[0]), Int(version) ?? 0)
        }
        guard phones.count == 1, let (id, version) = phones.first else {
            return .unavailable(phones.isEmpty ? "Connect one iPhone by USB, unlock it, and tap Trust."
                : "Disconnect other iPhones before using Wired Control.")
        }
        guard version >= 27 else { return .unavailable("Wired Control needs iOS 27 or later. Choose WebDriverAgent in Settings for this iPhone.") }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastProbe, lastProbe.id == id, now - lastProbe.time < 20 {
            keepTunnelOpen(for: id)
            return .ready(id)
        }
        if lastProbe?.id != id { stopLease() }
        let doctor = BoundedProcessRunner.run(executable, ["-s", id, "doctor"], timeout: 9)
        guard doctor.code == 0 else {
            lastProbe = nil
            if doctor.out.localizedCaseInsensitiveContains("locked") && !doctor.out.localizedCaseInsensitiveContains("unlocked") {
                return .unavailable("Unlock the iPhone to use Wired Control.")
            }
            return .unavailable("Enable Developer Mode on the iPhone, then open Xcode’s Device Hub once to finish preparing the device.")
        }
        lastProbe = (id, now)
        keepTunnelOpen(for: id)
        return .ready(id)
    }

    /// CoreDevice's service sockets do not renew the tunnel. A bounded Apple
    /// notification observer keeps it open while the preview is ready for input.
    private func keepTunnelOpen(for id: String) {
        guard lease?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "notification", "observe", "--device", id,
                             "--name", "com.imirror.coredevice.keepalive",
                             "--session-timeout", "90", "--timeout", "90"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { lease = process }
    }

    private func stopLease() {
        if let lease, lease.isRunning { lease.terminate() }
        lease = nil
    }

    func send(_ commands: [[String]], to id: String, frameSize: CGSize, onFailure: @escaping (String) -> Void) {
        guard let executable = Self.executable, !commands.isEmpty else { return }
        let ticket = lock.withLock { () -> Int? in
            guard pending < 24 else { return nil }
            pending += 1
            return generation
        }
        guard let ticket else {
            onFailure("Wired Control is busy. Wait for pending input to finish.")
            return
        }
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            for command in commands {
                guard isCurrent(ticket) else { return }
                let result: (code: Int32, out: String, timedOut: Bool)
                if command.first == "tap" || command.first == "swipe" {
                    guard let target = touchscreen(for: id, frameSize: frameSize, executable: executable) else {
                        DispatchQueue.main.async { [self] in
                            if isCurrent(ticket) { onFailure("The active iPhone display changed. Wait for the preview and try again.") }
                        }
                        return
                    }
                    guard isCurrent(ticket) else { return }
                    let touch = Self.rotateTouch(command, quarter: target.quarter)
                    result = BoundedProcessRunner.run("/usr/bin/env",
                        ["UHID_SERVICE_ID=" + target.service, executable, "-s", id] + touch, timeout: 8)
                } else {
                    result = BoundedProcessRunner.run(executable, ["-s", id] + command, timeout: 8)
                }
                guard result.code == 0 else {
                    lastProbe = nil
                    DispatchQueue.main.async { [self] in
                        guard isCurrent(ticket) else { return }
                        reset()
                        onFailure("Wired input did not complete. Check that the iPhone is unlocked and connected.")
                    }
                    return
                }
            }
        }
    }

    private func touchscreen(for id: String, frameSize: CGSize, executable: String) -> (service: String, quarter: Int)? {
        let result = BoundedProcessRunner.run("/usr/bin/xcrun",
            ["devicectl", "device", "info", "displays", "--device", id, "--json-output", "/dev/stdout", "--quiet"],
            timeout: 3, captureStandardError: false)
        guard result.code == 0, let display = Self.activeTouchDisplay(result.out, frameSize: frameSize) else { return nil }
        if touchscreenDevice != id || touchscreenServices[display.uniqueID] == nil {
            let result = BoundedProcessRunner.run(executable, ["-s", id, "services"], timeout: 5)
            guard result.code == 0 else { return nil }
            touchscreenDevice = id
            touchscreenServices = Self.touchscreenDescriptors(result.out)
        }
        guard let service = touchscreenServices[display.uniqueID] else { return nil }
        return (service, display.quarter)
    }

    static func activeTouchDisplay(_ json: String, frameSize: CGSize) -> (uniqueID: String, quarter: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else { return nil }
        let active = displays.filter {
            ($0["active"] as? Bool) == true && ($0["type"] as? [String: Any])?["integrated"] != nil
        }
        guard active.count == 1, let display = active.first,
              let uniqueID = display["uniqueId"] as? String, !uniqueID.isEmpty,
              let orientation = display["currentOrientation"] as? String,
              let native = display["nativeSize"] as? [Double], native.count == 2,
              display["nativeOrientation"] as? String == "rot0",
              let quarter = ["rot0", "rot90", "rot180", "rot270"].firstIndex(of: orientation) else { return nil }
        let size = quarter.isMultiple(of: 2) ? CGSize(width: native[0], height: native[1])
                                            : CGSize(width: native[1], height: native[0])
        guard displayShapesMatch(frame: frameSize, logical: size) else { return nil }
        return (uniqueID, quarter)
    }

    static func touchscreenDescriptors(_ output: String) -> [String: String] {
        var services: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("connectedDescriptor[") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[1].hasPrefix("serviceID:0x"),
                  let start = parts[2].range(of: "CoreDevice touchscreen("),
                  let end = parts[2][start.upperBound...].firstIndex(of: ")") else { continue }
            services[String(parts[2][start.upperBound..<end])] = String(parts[1].dropFirst("serviceID:".count))
        }
        return services
    }

    static func rotateTouch(_ command: [String], quarter: Int) -> [String] {
        var result = command
        let indices = command.first == "swipe" ? [1, 3] : [1]
        for index in indices {
            guard command.indices.contains(index + 1),
                  let x = Double(command[index]), let y = Double(command[index + 1]) else { continue }
            switch quarter {
            case 1: result[index] = String(y); result[index + 1] = String(1 - x)
            case 2: result[index] = String(1 - x); result[index + 1] = String(1 - y)
            case 3: result[index] = String(1 - y); result[index + 1] = String(x)
            default: break
            }
        }
        return result
    }

    private func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }

    static func pointArguments(_ point: CGPoint, size: CGSize) -> [String] {
        [String(Double(point.x / size.width)), String(Double(point.y / size.height))]
    }

    static func typing(_ text: String) -> [[String]] {
        var keys: [[String]] = []
        let punctuation = [" ": "space", "\n": "return", "\r": "return", "\t": "tab",
                           "\u{8}": "backspace", "\u{7f}": "0x4c", "-": "minus",
                           "=": "equals", "[": "left-bracket", "]": "right-bracket",
                           "\\": "backslash", ";": "semicolon", "'": "apostrophe",
                           "`": "grave", ",": "comma", ".": "period", "/": "slash"]
        for character in text {
            let value = String(character)
            if let key = punctuation[value] {
                keys.append(["key", key, "0.02"])
            } else if let ascii = character.asciiValue, (97...122).contains(ascii) || (48...57).contains(ascii) {
                keys.append(["key", value, "0.02"])
            } else {
                // Uppercase, composed text, and keyboard-layout-dependent symbols
                // use the bridge's paste path. Settings explains the clipboard effect.
                return [["text", text]]
            }
        }
        return keys
    }
}
