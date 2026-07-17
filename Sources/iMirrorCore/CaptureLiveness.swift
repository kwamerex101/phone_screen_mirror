import Foundation

/// Thresholds for the capture watchdog.
public enum CaptureLiveness {
    /// No frame for longer than this means the mirror is stalled.
    public static let stallThreshold: TimeInterval = 5
    /// How long a recovery is given to produce its first frame before the
    /// watchdog is allowed to fire again.
    ///
    /// Rebinding tears the CMIO producer down and back up. That is ~40ms on a
    /// healthy device, but was measured at 12.2s on one that had just
    /// re-enumerated. The old 8s rate-limit was shorter than that teardown, so
    /// the watchdog re-fired the instant the stream came back and killed it
    /// ~2.8s in -- before the phone had delivered a single frame -- looping
    /// forever on a black mirror. This must stay comfortably above
    /// teardown + first-frame latency, or the recovery becomes the stall.
    public static let recoveryGrace: TimeInterval = 20
}

/// Everything the watchdog needs to decide, with no AVFoundation/AppKit types.
public struct CaptureLivenessInput {
    public var visible: Bool
    public var hasInput: Bool
    public var sessionRunning: Bool
    public var secondsSinceLastFrame: TimeInterval
    /// Seconds since the last recovery *began*, or nil if none has run yet.
    public var secondsSinceRecoveryStarted: TimeInterval?

    public init(visible: Bool,
                hasInput: Bool,
                sessionRunning: Bool,
                secondsSinceLastFrame: TimeInterval,
                secondsSinceRecoveryStarted: TimeInterval?) {
        self.visible = visible
        self.hasInput = hasInput
        self.sessionRunning = sessionRunning
        self.secondsSinceLastFrame = secondsSinceLastFrame
        self.secondsSinceRecoveryStarted = secondsSinceRecoveryStarted
    }
}

public enum CaptureLivenessDecision: Equatable {
    case idle
    case recover(reason: String)
}

/// Decide whether to rebind the capture input.
public func captureLivenessDecision(_ i: CaptureLivenessInput) -> CaptureLivenessDecision {
    guard i.visible else { return .idle }
    guard i.hasInput else { return .idle }
    if let since = i.secondsSinceRecoveryStarted, since < CaptureLiveness.recoveryGrace {
        return .idle
    }
    if !i.sessionRunning { return .recover(reason: "session stopped") }
    if i.secondsSinceLastFrame > CaptureLiveness.stallThreshold {
        return .recover(reason: "no frames >\(Int(CaptureLiveness.stallThreshold))s")
    }
    return .idle
}
