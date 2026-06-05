import CoreGraphics
import Foundation

/// Pure parsers for WebDriverAgent JSON responses — WDA wraps payloads in a
/// "value" object but not always, so each tolerates both shapes.
public enum WDAParse {
    public static func sessionId(_ json: [String: Any]?) -> String? {
        let value = (json?["value"] as? [String: Any]) ?? json ?? [:]
        return (value["sessionId"] as? String) ?? (json?["sessionId"] as? String)
    }

    public static func windowSize(_ json: [String: Any]?) -> CGSize? {
        let v = (json?["value"] as? [String: Any]) ?? json ?? [:]
        guard let w = (v["width"] as? NSNumber)?.doubleValue,
              let h = (v["height"] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    public static func ready(_ json: [String: Any]?) -> Bool {
        ((json?["value"] as? [String: Any])?["ready"] as? Bool) ?? false
    }
}
