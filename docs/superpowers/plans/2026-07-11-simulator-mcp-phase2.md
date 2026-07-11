# iOS Simulator + MCP Management — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the "iOS Simulator" Enable flow work in a **packaged** `iMirror.app` (no source checkout), by bundling the WDA source + `sim-wda-up.sh` and staging them into a writable dir the proven script runs from.

**Architecture:** `package.sh` copies `tools/WebDriverAgent` + `scripts/{sim-wda-up.sh,make_ios_icon.swift}` into `Contents/Resources/` (mirroring the repo layout). `SimulatorController.resolvedRoot()` returns the repo root when running from a checkout (Phase 1 behavior) or, in a packaged app, stages the bundled copy into `~/Library/Application Support/iMirror/wda-stage/` (once per app build) and returns that. The script and its `$ROOT`-relative paths (WDA_PROJECT, the icon script, the writable `build/` DerivedData) then resolve unchanged. A spike already proved a relocated stage builds WDA and serves `:8201`.

**Tech Stack:** Swift 6 package (`swift build`/`swift test`), AppKit, XCTest, `bash`, `xcodebuild`.

## Global Constraints

- Swift tools 6.0; macOS 14+; language mode v5. Only `iMirrorCore` is unit-tested — never add a test target for `iMirror`.
- Simulator WDA is loopback `http://127.0.0.1:8201` (`SimulatorController.port == 8201`); device stays 8100. Never widen a host.
- Do NOT modify `scripts/sim-wda-up.sh` — it is already proven and must stay identical for the dev and packaged paths.
- The dev-checkout Enable path (Phase 1) must behave exactly as before.
- Staging dir: `~/Library/Application Support/iMirror/wda-stage/`; freshness keyed on the app's `CFBundleVersion` via a `.app-build` marker file.
- No new third-party dependencies. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

**Create:**
- `Sources/iMirrorCore/StageMarker.swift` — pure `StageMarker.isCurrent(marker:appBuild:)`.

**Modify:**
- `Sources/iMirror/SimulatorController.swift` — add `resolvedRoot()`/staging; wire `enable()` to it.
- `scripts/package.sh` — bundle WDA source + the two scripts.
- `Tests/iMirrorCoreTests/CoreTests.swift` — tests for `StageMarker`.

---

## Task 1: `StageMarker.isCurrent` (pure staleness check)

**Files:**
- Create: `Sources/iMirrorCore/StageMarker.swift`
- Test: `Tests/iMirrorCoreTests/CoreTests.swift`

**Interfaces:**
- Produces: `public enum StageMarker { public static func isCurrent(marker: String?, appBuild: String) -> Bool }` — true only when a non-nil `marker` equals `appBuild`.

- [ ] **Step 1: Write the failing tests** — add a new class at the end of `Tests/iMirrorCoreTests/CoreTests.swift`:

```swift
final class StageMarkerTests: XCTestCase {
    func testCurrentWhenMarkerMatches() {
        XCTAssertTrue(StageMarker.isCurrent(marker: "20260708", appBuild: "20260708"))
    }
    func testStaleWhenMarkerDiffers() {
        XCTAssertFalse(StageMarker.isCurrent(marker: "20260101", appBuild: "20260708"))
    }
    func testStaleWhenMarkerNil() {
        XCTAssertFalse(StageMarker.isCurrent(marker: nil, appBuild: "20260708"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StageMarkerTests`
Expected: FAIL to build with "cannot find 'StageMarker' in scope".

- [ ] **Step 3: Implement** — create `Sources/iMirrorCore/StageMarker.swift`:

