import Foundation

/// Video liveness survives control-session failures, but each runner startup
/// gets a new grace period before the video watchdog can recover it.
public struct VideoRecoveryClock {
    public private(set) var lastActivityAt: TimeInterval?
    public private(set) var hasReceivedFrame = false

    public init() {}

    public mutating func clear() {
        lastActivityAt = nil
        hasReceivedFrame = false
    }

    public mutating func beginStartup(at now: TimeInterval) {
        lastActivityAt = now
        hasReceivedFrame = false
    }

    public mutating func receivedFrame(at now: TimeInterval) {
        lastActivityAt = now
        hasReceivedFrame = true
    }

    public func hasFreshFrame(at now: TimeInterval, threshold: TimeInterval) -> Bool {
        guard hasReceivedFrame, let lastActivityAt else { return false }
        return now - lastActivityAt < threshold
    }

    public func noFrameDuration(at now: TimeInterval, controlConnected: Bool) -> TimeInterval? {
        guard hasReceivedFrame || controlConnected, let lastActivityAt else { return nil }
        return max(0, now - lastActivityAt)
    }
}
