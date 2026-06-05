# iMirror MCP server

An MCP (Model Context Protocol) server that lets an MCP client — e.g. Claude —
**drive the iPhone directly**: take device screenshots, tap, swipe, type, press
hardware buttons, find-and-tap by visible text, read the accessibility tree, and
check status. Useful for testing flows on a real device without clicking the Mac
UI by hand.

It is a thin client over WebDriverAgent. The **iMirror app** must be running and
its toolbar health dot **green** — the app brings WDA up at `127.0.0.1:8100` via
its self-managed transport (userspace tunnel + runwda + forward + relay).

## Tools

| Tool | What it does |
|------|--------------|
| `ios_status` | WDA ready? + iOS version / device name |
| `ios_window_size` | logical screen size (points) for the current orientation |
| `ios_screenshot` | full-res device screenshot (PNG) — no macOS Screen Recording perm needed |
| `ios_tap(x, y)` | tap at a point (points, top-left origin) |
| `ios_swipe(from_x, from_y, to_x, to_y, duration_ms)` | swipe / drag / scroll |
| `ios_type(text)` | type into the focused field (`\n`=return, `\b`=backspace) |
| `ios_press_button(name)` | `home` / `volumeUp` / `volumeDown` |
| `ios_find_and_tap(text)` | find an element by visible label/name and tap it |
| `ios_wait_for(text, timeout_s)` | poll until an element with that label/name appears |
| `ios_source` | accessibility hierarchy (XML) of the current screen |
| `ios_start_run(label)` | begin recording a test run (opt-in) |
| `ios_run_note(text, status)` | add a checkpoint — `info` / `pass` / `fail` |
| `ios_finish_run()` | write a self-contained HTML report and stop recording |

## Setup

```bash
python3 -m venv mcp-server/.venv
mcp-server/.venv/bin/pip install "mcp[cli]"
```

Register with Claude Code (run from the repo root):

```bash
claude mcp add imirror --scope local -- \
  "$PWD/mcp-server/.venv/bin/python" "$PWD/mcp-server/imirror_mcp.py"
```

Or add to a client config (e.g. Claude Desktop `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "imirror": {
      "command": "/abs/path/phone_screen_mirror/mcp-server/.venv/bin/python",
      "args": ["/abs/path/phone_screen_mirror/mcp-server/imirror_mcp.py"]
    }
  }
}
```

Restart the client so it picks up the new server. Then start the iMirror app,
wait for the green dot, and the tools are live.

Override the target (default `http://127.0.0.1:8100`) with `IMIRROR_WDA` — it must
stay on loopback.

## Test reports (opt-in)

The server can record a **test run** and emit a self-contained HTML report —
a timeline of every action with embedded screenshots and pass/fail checkpoints.
Recording is off until you call `ios_start_run`, so normal device control is
unaffected.

1. `ios_start_run("login flow")` — begin recording.
2. Drive the flow as usual. Every tap / swipe / type / find / wait is logged, and
   each `ios_screenshot` is saved to the run directory.
3. `ios_run_note("home screen shown", status="pass")` — mark checkpoints
   (`info` / `pass` / `fail`; any `fail` flips the report verdict to FAIL).
4. `ios_finish_run()` — writes `report.html` and returns its path.

Runs are stored under `~/.imirror/runs/<timestamp>-<label>/` (override the base
with the `IMIRROR_RUNS_DIR` env var). The bundled **`ios-test-report` skill**
(`.claude/skills/`) walks Claude through this end to end — ask it to "test a flow
and give me a report".

## Tests

The unit tests stub the HTTP layer, so no device or WebDriverAgent is needed:

```bash
mcp-server/.venv/bin/pip install pytest
mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py
```

## Security

WebDriverAgent has **no authentication** on the wire, so the server refuses any
non-loopback target. These tools fully control the phone — use only on a device
you own, with consent.