```swift
// Whether a staged copy of the bundled WDA source is current for this app build.
// The stage records the app's CFBundleVersion in a marker file; it is re-staged
// when the app updates. Pure so the freshness rule is unit-testable.

import Foundation

public enum StageMarker {
    /// True only when `marker` is present and equals the current app build.
    public static func isCurrent(marker: String?, appBuild: String) -> Bool {
        marker == appBuild
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StageMarkerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/iMirrorCore/StageMarker.swift Tests/iMirrorCoreTests/CoreTests.swift
git commit -m "feat(core): StageMarker.isCurrent for WDA stage freshness

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `SimulatorController` staging (bundled → writable stage)

**Files:**
- Modify: `Sources/iMirror/SimulatorController.swift`

**Interfaces:**
- Consumes: `StageMarker.isCurrent` (Task 1); existing `ManagedProcess`, `shellEscape`, `emit`, `queue`, `port`.
- Produces: unchanged public surface (`enable(udid:)`, `disable()`, `onState`, `xcodeAvailable()`, `listSimulators()`). Internally, `enable` now sources the script/project from `resolvedRoot()` (repo checkout or staged bundle) instead of the repo-only resolvers.

**Note:** app target, no unit tests. Verify with `swift build` + `swift test` (regression) + the manual note below.

- [ ] **Step 1: Update the file-header comment**

In `Sources/iMirror/SimulatorController.swift`, replace the Phase-1 line in the top comment:

```swift
// to scripts/sim-wda-up.sh (present in a source checkout) and supervises it with
// ManagedProcess; Phase 2 will build in-process from bundled source. Viewing is via
```

with:

```swift
// to scripts/sim-wda-up.sh and supervises it with ManagedProcess. The script comes
// from the repo checkout (dev) or a copy of the app's bundled tools/+scripts/ staged
// into Application Support (packaged). Viewing is via
```

- [ ] **Step 2: Replace the two repo-only resolvers with staging**

Replace the `scriptURL()` and `wdaProjectURL()` methods (the block from `/// Repo `scripts/sim-wda-up.sh`` through the end of `wdaProjectURL()`) with:

```swift
    private var stageDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror/wda-stage", isDirectory: true)
    }

    /// The directory to run `scripts/sim-wda-up.sh` from: the repo checkout when
    /// running from source (Phase 1 behavior), otherwise a staged copy of the app's
    /// bundled `tools/`+`scripts/`. Returns nil when neither is available. Runs on
    /// `queue` (the stage copy can take a moment); never on the main thread.
    private func resolvedRoot() -> URL? {
        let fm = FileManager.default
        // 1. Dev checkout — the repo tree next to this source file.
        let repo = URL(fileURLWithPath: #filePath)          // Sources/iMirror/SimulatorController.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if fm.fileExists(atPath: repo.appendingPathComponent("scripts/sim-wda-up.sh").path) {
            return repo
        }
        // 2. Packaged — stage the bundled copy into a writable dir, once per app build.
        guard let res = Bundle.main.resourceURL,
              fm.fileExists(atPath: res.appendingPathComponent("scripts/sim-wda-up.sh").path)
        else { return nil }
        return stageBundledResources(from: res)
    }

    /// Copy the bundled `tools/`+`scripts/` into `stageDir` when missing or stale
    /// (marker != current app build), then return `stageDir`. nil on copy failure.
    private func stageBundledResources(from res: URL) -> URL? {
        let fm = FileManager.default
        let dir = stageDir
        let marker = dir.appendingPathComponent(".app-build")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let current = try? String(contentsOf: marker, encoding: .utf8)
        let present = fm.fileExists(atPath: dir.appendingPathComponent("scripts/sim-wda-up.sh").path)
        if !present || !StageMarker.isCurrent(marker: current, appBuild: build) {
            try? fm.removeItem(at: dir)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: res.appendingPathComponent("tools"),
                                to: dir.appendingPathComponent("tools"))
                try fm.copyItem(at: res.appendingPathComponent("scripts"),
                                to: dir.appendingPathComponent("scripts"))
                try build.write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return dir
    }
```

- [ ] **Step 3: Wire `enable(udid:)` to `resolvedRoot()`**

In `enable(udid:)`, replace this block:

```swift
            guard self.xcodeAvailable() else { return self.emit(.failed("Requires Xcode.")) }
            guard let script = self.scriptURL(), let proj = self.wdaProjectURL() else {
                return self.emit(.failed("Simulator bring-up needs a source checkout (Phase 1)."))
            }
```

with:

```swift
            guard self.xcodeAvailable() else { return self.emit(.failed("Requires Xcode.")) }
            guard let root = self.resolvedRoot() else {
                return self.emit(.failed("Simulator support isn't available in this build."))
            }
            let script = root.appendingPathComponent("scripts/sim-wda-up.sh")
            let proj = root.appendingPathComponent("tools/WebDriverAgent/WebDriverAgent.xcodeproj")
```

The rest of `enable` (the `cmd` string using `script.path` / `proj.path`, `ManagedProcess`, polling) is unchanged — `script` and `proj` are now `URL`s from `root`, and `.path` on them works exactly as before.

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Regression tests**

