# iMirror project review and implementation

30 October 2026. Baseline: `501a15f` (v0.6.0). Hardware follow-up: [physical iPhone smoke test](2026-10-30-physical-smoke.md). Review covers the native Mac app, physical-device transport, simulator lifecycle, MCP navigation, streaming, packaging, and automated checks.

## Decision

Keep the native app, local WDA transport, and dependency-light MCP implementation. Prioritize trustworthy connection state and agent actions before a visual redesign or more tools. A wrong-device action, duplicated input, false absence assertion, or stale green status is more costly than an extra tool call.

The existing app already has selector navigation, condition polling, scroll-to-element, batching, screenshots, and recorded run reports. The work strengthens these paths rather than replacing them with another automation framework.

## Comparison with similar products

| Product | Relevant evidence | Recommendation for iMirror |
| --- | --- | --- |
| [Mobile MCP](https://github.com/mobile-next/mobile-mcp/blob/main/src/server.ts) | Its agent instructions favor accessibility observations, element references, direct app launches, and batching. | Teach the agent an observation/action loop at initialization; make compact observations smaller and target selection explicit. |
| [Maestro](https://docs.maestro.dev/maestro-flows/flow-control-and-logic/wait-commands) | Its assertions poll for expected UI and return as soon as conditions hold. It distinguishes element presence from animation completion. | Prefer iMirror's existing wait/assert tools to arbitrary sleeps. Fix error handling so transport failure cannot masquerade as absence. |
| [idb](https://fbidb.io/docs/idb/ui/) | Accessibility reads expose labels and geometry; requesting fewer attributes reduces target work. Its documented accessibility operations are simulator-only. | Keep WDA as the shared physical/simulator interface. Reduce returned observation noise first; measure before changing snapshot fidelity. |
| [Apple iPhone Mirroring](https://support.apple.com/en-us/120421) | Requires a locked iPhone and has explicit connection and pause states. | Preserve iMirror's usable physical phone and agent control. Give connection loss a clear waiting/reconnect state instead of showing a frozen screenshot as live. |
| [Appium XCUITest](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/reference/settings.md) | Exposes snapshot limits, expensive-attribute exclusions, screenshot format, and wait settings. | Keep source fidelity by default. Consider opt-in observation profiles only after measuring representative screens. |

These are design comparisons, not a claim that the tools share identical requirements or that iMirror matches Apple's input latency.

## Supported findings and implemented changes

### MCP correctness and target safety

1. **Normal missing elements recreated WDA sessions.** `_find_element` treated every HTTP 404 as an expired session. [WDA's error definitions](https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Routing/FBCommandStatus.m) use 404 for several different errors. Recovery now checks `value.error`; only an invalid session triggers recreation. Missing elements preserve the current session, and other lookup errors propagate rather than making an absence assertion pass.
2. **Dropped responses could replay actions.** A tap or typing POST could already have executed before its connection failed. Ambiguous mutation failures now return `kind=outcome_unknown` without automatic replay. Read-only GET retries remain. Agents are instructed to observe the screen before deciding whether to repeat an action.
3. **Reused sockets retained an old timeout.** Updating `HTTPConnection.timeout` did not update its existing socket. Each request now applies its timeout to the live socket, so a short probe cannot silently impose its deadline on a full source read.
4. **Simulator helpers could target a different simulator.** All simctl helpers and video recording now share a pinned UDID. `IMIRROR_SIM_UDID` selects explicitly; otherwise exactly one booted available iOS simulator is required. Multiple candidates produce an actionable error. Screenshot and clipboard fallback cannot bypass selection ambiguity.
5. **Physical installs ignored explicit device selection.** Both installation paths now pass `IMIRROR_UDID` to go-ios.
6. **Headless teardown could terminate another owner's transport.** Python bringup now cleans up only its tracked children and rolls back partial startup on failure; broad `pkill` was removed from this path.

MCP status now returns the configured target, endpoint, and known/configured UDID. This is configuration context, not independent proof that an arbitrary WDA endpoint belongs to that UDID.

### Agent usability and observation cost

MCP 1.3.0 adds an explicit `ios_alert` tool to read dialog text and buttons or choose accept, dismiss, or an exact named button. It does not auto-accept alerts, replay alert mutations, or include dialog contents in run recordings. A real system dialog reproduced the navigation blocker; explicit Not Now dismissal cleared it.

MCP 1.3.0 publishes initialization instructions: check status, prefer compact accessibility source and selectors, use condition waits, batch known sequences, and use screenshots for visual or inaccessible content. Unknown mutation outcomes require observation before another action.

Compact source deduplicates identical label/name/value/identifier values, caps each value at 240 characters, and caps the response at 20,000 characters. Whole retained element lines still include geometry and available interaction flags. Truncation is explicit and points to XML for more detail; XML also retains its existing length limit.

The in-app installer now supports Codex through its CLI, alongside the existing clients. Status checks parse Codex's JSON output and validate command, arguments, enabled state, and required environment. Installation is an explicit UI action. Tests use injected commands and do not alter real client configuration. CLI behavior was checked against [official OpenAI documentation](https://learn.chatgpt.com/docs/extend/mcp) and the installed CLI help.

### Connection lifecycle and UI

- A transport startup sweep could finish after Automation was switched off and spawn children anyway. Generation checks now guard both background preparation and main-queue completion.
- Old health, session, and video callbacks could restore connected state after a toggle or replacement connection. Callback scopes now invalidate those completions.
- The recovery ladder reused an expired outage clock after a full restart. Restart preparation and actual WDA launch now receive fresh deadlines while preserving the escalation stage.
- Disconnect clears the last displayed frame and screenshot availability, so stale video cannot appear to be a current device view.
- USB presence discovery runs off the main thread, with a process deadline and a minimum six-second sample interval while down. Verified absence shows a waiting-for-iPhone state and stops unnecessary children. Verified reattachment re-arms recovery. Discovery failure is distinct from absence; a still-present wedged phone does not get an endless retry loop.
- Simulator readiness continues to be checked after startup. A lost runner leaves ready state, can recover, and has a finite recovery deadline. Startup is bounded as well. Simulator selection is disabled while active, startup callbacks are generation guarded, subprocess checks are bounded, and quitting stops the owned runner.
- MCP install progress now reaches AppKit on the main queue.

### Streaming and packaging

Repeated MJPEG starts previously left the old socket open. Starts now close the old connection, and stop/restart invalidates delayed reconnect work. The parser rejects negative, malformed, duplicate, or oversized lengths and bounds headers to 16 KiB and compressed frames to 8 MiB. A malformed stream reconnects instead of accumulating unlimited data. Each receive batch decodes its newest complete image, preserving an incomplete tail.

Both app assembly scripts now include the required `wda_bringup.py` module. A bundled MCP smoke checker starts the actual bundle from a temporary directory, initializes the MCP protocol, and verifies tool discovery and agent instructions. A hardware-free Python CI job now covers both MCP test suites in addition to existing Swift CI.

## Measurements and verification

- Before the request-handling fixes, focused new regressions produced nine failures. Target/cleanup regressions and compact-source regressions also failed before their fixes.
- The repeated-start real TCP test failed before the stream fix because the old connection never closed. It passes after the fix.
- A 100-button repeated-field fixture shrank from **27,584 to 12,084 characters**, a **56.2% reduction**, retaining all 100 buttons. A one-million-character label shrank from **1,000,100 to 414 characters**, including an explicit truncation notice. These are output-size measurements, not token counts or device-latency benchmarks.
- Live iOS 27 simulator checks passed: status, logical size, screenshot, source, orientation, session reuse, recorded report, tap, and Home. An additional agent-style flow launched Settings, waited for General, tapped it by selector, verified About, and returned Home. A missing-element lookup preserved its WDA session.
- The first Linux CI run exposed three legacy timelapse tests that assumed ffmpeg was installed despite stubbing its execution. All three failed locally with a restricted PATH before the availability stubs were fixed. The complete 258-test Python suite then passed without Homebrew tools.
- Swift: **157 tests passed** across both test bundles. Python: **258 tests passed**, with nine opt-in live tests skipped in the default full run. The separately enabled simulator suite passed all nine live checks. Bundled MCP protocol initialization and tool discovery passed.

The initial overnight review had no physical iPhone attached. The subsequent hardware follow-up verified one unplug/replug cycle, live navigation, session sharing, and bundle signature preservation. Fresh installation/provisioning and sustained physical-device latency remain unverified. See the linked smoke report for the tested scope.

## Further recommendations

1. **Coordinate WDA ownership across app and agent processes.** WDA has shared session and port state. Add an explicit owner/lease protocol before promising independent concurrent agents or multiple physical targets. The Swift app's existing orphan sweep still assumes it owns its go-ios chain; the Python cleanup fix does not remove that broader limitation.
2. **Unify target identity from app selection to every MCP operation.** Explicit UDIDs prevent ambiguous simctl selection, but arbitrary configured endpoints are not identity verified. Publish a small local target descriptor or perform a verified handshake before supporting simultaneous WDA targets in one profile.
3. **Measure end-to-end latency on physical hardware.** Separate tunnel startup, runner install, WDA boot, source acquisition, image transfer, and decode. Report median and p95 for representative screens before adding quality presets or changing idle/snapshot settings.
4. **Treat simulator build progress as a real state.** The existing launch script builds and runs in one child. A structured stage signal would let Settings distinguish compiling, installing, waiting, and reconnecting accurately. Do not infer these stages from elapsed time.
5. **Bound legacy physical install subprocesses.** USB discovery and simulator checks now have deadlines, but the physical runner install/list commands still use their older blocking process paths. Add cancellation and per-command deadlines before expanding unattended first-install promises.
6. **Add a repeatable hardware reconnect matrix.** Cover unplug during install, locked phone, trust prompt, sleep/wake, multiple attached phones, simulator termination, and process ownership contention. Keep destructive or privacy-sensitive actions outside unattended smoke tests.

Large-file splitting and a broad visual redesign were deliberately left for later. The highest-value seams in this pass are the request transport, callback lifetime, readiness monitor, parser, and client adapter. Their interfaces now concentrate real behavior and support focused tests; cosmetic file splitting would add little leverage.

## Independent review

The standards and behavior passes found three additional defects: a device-profile Codex registration accepted simulator environment overrides as current; read-only POST selector lookups lost safe reconnect retries; and mutation timeouts did not consistently report an unknown outcome. These findings were addressed with regression coverage. Read-only selector retries remain separate from action replay.

The review also checked generation ownership, fragmented stream parsing, simulator cancellation/shutdown, target ambiguity, and the report's claims against actual control flow. Hardware limitations and the remaining shared-owner risk above are retained explicitly.
