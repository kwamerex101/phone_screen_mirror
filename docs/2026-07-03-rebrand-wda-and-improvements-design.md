# Design: Rebrand the WDA Runner + Product Improvements (A / B / C)

**Date:** 2026-07-03
**Status:** Design — approved scope, pending spec review. No implementation yet.
**Prereq feasibility:** see [2026-07-03-rebrand-wda-internal-app-feasibility.md](2026-07-03-rebrand-wda-internal-app-feasibility.md).

## Goal

Turn the vendored WebDriverAgent (WDA) into a **branded, locally-installed** iMirror
component, and improve the product around it — **without** forking WDA and while keeping the
MCP server dependency-light. Internal / dev-signed only; the App Store is explicitly out of
scope (ruled out in the feasibility study).

## Locked decisions

- **Internal, dev-signed** distribution. A **paid** Apple Developer Team is available to sign
  the branded WDA `.ipa` (so the one-click bundled install path is buildable).
- **Runner is rebranded cosmetically only** — it stays stock so it upgrades cleanly.
- **OCR / image-based element find: dropped.** The agent already sees `ios_screenshot` and can
  locate unlabeled elements visually; a dedicated OCR tool would add a heavy dependency for
  marginal gain.
- **Multi-device: out of scope** for this pass (single-device transport unchanged).
- **Dependency-light preserved:** stdlib + `mcp[cli]` only; anything heavier shells out and
  degrades gracefully (the existing ffmpeg precedent).

## Architecture & layering

Features live in the layer whose code we own:

| Layer | Role | Changes in this design |
|---|---|---|
| **WDA runner** (`tools/WebDriverAgent`) | automation engine (XCUITest) | cosmetic rebrand only, applied at build time |
| **Mac app** (`Sources/iMirror`) | capture, control, bring-up, packaging | runner-id constants; install-if-missing; packaging |
| **MCP server** (`mcp-server/imirror_mcp.py`) | agent tools + HTML reports | new `ios_*` tools (B); report/assertions/metrics (C) |

---

## Component 1 — Runner rebrand (build-time reskin, no fork)

**Mechanism.** Add `scripts/rebrand-wda.sh` + a generated `.xcconfig` overlay applied when WDA
is built, setting:

- `PRODUCT_BUNDLE_IDENTIFIER` → `<brand>.WebDriverAgentRunner` (Runner target)
- `PRODUCT_NAME` → `<Brand>Runner` (drives the `.xctest`/`.xctrunner` names)
- `CFBundleDisplayName` → branded on-device label
- app icon asset + a branded `LaunchScreen`

Re-runnable after any upstream WDA version bump: re-clone the pinned tag, re-apply the overlay.

**The one permanent code change.** `go-ios runwda` is currently called with **no arguments**
([Transport.swift:256](../Sources/iMirror/Transport.swift)), so it relies on the hardcoded
default id `com.facebook.WebDriverAgentRunner.xctrunner`. Renaming the bundle **breaks bring-up**
(health dot stays red) unless we thread the new identity through that call:

```
runwda --bundleid <brand>.WebDriverAgentRunner.xctrunner \
       --testrunnerbundleid <brand>.WebDriverAgentRunner.xctrunner \
       --xctestconfig <Brand>Runner.xctest
```

Introduce these as **named constants in one place** (e.g. a `WDAIdentity` struct in
`Transport.swift`) so the Mac app and the rebrand script share one source of truth.

**Untouched (hard rule):** HTTP port `8100` and all W3C paths — that is the wire the Mac app
(`WDAClient.swift`) and MCP server depend on. Rebrand the *identity*, never the *wire*.

---

## Component 2 — Theme A: Branded install & polish

**Goal:** the phone shows *our* branded icon/name, and first run installs the runner with no
Xcode.

- **Bundle a pre-signed branded WDA `.ipa`** into `iMirror.app/Contents/Resources/` — exactly
  as `package.sh` already bundles the `ios` binary.
- **Install-if-missing:** before `runwda`, the Mac app checks whether the branded runner is
  installed (go-ios list apps) and, if absent, runs `ios install --path <bundled ipa>`.
  Guarded so it happens once, behind the existing transport bring-up seam.
- **`package.sh` gains a `--with-wda <ipa>` step** that copies the signed `.ipa` into Resources
  and (when signing) leaves it intact (the `.ipa` is already signed with the paid Team; it is
  not re-signed with the Mac Developer ID).
- **Unavoidable human steps remain** (documented, not automated): Developer-Mode first-enable
  (restart + passcode) and the first cert-trust / Local-Network prompts.

