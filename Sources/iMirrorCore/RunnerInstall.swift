import Foundation

/// Outcome of checking/installing the WebDriverAgent runner on the device.
public enum RunnerInstall: Equatable {
    case alreadyPresent          // runner already on the device — nothing to do
    case installed               // we just installed the bundled ipa
    case noBundle                // dev build ships no ipa; assume external install
    case failed(RunnerInstallError)
}

/// Why an `ios install` attempt failed, classified from go-ios's stderr so the UI
/// can give guidance specific to the fix.
public enum RunnerInstallError: Equatable {
    case notProvisioned(raw: String)   // ipa isn't code-signed for this device's UDID
    case deviceLocked(raw: String)     // phone is locked / needs the passcode
    case other(raw: String)            // anything we can't confidently classify
}

/// Progress of the runner check/install, emitted to the app so it can reflect
/// state in the status line + health dot.
public enum RunnerInstallEvent: Equatable {
    case checking
    case installing
    case done(RunnerInstall)
}

/// Map go-ios `install` stderr to a classified error. Pure so it's unit-testable
/// without a device. Matching is case-insensitive substring — deliberately loose,
/// since go-ios surfaces the underlying MobileInstallation text which varies by
/// iOS version; unknown text falls back to `.other` with the raw message.
public func classifyInstallError(_ stderr: String) -> RunnerInstallError {
    let raw = trimmedRaw(stderr)
    let s = raw.lowercased()

    // Locked first: a locked device is the most actionable and its wording is
    // distinct ("device locked", "please unlock", "passcode").
    if s.contains("lock") || s.contains("passcode") || s.contains("unlock") {
        return .deviceLocked(raw: raw)
    }
    // Provisioning / code-signing mismatch for this device.
    let provisioningSignals = [
        "provision", "eligible", "not eligible", "entitlement",
        "verification", "applicationverificationfailed",
        "no profile", "0xe8008015", "0xe8008016",
    ]
    if provisioningSignals.contains(where: s.contains) {
        return .notProvisioned(raw: raw)
    }
    return .other(raw: raw)
}

/// Whether runwda should be launched given the install result. A failed install
/// with the runner still absent short-circuits — launching runwda would only
/// fail-loop. Everything else (present, freshly installed, or a dev build with no
/// bundled ipa where the runner may have been installed externally) proceeds.
public func shouldSpawnRunwda(after result: RunnerInstall) -> Bool {
    switch result {
    case .alreadyPresent, .installed, .noBundle:
        return true
    case .failed:
        return false
    }
}

/// Trim whitespace and cap length so a runaway error string can't bloat the UI.
private func trimmedRaw(_ s: String, cap: Int = 300) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count <= cap ? t : String(t.prefix(cap)) + "…"
}
