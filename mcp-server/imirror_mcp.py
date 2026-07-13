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

__version__ = "1.0.0"

import base64
import html
import http.client
import ipaddress
import json
import math
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlsplit

from mcp.server.fastmcp import FastMCP, Image


def _is_loopback_url(url: str) -> bool:
    """True only if `url` is plain http to an actual loopback host.

    A raw `startswith("http://127.0.0.1")` prefix check is unsafe: it accepts
    hostile hosts like http://127.0.0.1.attacker.example or
    http://localhost.attacker.example, which resolve off-box. Parse the URL and
    compare the *hostname* exactly — "localhost" by name, or any address in the
    127.0.0.0/8 (and ::1) loopback ranges via ipaddress. WDA has no auth on the
    wire, so this must never widen to a non-loopback host.
    """
    parts = urlsplit(url)
    if parts.scheme != "http":
        return False
    host = parts.hostname
    if host is None:
        return False
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


WDA = os.environ.get("IMIRROR_WDA", "http://127.0.0.1:8100")
if not _is_loopback_url(WDA):
    raise SystemExit("Refusing non-loopback WDA target (WDA has no auth on the wire).")

# Which kind of target is behind WDA. "device" (default) is a physical iPhone the
# iMirror app brought up; "simulator" is a booted Simulator whose WDA was launched
# by scripts/sim-wda-up.sh. The interaction tools are identical either way — this
# only switches the few non-WDA paths: app install (go-ios vs `simctl`), the
# simulator-only sim_* helpers, and the wording of "unreachable"/wedged hints
# (a simulator has no health dot). See scripts/sim-wda-up.sh.
TARGET = os.environ.get("IMIRROR_TARGET", "device").strip().lower()
if TARGET not in ("device", "simulator"):
    raise SystemExit(f"IMIRROR_TARGET must be 'device' or 'simulator', got {TARGET!r}.")
_IS_SIM = TARGET == "simulator"


def _unreachable_hint() -> str:
    """Actionable 'why can't I reach WDA' suffix, phrased for the current target."""
    if _IS_SIM:
        return (f"Is the simulator's WebDriverAgent running (scripts/sim-wda-up.sh) "
                f"and reachable at {WDA}?")
    return "Is the iMirror app running and is the health dot green?"


