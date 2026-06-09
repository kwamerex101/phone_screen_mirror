#!/usr/bin/env python3
"""iMirror MCP — drive a real iPhone from an MCP client (Claude).

A thin MCP server over WebDriverAgent (XCUITest). It assumes WDA is reachable on
loopback at http://127.0.0.1:8100 — which the iMirror macOS app brings up itself
(userspace tunnel + runwda + forward + in-process relay). Start the app first,
wait for the toolbar health dot to go green, then connect this server.

Capabilities: device screenshot, tap, swipe, type, hardware buttons, find-and-tap
by visible text, accessibility source, and status/size.

SECURITY: talks to WDA over loopback only — WDA has no auth on the wire, so it
must never be exposed beyond localhost. These tools fully control the phone; use
on a device you own, with consent.

Run:  pip install "mcp[cli]"  &&  python imirror_mcp.py
Override target:  IMIRROR_WDA=http://127.0.0.1:8100
"""
from __future__ import annotations

import base64
import html
import http.client
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP, Image

WDA = os.environ.get("IMIRROR_WDA", "http://127.0.0.1:8100")
if not (WDA.startswith("http://127.0.0.1") or WDA.startswith("http://localhost")):
    raise SystemExit("Refusing non-loopback WDA target (WDA has no auth on the wire).")

mcp = FastMCP("imirror")

_session: dict[str, str | None] = {"id": None}

# Optional per-run recording. Off until ios_start_run; every action/screenshot is
# appended to _run["steps"], and ios_finish_run renders them into a report.
_run: dict[str, Any] = {
    "active": False, "dir": None, "label": None, "started": None,
    "device": None, "ios": None, "steps": [],
}


def _record(action: str, detail: str = "", screenshot: str | None = None,
            note: str = "") -> None:
    """Append a step to the active run. No-op when no run is recording."""
    if not _run["active"]:
        return
    _run["steps"].append({
        "i": len(_run["steps"]) + 1, "t": time.time(),
        "action": action, "detail": detail, "screenshot": screenshot, "note": note,
    })


# ---- HTTP helpers (fresh connection per request) -------------------------------

