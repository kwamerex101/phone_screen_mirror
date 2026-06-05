# phone_screen_mirror

iMirror — mirror and control a real iPhone from macOS. The repo has two parts:

- **macOS app** (Swift) — brings up WebDriverAgent over a self-managed transport
  and mirrors the device screen.
- **MCP server** (`mcp-server/`) — a Python MCP server that drives the device
  (tap/swipe/type/screenshot/…) and records test runs into HTML reports.

## MCP server — always run the tests locally

There is **no CI**. Before committing or opening a PR for anything under
`mcp-server/`, run the unit suite locally and make sure it passes:

```bash
mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py
```

First-time setup (creates the venv the command above expects):

```bash
python3 -m venv mcp-server/.venv
mcp-server/.venv/bin/pip install "mcp[cli]" pytest
```

The unit tests stub the HTTP layer, so they need **no device and no
WebDriverAgent**. Keep them that way — new tests must not require a phone.

When you change `imirror_mcp.py`, also run a quick compile check:

```bash
mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py
```

### Live integration tests (optional, needs a device)

`mcp-server/test_integration.py` exercises the real WebDriverAgent wire and is
**skipped by default**. Run it only with the iMirror app running and its health
dot green:

```bash
IMIRROR_LIVE=1 mcp-server/.venv/bin/python -m pytest mcp-server/test_integration.py -v
```

## Conventions

- Keep the MCP server dependency-light: standard library + `mcp[cli]`. The
  timelapse feature shells out to `ffmpeg` if present and degrades gracefully if
  not — don't add it as a hard dependency.
- The server talks to WDA on **loopback only** (WDA has no auth on the wire).
  Never relax the loopback guard in `imirror_mcp.py`.
