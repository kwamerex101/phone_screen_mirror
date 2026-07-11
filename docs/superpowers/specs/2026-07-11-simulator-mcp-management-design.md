# Design: In-app iOS Simulator + MCP management

Date: 2026-07-11
Status: Approved (design) — pending implementation plan

## Summary

iMirror today mirrors and drives a **physical** iPhone: the app brings up
WebDriverAgent (WDA) over a self-managed go-ios transport, and a Settings section
one-click-registers the `imirror` MCP server so an agent (Claude) can drive the
phone.

This feature adds a parallel path for an **iOS Simulator**. From a new Settings
section the user picks a simulator, and iMirror boots it, brings up WDA on the
sim, and registers a dedicated `imirror-sim` MCP server. The user views and
interacts with the simulator through Apple's own `Simulator.app` and through the
MCP/Claude — iMirror does **not** render the sim's pixels in its own window.

The work is **phased**:

- **Phase 1 (dev checkout):** the MCP `imirror-sim` profile, the sim picker, the
  Enable toggle, and WDA bring-up built from the repo's `tools/WebDriverAgent`.
  Fully usable when iMirror runs from a source checkout.
- **Phase 2 (packaged app):** bundle the WDA source into `iMirror.app`, build it
  once with the user's Xcode into a cached DerivedData, brand/re-sign it. Makes
  the feature work in an installed, notarized app.

## Goals

- A Settings "iOS Simulator" section that mirrors the existing device MCP UX:
  pick a sim, Enable, and Install/Uninstall the MCP server.
- Reuse the app's existing supervision (`ManagedProcess`) and MCP-registration
  machinery rather than duplicating them.
- Let the device (`imirror`, WDA on `127.0.0.1:8100`) and simulator
  (`imirror-sim`, WDA on `127.0.0.1:8101`) coexist.
- Keep everything testable at the pure-helper layer (no device/sim/Xcode needed
  for unit tests).

## Non-goals

- Rendering the simulator's screen inside the iMirror window. The sim has its own
  window; iMirror only manages lifecycle + MCP and shows status.
- Supporting simulators without Xcode. iOS simulators only exist with full Xcode
  installed, and `xcodebuild` (required to launch an XCUITest runner) ships with
  it; the feature is gated on Xcode presence.
- Shipping prebuilt WDA runner products. Prebuilt runners are coupled to the exact
  toolchain they were built against (the `lib_TestingInterop.dylib` load failure).
  We build from source with the user's Xcode instead.

## Key decisions (from brainstorming)

| Decision | Choice | Why |
|---|---|---|
| WDA source | Bundle WDA **source**, build with the user's Xcode, cache | No Xcode-version coupling; independent of the dev `tools/` checkout |
| Visual scope | **Manage only** — view via Simulator.app | The sim already has a good window; a second capture/render path is out of scope |
| Sim selection | **Picker** in Settings (`simctl list`) | Explicit control when several sims exist |
| Orchestration | **Native `SimulatorController`** (Approach A) | Matches how the app already supervises go-ios; real status/restart |
| Rollout | **Phased** (dev checkout → packaged) | A working sim path fast, then hardening |
| Port | Sim WDA on **8101** (device stays 8100) | Device and sim can be enabled together |

## Architecture

Three units, each independently understandable and testable:

### 1. `MCPInstaller.Profile`

Parameterize the existing installer by a small value type instead of a single
hard-coded `serverName`:

```
struct Profile {
    let serverName: String        // "imirror" | "imirror-sim"
    let env: [String: String]     // [:] | [IMIRROR_TARGET: simulator, IMIRROR_WDA: ...8101]
    static let device    = Profile(serverName: "imirror", env: [:])
    static let simulator = Profile(serverName: "imirror-sim",
        env: ["IMIRROR_TARGET": "simulator",
              "IMIRROR_WDA": "http://127.0.0.1:8101"])
}
```

- `install(profile:update:progress:completion:)`, `uninstall(profile:)`,
  `status(profile:)` all take a profile (default `.device` to preserve existing
  call sites). The venv/deps step is shared and unchanged; only registration
  varies by profile.
- **Claude Code:** `claude mcp add <name> --scope user -e K=V … -- <python> <script>`.
- **Claude Desktop:** `MCPConfig.merged(into:name:command:args:env:)` — the `env`
  parameter already exists.
- **Staleness:** `status(profile:)` must also detect a stale/missing `env`, not
  just a stale script path. Add `MCPConfig.entryEnv(_:name:) -> [String:String]`
  for the Desktop config, and for Claude Code verify the `claude mcp get` output
  contains each expected `K=V` pair.

The two profiles register two independent servers; the device path is byte-for-byte
unchanged in behavior.

### 2. `SimulatorController` (new, `Sources/iMirror/`)

Owns the sim + WDA lifecycle. Pure helpers are separated from process side effects
so they unit-test without a sim.

State machine surfaced to the UI via a callback:

```
enum State { case idle, booting, building, starting, ready, failed(String) }
```

Responsibilities:

- `listSimulators() -> [Simulator]` — parse `xcrun simctl list devices available -j`
  (JSON) into `{udid, name, runtime, isBooted}`. **Pure/testable** given canned JSON.
- `boot(udid)` — `xcrun simctl boot <udid>` (no-op if booted) + `open -a Simulator`.
- `bringUpWDA(udid, port: 8101)`:
  - **ensure-built** (see §Build): produce a branded, signed sim runner (cached).
  - spawn `xcodebuild test-without-building` as a **supervised** `ManagedProcess`
    (reuse Transport.swift), with `TEST_RUNNER_USE_PORT=<port>` in the process
    **environment** (not a build setting — build-setting form is ignored).
  - poll `http://127.0.0.1:<port>/status` until `value.ready == true`.