Run: `swift test`
Expected: all tests pass (Task 1's additions + the pre-existing suite).

- [ ] **Step 6: Manual note (human, needs the packaged app)**

The packaged-path behavior is verified end-to-end after Task 3 by running `package.sh` and launching the app from `/Applications`. From a **source checkout**, `resolvedRoot()` returns the repo and Enable behaves exactly as in Phase 1 (no staging) — confirm by running the app from source and clicking Enable (WDA reaches `:8201`).

- [ ] **Step 7: Commit**

```bash
git add Sources/iMirror/SimulatorController.swift
git commit -m "feat(app): stage bundled WDA source so sim Enable works in packaged app

resolvedRoot() returns the repo checkout (dev) or a copy of the bundled
tools/+scripts/ staged into Application Support (packaged, re-staged per app
build). The proven sim-wda-up.sh runs from there unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `package.sh` bundles the WDA source + scripts

**Files:**
- Modify: `scripts/package.sh`

**Interfaces:**
- Produces: a packaged `iMirror.app/Contents/Resources/` that additionally contains `tools/WebDriverAgent/…` and `scripts/{sim-wda-up.sh,make_ios_icon.swift}`, so `SimulatorController.stageBundledResources` (Task 2) can stage them.

- [ ] **Step 1: Add the bundling step**

In `scripts/package.sh`, immediately after the license-notices block (the two `cp "$ROOT/tools/…/LICENSE" …` lines ending the block around line 55), insert:

```bash
# Bundle the WDA source + sim bring-up script so the "iOS Simulator" Enable flow
# works from a packaged app (SimulatorController stages these into Application
# Support and runs sim-wda-up.sh from there). Mirrors the repo layout so the
# script's $ROOT-relative paths resolve. Only present when the source is vendored.
if [[ -d "$ROOT/tools/WebDriverAgent" ]]; then
    echo "==> bundling WDA source + sim scripts (for in-app simulator build)"
    mkdir -p "$APP/Contents/Resources/tools" "$APP/Contents/Resources/scripts"
    cp -R "$ROOT/tools/WebDriverAgent" "$APP/Contents/Resources/tools/WebDriverAgent"
    cp "$ROOT/scripts/sim-wda-up.sh"      "$APP/Contents/Resources/scripts/"
    cp "$ROOT/scripts/make_ios_icon.swift" "$APP/Contents/Resources/scripts/"
fi
```

- [ ] **Step 2: Verify the bundling (no full sign/notarize needed)**

Run a build + assemble far enough to inspect the Resources. Since `package.sh` signs and builds a DMG, just run it and inspect (ad-hoc signing is fine locally):

Run:
```bash
./scripts/package.sh >/tmp/pkg.log 2>&1; tail -3 /tmp/pkg.log
ls build/iMirror.app/Contents/Resources/scripts/
test -e build/iMirror.app/Contents/Resources/tools/WebDriverAgent/WebDriverAgent.xcodeproj && echo "WDA project bundled ✓"
```
Expected: `sim-wda-up.sh` and `make_ios_icon.swift` listed; "WDA project bundled ✓".

- [ ] **Step 3: Commit**

```bash
git add scripts/package.sh
git commit -m "build(package): bundle WDA source + sim scripts into iMirror.app

Lets the packaged app stage them and run sim-wda-up.sh, so the iOS Simulator
Enable flow works without a source checkout.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (human / controller, on a Mac with Xcode)

The true end-to-end — proving the no-checkout path:

1. `./scripts/package.sh` (ad-hoc is fine) → `build/iMirror.app`.
2. Copy it OUT of the repo so `#filePath`'s repo check fails and the staging path is exercised: `cp -R build/iMirror.app /Applications/` (or any non-repo dir).
3. Launch that copy, open Settings → **iOS Simulator**, pick a sim, **Enable**.
4. Expect: status walks `Booting → Building (first run) → Starting → WebDriverAgent ready on :8201 ✓`, and `~/Library/Application Support/iMirror/wda-stage/` now holds the staged `tools/`+`scripts/`+`build/`.
5. Drive it via the `imirror-sim` MCP to confirm.

---

## Self-Review

**Spec coverage:** bundling (Task 3), staging + resolver fallback (Task 2), pure freshness check (Task 1), unchanged script (no task touches it), unchanged dev path (Task 2 returns repo root first), 8201 (unchanged), Xcode gate (unchanged). ✓

**Placeholder scan:** every code step is complete; commands have expected output; the manual/final verification steps are explicitly human/controller-run (the app target has no test harness). No TBD/TODO.

**Type consistency:** `StageMarker.isCurrent(marker:appBuild:)` matches between Task 1 and its call in Task 2. `resolvedRoot()`/`stageBundledResources(from:)`/`stageDir` are internal to `SimulatorController`; `enable` uses `root.appendingPathComponent(...)` → `URL`, and the existing `cmd` uses `.path` on them — consistent with the pre-existing `script.path`/`proj.path` usage. `package.sh` uses the existing `$APP`/`$ROOT` variables.
