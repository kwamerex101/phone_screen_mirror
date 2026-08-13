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
    /// Consecutive watchdog ticks (each ~3s in main.swift) with an unchanged frame
    /// fingerprint before the content signal is trusted. A single matching tick is
    /// common noise (a genuinely still screen, a hash coincidence); this is the
    /// outage-vs-blip gate for the content-liveness advisory -- see
    /// `captureWaitingReason`. This never affects `captureWatchdogDecision`.
    public static let staticFrameGate = 3
}

/// Cheap per-tick fingerprint of the latest frame's content, computed once per
/// watchdog tick (not per delivered frame -- see `checkCaptureLiveness` in
/// main.swift for why hashing every buffer in `captureOutput` is too expensive).
public struct FrameFingerprint: Equatable {
    /// Hash of the sampled luma grid. Only meaningful for equality between ticks
    /// within the same process run -- it is never persisted or compared cross-run.
    public let hash: UInt64
    /// The sampled grid's average luma is at or below `FrameContentSampling.nearBlackLumaThreshold`.
    public let nearBlack: Bool

    public init(hash: UInt64, nearBlack: Bool) {
        self.hash = hash
        self.nearBlack = nearBlack
    }
}

/// Pure sampling math: turns already-extracted sampled luma bytes into a
/// `FrameFingerprint`. Deliberately takes plain bytes rather than a live
/// `CVPixelBuffer` so it is testable without a device -- the caller (main.swift)
/// does the `CVPixelBufferLockBaseAddress` / strided-grid extraction and hands the
/// result here.
public enum FrameContentSampling {
    /// Average sampled luma (0-255) at or below this is considered near-black.
    public static let nearBlackLumaThreshold: Int = 16

    /// - Parameter samples: plane-0 luma bytes sampled on a stride grid (e.g. a
    ///   16x16 grid = 256 bytes). Empty input is treated as near-black with a
    ///   fixed zero hash (no data to distinguish frames by).
    public static func fingerprint(samples: [UInt8]) -> FrameFingerprint {
        guard !samples.isEmpty else { return FrameFingerprint(hash: 0, nearBlack: true) }
        var hasher = Hasher()
        var total = 0
        for byte in samples {
            hasher.combine(byte)
            total += Int(byte)
        }
        let hash = UInt64(bitPattern: Int64(hasher.finalize()))
        let average = total / samples.count
        return FrameFingerprint(hash: hash, nearBlack: average <= nearBlackLumaThreshold)
    }
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

    // MARK: Content-liveness advisory fields (I3)
    //
    // These three are ADVISORY ONLY. `captureWatchdogDecision` below never reads
    // them -- recovery and dead-marking stay exactly frame-age-driven. They exist
    // solely to feed `captureWaitingReason`, which only selects which waiting/
    // occluded UI message to show. Defaulted so every existing call site (and
    // every existing test) keeps compiling unchanged.

    /// Consecutive watchdog ticks whose sampled frame fingerprint matched the
    /// previous tick's fingerprint. Reset to 0 by the caller the moment the
    /// fingerprint changes, on rebind, or on `markActive()`.
    public var consecutiveStaticFrames: Int
    /// The most recent tick's sampled frame was near-black (see
    /// `FrameContentSampling.nearBlackLumaThreshold`). This is the current tick's
    /// value only -- unlike `consecutiveStaticFrames` it is not accumulated.
    public var nearBlack: Bool
    /// An `AVCaptureSessionWasInterrupted` with a telephony-relevant reason is
    /// currently active (no matching `InterruptionEnded` yet).
    public var interruptionActive: Bool

    public init(visible: Bool,
                hasInput: Bool,
                sessionRunning: Bool,
                secondsSinceLastFrame: TimeInterval,
                secondsSinceRecoveryStarted: TimeInterval?,
                consecutiveFailedRecoveries: Int,
                consecutiveStaticFrames: Int = 0,
                nearBlack: Bool = false,
                interruptionActive: Bool = false) {
        self.visible = visible
        self.hasInput = hasInput
        self.sessionRunning = sessionRunning
        self.secondsSinceLastFrame = secondsSinceLastFrame
        self.secondsSinceRecoveryStarted = secondsSinceRecoveryStarted
        self.consecutiveFailedRecoveries = consecutiveFailedRecoveries
        self.consecutiveStaticFrames = consecutiveStaticFrames
        self.nearBlack = nearBlack
        self.interruptionActive = interruptionActive
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

/// Which waiting/occluded message the mirror UI should show, if any. ADVISORY
/// ONLY: this is a separate output from `captureWatchdogDecision` and must never
/// be used to trigger recovery or dead-marking -- frame age alone drives that
/// (see the guard test in CoreTests.swift). This only tells the caller which
/// copy to put in the existing waiting overlay.
public enum CaptureWaitingReason: Equatable {
    /// No sustained content stall detected (frames are changing, or too few
    /// static ticks have been seen yet to trust the signal).
    case none
    /// Content has been static for `CaptureLiveness.staticFrameGate` or more
    /// consecutive ticks, corroborated by an active telephony-relevant capture
    /// interruption -- most likely a phone call or a physically occluded camera.
    case callOrOcclusion
    /// Content has been static for `CaptureLiveness.staticFrameGate` or more
    /// consecutive ticks with no corroborating interruption -- a generic stalled
    /// source (e.g. a wedged encoder still delivering the same frame).
    case staticSource
}

/// Decide the advisory waiting-message reason from the same tick's content
/// signal. Pure and separate from `captureWatchdogDecision` by design (see I3 in
/// the improvements plan): the content signal must never be able to change a
/// recover/idle/dead outcome, only which "waiting for video" copy is shown.
///
/// Gates on `consecutiveStaticFrames` alone (the outage-vs-blip rule: one static
/// tick is not enough). `nearBlack` is exposed on the state for callers that want
/// richer copy, but is not required here -- gating on it too would miss a frozen
/// call screen that happens not to be black, and a single near-black tick with
/// otherwise-changing content is not a stall at all.
public func captureWaitingReason(_ s: CaptureWatchdogState) -> CaptureWaitingReason {
    guard s.consecutiveStaticFrames >= CaptureLiveness.staticFrameGate else { return .none }
    return s.interruptionActive ? .callOrOcclusion : .staticSource
}
