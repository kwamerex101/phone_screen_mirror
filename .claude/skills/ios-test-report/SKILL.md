---
name: ios-test-report
description: Drive an iPhone through a test flow with the iMirror MCP and produce a self-contained HTML report (screenshots + step timeline) at the end. Use when the user asks to test a flow on the device AND wants a report/recording/evidence of the run — e.g. "test the login flow and give me a report", "record this run", "walk through checkout with screenshots". Reporting is opt-in: only record when the user asks for it.
---

# iOS test report

Run a flow on a real iPhone via the **iMirror MCP** server and generate a
self-contained HTML report of what happened — a timeline of every action with
embedded screenshots and pass/fail checkpoints.

## When to use

Use this skill ONLY when the user wants a record of a device test, not for
ordinary one-off device control. Triggers: "test … and give me a report",
"record this run", "with screenshots", "produce evidence", "report at the end".

If the user just wants to tap around the phone, drive the MCP tools directly and
do **not** start a run — recording is opt-in and adds overhead.

## Prerequisites

The iMirror app must be running with its toolbar **health dot green** (it brings
WebDriverAgent up on `127.0.0.1:8100`). Verify with `ios_status` first; if it's
not ready, tell the user to start the app rather than retrying blindly.

## Workflow

1. **Confirm scope.** Restate the flow you'll test and that you'll produce a
   report. If the steps are ambiguous (which screen to start from, what counts as
   success), ask before driving the device — a wrong tap is hard to undo.

2. **Start recording.** Call `ios_start_run(label="<short flow name>")`. Nothing
   is recorded before this. Runs are written under `~/.imirror/runs/` (override
   with the `IMIRROR_RUNS_DIR` env var).

3. **Drive the flow.** Use the normal tools — `ios_tap`, `ios_swipe`, `ios_type`,
   `ios_find_and_tap`, `ios_press_button`, `ios_wait_for`. Each is logged
   automatically while the run is active.
   - **Screenshot at every meaningful state change** (`ios_screenshot`): after a
     navigation, before/after a submit, on the final screen. These are the report.
   - Use `ios_wait_for(text)` after transitions so screenshots aren't taken mid-load.
   - Read the screen with `ios_source` when you need exact labels to drive
     `ios_find_and_tap`; prefer find-and-tap over hard-coded coordinates.

4. **Annotate checkpoints.** Call `ios_run_note(text, status=...)` to mark what a
   step verified:
   - `status="pass"` — an expectation was met (e.g. "home screen shown after login").
   - `status="fail"` — an expectation was NOT met. Any failure note flips the
     report's overall verdict to FAIL and is highlighted.
   - `status="info"` — a neutral milestone.
   Take a screenshot **before** a `fail` note so the report shows the bad state.

5. **Finish.** Call `ios_finish_run()`. It writes `report.html` to the run
   directory and returns the path. Recording stops.

6. **Report back.** Give the user the returned path as a clickable link and a
   one-line verdict (PASS/FAIL + step/screenshot counts). Don't paste the HTML.

## Error handling

- If a tool raises mid-flow, add an `ios_run_note(..., status="fail")` describing
  what broke, take a screenshot if the device is still responsive, then
  `ios_finish_run()` so the partial run is still captured — don't discard it.
- If `ios_start_run` was never called, the action tools simply don't record;
  there's nothing to finish. Don't call `ios_finish_run` without a run.

## Example

User: "Test the login flow and give me a report."

1. `ios_status` → ready.
2. `ios_start_run("login flow")`
3. `ios_screenshot` (login screen) →
   `ios_find_and_tap("Email")` → `ios_type("user@example.com")` →
   `ios_find_and_tap("Password")` → `ios_type("hunter2")` →
   `ios_find_and_tap("Sign In")`
4. `ios_wait_for("Home")` → `ios_screenshot` →
   `ios_run_note("home screen shown after login", status="pass")`
5. `ios_finish_run()` → `/Users/.../.imirror/runs/20260605-…-login-flow/report.html`
6. Reply: "PASS — login flow, 7 steps, 2 screenshots. Report: <path>"