**Acceptance:** on a fresh (already dev-trusted) device, launching iMirror installs the branded
runner and the health dot goes green with no Xcode.

---

## Component 3 — Theme B: More automation power (new `ios_*` tools)

New tools follow the existing pattern (`_session_post` / `_req`, `_record` for run capture). All
dependency-free.

| Tool | WDA / go-ios call | Notes |
|---|---|---|
| `ios_launch_app(bundle_id)` | `POST /wda/apps/launch` | foreground/launch a target app |
| `ios_terminate_app(bundle_id)` | `POST /wda/apps/terminate` | |
| `ios_activate_app(bundle_id)` | `POST /wda/apps/activate` | bring existing app to front |
| `ios_app_state(bundle_id)` | `POST /wda/apps/state` | returns not-installed/background/front |
| `ios_install_app(path)` | bundled `ios install` | install an `.ipa`/`.app` on the device |
| `ios_open_url(url)` | `POST /url` | deep-link / universal-link open |
| `ios_clipboard_get()` / `ios_clipboard_set(text)` | `POST /wda/getPasteboard` / `setPasteboard` | **caveat:** iOS grants pasteboard access only while WDA is foreground; document the limitation and surface a clear error rather than failing silently |

**Dropped:** OCR / image-find (decision above). **Out of scope:** live network-condition
simulation (no clean remote toggle).

---

## Component 4 — Theme C: Richer reports & metrics

Extends the existing report pipeline (`_render_report`, `_make_timelapse`, `_stat_card`, …).

- **Assertion library (dep-free, easy):** `ios_assert_visible(text, timeout_s)` /
  `ios_assert_not_visible(...)`, wrapping the existing find/wait logic and auto-recording a
  pass/fail step into the report rollup (so assertions show in the donut + section tallies).
- **Flaky-retry (dep-free):** a small retry wrapper for find/tap/wait with bounded attempts +
  backoff; the report notes retried steps.
- **Per-run metrics (moderate — via bundled go-ios, degrade gracefully):** sample CPU / memory
  (and fps where the installed go-ios supports it) during a run and render them as report stat
  cards / a small sparkline. If go-ios can't provide a metric, the report omits it with a note
  (ffmpeg-style graceful degrade). *Verify exact go-ios metric support during implementation —
  this is the least-certain piece.*
- **Embed real video (dep-free):** the Mac app already records true mp4 via
  `AVCaptureMovieFileOutput`. Let `ios_finish_run` optionally reference/embed that recording
  alongside (or instead of) the ffmpeg timelapse.

**Out of scope:** full network-request logs (needs a proxy dependency).

---

## Testing strategy (per CLAUDE.md — no device, stub HTTP)

- Every new MCP tool + report feature gets unit tests in `mcp-server/test_imirror_mcp.py` that
  **stub the WDA HTTP layer** (as the suite already does) — no phone, no WDA.
- New Mac-side install logic sits behind the existing transport seam; keep it unit-testable
  where practical, otherwise exercise via the optional live integration suite.
- Before any commit: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py`
  and `python -m py_compile mcp-server/imirror_mcp.py`.

## Licensing & branding checklist

- Retain WDA's on-disk `LICENSE` (BSD-3-Clause) verbatim in the distribution; resolve the
  `package.json` Apache-2.0 mismatch. Bundle go-ios's MIT notice.
- Brand name must **not** contain "Appium" or "Selenium" (registered marks); use a distinct
  brand + a factual nominative-attribution line. Don't imply Facebook/Meta endorsement.

## Risks

1. **Platform treadmill (existential):** go-ios + WDA track Apple's private protocols; an iOS
   major can break bring-up until upstream catches up. The rebrand overlay is designed to
   re-apply cleanly against a new tag to limit this cost.
2. **Metrics uncertainty:** go-ios's CPU/mem/fps surface must be verified; treat that report
   feature as best-effort/degrade-gracefully.
3. **Pasteboard limitation:** WDA pasteboard access requires foreground; the clipboard tools
   must fail loudly with guidance, not silently.

## Build order (for the plan)

1. Runner rebrand + `Transport.swift` id constants (Component 1) — smallest, de-risks the one
   thing that can break bring-up.
2. Theme A bundled install (Component 2) — makes it a finished product.
3. Theme B tools (Component 3) — independent, incremental, each with tests.
4. Theme C report features (Component 4) — assertions/retry first (easy), metrics last (verify).

## Out of scope (explicit)

App Store distribution · a fork of WebDriverAgentLib · OCR/image-find · network-condition
simulation · full network-request logging · multi-device support · turning IntegrationApp into
a companion app (a separate future track).