def _req(method: str, path: str, body: dict | None = None,
         timeout: float = 15) -> tuple[int, dict[str, Any]]:
    data = json.dumps(body).encode() if body is not None else None
    # WDA's CocoaHTTPServer occasionally drops a connection mid-exchange
    # (RemoteDisconnected / reset). Retry such transient failures a couple times.
    last_exc: Exception | None = None
    for attempt in range(3):
        req = urllib.request.Request(
            WDA + path, data=data, method=method,
            headers={"Content-Type": "application/json", "Connection": "close"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, {"error": raw.decode("utf-8", "replace")[:300]}
        except (http.client.RemoteDisconnected, ConnectionResetError,
                http.client.BadStatusLine, http.client.IncompleteRead) as e:
            last_exc = e
            time.sleep(0.3 * (attempt + 1))
            continue
        except urllib.error.URLError as e:
            raise RuntimeError(
                f"Cannot reach WDA at {WDA} ({e.reason}). Is the iMirror app running and "
                f"is the health dot green?") from e
    raise RuntimeError(
        f"WDA dropped the connection repeatedly on {path} ({last_exc}). "
        f"It may be busy or wedged — check the iMirror health dot.")


def _ensure_session() -> str:
    if _session["id"]:
        return _session["id"]  # type: ignore[return-value]
    code, j = _req("POST", "/session",
                   {"capabilities": {"alwaysMatch": {}, "firstMatch": [{}]}})
    sid = (j.get("value") or {}).get("sessionId") or j.get("sessionId")
    if not sid:
        raise RuntimeError(f"WDA session create failed (HTTP {code}): {j}")
    _session["id"] = sid
    return sid


def _session_post(subpath: str, body: dict, _retry: bool = True) -> dict[str, Any]:
    """POST to /session/<id><subpath>; recreate the session once on 404."""
    sid = _ensure_session()
    code, j = _req("POST", f"/session/{sid}{subpath}", body)
    if code == 404 and _retry:               # stale session (WDA restarted)
        _session["id"] = None
        return _session_post(subpath, body, _retry=False)
    if code >= 400:
        raise RuntimeError(f"WDA error (HTTP {code}) on {subpath}: {j}")
    return j


def _session_get(subpath: str, _retry: bool = True) -> dict[str, Any]:
    """GET /session/<id><subpath>; recreate the session once on 404."""
    sid = _ensure_session()
    code, j = _req("GET", f"/session/{sid}{subpath}")
    if code == 404 and _retry:               # stale session (WDA restarted)
        _session["id"] = None
        return _session_get(subpath, _retry=False)
    if code >= 400:
        raise RuntimeError(f"WDA error (HTTP {code}) on {subpath}: {j}")
    return j


def _pointer(steps: list[dict]) -> dict:
    return {"actions": [{"type": "pointer", "id": "finger1",
                         "parameters": {"pointerType": "touch"}, "actions": steps}]}


# Serialise gesture (/actions) posts across threads. WDA has a single XCUITest
# queue; two overlapping gestures stall it and can wedge the wire. With several
# agents (or test threads) sharing one MCP server, the lock prevents that.
_gesture_lock = threading.Lock()


def _gesture(steps: list[dict]) -> None:
    if not _gesture_lock.acquire(timeout=5):
        raise RuntimeError("WDA gesture lock timeout — another gesture is stuck")
    try:
        _session_post("/actions", _pointer(steps))
    finally:
        _gesture_lock.release()


# Logical screen size, cached briefly so scroll helpers don't re-query every call.
_window_cache: dict[str, Any] = {"size": None, "t": 0.0}


def _win_size() -> tuple[float, float]:
    now = time.monotonic()
    cached = _window_cache["size"]
    if cached and now - _window_cache["t"] < 30:
        return cached
    j = _session_get("/window/size")
    v = j.get("value", j)
    size = (float(v["width"]), float(v["height"]))
    _window_cache.update(size=size, t=now)
    return size


def _scroll_geom(direction: str, distance_pct: float,
                 x_pct: float, y_pct: float) -> tuple[float, float, float, float, float]:
    """Compute swipe endpoints for a scroll. `direction` is the CONTENT/reading
    direction: "down" reveals content further down the page (the finger swipes up),
    matching how people and agents say "scroll down". Returns (fx, fy, tx, ty, dist)."""
    w, h = _win_size()
    pct = max(15.0, float(distance_pct))
    cx, cy = w * x_pct / 100.0, h * y_pct / 100.0
    sv, sh = h * pct / 100.0, w * pct / 100.0
    d = direction.lower()
    if d == "down":    fx, fy, tx, ty = cx, cy + sv / 2, cx, cy - sv / 2
    elif d == "up":    fx, fy, tx, ty = cx, cy - sv / 2, cx, cy + sv / 2
    elif d == "left":  fx, fy, tx, ty = cx + sh / 2, cy, cx - sh / 2, cy
    elif d == "right": fx, fy, tx, ty = cx - sh / 2, cy, cx + sh / 2, cy
    else:
        raise RuntimeError("direction must be one of up / down / left / right")
    clamp = lambda v, m: min(max(v, 1.0), m - 1.0)
    fx, tx = clamp(fx, w), clamp(tx, w)
    fy, ty = clamp(fy, h), clamp(ty, h)
    return fx, fy, tx, ty, ((tx - fx) ** 2 + (ty - fy) ** 2) ** 0.5


def _scroll_once(direction: str, distance_pct: float, x_pct: float,
                 y_pct: float, duration_ms: int) -> tuple[float, float, float, float, float]:
    fx, fy, tx, ty, dist = _scroll_geom(direction, distance_pct, x_pct, y_pct)
    _gesture([
        {"type": "pointerMove", "duration": 0, "x": fx, "y": fy},
        {"type": "pointerDown", "button": 0},
        {"type": "pointerMove", "duration": max(1, duration_ms), "x": tx, "y": ty},
        {"type": "pointerUp", "button": 0},
    ])
    return fx, fy, tx, ty, dist


def _find_element(text: str, _retry: bool = True) -> str | None:
    """Return the element id of the first element whose label/name/value matches
    `text`, or None if no such element is on screen. Recreates the session once
    on a stale 404.
    """
    sid = _ensure_session()
    safe = text.replace("'", "\\'")
    predicate = f"label == '{safe}' OR name == '{safe}' OR value == '{safe}'"
    code, j = _req("POST", f"/session/{sid}/element",
                   {"using": "predicate string", "value": predicate})
    if code == 404 and _retry:
        _session["id"] = None
        return _find_element(text, _retry=False)
    return (j.get("value") or {}).get("ELEMENT") or \
           (j.get("value") or {}).get("element-6066-11e4-a52e-4f735466cecf")


# ---- Read-only tools -----------------------------------------------------------

@mcp.tool()
def ios_status() -> str:
    """Check whether WebDriverAgent is up and ready to accept commands.

    Returns a short JSON summary (ready flag, iOS version, device name). Call this
    first if other tools fail — a not-ready/unreachable result means the iMirror
    app isn't running or its health dot isn't green yet.
    """
    _, j = _req("GET", "/status")
    v = j.get("value", {})
    return json.dumps({
        "ready": v.get("ready"),
        "message": v.get("message"),
        "ios": v.get("os", {}).get("version"),
        "device": v.get("device"),
    })


@mcp.tool()
def ios_window_size() -> str:
    """Get the device's logical screen size in points for the CURRENT orientation.

    Coordinates for ios_tap / ios_swipe are in these points (origin top-left).
    The width/height swap when the device is in landscape, so call this before
    computing coordinates if the orientation may have changed.
    """
    j = _session_get("/window/size")
    return json.dumps(j.get("value", j))


@mcp.tool()
def ios_screenshot() -> Image:
    """Capture the iPhone's current screen as a PNG.

    Returns a full-resolution device screenshot. Needs no macOS Screen Recording
    permission (the frame comes from WebDriverAgent, not a Mac screen capture).
    Use it to see the device state before/after an action.
    """
    _, j = _req("GET", "/screenshot")
    b64 = j.get("value")
    if not b64:
        raise RuntimeError(f"No screenshot returned: {j}")
    data = base64.b64decode(b64)
    if _run["active"]:
        fname = f"{len(_run['steps']) + 1:03d}.png"
        with open(os.path.join(_run["dir"], fname), "wb") as f:
            f.write(data)
        _record("screenshot", screenshot=fname)
    return Image(data=data, format="png")


@mcp.tool()
def ios_source() -> str:
    """Get the accessibility hierarchy (XML) of the current screen.

    Useful for finding element labels/identifiers to drive ios_find_and_tap, or
    for asserting that expected UI is present. The output can be large; prefer a
    screenshot for a quick look and use this when you need exact element text.
    """
    # /source is a sessionless WDA route. On a complex screen WDA can take far
    # longer than a tap to serialise the whole tree (seen >15s, ~160 KB on a
    # real device), so give it a generous timeout.
    code, j = _req("GET", "/source", timeout=60)
    if code >= 400:
        raise RuntimeError(f"WDA error (HTTP {code}) on /source: {j}")
    src = j.get("value", "")
    if not isinstance(src, str):
        src = json.dumps(src)
    if len(src) > 20000:
        src = src[:20000] + "\n… (truncated)"
    return src


# ---- Control tools -------------------------------------------------------------

@mcp.tool()
def ios_tap(x: float, y: float) -> str:
    """Tap the screen at a point, in logical points (see ios_window_size).

    Origin is top-left. Example: center of a 430×932 portrait screen is (215, 466).
    """
    _gesture([
        {"type": "pointerMove", "duration": 0, "x": x, "y": y},
        {"type": "pointerDown", "button": 0},
        {"type": "pause", "duration": 40},
        {"type": "pointerUp", "button": 0},
    ])
    _record("tap", f"({x}, {y})")
    return f"tapped ({x}, {y})"


@mcp.tool()
def ios_swipe(from_x: float, from_y: float, to_x: float, to_y: float,
              duration_ms: int = 250, settle_ms: int = 0) -> str:
    """Swipe/drag from one point to another (logical points). Use for scrolling,
    paging, and drag gestures. Larger duration_ms = slower drag.

    Note: scrolling on a real device has NO inertial momentum via WebDriverAgent —
    a swipe moves content ~1:1 and stops on release, so use a longer swipe to cover
    more distance, not a faster one. /actions returns when the gesture wire is sent,
    not when the iOS animation settles (~200-350ms); pass settle_ms (e.g. 300) to
    wait before a following ios_source / ios_screenshot so you don't capture mid-scroll.
    """
    _gesture([
        {"type": "pointerMove", "duration": 0, "x": from_x, "y": from_y},
        {"type": "pointerDown", "button": 0},
        {"type": "pointerMove", "duration": max(1, duration_ms), "x": to_x, "y": to_y},
        {"type": "pointerUp", "button": 0},
    ])
    if settle_ms > 0:
        time.sleep(settle_ms / 1000.0)
    _record("swipe", f"({from_x},{from_y}) -> ({to_x},{to_y})")
    return f"swiped ({from_x},{from_y}) -> ({to_x},{to_y})"


@mcp.tool()
def ios_scroll(direction: str, distance_pct: float = 40, x_pct: float = 50,
               y_pct: float = 50, duration_ms: int = 300, settle_ms: int = 300) -> str:
    """Scroll the screen in a direction by a fraction of the screen.

    `direction` is the CONTENT direction: "down" reveals content further down the
    page, "up" goes back toward the top, "left"/"right" for horizontal scrollers.
    `distance_pct` is how far to scroll as a percent of the screen dimension
    (floored at 15; ~85 ≈ a full page). `x_pct`/`y_pct` place the swipe (e.g. scroll
    a specific pane). Waits `settle_ms` after so a following screenshot/source is
    stable. Returns JSON with the actual from/to points and distance in points.

    There is no momentum: distance is set by the swipe length, not its speed.
    """
    fx, fy, tx, ty, dist = _scroll_once(direction, distance_pct, x_pct, y_pct, duration_ms)
    if settle_ms > 0:
        time.sleep(settle_ms / 1000.0)
    _record("scroll", f"{direction} {distance_pct:g}%")
    return json.dumps({"from_pt": [round(fx, 1), round(fy, 1)],
                       "to_pt": [round(tx, 1), round(ty, 1)],
                       "distance_pts": round(dist, 1)})


@mcp.tool()
def ios_scroll_to(text: str, direction: str = "down", max_swipes: int = 10,
                  distance_pct: float = 35, settle_ms: int = 350) -> str:
    """Scroll until an element with the given visible label/name/value is on screen.

    Repeatedly scrolls `direction` (content direction; default "down") up to
    `max_swipes` times (hard-capped at 20), checking after each whether `text` is
    present. Returns JSON {"found": true, "swipes": n} as soon as it appears, or
    raises if it never does. Use to bring a known row/button into view before
    tapping it. Each step waits `settle_ms` so the check sees a settled screen.
    """
    cap = min(max_swipes, 20)
    if max_swipes > 20:
        _record("scroll_to", f"max_swipes {max_swipes} capped at 20")
    for n in range(cap + 1):
        if _find_element(text):
            return json.dumps({"found": True, "swipes": n})
        if n == cap:
            break
        _scroll_once(direction, distance_pct, 50, 50, 300)
        time.sleep(settle_ms / 1000.0)
    raise RuntimeError(f"Element '{text}' not found after {cap} swipes ({direction}).")


@mcp.tool()
def ios_type(text: str) -> str:
    """Type text into the currently focused field. Tap a text field first.

    Special characters: use "\\n" for return, "\\b" (U+0008) for backspace.
    """
    _session_post("/wda/keys", {"value": list(text)})
    _record("type", repr(text))
    return f"typed {len(text)} char(s)"


@mcp.tool()
def ios_press_button(name: str = "home") -> str:
    """Press a hardware button. name ∈ {home, volumeUp, volumeDown}.

    Note: App Switcher, Control Center, and Siri are NOT reachable (XCUITest
    limitation), so there is no reliable button for them.
    """
    allowed = {"home", "volumeUp", "volumeDown"}
    if name not in allowed:
        raise RuntimeError(f"name must be one of {sorted(allowed)}")
    if name == "home":
        _req("POST", "/wda/homescreen", {})
    else:
        _session_post("/wda/pressButton", {"name": name})
    _record("press_button", name)
    return f"pressed {name}"


@mcp.tool()
def ios_find_and_tap(text: str) -> str:
    """Find an on-screen element by its visible label/name and tap it.

    Convenience for tapping by text instead of pixel coordinates (e.g. a button
    titled "Settings"). Fails with a clear message if no matching element is
    found — fall back to ios_source to inspect, or ios_tap with coordinates.
    """
    eid = _find_element(text)
    if not eid:
        raise RuntimeError(f"No element matching '{text}'. Use ios_source to inspect.")
    sid = _ensure_session()
    _req("POST", f"/session/{sid}/element/{eid}/click", {})
    _record("find_and_tap", text)
    return f"tapped element '{text}'"


@mcp.tool()
def ios_wait_for(text: str, timeout_s: float = 10.0) -> str:
    """Wait until an element with the given visible label/name/value appears.

    Polls the screen until a matching element is present or `timeout_s` elapses.
    Use after an action that triggers a transition (navigation, a network load) so
    later taps don't race the UI. Raises if the element never appears in time.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    while True:
        attempts += 1
        if _find_element(text):
            _record("wait_for", f"'{text}' (found after {attempts} check(s))")
            return f"found '{text}' after {attempts} check(s)"
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"'{text}' did not appear within {timeout_s}s. Use ios_source to inspect.")
        time.sleep(0.5)


@mcp.tool()
def ios_orientation(set_to: str = "") -> str:
    """Get the device orientation, or set it.

    Call with no argument to read the current orientation. Pass `set_to` =
    PORTRAIT or LANDSCAPE to rotate the device first. Returns the (resulting)
    orientation as JSON. After rotating, screen dimensions swap — call
    ios_window_size again before computing tap coordinates.
    """
    if set_to:
        val = set_to.upper()
        allowed = {"PORTRAIT", "LANDSCAPE"}
        if val not in allowed:
            raise RuntimeError(f"set_to must be one of {sorted(allowed)}")
        _session_post("/orientation", {"orientation": val})
        _record("orientation", f"set {val}")
    j = _session_get("/orientation")
    return json.dumps({"orientation": j.get("value")})


# ---- Test-run recording & report -----------------------------------------------

@mcp.tool()
def ios_start_run(label: str = "test") -> str:
    """Begin recording a test run so a report can be generated at the end.

    OPT-IN: nothing is recorded until you call this. While a run is active, every
    tap / swipe / type / button / find / wait is logged, and every ios_screenshot
    is also saved to the run directory. Add checkpoints with ios_run_note, then
    call ios_finish_run to write a self-contained HTML report.

    `label` names the run (used in the directory and report title). Runs are stored
    under $IMIRROR_RUNS_DIR (default ~/.imirror/runs). Starting a run replaces any
    run already in progress.
    """
    base = os.environ.get("IMIRROR_RUNS_DIR", os.path.expanduser("~/.imirror/runs"))
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", label).strip("-") or "test"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(base, f"{stamp}-{slug}")
    os.makedirs(run_dir, exist_ok=True)
    device = ios_ver = None
    try:                                  # best-effort header info; don't fail the run
        _, st = _req("GET", "/status")
        v = st.get("value", {})
        device, ios_ver = v.get("device"), v.get("os", {}).get("version")
    except Exception:
        pass
    _run.update(active=True, dir=run_dir, label=label, started=time.time(),
                device=device, ios=ios_ver, steps=[])
    return f"recording run '{label}' -> {run_dir}"


@mcp.tool()
def ios_run_note(text: str, status: str = "info") -> str:
    """Add a checkpoint/annotation to the active run's timeline.

    Use it to mark what a step verified. `status` is one of info / pass / fail —
    `fail` is highlighted in the report and counted as a failure. Raises if no run
    is active (start one with ios_start_run).
    """
    if not _run["active"]:
        raise RuntimeError("No active run. Call ios_start_run first.")
    status = status.lower()
    if status not in {"info", "pass", "fail"}:
        raise RuntimeError("status must be one of info / pass / fail")
    _record("note", detail=text, note=status)
    return f"noted ({status}): {text}"


@mcp.tool()
def ios_finish_run(video: str = "gif") -> str:
    """Finish the active run and write an HTML report.

    Renders the recorded timeline — actions, notes, and embedded screenshots — to
    report.html in the run directory and returns its path. Stops recording. Raises
    if no run is active.

    `video` stitches the run's screenshots into a looping timelapse shown at the
    top of the report: "gif" (default), "mp4", or "none". Needs ffmpeg on PATH and
    at least two screenshots; if either is missing the report is still written, with
    a note that the timelapse was skipped. The clip is saved beside report.html
    (so a video-bearing report is a folder, not a single file); screenshots stay
    embedded in the HTML regardless.
    """
    if not _run["active"]:
        raise RuntimeError("No active run. Call ios_start_run first.")
    video = video.lower()
    if video not in {"none", "gif", "mp4"}:
        raise RuntimeError("video must be one of none / gif / mp4")
    clip, clip_note = _make_timelapse(video)
    path = os.path.join(_run["dir"], "report.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(_render_report(ended=time.time(), clip=clip, clip_note=clip_note))
    _run["active"] = False
    return path


def _make_timelapse(fmt: str) -> tuple[str | None, str]:
    """Stitch the run's screenshots into a timelapse. Returns (filename, note);
    filename is None when nothing was produced and note explains why."""
    shots = [s["screenshot"] for s in _run["steps"] if s["screenshot"]]
    if fmt == "none":
        return None, ""
    if len(shots) < 2:
        return None, "timelapse skipped: fewer than 2 screenshots"
    if not shutil.which("ffmpeg"):
        return None, "timelapse skipped: ffmpeg not found on PATH"

    run_dir = _run["dir"]
    listfile = os.path.join(run_dir, "_frames.txt")
    palette = os.path.join(run_dir, "_palette.png")
    hold = 1.2                                    # seconds each frame is held

    def _entry(name: str) -> str:                 # escape ' for concat syntax
        return "file '%s'" % name.replace("'", "'\\''")

    lines = []
    for name in shots:
        lines.append(_entry(name))
        lines.append(f"duration {hold}")
    lines.append(_entry(shots[-1]))               # concat needs the last file twice
    with open(listfile, "w") as f:
        f.write("\n".join(lines) + "\n")

    out = f"timelapse.{fmt}"
    out_path = os.path.join(run_dir, out)
    scale = "scale=480:-1:flags=lanczos"
    # Entries are bare relative names (NNN.png), so concat's default safe mode
    # accepts them — no -safe 0, which keeps path traversal out of the listfile.
    concat = ["-f", "concat", "-i", listfile]
    try:
        if fmt == "gif":
            _ffmpeg(concat + ["-vf", f"{scale},palettegen", palette])
            _ffmpeg(concat + ["-i", palette,
                              "-lavfi", f"{scale}[x];[x][1:v]paletteuse", out_path])
        else:  # mp4 — force even dimensions for yuv420p
            _ffmpeg(concat + ["-vsync", "vfr", "-pix_fmt", "yuv420p",
                              "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", out_path])
    except (subprocess.CalledProcessError, OSError) as e:
        return None, f"timelapse skipped: ffmpeg failed ({e})"
    finally:
        for tmp in (listfile, palette):
            try:
                os.remove(tmp)
            except OSError:
                pass
    if os.path.exists(out_path):
        return out, ""
    return None, "timelapse skipped: ffmpeg produced no output"


def _ffmpeg(args: list[str]) -> None:
    subprocess.run(["ffmpeg", "-y", *args], check=True, capture_output=True)


def _render_report(ended: float, clip: str | None = None, clip_note: str = "") -> str:
    steps = _run["steps"]
    started = _run["started"] or ended
    fails = sum(1 for s in steps if s["action"] == "note" and s["note"] == "fail")
    shots = sum(1 for s in steps if s["screenshot"])
    overall = "FAIL" if fails else "PASS"

    blocks = []
    for s in steps:
        off = s["t"] - started
        img = ""
        if s["screenshot"]:
            p = os.path.join(_run["dir"], s["screenshot"])
            try:
                with open(p, "rb") as fh:
                    b64 = base64.b64encode(fh.read()).decode()
                uri = f"data:image/png;base64,{b64}"
                img = (f'<a href="{uri}" target="_blank">'
                       f'<img class="shot" src="{uri}" alt="step {s["i"]}"></a>')
            except OSError:
                img = '<span class="missing">[screenshot missing]</span>'
        badge = ""
        if s["action"] == "note":
            cls = {"pass": "ok", "fail": "bad"}.get(s["note"], "info")
            badge = f'<span class="badge {cls}">{html.escape(s["note"])}</span>'
        blocks.append(
            f'<div class="step">'
            f'<div class="meta"><span class="i">#{s["i"]}</span>'
            f'<span class="act">{html.escape(s["action"])}</span>'
            f'<span class="off">+{off:.1f}s</span>{badge}</div>'
            f'<div class="detail">{html.escape(s["detail"])}</div>{img}</div>'
        )

    title = html.escape(_run["label"] or "test")
    meta = " · ".join(filter(None, [
        f"device: {html.escape(_run['device'])}" if _run["device"] else "",
        f"iOS {html.escape(_run['ios'])}" if _run["ios"] else "",
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started)),
        f"{ended - started:.1f}s",
        f"{len(steps)} steps · {shots} screenshots · {fails} failures",
    ]))
    body = "\n".join(blocks) or '<p class="detail">No steps were recorded.</p>'

    clip_html = ""
    if clip and clip.endswith(".mp4"):
        clip_html = (f'<video class="clip" src="{html.escape(clip)}" '
                     f'controls loop muted playsinline></video>')
    elif clip:                                    # gif
        clip_html = f'<img class="clip" src="{html.escape(clip)}" alt="run timelapse">'
    elif clip_note:
        clip_html = f'<p class="clip-note">{html.escape(clip_note)}</p>'

    return _REPORT_TEMPLATE.format(
        title=title, overall=overall, overall_cls=("bad" if fails else "ok"),
        meta=meta, clip=clip_html, body=body)


_REPORT_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iMirror test report — {title}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0;
         background: #f6f7f9; color: #1c1e21; }}
  @media (prefers-color-scheme: dark) {{ body {{ background:#16181c; color:#e6e6e6; }}
    header, .step {{ background:#22252b !important; }} }}
  header {{ background:#fff; padding:24px 32px; border-bottom:1px solid #0001; }}
  h1 {{ margin:0 0 6px; font-size:20px; }}
  .meta-top {{ color:#6b7280; font-size:13px; }}
  .badge {{ font-size:12px; font-weight:600; padding:2px 8px; border-radius:999px;
           margin-left:8px; vertical-align:middle; }}
  .badge.ok {{ background:#16a34a22; color:#16a34a; }}
  .badge.bad {{ background:#dc262622; color:#dc2626; }}
  .badge.info {{ background:#3b82f622; color:#3b82f6; }}
  main {{ max-width:760px; margin:24px auto; padding:0 16px; }}
  .step {{ background:#fff; border:1px solid #0001; border-radius:10px;
          padding:14px 16px; margin:0 0 14px; }}
  .meta {{ display:flex; align-items:center; gap:10px; font-size:13px; color:#6b7280; }}
  .i {{ font-weight:700; color:#9ca3af; }}
  .act {{ font-weight:600; color:inherit; text-transform:uppercase; letter-spacing:.04em;
         font-size:12px; }}
  .off {{ margin-left:auto; font-variant-numeric:tabular-nums; }}
  .detail {{ margin:6px 0; font-family:ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size:13px; word-break:break-word; }}
  .shot {{ margin-top:8px; max-width:100%; border-radius:8px; border:1px solid #0002;
          display:block; }}
  .missing {{ color:#dc2626; font-size:13px; }}
  .clip {{ display:block; width:100%; max-width:480px; margin:16px auto 0;
          border-radius:10px; border:1px solid #0002; }}
  .clip-note {{ color:#6b7280; font-size:13px; font-style:italic; }}
</style></head>
<body>
<header>
  <h1>{title} <span class="badge {overall_cls}">{overall}</span></h1>
  <div class="meta-top">{meta}</div>
</header>
<main>
{clip}
{body}
</main></body></html>"""


if __name__ == "__main__":
    mcp.run()
