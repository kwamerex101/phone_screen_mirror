// Parse `xcrun simctl list devices available -j` into a flat, display-ready list.
// Pure (no shell-out) so it unit-tests against canned JSON. The controller in the
// app target does the actual shell-out and hands the bytes here.

import Foundation

public struct SimDevice: Equatable, Sendable {
    public let udid: String
    public let name: String
    public let runtime: String   // humanized, e.g. "iOS 26.5"
    public let isBooted: Bool

    public init(udid: String, name: String, runtime: String, isBooted: Bool) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.isBooted = isBooted
    }
}

public enum SimctlParsing {
    public static func parseSimulators(_ data: Data) -> [SimDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }
        var out: [SimDevice] = []
        for (runtimeKey, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            let runtime = humanizeRuntime(runtimeKey)
            for d in list {
                guard let udid = d["udid"] as? String,
                      let name = d["name"] as? String else { continue }
                let booted = (d["state"] as? String) == "Booted"
                out.append(SimDevice(udid: udid, name: name, runtime: runtime, isBooted: booted))
            }
        }
        // Booted first, then by runtime, then by name — stable, useful default for a picker.
        return out.sorted {
            if $0.isBooted != $1.isBooted {
                return $0.isBooted
            } else if $0.runtime != $1.runtime {
                return $0.runtime < $1.runtime
            } else {
                return $0.name < $1.name
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5".
    private static func humanizeRuntime(_ key: String) -> String {
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        let parts = tail.split(separator: "-")
        guard let os = parts.first else { return tail }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(os) : "\(os) \(version)"
    }
}
