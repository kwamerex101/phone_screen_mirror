import Foundation

/// Only a successful USB discovery proves presence or absence. Failed discovery
/// must never be mistaken for an unplug, which could spuriously re-arm recovery.
enum DevicePresence: Equatable {
    case absent, present, unavailable

    static func parse(_ output: String, exitCode: Int32) -> DevicePresence {
        guard exitCode == 0, let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["deviceList"] as? [[String: Any]] else { return .unavailable }
        var hasUSB = false
        for device in devices {
            guard let udid = device["Udid"] as? String, !udid.isEmpty,
                  let connection = device["ConnectionType"] as? String,
                  connection == "USB" || connection == "Network" else { return .unavailable }
            hasUSB = hasUSB || connection == "USB"
        }
        return hasUSB ? .present : .absent
    }
}

/// Main-thread polling coordinator. The injected discovery operation is async;
/// only one request can be pending, even if several health ticks ask to sample.
final class DevicePresenceMonitor {
    private let discover: (@escaping (DevicePresence) -> Void) -> Void
    private let now: () -> TimeInterval
    private let interval: TimeInterval
    private let callbacks = MainQueueCallbackScope()
    private let onChange: (DevicePresence, Bool) -> Void
    private var lastSampleAt: TimeInterval?
    private var pending = false
    private var lastVerified: DevicePresence?

    init(interval: TimeInterval = 6,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         discover: @escaping (@escaping (DevicePresence) -> Void) -> Void,
         onChange: @escaping (DevicePresence, Bool) -> Void) {
        self.interval = interval
        self.now = now
        self.discover = discover
        self.onChange = onChange
    }

    func reset() {
        callbacks.invalidate()
        pending = false
        lastSampleAt = nil
        lastVerified = nil
    }

    func markConnected() {
        reset()
        lastVerified = .present
    }

    func sampleIfDue(force: Bool = false) {
        guard !pending else { return }
        let sampledAt = now()
        if !force, let lastSampleAt, sampledAt - lastSampleAt < interval { return }
        pending = true
        lastSampleAt = sampledAt
        discover(callbacks.delivering { [weak self] presence in
            guard let self else { return }
            self.pending = false
            let reattached = self.lastVerified == .absent && presence == .present
            if presence != .unavailable { self.lastVerified = presence }
            self.onChange(presence, reattached)
        })
    }
}