def _wedged_hint() -> str:
    """Where to look when WDA is up but not answering, phrased for the target."""
    return ("check the simulator's WebDriverAgent process" if _IS_SIM
            else "check the iMirror health dot")


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
    """Append a step to the active run. No-op when no run is recording.

    Each step is also appended to steps.jsonl in the run dir so a crash between
    ios_start_run and ios_finish_run leaves a replayable log next to the
    screenshots already on disk (the in-memory timeline would otherwise be lost).
    The disk append is best-effort — a write failure must never break recording.
    """
    if not _run["active"]:
        return
    step = {
        "i": len(_run["steps"]) + 1, "t": time.time(),
        "action": action, "detail": detail, "screenshot": screenshot, "note": note,
    }
    _run["steps"].append(step)
    run_dir = _run.get("dir")
    if run_dir:
        try:
            with open(os.path.join(run_dir, "steps.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(step) + "\n")
        except OSError:
            pass


# ---- HTTP helpers (keep-alive connection, reconnect on drop) -------------------

# A reused HTTPConnection to WDA on loopback, kept *per thread*. Every WDA call
# (every tap, and every poll iteration in wait_for/scroll_to/asserts) otherwise
# paid a fresh TCP handshake *and* a fresh hop through the in-app relay's USB
# tunnel. Reusing the connection removes that per-call setup. It's thread-local
# (not one shared, lock-serialised connection) so a slow request on one thread —
# e.g. a 60s /source — can't block a concurrent call on another thread. A
# dropped/half-closed connection is detected on the next request and replaced.
_conn_local = threading.local()


def _drop_conn() -> None:
    c = getattr(_conn_local, "c", None)
    if c is not None:
        try:
            c.close()
        except Exception:
            pass
        _conn_local.c = None


def _http(method: str, path: str, data: bytes | None,
          timeout: float) -> tuple[int, bytes]:
    """Send one request over this thread's cached keep-alive connection and return
    (status, raw_body). Raises the underlying socket/http.client error on a
    connection-level failure (the caller decides whether to retry)."""
    parts = urlsplit(WDA)
    host, port = parts.hostname, parts.port or 80
    c = getattr(_conn_local, "c", None)
    if c is None:
        c = http.client.HTTPConnection(host, port, timeout=timeout)
        _conn_local.c = c
    try:
        c.timeout = timeout
        c.request(method, path, body=data,
                  headers={"Content-Type": "application/json"})
        r = c.getresponse()
        return r.status, r.read()
    except Exception:
        _drop_conn()          # poison so the next call reconnects clean
        raise


def _req(method: str, path: str, body: dict | None = None,
         timeout: float = 15) -> tuple[int, dict[str, Any]]:
    data = json.dumps(body).encode() if body is not None else None
    # WDA's CocoaHTTPServer occasionally drops a connection mid-exchange
    # (RemoteDisconnected / reset), and keep-alive means we may hand back a
    # server-closed socket — retry such transient failures a couple times.
    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            status, raw = _http(method, path, data, timeout)
        except (http.client.RemoteDisconnected, ConnectionResetError,
                http.client.BadStatusLine, http.client.IncompleteRead,
                BrokenPipeError) as e:
            last_exc = e
            # A reused keep-alive socket the server already closed fails on the
            # first send — that's expected staleness, so reconnect and retry
            # immediately (no penalty). Only back off on repeated failures, which
            # signal a genuinely busy/wedged WDA rather than a stale socket.
            if attempt > 0:
                time.sleep(0.3 * attempt)
            continue
        except (socket.timeout, TimeoutError) as e:
            raise RuntimeError(
                f"WDA timed out after {timeout}s on {path}. It may be busy or "
                f"wedged — {_wedged_hint()}.") from e
        except OSError as e:
            raise RuntimeError(
                f"Cannot reach WDA at {WDA} ({e}). {_unreachable_hint()}") from e
        # HTTP errors (4xx/5xx) come back as a normal response with http.client,
        # not an exception — callers (e.g. _session_post) rely on seeing the code
        # and any JSON error body, so return them rather than raising.
        try:
            return status, (json.loads(raw) if raw else {})
        except Exception:
            if status >= 400:
                return status, {"error": raw.decode("utf-8", "replace")[:300]}
            raise
    raise RuntimeError(
        f"WDA dropped the connection repeatedly on {path} ({last_exc}). "
        f"It may be busy or wedged — {_wedged_hint()}.")


def _screenshot_quality() -> int:
    """IMIRROR_SCREENSHOT_QUALITY as 0 (lossless PNG), 1 (medium JPEG), or 2
    (low JPEG). Unset or invalid falls back to 1 — the default that trades
    imperceptible fidelity for a large latency/size win. Never raises."""
    try:
        q = int(os.environ.get("IMIRROR_SCREENSHOT_QUALITY", "1"))
    except (ValueError, TypeError):
        return 1
    return q if q in (0, 1, 2) else 1


def _ensure_session() -> str:
    if _session["id"]:
        return _session["id"]  # type: ignore[return-value]
    # shouldWaitForQuiescence:false slashes gesture latency — measured on-device, a
    # swipe's /actions drops from ~1300ms to ~10-200ms (XCUITest otherwise blocks each
    # gesture until the UI settles). Use settle_ms on scroll/swipe when a following
    # screenshot/source needs a stable, post-animation frame.
    code, j = _req("POST", "/session",
                   {"capabilities": {"alwaysMatch": {"shouldWaitForQuiescence": False},
                                     "firstMatch": [{}]}})
    sid = (j.get("value") or {}).get("sessionId") or j.get("sessionId")
    if not sid:
        raise RuntimeError(f"WDA session create failed (HTTP {code}): {j}")
    _session["id"] = sid
    # Disable XCUITest's idle/animation wait — the big latency win (a swipe over
    # animating content drops ~13s -> ~1s, static lists ~1.3s -> near-instant).
    # Best-effort; the capability above is ignored by this WDA build, but this
    # per-session settings route is honored.
    try:
        _req("POST", f"/session/{sid}/appium/settings",
             {"settings": {"waitForIdleTimeout": 0, "animationCoolOffTimeout": 0}}, timeout=5)
    except Exception:
        pass
    # Ask WDA to JPEG-encode screenshots device-side (screenshotQuality 1/2) —
    # cuts encode time and payload vs lossless PNG. Separate best-effort POST so
    # a build that rejects the key can't also drop the idle-wait settings above.
    try:
        _req("POST", f"/session/{sid}/appium/settings",
             {"settings": {"screenshotQuality": _screenshot_quality()}}, timeout=5)
    except Exception:
        pass
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
    # Escape backslashes BEFORE quotes: input ending in \' would otherwise become
    # \\' (escaped backslash + live quote) and break out of the predicate literal.
    safe = text.replace("\\", "\\\\").replace("'", "\\'")
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

    Returns a short JSON summary (ready flag, iOS version, device name, and this
    MCP server's version). Call this first if other tools fail — a not-ready/
    unreachable result means the iMirror app isn't running or its health dot isn't
    green yet.
    """
    _, j = _req("GET", "/status")
    v = j.get("value", {})
    return json.dumps({
        "ready": v.get("ready"),
        "message": v.get("message"),
        "ios": v.get("os", {}).get("version"),
        "device": v.get("device"),
        "server_version": __version__,
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


def _img_kind(data: bytes) -> tuple[str, str]:
    """Sniff image bytes -> (fastmcp_format, file_extension).

    WDA returns PNG by default and JPEG when a lower screenshot quality is
    configured. Default to PNG on anything unrecognized so a screenshot that
    came back always returns rather than erroring on an odd header.
    """
    if data[:2] == b"\xff\xd8":
        return "jpeg", ".jpg"
    return "png", ".png"


@mcp.tool()
def ios_screenshot() -> Image:
    """Capture the iPhone's current screen. Returns a PNG by default, or JPEG when
    IMIRROR_SCREENSHOT_QUALITY is 1 (medium) or 2 (low) — faster and smaller for
    agent loops.

    Returns a full-resolution device screenshot. Needs no macOS Screen Recording
    permission (the frame comes from WebDriverAgent, not a Mac screen capture).
    Use it to see the device state before/after an action.
    """
    # Ensure a session exists first so the screenshotQuality settings POST (in
    # _ensure_session) has run even when a screenshot is the very first tool call
    # of a session — otherwise the sessionless /screenshot route below returns a
    # full PNG because quality settings were never applied. Cheap/cached after
    # the first call.
    _ensure_session()
    _, j = _req("GET", "/screenshot")
    b64 = j.get("value")
    if not b64:
        raise RuntimeError(f"No screenshot returned: {j}")
    data = base64.b64decode(b64)
    fmt, ext = _img_kind(data)
    if _run["active"]:
        # Cap saved screenshots per run so a looping agent can't fill the disk
        # (~0.5 MB each). Past the cap the screenshot still returns to the caller;
        # it just isn't persisted into the run.
        cap = int(os.environ.get("IMIRROR_MAX_RUN_SHOTS", "500"))
        saved = sum(1 for s in _run["steps"] if s["screenshot"])
        if saved < cap:
            fname = f"{len(_run['steps']) + 1:03d}{ext}"
            with open(os.path.join(_run["dir"], fname), "wb") as f:
                f.write(data)
            _record("screenshot", screenshot=fname)
        elif not _run.get("cap_noted"):
            _run["cap_noted"] = True
            _record("note", f"screenshot cap reached ({cap}); further shots not saved",
                    note="info")
    return Image(data=data, format=fmt)


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
            _record("scroll_to", f"'{text}' {direction}: found after {n} swipe(s)")
            return json.dumps({"found": True, "swipes": n})
        if n == cap:
            break
        _scroll_once(direction, distance_pct, 50, 50, 300)
        time.sleep(settle_ms / 1000.0)
    # Recorded as a "note" so the failure counts in the report's pass/fail rollup.
    _record("note", f"scroll_to '{text}' {direction}: NOT found after {cap} swipes",
            note="fail")
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
    if name in ("volumeUp", "volumeDown") and _IS_SIM:
        # Volume is a physical button; WDA returns an opaque HTTP 500 on a
        # simulator. Fail early with something the caller can act on.
        raise RuntimeError(
            f"{name} is unavailable on a simulator (volume buttons are "
            "physical-device-only). Use 'home', or run against a device.")
    if name == "home":
        code, j = _req("POST", "/wda/homescreen", {})
        if code >= 400:
            raise RuntimeError(f"WDA error (HTTP {code}) pressing home: {j}")
    else:
        _session_post("/wda/pressButton", {"name": name})
    _record("press_button", name)
    return f"pressed {name}"


@mcp.tool()
def ios_find_and_tap(text: str, retries: int = 0, retry_delay_s: float = 0.5) -> str:
    """Find an on-screen element by its visible label/name and tap it.

    Convenience for tapping by text instead of pixel coordinates (e.g. a button
    titled "Settings"). `retries` re-attempts the find (with `retry_delay_s`
    between) to absorb a slow-appearing element; default 0 keeps single-shot
    behavior. Fails with a clear message if no matching element is found — fall
    back to ios_source to inspect, or ios_tap with coordinates.
    """
    attempt = 0
    while True:
        eid = _find_element(text)
        if eid:
            # The click leg goes through _session_post so a stale-session 404 retries
            # and a WDA error raises — returning "tapped" on a failed click would mislead.
            _session_post(f"/element/{eid}/click", {})
            _record("find_and_tap", text)
            return f"tapped element '{text}'"
        if attempt >= retries:
            raise RuntimeError(f"No element matching '{text}'. Use ios_source to inspect.")
        attempt += 1
        time.sleep(retry_delay_s)


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
        # Width/height swap on rotation — drop the cached window size so the next
        # ios_scroll computes its geometry from the new dimensions, not stale ones.
        _window_cache.update(size=None, t=0.0)
        _record("orientation", f"set {val}")
    j = _session_get("/orientation")
    return json.dumps({"orientation": j.get("value")})


@mcp.tool()
def ios_launch_app(bundle_id: str) -> str:
    """Launch (or foreground) an app by bundle id, e.g. com.apple.Preferences."""
    _session_post("/wda/apps/launch", {"bundleId": bundle_id})
    _record("launch_app", bundle_id)
    return f"launched {bundle_id}"


@mcp.tool()
def ios_terminate_app(bundle_id: str) -> str:
    """Terminate a running app by bundle id."""
    _session_post("/wda/apps/terminate", {"bundleId": bundle_id})
    _record("terminate_app", bundle_id)
    return f"terminated {bundle_id}"


@mcp.tool()
def ios_activate_app(bundle_id: str) -> str:
    """Bring an already-running app to the foreground by bundle id."""
    _session_post("/wda/apps/activate", {"bundleId": bundle_id})
    _record("activate_app", bundle_id)
    return f"activated {bundle_id}"


@mcp.tool()
def ios_app_state(bundle_id: str) -> str:
    """Report an app's running state as JSON: not-installed / not-running /
    background / foreground (WDA numeric code included)."""
    j = _session_post("/wda/apps/state", {"bundleId": bundle_id})
    code = j.get("value")
    names = {0: "not-installed", 1: "not-running", 2: "background-suspended",
             3: "background", 4: "foreground"}
    state = names.get(code, f"unknown({code})")
    _record("app_state", f"{bundle_id}: {state}")
    return json.dumps({"bundleId": bundle_id, "state": state, "code": code})


@mcp.tool()
def ios_open_url(url: str) -> str:
    """Open a URL or deep link (https://… or myapp://…) on the device."""
    _session_post("/url", {"url": url})
    _record("open_url", url)
    return f"opened {url}"


@mcp.tool()
def ios_clipboard_set(text: str) -> str:
    """Set the device clipboard to `text`.

    NOTE: iOS grants pasteboard access only while WebDriverAgent is foreground;
    with another app in front this may be ignored — call after a WDA-owned screen
    or expect a no-op.
    """
    b64 = base64.b64encode(text.encode()).decode()
    _session_post("/wda/setPasteboard", {"content": b64, "contentType": "plaintext"})
    _record("clipboard_set", repr(text))
    return f"set clipboard ({len(text)} chars)"


@mcp.tool()
def ios_clipboard_get() -> str:
    """Read the device clipboard (plaintext). Same foreground caveat as
    ios_clipboard_set applies."""
    j = _session_post("/wda/getPasteboard", {"contentType": "plaintext"})
    raw = j.get("value") or ""
    try:
        text = base64.b64decode(raw).decode("utf-8", "replace")
    except Exception:
        text = raw
    _record("clipboard_get", f"{len(text)} chars")
    return text


# go-ios ships inside an installed iMirror.app; probe it so ios_install_app works
# from the packaged app without the user exporting IMIRROR_IOS_BIN.
_BUNDLED_IOS = "/Applications/iMirror.app/Contents/Resources/ios"


def _ios_bin() -> str:
    """Path to the go-ios `ios` binary: IMIRROR_IOS_BIN if set, else the copy
    bundled in an installed iMirror.app, else `ios` on PATH."""
    env = os.environ.get("IMIRROR_IOS_BIN")
    if env:
        return env
    if os.path.exists(_BUNDLED_IOS):
        return _BUNDLED_IOS
    return "ios"


@mcp.tool()
def ios_install_app(path: str) -> str:
    """Install an app on the current target (see IMIRROR_TARGET).

    Device (default): installs an .ipa/.app via the bundled go-ios; needs a
    signature already valid for the device.
    Simulator: installs a simulator-SDK .app via `xcrun simctl install booted`.
    A device .ipa will NOT run on a simulator — build the app for the simulator
    SDK. Shell-out (not WDA); degrades with a clear error if the tool is absent.
    """
    if not os.path.exists(path):
        raise RuntimeError(f"No such file: {path}")
    if _IS_SIM:
        _install_on_simulator(path)
    else:
        _install_on_device(path)
    _record("install_app", path)
    return f"installed {os.path.basename(path)}"


def _install_on_device(path: str) -> None:
    """Install `path` on the connected device via go-ios (resolved by _ios_bin)."""
    try:
        subprocess.run([_ios_bin(), "install", f"--path={path}"],
                       check=True, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise RuntimeError("go-ios 'ios' binary not found (set IMIRROR_IOS_BIN).") from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"install failed: {(e.stderr or '').strip() or e}") from e


def _install_on_simulator(path: str) -> None:
    """Install `path` on the booted simulator via `xcrun simctl install booted`."""
    try:
        subprocess.run(["xcrun", "simctl", "install", "booted", path],
                       check=True, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise RuntimeError("`xcrun` not found — install the Xcode command-line tools.") from e
    except subprocess.CalledProcessError as e:
        # The single most common mistake is handing a device .ipa to a simulator;
        # simctl's own error is terse, so add the actionable hint.
        hint = (" (a device .ipa won't run on a simulator — build the .app for the "
                "simulator SDK)") if path.endswith(".ipa") else ""
        raise RuntimeError(
            f"simctl install failed: {(e.stderr or '').strip() or e}{hint}") from e


# ---- Simulator-only helpers (xcrun simctl) -------------------------------------
# These control the booted simulator directly, doing things WDA/XCUITest can't:
# deliver push payloads, flip privacy permissions without tapping the system
# dialog, and freeze the status bar for clean screenshots. simctl only ever talks
# to simulators, so they require IMIRROR_TARGET=simulator and target `booted`.

def _simctl(*args: str) -> str:
    """Run `xcrun simctl <args>` and return stdout. Simulator-only.

    Raises a clear error when the current target isn't a simulator, when `xcrun`
    is missing, or when simctl exits non-zero (surfacing its stderr).
    """
    if not _IS_SIM:
        raise RuntimeError("simctl tools require IMIRROR_TARGET=simulator.")
    try:
        r = subprocess.run(["xcrun", "simctl", *args],
                           check=True, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise RuntimeError("`xcrun` not found — install the Xcode command-line tools.") from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"simctl {args[0]} failed: {(e.stderr or '').strip() or e}") from e
    return (r.stdout or "").strip()


@mcp.tool()
def sim_push(bundle_id: str, payload_json: str) -> str:
    """(Simulator only) Deliver a push notification to `bundle_id`.

    `payload_json` is the full APNs payload as a JSON string, e.g.
    '{"aps": {"alert": "Hello"}}'. Lets you exercise notification handling without
    a real APNs round-trip. Requires IMIRROR_TARGET=simulator.
    """
    try:
        json.loads(payload_json)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"payload_json is not valid JSON: {e}") from e
    # simctl reads the payload from a file; hand it a temp .apns and clean up.
    with tempfile.NamedTemporaryFile("w", suffix=".apns", delete=False) as f:
        f.write(payload_json)
        tmp = f.name
    try:
        _simctl("push", "booted", bundle_id, tmp)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    _record("sim_push", bundle_id)
    return f"pushed to {bundle_id}"


@mcp.tool()
def sim_privacy(action: str, service: str, bundle_id: str = "") -> str:
    """(Simulator only) Grant, revoke, or reset a privacy permission without
    tapping the system consent dialog.

    action ∈ {grant, revoke, reset}. service is a simctl service name, e.g.
    photos, camera, microphone, contacts, calendar, location, all. `bundle_id`
    scopes grant/revoke to one app (simctl requires it for those); reset accepts
    a bundle id or `all`. Requires IMIRROR_TARGET=simulator.
    """
    if action not in ("grant", "revoke", "reset"):
        raise RuntimeError("action must be one of ['grant', 'revoke', 'reset'].")
    args = ["privacy", "booted", action, service]
    if bundle_id:
        args.append(bundle_id)
    _simctl(*args)
    _record("sim_privacy", f"{action} {service} {bundle_id}".strip())
    return f"{action} {service}" + (f" for {bundle_id}" if bundle_id else "")


@mcp.tool()
def sim_status_bar(time: str = "9:41", clear: bool = False) -> str:
    """(Simulator only) Override the status bar for clean screenshots — full
    signal/wifi bars, 100% battery, and a fixed `time` (default 9:41).

    Pass clear=True to restore the real status bar. Requires
    IMIRROR_TARGET=simulator.
    """
    if clear:
        _simctl("status_bar", "booted", "clear")
        _record("sim_status_bar", "clear")
        return "status bar restored"
    _simctl("status_bar", "booted", "override",
            "--time", time, "--batteryState", "charged", "--batteryLevel", "100",
            "--cellularBars", "4", "--wifiBars", "3", "--dataNetwork", "wifi")
    _record("sim_status_bar", f"override time={time}")
    return f"status bar overridden (time {time})"


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
    # Surface (don't silently swallow) an in-progress run being discarded — with
    # several agents sharing one server, a second start_run would otherwise wipe
    # the first caller's recording with no trace.
    warn = ""
    if _run["active"]:
        warn = (f"WARNING: discarded in-progress run '{_run['label']}' "
                f"({len(_run['steps'])} steps) — only one run records at a time. ")
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
                device=device, ios=ios_ver, steps=[], cap_noted=False)
    return f"{warn}recording run '{label}' -> {run_dir}"


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
def ios_run_section(title: str) -> str:
    """Start a named section in the active run (e.g. a test area or scenario).

    Sections give the report a "what was tested" structure: every step and note
    recorded after this call is grouped under `title`, the report's table of
    contents lists each section with its own pass/fail rollup, and the summary
    counts them. Call it at the start of each logical area you test. Steps recorded
    before the first section land in an implicit opening section, so existing flows
    keep working unchanged. Raises if no run is active.
    """
    if not _run["active"]:
        raise RuntimeError("No active run. Call ios_start_run first.")
    _record("section", detail=title)
    return f"section: {title}"


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
    # Stop recording even if rendering/writing fails — otherwise later actions keep
    # appending to a run the caller believes is finished. Steps stay in memory, so a
    # failed write can still be retried out-of-band.
    try:
        clip, clip_note = _make_timelapse(video)
        path = os.path.join(_run["dir"], "report.html")
        with open(path, "w", encoding="utf-8") as f:
            f.write(_render_report(ended=time.time(), clip=clip, clip_note=clip_note))
    finally:
        _run["active"] = False
    return path


@mcp.tool()
def ios_assert_visible(text: str, timeout_s: float = 5.0) -> str:
    """Assert an element with the given visible label/name/value is present.

    Polls up to `timeout_s`. Records a PASS note on success or a FAIL note on
    timeout (so it lands in the report's pass/fail rollup), then raises on failure.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    while True:
        attempts += 1
        if _find_element(text):
            _record("note", f"assert visible '{text}' (after {attempts} check(s))", note="pass")
            return f"PASS: '{text}' is visible"
        if time.monotonic() >= deadline:
            _record("note", f"assert visible '{text}' — NOT found within {timeout_s}s", note="fail")
            raise RuntimeError(f"ASSERT FAILED: '{text}' not visible within {timeout_s}s.")
        time.sleep(0.5)


@mcp.tool()
def ios_assert_not_visible(text: str, timeout_s: float = 3.0) -> str:
    """Assert an element with the given text is ABSENT (waits until it's gone).

    Polls up to `timeout_s` for the element to disappear. Records PASS/FAIL note
    like ios_assert_visible, then raises on failure.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    while True:
        attempts += 1
        if not _find_element(text):
            _record("note", f"assert not-visible '{text}' (after {attempts} check(s))", note="pass")
            return f"PASS: '{text}' is not visible"
        if time.monotonic() >= deadline:
            _record("note", f"assert not-visible '{text}' — still present after {timeout_s}s", note="fail")
            raise RuntimeError(f"ASSERT FAILED: '{text}' still visible after {timeout_s}s.")
        time.sleep(0.5)


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
    # Entries are bare relative names like NNN.png / NNN.jpg, so concat's default
    # safe mode accepts them — no -safe 0, which keeps path traversal out of the listfile.
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


def _screenshot_img(name: str, alt: str) -> str:
    """Embed a run screenshot as a clickable base64 <img>, or a missing marker."""
    mime = "image/jpeg" if name.endswith((".jpg", ".jpeg")) else "image/png"
    try:
        with open(os.path.join(_run["dir"], name), "rb") as fh:
            uri = f"data:{mime};base64," + base64.b64encode(fh.read()).decode()
        return (f'<a href="{uri}" target="_blank">'
                f'<img class="shot" src="{uri}" alt="{html.escape(alt)}"></a>')
    except OSError:
        return '<span class="missing">[screenshot missing]</span>'


def _donut_svg(passes: int, fails: int) -> str:
    """Inline SVG pass/fail donut (no JS, no external libs). Green ring with a red
    arc proportional to failures; centre shows the pass rate."""
    total = passes + fails
    r, circ = 42.0, 2 * math.pi * 42.0
    if total == 0:
        center, sub = "—", "no checks"
        arc = ""
    else:
        rate = round(passes / total * 100)
        center, sub = f"{rate}%", "passed"
        fail_len = circ * (fails / total)
        arc = (f'<circle class="d-fail" cx="50" cy="50" r="42" '
               f'stroke-dasharray="{fail_len:.2f} {circ:.2f}" '
               f'transform="rotate(-90 50 50)"></circle>')
    return (
        f'<svg class="donut" viewBox="0 0 100 100" role="img" '
        f'aria-label="{passes} passed, {fails} failed">'
        f'<circle class="d-track" cx="50" cy="50" r="42"></circle>{arc}'
        f'<text class="d-num" x="50" y="48">{center}</text>'
        f'<text class="d-sub" x="50" y="64">{sub}</text></svg>'
    )


def _stat_card(value: str, label: str, cls: str = "") -> str:
    return (f'<div class="stat {cls}"><div class="stat-v">{value}</div>'
            f'<div class="stat-l">{label}</div></div>')


def _action_bars(steps: list[dict]) -> str:
    """Horizontal bar chart of action counts (excludes section markers)."""
    counts: dict[str, int] = {}
    for s in steps:
        if s["action"] == "section":
            continue
        counts[s["action"]] = counts.get(s["action"], 0) + 1
    if not counts:
        return ""
    top = max(counts.values())
    rows = []
    for act, n in sorted(counts.items(), key=lambda kv: kv[1], reverse=True):
        pct = round(n / top * 100)
        rows.append(
            f'<div class="bar-row"><span class="bar-lbl">{html.escape(act)}</span>'
            f'<span class="bar-track"><span class="bar-fill" style="width:{pct}%"></span></span>'
            f'<span class="bar-n">{n}</span></div>'
        )
    return '<div class="bars">' + "".join(rows) + "</div>"


def _render_step(s: dict, started: float) -> str:
    off = s["t"] - started
    badge = ""
    if s["action"] == "note":
        cls = {"pass": "ok", "fail": "bad"}.get(s["note"], "info")
        badge = f'<span class="badge {cls}">{html.escape(s["note"])}</span>'
    img = _screenshot_img(s["screenshot"], f'step {s["i"]}') if s["screenshot"] else ""
    return (
        f'<div class="step" id="step-{s["i"]}">'
        f'<div class="meta"><span class="i">#{s["i"]}</span>'
        f'<span class="act">{html.escape(s["action"])}</span>'
        f'<span class="off">+{off:.1f}s</span>{badge}</div>'
        f'<div class="detail">{html.escape(s["detail"])}</div>{img}</div>'
    )


def _split_sections(steps: list[dict]) -> list[dict]:
    """Group steps into sections by `section` markers. Steps before the first
    marker fall into an implicit opening section so older flows still render."""
    sections: list[dict] = []
    cur: dict | None = None

    def open_section(title: str) -> dict:
        sec = {"title": title, "steps": [], "passes": 0, "fails": 0}
        sections.append(sec)
        return sec

    for s in steps:
        if s["action"] == "section":
            cur = open_section(s["detail"] or "Section")
            continue
        if cur is None:
            cur = open_section(_run["label"] or "Run")
        cur["steps"].append(s)
        if s["action"] == "note" and s["note"] == "pass":
            cur["passes"] += 1
        elif s["action"] == "note" and s["note"] == "fail":
            cur["fails"] += 1
    return sections


def _render_report(ended: float, clip: str | None = None, clip_note: str = "") -> str:
    steps = _run["steps"]
    started = _run["started"] or ended
    fails = sum(1 for s in steps if s["action"] == "note" and s["note"] == "fail")
    passes = sum(1 for s in steps if s["action"] == "note" and s["note"] == "pass")
    shots = sum(1 for s in steps if s["screenshot"])
    action_steps = sum(1 for s in steps if s["action"] != "section")
    overall = "FAIL" if fails else "PASS"
    overall_cls = "bad" if fails else "ok"

    sections = _split_sections(steps)

    def sec_status(sec: dict) -> tuple[str, str]:
        if sec["fails"]:
            return "FAIL", "bad"
        if sec["passes"]:
            return "PASS", "ok"
        return "—", "info"

    # Table of contents + section bodies (anchored).
    toc_rows, body_blocks = [], []
    for n, sec in enumerate(sections, 1):
        label, cls = sec_status(sec)
        sid = f"sec-{n}"
        counts = (f'{sec["passes"]} pass · {sec["fails"]} fail · '
                  f'{len(sec["steps"])} steps')
        toc_rows.append(
            f'<li><a href="#{sid}"><span class="toc-t">{html.escape(sec["title"])}</span>'
            f'<span class="toc-c">{counts}</span>'
            f'<span class="badge {cls}">{label}</span></a></li>'
        )
        inner = "\n".join(_render_step(s, started) for s in sec["steps"]) \
            or '<p class="detail">No steps in this section.</p>'
        body_blocks.append(
            f'<section class="sec" id="{sid}">'
            f'<h2>{html.escape(sec["title"])}'
            f'<span class="badge {cls}">{label}</span></h2>{inner}</section>'
        )
    toc = ('<nav class="toc"><h2>What was tested</h2><ol>'
           + "\n".join(toc_rows) + "</ol></nav>") if toc_rows else ""
    body = "\n".join(body_blocks) or '<p class="detail">No steps were recorded.</p>'

    # Failures-first panel.
    fail_panel = ""
    if fails:
        items = []
        for n, sec in enumerate(sections, 1):
            for s in sec["steps"]:
                if s["action"] == "note" and s["note"] == "fail":
                    items.append(
                        f'<li><a href="#step-{s["i"]}">'
                        f'<span class="fp-sec">{html.escape(sec["title"])}</span>'
                        f'{html.escape(s["detail"])}</a></li>')
        fail_panel = ('<section class="fail-panel"><h2>Failures</h2><ol>'
                      + "".join(items) + "</ol></section>")

    title = html.escape(_run["label"] or "test")
    meta = " · ".join(filter(None, [
        f"device: {html.escape(_run['device'])}" if _run["device"] else "",
        f"iOS {html.escape(_run['ios'])}" if _run["ios"] else "",
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started)),
        f"{ended - started:.1f}s",
        f"{action_steps} steps · {shots} screenshots · {fails} failures",
    ]))

    clip_html = ""
    if clip and clip.endswith(".mp4"):
        clip_html = (f'<video class="clip" src="{html.escape(clip)}" '
                     f'controls loop muted playsinline></video>')
    elif clip:                                    # gif
        clip_html = f'<img class="clip" src="{html.escape(clip)}" alt="run timelapse">'
    elif clip_note:
        clip_html = f'<p class="clip-note">{html.escape(clip_note)}</p>'

    cards = "".join([
        _stat_card(str(action_steps), "Steps"),
        _stat_card(str(shots), "Screenshots"),
        _stat_card(str(passes), "Passes", "ok"),
        _stat_card(str(fails), "Failures", "bad" if fails else ""),
        _stat_card(str(len(sections)), "Sections"),
        _stat_card(f"{ended - started:.0f}s", "Duration"),
    ])
    summary = (
        '<section class="summary">'
        f'<div class="sum-chart">{_donut_svg(passes, fails)}</div>'
        f'<div class="sum-stats">{cards}</div>'
        f'<div class="sum-bars">{_action_bars(steps)}</div>'
        '</section>'
    )

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iMirror test report — {title}</title>
<style>{_REPORT_CSS}</style></head>
<body>
<header class="cover">
  <div class="cover-main">
    <p class="eyebrow">iMirror test report</p>
    <h1>{title} <span class="badge {overall_cls}">{overall}</span></h1>
    <div class="meta-top">{meta}</div>
  </div>
  {clip_html}
</header>
<main>
{summary}
{fail_panel}
{toc}
{body}
</main></body></html>"""


_REPORT_CSS = """
  :root { color-scheme: light dark; --card:#fff; --line:#0001; --muted:#6b7280;
          --ok:#16a34a; --bad:#dc2626; --info:#3b82f6; --accent:#6366f1; }
  @media (prefers-color-scheme: dark) {
    :root { --card:#22252b; --line:#ffffff14; --muted:#9aa3b2; } }
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0;
         background: #f6f7f9; color: #1c1e21; }
  @media (prefers-color-scheme: dark) { body { background:#16181c; color:#e6e6e6; } }
  h1 { margin:0 0 6px; font-size:24px; }
  h2 { font-size:15px; margin:0 0 12px; display:flex; align-items:center; gap:10px; }
  a { color:inherit; text-decoration:none; }
  .eyebrow { margin:0 0 4px; font-size:11px; letter-spacing:.12em; text-transform:uppercase;
             color:var(--accent); font-weight:700; }
  .meta-top { color:var(--muted); font-size:13px; }
  .badge { font-size:11px; font-weight:700; padding:2px 9px; border-radius:999px;
           vertical-align:middle; letter-spacing:.03em; }
  .badge.ok { background:#16a34a22; color:var(--ok); }
  .badge.bad { background:#dc262622; color:var(--bad); }
  .badge.info { background:#9ca3af22; color:var(--muted); }
  h1 .badge { font-size:13px; margin-left:8px; }
  /* Cover */
  .cover { background:linear-gradient(135deg,#6366f1,#8b5cf6); color:#fff;
           padding:40px 32px; display:flex; gap:28px; align-items:center;
           justify-content:space-between; flex-wrap:wrap; }
  .cover .eyebrow { color:#ffffffcc; }
  .cover .meta-top { color:#ffffffd8; }
  .cover .badge.ok { background:#fff; color:var(--ok); }
  .cover .badge.bad { background:#fff; color:var(--bad); }
  .cover .clip { margin:0; max-width:200px; box-shadow:0 8px 28px #0003; }
  main { max-width:860px; margin:24px auto; padding:0 16px; }
  /* Summary */
  .summary { background:var(--card); border:1px solid var(--line); border-radius:14px;
             padding:22px; margin:0 0 18px; display:grid;
             grid-template-columns:160px 1fr; gap:24px; align-items:center; }
  .sum-bars { grid-column:1 / -1; }
  .donut { width:150px; height:150px; }
  .d-track { fill:none; stroke:#16a34a33; stroke-width:11; }
  .d-fail  { fill:none; stroke:var(--bad); stroke-width:11; stroke-linecap:round; }
  .donut .d-num { fill:currentColor; font-size:22px; font-weight:700; text-anchor:middle; }
  .donut .d-sub { fill:var(--muted); font-size:9px; text-anchor:middle;
                  text-transform:uppercase; letter-spacing:.1em; }
  .sum-stats { display:grid; grid-template-columns:repeat(3,1fr); gap:12px; }
  .stat { background:#00000005; border:1px solid var(--line); border-radius:10px;
          padding:12px 14px; }
  @media (prefers-color-scheme: dark) { .stat { background:#ffffff08; } }
  .stat-v { font-size:22px; font-weight:700; font-variant-numeric:tabular-nums; }
  .stat-l { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
  .stat.ok .stat-v { color:var(--ok); } .stat.bad .stat-v { color:var(--bad); }
  .bars { display:flex; flex-direction:column; gap:7px; }
  .bar-row { display:flex; align-items:center; gap:10px; font-size:12px; }
  .bar-lbl { width:120px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em;
             font-size:11px; text-align:right; }
  .bar-track { flex:1; height:8px; background:#00000010; border-radius:99px; overflow:hidden; }
  .bar-fill { display:block; height:100%; background:var(--accent); border-radius:99px; }
  .bar-n { width:28px; font-variant-numeric:tabular-nums; }
  /* Failures panel */
  .fail-panel { background:#dc26260d; border:1px solid #dc262633; border-radius:14px;
                padding:18px 22px; margin:0 0 18px; }
  .fail-panel h2 { color:var(--bad); }
  .fail-panel ol { margin:0; padding-left:18px; }
  .fail-panel li { margin:4px 0; }
  .fail-panel .fp-sec { font-weight:700; margin-right:6px; }
  .fail-panel a:hover { text-decoration:underline; }
  /* TOC */
  .toc { background:var(--card); border:1px solid var(--line); border-radius:14px;
         padding:18px 22px; margin:0 0 18px; }
  .toc ol { list-style:none; margin:0; padding:0; counter-reset:s; }
  .toc li a { display:flex; align-items:center; gap:12px; padding:9px 0;
              border-bottom:1px solid var(--line); }
  .toc li:last-child a { border-bottom:0; }
  .toc li a:before { counter-increment:s; content:counter(s); font-weight:700;
                     color:var(--muted); min-width:18px; }
  .toc-t { font-weight:600; flex:1; }
  .toc-c { color:var(--muted); font-size:12px; font-variant-numeric:tabular-nums; }
  .toc a:hover .toc-t { color:var(--accent); }
  /* Sections + steps */
  .sec { margin:0 0 26px; scroll-margin-top:16px; }
  .sec > h2 { position:sticky; top:0; background:#f6f7f9; padding:8px 0; z-index:1; }
  @media (prefers-color-scheme: dark) { .sec > h2 { background:#16181c; } }
  .step { background:var(--card); border:1px solid var(--line); border-radius:10px;
          padding:14px 16px; margin:0 0 12px; scroll-margin-top:60px; }
  .meta { display:flex; align-items:center; gap:10px; font-size:13px; color:var(--muted); }
  .i { font-weight:700; color:#9ca3af; }
  .act { font-weight:600; color:inherit; text-transform:uppercase; letter-spacing:.04em;
         font-size:12px; }
  .off { margin-left:auto; font-variant-numeric:tabular-nums; }
  .detail { margin:6px 0; font-family:ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size:13px; word-break:break-word; }
  .shot { margin-top:8px; max-width:100%; border-radius:8px; border:1px solid #0002;
          display:block; }
  .missing { color:var(--bad); font-size:13px; }
  .clip { display:block; width:100%; max-width:480px; margin:16px auto 0;
          border-radius:10px; border:1px solid #0002; }
  .clip-note { color:var(--muted); font-size:13px; font-style:italic; }
"""


if __name__ == "__main__":
    mcp.run()
