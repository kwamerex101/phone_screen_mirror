# Design: iOS Simulator support — Phase 2 (packaged app)

Date: 2026-07-11
Status: Approved design basis (Phase 1 spec's "Phase 2" section) — refined for implementation

## Summary

Phase 1 shipped in-app iOS Simulator support that works **only from a source
checkout**: `SimulatorController` finds `scripts/sim-wda-up.sh` and
`tools/WebDriverAgent` via `#filePath` (the repo). A packaged, notarized
`iMirror.app` has neither, so the "iOS Simulator" section can't bring WDA up.

Phase 2 makes it work in the **packaged app** by bundling the WDA source and the
bring-up script into `iMirror.app`, and — because a bundle is read-only —
**staging** them into a writable Application Support directory on first use, then
running the already-proven `sim-wda-up.sh` from that stage exactly like a dev
checkout. No native re-implementation of the Xcode build; no changes to the
script's internals.

## Goals

- The "iOS Simulator" Enable flow works from an installed `iMirror.app` (with
  Xcode present), not just a source checkout.
- Reuse `scripts/sim-wda-up.sh` unchanged — it is already verified end-to-end.
- Incremental builds persist (fast subsequent Enables); re-stage only when the
  app updates.
- Keep the dev-checkout path behaving exactly as in Phase 1.

## Non-goals

- Re-implementing WDA's build/brand/sign natively in Swift. The script does it.
- Supporting simulators without Xcode (unchanged from Phase 1 — Xcode-gated).
- Shipping prebuilt WDA runner products (toolchain-coupled; we build from source
  with the user's Xcode, as decided in Phase 1).

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| How the packaged app gets WDA | **Bundle source + script**, `package.sh` copies them into `Contents/Resources/` preserving the `tools/` + `scripts/` layout | The script's `$ROOT`-relative reads then resolve unchanged |
| Read-only bundle | **Stage** the bundled `tools/`+`scripts/` into `~/Library/Application Support/iMirror/wda-stage/` once, run the script from there | The script writes into `$ROOT/build/…`; a writable stage makes it behave like a dev checkout — zero script changes |
| Caching | The stage's `build/wda-sim-derived` persists → **incremental builds for free**; re-stage only when the app build changes | Simple, robust; no bespoke cache-key logic |
| Stage freshness | A marker file records the app's `CFBundleVersion`; re-stage when it differs | Handles app updates that ship new WDA source |
| Script | **Unchanged** | Already proven; keeps the two paths identical |

## Architecture

### 1. Bundling (`scripts/package.sh`)

Add to the packaged `Contents/Resources/`:
- `tools/WebDriverAgent/` — the WDA Xcode project + sources (tens of MB).
- `scripts/sim-wda-up.sh` and `scripts/make_ios_icon.swift` — the bring-up script
  and the icon generator it invokes (`$ROOT/scripts/make_ios_icon.swift`).

Layout under Resources mirrors the repo (`Resources/tools/WebDriverAgent`,
`Resources/scripts/…`) so that a staged copy's `$ROOT`-relative paths — `WDA_PROJECT`
default `$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj`, the icon script at
`$ROOT/scripts/make_ios_icon.swift`, and the writable `$ROOT/build/…` — all resolve.

These are inert source/script files; they seal into the app signature normally
(no separate signing, no notarization impact).

### 2. Staging (`SimulatorController`, new pure + app pieces)

- **`stageDirURL`** — `~/Library/Application Support/iMirror/wda-stage/`.
- **`bundledResourcesURL()`** — `Bundle.main.resourceURL` (packaged) that contains
  `tools/` + `scripts/`.
- **`ensureStaged() -> URL?`** — returns the directory to run the script from:
  1. **Dev checkout** (repo `scripts/sim-wda-up.sh` resolvable via `#filePath`):
     return the repo root — Phase 1 behavior, no staging.
  2. **Packaged**: if `wda-stage/` is missing or its marker ≠ current app
     `CFBundleVersion`, copy `Resources/tools` + `Resources/scripts` into
     `wda-stage/` and write the marker. Return `wda-stage/`.
- **`scriptURL()` / `wdaProjectURL()`** resolve against the value `ensureStaged()`
  returns (`<root>/scripts/sim-wda-up.sh`, `<root>/tools/WebDriverAgent/…`).
- **Pure, unit-tested helper** in `iMirrorCore`: `stageIsCurrent(marker: String?,
  appBuild: String) -> Bool` — the marker/version comparison (the only branch worth
  a test). The copy itself is app-target, build-verified + manual.

The first Enable in a packaged app: stage copy (~seconds) → build (~2–3 min, shown
as "Building…") → ready. Subsequent Enables reuse the stage and its incremental
DerivedData → fast.

### 3. Enable flow (unchanged shape)

`enable(udid:)` → `ensureStaged()` → run `<root>/scripts/sim-wda-up.sh` with
`PORT=8201`, `WDA_PROJECT=<root>/tools/WebDriverAgent/WebDriverAgent.xcodeproj`,
supervised by `ManagedProcess` → poll `:8201/status`. Exactly Phase 1, only the
`<root>` source changes.

## Data flow

```
Enable → ensureStaged()
          ├─ dev checkout → repo root (no copy)
          └─ packaged → copy bundled tools/+scripts/ to wda-stage/ (if marker stale)
       → run <root>/scripts/sim-wda-up.sh (PORT=8201, WDA_PROJECT=<root>/…)
       → build (incremental via <root>/build/wda-sim-derived) → brand → test-without-building
       → poll :8201/status → ready
```

## Error handling

- **No Xcode** → unchanged: section disabled, "Requires Xcode."
- **No bundled resources and no dev checkout** (shouldn't happen in a real build)
  → `enable` reports a clear "simulator support not available in this build."
- **Stage copy fails** (disk full / permissions) → surface the error in the status
  label; do not silently fall back.
- **Build failure** → surfaced by the script/`ManagedProcess` as today.
- Ports unchanged: sim 8201, device 8100.

## Testing

- **Unit (iMirrorCore):** `stageIsCurrent(marker:appBuild:)` — fresh stage, matching
  marker, stale marker, nil marker.
- **App target (build-verified + manual):** staging copy, resolver fallback,
  `package.sh` bundling.
- **End-to-end (manual on a Mac with Xcode):** run `package.sh`, launch the packaged
  `iMirror.app` **from `/Applications`** (not the repo), Enable a sim, confirm WDA
  reaches `:8201` and an agent can drive it — proving the no-checkout path.

## Risks

- **App size**: bundling WDA source adds tens of MB. Accepted (documented in Phase 1).
- **Read-only source build**: avoided entirely by staging to a writable copy before
  building.
- **Stage staleness across app updates**: handled by the `CFBundleVersion` marker.
- **First-run latency**: ~2–3 min build on first Enable per app version; surfaced in
  the status label, not silent.

## Rollout

Single plan. First task is a **spike**: stage the repo's `tools/`+`scripts/` into a
throwaway writable dir and run the script from there on `:8201`, proving a relocated
(non-repo) stage builds and serves WDA — before touching `package.sh` or the app.
