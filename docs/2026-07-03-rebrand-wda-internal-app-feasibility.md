# Feasibility: Rebranding WebDriverAgent into a Proper, Bundled iMirror App

**Date:** 2026-07-03
**Status:** Investigation complete — no implementation. Reference artifact for a build decision.
**Method:** Two rounds of parallel multi-agent investigation (7 specialists across technical,
policy, licensing, distribution, and architecture angles), reconciled into consensus.

---

## Executive summary

The original idea — "rebrand the WebDriverAgent (WDA) app installed on iOS and ship it as a
proper iOS application, bundled with the IntegrationApp it also installs" — has **two very
different answers depending on the distribution target**:

- **As an App Store consumer app: impossible.** WDA is an XCUITest runner. Its powers (control
  any app, full-screen screenshots, accessibility-tree reads, touch injection) exist *only*
  because it runs as an instrumented test process. That capability, and the runner bundle
  itself, cannot pass App Store signing **or** review. A sandboxed App Store app can do none of
  it. The only App-Store-legal product in this space is a *screen-sharing/recording* app
  (ReplayKit broadcast of the phone's **own** screen), which drops the entire differentiator.

- **As an internal-only, dev-signed, bundled tool: viable — and mostly a packaging job.** With
  no App Store review, the automation powers survive intact. Rebranding WDA is a **build-config
  exercise, not a code fork**. The IntegrationApp skeleton can become a thin branded companion.
  The whole thing packages into a single branded DMG installer.

**This document assumes the internal-only target** (the chosen direction), and records the App
Store analysis as the boundary that rules it out.

**Buildable shape, in one line:** rebrand WDA at build time (bundle id / product name / icon →
thread the new id through the one `runwda` call), repurpose the IntegrationApp skeleton into a
branded pairing/status companion, package Mac app + go-ios + a pre-signed branded WDA `.ipa` +
companion into one branded DMG, sign with a **paid** Developer cert, install via go-ios, re-sign
yearly. Skip ReplayKit.

---

## Part 1 — Why the App Store path is ruled out (the boundary)

Three independent, stacking blockers — any one is fatal:

| # | Blocker | Why it's fatal | Confidence |
|---|---------|----------------|-----------|
| 1 | **Signing / provisioning** | An XCUITest runner requires `get-task-allow = true` + test entitlements, granted only by Development / Ad-Hoc / Enterprise profiles. App Store distribution profiles force `get-task-allow = false`. It cannot be *signed* for submission. | High |
| 2 | **iOS sandbox (physics)** | No public API injects touches into other apps, reads another app's accessibility tree, or screenshots the system on demand. These don't exist for third-party apps — WDA gets them only as an XCUITest process. | High |
| 3 | **App Review policy** | Even hypothetically past 1–2: WDA links **private** `XCTestManager_IDEInterface` headers → violates **Guideline 2.5.1** (public APIs only); driving other apps violates **2.5.2** (code that changes other apps' functionality). | High |

**Maximal App-Store-legal subset (for reference):** a user-consented ReplayKit broadcast that
mirrors the phone's *own* screen to a Mac over Local Network, plus a report viewer and pairing
UI. This is a screen-sharing product, **not** a remote-control one — it cannot carry iMirror's
value. A remote-desktop *client* (iOS app controlling a user-owned Mac, Guideline 4.2.7) is also
legal but is the opposite of iMirror's direction.

---

## Part 2 — Internal build feasibility (the chosen path)

### 2.1 Signing & lifecycle

**Recommended: the $99 paid Apple Developer Program with plain Development signing; install via
go-ios.** The non-obvious findings:

- **Not Enterprise.** An enterprise-signed WDA is documented to **crash on `houseArrest` init**.
  Enterprise also adds "employees-only" audit terms + revocation risk for a QA tool.
- **Not any review-gated channel** (TestFlight, ABM Custom Apps, App Store) — they strip the
  `get-task-allow` entitlement the runner needs.
- **The 7-day cert pain is a *free-account* artifact.** A **paid** Development provisioning
  profile lasts **~12 months**. Re-sign once a year, not weekly.
- **go-ios runs day-to-day, no Xcode:** install the pre-signed `.ipa`, toggle Developer Mode,
  start the tunnel (iOS 17+), launch/kill WDA.
- **MDM is complementary, not the runner path:** use it to supervise devices and silently push
  the *companion viewer* only.

**Channel comparison**

| Channel | Device cap | Profile lifetime | Renewal friction | Runner deployable? | Best for |
|---|---|---|---|---|---|
| Free personal (dev) | tiny | **7-day** | very high | Yes | throwaway trials only |
| **Paid Development** ($99/yr) | 100/device-class/yr | **~12 mo** | low (annual) | **Yes — native fit** | **recommended runner path** |
| Ad-Hoc (same paid program) | 100/yr | ~12 mo | low-med | No (strips `get-task-allow`) | companion viewer sideload |
| Enterprise ($299/yr) | none | ~12 mo | med + revocation risk | **Effectively no** (houseArrest crash) | not advised |
| ABM Custom App + MDM | none (managed) | MDM-managed | low (silent push) | No (review-gated) | push the viewer silently |
| TestFlight | 10k | 90-day build | n/a | No | not usable for runner |

**Automation ceiling — what still needs a human (once per device):**

- Developer Mode first-enable on iOS 16+ (Settings toggle → **restart → passcode**; unscriptable)
- First trust of the developer cert (non-MDM profile)
- The Local Network permission prompt on first WDA launch
- Physical USB for the very first go-ios pairing/trust handshake

Everything else — install/re-install the `.ipa`, mount dev image / start tunnel, launch/kill WDA,
run sessions — is automatable via go-ios. Renewal cadence: re-sign & re-push the `.ipa` ~yearly;
register new device UDIDs as the fleet grows (100/yr/class cap on Development).

### 2.2 Rebrand & bundle mechanics

**The one structural coupling that matters.** The Mac app launches WDA via `go-ios runwda` with
**no arguments** (`Sources/iMirror/Transport.swift:256`). With no `--bundleid` /
`--testrunnerbundleid` / `--xctestconfig`, go-ios falls back to hardcoded defaults:

```
com.facebook.WebDriverAgentRunner.xctrunner   (bundle id + test-runner bundle id)
WebDriverAgentRunner.xctest                    (xctest config)
```

**The moment you rename WDA's bundle id or product name, `runwda` stops finding it** and the
health dot stays red — until you thread the new identity through that one call. (The `.xctrunner`
suffix is appended by Xcode when it wraps a UI-test target into a runner `.app`; go-ios matches
on the suffixed id.)

**What to rebrand vs. leave alone**

| Item | Kind | What breaks if changed | Where it's coupled |
|---|---|---|---|
| Runner `PRODUCT_BUNDLE_IDENTIFIER` (`com.facebook.WebDriverAgentRunner`) | **Structural** | `runwda` default no longer matches → red dot | `project.pbxproj`; must pass new id to `Transport.swift:256` |
| Lib `PRODUCT_BUNDLE_IDENTIFIER` (`…WebDriverAgentLib`) | Cosmetic | nothing external (keep unique) | `project.pbxproj` |
| Product/scheme name `WebDriverAgentRunner` | **Structural** | changes `.xctest` name → `--xctestconfig` default breaks | `project.pbxproj`; README build steps |
| Display name / `CFBundleName` | Cosmetic | nothing (on-device label) | Runner `Info.plist` |
| App icon | Cosmetic | nothing (Runner has none today) | add asset catalog |
| HTTP port **8100** | **Leave as-is** | renaming is pure risk | `FBConfiguration.m`, `Transport.swift`, `wda-up.sh`, `imirror_mcp.py` |
| HTTP paths (`/status`, `/session`, W3C `/actions`) | **Do not touch** | forks the wire the Mac app + MCP depend on | `WDAClient.swift`, `imirror_mcp.py`, `wda-up.sh` |

**Rule of thumb:** rebrand the *identity* (bundle id, product/xctest name, display name, icon);
never touch the *wire* (port, W3C paths). Any structural id change must be threaded to `runwda`
as `--bundleid <new>.xctrunner --testrunnerbundleid <new>.xctrunner --xctestconfig <New>.xctest`.

**Fork vs. build-time reskin → build-time reskin.** WDA tracks Apple's private XCTest/RSD
protocols and ships ~monthly. A hard fork means perpetual rebasing of rename commits for zero
functional gain. Instead: keep `tools/WebDriverAgent` at the pinned upstream tag (as today,
gitignored) and apply the rebrand at build time — an `.xcconfig` overlay overriding
`PRODUCT_BUNDLE_IDENTIFIER` / `PRODUCT_NAME`, plus an icon asset and display name. Bumping WDA
later becomes: re-clone the new tag, re-run the overlay. The only permanently carried code change
is the `runwda` args in `Transport.swift` — one line, upstream-independent.

**IntegrationApp's realistic role.** Today it's a throwaway XCUITest **host fixture**
(`com.facebook.IntegrationApp`) used by the *IntegrationTests* target; the WDA **Runner does not
use it** (WDA runs host-less on device). Promoting it to "the WDA host" buys nothing and *costs*
the host-less simplicity go-ios relies on. Its real value is orthogonal: it's already a complete,
signable branded iOS-app skeleton to **repurpose into the on-device companion app** (see 2.3).
Keep it decoupled from the automation runner.

**Single deliverable.** The existing `scripts/package.sh` already builds a notarized DMG bundling
go-ios. Extend it to also carry a **pre-built, pre-signed branded WDA `.ipa`** + install tooling
(`go-ios install`), collapsing the one-time Xcode dance into a bundled installer. Caveat: WDA
must be signed with an Apple Team you control, so "pre-signed" means "signed at your build time
with your paid Dev cert," and the ~yearly re-sign still applies.

### 2.3 The branded iOS companion app — thin, not a second brain

**Mac-primary is structurally correct.** All cross-app power lives in the WDA runner and cannot
move into a normal app (even dev-signed). Do not invert the architecture.

Realistic companion roles, ranked:

1. **Pairing / consent / branding front-end** for WDA bring-up — in-process, no WDA needed, low
   effort. Turns the raw trust/Developer-Mode dance into an on-brand moment. **Build first.**
2. **Run-status display** ("Run in progress: login flow — step 4/12") — needs a small Mac→phone
   status channel that doesn't exist today (Bonjour / local HTTP). Real value if a human stands
   near the phone during agent-driven runs.
3. **On-device HTML report viewer** — marginal; a Mac browser already opens the self-contained
   report equally well.

Skip "phone drives the run" / full inversion — foreground contention (the companion and the app
under test fight for foreground) and no real workflow.

### 2.4 ReplayKit vs. USB capture — don't build it (now)

The existing USB **CoreMediaIO** capture is **strictly better on every axis that matters**:
full-res, full-fps, no per-session consent tap, no memory ceiling, already working.

| Dimension | USB CoreMediaIO (current) | ReplayKit broadcast (proposed) |
|---|---|---|
| Tether | USB required | **Untethered (Wi-Fi)** — its one advantage |
| Latency | uncompressed pipe, no encode/network hop | + H.264 encode + network hop (200–500ms typical) |
| Resolution/fps | full native res | capped by ~50MB budget → forced downscale (720p/540p) |
| Memory | normal Mac process | **~50MB hard extension ceiling** (jetsam kills over it) |
| Setup | camera permission once | new extension target + App Group + **per-session consent tap** |
| Reliability | minor private-API quirks, ships today | memory-limit crashes; no mature extension→Mac prior art |
| Control | N/A (WDA does control) | N/A (WDA still does control) |

Internal/dev signing relaxes **nothing** here — the 50MB ceiling and the consent picker are
OS-enforced, not review-enforced. ReplayKit only replaces the *video* leg; WDA still does 100% of
control either way. **Recommendation: don't build it. Revisit only if an untethered use case is
explicitly required**, and budget real R&D risk (the extension→Mac network hop has no mature
reference implementation).

---

## Part 3 — Licensing & trademark (must-do if you rebrand)

- **WDA license ambiguity — resolve it.** The vendored `tools/WebDriverAgent/LICENSE` is
  **BSD-3-Clause (Facebook, 2015-present)**, while `tools/WebDriverAgent/package.json` declares
  **Apache-2.0**, and this repo's README credits it as Apache-2.0. Retain the actual on-disk
  `LICENSE` text verbatim in any distribution; pin down which license genuinely governs the tag
  you ship. Both licenses permit commercial rebranding.
- **go-ios (MIT):** bundle the MIT copyright + permission notice (e.g., an "Open Source Licenses"
  screen). That's the only obligation.
- **Trademark:** "Appium" (OpenJS Foundation) and "Selenium" (Software Freedom Conservancy) are
  registered — **never** put them in your app name, title, or domain. "WebDriverAgent" has no
  separate registered mark. Use a wholly distinct brand + a factual nominative-fair-use line
  ("built using WebDriverAgent, an open-source project"). Don't imply Facebook/Meta endorsement.

---

## Part 4 — Risks

1. **Platform treadmill (existential).** go-ios + WDA reverse-engineer Apple's private wire
   protocols; a new iOS major can break the whole chain until upstream catches up. Everything
   control-side inherits this. Already flagged in the project README — the real business risk.
2. **Signing friction at fleet scale.** Paid Dev cert + per-device Developer Mode / trust /
   Local Network prompts mean genuinely headless onboarding is not achievable today; supervision
   reduces but doesn't eliminate the human touches.
3. **Pre-signed `.ipa` ergonomics.** Device provisioning/cert specifics vary per deployment;
   the "one bundled installer" still assumes the customer's own Apple Team and ~yearly re-sign.

---

## Appendix — Method & confidence

Investigated in two parallel rounds (read-only, no code changed):

- **Round 1 (App Store target):** iOS sandbox capability envelope; App Review policy + signing;
  WDA/go-ios licensing + trademark; realistic product architectures.
- **Round 2 (internal target):** internal signing & cert lifecycle; rebrand/bundle mechanics with
  in-repo coupling; ReplayKit vs. USB; iOS control-surface inversion.

Confidence is **High** on the hard technical/policy boundaries (sandbox limits, `get-task-allow`
incompatibility, the `runwda` coupling — verified in this repo, the enterprise houseArrest crash,
the ReplayKit constraints) and **Medium** on deployment ergonomics and companion-app value
rankings (they depend on real day-to-day usage). Key external sources: Apple App Review
Guidelines, ReplayKit security guide, Apple provisioning/Developer-Mode docs, go-ios README,
Appium "run pre-installed WDA" guide, and the WDA/Appium issue trackers.
