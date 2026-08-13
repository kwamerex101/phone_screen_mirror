# iMirror improvement plan — lessons from the Argent teardown

Status: draft for review
Author: (Claude Code session, on branch `claude/argent-device-control-review-94b011`)
Reviewer: Fable
Date: 2026-08-13

## 1. Context and framing

We reviewed Software Mansion's **Argent** (open-source, github.com/software-mansion/argent) because it markets faster device control. The teardown produced one load-bearing conclusion:

**Argent's speed is a simulator artifact and does not port to iMirror.** For iOS, Argent drives the **Simulator only** — there is no real-device iOS code anywhere in the repo (no `WebDriverAgent`, `devicectl`, `libimobiledevice`, or `idevice*`; `resolveDevice()` classifies any UUID as `kind:"simulator"` unconditionally, and the `apple:{device:true}` flag on ~25 tools is dead code for iOS). Its speed comes from techniques that require a simulator you own: injecting a dylib into the app process via `DYLD_INSERT_LIBRARIES`, an `ax-service` daemon `simctl spawn`'d into the sim, and native HID via SimulatorKit. On a real iPhone none of that is available; WebDriverAgent/XCUITest over HTTP is the only Apple-sanctioned channel, and iMirror already pulls the legitimate WDA speed levers (`shouldWaitForQuiescence:false`, `waitForIdleTimeout:0`, `animationCoolOffTimeout:0`, device-side JPEG, keep-alive, gesture-serialization lock).

So this plan does **not** chase their speed. It ports their **reliability engineering, tool ergonomics, and error/report discipline** — the parts that harden the exact bugs we have already been fixing (call-interruption stalls, dead-capture detection, watchdog timing) and that reduce the agent's context and round-trip cost.

## 2. Scope and non-goals

In scope: the 11 items in section 4, plus a short lower-confidence backlog in section 7.

Non-goals (explicitly not porting, because they need a simulator, dylib injection, or a Metro/Hermes debug build):
- `simctl`-based lifecycle, `simctl privacy` TCC editing, simulator screen-recording.
- The entire `native-*` devtools family (UIKit tree, view-at-point, native network) — needs `DYLD_INSERT_LIBRARIES` in the sim's launchd env.
- The `debugger-*` / React-profiler / JS-eval / JS-network families — need Metro's CDP endpoint and a Hermes debug build.
- OCR/font-aware visual diff (Tesseract + SSIM + HOG) — built for a cross-OS-version simulator matrix we do not have.
- The full multi-backend `ServiceBlueprint` registry, MoQ/WebTransport remote streaming, and the Electron "Argent Lens" variant picker.

## 3. Summary

| ID | Item | Area | Priority | Effort | Risk |
|----|------|------|----------|--------|------|
| I1 | Compact text accessibility tree for `ios_source` | MCP (Python) | P1 | M | Low |
| I2 | Tiered WDA timeouts + ride-out-the-stall | MCP (Python) | P1 | M | Med |
| I3 | Frame-content-aware capture liveness (black/frozen vs dead) | App (Swift) | P1 | M | Med |
| I4 | Settle-before-act (spike, may not ship) | MCP (Python) | P3 | M | Med |
| I5 | `ios_await_idle` + `ios_wait_for` → await-element contract | MCP (Python) | P2 | M | Low |
| I6 | `ios_run_sequence` batched steps | MCP (Python) | P2 | M | Low |
| I7 | Structured error codes/kinds + recovery-instruction messages | MCP (Python) | P2 | M | Med |
| I8 | Report: structured per-step verdicts + idle verdict vocabulary | MCP (Python) | P2 | M | Low |
| I9 | PNG signature validation in `ios_screenshot` | MCP (Python) | P3 | S | Low |
| I10 | Multi-editor MCP installer adapter | App (Swift) | P2 | M | Low |
| I11 | Loopback Host-allowlist hardening (defense-in-depth) | App (Swift) | P3 | M | Low |

Effort: S = under half a day, M = half to two days, L = more than two days. All Python file edits land in `mcp-server/imirror_mcp.py` with tests in `mcp-server/test_imirror_mcp.py` (111 tests today, stubbed HTTP, no device needed — keep it that way).

## 4. Plan items

### I1 — Compact text accessibility tree for `ios_source`  (P1, Python, M, Low risk)

**Problem.** `ios_source` returns raw WDA XML and hard-truncates at 20,000 chars, so on a complex screen the model sees a partial tree. Argent measured their equivalent text tree at roughly 1/6th the bytes of the structured form, which is the single biggest context win available to us.

**Current state.** `ios_source` at `mcp-server/imirror_mcp.py:474` does `GET /source` (timeout 60) and truncates: `src[:20000] + "\n… (truncated)"` at `imirror_mcp.py:490-491`. Returns raw XML string.

