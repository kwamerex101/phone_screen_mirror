# Physical iPhone smoke test

30 October 2026, Africa/Accra. Tested the PR #44 review build against a USB-connected iPhone on iOS 27.0.1, WebDriverAgent 16.14.2, and go-ios 1.3.2.

## Result

The tested connection, navigation, recording, disconnect, and automatic reconnect paths passed after correcting two issues uncovered on hardware.

| Check | Evidence |
| --- | --- |
| USB discovery and readiness | One physical USB target detected; WDA reports ready. |
| Read-only live checks | Status, 420 x 912 logical screen size, valid screenshot, accessibility source, orientation, and cached session reuse passed. |
| Selector navigation | Opened Settings, found General, tapped it by label, and verified About was visible. No phone settings were changed. |
| Recording/report generation | Existing recorded-run integration test passed on the General screen. Screen contents are excluded from this report. |
| Session coexistence | Patched agent adopted the app's existing session. Twelve observations over 14.62 seconds remained on one session; a missing-element lookup preserved it. |
| Cable removal | USB absence confirmed at 09:07:57 UTC. UI showed No iPhone connected, cleared stale video, and disabled Screenshot, Home, and Control. |
| Cable reattachment | USB presence observed at 09:08:36 UTC. WDA became ready 3.03 seconds after the harness observed presence, without a retry click or Automation toggle. |
| Video and controls after reconnect | UI resumed Mirroring. Screenshot and Home became available; local Control armed and disarmed correctly and was left off. |
| Native Home action | Clicking Home in the Mac app brought SpringBoard to the foreground. |
| Fresh MCP connection | A newly initialized stdio client exposed 33 tools, read screen size, checked a missing element, and inspected alert presence without replacing the active session. |
| Final live suite | Eight tests passed after reconnect. The two generic gesture tests were deselected; selector tapping and native Home were verified separately instead of tapping an arbitrary point on the user's screen. |

The 3.03-second figure is a single warm-reconnect observation measured from the harness's USB detection, not a cold-start benchmark or a timing guarantee.

## Issues found and corrected

### Stale local go-ios build artifact

The installed app used go-ios 1.3.2, but the local tools cache and original review bundle contained 1.1.0. The installed app passed six initial read-only checks; the stale-helper review bundle failed its WDA startup window. Reassembling the same review app with the known working helper restored readiness.

The helper's Go build metadata identifies the audited 1.3.2 source revision `2fb34682ef12db97c9fafdf99f1dd1d3522604ad`. The local cached binary was corrected from the existing installed build, with the previous binary backed up. Existing dependency-file changes in the vendored checkout were preserved.

Both assembly scripts now accept `IMIRROR_IOS_BIN`, consistent with the runtime override. Invalid overrides and an override pointing inside the app being rebuilt fail before changing the app. Four preflight checks passed. The go-ios build script now rejects an outdated source revision before changing dependency files. The local vendored source checkout itself still needs preparation at the audited revision before a future source rebuild.

Reproduce the verified local assembly with:

```bash
IMIRROR_IOS_BIN=/Applications/iMirror.app/Contents/Resources/ios \
  IMIRROR_NO_LAUNCH=1 scripts/run.sh debug
```

### App and agent replacing each other's WDA session

The initial stability check observed an active session different from the agent's initial session in 11 of 12 samples. A control check that joined the existing app session remained stable for ten samples, isolating independent session creation as the cause.

The MCP server now checks WDA status before creating a session and adopts an existing active session. Expired-session recovery uses the same path. It creates a session only when none is reported, and a failed discovery response cannot trigger a replacement. Four new regression cases failed before the fix; the updated full Python suite passed 262 tests afterward. A live integration regression checks that an agent adopts rather than replaces the already active app session.

A stale connection from the earlier app restart also produced an explicit unknown-outcome session-creation error once. The foreground state was inspected before retrying. The fresh-client MCP test passed after the session-adoption fix.

## Limits and handoff

This verifies one unlocked, trusted, already-provisioned phone and one manual unplug/replug cycle. Fresh WDA installation, provisioning failures, locked-device recovery, multiple attached phones, sleep/wake, and sustained latency are not established by this pass. The legacy physical install subprocess timeout recommendation remains open.

The native review build is in `build/iMirror.app`; the installed `/Applications` app was not replaced. Reconnect the MCP client or start a fresh client process to load the session-sharing fix. The Mac app was left mirroring with local Control off.

## Bundle integrity follow-up

The post-startup signature check found that Python created `__pycache__/wda_bringup.cpython-313.pyc` inside the signed bundle. The bundle smoke checker now compares its MCP resource files before and after protocol initialization. That check failed on the original import path. Suppressing bytecode writes only while importing the bundled sibling helper fixed the failure; the Python process's prior bytecode setting is restored afterward.

Fresh initialization still exposes 33 tools, the resource snapshot remains unchanged, and `codesign --verify --strict` passes after startup. The Mac CI job now runs this bundle-startup and signature check to retain coverage.
