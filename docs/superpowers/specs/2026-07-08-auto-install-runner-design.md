# Auto-install the WebDriverAgent runner on Automation-on

## Problem

When the user flips the **Automation** switch, iMirror brings up the go-ios chain
and launches the WebDriverAgent (WDA) runner on the connected iPhone. The runner
install already happens (`Transport.installRunnerIfMissing`), but it has gaps:

- It runs **once per app launch** (`runnerInstallAttempted` guard), so toggling
  Automation off/on — or plugging in a *different* iPhone — won't re-check.
- It is **silent**: install runs with no progress, and failure only `NSLog`s. The
  user just sees the health dot stay red.
- It gives **no actionable guidance** for the common failure modes, chiefly a
  runner that isn't code-signed for the connected device's UDID.

## Goal

Flipping Automation on checks the runner and installs it if missing, on **every**
toggle, with clear progress and actionable failure messages — reusing the
existing status line + health dot. Provisioning for a brand-new device still
cannot be automated (Apple requires the device be registered and the ipa
re-signed), but the app should say so and point at the fix.

## Decisions (from brainstorming)

- **Trigger:** re-check on every Automation-on. The `ios apps --list` check is
  cheap and only *installs* when the runner is actually absent.
- **Feedback:** reuse the existing status line + health dot (no new overlay).
- **Failure messaging:** best-effort classification of common go-ios errors, with
  a raw-error fallback.
- **Surfacing mechanism:** a callback closure on `Transport`
  (`onRunnerInstall`), mirroring the existing `onWDAUnrecoverable`.
- **Retry:** no auto-loop; toggling Automation off→on retries (messages say so).

## Design

### Types (pure — live in `iMirrorCore`, unit-tested)

```swift
enum RunnerInstall: Equatable {
    case alreadyPresent
    case installed
    case noBundle                       // dev build, no bundled ipa — proceed anyway
    case failed(RunnerInstallError)
}

enum RunnerInstallError: Equatable {
    case notProvisioned(raw: String)    // ipa not signed for this device's UDID
    case deviceLocked(raw: String)
    case other(raw: String)
}

enum RunnerInstallEvent: Equatable {
    case checking
    case installing
    case done(RunnerInstall)
}

/// Map go-ios `install` stderr to a classified error. Pure + testable.
func classifyInstallError(_ stderr: String) -> RunnerInstallError

/// Whether runwda should be spawned given the install result. Absent-and-failed
/// short-circuits (runwda would only fail-loop); everything else proceeds.
func shouldSpawnRunwda(after result: RunnerInstall) -> Bool
```

`classifyInstallError` matches case-insensitive substrings:
- provisioning / eligibility / "not eligible" / "no profile" / "0xe8008015"-style
  signing errors → `.notProvisioned`
- "locked" / "passcode" / "unlock" → `.deviceLocked`
- otherwise → `.other(raw:)` (raw trimmed/capped to a sane length)

`shouldSpawnRunwda`: `true` for `.alreadyPresent`, `.installed`, `.noBundle`;
`false` for `.failed`.

### Transport changes

- Remove the `runnerInstallAttempted` once-per-launch guard.
- `installRunnerIfMissing(bin:) -> RunnerInstall` now **returns** a result and
  emits events via `onRunnerInstall`:
  - emit `.checking`; if `apps --list` shows the runner → return `.alreadyPresent`
  - no bundled ipa → return `.noBundle`
  - else emit `.installing`, shell `ios install`; on success → `.installed`;
    on `CalledProcessError`/failure → `.failed(classifyInstallError(stderr))`
  - always emit `.done(result)` before returning
- `onRunnerInstall: ((RunnerInstallEvent) -> Void)?` — invoked on the main thread.
- In `startChildren`, after `installDone.wait()`, read the stored result and only
  spawn runwda/forward when `shouldSpawnRunwda(after:)` is true; re-check
  `chainGeneration` after the (possibly slow) install.

### AppDelegate changes

Set `transport.onRunnerInstall` next to `onWDAUnrecoverable`. All handlers guard
on `automationEnabled` (a late callback after the user turns Automation off must
not clobber the "mirror only" status). Event → UI:

| Event | Status line | Health |
|---|---|---|
| `.checking` | "Checking WebDriverAgent on iPhone…" | connecting |
| `.installing` | "Installing WebDriverAgent on iPhone… (first time can take ~30s)" | connecting |
| `.done(.installed)` | "WebDriverAgent installed — starting…" | connecting |
| `.done(.alreadyPresent)` / `.done(.noBundle)` | *(no change)* | unchanged |
| `.done(.failed(.notProvisioned))` | "Couldn't install WebDriverAgent — it isn't signed for this iPhone. Re-sign it for this device: WDA_DESTINATION=<udid> ./scripts/build-wda.sh" | down |
| `.done(.failed(.deviceLocked))` | "Unlock your iPhone, then turn Automation off and on to retry." | down |
| `.done(.failed(.other))` | "WebDriverAgent install failed: <raw error>" | down |

Refine the existing `onWDAUnrecoverable` message (post-install, runner won't
launch) to mention trust: "WebDriverAgent installed but won't start — trust the
developer on the phone: Settings ▸ General ▸ VPN & Device Management."

### Error handling / lifecycle

- Install runs on the existing background bring-up thread; only the callback hops
  to main. The `installDone` semaphore always signals (result stored first), so
  the bring-up thread can't hang on failure.
- `chainGeneration` re-checked after install so a stop/restart mid-install can't
  spawn a stale runwda.

## Testing

Pure logic in `iMirrorCore`, covered in `CoreTests` (no device needed, matching
the `WDAParsing`/`Geometry` split):
- `classifyInstallError`: provisioning/eligibility sample → `.notProvisioned`;
  locked/passcode sample → `.deviceLocked`; unknown → `.other`; plus real go-ios
  stderr samples.
- `shouldSpawnRunwda`: true for present/installed/noBundle, false for failed.

`Transport`'s process spawning stays untested (as the rest of it is).

## Out of scope (YAGNI)

- No Settings "Install runner" button (toggle-only retry).
- No auto-retry loop on failure.
- No install progress percentage (go-ios `install` exposes no reliable stream).
- No confirmation prompt (flipping Automation is the consent — current behavior).
