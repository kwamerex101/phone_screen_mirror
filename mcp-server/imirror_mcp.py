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

__version__ = "1.2.0"

import atexit
import base64
import functools
import html
import http.client
import ipaddress
import json
import math
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any
from urllib.parse import urlsplit

from mcp.server.fastmcp import FastMCP, Image


class ErrorKind:
    """Closed set of machine-readable failure classifications for
    MCPToolError. Plain string constants (not a real Enum) so `error_kind`
    stays a bare string — both an attribute value and the thing embedded in
    the wire-visible message tail (see MCPToolError.__str__)."""
    VALIDATION = "validation"
    NOT_FOUND = "not_found"
    WDA_HTTP = "wda_http"
    UNREACHABLE = "unreachable"
    WEDGED = "wedged"
    TIMEOUT = "timeout"
    UNSUPPORTED = "unsupported"


_ERROR_KINDS = {ErrorKind.VALIDATION, ErrorKind.NOT_FOUND, ErrorKind.WDA_HTTP,
                ErrorKind.UNREACHABLE, ErrorKind.WEDGED, ErrorKind.TIMEOUT,
                ErrorKind.UNSUPPORTED}


class MCPToolError(RuntimeError):
    """A RuntimeError that also carries a machine-readable classification.

    FastMCP hands a raised exception back to the agent as `str(e)` — bare
    attributes such as `.error_kind` never reach the agent over the wire.
    So the classification is ALSO encoded into the message itself, as a
    trailing `[kind=<kind>]` (or `[kind=<kind> code=<code>]`) tag appended
    by `__str__` after the human-readable message. `.error_kind`/
    `.error_code` stay available as plain attributes too, for in-process
    use (e.g. the run report).

    Subclassing RuntimeError keeps every existing
    `pytest.raises(RuntimeError, match=...)` test passing unchanged — this
    is additive, not a breaking change to the exception contract.
    """

    def __init__(self, message: str, *, kind: str, code: str | None = None):
        if kind not in _ERROR_KINDS:
            raise ValueError(f"unknown MCPToolError kind: {kind!r}")
        super().__init__(message)
        self.human_message = message
        self.error_kind = kind
        self.error_code = code

    def __str__(self) -> str:
        tail = (f"[kind={self.error_kind}]" if self.error_code is None
                else f"[kind={self.error_kind} code={self.error_code}]")
        return f"{self.human_message} {tail}"


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


# Named timeout tiers, in place of scattered per-call literals.
#   PROBE    — cheap existence/point checks (/status, element lookups in poll
#              loops, best-effort settings POSTs). Deliberately short: a poll
#              loop calls this many times, and a wedged WDA should surface fast.
#   INTERACT — gestures and other session operations. Same value as the old
#              flat _req default (15s) — this is a relabel, not a behavior change.
#   TREE     — full /source reads. A legitimately heavy accessibility tree has
#              been observed taking >15s (~160KB on a real device), so this
#              stays generous. What actually protects against a stalled WDA
#              queue is the probe-gated retry in _req_tree, not a short timeout
#              here — WDA serializes on one XCUITest queue, so a short timeout
#              plus a blind retry would just queue a second full-tree
#              serialization behind whatever is already stalling it.
_TIMEOUT_PROBE = 5
_TIMEOUT_INTERACT = 15
_TIMEOUT_TREE = 60

mcp = FastMCP("imirror")

_session: dict[str, str | None] = {"id": None}

# Optional per-run recording. Off until ios_start_run; every action/screenshot is
# appended to _run["steps"], and ios_finish_run renders them into a report.
_run: dict[str, Any] = {
    "active": False, "dir": None, "label": None, "started": None,
    "device": None, "ios": None, "steps": [],
    "recorder": None, "recording": None,
}


def _record(action: str, detail: str = "", screenshot: str | None = None,
            note: str = "", verdict: dict[str, Any] | None = None) -> None:
    """Append a step to the active run. No-op when no run is recording.

    Each step is also appended to steps.jsonl in the run dir so a crash between
    ios_start_run and ios_finish_run leaves a replayable log next to the
    screenshots already on disk (the in-memory timeline would otherwise be lost).
    The disk append is best-effort — a write failure must never break recording.

    `verdict` (I8 schema addition) is an optional structured outcome, e.g.
    `{"kind": "fail", "reason": <str>, "error_kind": ..., "error_code": ...}`
    for an auto-recorded tool failure (see `_recorded`), or
    `{"kind": "idle", "reason": <settled|still-moving|empty|too-few-reads>}`
    for an `ios_await_idle` read. It is additive: the legacy `note` field
    keeps working unchanged for callers that don't pass a verdict.
    """
    if not _run["active"]:
        return
    step = {
        "i": len(_run["steps"]) + 1, "t": time.time(),
        "action": action, "detail": detail, "screenshot": screenshot, "note": note,
        "verdict": verdict,
    }
    _run["steps"].append(step)
    run_dir = _run.get("dir")
    if run_dir:
        try:
            with open(os.path.join(run_dir, "steps.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(step) + "\n")
        except OSError:
            pass


def _step_is_fail(s: dict[str, Any]) -> bool:
    """True if a recorded step counts as a failure in the report rollup.

    Two paths count: the legacy manual `note="fail"` marker (still used by a
    couple of call sites for a PASS-only signal), and a structured `verdict`
    with `kind == "fail"` recorded automatically by `_recorded` when a
    decorated tool raises. This is an intentional semantics change (I8): a
    raised failure that previously went unrecorded — because no tool
    manually logged a fail note before raising — now flips a report from
    PASS to FAIL. An `idle` verdict (or any other non-"fail" kind) never
    counts here.
    """
    if s["action"] == "note" and s["note"] == "fail":
        return True
    v = s.get("verdict")
    return bool(v and v.get("kind") == "fail")


def _recorded(fn):
    """Decorator: auto-record ONE `fail` step (with a structured verdict) when
    the wrapped tool raises during an active run, then re-raise unchanged.

    Centralizes fail-recording at the raise boundary so individual tools
    don't each need to remember to log a fail note before raising — this
    replaces the old manual `_record(..., note="fail")` calls in
    `ios_scroll_to`/`ios_assert_visible`/`ios_assert_not_visible`, which are
    removed in favor of this single source of truth (avoids double-recording
    the same failure).

    No-op when no run is active: it still re-raises, but records nothing —
    behavior is identical to calling the undecorated function.

    Apply this UNDER `@mcp.tool()` (i.e. `@mcp.tool()` on top, `@_recorded`
    directly above `def`) so FastMCP registers/introspects the real function.
    `functools.wraps` preserves `__name__`/`__doc__`/signature for that.
    """
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except Exception as e:
            if _run["active"]:
                verdict: dict[str, Any] = {
                    "kind": "fail",
                    "reason": e.human_message if isinstance(e, MCPToolError) else str(e),
                }
                if isinstance(e, MCPToolError):
                    verdict["error_kind"] = e.error_kind
                    verdict["error_code"] = e.error_code
                _record(fn.__name__, detail=verdict["reason"], verdict=verdict)
            raise
    return wrapper


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
         timeout: float = _TIMEOUT_INTERACT) -> tuple[int, dict[str, Any]]:
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
            raise MCPToolError(
                f"WDA timed out after {timeout}s on {path}. It may be busy or "
                f"wedged — {_wedged_hint()}.", kind=ErrorKind.WEDGED) from e
        except OSError as e:
            raise MCPToolError(
                f"Cannot reach WDA at {WDA} ({e}). {_unreachable_hint()}",
                kind=ErrorKind.UNREACHABLE) from e
        # HTTP errors (4xx/5xx) come back as a normal response with http.client,
        # not an exception — callers (e.g. _session_post) rely on seeing the code
        # and any JSON error body, so return them rather than raising.
        try:
            return status, (json.loads(raw) if raw else {})
        except Exception:
            if status >= 400:
                return status, {"error": raw.decode("utf-8", "replace")[:300]}
            raise
    raise MCPToolError(
        f"WDA dropped the connection repeatedly on {path} ({last_exc}). "
        f"It may be busy or wedged — {_wedged_hint()}.", kind=ErrorKind.WEDGED)


def _req_tree(path: str) -> tuple[int, dict[str, Any]]:
    """GET a read-only /source route at the TREE tier, riding out one stall
    instead of failing the step outright.

    On a timeout, a blind retry is dangerous: WDA serializes on a single
    XCUITest queue, so retrying immediately just queues a second full-tree
    serialization behind whatever is already stalling the first one. Instead,
    probe cheaply first (GET /status at the PROBE tier):
      - probe answers  -> the queue cleared, so retry the tree read once more
        (a second timeout there propagates as the usual wedged error).
      - probe also times out -> WDA is still stalled; re-raise the original
        error immediately rather than piling on more work.

    Read-only routes ONLY. Never wrap a gesture or other state-changing POST
    in this: a timed-out call may have already applied server-side, and a
    retry could double-apply it.
    """
    try:
        return _req("GET", path, timeout=_TIMEOUT_TREE)
    except RuntimeError as first_exc:
        if not isinstance(first_exc.__cause__, (socket.timeout, TimeoutError)):
            raise  # not a timeout (e.g. repeated connection drops) — nothing to ride out
        try:
            _req("GET", "/status", timeout=_TIMEOUT_PROBE)
        except Exception:
            raise first_exc from None  # still stalled — don't pile another read on the queue
        return _req("GET", path, timeout=_TIMEOUT_TREE)  # queue cleared — ride it out once


def _screenshot_quality() -> int:
    """IMIRROR_SCREENSHOT_QUALITY as 0 (lossless PNG), 1 (medium JPEG), or 2
    (low JPEG). Unset/invalid falls back to a target-aware default: 0 on the
    simulator (where WDA ignores the JPEG path and higher values only bloat the
    PNG) and 1 on a physical device (where 1/2 make WDA JPEG-encode device-side,
    cutting encode time and payload). An explicit valid env value always wins.
    Never raises."""
    default = 0 if _IS_SIM else 1
    raw = os.environ.get("IMIRROR_SCREENSHOT_QUALITY")
    if raw is None:
        return default
    try:
        q = int(raw)
    except (ValueError, TypeError):
        return default
    return q if q in (0, 1, 2) else default


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
             {"settings": {"waitForIdleTimeout": 0, "animationCoolOffTimeout": 0}}, timeout=_TIMEOUT_PROBE)
    except Exception:
        pass
    # Ask WDA to JPEG-encode screenshots device-side (screenshotQuality 1/2) —
    # cuts encode time and payload vs lossless PNG. Separate best-effort POST so
    # a build that rejects the key can't also drop the idle-wait settings above.
    try:
        _req("POST", f"/session/{sid}/appium/settings",
             {"settings": {"screenshotQuality": _screenshot_quality()}}, timeout=_TIMEOUT_PROBE)
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
        raise MCPToolError(f"WDA error (HTTP {code}) on {subpath}: {j}",
                            kind=ErrorKind.WDA_HTTP, code=f"WDA_HTTP_{code}")
    return j


