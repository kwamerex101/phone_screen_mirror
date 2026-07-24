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
    /// re-enumerated. A rate-limit shorter than that teardown makes the watchdog
    /// re-fire the instant the stream comes back and kill it before the phone
    /// delivers a frame. This must stay comfortably above teardown + first-frame
    /// latency, or the recovery becomes the stall.
    public static let recoveryGrace: TimeInterval = 20
    /// After this many consecutive frameless recoveries, treat the capture source
    /// as dead: the device enumerates and StartStream succeeds, but no app can get
    /// a frame from it (observed when an iPhone's screen-capture endpoint wedges).
    /// iMirror cannot fix that from the Mac side, so it stops pretending to mirror
    /// and tells the user to replug. With recoveryGrace at 20s this lands ~45-50s
    /// after frames stop -- long enough that a transient stall (which heals inside
    /// the grace window and resets the counter) never trips it.
    public static let deadAfterFailedRecoveries = 3
    /// Once the source is declared dead, keep retrying at this slow cadence rather
    /// than thrashing at recoveryGrace. A replug re-inits the endpoint, so a rebind
    /// at this interval heals it on its own -- no app restart, no CPU spin.
    public static let deadRetryInterval: TimeInterval = 60
}

/// Everything the watchdog needs to decide, with no AVFoundation/AppKit types.
public struct CaptureWatchdogState: Equatable {
    public var visible: Bool
    public var hasInput: Bool
    public var sessionRunning: Bool
    public var secondsSinceLastFrame: TimeInterval
    /// Seconds since the last recovery *began*, or nil if none has run yet.
    public var secondsSinceRecoveryStarted: TimeInterval?
    /// Consecutive recoveries that have not yet been followed by a frame. Reset to
    /// 0 by the caller the moment frames flow again.
    public var consecutiveFailedRecoveries: Int

    public init(visible: Bool,
                hasInput: Bool,
                sessionRunning: Bool,
                secondsSinceLastFrame: TimeInterval,
                secondsSinceRecoveryStarted: TimeInterval?,
                consecutiveFailedRecoveries: Int) {
        self.visible = visible
        self.hasInput = hasInput
        self.sessionRunning = sessionRunning
        self.secondsSinceLastFrame = secondsSinceLastFrame
        self.secondsSinceRecoveryStarted = secondsSinceRecoveryStarted
        self.consecutiveFailedRecoveries = consecutiveFailedRecoveries
    }
}

public enum CaptureWatchdogAction: Equatable {
    case idle
    case recover(reason: String)
}

public struct CaptureWatchdogDecision: Equatable {
    /// What the watchdog should do this tick.
    public var action: CaptureWatchdogAction
    /// Frames are flowing right now -- the caller should reset its recovery
    /// counter and restore the live mirror UI.
    public var sourceHealthy: Bool
    /// The source has failed enough recoveries to be treated as dead. This governs
    /// the retry cadence (a dead source rebinds at deadRetryInterval, not the tighter
    /// recoveryGrace) and is asserted by the watchdog tests. The live UI now shows one
    /// unified "waiting for video" overlay for any stall, so the caller no longer
    /// branches on this flag to pick a distinct message.
    public var sourceLikelyDead: Bool

    public init(action: CaptureWatchdogAction, sourceHealthy: Bool, sourceLikelyDead: Bool) {
        self.action = action
        self.sourceHealthy = sourceHealthy
        self.sourceLikelyDead = sourceLikelyDead
    }
}

/// Decide what the capture watchdog should do this tick: leave the stream alone,
/// rebind it, and/or surface a dead-source state. Pure so it can be unit-tested
/// without AVFoundation.
public func captureWatchdogDecision(_ s: CaptureWatchdogState) -> CaptureWatchdogDecision {
    // Hidden window or no bound device: frame delivery is legitimately paused, so
    // never recover and never call the source dead.
    guard s.visible, s.hasInput else {
        return CaptureWatchdogDecision(action: .idle, sourceHealthy: false, sourceLikelyDead: false)
    }
    // Frames flowing -> healthy. The caller resets counters and clears dead UI.
    if s.sessionRunning, s.secondsSinceLastFrame <= CaptureLiveness.stallThreshold {
        return CaptureWatchdogDecision(action: .idle, sourceHealthy: true, sourceLikelyDead: false)
    }
    let dead = s.consecutiveFailedRecoveries >= CaptureLiveness.deadAfterFailedRecoveries
    // A dead source retries slowly (so a replug still heals it) instead of at the
    // tighter live-recovery cadence.
    let grace = dead ? CaptureLiveness.deadRetryInterval : CaptureLiveness.recoveryGrace
    if let since = s.secondsSinceRecoveryStarted, since < grace {
        return CaptureWatchdogDecision(action: .idle, sourceHealthy: false, sourceLikelyDead: dead)
    }
    let reason = s.sessionRunning ? "no frames >\(Int(CaptureLiveness.stallThreshold))s" : "session stopped"
    return CaptureWatchdogDecision(action: .recover(reason: reason), sourceHealthy: false, sourceLikelyDead: dead)
}