**Proposal.** Add a compact renderer: parse WDA's source (offer `format="xml"` to keep the raw path, add `format="text"` as the new default). Emit one line per meaningful element: role/type, label/name/value/identifier, interactivity flags, and a normalized `[0,1]` frame. Collapse pure containers unless they carry their own label/value/id or are interactive. Put the tap formula (`tap_x = frame.x + width/2`, `tap_y = frame.y + height/2`) in the response header so a single line is actionable in isolation.

**Approach / notes.**
- WDA `/source` can return XML or JSON (`format` query param, and `/source?format=json`). Prefer requesting JSON and walking it, which is cleaner than XML parsing and lets us compute normalized frames from `rect` against the window size (`ios_window_size` logic already exists).
- Keep a hard output cap but raise the effective information density so truncation is rare; when we do truncate, say how many elements were dropped.
- Mirror Argent's content model: always print "content" roles (buttons, text, images, fields) even with an empty label; print containers only when they add information.

**Tests.** Feed a captured WDA JSON/XML source fixture through the renderer; assert element lines, normalized-frame math, container collapsing, the header formula line, and the truncation-count message. Keep `format="xml"` covered by the existing behavior test.

**Dependencies.** None. Unblocks I4 (a cheap fingerprint can reuse this) and improves I5/I8.

---

### I2 — Tiered WDA timeouts + ride-out-the-stall  (P1, Python, M, Med risk)

**Problem.** A heavy app cold-start or a telephony interruption can pin the iOS main thread past a flat timeout, so a full-tree read fails the step. This is exactly Argent's commit #778 class of bug, and it overlaps our call-interruption / watchdog work.

**Current state.** `_req(method, path, body=None, timeout=15)` at `imirror_mcp.py:180` is one flat per-call timeout. `/source` already gets `timeout=60` (`imirror_mcp.py:484`); cheap settings POSTs get `timeout=5`. `_req` retries transient connection drops (RemoteDisconnected/reset/BadStatusLine/IncompleteRead) up to 3 times with `0.3*attempt` backoff (`imirror_mcp.py:187-200`) but does **not** retry on `socket.timeout`/`TimeoutError` — those raise immediately with a "wedged" hint (`imirror_mcp.py:201-204`). No tiered-timeout concept exists.

**Proposal.** Introduce named timeout tiers instead of scattered literals:
- `PROBE` (short, e.g. 5s) for cheap existence/point checks.
- `INTERACT` (medium, e.g. 15s) for gestures.
- `TREE` (long, e.g. 20-30s) for `/source` full reads — the read most likely caught behind a stalled main thread.

Adopt Argent's discipline for the long tier: a timeout on a `TREE` read should **ride out and retry once** rather than fail the step, mirroring their per-method escalation. Keep the "prove the request never landed before retrying a state-changing call" rule: only auto-retry idempotent reads on timeout, never gestures (a timed-out gesture may have applied).