def _session_get(subpath: str, _retry: bool = True) -> dict[str, Any]:
    """GET /session/<id><subpath>; recreate the session once on 404."""
    sid = _ensure_session()
    code, j = _req("GET", f"/session/{sid}{subpath}")
    if code == 404 and _retry:               # stale session (WDA restarted)
        _session["id"] = None
        return _session_get(subpath, _retry=False)
    if code >= 400:
        raise MCPToolError(f"WDA error (HTTP {code}) on {subpath}: {j}",
                            kind=ErrorKind.WDA_HTTP, code=f"WDA_HTTP_{code}")
    return j


def _pointer(steps: list[dict]) -> dict:
    return {"actions": [{"type": "pointer", "id": "finger1",
                         "parameters": {"pointerType": "touch"}, "actions": steps}]}


# Serialise gesture (/actions) posts across threads. WDA has a single XCUITest
# queue; two overlapping gestures stall it and can wedge the wire. With several
# agents (or test threads) sharing one MCP server, the lock prevents that.
_gesture_lock = threading.Lock()

# Serialise the simulator recorder handoff (start/stop) across threads. Two
# racing ios_start_run calls could otherwise interleave their _run["recorder"]
# mutations and orphan a recordVideo child with no reference left to kill it.
# RLock so a thread already holding it (ios_start_run) can call into
# _start_sim_recording/_stop_sim_recording, which also take the lock.
_recorder_lock = threading.RLock()


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
        raise MCPToolError("direction must be one of up / down / left / right",
                            kind=ErrorKind.VALIDATION)
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


def _find_element(text: str, visible_only: bool = False, _retry: bool = True) -> str | None:
    """Return the element id of the first element whose label/name/value matches
    `text`, or None if no such element is on screen. Recreates the session once
    on a stale 404.

    `visible_only` ANDs `visible == 1` into the predicate so only an on-screen
    match counts — WDA returns the first predicate match, which is reading
    order, so this is how a caller waits for the first VISIBLE match rather
    than any matching element regardless of visibility. Extending the same
    predicate string (rather than switching to `/elements` + per-element rect
    lookups) keeps this a single round trip; the latter would be N round trips
    per poll, a real-device perf regression. Default False keeps today's
    behavior for ios_find_and_tap / ios_scroll_to / the asserts.
    """
    sid = _ensure_session()
    # Escape backslashes BEFORE quotes: input ending in \' would otherwise become
    # \\' (escaped backslash + live quote) and break out of the predicate literal.
    safe = text.replace("\\", "\\\\").replace("'", "\\'")
    predicate = f"label == '{safe}' OR name == '{safe}' OR value == '{safe}'"
    if visible_only:
        predicate = f"({predicate}) AND visible == 1"
    # PROBE tier: poll loops (ios_wait_for, ios_find_and_tap, ios_scroll_to, the
    # asserts) call this many times per second, so a wedged WDA should surface
    # fast rather than each lookup eating the INTERACT tier.
    code, j = _req("POST", f"/session/{sid}/element",
                   {"using": "predicate string", "value": predicate},
                   timeout=_TIMEOUT_PROBE)
    if code == 404 and _retry:
        _session["id"] = None
        return _find_element(text, visible_only=visible_only, _retry=False)
    return (j.get("value") or {}).get("ELEMENT") or \
           (j.get("value") or {}).get("element-6066-11e4-a52e-4f735466cecf")


