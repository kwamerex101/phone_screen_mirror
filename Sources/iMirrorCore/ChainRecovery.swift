import Foundation

/// Pure decision logic for the app-level WDA recovery ladder (`main.swift`'s
/// `runWatchdog`) and the MJPEG partial-wedge watchdog. `ManagedProcess`
/// (see `ManagedProcessLiveness.swift`) already recovers a wedged `runwda` on
/// its own by killing it past a readiness deadline; these functions cover
/// what's above that: what to do when runwda's own respawns still aren't
/// bringing WDA back, and what to do when the WDA HTTP session is healthy but
/// the MJPEG video stream has gone quiet.

/// What the chain-level watchdog should do about a WDA outage.
public enum ChainRecoveryAction: Equatable {
    /// Still within grace — a `ManagedProcess` readiness cycle may still recover it.
    case wait
    /// One readiness cycle wasn't enough; tear down and rebuild the whole chain.
    case restartChain
    /// A full chain restart wasn't enough either — this isn't self-healing.
    /// Stop retrying automatically until the user explicitly asks again.
    case giveUp
}

/// `downForSec` is measured on a monotonic clock since automation turned on
/// or since the last `restartChain`. `stage` is 0 before any restart has been
/// attempted for this outage, 1 after one `restartChain`. `graceSec` is how
/// long each stage gets before escalating — long enough to cover one
/// `ManagedProcess` readiness cycle plus WDA's own boot time.
public func nextChainRecoveryAction(downForSec: TimeInterval, stage: Int, graceSec: TimeInterval) -> ChainRecoveryAction {
    guard downForSec >= graceSec else { return .wait }
    return stage <= 0 ? .restartChain : .giveUp
}

/// What the MJPEG partial-wedge watchdog should do. WDA's `/status` can stay
/// healthy while its MJPEG stream has silently died, so `health == .connected`
/// alone doesn't guarantee frames are actually arriving.
public enum MjpegRecoveryAction: Equatable {
    /// Still within the no-frame threshold — could just be a quiet screen.
    case wait
    /// Past the threshold for the first time: bounce the cheap thing first,
    /// the `forward` child carrying the MJPEG port.
    case bounceForward
    /// Still no frames after the bounce: this is more than a dropped forward
    /// socket — escalate to a full chain-level recovery.
    case escalate
}

/// `noFrameForSec` is how long it's been since the last MJPEG frame arrived,
/// on a monotonic clock. `alreadyBounced` is whether `bounceForward` already
/// fired for this stall. `thresholdSec` is how long to wait before acting.
public func nextMjpegRecoveryAction(noFrameForSec: TimeInterval, alreadyBounced: Bool, thresholdSec: TimeInterval) -> MjpegRecoveryAction {
    guard noFrameForSec >= thresholdSec else { return .wait }
    return alreadyBounced ? .escalate : .bounceForward
}