- `stop()` — terminate the supervised runner.
- `xcodeAvailable() -> Bool` — `xcodebuild -version` succeeds (full Xcode, not just
  Command Line Tools). Gates the whole feature.

Port is fixed at **8101** for the sim so it never collides with the device relay
on 8100.

### 3. Settings "iOS Simulator" section (`Sources/iMirror/main.swift`)

A new section in the Settings popover, below the device MCP section:

- **Picker** (`NSPopUpButton`) of available simulators, refreshed on open.
- **Enable / Disable** control — boots the chosen sim and brings up WDA (or tears
  it down). Reflects `SimulatorController.State` in a status label (booting →
  building → starting → ready / failed).
- **MCP Install / Uninstall** buttons for `Profile.simulator`, reusing the same
  handlers as the device section.

The existing device MCP-section UI is lightly refactored into a profile-parameterized
builder (a small helper that creates button/uninstall/spinner/status for a given
`Profile` and wires them to `install/uninstall/status`), so both sections share
one implementation instead of duplicating ~60 lines.

When `xcodeAvailable()` is false, the section is present but disabled with a
"Requires Xcode" note.

## Build & bundling (Phase 2 detail)

Mirrors `scripts/sim-wda-up.sh` and `scripts/build-wda.sh`, moved in-process:

- **Source resolution** `wdaProjectURL()` — prefer the repo `tools/WebDriverAgent`
  (dev), else the copy bundled at `iMirror.app/Contents/Resources/WebDriverAgent`.
  Parallels the existing `MCPInstaller.scriptURL()`.
- **`package.sh`** copies the WDA source project into `Contents/Resources/WebDriverAgent`
  (Phase 2). Adds tens of MB to the app.
- **Build** `xcodebuild build-for-testing` into a writable DerivedData under
  `~/Library/Application Support/iMirror/wda-sim-derived`, with the accommodations
  from `build-wda.sh`: `CODE_SIGNING_ALLOWED=NO`, `GCC_TREAT_WARNINGS_AS_ERRORS=NO`,
  `PRODUCT_BUNDLE_IDENTIFIER=com.local.imirror.WebDriverAgentRunner`. Never set
  `PRODUCT_NAME`.
- **Brand + sign** the runner: iMirror icon (bundled `make_ios_icon.swift` + actool
  `--platform iphonesimulator`), `CFBundleDisplayName=iMirror`, then ad-hoc
  `codesign --sign -` (sims need no team). Matches the on-device rebrand.
- **Cache** keyed on `xcodebuild -version` + a hash of the WDA source, so a rebuild
  only happens on an Xcode upgrade or a WDA bump. First enable ≈ 2–3 min (progress
  surfaced in the status label); cached thereafter.

Building with the user's Xcode is what avoids the `lib_TestingInterop.dylib`
version-coupling crash seen with prebuilt runners.

## Data flow

```
pick sim → Enable
  → SimulatorController.boot(udid)
  → ensure WDA built (cache hit → skip)
  → supervised `xcodebuild test-without-building` (TEST_RUNNER_USE_PORT=8101)
  → poll 127.0.0.1:8101/status == ready
→ Install MCP (Profile.simulator → registers imirror-sim @ 8101)
→ drive via Claude (mcp__imirror-sim__*) + view in Simulator.app
```

## Error handling

- **No full Xcode** → section disabled, "Requires Xcode."
- **Build failure** → surface the first real error line (reuse
  `MCPInstaller.firstError`) in the status label.
- **WDA process dies** (Xcode update, runtime mismatch, sim shutdown) →
  `ManagedProcess` restarts it; the state machine returns to `starting`/`failed`
  and the UI reflects it. The 404-session-recreate logic in the MCP server cannot
  resurrect a dead WDA, so supervision lives here.
- **Standalone runner launch** → the branded iMirror runner on the sim is a test
  runner; launching it by tapping its icon crashes (`lib_TestingInterop.dylib`).
  The status/help text notes this; only the controller launches it via xcodebuild.
- **Port** → sim fixed at 8101, device at 8100; no collision when both are on.

## Testing

Pure, no device/sim/Xcode required:

- `simctl` JSON → `[Simulator]` parsing (canned JSON fixtures).
- `MCPConfig` `env` merge + round-trip, and `entryEnv` extraction.
- Build cache-key computation (given a fixed Xcode version string + source hash).
- `xcodebuild`/`TEST_RUNNER_USE_PORT` argument construction.
- `Profile` env for `.device` vs `.simulator`, and profile-aware
  `install/uninstall/status` registration (mirrors existing `MCPInstaller` tests).

Integration/manual (documented, like the go-ios path): the real Xcode build, the
supervised `test-without-building` process, and end-to-end MCP drive.

## Risks & open questions

- **Size:** bundling WDA source materially grows the app (Phase 2).
- **First-run latency:** ~2–3 min build on first enable; must be clearly surfaced,
  not look hung.
- **Xcode-version drift:** handled by building with the user's Xcode + cache
  invalidation on version change.
- **Notarization:** bundled WDA source is inert source files; the in-app build
  writes only to Application Support. iMirror is not sandboxed, so spawning
  `xcodebuild`/`simctl` is permitted (it already spawns go-ios).
- **Open:** exact UI affordance for "Enable" (toggle vs button) — settle during
  the implementation plan; both map to the same controller calls.

## Rollout

1. **Phase 1** — `Profile` plumbing, picker, Enable, dev-checkout bring-up,
   `imirror-sim` registration. Usable from a source checkout immediately.
2. **Phase 2** — bundle WDA source, in-app cached build + branding/sign, Xcode-gate
   polish. Makes it work in the packaged app.