def _find_element_or_timeout(text: str, visible_only: bool = False) -> tuple[str | None, MCPToolError | None]:
    """Call `_find_element`, catching a timeout-class failure so poll loops can
    treat a slow-but-not-wedged lookup as a transient miss instead of
    aborting their whole retry/timeout budget after one attempt.

    `_find_element` posts at the PROBE tier (5s) so poll loops can surface a
    wedged WDA fast — but that same short tier means a legitimately slow
    (>5s, not wedged) lookup also raises. Swallowing only WEDGED/TIMEOUT here
    lets the caller keep polling toward its own deadline; anything else
    (unreachable, wda_http, ...) still propagates immediately so callers fail
    fast when WDA is genuinely down rather than confused with WDA slow.

    Returns `(element_id_or_None, error_or_None)`. `error` is set only when
    this attempt was a caught timeout — callers use it to decide, once their
    budget is exhausted, whether to report a plain "not found" (at least one
    attempt read cleanly) or re-raise the timeout (every attempt timed out,
    meaning WDA was wedged the whole time).
    """
    try:
        return _find_element(text, visible_only=visible_only), None
    except MCPToolError as e:
        if e.error_kind in (ErrorKind.WEDGED, ErrorKind.TIMEOUT):
            return None, e
        raise


# ---- Compact accessibility tree (ios_source text mode) --------------------------
#
# WDA's /source can return either an XCUITest XML dump or (on some WDA builds,
# via ?format=json) a JSON tree. We do not assume JSON support — probe once and
# fall back to XML — and normalize either shape into one internal node dict
# before rendering, so the renderer only has to know one shape:
#   {type, label, name, value, identifier, enabled, visible, hittable, rect, children}
# `rect` is (x, y, width, height) in points or None when unusable/missing.

# Cap the rendered tree by ELEMENT COUNT, not bytes — a screen can carry a huge
# but info-dense tree, and a byte cap would truncate mid-element. The full
# payload is always parsed first; only the rendered output is capped.
_SOURCE_MAX_ELEMENTS = 400

# "Content" roles are always rendered, even with an empty label, because they're
# the elements an agent actually taps/reads. Pure containers (Other, Window,
# Group, ...) are rendered only when they carry their own label/value/identifier
# or are themselves interactive — otherwise they're collapsed and we recurse
# straight into their children.
_SOURCE_CONTENT_ROLES = {
    "Button", "StaticText", "TextField", "SecureTextField", "TextView",
    "Image", "Cell", "SearchField", "Switch", "Link", "Icon", "Key",
}


def _source_short_type(raw_type: str | None) -> str:
    """Strip the "XCUIElementType" prefix XML tags/JSON `type` values carry."""
    t = raw_type or "Other"
    prefix = "XCUIElementType"
    return t[len(prefix):] if t.startswith(prefix) else t


def _source_bool(v: Any) -> bool | None:
    """Normalize a WDA truthy field (XML string "true"/"false" or JSON bool) to
    a real bool, or None when the field is absent/unrecognized."""
    if isinstance(v, bool):
        return v
    if v is None:
        return None
    if isinstance(v, str):
        low = v.strip().lower()
        if low in ("true", "1"):
            return True
        if low in ("false", "0"):
            return False
        return None
    return bool(v)


def _source_rect(x: Any, y: Any, w: Any, h: Any) -> tuple[float, float, float, float] | None:
    try:
        return (float(x), float(y), float(w), float(h))
    except (TypeError, ValueError):
        return None


def _norm_source_xml(el: ET.Element) -> dict[str, Any]:
    """Normalize one WDA XML element (and its subtree) into the internal node shape."""
    a = el.attrib
    return {
        "type": a.get("type") or el.tag,
        "label": a.get("label") or None,
        "name": a.get("name") or None,
        "value": a.get("value") or None,
        "identifier": a.get("identifier") or None,
        "enabled": _source_bool(a.get("enabled")),
        "visible": _source_bool(a.get("visible")),
        "hittable": _source_bool(a.get("hittable")),
        "rect": _source_rect(a.get("x"), a.get("y"), a.get("width"), a.get("height")),
        "children": [_norm_source_xml(c) for c in el],
    }


def _norm_source_json(d: dict) -> dict[str, Any] | None:
    """Normalize one WDA JSON tree node (and its subtree) into the internal node
    shape. Returns None for a malformed (non-dict) node so callers can skip it."""
    if not isinstance(d, dict):
        return None
    rect_field = d.get("rect")
    if isinstance(rect_field, dict):
        rect = _source_rect(rect_field.get("x"), rect_field.get("y"),
                            rect_field.get("width"), rect_field.get("height"))
    else:
        rect = _source_rect(d.get("x"), d.get("y"), d.get("width"), d.get("height"))
    children = [n for n in (_norm_source_json(c) for c in d.get("children") or []) if n]
    return {
        "type": d.get("type") or "Other",
        "label": d.get("label") or None,
        "name": d.get("name") or None,
        "value": d.get("value") or None,
        "identifier": d.get("identifier") or None,
        "enabled": _source_bool(d.get("isEnabled", d.get("enabled"))),
        "visible": _source_bool(d.get("isVisible", d.get("visible"))),
        "hittable": _source_bool(d.get("isHittable", d.get("hittable"))),
        "rect": rect,
        "children": children,
    }


def _fetch_source_json_tree() -> dict[str, Any] | None:
    """Probe WDA's JSON source once. Returns a normalized root node, or None if
    this WDA build doesn't support it (non-2xx, missing/non-dict `value`, or the
    request itself blows up) so the caller falls back to XML. Never raises."""
    try:
        code, j = _req_tree("/source?format=json")
    except Exception:
        return None
    if code >= 400:
        return None
    value = j.get("value")
    if not isinstance(value, dict):
        return None
    return _norm_source_json(value)


def _fetch_source_xml_tree() -> dict[str, Any]:
    """Fetch and parse WDA's XML /source (the universally-supported form)."""
    code, j = _req_tree("/source")
    if code >= 400:
        raise MCPToolError(f"WDA error (HTTP {code}) on /source: {j}",
                            kind=ErrorKind.WDA_HTTP, code=f"WDA_HTTP_{code}")
    src = j.get("value", "")
    if not isinstance(src, str):
        raise RuntimeError(f"WDA returned an unexpected /source payload: {j}")
    return _norm_source_xml(ET.fromstring(src))


def _fetch_source_tree() -> dict[str, Any]:
    """Probe-and-fallback source acquisition (never assume WDA supports JSON)."""
    return _fetch_source_json_tree() or _fetch_source_xml_tree()


def _collect_source_elements(node: dict[str, Any], depth: int,
                              out: list[tuple[int, dict[str, Any]]]) -> None:
    """Walk the full normalized tree collecting the elements worth rendering
    (content roles always; containers only when they carry info or are
    interactive), in document order. Always recurses into children regardless
    of whether `node` itself qualifies, so a collapsed container's meaningful
    descendants are never lost."""
    short = _source_short_type(node.get("type"))
    has_info = any(node.get(f) for f in ("label", "name", "value", "identifier"))
    interactive = node.get("enabled") is True or node.get("hittable") is True
    if short in _SOURCE_CONTENT_ROLES or has_info or interactive:
        out.append((depth, node))
    for child in node.get("children") or []:
        _collect_source_elements(child, depth + 1, out)


def _render_source_line(depth: int, node: dict[str, Any],
                        win_w: float, win_h: float) -> str:
    short = _source_short_type(node.get("type"))
    parts = [("  " * depth) + short]
    for field, tag in (("label", "label"), ("name", "name"),
                       ("value", "value"), ("identifier", "id")):
        v = node.get(field)
        if v:
            parts.append(f'{tag}="{v}"')
    flags = [name for name, v in (("enabled", node.get("enabled")),
                                  ("visible", node.get("visible")),
                                  ("hittable", node.get("hittable"))) if v is True]
    if flags:
        parts.append("[" + ",".join(flags) + "]")
    rect = node.get("rect")
    if rect and win_w and win_h:
        x, y, w, h = rect
        nx, ny, nw, nh = x / win_w, y / win_h, w / win_w, h / win_h
        parts.append(f"norm=({nx:.3f},{ny:.3f},{nw:.3f},{nh:.3f})")
    return " ".join(parts)


