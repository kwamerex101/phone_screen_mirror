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
import http.client
import json
import os
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


# ---- HTTP helpers (fresh connection per request) -------------------------------

def _req(method: str, path: str, body: dict | None = None) -> tuple[int, dict[str, Any]]:
    data = json.dumps(body).encode() if body is not None else None
    # WDA's CocoaHTTPServer occasionally drops a connection mid-exchange
    # (RemoteDisconnected / reset). Retry such transient failures a couple times.
    last_exc: Exception | None = None
    for attempt in range(3):
        req = urllib.request.Request(
            WDA + path, data=data, method=method,
            headers={"Content-Type": "application/json", "Connection": "close"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
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
    return Image(data=base64.b64decode(b64), format="png")


@mcp.tool()
def ios_source() -> str:
    """Get the accessibility hierarchy (XML) of the current screen.

    Useful for finding element labels/identifiers to drive ios_find_and_tap, or
    for asserting that expected UI is present. The output can be large; prefer a
    screenshot for a quick look and use this when you need exact element text.
    """
    # /source is a sessionless WDA route.
    code, j = _req("GET", "/source")
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
    _session_post("/actions", _pointer([
        {"type": "pointerMove", "duration": 0, "x": x, "y": y},
        {"type": "pointerDown", "button": 0},
        {"type": "pause", "duration": 40},
        {"type": "pointerUp", "button": 0},
    ]))
    return f"tapped ({x}, {y})"


@mcp.tool()
def ios_swipe(from_x: float, from_y: float, to_x: float, to_y: float,
              duration_ms: int = 250) -> str:
    """Swipe/drag from one point to another (logical points). Use for scrolling,
    paging, and drag gestures. Larger duration_ms = slower drag (less inertia).
    """
    _session_post("/actions", _pointer([
        {"type": "pointerMove", "duration": 0, "x": from_x, "y": from_y},
        {"type": "pointerDown", "button": 0},
        {"type": "pointerMove", "duration": max(1, duration_ms), "x": to_x, "y": to_y},
        {"type": "pointerUp", "button": 0},
    ]))
    return f"swiped ({from_x},{from_y}) -> ({to_x},{to_y})"


@mcp.tool()
def ios_type(text: str) -> str:
    """Type text into the currently focused field. Tap a text field first.

    Special characters: use "\\n" for return, "\\b" (U+0008) for backspace.
    """
    _session_post("/wda/keys", {"value": list(text)})
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
    return f"pressed {name}"


@mcp.tool()
def ios_find_and_tap(text: str) -> str:
    """Find an on-screen element by its visible label/name and tap it.

    Convenience for tapping by text instead of pixel coordinates (e.g. a button
    titled "Settings"). Fails with a clear message if no matching element is
    found — fall back to ios_source to inspect, or ios_tap with coordinates.
    """
    sid = _ensure_session()
    safe = text.replace("'", "\\'")
    predicate = f"label == '{safe}' OR name == '{safe}' OR value == '{safe}'"
    code, j = _req("POST", f"/session/{sid}/element",
                   {"using": "predicate string", "value": predicate})
    if code == 404:
        _session["id"] = None
        return ios_find_and_tap(text)
    eid = (j.get("value") or {}).get("ELEMENT") or \
          (j.get("value") or {}).get("element-6066-11e4-a52e-4f735466cecf")
    if not eid:
        raise RuntimeError(f"No element matching '{text}'. Use ios_source to inspect.")
    _req("POST", f"/session/{sid}/element/{eid}/click", {})
    return f"tapped element '{text}'"


if __name__ == "__main__":
    mcp.run()