**Approach / notes.**
- Define the tiers as module constants and thread them through `_req` call sites; this is mostly a mechanical relabel plus one new "retry-once-on-timeout for reads" branch guarded to read-only routes.
- Optional: a "last-known foreground app/screen" hint used only as a tie-breaker when a probe times out, never to override an answered result (Argent's `launchedNativeApp` pattern). Flag for Fable: is this worth it on a single-app-under-test real device, or over-engineering?

**Tests.** Extend the existing `_http`/`_req` retry/timeout unit tests (`test_imirror_mcp.py:117-206`): assert a `TREE` read retries once on timeout, an `INTERACT` gesture does not retry on timeout, and tier constants are applied at the right call sites.

**Dependencies.** Independent, but pairs naturally with I1 in the same read-path PR.

---

### I3 — Frame-content-aware capture liveness  (P1, Swift, M, Med risk)

**Problem.** During a phone call the capture source can keep delivering a static/black frame. The watchdog resets its liveness clock on every delivered buffer, so it treats a wedged-but-still-delivering source as healthy. We shipped a waiting-state (PR #34), but the underlying signal is still single-axis (frame age), which a repeated black frame defeats.

**Current state.** `Sources/iMirrorCore/CaptureLiveness.swift` is time-since-last-frame only: `stallThreshold=5s`, `recoveryGrace=20s`, `deadAfterFailedRecoveries=3`, `deadRetryInterval=60s` (`CaptureLiveness.swift:3-28`); it counts consecutive **frameless recoveries**, not frame content. `FrameGrabber.captureOutput` stamps `lastFrameAt` on every buffer and stores only the latest `CVPixelBuffer` under an `NSLock`, with no hashing/fingerprinting (`Sources/iMirror/main.swift:225-252`). The code comment at `main.swift:968-971` states plainly it "can't tell a transient telephony pause from a wedged capture endpoint."

**Proposal.** Add cheap frame-content awareness so the watchdog can distinguish three states instead of two:
- healthy: fresh, changing frames;
- stalled-but-delivering: frames arriving but content static (near-identical) and/or near-black beyond a threshold → show the waiting state, do not fake health;
- dead: no frames at all → recover.

Implement a downsampled fingerprint of the latest buffer (small average-luma grid or a cheap hash) computed in `FrameGrabber`; feed `consecutiveStaticFrames` and a `nearBlack` flag into `CaptureWatchdogState`. Apply Argent's outage-vs-blip rule: never flag on one static/black frame; require N consecutive over a bounded window.

**Approach / notes / open question.** A legitimately dark or static UI (a black settings screen, a paused video) must not be misclassified as wedged. Static + near-black alone is ambiguous. Design question for Fable: combine the content signal with context we already have (an `AVCaptureSessionWasInterrupted` with a telephony reason, `main.swift:839-844`) so "static/black" only escalates to a distinct waiting/occluded verdict when corroborated, and never hard-fails on its own. The bias should match Argent's: readiness is not correctness — degrade to a waiting state with a reason, do not kill the session on a content heuristic.

**Tests.** `CaptureLiveness.swift` decision logic is already pure and unit-testable. Add cases for the new state fields: static-frame counting, near-black flag, the N-consecutive gate, and corroboration-with-interruption. Frame fingerprinting in `FrameGrabber` needs a small seam so the hash function is testable without a device.

**Dependencies.** Standalone. Highest-value item for the known black-screen bug.

---

### I4 — Settle-before-act (spike, may not ship)  (P3, Python, M, Med risk)

**Problem.** Acting on a mid-animation screen causes "tapped and missed" flakiness. Argent re-reads a cheap tree fingerprint until two consecutive reads match before acting.

**Current state.** Our interaction tools do not settle before acting; polling tools use WDA element-predicate lookups, not a screen fingerprint (`ios_wait_for` etc., see I5).

**Proposal (spike first).** The honest blocker: Argent's settle is cheap because their tree read is in-process sub-100ms. On a real device the analogous read (`/source`) is the expensive call, so polling it to settle is costly. Spike two cheap-signal options and measure before committing:
1. a downscaled screenshot hash polled until stable (screenshot is a lighter round-trip than `/source`);
2. reuse the I1 compact-tree fingerprint but only where we were going to read the tree anyway.

If neither is cheap enough to be worth it, do not ship a general settle; instead expose it as an opt-in `settle_ms`/`settle=true` parameter on the gesture tools (we already have `settle_ms` on swipe/scroll) rather than a global default.

**Tests.** For whichever signal wins: fingerprint-stability logic with stubbed reads, and the opt-in parameter path.

**Dependencies.** Benefits from I1. Explicitly gated on the spike result; Fable to advise whether to spike now or defer.

---

### I5 — `ios_await_idle` + upgrade `ios_wait_for` to the await-element contract  (P2, Python, M, Low risk)

**Problem.** We have no "wait until the screen stops changing" primitive, so flows fall back to blind sleeps; and `ios_wait_for` returns a bare "did not appear" without saying what it did see.

**Current state.** All polling tools (`ios_wait_for` `imirror_mcp.py:650`, `ios_find_and_tap` `:625`, `ios_scroll_to` `:560`, `ios_assert_visible` `:1027`, `ios_assert_not_visible` `:1047`) poll `_find_element` (WDA element predicate, `:368-384`) with `0.5s` sleeps and a deadline, then raise. No idle primitive; error messages do not quote the element actually matched.

**Proposal.**
- Add `ios_await_idle(timeout_s, min_stable_ms)`: poll a cheap screen fingerprint (whatever I4's spike selects, or the I1 compact tree where affordable) until stable for `min_stable_ms`, capped by `timeout_s`. Report a structured verdict, never a hard failure (see I8's vocabulary).
- Upgrade `ios_wait_for` to Argent's `await-ui-element` contract: match the first visible element in reading order; on timeout, include a note quoting the nearest/last element considered so a loose selector is debuggable. Keep it a blocking-on-condition tool with no bare-timer mode.

**Tests.** Stub `_find_element`/fingerprint reads and `time.sleep` (existing pattern, e.g. `test_imirror_mcp.py:410-413`): assert reading-order first match, the timeout note quotes what it saw, and `ios_await_idle` returns each verdict without raising.

**Dependencies.** Idle primitive shares the fingerprint decision with I4.

---

### I6 — `ios_run_sequence` batched steps  (P2, Python, M, Low risk)

**Problem.** Scripted flows pay one MCP round-trip per step. Argent's `run-sequence` batches N interaction steps in one call with per-step results, and an interleaved await that aborts the rest on failure.

**Current state.** No batching tool exists; each interaction is its own tool call.

**Proposal.** Add `ios_run_sequence(steps)` where each step is one of an allowlisted set (tap/swipe/scroll/type/press_button/wait_for), executed in order, returning a per-step pass/fail list. If an interleaved `wait_for`/assert step fails, stop and do not run later steps. Optionally return one screenshot at the end (respect the active-run recording rules).

**Approach / notes.** Reuse the existing single-step implementations; this is an orchestration wrapper, not new device capability. Route every step through the same validation the single tools use (do not let a batched step bypass argument checks).

**Tests.** Stubbed WDA: a happy-path multi-step sequence records each step; a failing gate aborts the remainder; argument validation still fires per step.

**Dependencies.** None. Composes with I8 (per-step verdicts).

---

### I7 — Structured error codes/kinds + recovery-instruction messages  (P2, Python, M, Med risk)

**Problem.** Every failure is a human-readable `RuntimeError` string (34 sites), so neither the agent nor the report can classify a failure without regexing prose.

**Current state.** 34 `raise RuntimeError(f"...")` sites, no exception subclasses or codes (`imirror_mcp.py`, e.g. WDA errors `:282/:294/:486/:618`, validation `:349/:972`, domain failures `:585/:666-667/:1043`). Test doctrine is `pytest.raises(RuntimeError, match=...)` (`test_imirror_mcp.py:224,397,1164,1186`).

**Proposal.** Introduce a small structured error layer without breaking the string contract:
- an `MCPToolError(RuntimeError)` subclass carrying `error_code`, `error_kind` (closed enum: `validation` / `not_found` / `wda_http` / `unreachable` / `wedged` / `timeout` / `unsupported`), and the existing human message;
- for network errors, keep Argent's rule that each message ends in a concrete recovery instruction (we already have `_unreachable_hint()`/`_wedged_hint()` (call sites at `imirror_mcp.py:202-219`, definitions at `:85-97`) — extend, do not replace);
- subclassing `RuntimeError` keeps all existing `pytest.raises(RuntimeError, match=...)` tests green.

**Approach / notes.** Roll out incrementally: add the subclass and codes at the highest-value sites first (WDA HTTP, unreachable/wedged, not-found, validation), leave the rest as plain `RuntimeError` until touched. The report (I8) reads `error_kind` when present.

**Tests.** Assert representative sites now raise `MCPToolError` with the right `error_kind` while still matching the old message text (backward-compatible). Add a couple of new code-based assertions.

**Dependencies.** Feeds I8.

---

### I8 — Report: structured per-step verdicts + idle verdict vocabulary  (P2, Python, M, Low risk)

**Problem.** The HTML report only rolls up explicit `note` steps; a raised failure from an action step is not linked into the timeline unless a tool manually records a `fail` note first, and idle/wait outcomes are a single pass/fail with no "why."

**Current state.** `_record()` builds `{i,t,action,detail,screenshot,note}` with `note ∈ {"","info","pass","fail"}` (`imirror_mcp.py:122-125`); pass/fail rollup counts only `action=="note"` steps (`:1231-1234`). `_render_report()` at `:1228-1337` with CSS `_REPORT_CSS` `:1340-1434`. Only `ios_scroll_to`/`ios_assert_*` manually record a `fail` note before raising (`:582-585,1042-1043,1062-1063`).

**Proposal.**
- Give each recorded step an optional structured `verdict` object (`kind`, `reason`, and for errors the I7 `error_code`/`error_kind`), rendered in the report alongside the existing `note`. Keep `note` for backward compatibility.
- When a tool raises, record a `fail` step with the structured verdict automatically (a small wrapper at the raise boundary or in the run recorder), so failures always appear in the timeline without each tool remembering to.
- Adopt Argent's six-way idle verdict vocabulary for `ios_await_idle` (I5) as structured fields: `never-settled` / `partially-moving` / `timed-out-mid-hold` / `empty-tree` / `settled-tree-only-no-pixels` / `too-few-reads`. Idle never fails a run; it annotates it. This plays directly to our HTML-report differentiator.

**Tests.** Existing report tests read the rendered `report.html` for fragments (`test_imirror_mcp.py:1188-1190`). Add: a raised failure appears as a `fail` step with its `error_kind`; each idle verdict renders its label; rollup counts unchanged for the legacy `note` path.

**Dependencies.** Reads I7 error kinds and I5 idle verdicts. Sequence after both.

---

### I9 — PNG signature validation in `ios_screenshot`  (P3, Python, S, Low risk)

**Problem.** A non-image WDA response (a 404 body, HTML, a truncated payload) would be handed to the model as `image/png` and rejected with a confusing error.

**Current state.** `ios_screenshot` at `imirror_mcp.py:433-470` base64-decodes `/screenshot` and calls `_img_kind` (`:421-430`), which only sniffs the JPEG SOI marker (`\xff\xd8`) and otherwise assumes PNG with no magic-byte check.

**Proposal.** Validate the decoded bytes carry a real image signature (PNG `\x89PNG\r\n\x1a\n` or JPEG SOI) before returning; on mismatch, raise a clear `MCPToolError` (I7) that names the likely cause (WDA returned a non-image body) instead of returning a broken image block.

**Tests.** Stub `/screenshot` to return a valid PNG, a valid JPEG, and a garbage/HTML body; assert the first two return `Image` and the third raises with a clear kind.

**Dependencies.** Uses I7's error type if present; otherwise a plain `RuntimeError` is fine.

---

### I10 — Multi-editor MCP installer adapter  (P2, Swift, M, Low risk)

**Problem.** The installer supports only Claude Code and Claude Desktop, hardcoded, so adding editors means more linear branches.

**Current state.** `Sources/iMirror/MCPInstaller.swift` is a flat `enum` with two hardcoded blocks: Claude Code via shelling `claude mcp add/remove/get` (`MCPInstaller.swift:182-189,111-118,217-220`) and Claude Desktop via JSON merge into `~/Library/Application Support/Claude/claude_desktop_config.json` (`:27-30,193-204,222-226`). Detection is a fixed binary candidate list for the CLI (`:45-50,80-84`) and a status check for Desktop that requires an actual `MCPConfig.entry` in the config to report installed (`status()` at `:105-107`); the directory-exists check (`:192-194`) only gates whether *install* writes the config. `MCPConfig.swift` has pure JSON helpers (`merged`/`removed`/`contains`, `:12-58`); `MCPProfile.swift` holds `device`/`simulator` profiles (`:17-21`).

**Proposal.** Introduce a small `McpConfigAdapter` protocol (detect / config-path(s) / write / remove) and one conforming struct per editor, collected in an `allAdapters` array — Argent's pattern. Port the two existing clients into adapters first (no behavior change), then add Cursor, VS Code, Windsurf, Zed as adapters. Adopt Argent's **evidence-based detection**: do not treat a bare config directory as "installed" (iMirror creates some of these dirs itself, which would self-confirm a false positive); require a real signal (a binary on PATH, or a non-iMirror-authored config).

**Tests.** `MCPConfig.swift` helpers are already unit-tested and pure; add per-adapter path/format tests and an evidence-detection test (empty dir is not "installed"). Follow the existing Swift test style.

**Dependencies.** None.

---

### I11 — Loopback Host-allowlist hardening (defense-in-depth)  (P3, Swift, M, Low risk)

**Problem.** WDA has no auth on the wire. Argent fronts its loopback server with a Host-header allowlist (run before auth) to close the DNS-rebinding class, plus a per-spawn bearer token.

**Current state.** iMirror's posture is "never bind or dial anything but loopback": `WDAClient` preconditions `host == 127.0.0.1 || localhost` (`Sources/iMirror/WDAClient.swift:33-35`); `LocalRelay` binds `requiredLocalEndpoint` to `127.0.0.1` only (`Sources/iMirror/Transport.swift:202-212`) and is a **raw TCP byte pump** with no HTTP/Host inspection (`Transport.swift:219-227`). No Host check, token, or origin guard exists.

**Proposal (honest severity: defense-in-depth, not a live exploit).** The DNS-rebinding risk is real in principle — a local web page could resolve a hostname to `127.0.0.1` and reach WDA — but it is largely blunted here because WDA's state-changing endpoints require JSON POSTs, which browsers gate behind a CORS preflight WDA will not satisfy. Still, to close the class definitively and match Argent: make `LocalRelay` HTTP-aware enough to read the request line's `Host` header and reject any value that is not an approved loopback host before proxying bytes. A bearer token is a larger change (WDA does not check one) and is likely not worth it; recommend Host-allowlist only. Fable to confirm severity/appetite before we spend effort here.

**Tests.** Relay-level test: a request with a loopback `Host` proxies through; a request with a foreign `Host` is rejected. Keep the existing loopback-precondition tests.

**Dependencies.** None. Lowest priority; include for completeness, cut first if we trim scope.

## 5. Proposed sequencing (reviewable PRs)

Each PR is independently shippable and keeps the MCP unit suite green (no device).

1. **PR-A (read path):** I1 (text tree) + I2 (tiered timeouts). Highest context + reliability win, one coherent area.
2. **PR-B (interaction reliability):** I5 (await_idle + wait_for contract) + I6 (run_sequence) + I9 (PNG validation).
3. **PR-C (errors + report):** I7 (error codes) then I8 (structured verdicts + idle vocabulary). I8 depends on I7 and I5.
4. **PR-D (capture liveness, Swift):** I3. Standalone, different subsystem/reviewer; can run in parallel with A–C.
5. **PR-E (installer, Swift):** I10.
6. **PR-F (optional):** I4 spike outcome, and I11 hardening. Cut first if trimming.

Rationale: front-load the two P1 Python items and the P1 Swift capture fix; keep error/report changes after the primitives they describe exist; treat I4 and I11 as optional tail.

## 6. Cross-cutting concerns

**Testing.** Every Python change ships with tests in `mcp-server/test_imirror_mcp.py` using the existing `FakeWDA` fixture / `_req` monkeypatch / `time.sleep` stub patterns; no test may require a device or WDA (per `CLAUDE.md`). Run before each commit:
```
mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py
mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py
```
Swift changes (I3, I10, I11) ship with `iMirrorCore` unit tests where the logic is pure (the capture-decision and MCPConfig code already are) and follow the existing Swift test style.

**Backward compatibility.** I7 subclasses `RuntimeError` so existing `pytest.raises(RuntimeError, ...)` tests stay green; `ios_source` keeps a `format="xml"` escape hatch (I1); the report keeps the legacy `note` field (I8). No tool is renamed or removed.

**Rollback.** Each item is additive and independently revertible. New behavior that changes a default (the `ios_source` text default, the `TREE` retry-on-timeout) is guarded so we can flip back to the old default via a parameter or constant if a regression appears in the field.

**Non-porting reminder.** Nothing in this plan depends on a simulator, dylib injection, or a Metro/Hermes debug build. If an item starts to require any of those, it is out of scope by definition (section 2).

## 7. Lower-confidence backlog (not scheduled; raise if Fable wants them in)

- **`alwaysLoad` / `searchHint` tool metadata** for progressive tool loading. Value is real at ~30 tools, but depends on whether our Python MCP SDK surfaces the `_meta` annotations Argent uses; verify SDK support before committing.
- **`{{secret:NAME}}` typed-secret handling** with placeholder-echo and screenshot suppression. Only worth it if we add a login-during-test story; needs a server-side substitution layer we do not have.
- **Release-age-aware update check** against GitHub Releases (Argent checks the actual next version + the user's min-release-age policy). Maps onto our notarized `.app` appcast; small, but no current update-nudge surface to hang it on.
- **`ios_screenshot_diff`** (plain pixel diff, no OCR/font machinery). Useful for the report; deferred because our single-device setup does not have the cross-OS-version regression need that justifies Argent's version.
- **Ship a tool-usage rule file** encoding the discovery-before-tap discipline ("never derive tap coordinates from a screenshot; call a discovery tool before every tap; if a tap fails twice at the same point, re-run discovery") and an intent→tool decision table, alongside the existing `ios-test-report` skill.

## 8. Open questions for Fable

1. I2: is the "last-known foreground app/screen" tie-breaker hint worth it on a single-app real-device flow, or over-engineering?
2. I3: what corroboration should gate the static/black content heuristic so a legitimately dark or paused UI is never misread as wedged? Is `AVCaptureSessionWasInterrupted` (telephony reason) the right corroborator, or do we need more?
3. I4: spike now or defer? Which cheap signal (downscaled screenshot hash vs compact-tree fingerprint) do you want measured first, and what latency budget makes it worth shipping?
4. I11: given the CORS-preflight mitigation, is the Host-allowlist worth the effort now, or park it?
5. Sequencing: any reason to pull I3 (capture fix) ahead of the Python read-path PR, given it targets the most user-visible bug?

## 9. Fable review outcomes (2026-08-13) — accepted corrections

Fable reviewed this plan against the real source and verified every `file:line`. Verdict: sound to execute with the corrections below. These amendments supersede the item cards where they conflict.

### Cross-cutting (apply to all items)

- **Error serialization over the MCP wire (critical, affects I7/I8/I9).** FastMCP returns a raised exception to the agent as `str(e)`. `error_code`/`error_kind` as exception *attributes* reach the in-process report but NOT the agent over the wire. I7 must encode the code/kind into the message string (e.g. a machine-readable tail `[kind=timeout code=WDA_TIMEOUT]`) or use the installed `mcp[cli]` structured-error path if it has one. Without this, "the agent can classify without regexing prose" is not delivered.
- **Concurrency note required.** `_run`/`_record`, `_session`, and `_window_cache` are module globals mutated from multiple threads; `_gesture_lock` (`imirror_mcp.py:306`) covers gestures only. I5 idle polling and I6 sequences widen the concurrent surface. The plan must state what is single-writer (run recording) and whether sequences are atomic.
- **Versioning / default-flip.** Changing the `ios_source` default to text and the report schema requires bumping `__version__` (drives the installer staleness check, `MCPInstaller.swift:100-121`) and stating the default flip in the tool docstring the agent actually reads.
- **WDA provenance.** `scripts/build-wda.sh` has no version pin and WDA source is not vendored. Any WDA-feature dependency (I1) must probe at runtime and state a minimum upstream WDA version.

### Per-item amendments

- **I1.** Cannot assert WDA supports `?format=json` (unvendored/unpinned). Probe once (`GET /source?format=json`, confirm value is a dict) and fall back to stdlib `xml.etree` parsing of the XML form; the renderer accepts both. The win is context/parse only, not a cheaper device-side snapshot (snapshot acquisition dominates). Cap output by ELEMENT COUNT, not bytes — the renderer must parse the full payload (160KB+) before emitting; keep the "N elements dropped" message. Normalized frames use `_win_size()` (`:322-331`, 30s cache, orientation-invalidated via `ios_orientation` `:688`) — document that dependency. Add a fixture-based element-cap upper-bound test.
- **I2.** `TREE` tier = ~30s (not 60). Do NOT blind-retry on timeout: before retrying a read, do a cheap `GET /status` (PROBE tier) and retry only if it answers; cap total wall time ~75s. Rationale: WDA serializes on one XCUITest queue, so a blind retry queues a second full-tree serialization behind the stalled main thread and can push a single call past the MCP client's own timeout. Poll loops (`ios_wait_for`, asserts) `_find_element` calls should use the PROBE tier. Drop the last-known-foreground hint (Q1).
- **I3.** Do NOT fingerprint in `captureOutput` (a full-buffer luma pass is ~350-700MB/s on the frames queue). Hash once per watchdog tick on the watchdog thread via `FrameGrabber.snapshot()` (`main.swift:238-240`, retained latest buffer): `CVPixelBufferLockBaseAddress`, plane-0 only, stride-sampled grid (e.g. 16x16). The content signal is ADVISORY-ONLY: it may only select the waiting/occluded UI message; it must NEVER trigger recovery or count toward dead-marking — frame age alone keeps driving recovery unchanged (`CaptureLiveness.swift:86-105`). Reset `consecutiveStaticFrames` on rebind/`markActive()` (`main.swift:243-245`) or a recovery onto the same static screen instantly re-trips it. Corroboration: static/near-black + active `AVCaptureSessionWasInterrupted` (telephony) selects the call-specific waiting message; sustained static/near-black without an interruption selects the generic waiting overlay.
- **I4.** Defer the spike. Ship the opt-in settle parameter path now (`settle_ms` already exists on swipe/scroll, `imirror_mcp.py:515,539`); spike only if `ios_await_idle` proves too slow. The spike must use a downscaled/quantized comparison WITH TOLERANCE, not byte equality (status-bar clock, spinners, and cursor keep exact hashes unstable). Budget: a default-on settle must add under ~500ms median per action or it stays opt-in.
- **I5.** "First visible element in reading order" must use an extended WDA predicate (`visible == 1 AND ...`), NOT `/elements` + per-element rect calls (N round trips = real-device perf regression). "Quote what it saw" on timeout needs one extra read on the failure path only: take one I1 compact-tree snapshot and append its first ~10 lines. This makes I5 genuinely depend on I1 (correct the stated dependency).
- **I6.** Pre-validate ALL steps before executing step 1 (a typo in step 5 must not strand the device mid-flow). Decide gesture-lock semantics explicitly: `_gesture_lock` is per-gesture, so another agent's tap can interleave between sequence steps — either hold a sequence-level lock or document that sequences are not atomic.
- **I7.** See the cross-cutting error-serialization fix (the critical part). Subclassing `RuntimeError` confirmed safe: 29 `pytest.raises(RuntimeError, ...)`, no `type(e) is` / `excinfo.type ==` identity checks, nothing catches `RuntimeError` in a way subclassing changes. All 111 tests stay green.
- **I8.** Auto-record-on-raise MUST dedupe against the manual fail notes already emitted by `ios_scroll_to` (`:582-585`) and both asserts (`:1042-1043,:1062-1063`), or remove those manual records in the same change (otherwise double fail steps). Rollup semantics CHANGE: auto-recording flips previously-PASS reports to FAIL (today only `note` steps count, `:1231-1234`). This is NOT backward-compatible for the rollup — call it out explicitly and test it, do not slip it under "backward compatible". Derive the idle verdict enum from whatever signal I5 actually ships; do not import `settled-tree-only-no-pixels` if we build screenshot-only. Note the new optional field on the `steps.jsonl` schema (`:127-133`).
- **I9.** Fine. The commit message/comment must acknowledge it reverses the documented lenient-default design (`:424-427`) and update that comment.
- **I10.** The adapter protocol must be behavior-shaped (detect / install / remove / status), NOT "config-path / write" — Claude Code is CLI-driven (`claude mcp add/remove/get`, `:182-189`), so a config-path protocol cannot port it without behavior change. The false-positive detection risk is PROSPECTIVE (a requirement on the new adapters), not a current bug. Adding Cursor / VS Code / Windsurf / Zed (4 formats + 4 detection strategies) is a SEPARATE PR after the no-behavior-change refactor.
- **I11.** PARK IT. A Host allowlist on `LocalRelay` does not close DNS-rebinding while go-ios `forward` publishes WDA directly on `127.0.0.1:8101` (`Transport.swift:7-10,:404`), bypassing the relay at `:8100`. Real closure needs guarding/randomizing the backend port too (bigger than M). Combined with the CORS-preflight mitigation, park entirely; the 8101 finding is recorded here so nobody ships the half-measure believing it helps.

### Answers to the section-8 open questions

1. **I2 hint:** drop it. Over-engineering for a single-app real-device flow; cached "last known foreground" that tie-breaks a timeout is a new way to be confidently wrong.
2. **I3 corroboration:** make the content heuristic advisory-only (never recovers, never dead-marks). Static/near-black + telephony interruption → call-specific waiting message; sustained static/near-black without interruption → generic waiting overlay. No further corroborator needed once it cannot hard-fail anything.
3. **I4:** defer the spike; ship the opt-in parameter now. If the spike runs, measure the downscaled-screenshot hash (with tolerance) first; a default-on settle must stay under ~500ms median/action.
4. **I11:** park it (see amendment).
5. **I3 sequencing:** yes, pull it forward — run it in parallel with PR-A from day one and land first if ready.

### Amended sequencing and cut-list

- Run PR-D (I3) in parallel from day one; land it first if ready (Swift-only, standalone, most user-visible bug).
- If trimming to three items: **I3, I1, I2** (I2 amended per above). I5 is the runner-up — first to add back if budget stretches to four.
- I11 should not ship in its current form at all.

## 10. I12 — simctl IO fast-path for the simulator branch (added 2026-08-13)

**Context.** iMirror's simulator mode still drives the sim through WDA/XCUITest (port 8201) for gestures, screenshots, and the AX tree; `simctl` is used today only for install/push/privacy/status-bar (`_simctl`, `imirror_mcp.py`). On the simulator (unlike a real device) Apple's own public `simctl` can do IO-heavy operations faster and session-free.

**Why not port argent's simulator engine.** Their fast components (`simulator-server`, `ax-service`, injection dylibs) are closed-source and licensed no-reverse-engineering — unusable. Rebuilding them would mean our own SimulatorKit/CoreSimulator HID injector + a `simctl spawn` AX daemon + a DYLD-inject dylib: Radon-scale work on private, version-fragile frameworks, and the injected devtools only work for RN/dev builds you launch. Out of scope.

**In scope.** Route IO-heavy ops through public `simctl` on the `_IS_SIM` branch only:
- Screenshots (this item): `xcrun simctl io booted screenshot` — session-free, faster than the WDA round-trip. Falls back to the WDA path if simctl fails, so the sim path never regresses.
- Follow-ons (implemented): video via `simctl io booted recordVideo`, wired into `ios_start_run`/`ios_finish_run` so a run report on the simulator gets a real screen recording instead of a screenshot timelapse (falls back to the timelapse if the recording is unavailable); pasteboard via `simctl pbcopy/pbpaste`.

**Explicit non-goals.** Gestures and the accessibility tree stay on WDA (no public `simctl` equivalent; the only faster path is the closed injection engine). Do not rebuild `simulator-server` or any dylib injection.

**Design (screenshot).** Factor the WDA capture into `_screenshot_bytes_wda()`; add `_screenshot_bytes_simctl()` (writes a temp PNG via `_simctl("io","booted","screenshot",path)`, reads then deletes it). `ios_screenshot` picks simctl on `_IS_SIM` with a WDA fallback on failure, then runs the shared `_img_kind` validation + active-run save/record. The device path is unchanged.

**Tests (device-free, use the `sim_mod` fixture).** Sim mode captures via simctl (WDA `_req` not called); a simctl failure falls back to WDA; device mode unchanged; simctl invoked with the correct args.
</content>