def _render_source_text(root: dict[str, Any]) -> str:
    """Render the normalized tree as one line per meaningful element: type,
    whichever of label/name/value/identifier is present, interactivity flags,
    and a normalized [0,1] frame (from `_win_size()`, so a stale 30s-cached
    size or a mid-rotation call can skew the frame briefly — same caveat as
    every other tool that reads it)."""
    elements: list[tuple[int, dict[str, Any]]] = []
    _collect_source_elements(root, 0, elements)
    win_w, win_h = _win_size()
    lines = ["# tap point = (x + w/2, y + h/2) in normalized [0,1] coords, "
             "multiply by window size"]
    total = len(elements)
    for depth, node in elements[:_SOURCE_MAX_ELEMENTS]:
        lines.append(_render_source_line(depth, node, win_w, win_h))
    dropped = total - _SOURCE_MAX_ELEMENTS
    if dropped > 0:
        lines.append(f"… ({dropped} elements dropped; refine with a more specific screen)")
    return "\n".join(lines)


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
    configured. This is now STRICT: only a real JPEG SOI+marker prefix
    (`\\xff\\xd8\\xff`) or the full 8-byte PNG magic
    (`\\x89PNG\\r\\n\\x1a\\n`) is accepted. Anything else raises
    MCPToolError instead of guessing.

    This reverses the previous lenient design, which defaulted to
    `("png", ".png")` for any unrecognized header on the theory that a
    screenshot which came back should always return rather than erroring on
    an odd header. In practice that swallowed real failures: an HTML error
    page, an empty body, or a truncated payload from WDA would silently be
    reported to the caller as a valid PNG. Failing loudly here surfaces
    those cases instead of shipping garbage bytes labeled as an image.
    """
    if data[:3] == b"\xff\xd8\xff":
        return "jpeg", ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png", ".png"
    preview = data[:16].hex()
    raise MCPToolError(
        f"WDA's /screenshot response was not a recognizable image "
        f"(likely an error page, empty body, or truncated payload from WDA). "
        f"Got {len(data)} byte(s); first bytes: {preview}",
        kind=ErrorKind.WDA_HTTP,
        code="SCREENSHOT_NOT_IMAGE",
    )


def _screenshot_bytes_wda() -> bytes:
    """Capture a screenshot over WDA. Used directly on a device, and as the
    simulator's fallback when the simctl fast path fails."""
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
    return base64.b64decode(b64)


def _screenshot_bytes_simctl() -> bytes:
    """Capture a screenshot via `simctl io booted screenshot`. Simulator-only,
    session-free, and faster than the WDA round-trip. Raises RuntimeError (via
    `_simctl`) or OSError on failure; callers should fall back to WDA."""
    fd, path = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        _simctl("io", "booted", "screenshot", path)
        with open(path, "rb") as f:
            return f.read()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


@mcp.tool()
def ios_screenshot() -> Image:
    """Capture the iPhone's current screen. Returns a PNG by default. On a
    physical device, IMIRROR_SCREENSHOT_QUALITY=1/2 makes WDA return smaller,
    faster JPEG frames; the simulator always returns PNG.

    On the simulator, the screenshot is captured via `simctl io booted
    screenshot` (session-free, faster than the WDA round-trip), falling back
    to WDA if simctl is unavailable or fails. The device path is unchanged.

    Returns a full-resolution device screenshot. Needs no macOS Screen Recording
    permission (the frame comes from WebDriverAgent, not a Mac screen capture).
    Use it to see the device state before/after an action.
    """
    if _IS_SIM:
        try:
            data = _screenshot_bytes_simctl()
        except (RuntimeError, OSError):
            # Deliberate graceful degradation: simctl is a fast path that can be
            # unavailable (no xcrun, no booted sim, a transient simctl hiccup).
            # WDA is already up on the simulator for gestures/AX, so fall back to
            # it rather than failing the call outright. This is not swallowing a
            # real error — the sim path never regresses below "as reliable as
            # before this fast path existed."
            data = _screenshot_bytes_wda()
    else:
        data = _screenshot_bytes_wda()
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
def ios_source(format: str = "text") -> str:
    """Get the accessibility hierarchy of the current screen.

    Default (`format="text"`, NEW as of 1.1.0): a compact tree, one line per
    meaningful element — type, whichever of label/name/value/identifier is
    present, interactivity flags (enabled/visible/hittable, when known), and a
    normalized [0,1] frame. The first line spells out the tap formula:
    `tap point = (x + w/2, y + h/2) in normalized [0,1] coords, multiply by
    window size` — multiply that point by ios_window_size() to get real tap
    coordinates. Frames are computed against the cached window size (30s TTL,
    invalidated by ios_orientation), so a size read right after a rotation can
    be briefly stale. Pure containers (Other/Window/Group/...) are collapsed
    unless they carry their own label/value/identifier or are interactive;
    content elements (buttons, text, fields, images, cells, ...) always
    appear, even with an empty label. Output is capped at 400 elements (by
    count, not bytes — the full tree is always parsed first); a trailing line
    reports how many were dropped, if any. This is far cheaper for an agent to
    read than the raw XML — prefer it unless you need the exact raw markup.

    `format="xml"` returns the raw WDA source string unchanged (today's
    original behavior): hard-truncated at 20,000 characters with a
    "… (truncated)" suffix, no element cap, no normalization.

    Either mode is useful for finding element labels/identifiers to drive
    ios_find_and_tap, or for asserting that expected UI is present.
    """
    if format == "xml":
        # /source is a sessionless WDA route. On a complex screen WDA can take
        # far longer than a tap to serialise the whole tree (seen >15s, ~160 KB
        # on a real device), so give it the TREE tier — and ride out one stall
        # via _req_tree rather than fail the step outright.
        code, j = _req_tree("/source")
        if code >= 400:
            raise MCPToolError(f"WDA error (HTTP {code}) on /source: {j}",
                                kind=ErrorKind.WDA_HTTP, code=f"WDA_HTTP_{code}")
        src = j.get("value", "")
        if not isinstance(src, str):
            src = json.dumps(src)
        if len(src) > 20000:
            src = src[:20000] + "\n… (truncated)"
        return src
    if format != "text":
        raise MCPToolError(f"format must be 'text' or 'xml', got {format!r}",
                            kind=ErrorKind.VALIDATION)
    root = _fetch_source_tree()
    return _render_source_text(root)


# ---- ios_await_idle (screen-settle detection) -----------------------------------

# Poll cadence for ios_await_idle. Deliberately not tied to _TIMEOUT_* — this is
# the pause BETWEEN reads, not a request timeout.
_IDLE_POLL_S = 0.4


def _idle_fingerprint(root: dict[str, Any]) -> tuple:
    """Cheap per-element signature for settle detection: short type + whichever
    of label/value/identifier is present + frame rounded to ~1% of the screen
    (2 decimal places of the normalized [0,1] coordinate). Reuses I1's element
    walk (_collect_source_elements) so containers that don't carry their own
    info are collapsed the same way ios_source collapses them. Two reads with
    an identical fingerprint mean the visible structure hasn't changed."""
    elements: list[tuple[int, dict[str, Any]]] = []
    _collect_source_elements(root, 0, elements)
    win_w, win_h = _win_size()
    fp = []
    for _, node in elements:
        short = _source_short_type(node.get("type"))
        label = node.get("label") or node.get("value") or node.get("identifier") or ""
        rect = node.get("rect")
        if rect and win_w and win_h:
            x, y, w, h = rect
            cell = (round(x / win_w, 2), round(y / win_h, 2),
                    round(w / win_w, 2), round(h / win_h, 2))
        else:
            cell = None
        fp.append((short, label, cell))
    return tuple(fp)


