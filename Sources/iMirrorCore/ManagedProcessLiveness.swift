import Foundation

/// Pure readiness-deadline predicate for `ManagedProcess` (Transport.swift).
///
/// `go-ios runwda` can wedge: the process stays alive but WDA never serves, so
/// an exit-only restart never recovers it. `ManagedProcess` polls a caller-supplied
/// readiness check after spawn and, if it never returns true within `readyWithin`,
/// SIGKILLs the child so its existing exit-triggered respawn fires. This function
/// is the boundary decision, kept framework-light so it is unit-testable without
/// spawning a real process.
///
/// - Parameters:
///   - uptime: seconds since this spawn, measured on a monotonic clock (never
///     wall-clock `Date()`, which a Mac sleep can skew).
///   - readySeen: whether the readiness check has already returned true for this spawn.
///   - readyWithin: the deadline in seconds; 0 (or negative) disables the check.
public func managedProcessShouldKillForUnreadiness(uptime: TimeInterval, readySeen: Bool, readyWithin: TimeInterval) -> Bool {
    readyWithin > 0 && !readySeen && uptime >= readyWithin
}