@mcp.tool()
def ios_await_idle(timeout_s: float = 5.0, min_stable_ms: int = 600) -> str:
    """Block until the screen's accessibility structure stops changing.

    Polls a cheap fingerprint of the compact tree (element type + label/value/
    identifier + frame, rounded to ~1% of the screen) roughly every 400ms.
    "Settled" means the fingerprint held across two-or-more consecutive reads
    spanning at least `min_stable_ms`. Use it after an action that starts a
    transition (navigation, a network load, an animation) instead of a blind
    sleep.

    NEVER raises for a non-settle outcome — it always returns a JSON verdict
    `{"verdict", "elapsed_s", "reads", "stable_ms"}`, where verdict is one of:
      "settled"       — the fingerprint was stable across the whole observed
                        window: either it held for min_stable_ms before
                        timeout_s elapsed, or it simply never changed across
                        every read taken (even if that span fell short of
                        min_stable_ms — a screen that never moved is settled,
                        not "still moving").
      "still-moving"  — the fingerprint actually changed at least once and
                        never re-stabilized before timeout_s elapsed.
      "empty"         — the tree had no elements for the whole window (a blank
                        screen, or a read that isn't returning content).
      "too-few-reads" — timed out before enough reads landed to judge either
                        way (e.g. reads are slow relative to timeout_s).
    A genuine transport failure (WDA unreachable/wedged) still raises out of
    this call — only "didn't settle in time" is swallowed into a verdict.

    Read-only: does not take the gesture lock, so it's safe to call alongside
    other read tools. Each poll is a full compact-tree read (the same heavy
    /source call ios_source makes), so a long timeout_s here means real
    device round-trips — call it deliberately, not in a tight loop.
    """
    start = time.monotonic()
    deadline = start + max(0.0, timeout_s)
    reads = 0
    any_elements_seen = False
    ever_changed = False
    candidate_fp: tuple | None = None
    candidate_ts: float | None = None
    last_ts = start
    while True:
        ts = time.monotonic()
        last_ts = ts
        fp = _idle_fingerprint(_fetch_source_tree())
        reads += 1
        if fp:
            any_elements_seen = True
            if fp != candidate_fp:
                if candidate_fp is not None:
                    # A real change from one non-empty fingerprint to another
                    # (not just the first read establishing a candidate).
                    ever_changed = True
                candidate_fp, candidate_ts = fp, ts
            else:
                stable_ms = (ts - candidate_ts) * 1000.0  # type: ignore[operator]
                if stable_ms >= min_stable_ms:
                    _record("await_idle", f"settled after {reads} read(s)", note="info",
                            verdict={"kind": "idle", "reason": "settled"})
                    return json.dumps({
                        "verdict": "settled", "elapsed_s": round(ts - start, 3),
                        "reads": reads, "stable_ms": round(stable_ms, 1),
                    })
        else:
            candidate_fp, candidate_ts = None, None
        if ts >= deadline:
            break
        time.sleep(_IDLE_POLL_S)
    stable_ms = (last_ts - candidate_ts) * 1000.0 if candidate_ts is not None else 0.0
    if reads < 2:
        verdict = "too-few-reads"
    elif not any_elements_seen:
        verdict = "empty"
    elif not ever_changed:
        # The fingerprint held for the entire observation window — even
        # though the span never reached min_stable_ms, it's still static,
        # not animating. Report the real (shorter) observed stable span.
        verdict = "settled"
    else:
        verdict = "still-moving"
    # Idle verdicts always annotate the run, never fail it (see I8): recorded
    # as an "info" note with the verdict kind fixed at "idle" so the report
    # rollup (which only counts kind=="fail") never trips on a non-settle
    # outcome.
    _record("await_idle", f"{verdict} after {reads} read(s)", note="info",
            verdict={"kind": "idle", "reason": verdict})
    return json.dumps({
        "verdict": verdict, "elapsed_s": round(last_ts - start, 3),
        "reads": reads, "stable_ms": round(stable_ms, 1),
    })


# ---- Control tools -------------------------------------------------------------

@mcp.tool()
@_recorded
def ios_tap(x: float, y: float, settle_ms: int = 0) -> str:
    """Tap the screen at a point, in logical points (see ios_window_size).

    Origin is top-left. Example: center of a 430×932 portrait screen is (215, 466).

    `settle_ms` is an optional fixed pause after the tap, for when a following
    ios_screenshot / ios_source needs a stable frame (e.g. a tap that triggers a
    quick transition animation). It is a blind sleep, not a real settle check —
    to wait until the screen actually stops changing, use ios_await_idle instead.
    """
    _gesture([
        {"type": "pointerMove", "duration": 0, "x": x, "y": y},
        {"type": "pointerDown", "button": 0},
        {"type": "pause", "duration": 40},
        {"type": "pointerUp", "button": 0},
    ])
    if settle_ms > 0:
        time.sleep(settle_ms / 1000.0)
    _record("tap", f"({x}, {y})")
    return f"tapped ({x}, {y})"


@mcp.tool()
@_recorded
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
@_recorded
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
@_recorded
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
    any_clean = False
    last_timeout_err: MCPToolError | None = None
    for n in range(cap + 1):
        eid, err = _find_element_or_timeout(text)
        if err is not None:
            last_timeout_err = err
        else:
            any_clean = True
            if eid:
                _record("scroll_to", f"'{text}' {direction}: found after {n} swipe(s)")
                return json.dumps({"found": True, "swipes": n})
        if n == cap:
            break
        _scroll_once(direction, distance_pct, 50, 50, 300)
        time.sleep(settle_ms / 1000.0)
    if last_timeout_err is not None and not any_clean:
        raise last_timeout_err  # WDA was wedged for the whole search — say so
    # The @_recorded decorator logs the fail step (with a structured verdict)
    # when this raises, so the report's pass/fail rollup sees it without a
    # manual note here.
    raise MCPToolError(f"Element '{text}' not found after {cap} swipes ({direction}).",
                        kind=ErrorKind.NOT_FOUND)


@mcp.tool()
@_recorded
def ios_type(text: str) -> str:
    """Type text into the currently focused field. Tap a text field first.

    Special characters: use "\\n" for return, "\\b" (U+0008) for backspace.
    """
    _session_post("/wda/keys", {"value": list(text)})
    _record("type", repr(text))
    return f"typed {len(text)} char(s)"


@mcp.tool()
@_recorded
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
            raise MCPToolError(f"WDA error (HTTP {code}) pressing home: {j}",
                                kind=ErrorKind.WDA_HTTP, code=f"WDA_HTTP_{code}")
    else:
        _session_post("/wda/pressButton", {"name": name})
    _record("press_button", name)
    return f"pressed {name}"


@mcp.tool()
@_recorded
def ios_find_and_tap(text: str, retries: int = 0, retry_delay_s: float = 0.5) -> str:
    """Find an on-screen element by its visible label/name and tap it.

    Convenience for tapping by text instead of pixel coordinates (e.g. a button
    titled "Settings"). `retries` re-attempts the find (with `retry_delay_s`
    between) to absorb a slow-appearing element; default 0 keeps single-shot
    behavior. Fails with a clear message if no matching element is found — fall
    back to ios_source to inspect, or ios_tap with coordinates.
    """
    attempt = 0
    any_clean = False
    last_timeout_err: MCPToolError | None = None
    while True:
        eid, err = _find_element_or_timeout(text)
        if err is not None:
            last_timeout_err = err
        else:
            any_clean = True
            if eid:
                # The click leg goes through _session_post so a stale-session 404 retries
                # and a WDA error raises — returning "tapped" on a failed click would mislead.
                _session_post(f"/element/{eid}/click", {})
                _record("find_and_tap", text)
                return f"tapped element '{text}'"
        if attempt >= retries:
            if last_timeout_err is not None and not any_clean:
                raise last_timeout_err  # WDA was wedged for every attempt — say so
            raise RuntimeError(f"No element matching '{text}'. Use ios_source to inspect.")
        attempt += 1
        time.sleep(retry_delay_s)


@mcp.tool()
@_recorded
def ios_wait_for(text: str, timeout_s: float = 10.0) -> str:
    """Wait until an element with the given visible label/name/value appears.

    Polls the screen until a matching element is VISIBLE (not just present in
    the tree) or `timeout_s` elapses, matching the first hit in reading order.
    Use after an action that triggers a transition (navigation, a network load)
    so later taps don't race the UI. Raises if the element never appears in
    time — the error message appends a compact-tree snapshot of what was
    actually on screen (first ~10 lines) so a loose selector is debuggable
    without a follow-up ios_source call.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    any_clean = False
    last_timeout_err: MCPToolError | None = None
    while True:
        attempts += 1
        eid, err = _find_element_or_timeout(text, visible_only=True)
        if err is not None:
            last_timeout_err = err
        else:
            any_clean = True
            if eid:
                _record("wait_for", f"'{text}' (found after {attempts} check(s))")
                return f"found '{text}' after {attempts} check(s)"
        if time.monotonic() >= deadline:
            if last_timeout_err is not None and not any_clean:
                raise last_timeout_err  # WDA was wedged for every attempt — say so
            raise MCPToolError(
                f"'{text}' did not appear within {timeout_s}s.\n"
                f"{_wait_for_timeout_snapshot()}", kind=ErrorKind.NOT_FOUND)
        time.sleep(0.5)


def _wait_for_timeout_snapshot() -> str:
    """Best-effort compact-tree snapshot for a timed-out ios_wait_for, so the
    failure message quotes what was actually on screen instead of just "not
    found". One extra heavy /source read, only ever taken on this failure
    path — never on the polling hot path. If even this read fails (the same
    wedged WDA that likely caused the timeout), fall back to the old plain
    message rather than raising a different error."""
    try:
        root = _fetch_source_tree()
        lines = _render_source_text(root).splitlines()[:10]
        return "Current screen (first 10 lines):\n" + "\n".join(lines)
    except Exception as e:
        return f"(could not read current screen: {e})"


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


def _simctl_pbcopy(text: str) -> None:
    """Set the simulator's clipboard via `simctl pbcopy booted`. Simulator-only,
    session-free, and free of WDA's foreground caveat. Raises RuntimeError when
    the current target isn't a simulator, when `xcrun` is missing, or when
    simctl exits non-zero (surfacing its stderr); callers should fall back
    to WDA."""
    if not _IS_SIM:
        raise RuntimeError("simctl tools require IMIRROR_TARGET=simulator.")
    try:
        r = subprocess.run(["xcrun", "simctl", "pbcopy", "booted"],
                           input=text.encode(), capture_output=True, text=False)
    except FileNotFoundError as e:
        raise RuntimeError("`xcrun` not found — install the Xcode command-line tools.") from e
    if r.returncode != 0:
        stderr = (r.stderr or b"").decode("utf-8", "replace").strip()
        raise RuntimeError(f"simctl pbcopy failed: {stderr or r.returncode}")


@mcp.tool()
def ios_clipboard_set(text: str) -> str:
    """Set the device clipboard to `text`.

    On the simulator, the clipboard is set via `simctl pbcopy` (session-free,
    no WDA-foreground caveat), falling back to WDA if simctl is unavailable or
    fails. On a physical device, iOS grants pasteboard access only while
    WebDriverAgent is foreground; with another app in front this may be
    ignored — call after a WDA-owned screen or expect a no-op.
    """
    if _IS_SIM:
        try:
            _simctl_pbcopy(text)
            _record("clipboard_set", repr(text))
            return f"set clipboard ({len(text)} chars)"
        except (RuntimeError, OSError):
            # Deliberate graceful degradation to WDA, not swallowing a real
            # error — the sim path never regresses below "as reliable as
            # before this fast path existed."
            pass
    b64 = base64.b64encode(text.encode()).decode()
    _session_post("/wda/setPasteboard", {"content": b64, "contentType": "plaintext"})
    _record("clipboard_set", repr(text))
    return f"set clipboard ({len(text)} chars)"


@mcp.tool()
def ios_clipboard_get() -> str:
    """Read the device clipboard (plaintext).

    On the simulator, the clipboard is read via `simctl pbpaste` (session-free,
    no WDA-foreground caveat), falling back to WDA if simctl is unavailable or
    fails. On a physical device, the same foreground caveat as
    ios_clipboard_set applies.
    """
    if _IS_SIM:
        try:
            # strip=False: pbpaste's stdout IS the clipboard content verbatim —
            # trailing newlines, indentation, and other meaningful whitespace
            # must round-trip unchanged (unlike UDID/device-list callers, where
            # _simctl's default strip=True is correct).
            text = _simctl("pbpaste", "booted", strip=False)
            _record("clipboard_get", f"{len(text)} chars")
            return text
        except (RuntimeError, OSError):
            # Deliberate graceful degradation to WDA — see ios_clipboard_set.
            pass
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

def _simctl(*args: str, strip: bool = True) -> str:
    """Run `xcrun simctl <args>` and return stdout. Simulator-only.

    Raises a clear error when the current target isn't a simulator, when `xcrun`
    is missing, or when simctl exits non-zero (surfacing its stderr).

    `strip` defaults to True (matching every existing caller — UDIDs, device
    lists, and other structured output where surrounding whitespace is noise).
    Pass `strip=False` for output where whitespace is meaningful, e.g.
    clipboard content read via `pbpaste`.
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
    out = r.stdout or ""
    return out.strip() if strip else out


def _start_sim_recording(run_dir: str) -> None:
    """Best-effort: start `xcrun simctl io booted recordVideo` for this run.

    Records into recording.mp4 inside `run_dir` until _stop_sim_recording sends
    SIGINT. Simulator-only, and never allowed to fail the run: xcrun missing,
    a simulator that rejects the command, or any other error just leaves the
    run without a recording (ios_finish_run then falls back to the ffmpeg
    timelapse) rather than raising.
    """
    path = os.path.join(run_dir, "recording.mp4")
    with _recorder_lock:
        try:
            proc = subprocess.Popen(
                ["xcrun", "simctl", "io", "booted", "recordVideo",
                 "--codec=h264", "--force", path],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                # DEVNULL, not PIPE: nothing ever reads this pipe, and a long
                # run can fill the ~64KB stderr buffer and block the child,
                # stalling the recording.
                stderr=subprocess.DEVNULL)
        except Exception:
            _run["recorder"] = None
            _run["recording"] = None
            return
        _run["recorder"] = proc
        _run["recording"] = path


def _stop_sim_recording() -> tuple[str | None, str]:
    """Stop any in-flight simulator recording started by _start_sim_recording.

    `recordVideo` only finalizes its mp4 on SIGINT (a kill leaves a broken
    file), so this signals it and waits up to ~10s; a process that won't die
    in time is killed and the clip is flagged as possibly incomplete.

    Returns (basename, note) — a bare filename like _make_timelapse's clip
    return, since ios_finish_run treats the two interchangeably and
    _render_report embeds the clip as a path relative to report.html in the
    same run directory. (None, "") when no recorder was running; (None,
    reason) when one ran but produced no usable file.
    """
    with _recorder_lock:
        proc = _run.get("recorder")
        path = _run.get("recording")
        if proc is None:
            _run["recorder"] = None
            _run["recording"] = None
            return None, ""
        note = ""
        try:
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            note = "recording stop timed out; clip may be incomplete"
        except Exception:
            pass
        _run["recorder"] = None
        _run["recording"] = None
    if path and os.path.exists(path) and os.path.getsize(path) > 0:
        return os.path.basename(path), note
    return None, note or "recording skipped: no output produced"


# Best-effort cleanup so a server exit (normal exit, sys.exit, an unhandled
# exception, or a client disconnect) between ios_start_run and ios_finish_run
# doesn't leave the recordVideo child running and writing forever. This can
# only catch orderly interpreter shutdown — a hard SIGKILL of the server
# process still leaves the recorder orphaned, same as any other atexit hook.
atexit.register(_stop_sim_recording)


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
    # Hold the recorder lock across the whole stop -> reset -> start handoff so
    # a concurrent ios_start_run can't interleave and orphan a recorder handle
    # (one thread's reset overwriting another's just-set recorder with no
    # reference left to kill it). A replaced run must not leak the previous
    # run's recorder process, so stop it (discarding the clip) before
    # resetting state for the new run.
    with _recorder_lock:
        _stop_sim_recording()
        _run.update(active=True, dir=run_dir, label=label, started=time.time(),
                    device=device, ios=ios_ver, steps=[], cap_noted=False,
                    recorder=None, recording=None)
        if _IS_SIM:
            # Best-effort: a failed recorder start must never fail the run or
            # change what's returned here (see _start_sim_recording).
            _start_sim_recording(run_dir)
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
        raise MCPToolError("status must be one of info / pass / fail",
                            kind=ErrorKind.VALIDATION)
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

    `video` controls the clip shown at the top of the report: "gif" (default),
    "mp4", or "none". On the simulator this is a real continuous screen
    recording captured via `xcrun simctl io recordVideo` while the run was
    active; if that recording is missing (e.g. xcrun unavailable), it falls
    back to stitching the run's screenshots into a timelapse with ffmpeg, same
    as on a physical device. The timelapse fallback needs ffmpeg on PATH and
    at least two screenshots; if either is missing the report is still
    written, with a note that the clip was skipped. The clip is saved beside
    report.html (so a video-bearing report is a folder, not a single file);
    screenshots stay embedded in the HTML regardless.
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
        if _IS_SIM:
            # Always stop the recorder (even for video="none") so it doesn't
            # keep running past the end of the run.
            rec_clip, rec_note = _stop_sim_recording()
            if video == "none":
                clip, clip_note = None, ""
            elif rec_clip is not None:
                clip, clip_note = rec_clip, (rec_note or "screen recording (simulator)")
            else:
                clip, clip_note = _make_timelapse(video)
        else:
            clip, clip_note = _make_timelapse(video)
        path = os.path.join(_run["dir"], "report.html")
        with open(path, "w", encoding="utf-8") as f:
            f.write(_render_report(ended=time.time(), clip=clip, clip_note=clip_note))
    finally:
        _run["active"] = False
    return path


@mcp.tool()
@_recorded
def ios_assert_visible(text: str, timeout_s: float = 5.0) -> str:
    """Assert an element with the given visible label/name/value is present.

    Polls up to `timeout_s`. Records a PASS note on success; on timeout the
    @_recorded decorator logs the fail step (with a structured verdict) when
    this raises. Raises on failure.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    any_clean = False
    last_timeout_err: MCPToolError | None = None
    while True:
        attempts += 1
        eid, err = _find_element_or_timeout(text)
        if err is not None:
            last_timeout_err = err
        else:
            any_clean = True
            if eid:
                _record("note", f"assert visible '{text}' (after {attempts} check(s))", note="pass")
                return f"PASS: '{text}' is visible"
        if time.monotonic() >= deadline:
            if last_timeout_err is not None and not any_clean:
                raise last_timeout_err  # WDA was wedged for every attempt — say so
            raise MCPToolError(f"ASSERT FAILED: '{text}' not visible within {timeout_s}s.",
                                kind=ErrorKind.NOT_FOUND)
        time.sleep(0.5)


@mcp.tool()
@_recorded
def ios_assert_not_visible(text: str, timeout_s: float = 3.0) -> str:
    """Assert an element with the given text is ABSENT (waits until it's gone).

    Polls up to `timeout_s` for the element to disappear. Records a PASS note
    on success; on timeout the @_recorded decorator logs the fail step (with
    a structured verdict) when this raises. Raises on failure.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    attempts = 0
    any_clean = False
    last_timeout_err: MCPToolError | None = None
    while True:
        attempts += 1
        eid, err = _find_element_or_timeout(text)
        if err is not None:
            last_timeout_err = err
        else:
            any_clean = True
            if not eid:
                _record("note", f"assert not-visible '{text}' (after {attempts} check(s))", note="pass")
                return f"PASS: '{text}' is not visible"
        if time.monotonic() >= deadline:
            if last_timeout_err is not None and not any_clean:
                raise last_timeout_err  # WDA was wedged for every attempt — say so
            raise MCPToolError(f"ASSERT FAILED: '{text}' still visible after {timeout_s}s.",
                                kind=ErrorKind.NOT_FOUND)
        time.sleep(0.5)


# ---- ios_run_sequence -----------------------------------------------------------

# Allowlisted step actions for ios_run_sequence. Each entry names the existing
# tool it dispatches to, plus the required/optional params it accepts (as
# type tuples for a basic isinstance check). The callable is a lambda that
# looks `ios_*` up by name at call time (not a direct function reference) so
# monkeypatching the tool function (as tests already do for the single-step
# tools) also takes effect when it runs inside a sequence.
_SEQ_ACTIONS: dict[str, dict[str, Any]] = {
    "tap": {
        "fn": lambda **kw: ios_tap(**kw),
        "required": {"x": (int, float), "y": (int, float)},
        "optional": {"settle_ms": (int,)},
    },
    "swipe": {
        "fn": lambda **kw: ios_swipe(**kw),
        "required": {"from_x": (int, float), "from_y": (int, float),
                     "to_x": (int, float), "to_y": (int, float)},
        "optional": {"duration_ms": (int,), "settle_ms": (int,)},
    },
    "scroll": {
        "fn": lambda **kw: ios_scroll(**kw),
        "required": {"direction": (str,)},
        "optional": {"distance_pct": (int, float), "x_pct": (int, float),
                     "y_pct": (int, float), "settle_ms": (int,)},
    },
    "scroll_to": {
        "fn": lambda **kw: ios_scroll_to(**kw),
        "required": {"text": (str,)},
        "optional": {"direction": (str,), "max_swipes": (int,),
                     "distance_pct": (int, float), "settle_ms": (int,)},
    },
    "type": {
        "fn": lambda **kw: ios_type(**kw),
        "required": {"text": (str,)},
        "optional": {},
    },
    "press_button": {
        "fn": lambda **kw: ios_press_button(**kw),
        "required": {},
        "optional": {"name": (str,)},
    },
    "find_and_tap": {
        "fn": lambda **kw: ios_find_and_tap(**kw),
        "required": {"text": (str,)},
        "optional": {"retries": (int,), "retry_delay_s": (int, float)},
    },
    "wait_for": {
        "fn": lambda **kw: ios_wait_for(**kw),
        "required": {"text": (str,)},
        "optional": {"timeout_s": (int, float)},
    },
    "assert_visible": {
        "fn": lambda **kw: ios_assert_visible(**kw),
        "required": {"text": (str,)},
        "optional": {"timeout_s": (int, float)},
    },
    "assert_not_visible": {
        "fn": lambda **kw: ios_assert_not_visible(**kw),
        "required": {"text": (str,)},
        "optional": {"timeout_s": (int, float)},
    },
}


def _validate_seq_step(i: int, step: Any) -> None:
    """Raise RuntimeError naming step `i` (1-based) if it isn't a well-formed
    sequence step. Checks: step is an object, action is allowlisted, every
    required param is present with a plausible type, every optional param
    present has a plausible type, and no unexpected params are carried."""
    if not isinstance(step, dict):
        raise MCPToolError(f"step {i}: expected an object, got {type(step).__name__}",
                            kind=ErrorKind.VALIDATION)
    action = step.get("action")
    if action not in _SEQ_ACTIONS:
        raise MCPToolError(
            f"step {i}: unknown action {action!r} (allowed: {sorted(_SEQ_ACTIONS)})",
            kind=ErrorKind.VALIDATION)
    spec = _SEQ_ACTIONS[action]
    for name, types in spec["required"].items():
        if name not in step:
            raise MCPToolError(f"step {i} ({action}): missing required param '{name}'",
                                kind=ErrorKind.VALIDATION)
        if not isinstance(step[name], types):
            raise MCPToolError(
                f"step {i} ({action}): param '{name}' must be {types}, "
                f"got {type(step[name]).__name__}", kind=ErrorKind.VALIDATION)
    for name, types in spec["optional"].items():
        if name in step and not isinstance(step[name], types):
            raise MCPToolError(
                f"step {i} ({action}): param '{name}' must be {types}, "
                f"got {type(step[name]).__name__}", kind=ErrorKind.VALIDATION)
    allowed_params = set(spec["required"]) | set(spec["optional"])
    extra = set(step) - allowed_params - {"action"}
    if extra:
        raise MCPToolError(f"step {i} ({action}): unexpected param(s) {sorted(extra)}",
                            kind=ErrorKind.VALIDATION)


@mcp.tool()
@_recorded
def ios_run_sequence(steps: list[dict]) -> str:
    """Run a batch of interaction steps in one call, stopping at the first failure.

    Each step is an object `{"action": <name>, ...params}`. Allowed actions:
    tap (x, y); swipe (from_x, from_y, to_x, to_y, optional duration_ms/
    settle_ms); scroll (direction, optional distance_pct/x_pct/y_pct/
    settle_ms); scroll_to (text, optional direction/max_swipes/distance_pct/
    settle_ms); type (text); press_button (optional name); find_and_tap (text,
    optional retries/retry_delay_s); wait_for (text, optional timeout_s);
    assert_visible (text, optional timeout_s); assert_not_visible (text,
    optional timeout_s). Each action dispatches straight to the matching
    ios_* tool, so a step behaves exactly like calling that tool on its own —
    including its own recording when a run is active. This tool never records
    or screenshots on top of that; it only reports the per-step outcome.

    ALL steps are validated (unknown action, missing or mistyped params,
    unexpected params) before step 1 runs. If any step is invalid, this
    raises naming the offending step (1-based) and no step is executed — a
    typo in step 5 must not leave the device mid-flow. Once running, a step
    that raises (a failed wait_for/assert_*, or any tool error) stops the
    sequence; later steps are not run.

    Returns a JSON string: {"ok", "ran", "total", "steps": [{"i", "action",
    "status": "pass"|"fail", "detail" (on pass) | "error" (on fail)}, ...]}.
    `ok` is true only if every step ran and passed.

    NOT atomic across concurrent agents: only individual gestures are
    serialized (via the existing per-gesture lock), not the sequence as a
    whole, so a multi-second wait_for/assert_* inside it can interleave with
    another agent's action between steps. This is meant for single-agent
    scripted flows, not for holding the device off-limits to others while it
    runs.
    """
    if not isinstance(steps, list) or not steps:
        raise MCPToolError("steps must be a non-empty list", kind=ErrorKind.VALIDATION)
    for i, step in enumerate(steps, start=1):
        _validate_seq_step(i, step)

    results: list[dict[str, Any]] = []
    ok = True
    ran = 0
    for i, step in enumerate(steps, start=1):
        action = step["action"]
        kwargs = {k: v for k, v in step.items() if k != "action"}
        ran = i
        try:
            detail = _SEQ_ACTIONS[action]["fn"](**kwargs)
            results.append({"i": i, "action": action, "status": "pass", "detail": detail})
        except Exception as e:
            results.append({"i": i, "action": action, "status": "fail", "error": str(e)})
            ok = False
            break
    return json.dumps({"ok": ok, "ran": ran, "total": len(steps), "steps": results})


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
    verdict_html = ""
    v = s.get("verdict")
    if v:
        kind = v.get("kind", "")
        if not badge:
            cls = {"fail": "bad", "pass": "ok"}.get(kind, "info")
            badge = f'<span class="badge {cls}">{html.escape(str(kind))}</span>'
        parts = []
        reason = v.get("reason")
        if reason:
            parts.append(html.escape(str(reason)))
        if v.get("error_kind"):
            parts.append(f"error_kind={html.escape(str(v['error_kind']))}")
        if v.get("error_code"):
            parts.append(f"error_code={html.escape(str(v['error_code']))}")
        if parts:
            verdict_html = f'<div class="verdict">{" · ".join(parts)}</div>'
    img = _screenshot_img(s["screenshot"], f'step {s["i"]}') if s["screenshot"] else ""
    return (
        f'<div class="step" id="step-{s["i"]}">'
        f'<div class="meta"><span class="i">#{s["i"]}</span>'
        f'<span class="act">{html.escape(s["action"])}</span>'
        f'<span class="off">+{off:.1f}s</span>{badge}</div>'
        f'<div class="detail">{html.escape(s["detail"])}</div>{verdict_html}{img}</div>'
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
        elif _step_is_fail(s):
            cur["fails"] += 1
    return sections


def _render_report(ended: float, clip: str | None = None, clip_note: str = "") -> str:
    steps = _run["steps"]
    started = _run["started"] or ended
    # Rollup semantics (I8): counts a legacy note="fail" step AND a step with a
    # structured fail verdict (auto-recorded by @_recorded on a raise). This is
    # an intentional, non-backward-compatible change to the rollup — a report
    # that previously showed PASS because a raised failure went unrecorded now
    # shows FAIL. An "idle" verdict from ios_await_idle never counts here.
    fails = sum(1 for s in steps if _step_is_fail(s))
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
                if _step_is_fail(s):
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
  .verdict { margin:0 0 6px; color:var(--muted); font-size:12px; word-break:break-word; }
  .shot { margin-top:8px; max-width:100%; border-radius:8px; border:1px solid #0002;
          display:block; }
  .missing { color:var(--bad); font-size:13px; }
  .clip { display:block; width:100%; max-width:480px; margin:16px auto 0;
          border-radius:10px; border:1px solid #0002; }
  .clip-note { color:var(--muted); font-size:13px; font-style:italic; }
"""


if __name__ == "__main__":
    mcp.run()
