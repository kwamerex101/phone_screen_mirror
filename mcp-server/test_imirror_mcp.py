"""Unit tests for imirror_mcp.

No real device or WebDriverAgent needed: every test stubs the HTTP layer
(`_req`) so we exercise the server's own logic — session handling, retry on
stale 404, predicate building, gesture payloads, wait/poll, and the loopback
guard — in isolation.
"""
from __future__ import annotations

import importlib
import json
import os
import sys

import pytest


@pytest.fixture()
def mod(monkeypatch):
    """Import a fresh copy of the module with a clean session, on a loopback target."""
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.delenv("IMIRROR_TARGET", raising=False)  # default (device) mode
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    m._session["id"] = None
    return m


class FakeWDA:
    """Records requests and replies from a scripted (status, body) queue per route key."""

    def __init__(self):
        self.calls: list[tuple[str, str, dict | None]] = []
        self.timeouts: list[float | None] = []
        self.replies: dict[str, list[tuple[int, dict]]] = {}
        self.allowed: set[str] = set()

    def script(self, key: str, *responses: tuple[int, dict]):
        self.replies[key] = list(responses)

    def allow(self, *suffixes: str):
        """Let these route suffixes default-succeed (200, empty) without scripting.
        Explicit opt-in keeps unscripted-route failures loud everywhere else."""
        self.allowed.update(suffixes)

    def __call__(self, method, path, body=None, timeout=None):
        self.calls.append((method, path, body))
        self.timeouts.append(timeout)
        # Match by exact path, then by suffix (".../actions", ".../window/size").
        # No loose substring match: that let "/session" shadow both
        # "/session/s/actions" and the "/session/s/appium/settings" call that
        # _ensure_session now fires, consuming the wrong scripted reply.
        for match in (lambda k: k == path, path.endswith):
            for key in sorted(self.replies, key=len, reverse=True):
                if self.replies[key] and match(key):
                    return self.replies[key].pop(0)
        # _ensure_session always fires this boilerplate; succeed it by default.
        if path.endswith("/appium/settings"):
            return 200, {"value": {}}
        if any(path.endswith(s) for s in self.allowed):
            return 200, {"value": {}}
        # Anything else unscripted is a test bug or a silently renamed route —
        # fail loudly instead of returning a fake success.
        raise AssertionError(f"FakeWDA: unscripted call {method} {path}")


@pytest.fixture()
def wda(mod, monkeypatch):
    fake = FakeWDA()
    monkeypatch.setattr(mod, "_req", fake)
    return fake


@pytest.fixture()
def sim_mod(monkeypatch):
    """A fresh module imported in simulator mode (IMIRROR_TARGET=simulator)."""
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.setenv("IMIRROR_TARGET", "simulator")
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    m._session["id"] = None
    return m


# ---- loopback guard ------------------------------------------------------------

@pytest.mark.parametrize("target", [
    "http://10.0.0.5:8100",
    "https://example.com",
    "http://evil.localhost.attacker.com",
    # suffix-abuse: these pass a naive startswith() prefix check but resolve off-box
    "http://127.0.0.1.attacker.example:8100",
    "http://localhost.attacker.example:8100",
    "https://127.0.0.1:8100",              # non-http scheme to a loopback host
])
def test_refuses_non_loopback_target(monkeypatch, target):
    monkeypatch.setenv("IMIRROR_WDA", target)
    sys.modules.pop("imirror_mcp", None)
    with pytest.raises(SystemExit):
        importlib.import_module("imirror_mcp")


@pytest.mark.parametrize("target", [
    "http://127.0.0.1:8100",
    "http://localhost:8100",
    "http://127.0.0.2:9100",               # anywhere in 127.0.0.0/8 is loopback
    "http://[::1]:8100",                    # IPv6 loopback
])
def test_accepts_loopback_target(monkeypatch, target):
    monkeypatch.setenv("IMIRROR_WDA", target)
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")   # must not raise
    assert m._is_loopback_url(target)


# ---- HTTP wire layer (_req over the _http seam) --------------------------------

def test_req_parses_json_body(mod, monkeypatch):
    monkeypatch.setattr(mod, "_http", lambda *a: (200, b'{"value": 42}'))
    assert mod._req("GET", "/status") == (200, {"value": 42})


def test_req_returns_error_code_and_body(mod, monkeypatch):
    """4xx/5xx come back as a normal response (not an exception) so callers like
    _session_post can see the code and recreate a stale session."""
    monkeypatch.setattr(mod, "_http", lambda *a: (404, b'{"value": "no session"}'))
    assert mod._req("POST", "/session/s/actions", {}) == (404, {"value": "no session"})


def test_req_wraps_non_json_error_body(mod, monkeypatch):
    monkeypatch.setattr(mod, "_http", lambda *a: (500, b"Internal Error"))
    code, j = mod._req("GET", "/x")
    assert code == 500 and j["error"] == "Internal Error"


def test_req_retries_transient_drop_then_succeeds(mod, monkeypatch):
    import http.client
    calls = {"n": 0}

    def flaky(method, path, data, timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            raise http.client.RemoteDisconnected("boom")
        return 200, b'{"ok": true}'

    monkeypatch.setattr(mod, "_http", flaky)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    assert mod._req("GET", "/status") == (200, {"ok": True})
    assert calls["n"] == 2


def test_req_timeout_gives_actionable_error(mod, monkeypatch):
    import socket

    def slow(*a):
        raise socket.timeout("timed out")

    monkeypatch.setattr(mod, "_http", slow)
    with pytest.raises(RuntimeError, match="timed out"):
        mod._req("GET", "/source", timeout=1)


def test_req_unreachable_gives_actionable_error(mod, monkeypatch):
    def refused(*a):
        raise ConnectionRefusedError("nope")

    monkeypatch.setattr(mod, "_http", refused)
    with pytest.raises(RuntimeError, match="Cannot reach WDA"):
        mod._req("GET", "/status")


# ---- timeout tiers and _req_tree ride-out ---------------------------------

def _timeout_runtime_error(path: str) -> RuntimeError:
    """Build the same shape of RuntimeError _req raises on a real socket
    timeout: chained (`raise ... from e`) to the underlying socket.timeout, so
    `err.__cause__` is a socket.timeout — exactly what _req_tree inspects to
    tell a timeout apart from a connection-drop RuntimeError."""
    import socket
    err = RuntimeError(f"WDA timed out after 60s on {path}. It may be busy or wedged.")
    err.__cause__ = socket.timeout("timed out")
    return err


def test_timeout_tier_constants(mod):
    """Tiers are ordered PROBE < INTERACT < TREE, and TREE stays at 60 (the
    amendment's 30s cap was deliberately not adopted — see the plan)."""
    assert mod._TIMEOUT_PROBE < mod._TIMEOUT_INTERACT < mod._TIMEOUT_TREE
    assert mod._TIMEOUT_TREE == 60


def test_req_tree_uses_the_tree_tier(mod, monkeypatch):
    calls = []
    monkeypatch.setattr(mod, "_req",
                        lambda method, path, body=None, timeout=None: calls.append(timeout) or
                        (200, {"value": "<XCUIElementTypeApplication/>"}))
    mod._req_tree("/source")
    assert calls == [mod._TIMEOUT_TREE]


def test_req_tree_rides_out_a_stall_then_succeeds(mod, monkeypatch):
    """First /source read times out, but a cheap /status probe answers — the
    queue cleared, so _req_tree retries the tree read once more and returns
    its result. Exactly one probe and two tree reads should happen."""
    calls = []
    source_attempts = {"n": 0}

    def fake_req(method, path, body=None, timeout=None):
        calls.append((method, path, timeout))
        if path == "/source":
            source_attempts["n"] += 1
            if source_attempts["n"] == 1:
                raise _timeout_runtime_error(path)
            return 200, {"value": "<XCUIElementTypeApplication/>"}
        if path == "/status":
            return 200, {"value": {}}
        raise AssertionError(f"unexpected call {method} {path}")

    monkeypatch.setattr(mod, "_req", fake_req)
    code, j = mod._req_tree("/source")
    assert (code, j) == (200, {"value": "<XCUIElementTypeApplication/>"})
    source_calls = [c for c in calls if c[1] == "/source"]
    probe_calls = [c for c in calls if c[1] == "/status"]
    assert len(source_calls) == 2
    assert len(probe_calls) == 1
    assert probe_calls[0][2] == mod._TIMEOUT_PROBE


def test_req_tree_fails_fast_when_probe_also_times_out(mod, monkeypatch):
    """If the /status probe also fails to answer, WDA is still stalled — fail
    fast with the original wedged error instead of piling on a second read."""
    calls = []

    def fake_req(method, path, body=None, timeout=None):
        calls.append((method, path, timeout))
        raise _timeout_runtime_error(path)

    monkeypatch.setattr(mod, "_req", fake_req)
    with pytest.raises(RuntimeError, match="timed out"):
        mod._req_tree("/source")
    source_calls = [c for c in calls if c[1] == "/source"]
    probe_calls = [c for c in calls if c[1] == "/status"]
    assert len(source_calls) == 1  # no second tree read attempted
    assert len(probe_calls) == 1


def test_req_tree_does_not_retry_on_connection_drop_error(mod, monkeypatch):
    """A RuntimeError from _req's own connection-drop exhaustion (not a
    timeout) must not trigger the probe-and-retry dance — just propagate."""
    calls = []

    def fake_req(method, path, body=None, timeout=None):
        calls.append((method, path))
        raise RuntimeError(f"WDA dropped the connection repeatedly on {path} (boom).")

    monkeypatch.setattr(mod, "_req", fake_req)
    with pytest.raises(RuntimeError, match="dropped the connection"):
        mod._req_tree("/source")
    assert calls == [("GET", "/source")]  # no probe attempted


def test_http_reconnects_after_failure(mod, monkeypatch):
    """A connection-level error must poison the cached connection so the next
    call builds a fresh one rather than reusing a half-closed socket."""
    class FakeConn:
        instances: list = []

        def __init__(self, *a, **k):
            self.closed = False
            self.timeout = None
            FakeConn.instances.append(self)

        def request(self, *a, **k):
            if len(FakeConn.instances) == 1:
                raise ConnectionResetError("reset")

        def getresponse(self):
            class R:
                status = 200
                def read(self_inner): return b"{}"
            return R()

        def close(self):
            self.closed = True

    monkeypatch.setattr(mod.http.client, "HTTPConnection", FakeConn)
    mod._drop_conn()
    with pytest.raises(ConnectionResetError):
        mod._http("GET", "/x", None, 5)
    assert FakeConn.instances[0].closed and getattr(mod._conn_local, "c", None) is None
    # next call transparently opens a new connection and succeeds
    assert mod._http("GET", "/x", None, 5) == (200, b"{}")
    assert len(FakeConn.instances) == 2
    mod._drop_conn()


# ---- session lifecycle ---------------------------------------------------------

def test_ensure_session_creates_once(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "abc"}}))
    assert mod._ensure_session() == "abc"
    assert mod._ensure_session() == "abc"  # cached, no second create
    assert sum(1 for m, p, _ in wda.calls if p == "/session") == 1


def test_session_post_recreates_on_stale_404(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s1"}}),
               (200, {"value": {"sessionId": "s2"}}))
    wda.script("/actions", (404, {"value": "no session"}), (200, {"value": {}}))
    mod._session_post("/actions", {"actions": []})
    # session got cleared and recreated, and the new id is cached
    assert mod._session["id"] == "s2"


def test_session_post_raises_on_hard_error(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s1"}}))
    wda.script("/actions", (500, {"value": "boom"}))
    with pytest.raises(RuntimeError, match="HTTP 500"):
        mod._session_post("/actions", {})


# ---- read-only tools -----------------------------------------------------------

def test_status_summarizes(mod, wda):
    import json
    wda.script("/status", (200, {"value": {
        "ready": True, "message": "ok",
        "os": {"version": "17.4"}, "device": "iPhone"}}))
    out = json.loads(mod.ios_status())
    assert out == {"ready": True, "message": "ok", "ios": "17.4", "device": "iPhone",
                   "server_version": mod.__version__}


def test_source_xml_format_truncates_large_output(mod, wda):
    """format="xml" preserves the original raw-string + 20,000-char truncation
    behavior exactly, with no JSON probe, no element cap, no normalization."""
    wda.script("/source", (200, {"value": "x" * 25000}))
    out = mod.ios_source(format="xml")
    assert out.endswith("… (truncated)")
    assert len(out) < 25000
    assert not any(p == "/source?format=json" for _, p, _ in wda.calls)


def test_source_xml_format_uses_long_timeout(mod, wda):
    """A heavy accessibility tree can take >15s; ios_source must not use the
    default short timeout (regression: real device timed out at 15s)."""
    wda.script("/source", (200, {"value": "<XCUIElementTypeApplication/>"}))
    mod.ios_source(format="xml")
    src_idx = next(i for i, (_, p, _) in enumerate(wda.calls) if p == "/source")
    assert wda.timeouts[src_idx] is not None and wda.timeouts[src_idx] >= 60


def test_source_rejects_unknown_format(mod, wda):
    with pytest.raises(RuntimeError, match="format must be"):
        mod.ios_source(format="yaml")


# ---- ios_source text mode (compact accessibility tree, the new default) --------

_SIMPLE_XML_TREE = (
    '<XCUIElementTypeApplication name="App">'
    '<XCUIElementTypeWindow x="0" y="0" width="400" height="800">'
    '<XCUIElementTypeNavigationBar name="Nav">'
    '<XCUIElementTypeStaticText label="Screen Title" x="10" y="20" width="100" height="30"/>'
    '</XCUIElementTypeNavigationBar>'
    '<XCUIElementTypeButton label="Login" enabled="true" visible="true" hittable="true" '
    'x="50" y="700" width="120" height="40"/>'
    '<XCUIElementTypeOther x="0" y="0" width="400" height="800">'
    '<XCUIElementTypeStaticText label="" x="0" y="0" width="0" height="0"/>'
    '</XCUIElementTypeOther>'
    '</XCUIElementTypeWindow>'
    '</XCUIElementTypeApplication>'
)


def test_source_text_xml_fallback_renders_tree(mod, wda, monkeypatch):
    """No JSON support on this WDA build (non-dict `value`): falls back to
    parsing the XML form, collapses the empty container, keeps content
    elements, and shows depth via indentation."""
    monkeypatch.setattr(mod, "_win_size", lambda: (400.0, 800.0))
    wda.script("/source?format=json", (200, {"value": "not json, unsupported"}))
    wda.script("/source", (200, {"value": _SIMPLE_XML_TREE}))
    out = mod.ios_source()

    lines = out.splitlines()
    assert lines[0].startswith("# tap point = (x + w/2, y + h/2)")
    assert 'label="Screen Title"' in out
    assert 'label="Login"' in out
    # The empty Other container is collapsed away...
    assert not any(line.strip().startswith("Other") for line in lines)
    # ...but its StaticText child (a content role, even with an empty label)
    # still renders.
    assert sum(1 for line in lines if "StaticText" in line) == 2
    # Depth indentation: the NavigationBar's StaticText (depth 2) is indented
    # more than the top-level Button (depth 1).
    title_line = next(l for l in lines if "Screen Title" in l)
    button_line = next(l for l in lines if "Login" in l)
    indent = lambda l: len(l) - len(l.lstrip(" "))
    assert indent(title_line) > indent(button_line)
    # Both JSON probe and XML fallback were actually attempted, in that order.
    paths = [p for _, p, _ in wda.calls if p.startswith("/source")]
    assert paths == ["/source?format=json", "/source"]


def test_source_text_uses_json_when_supported(mod, wda, monkeypatch):
    """When /source?format=json returns a dict `value`, render it directly —
    no XML fallback call at all."""
    monkeypatch.setattr(mod, "_win_size", lambda: (400.0, 800.0))
    tree = {
        "type": "Application", "children": [
            {"type": "Button", "label": "Continue", "isEnabled": True,
             "isVisible": True, "isHittable": True,
             "rect": {"x": 10, "y": 20, "width": 100, "height": 40}},
        ],
    }
    wda.script("/source?format=json", (200, {"value": tree}))
    out = mod.ios_source()
    assert 'label="Continue"' in out
    assert not any(p == "/source" for _, p, _ in wda.calls)


def test_source_text_normalized_frame_math(mod, wda, monkeypatch):
    """Normalized [0,1] frame is exact against a stubbed window size."""
    monkeypatch.setattr(mod, "_win_size", lambda: (400.0, 800.0))
    tree = {
        "type": "Application", "children": [
            {"type": "Button", "label": "Buy",
             "rect": {"x": 100, "y": 200, "width": 50, "height": 40}},
        ],
    }
    wda.script("/source?format=json", (200, {"value": tree}))
    out = mod.ios_source()
    button_line = next(l for l in out.splitlines() if "Buy" in l)
    assert "norm=(0.250,0.250,0.125,0.050)" in button_line


def test_source_text_caps_by_element_count(mod, wda, monkeypatch):
    """Output is capped by ELEMENT COUNT (400), with a trailing line reporting
    exactly how many elements were dropped — after parsing the FULL tree."""
    monkeypatch.setattr(mod, "_win_size", lambda: (400.0, 800.0))
    n = mod._SOURCE_MAX_ELEMENTS + 50
    tree = {
        "type": "Application",
        "children": [
            {"type": "Button", "label": f"Item {i}",
             "rect": {"x": 0, "y": 0, "width": 10, "height": 10}}
            for i in range(n)
        ],
    }
    wda.script("/source?format=json", (200, {"value": tree}))
    out = mod.ios_source()
    lines = out.splitlines()
    element_lines = [l for l in lines if l.strip().startswith("Button")]
    assert len(element_lines) == mod._SOURCE_MAX_ELEMENTS
    assert lines[-1] == "… (50 elements dropped; refine with a more specific screen)"


# ---- ios_await_idle (settle detection) ------------------------------------------

def _fake_monotonic(monkeypatch, mod, values):
    """Feed a fixed sequence of time.monotonic() readings (one per call)."""
    it = iter(values)
    monkeypatch.setattr(mod.time, "monotonic", lambda: next(it))


def _norm_button(label: str) -> dict:
    """A single already-normalized Button node (the internal shape
    _fetch_source_tree returns — rect as an (x,y,w,h) tuple, not a raw dict)."""
    return {"type": "Button", "label": label, "name": None, "value": None,
            "identifier": None, "enabled": None, "visible": None, "hittable": None,
            "rect": (0.0, 0.0, 10.0, 10.0), "children": []}


def _button_tree(label: str) -> dict:
    return {"type": "Application", "label": None, "name": None, "value": None,
            "identifier": None, "enabled": None, "visible": None, "hittable": None,
            "rect": None, "children": [_norm_button(label)]}


def test_await_idle_settles_on_unchanging_fingerprint(mod, monkeypatch):
    # start, then one monotonic() read per poll iteration.
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4, 0.8])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    tree = _button_tree("Same")
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: tree)
    out = json.loads(mod.ios_await_idle(timeout_s=5.0, min_stable_ms=600))
    assert out["verdict"] == "settled"
    assert out["reads"] == 3
    assert out["stable_ms"] >= 600


def test_await_idle_records_info_verdict_step_without_failing_run(mod, monkeypatch, tmp_path):
    """During an active run, ios_await_idle logs an "idle" verdict step as
    info, and it must never count toward the fail rollup (I8)."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("idle-check")
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4, 0.8])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    tree = _button_tree("Same")
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: tree)
    out = json.loads(mod.ios_await_idle(timeout_s=5.0, min_stable_ms=600))
    assert out["verdict"] == "settled"
    idle_steps = [s for s in mod._run["steps"] if s["action"] == "await_idle"]
    assert len(idle_steps) == 1
    assert idle_steps[0]["note"] == "info"
    assert idle_steps[0]["verdict"] == {"kind": "idle", "reason": "settled"}
    assert not any(mod._step_is_fail(s) for s in mod._run["steps"])
    report = mod.ios_finish_run(video="none")
    htmltext = open(report, encoding="utf-8").read()
    assert ">PASS<" in htmltext or "0 failures" in htmltext


def test_await_idle_settled_when_static_but_shorter_than_min_stable(mod, monkeypatch):
    """A static screen (fingerprint identical every read) must be reported as
    'settled', even when the observed span never reaches min_stable_ms —
    labeling it 'still-moving' would misreport a screen that never moved."""
    # start=0.0, then two reads 0.4s apart; the second read already sits past
    # timeout_s=0.3 (well short of min_stable_ms=600ms), so the loop times
    # out right after that second read.
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    tree = _button_tree("Same")
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: tree)
    out = json.loads(mod.ios_await_idle(timeout_s=0.3, min_stable_ms=600))
    assert out["verdict"] == "settled"
    assert out["reads"] == 2
    assert out["stable_ms"] == pytest.approx(400.0)


def test_await_idle_still_moving_when_fingerprint_keeps_changing(mod, monkeypatch):
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4, 0.8, 1.2, 1.6, 2.0])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    counter = {"i": 0}

    def changing_tree():
        counter["i"] += 1
        return _button_tree(f"State{counter['i']}")
    monkeypatch.setattr(mod, "_fetch_source_tree", changing_tree)
    out = json.loads(mod.ios_await_idle(timeout_s=2.0, min_stable_ms=600))
    assert out["verdict"] == "still-moving"
    assert out["reads"] >= 2


_EMPTY_TREE = {"type": "Application", "label": None, "name": None, "value": None,
               "identifier": None, "enabled": None, "visible": None, "hittable": None,
               "rect": None, "children": []}


def test_await_idle_empty_when_tree_has_no_elements(mod, monkeypatch):
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4, 0.8, 1.2])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: _EMPTY_TREE)
    out = json.loads(mod.ios_await_idle(timeout_s=1.0, min_stable_ms=600))
    assert out["verdict"] == "empty"


def test_await_idle_too_few_reads_when_timeout_hits_before_second_read(mod, monkeypatch):
    # Deadline is 1.0s past start; the single read already lands past it, so
    # the loop never gets a second read to compare against.
    _fake_monotonic(monkeypatch, mod, [0.0, 1.5])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: _button_tree("Once"))
    out = json.loads(mod.ios_await_idle(timeout_s=1.0, min_stable_ms=600))
    assert out["verdict"] == "too-few-reads"
    assert out["reads"] == 1


def test_await_idle_never_raises_on_timeout(mod, monkeypatch):
    """ios_await_idle must never turn a non-settle into an exception — only a
    genuine transport failure from _fetch_source_tree should propagate."""
    _fake_monotonic(monkeypatch, mod, [0.0, 0.0, 0.4, 0.8])
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_win_size", lambda: (100.0, 100.0))
    monkeypatch.setattr(mod, "_fetch_source_tree",
                        lambda: {"type": "Application", "children": []})
    # Must not raise.
    json.loads(mod.ios_await_idle(timeout_s=0.5, min_stable_ms=600))


def test_await_idle_propagates_genuine_transport_error(mod, monkeypatch):
    """A real WDA failure (wedged/unreachable) from _fetch_source_tree is NOT
    swallowed into a verdict — it's a transport wedge, not a non-settle."""
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)

    def boom():
        raise RuntimeError("WDA timed out after 60s on /source. It may be busy or wedged.")
    monkeypatch.setattr(mod, "_fetch_source_tree", boom)
    with pytest.raises(RuntimeError, match="wedged"):
        mod.ios_await_idle(timeout_s=1.0)


def test_screenshot_decodes_base64(mod, wda):
    import base64
    png = b"\x89PNG\r\n\x1a\nfake"
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    img = mod.ios_screenshot()
    assert img.data == png


def test_screenshot_raises_when_empty(mod, wda):
    # _ensure_session() runs BEFORE the GET /screenshot, so /session must be
    # scripted for the RuntimeError("No screenshot") assertion to be reached.
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", (200, {"value": None}))
    with pytest.raises(RuntimeError, match="No screenshot"):
        mod.ios_screenshot()


def test_screenshot_raises_when_wda_returns_non_image_body(mod, wda):
    # _ensure_session() runs BEFORE the GET /screenshot, so /session must be
    # scripted for the MCPToolError assertion below to be reached.
    import base64
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(b"<html>404</html>").decode()}))
    with pytest.raises(mod.MCPToolError) as excinfo:
        mod.ios_screenshot()
    assert excinfo.value.error_kind == "wda_http"
    assert excinfo.value.error_code == "SCREENSHOT_NOT_IMAGE"
    assert "not a recognizable image" in str(excinfo.value)


def test_img_kind_sniffs_magic_bytes(mod):
    assert mod._img_kind(b"\xff\xd8\xff\xe0stuff") == ("jpeg", ".jpg")
    assert mod._img_kind(b"\x89PNG\r\n\x1a\nfake") == ("png", ".png")
    with pytest.raises(mod.MCPToolError) as excinfo:
        mod._img_kind(b"garbage")
    assert excinfo.value.error_kind == "wda_http"
    assert excinfo.value.error_code == "SCREENSHOT_NOT_IMAGE"


def test_screenshot_reports_jpeg_when_wda_sends_jpeg(mod, wda):
    import base64
    jpeg = b"\xff\xd8\xff\xe0" + b"\x00" * 16
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(jpeg).decode()}))
    img = mod.ios_screenshot()
    assert img.data == jpeg
    assert img._mime_type == "image/jpeg"


def test_screenshot_quality_env(mod, monkeypatch):
    """mod is device-mode (see the `mod` fixture) so the fallback default is 1."""
    monkeypatch.delenv("IMIRROR_SCREENSHOT_QUALITY", raising=False)
    assert mod._screenshot_quality() == 1
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "0")
    assert mod._screenshot_quality() == 0
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "2")
    assert mod._screenshot_quality() == 2
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "5")     # out of range
    assert mod._screenshot_quality() == 1
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "junk")  # non-int
    assert mod._screenshot_quality() == 1


def test_screenshot_quality_default_on_simulator(sim_mod, monkeypatch):
    """On the simulator, WDA ignores the JPEG path and higher quality values only
    bloat the PNG, so the fallback default is 0 (lossless PNG) instead of 1."""
    monkeypatch.delenv("IMIRROR_SCREENSHOT_QUALITY", raising=False)
    assert sim_mod._screenshot_quality() == 0
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "2")
    assert sim_mod._screenshot_quality() == 2


def test_ensure_session_sends_screenshot_quality(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod._ensure_session()
    bodies = [b for m, p, b in wda.calls if p.endswith("/appium/settings")]
    assert any(b["settings"].get("screenshotQuality") == 1 for b in bodies)


def test_ensure_session_sends_screenshot_quality_override(mod, wda, monkeypatch):
    monkeypatch.setenv("IMIRROR_SCREENSHOT_QUALITY", "2")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod._ensure_session()
    bodies = [b for m, p, b in wda.calls if p.endswith("/appium/settings")]
    assert any(b["settings"].get("screenshotQuality") == 2 for b in bodies)


# ---- I12: simctl fast-path screenshot on the simulator branch ------------------

def test_screenshot_sim_uses_simctl_fast_path(sim_mod, monkeypatch):
    """On the simulator, a working simctl captures the shot without ever
    touching WDA."""
    png = b"\x89PNG\r\n\x1a\nfake"

    def fake_run(args, **kw):
        with open(args[-1], "wb") as f:
            f.write(png)
        class R: returncode = 0; stdout = ""; stderr = ""
        return R()
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)

    wda_calls = []
    monkeypatch.setattr(sim_mod, "_req",
                        lambda *a, **k: wda_calls.append(a) or pytest.fail("WDA should not be called"))

    img = sim_mod.ios_screenshot()
    assert img.data == png
    assert wda_calls == []


def test_screenshot_sim_falls_back_to_wda_on_simctl_failure(sim_mod, monkeypatch):
    """A simctl failure on the sim falls back to the WDA path instead of
    failing the call."""
    import base64
    import subprocess as sp

    def fake_run(args, **kw):
        raise sp.CalledProcessError(1, args, stderr="boom")
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)

    fake = FakeWDA()
    png = b"\x89PNG\r\n\x1a\nfake"
    fake.script("/session", (200, {"value": {"sessionId": "s"}}))
    fake.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    monkeypatch.setattr(sim_mod, "_req", fake)

    img = sim_mod.ios_screenshot()
    assert img.data == png


def test_screenshot_sim_calls_simctl_with_correct_args(sim_mod, monkeypatch):
    seen = _fake_simctl(sim_mod, monkeypatch)
    with pytest.raises(sim_mod.MCPToolError):
        sim_mod.ios_screenshot()  # empty temp file -> not a recognizable image
    assert seen["args"][:5] == ["xcrun", "simctl", "io", "booted", "screenshot"]
    assert seen["args"][5].endswith(".png")


def test_screenshot_device_never_calls_simctl(mod, wda, monkeypatch):
    """Device mode is unchanged: it always goes through WDA and never shells
    out to simctl."""
    import base64

    def fail_run(*a, **k):
        pytest.fail("simctl should not run in device mode")
    monkeypatch.setattr(mod.subprocess, "run", fail_run)

    png = b"\x89PNG\r\n\x1a\nfake"
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    img = mod.ios_screenshot()
    assert img.data == png


def test_screenshot_first_call_applies_quality(mod, wda):
    """Fable risk #1 regression guard: quality must be applied even when a
    screenshot is the very first tool call of a session."""
    import base64
    assert mod._session["id"] is None
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    png = b"\x89PNG\r\n\x1a\nfake"
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    mod.ios_screenshot()
    assert any(p == "/session" for m, p, _ in wda.calls)
    bodies = [b for m, p, b in wda.calls if p.endswith("/appium/settings")]
    assert any("screenshotQuality" in b["settings"] for b in bodies)


# ---- gestures ------------------------------------------------------------------

def test_tap_emits_pointer_sequence(mod, wda):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_tap(10, 20)
    actions = next(b for m, p, b in wda.calls if p.endswith("/actions"))
    steps = actions["actions"][0]["actions"]
    assert steps[0] == {"type": "pointerMove", "duration": 0, "x": 10, "y": 20}
    assert any(s["type"] == "pointerDown" for s in steps)
    assert any(s["type"] == "pointerUp" for s in steps)


def test_tap_settle_sleeps(mod, wda, monkeypatch):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    slept = []
    monkeypatch.setattr(mod.time, "sleep", lambda s: slept.append(s))
    mod.ios_tap(10, 20, settle_ms=300)
    assert slept == [0.3]


def test_tap_no_settle_by_default(mod, wda, monkeypatch):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    slept = []
    monkeypatch.setattr(mod.time, "sleep", lambda s: slept.append(s))
    mod.ios_tap(10, 20)
    assert slept == []


def test_swipe_clamps_zero_duration(mod, wda):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_swipe(0, 0, 5, 5, duration_ms=0)
    actions = next(b for m, p, b in wda.calls if p.endswith("/actions"))
    move = actions["actions"][0]["actions"][2]
    assert move["duration"] >= 1  # never zero — WDA rejects a 0-duration drag


def test_type_sends_char_list(mod, wda):
    wda.allow("/wda/keys")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_type("hi")
    body = next(b for m, p, b in wda.calls if p.endswith("/wda/keys"))
    assert body == {"value": ["h", "i"]}


def test_press_button_rejects_unknown(mod, wda):
    with pytest.raises(RuntimeError, match="must be one of"):
        mod.ios_press_button("power")


def test_press_home_uses_homescreen_route(mod, wda):
    wda.allow("/wda/homescreen")
    mod.ios_press_button("home")
    assert any(p == "/wda/homescreen" for m, p, _ in wda.calls)


# ---- find / wait ---------------------------------------------------------------

def test_find_and_tap_escapes_quotes(mod, wda):
    wda.allow("/click")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod.ios_find_and_tap("O'Brien")
    find = next(b for m, p, b in wda.calls if p.endswith("/element"))
    assert "O\\'Brien" in find["value"]


def test_find_and_tap_raises_when_absent(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {}}))
    with pytest.raises(RuntimeError, match="No element matching"):
        mod.ios_find_and_tap("Nope")


def test_wait_for_returns_when_present(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    assert "found" in mod.ios_wait_for("Settings", timeout_s=1)


def test_wait_for_times_out(mod, monkeypatch):
    m = mod
    monkeypatch.setattr(m, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)  # don't actually wait
    # Stub the failure-path snapshot read too, so this stays device-free (no
    # real socket call) — see test_wait_for_timeout_appends_tree_snapshot for
    # the snapshot-content assertion.
    monkeypatch.setattr(m, "_fetch_source_tree", lambda: {"type": "Application", "children": []})
    with pytest.raises(RuntimeError, match="did not appear"):
        m.ios_wait_for("Ghost", timeout_s=0)


def test_wait_for_polls_then_succeeds(mod, monkeypatch):
    m = mod
    seq = [None, None, "e1"]
    monkeypatch.setattr(m, "_find_element", lambda *a, **k: seq.pop(0))
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    out = m.ios_wait_for("Later", timeout_s=10)
    assert "3 check(s)" in out


def test_wait_for_uses_visible_only_predicate(mod, wda):
    """ios_wait_for must wait for the first VISIBLE match, per the
    await-element contract — not just any match in the tree."""
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod.ios_wait_for("Settings", timeout_s=1)
    body = next(b for m, p, b in wda.calls if p.endswith("/element"))
    assert "visible == 1" in body["value"]


def test_find_element_or_timeout_swallows_wedged(mod, monkeypatch):
    def wedged(*a, **k):
        raise mod.MCPToolError("timed out", kind=mod.ErrorKind.WEDGED)
    monkeypatch.setattr(mod, "_find_element", wedged)
    eid, err = mod._find_element_or_timeout("X")
    assert eid is None
    assert isinstance(err, mod.MCPToolError)
    assert err.error_kind == mod.ErrorKind.WEDGED


def test_find_element_or_timeout_reraises_non_timeout(mod, monkeypatch):
    def unreachable(*a, **k):
        raise mod.MCPToolError("down", kind=mod.ErrorKind.UNREACHABLE)
    monkeypatch.setattr(mod, "_find_element", unreachable)
    with pytest.raises(mod.MCPToolError) as excinfo:
        mod._find_element_or_timeout("X")
    assert excinfo.value.error_kind == mod.ErrorKind.UNREACHABLE


def test_wait_for_transient_timeout_keeps_polling(mod, monkeypatch):
    """A single slow-but-not-wedged lookup (WEDGED from the PROBE-tier POST)
    must not abort the whole timeout_s budget after one attempt — it's a
    transient miss, so the loop keeps polling and can still succeed."""
    m = mod
    calls = {"i": 0}

    def flaky(*a, **k):
        calls["i"] += 1
        if calls["i"] == 1:
            raise m.MCPToolError("WDA timed out after 5s on /element.",
                                 kind=m.ErrorKind.WEDGED)
        return "e1"
    monkeypatch.setattr(m, "_find_element", flaky)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    out = m.ios_wait_for("Settings", timeout_s=10)
    assert "found" in out
    assert calls["i"] == 2  # did not abort on the first timeout


def test_wait_for_wedged_for_entire_budget_raises_wedged(mod, monkeypatch):
    """If EVERY lookup times out for the whole timeout_s window, ios_wait_for
    must re-raise the WEDGED error after the deadline (not after one
    attempt) — the caller still learns it was a wedge, not a plain miss."""
    m = mod
    it = iter([0.0, 0.4, 0.9, 1.5])
    monkeypatch.setattr(m.time, "monotonic", lambda: next(it))

    def always_wedged(*a, **k):
        raise m.MCPToolError("WDA timed out after 5s on /element.",
                             kind=m.ErrorKind.WEDGED)
    monkeypatch.setattr(m, "_find_element", always_wedged)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    with pytest.raises(m.MCPToolError) as excinfo:
        m.ios_wait_for("Ghost", timeout_s=1.0)
    assert excinfo.value.error_kind == m.ErrorKind.WEDGED


def test_wait_for_non_timeout_error_propagates_immediately(mod, monkeypatch):
    """A non-timeout failure (e.g. WDA unreachable) must fail fast, not be
    swallowed and retried like a transient timeout."""
    m = mod
    calls = {"i": 0}

    def unreachable(*a, **k):
        calls["i"] += 1
        raise m.MCPToolError("Cannot reach WDA", kind=m.ErrorKind.UNREACHABLE)
    monkeypatch.setattr(m, "_find_element", unreachable)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    with pytest.raises(m.MCPToolError) as excinfo:
        m.ios_wait_for("Ghost", timeout_s=10)
    assert excinfo.value.error_kind == m.ErrorKind.UNREACHABLE
    assert calls["i"] == 1


def test_wait_for_timeout_appends_tree_snapshot(mod, monkeypatch):
    """On timeout, the error names what was actually on screen (a compact-tree
    snapshot), not just 'did not appear' — the failure path's one extra heavy
    read, never taken on the polling hot path."""
    m = mod
    monkeypatch.setattr(m, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    monkeypatch.setattr(m, "_win_size", lambda: (100.0, 100.0))
    monkeypatch.setattr(m, "_fetch_source_tree", lambda: _button_tree("Cancel"))
    with pytest.raises(RuntimeError, match="Cancel"):
        m.ios_wait_for("Ghost", timeout_s=0)


def test_wait_for_timeout_snapshot_failure_falls_back(mod, monkeypatch):
    """If the failure-path snapshot read itself blows up (the same wedged WDA
    that likely caused the timeout), ios_wait_for still raises its normal
    timeout error rather than a confusing secondary exception."""
    m = mod
    monkeypatch.setattr(m, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)

    def boom():
        raise RuntimeError("WDA timed out")
    monkeypatch.setattr(m, "_fetch_source_tree", boom)
    with pytest.raises(RuntimeError, match="did not appear"):
        m.ios_wait_for("Ghost", timeout_s=0)


# ---- run recording & report ----------------------------------------------------

def test_recording_off_by_default(mod, wda):
    wda.allow("/actions")
    """Actions outside a run leave no trace and write nothing."""
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_tap(1, 2)
    assert mod._run["active"] is False
    assert mod._run["steps"] == []


def test_run_note_requires_active_run(mod):
    with pytest.raises(RuntimeError, match="No active run"):
        mod.ios_run_note("hi")


def test_finish_requires_active_run(mod):
    with pytest.raises(RuntimeError, match="No active run"):
        mod.ios_finish_run()


def test_run_note_validates_status(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("x")
    with pytest.raises(RuntimeError, match="info / pass / fail"):
        mod.ios_run_note("bad", status="maybe")


def test_full_run_records_and_renders_report(mod, wda, monkeypatch, tmp_path):
    wda.allow("/actions", "/wda/keys")
    import base64
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    png = b"\x89PNG\r\n\x1a\nfakebytes"
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/status", (200, {"value": {
        "device": "iPhone 15", "os": {"version": "17.4"}}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))

    out = mod.ios_start_run("login flow")
    assert "recording run" in out
    assert mod._run["active"] is True

    mod.ios_tap(10, 20)
    mod.ios_screenshot()           # saved to the run dir + recorded
    mod.ios_run_note("logged in", status="pass")
    report = mod.ios_finish_run(video="none")

    # run stopped, report exists, png persisted
    assert mod._run["active"] is False
    assert report.endswith("report.html")
    run_dir = mod._run["dir"]
    assert os.path.exists(os.path.join(run_dir, "001.png")) or \
           os.path.exists(os.path.join(run_dir, "002.png"))

    htmltext = open(report, encoding="utf-8").read()
    assert "login flow" in htmltext
    assert "iPhone 15" in htmltext and "17.4" in htmltext
    assert "logged in" in htmltext
    assert base64.b64encode(png).decode() in htmltext   # screenshot embedded
    assert "PASS" in htmltext


def test_full_run_with_jpeg_screenshot_embeds_jpeg_mime(mod, wda, monkeypatch, tmp_path):
    wda.allow("/actions", "/wda/keys")
    import base64
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    jpeg = b"\xff\xd8\xff\xe0" + b"\x00" * 16
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/status", (200, {"value": {
        "device": "iPhone 15", "os": {"version": "17.4"}}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(jpeg).decode()}))

    mod.ios_start_run("login flow")
    mod.ios_screenshot()           # saved to the run dir as .jpg + recorded
    report = mod.ios_finish_run(video="none")

    run_dir = mod._run["dir"]
    assert os.path.exists(os.path.join(run_dir, "001.jpg"))

    htmltext = open(report, encoding="utf-8").read()
    assert "data:image/jpeg" in htmltext
    assert base64.b64encode(jpeg).decode() in htmltext


def test_failed_note_marks_report_fail(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("broken")
    mod.ios_run_note("button missing", status="fail")
    report = mod.ios_finish_run(video="none")
    htmltext = open(report, encoding="utf-8").read()
    assert "1 failures" in htmltext
    assert ">FAIL<" in htmltext


def test_run_section_requires_active_run(mod):
    with pytest.raises(RuntimeError, match="No active run"):
        mod.ios_run_section("Login")


def test_run_section_groups_steps_and_builds_toc(mod, wda, monkeypatch, tmp_path):
    wda.allow("/actions", "/wda/keys")
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))

    mod.ios_start_run("wallet checks")
    out = mod.ios_run_section("Money requests")
    assert "Money requests" in out
    mod.ios_tap(1, 2)
    mod.ios_run_note("request shows correct amount", status="pass")
    mod.ios_run_section("Admin removal")
    mod.ios_run_note("empty state copy wrong", status="fail")
    report = mod.ios_finish_run(video="none")

    htmltext = open(report, encoding="utf-8").read()
    # both section titles rendered, and a table of contents links to anchors
    assert "Money requests" in htmltext and "Admin removal" in htmltext
    assert 'class="toc"' in htmltext
    assert 'href="#sec-' in htmltext and 'id="sec-' in htmltext
    # per-section rollup: the failing section's status shows FAIL, passing one PASS
    assert ">FAIL<" in htmltext
    # overall verdict is FAIL because a section failed
    assert htmltext.count("FAIL") >= 1


def test_report_has_cover_and_summary_infographics(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    import base64
    png = b"\x89PNG\r\n\x1a\nfakebytes"
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/status", (200, {"value": {"device": "iPhone 15", "os": {"version": "17.4"}}}))
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))

    mod.ios_start_run("smoke")
    mod.ios_run_section("Home")
    mod.ios_screenshot()
    mod.ios_run_note("home ok", status="pass")
    report = mod.ios_finish_run(video="none")

    htmltext = open(report, encoding="utf-8").read()
    # cover + summary infographic markers
    assert 'class="summary"' in htmltext
    assert "<svg" in htmltext          # donut / chart is inline SVG (no JS libs)
    assert "Screenshots" in htmltext   # stat card label
    assert "Sections" in htmltext


def test_report_without_sections_still_renders(mod, wda, monkeypatch, tmp_path):
    """Backward compatible: runs that never call ios_run_section group under a
    single implicit section and still render TOC + summary."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("legacy")
    mod.ios_run_note("did a thing", status="pass")
    report = mod.ios_finish_run(video="none")
    htmltext = open(report, encoding="utf-8").read()
    assert ">PASS<" in htmltext
    assert 'class="summary"' in htmltext
    assert "did a thing" in htmltext


def test_start_run_survives_status_failure(mod, monkeypatch, tmp_path):
    """A flaky /status during start must not abort recording."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))

    def boom(method, path, body=None):
        raise RuntimeError("status down")

    monkeypatch.setattr(mod, "_req", boom)
    mod.ios_start_run("resilient")
    assert mod._run["active"] is True
    assert mod._run["device"] is None


# ---- orientation ---------------------------------------------------------------

def test_orientation_get(mod, wda):
    import json
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/orientation", (200, {"value": "PORTRAIT"}))
    assert json.loads(mod.ios_orientation()) == {"orientation": "PORTRAIT"}


def test_orientation_set_then_get(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/orientation", (200, {"value": {}}), (200, {"value": "LANDSCAPE"}))
    mod.ios_orientation("landscape")           # lowercase is normalized
    posts = [b for m, p, b in wda.calls if m == "POST" and p.endswith("/orientation")]
    assert posts == [{"orientation": "LANDSCAPE"}]


def test_orientation_rejects_bad(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    with pytest.raises(RuntimeError, match="set_to must be one of"):
        mod.ios_orientation("sideways")


# ---- scroll tools --------------------------------------------------------------

def _swipe_points(wda):
    """Extract (from_pt, to_pt) from the last /actions pointer gesture."""
    body = next(b for m, p, b in reversed(wda.calls) if p.endswith("/actions"))
    steps = body["actions"][0]["actions"]
    frm = next(s for s in steps if s["type"] == "pointerMove" and s["duration"] == 0)
    to = [s for s in steps if s["type"] == "pointerMove" and s["duration"] > 0][-1]
    return (frm["x"], frm["y"]), (to["x"], to["y"])


def test_ios_scroll_down_swipes_up(mod, wda):
    wda.allow("/actions")
    import json
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    out = json.loads(mod.ios_scroll("down", distance_pct=40))
    (fx, fy), (tx, ty) = _swipe_points(wda)
    # "down" content => finger moves UP (from below centre to above centre)
    assert fx == tx == 215
    assert fy > ty, "down-scroll must swipe the finger upward"
    assert out["distance_pts"] > 0


def test_ios_scroll_up_swipes_down(mod, wda):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    mod.ios_scroll("up", distance_pct=40)
    (fx, fy), (tx, ty) = _swipe_points(wda)
    assert ty > fy, "up-scroll must swipe the finger downward"


def test_ios_scroll_distance_floored(mod, wda):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    mod.ios_scroll("down", distance_pct=1)            # floored to 15%
    (_, fy), (_, ty) = _swipe_points(wda)
    assert abs(fy - ty) >= 932 * 0.15 - 1


def test_ios_scroll_rejects_bad_direction(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    with pytest.raises(RuntimeError, match="direction must be one of"):
        mod.ios_scroll("sideways")


def test_ios_scroll_clamps_to_bounds(mod, wda):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    mod.ios_scroll("down", distance_pct=100, y_pct=50)  # would overshoot screen
    (_, fy), (_, ty) = _swipe_points(wda)
    assert 1 <= fy <= 931 and 1 <= ty <= 931


def test_ios_scroll_to_found_without_scrolling(mod, monkeypatch):
    import json
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")
    called = []
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: called.append(1))
    out = json.loads(mod.ios_scroll_to("Privacy"))
    assert out == {"found": True, "swipes": 0}
    assert called == []                               # already visible → no scroll


def test_ios_scroll_to_scrolls_then_finds(mod, monkeypatch):
    import json
    seq = [None, None, "e1"]
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: seq.pop(0))
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    out = json.loads(mod.ios_scroll_to("Privacy", max_swipes=10))
    assert out == {"found": True, "swipes": 2}


def test_ios_scroll_to_raises_after_cap(mod, monkeypatch):
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    scrolls = []
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: scrolls.append(1))
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError, match="not found after 3 swipes"):
        mod.ios_scroll_to("Ghost", max_swipes=3)
    assert len(scrolls) == 3                           # capped at max_swipes


def test_ios_scroll_to_transient_timeout_then_found(mod, monkeypatch):
    """A timeout-class lookup failure is a transient miss — it must not abort
    the scroll search outright."""
    seq_err = [True, False, False]

    def flaky(*a, **k):
        if seq_err.pop(0):
            raise mod.MCPToolError("timed out", kind=mod.ErrorKind.WEDGED)
        return "e1"
    monkeypatch.setattr(mod, "_find_element", flaky)
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    out = json.loads(mod.ios_scroll_to("Privacy", max_swipes=5))
    assert out["found"] is True


def test_ios_scroll_to_wedged_for_entire_budget_raises_wedged(mod, monkeypatch):
    def always_wedged(*a, **k):
        raise mod.MCPToolError("timed out", kind=mod.ErrorKind.WEDGED)
    monkeypatch.setattr(mod, "_find_element", always_wedged)
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(mod.MCPToolError) as excinfo:
        mod.ios_scroll_to("Ghost", max_swipes=2)
    assert excinfo.value.error_kind == mod.ErrorKind.WEDGED


def test_swipe_settle_sleeps(mod, wda, monkeypatch):
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    slept = []
    monkeypatch.setattr(mod.time, "sleep", lambda s: slept.append(s))
    mod.ios_swipe(1, 2, 3, 4, settle_ms=300)
    assert slept == [0.3]


def test_window_size_cached(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}))
    mod._win_size(); mod._win_size()
    n = sum(1 for m, p, _ in wda.calls if p.endswith("/window/size"))
    assert n == 1                                      # second call served from cache


# ---- timelapse -----------------------------------------------------------------

def _start_with_two_shots(mod, wda, tmp_path, monkeypatch):
    import base64
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    png = b"\x89PNG\r\n\x1a\nfake"
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/status", (200, {"value": {}}))
    wda.script("/screenshot",
               (200, {"value": base64.b64encode(png).decode()}),
               (200, {"value": base64.b64encode(png).decode()}))
    mod.ios_start_run("clip")
    mod.ios_screenshot()
    mod.ios_screenshot()


def test_finish_invalid_video(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("x")
    with pytest.raises(RuntimeError, match="video must be one of"):
        mod.ios_finish_run(video="webm")


def test_timelapse_embedded_when_ffmpeg_succeeds(mod, wda, monkeypatch, tmp_path):
    _start_with_two_shots(mod, wda, tmp_path, monkeypatch)
    run_dir = mod._run["dir"]

    def fake_ffmpeg(args):                       # last arg is the output path
        with open(args[-1], "wb") as f:
            f.write(b"GIF89a-fake")
    monkeypatch.setattr(mod, "_ffmpeg", fake_ffmpeg)

    report = mod.ios_finish_run(video="gif")
    htmltext = open(report, encoding="utf-8").read()
    assert '<img class="clip" src="timelapse.gif"' in htmltext
    assert os.path.exists(os.path.join(run_dir, "timelapse.gif"))
    # scratch files cleaned up
    assert not os.path.exists(os.path.join(run_dir, "_frames.txt"))
    assert not os.path.exists(os.path.join(run_dir, "_palette.png"))


def test_timelapse_mp4_uses_video_tag(mod, wda, monkeypatch, tmp_path):
    _start_with_two_shots(mod, wda, tmp_path, monkeypatch)
    monkeypatch.setattr(mod, "_ffmpeg",
                        lambda args: open(args[-1], "wb").write(b"\x00mp4"))
    report = mod.ios_finish_run(video="mp4")
    assert '<video class="clip" src="timelapse.mp4"' in open(report).read()


def test_timelapse_skipped_when_too_few_shots(mod, wda, monkeypatch, tmp_path):
    import base64
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot",
               (200, {"value": base64.b64encode(b"\x89PNG\r\n\x1a\nx").decode()}))
    mod.ios_start_run("one")
    mod.ios_screenshot()
    report = mod.ios_finish_run(video="gif")
    assert "fewer than 2 screenshots" in open(report).read()


def test_timelapse_skipped_when_ffmpeg_missing(mod, wda, monkeypatch, tmp_path):
    _start_with_two_shots(mod, wda, tmp_path, monkeypatch)
    monkeypatch.setattr(mod.shutil, "which", lambda _: None)
    report = mod.ios_finish_run(video="gif")
    assert "ffmpeg not found" in open(report).read()


def test_timelapse_handles_ffmpeg_failure(mod, wda, monkeypatch, tmp_path):
    import subprocess
    _start_with_two_shots(mod, wda, tmp_path, monkeypatch)

    def boom(args):
        raise subprocess.CalledProcessError(1, "ffmpeg")
    monkeypatch.setattr(mod, "_ffmpeg", boom)

    report = mod.ios_finish_run(video="gif")     # must not raise
    assert "ffmpeg failed" in open(report).read()
    assert mod._run["active"] is False


# ---- simulator screen recording -------------------------------------------------

class _FakeRecorderProc:
    """Stand-in for the Popen handle of `xcrun simctl io booted recordVideo`."""

    def __init__(self):
        self.signals: list[int] = []
        self.waits: list[float | None] = []
        self.killed = False

    def send_signal(self, sig):
        self.signals.append(sig)

    def wait(self, timeout=None):
        self.waits.append(timeout)

    def kill(self):
        self.killed = True


def _fake_popen_spy(monkeypatch, mod, proc=None):
    """Patch mod.subprocess.Popen with a spy; returns (calls, proc, kwarg_calls).

    `calls` collects the positional args list per invocation; `kwarg_calls`
    collects the matching kwargs dict so tests can assert on things like
    `stderr=`.
    """
    proc = proc or _FakeRecorderProc()
    calls: list[list[str]] = []
    kwarg_calls: list[dict] = []

    def fake_popen(args, **kwargs):
        calls.append(args)
        kwarg_calls.append(kwargs)
        return proc

    monkeypatch.setattr(mod.subprocess, "Popen", fake_popen)
    return calls, proc, kwarg_calls


def _touch_recording(m, size=100):
    """Make the active run's recording.mp4 exist and be non-empty on disk."""
    path = os.path.join(m._run["dir"], "recording.mp4")
    with open(path, "wb") as f:
        f.write(b"x" * size)
    return path


def _stub_status(m, monkeypatch):
    """Stub _req so ios_start_run's best-effort /status probe succeeds.

    sim_mod/mod are freestanding module instances (not the `wda` fixture's
    module) — mirroring the existing sim tests, which patch `_req` directly
    rather than pulling in the device-mode `wda` fixture.
    """
    fake = FakeWDA()
    fake.script("/status", (200, {"value": {}}))
    monkeypatch.setattr(m, "_req", fake)
    return fake


def test_sim_start_run_spawns_recorder(sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    calls, proc, kwarg_calls = _fake_popen_spy(monkeypatch, sim_mod)

    out = sim_mod.ios_start_run("rec")

    assert "recording run" in out
    assert sim_mod._run["active"] is True
    assert len(calls) == 1
    args = calls[0]
    assert "recordVideo" in args
    assert os.path.join(sim_mod._run["dir"], "recording.mp4") in args
    assert sim_mod._run["recorder"] is proc
    # I12 finding #4.1: stderr must be drained (DEVNULL), not left as an
    # unread PIPE — a long run can otherwise fill the buffer and block the
    # recorder child, stalling the recording.
    assert kwarg_calls[0]["stderr"] is sim_mod.subprocess.DEVNULL


def test_sim_finish_run_uses_real_recording(sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)
    sim_mod.ios_start_run("rec")
    proc = sim_mod._run["recorder"]
    _touch_recording(sim_mod)

    called_timelapse = []
    monkeypatch.setattr(sim_mod, "_make_timelapse",
                        lambda fmt: called_timelapse.append(fmt) or (None, "unused"))

    report = sim_mod.ios_finish_run(video="mp4")

    assert sim_mod.signal.SIGINT in proc.signals
    assert called_timelapse == []                    # ffmpeg path never used
    assert sim_mod._run["recorder"] is None
    htmltext = open(report, encoding="utf-8").read()
    assert '<video class="clip" src="recording.mp4"' in htmltext


def test_sim_finish_run_video_none_still_stops_recorder_but_no_clip(
        sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)
    sim_mod.ios_start_run("rec")
    proc = sim_mod._run["recorder"]
    _touch_recording(sim_mod)

    report = sim_mod.ios_finish_run(video="none")

    assert sim_mod.signal.SIGINT in proc.signals      # cleaned up regardless
    htmltext = open(report, encoding="utf-8").read()
    assert "recording.mp4" not in htmltext
    assert '<video' not in htmltext


def test_sim_finish_run_falls_back_when_recording_missing(sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)
    sim_mod.ios_start_run("rec")
    # recording.mp4 never gets written (e.g. recordVideo failed silently)

    called_timelapse = []
    monkeypatch.setattr(
        sim_mod, "_make_timelapse",
        lambda fmt: called_timelapse.append(fmt) or (None, "timelapse skipped: fewer than 2 screenshots"))

    report = sim_mod.ios_finish_run(video="gif")

    assert called_timelapse == ["gif"]                # fallback path used
    assert sim_mod._run["active"] is False
    assert os.path.exists(report)


def test_device_start_run_does_not_spawn_recorder(mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(mod, monkeypatch)
    calls, _, _ = _fake_popen_spy(monkeypatch, mod)

    mod.ios_start_run("device-run")

    assert calls == []
    assert mod._run["recorder"] is None
    assert mod._run["recording"] is None


def test_sim_start_run_recorder_failure_is_best_effort(sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)

    def boom(args, **kwargs):
        raise FileNotFoundError("xcrun not found")
    monkeypatch.setattr(sim_mod.subprocess, "Popen", boom)

    out = sim_mod.ios_start_run("rec")

    assert "recording run" in out
    assert sim_mod._run["active"] is True
    assert sim_mod._run["recorder"] is None
    assert sim_mod._run["recording"] is None


def test_stop_sim_recording_kills_on_timeout(sim_mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)

    class HangingProc(_FakeRecorderProc):
        def __init__(self):
            super().__init__()
            self.wait_calls = 0

        def wait(self, timeout=None):
            self.wait_calls += 1
            if self.wait_calls == 1:
                raise sim_mod.subprocess.TimeoutExpired(cmd="recordVideo", timeout=timeout)

    proc = HangingProc()
    _fake_popen_spy(monkeypatch, sim_mod, proc=proc)
    sim_mod.ios_start_run("rec")
    _touch_recording(sim_mod)

    clip, note = sim_mod._stop_sim_recording()

    assert proc.killed is True
    assert "incomplete" in note
    assert clip == "recording.mp4"                    # file still usable despite the timeout


def test_stop_sim_recording_no_recorder_is_noop(sim_mod):
    clip, note = sim_mod._stop_sim_recording()
    assert (clip, note) == (None, "")


# ---- I12 finding #4: atexit cleanup + recorder lock ----------------------------

def test_stop_sim_recording_registered_with_atexit(monkeypatch):
    """I12 #4.2: module load must register _stop_sim_recording as an atexit
    cleanup, so a server exit between ios_start_run and ios_finish_run doesn't
    orphan the recordVideo child. Patch atexit.register before importing so we
    can observe what the module hands it."""
    import atexit
    registered = []
    monkeypatch.setattr(atexit, "register", lambda f, *a, **k: registered.append(f))
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.delenv("IMIRROR_TARGET", raising=False)
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    assert m._stop_sim_recording in registered


def test_atexit_handler_stops_active_recorder(sim_mod, monkeypatch, tmp_path):
    """I12 #4.2: invoking the registered handler (simulating interpreter
    shutdown) with a fake active recorder sends SIGINT and clears
    _run["recorder"], same as a normal _stop_sim_recording call."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)
    sim_mod.ios_start_run("rec")
    proc = sim_mod._run["recorder"]
    assert proc is not None

    sim_mod._stop_sim_recording()  # the exact callable atexit.register was given

    assert sim_mod.signal.SIGINT in proc.signals
    assert sim_mod._run["recorder"] is None


def test_start_sim_recording_uses_recorder_lock(sim_mod, monkeypatch, tmp_path):
    """I12 #4.3: the spawn must happen while holding _recorder_lock, so a
    concurrent stop/start can't interleave with it."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    os.makedirs(tmp_path, exist_ok=True)
    _fake_popen_spy(monkeypatch, sim_mod)

    held_during_popen = []

    real_popen = sim_mod.subprocess.Popen

    def spying_popen(*a, **k):
        # RLock.acquire(blocking=False) succeeds here (same thread already
        # holds it), and _is_owned confirms the current thread is the owner.
        held_during_popen.append(sim_mod._recorder_lock._is_owned())
        return real_popen(*a, **k)
    monkeypatch.setattr(sim_mod.subprocess, "Popen", spying_popen)

    sim_mod._start_sim_recording(str(tmp_path))

    assert held_during_popen == [True]


def test_stop_sim_recording_uses_recorder_lock(sim_mod, monkeypatch, tmp_path):
    """I12 #4.3: the stop handshake (signal + _run mutation) must happen while
    holding _recorder_lock."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)
    sim_mod.ios_start_run("rec")
    proc = sim_mod._run["recorder"]

    held_during_signal = []
    real_send_signal = proc.send_signal

    def spying_send_signal(sig):
        held_during_signal.append(sim_mod._recorder_lock._is_owned())
        return real_send_signal(sig)
    proc.send_signal = spying_send_signal

    sim_mod._stop_sim_recording()

    assert held_during_signal == [True]


def test_ios_start_run_holds_lock_across_stop_reset_start(sim_mod, monkeypatch, tmp_path):
    """I12 #4.3: ios_start_run must hold _recorder_lock across stopping any
    prior recorder, resetting the recorder keys, and starting the new one —
    otherwise a concurrent ios_start_run could interleave and orphan a
    recorder handle."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    _stub_status(sim_mod, monkeypatch)
    _fake_popen_spy(monkeypatch, sim_mod)

    held = []
    real_start = sim_mod._start_sim_recording

    def spying_start(run_dir):
        held.append(sim_mod._recorder_lock._is_owned())
        return real_start(run_dir)
    monkeypatch.setattr(sim_mod, "_start_sim_recording", spying_start)

    sim_mod.ios_start_run("rec")

    assert held == [True]


# ---- verified-review fixes -------------------------------------------------------

def test_orientation_set_invalidates_window_cache(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/window/size", (200, {"value": {"width": 430, "height": 932}}),
               (200, {"value": {"width": 932, "height": 430}}))
    wda.script("/orientation", (200, {"value": {}}), (200, {"value": "LANDSCAPE"}))
    assert mod._win_size() == (430.0, 932.0)
    mod.ios_orientation("landscape")
    # cache must be dropped: next _win_size re-queries and sees swapped dims
    assert mod._win_size() == (932.0, 430.0)


def test_find_element_escapes_backslash(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod._find_element("end\\")
    body = next(b for m, p, b in wda.calls if p.endswith("/element"))
    # trailing backslash must be doubled so it can't eat the closing quote
    assert "end\\\\" in body["value"]


def test_find_element_uses_probe_tier(mod, wda):
    """Poll loops (ios_wait_for, ios_find_and_tap, ios_scroll_to, the asserts)
    call _find_element many times per second — it must use the short PROBE
    tier, not the INTERACT default, so a wedged WDA surfaces fast."""
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod._find_element("Login")
    idx = next(i for i, (_, p, _) in enumerate(wda.calls) if p.endswith("/element"))
    assert wda.timeouts[idx] == mod._TIMEOUT_PROBE


def test_find_element_default_predicate_unchanged(mod, wda):
    """Regression guard: visible_only defaults False, so ios_find_and_tap /
    ios_scroll_to / the asserts keep matching any on-screen element, not just
    a visible one."""
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod._find_element("Login")
    body = next(b for m, p, b in wda.calls if p.endswith("/element"))
    assert body["value"] == "label == 'Login' OR name == 'Login' OR value == 'Login'"


def test_find_element_visible_only_extends_predicate(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    mod._find_element("Login", visible_only=True)
    body = next(b for m, p, b in wda.calls if p.endswith("/element"))
    assert body["value"] == (
        "(label == 'Login' OR name == 'Login' OR value == 'Login') AND visible == 1")


def test_gesture_timeout_does_not_retry(mod, monkeypatch):
    """A gesture whose _req call times out must raise immediately with no
    retry (a timed-out gesture may have already applied on-device; retrying
    could double-apply it). Also confirms gestures use the INTERACT tier."""
    import socket

    action_calls = []

    def fake_http(method, path, data, timeout):
        if path.endswith("/session"):
            return 200, b'{"value": {"sessionId": "s1"}}'
        if path.endswith("/appium/settings"):
            return 200, b'{"value": {}}'
        if path.endswith("/actions"):
            action_calls.append(timeout)
            raise socket.timeout("timed out")
        raise AssertionError(f"unexpected path {path}")

    monkeypatch.setattr(mod, "_http", fake_http)
    with pytest.raises(RuntimeError, match="timed out"):
        mod._gesture([{"type": "pointerMove", "duration": 0, "x": 0, "y": 0}])
    assert action_calls == [mod._TIMEOUT_INTERACT]  # exactly one attempt, at the INTERACT tier


def test_press_home_raises_on_wda_error(mod, wda):
    wda.script("/wda/homescreen", (500, {"value": "boom"}))
    with pytest.raises(RuntimeError, match="HTTP 500"):
        mod.ios_press_button("home")


def test_find_and_tap_raises_on_click_error(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/element", (200, {"value": {"ELEMENT": "e1"}}))
    wda.script("/click", (500, {"value": "boom"}))
    with pytest.raises(RuntimeError, match="HTTP 500"):
        mod.ios_find_and_tap("Settings")


def test_scroll_to_records_success(mod, wda, monkeypatch, tmp_path):
    import json
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("r")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")
    json.loads(mod.ios_scroll_to("Privacy"))
    assert any(s["action"] == "scroll_to" and "found after 0" in s["detail"]
               for s in mod._run["steps"])


def test_scroll_to_records_failure_as_fail_note(mod, wda, monkeypatch, tmp_path):
    """@_recorded is now the single source of the fail step (I8 dedupe): the
    manual note="fail" call that used to live in ios_scroll_to is gone, so a
    raised failure produces exactly ONE recorded step, carrying a structured
    fail verdict instead of a bare note."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("r")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError):
        mod.ios_scroll_to("Ghost", max_swipes=2)
    fails = [s for s in mod._run["steps"] if mod._step_is_fail(s)]
    assert len(fails) == 1
    assert fails[0]["action"] == "ios_scroll_to"
    assert "not found" in fails[0]["verdict"]["reason"]
    assert fails[0]["verdict"]["error_kind"] == "not_found"


def test_finish_run_deactivates_even_if_write_fails(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("r")
    monkeypatch.setattr(mod, "_render_report", lambda **k: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        mod.ios_finish_run(video="none")
    assert mod._run["active"] is False  # recording stopped despite the failure


def test_screenshot_cap_stops_saving(mod, wda, monkeypatch, tmp_path):
    import base64, os as _os
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setenv("IMIRROR_MAX_RUN_SHOTS", "2")
    png = base64.b64encode(b"\x89PNG\r\n\x1a\nfakebytes").decode()
    wda.script("/status", (200, {"value": {}}))
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/screenshot", *[(200, {"value": png})] * 4)
    mod.ios_start_run("capped")
    for _ in range(4):
        mod.ios_screenshot()                      # all 4 still return an image
    saved = [f for f in _os.listdir(mod._run["dir"]) if f.endswith(".png")]
    assert len(saved) == 2                        # only the first 2 persisted
    notes = [s for s in mod._run["steps"] if s["action"] == "note"]
    assert len(notes) == 1 and "cap reached" in notes[0]["detail"]


# ---- app lifecycle -------------------------------------------------------------

def test_launch_app_posts_bundle_id(mod, wda):
    wda.allow("/wda/apps/launch")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_launch_app("com.apple.Preferences")
    body = next(b for m, p, b in wda.calls if p.endswith("/wda/apps/launch"))
    assert body == {"bundleId": "com.apple.Preferences"}


def test_terminate_app_posts_bundle_id(mod, wda):
    wda.allow("/wda/apps/terminate")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_terminate_app("com.apple.Preferences")
    assert any(p.endswith("/wda/apps/terminate") for m, p, _ in wda.calls)


def test_activate_app_posts_bundle_id(mod, wda):
    wda.allow("/wda/apps/activate")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_activate_app("com.apple.Preferences")
    body = next(b for m, p, b in wda.calls if p.endswith("/wda/apps/activate"))
    assert body == {"bundleId": "com.apple.Preferences"}


def test_app_state_maps_code_to_name(mod, wda):
    import json
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/wda/apps/state", (200, {"value": 4}))
    out = json.loads(mod.ios_app_state("com.apple.Preferences"))
    assert out == {"bundleId": "com.apple.Preferences", "state": "foreground", "code": 4}


# ---- url + clipboard -----------------------------------------------------------

def test_open_url_posts_url(mod, wda):
    wda.allow("/url")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_open_url("myapp://path")
    body = next(b for m, p, b in wda.calls if p.endswith("/url"))
    assert body == {"url": "myapp://path"}


def test_clipboard_set_base64_encodes(mod, wda):
    import base64
    wda.allow("/wda/setPasteboard")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_clipboard_set("hello")
    body = next(b for m, p, b in wda.calls if p.endswith("/wda/setPasteboard"))
    assert body == {"content": base64.b64encode(b"hello").decode(),
                    "contentType": "plaintext"}


def test_clipboard_get_base64_decodes(mod, wda):
    import base64
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/wda/getPasteboard",
               (200, {"value": base64.b64encode(b"copied").decode()}))
    assert mod.ios_clipboard_get() == "copied"


# ---- I12 follow-on: simctl fast-path clipboard on the simulator branch --------

def test_clipboard_set_sim_uses_simctl_fast_path(sim_mod, monkeypatch):
    """On the simulator, a working simctl sets the clipboard without ever
    touching WDA."""
    seen = {}

    def fake_pbcopy(text):
        seen["text"] = text
    monkeypatch.setattr(sim_mod, "_simctl_pbcopy", fake_pbcopy)

    monkeypatch.setattr(sim_mod, "_req",
                        lambda *a, **k: pytest.fail("WDA should not be called"))

    out = sim_mod.ios_clipboard_set("hi")
    assert seen["text"] == "hi"
    assert "set clipboard" in out


def test_clipboard_get_sim_uses_simctl_fast_path(sim_mod, monkeypatch):
    """On the simulator, a working simctl reads the clipboard without ever
    touching WDA."""
    def fake_simctl(*args, **kwargs):
        if args == ("pbpaste", "booted"):
            return "clip text"
        pytest.fail(f"unexpected simctl args {args} kwargs {kwargs}")
    monkeypatch.setattr(sim_mod, "_simctl", fake_simctl)
    monkeypatch.setattr(sim_mod, "_req",
                        lambda *a, **k: pytest.fail("WDA should not be called"))

    assert sim_mod.ios_clipboard_get() == "clip text"


def test_clipboard_get_sim_preserves_whitespace_e3(sim_mod, monkeypatch):
    """E3: pbpaste output must round-trip verbatim, including leading/trailing
    whitespace and a trailing newline — _simctl's default strip=True (correct
    for UDID/device-list callers) would silently corrupt clipboard content
    like an indented snippet or a password ending in a space."""
    seen_kwargs = {}
    raw = "  hi there \n"

    def fake_simctl(*args, **kwargs):
        assert args == ("pbpaste", "booted")
        seen_kwargs.update(kwargs)
        return raw
    monkeypatch.setattr(sim_mod, "_simctl", fake_simctl)
    monkeypatch.setattr(sim_mod, "_req",
                        lambda *a, **k: pytest.fail("WDA should not be called"))

    assert sim_mod.ios_clipboard_get() == raw
    assert seen_kwargs == {"strip": False}


def test_clipboard_set_sim_falls_back_to_wda_on_simctl_failure(sim_mod, monkeypatch):
    """A simctl failure on the sim falls back to the WDA route and still
    sets the clipboard."""
    import base64

    def fail_pbcopy(text):
        raise RuntimeError("boom")
    monkeypatch.setattr(sim_mod, "_simctl_pbcopy", fail_pbcopy)

    fake = FakeWDA()
    fake.allow("/wda/setPasteboard")
    fake.script("/session", (200, {"value": {"sessionId": "s"}}))
    monkeypatch.setattr(sim_mod, "_req", fake)

    out = sim_mod.ios_clipboard_set("hi")
    body = next(b for m, p, b in fake.calls if p.endswith("/wda/setPasteboard"))
    assert body == {"content": base64.b64encode(b"hi").decode(),
                    "contentType": "plaintext"}
    assert "set clipboard" in out


def test_clipboard_get_sim_falls_back_to_wda_on_simctl_failure(sim_mod, monkeypatch):
    """A simctl failure on the sim falls back to the WDA route and still
    reads the clipboard."""
    import base64

    def fail_simctl(*args, **kwargs):
        raise RuntimeError("boom")
    monkeypatch.setattr(sim_mod, "_simctl", fail_simctl)

    fake = FakeWDA()
    fake.script("/session", (200, {"value": {"sessionId": "s"}}))
    fake.script("/wda/getPasteboard",
               (200, {"value": base64.b64encode(b"copied").decode()}))
    monkeypatch.setattr(sim_mod, "_req", fake)

    assert sim_mod.ios_clipboard_get() == "copied"


def test_clipboard_device_never_calls_simctl(mod, wda, monkeypatch):
    """Device mode is unchanged: clipboard set/get always go through WDA and
    never shell out to simctl."""
    import base64

    def fail_run(*a, **k):
        pytest.fail("simctl should not run in device mode")
    monkeypatch.setattr(mod.subprocess, "run", fail_run)

    wda.allow("/wda/setPasteboard")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_clipboard_set("hi")

    wda.script("/wda/getPasteboard",
               (200, {"value": base64.b64encode(b"copied").decode()}))
    assert mod.ios_clipboard_get() == "copied"


# ---- install app (go-ios shell-out) --------------------------------------------

def test_install_app_invokes_go_ios(mod, monkeypatch, tmp_path):
    ipa = tmp_path / "App.ipa"; ipa.write_bytes(b"PK\x03\x04")
    seen = {}
    def fake_run(args, **kw):
        seen["args"] = args
        class R: returncode = 0; stderr = ""
        return R()
    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    out = mod.ios_install_app(str(ipa))
    assert seen["args"][1] == "install" and f"--path={ipa}" in seen["args"]
    assert "installed" in out


def test_install_app_missing_file_raises(mod):
    with pytest.raises(RuntimeError, match="No such file"):
        mod.ios_install_app("/nope/x.ipa")


def test_install_app_reports_go_ios_failure(mod, monkeypatch, tmp_path):
    import subprocess
    ipa = tmp_path / "App.ipa"; ipa.write_bytes(b"x")
    def boom(args, **kw):
        raise subprocess.CalledProcessError(1, args, stderr="device locked")
    monkeypatch.setattr(mod.subprocess, "run", boom)
    with pytest.raises(RuntimeError, match="install failed: device locked"):
        mod.ios_install_app(str(ipa))


# ---- target mode (IMIRROR_TARGET) ----------------------------------------------

def test_target_defaults_to_device(mod):
    assert mod.TARGET == "device" and mod._IS_SIM is False


def test_target_simulator_flag_set(sim_mod):
    assert sim_mod.TARGET == "simulator" and sim_mod._IS_SIM is True


def test_target_rejects_unknown_value(monkeypatch):
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.setenv("IMIRROR_TARGET", "emulator")
    sys.modules.pop("imirror_mcp", None)
    with pytest.raises(SystemExit):
        importlib.import_module("imirror_mcp")


def test_unreachable_hint_is_target_specific(mod, sim_mod):
    assert "health dot" in mod._unreachable_hint()
    assert "sim-wda-up.sh" in sim_mod._unreachable_hint()


# ---- install app on a simulator (xcrun simctl) ---------------------------------

def test_install_app_uses_simctl_on_simulator(sim_mod, monkeypatch, tmp_path):
    app = tmp_path / "App.app"; app.mkdir()
    seen = {}
    def fake_run(args, **kw):
        seen["args"] = args
        class R: returncode = 0; stderr = ""
        return R()
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)
    out = sim_mod.ios_install_app(str(app))
    assert seen["args"] == ["xcrun", "simctl", "install", "booted", str(app)]
    assert "installed" in out


def test_install_app_simulator_ipa_gets_hint(sim_mod, monkeypatch, tmp_path):
    import subprocess
    ipa = tmp_path / "App.ipa"; ipa.write_bytes(b"x")
    def boom(args, **kw):
        raise subprocess.CalledProcessError(1, args, stderr="Unable to install")
    monkeypatch.setattr(sim_mod.subprocess, "run", boom)
    with pytest.raises(RuntimeError, match="won't run on a simulator"):
        sim_mod.ios_install_app(str(ipa))


def test_install_app_simulator_missing_xcrun(sim_mod, monkeypatch, tmp_path):
    app = tmp_path / "App.app"; app.mkdir()
    def gone(args, **kw):
        raise FileNotFoundError()
    monkeypatch.setattr(sim_mod.subprocess, "run", gone)
    with pytest.raises(RuntimeError, match="xcrun.*not found"):
        sim_mod.ios_install_app(str(app))


# ---- volume-button gating on a simulator ---------------------------------------

def test_press_volume_rejected_on_simulator(sim_mod, monkeypatch):
    # Must fail before any WDA call — flag it if the request layer is touched.
    monkeypatch.setattr(sim_mod, "_session_post",
                        lambda *a, **k: pytest.fail("volume hit WDA on a simulator"))
    with pytest.raises(RuntimeError, match="unavailable on a simulator"):
        sim_mod.ios_press_button("volumeUp")


def test_press_home_still_works_on_simulator(sim_mod, monkeypatch):
    calls = []
    monkeypatch.setattr(sim_mod, "_req", lambda m, p, b=None, t=None: (calls.append(p), (200, {}))[1])
    assert sim_mod.ios_press_button("home") == "pressed home"
    assert calls == ["/wda/homescreen"]


# ---- simulator-only simctl tools -----------------------------------------------

def test_simctl_strips_by_default(sim_mod, monkeypatch):
    """Every pre-existing caller (UDID/device-list output) relies on the
    default strip=True — this must keep working unchanged."""
    def fake_run(args, **kw):
        class R: returncode = 0; stdout = "  some-udid  \n"; stderr = ""
        return R()
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)
    assert sim_mod._simctl("list") == "some-udid"


def test_simctl_strip_false_preserves_whitespace(sim_mod, monkeypatch):
    """E3: strip=False must return stdout verbatim, for callers like
    ios_clipboard_get where surrounding whitespace is meaningful content."""
    raw = "  hi there \n"
    def fake_run(args, **kw):
        class R: returncode = 0; stdout = raw; stderr = ""
        return R()
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)
    assert sim_mod._simctl("pbpaste", "booted", strip=False) == raw


def _fake_simctl(mod, monkeypatch):
    seen = {"args": None}
    def fake_run(args, **kw):
        seen["args"] = args
        class R: returncode = 0; stdout = ""; stderr = ""
        return R()
    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    return seen


def test_sim_push_writes_payload_and_calls_simctl(sim_mod, monkeypatch):
    seen = _fake_simctl(sim_mod, monkeypatch)
    out = sim_mod.sim_push("com.acme.app", '{"aps": {"alert": "hi"}}')
    args = seen["args"]
    assert args[:4] == ["xcrun", "simctl", "push", "booted"]
    assert args[4] == "com.acme.app" and args[5].endswith(".apns")
    assert "pushed to com.acme.app" in out


def test_sim_push_rejects_bad_json(sim_mod, monkeypatch):
    # Never reach simctl with an invalid payload.
    monkeypatch.setattr(sim_mod.subprocess, "run",
                        lambda *a, **k: pytest.fail("simctl called with bad JSON"))
    with pytest.raises(RuntimeError, match="not valid JSON"):
        sim_mod.sim_push("com.acme.app", "{not json")


def test_sim_push_cleans_up_temp_file(sim_mod, monkeypatch):
    captured = {}
    def fake_run(args, **kw):
        captured["payload_path"] = args[5]
        class R: returncode = 0; stdout = ""; stderr = ""
        return R()
    monkeypatch.setattr(sim_mod.subprocess, "run", fake_run)
    sim_mod.sim_push("com.acme.app", "{}")
    assert not os.path.exists(captured["payload_path"])  # temp file removed


def test_sim_privacy_builds_args(sim_mod, monkeypatch):
    seen = _fake_simctl(sim_mod, monkeypatch)
    sim_mod.sim_privacy("grant", "photos", "com.acme.app")
    assert seen["args"] == ["xcrun", "simctl", "privacy", "booted",
                            "grant", "photos", "com.acme.app"]


def test_sim_privacy_omits_bundle_when_absent(sim_mod, monkeypatch):
    seen = _fake_simctl(sim_mod, monkeypatch)
    sim_mod.sim_privacy("reset", "all")
    assert seen["args"] == ["xcrun", "simctl", "privacy", "booted", "reset", "all"]


def test_sim_privacy_rejects_bad_action(sim_mod, monkeypatch):
    monkeypatch.setattr(sim_mod.subprocess, "run",
                        lambda *a, **k: pytest.fail("simctl called on bad action"))
    with pytest.raises(RuntimeError, match="grant.*revoke.*reset"):
        sim_mod.sim_privacy("allow", "photos")


def test_sim_status_bar_override_and_clear(sim_mod, monkeypatch):
    seen = _fake_simctl(sim_mod, monkeypatch)
    sim_mod.sim_status_bar(time="12:34")
    assert seen["args"][:5] == ["xcrun", "simctl", "status_bar", "booted", "override"]
    assert "12:34" in seen["args"]
    sim_mod.sim_status_bar(clear=True)
    assert seen["args"] == ["xcrun", "simctl", "status_bar", "booted", "clear"]


def test_sim_tools_require_simulator_mode(mod, monkeypatch):
    # In device mode the simctl-backed tools refuse rather than shelling out.
    monkeypatch.setattr(mod.subprocess, "run",
                        lambda *a, **k: pytest.fail("simctl invoked in device mode"))
    with pytest.raises(RuntimeError, match="IMIRROR_TARGET=simulator"):
        mod.sim_push("com.acme.app", "{}")
    with pytest.raises(RuntimeError, match="IMIRROR_TARGET=simulator"):
        mod.sim_privacy("reset", "all")


# ---- assertions ----------------------------------------------------------------

def test_assert_visible_passes_and_records_pass(mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("asserts")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")
    out = mod.ios_assert_visible("Welcome")
    assert "PASS" in out
    notes = [s for s in mod._run["steps"] if s["action"] == "note"]
    assert notes and notes[-1]["note"] == "pass"


def test_assert_visible_fails_records_fail_and_raises(mod, monkeypatch, tmp_path):
    """@_recorded is the single source of the fail step (I8 dedupe): the manual
    note="fail" call that used to live in ios_assert_visible is gone, so a
    raised failure produces exactly ONE recorded step with a structured
    fail verdict — the pre-existing PASS-note recording is untouched."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("asserts")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError, match="ASSERT FAILED"):
        mod.ios_assert_visible("Ghost", timeout_s=0)
    fails = [s for s in mod._run["steps"] if mod._step_is_fail(s)]
    assert len(fails) == 1
    assert fails[0]["action"] == "ios_assert_visible"
    assert "Ghost" in fails[0]["verdict"]["reason"]
    assert fails[0]["verdict"]["error_kind"] == "not_found"


def test_assert_not_visible_fails_records_single_verdict_step(mod, monkeypatch, tmp_path):
    """Same dedupe guarantee for ios_assert_not_visible."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("asserts")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")  # stays visible
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError, match="ASSERT FAILED"):
        mod.ios_assert_not_visible("Ghost", timeout_s=0)
    fails = [s for s in mod._run["steps"] if mod._step_is_fail(s)]
    assert len(fails) == 1
    assert fails[0]["action"] == "ios_assert_not_visible"
    assert "Ghost" in fails[0]["verdict"]["reason"]


def test_assert_visible_transient_timeout_keeps_polling(mod, monkeypatch):
    m = mod
    calls = {"i": 0}

    def flaky(*a, **k):
        calls["i"] += 1
        if calls["i"] == 1:
            raise m.MCPToolError("timed out", kind=m.ErrorKind.WEDGED)
        return "e1"
    monkeypatch.setattr(m, "_find_element", flaky)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    out = m.ios_assert_visible("Welcome", timeout_s=10)
    assert "PASS" in out
    assert calls["i"] == 2  # did not abort on the first timeout


def test_assert_visible_wedged_for_entire_budget_raises_wedged(mod, monkeypatch):
    m = mod

    def always_wedged(*a, **k):
        raise m.MCPToolError("timed out", kind=m.ErrorKind.WEDGED)
    monkeypatch.setattr(m, "_find_element", always_wedged)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    with pytest.raises(m.MCPToolError) as excinfo:
        m.ios_assert_visible("Ghost", timeout_s=0)
    assert excinfo.value.error_kind == m.ErrorKind.WEDGED


def test_assert_not_visible_transient_timeout_keeps_polling(mod, monkeypatch):
    """A timeout doesn't confirm absence — it must not be mistaken for
    'element not found' and pass the assertion prematurely."""
    m = mod
    calls = {"i": 0}

    def flaky(*a, **k):
        calls["i"] += 1
        if calls["i"] == 1:
            raise m.MCPToolError("timed out", kind=m.ErrorKind.WEDGED)
        return None
    monkeypatch.setattr(m, "_find_element", flaky)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    out = m.ios_assert_not_visible("Spinner", timeout_s=10)
    assert "PASS" in out
    assert calls["i"] == 2


def test_assert_not_visible_passes_when_absent(mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("asserts")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    out = mod.ios_assert_not_visible("Spinner")
    assert "PASS" in out
    assert mod._run["steps"][-1]["note"] == "pass"


def test_assert_failure_shows_in_report(mod, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("report")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError):
        mod.ios_assert_visible("Missing", timeout_s=0)
    report = mod.ios_finish_run(video="none")
    html = open(report, encoding="utf-8").read()
    assert "1 failures" in html and ">FAIL<" in html


# ---- find-and-tap retry --------------------------------------------------------

def test_find_and_tap_retries_until_present(mod, wda, monkeypatch):
    wda.allow("/click")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    seq = [None, "e1"]                       # absent, then appears
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: seq.pop(0))
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    out = mod.ios_find_and_tap("Continue", retries=1)
    assert "tapped" in out
    assert seq == []                         # both attempts consumed


def test_find_and_tap_transient_timeout_counts_as_used_attempt(mod, monkeypatch):
    """A timeout-class failure from _find_element must not abort the retry
    loop outright, but it still consumes one of the `retries` slots — same
    as a plain miss would."""
    m = mod
    calls = {"i": 0}

    def flaky(*a, **k):
        calls["i"] += 1
        if calls["i"] == 1:
            raise m.MCPToolError("timed out", kind=m.ErrorKind.WEDGED)
        return None  # clean miss for the remaining attempts
    monkeypatch.setattr(m, "_find_element", flaky)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError, match="No element matching"):
        m.ios_find_and_tap("Ghost", retries=2)
    assert calls["i"] == 3  # initial timeout + 2 clean-miss retries, all used


def test_find_and_tap_wedged_for_entire_budget_raises_wedged(mod, monkeypatch):
    m = mod

    def always_wedged(*a, **k):
        raise m.MCPToolError("timed out", kind=m.ErrorKind.WEDGED)
    monkeypatch.setattr(m, "_find_element", always_wedged)
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    with pytest.raises(m.MCPToolError) as excinfo:
        m.ios_find_and_tap("Ghost", retries=2)
    assert excinfo.value.error_kind == m.ErrorKind.WEDGED


# ---- review-fix coverage -------------------------------------------------------

def test_app_state_unknown_code(mod, wda):
    import json
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/wda/apps/state", (200, {"value": 9}))
    out = json.loads(mod.ios_app_state("com.apple.Preferences"))
    assert out["state"] == "unknown(9)" and out["code"] == 9


def test_clipboard_get_falls_back_on_bad_base64(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/wda/getPasteboard", (200, {"value": "a"}))   # not valid base64
    assert mod.ios_clipboard_get() == "a"


# ---- crash-safe run log + clobber warning --------------------------------------

def test_record_appends_to_steps_jsonl(mod, wda, monkeypatch, tmp_path):
    """Each step is flushed to steps.jsonl so a crash mid-run leaves a replayable
    log beside the screenshots already on disk."""
    import json
    wda.allow("/actions")
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_start_run("crashy")
    mod.ios_tap(1, 2)
    mod.ios_run_note("checkpoint", status="pass")
    log = os.path.join(mod._run["dir"], "steps.jsonl")
    lines = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
    actions = [l["action"] for l in lines]
    assert "tap" in actions and "note" in actions


def test_record_survives_unwritable_run_dir(mod, wda, monkeypatch, tmp_path):
    """A failed steps.jsonl append must never break in-memory recording."""
    wda.allow("/actions")
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_start_run("x")
    mod._run["dir"] = "/nonexistent/dir/xyz"       # force the append to fail
    mod.ios_tap(1, 2)                              # must not raise
    assert any(s["action"] == "tap" for s in mod._run["steps"])


def test_start_run_warns_when_clobbering_active_run(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}), (200, {"value": {}}))
    mod.ios_start_run("first")
    mod.ios_run_note("did work", status="pass")
    out = mod.ios_start_run("second")
    assert "WARNING" in out and "first" in out and "recording run" in out


def test_ios_bin_prefers_env_then_bundle_then_path(mod, monkeypatch):
    monkeypatch.setenv("IMIRROR_IOS_BIN", "/custom/ios")
    assert mod._ios_bin() == "/custom/ios"
    monkeypatch.delenv("IMIRROR_IOS_BIN", raising=False)
    monkeypatch.setattr(mod.os.path, "exists", lambda p: p == mod._BUNDLED_IOS)
    assert mod._ios_bin() == mod._BUNDLED_IOS
    monkeypatch.setattr(mod.os.path, "exists", lambda p: False)
    assert mod._ios_bin() == "ios"


# ---- ios_run_sequence -----------------------------------------------------------

def test_run_sequence_happy_path_all_steps_pass(mod, wda, monkeypatch):
    wda.allow("/actions", "/wda/keys")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")
    steps = [
        {"action": "tap", "x": 1, "y": 2},
        {"action": "type", "text": "hi"},
        {"action": "wait_for", "text": "Settings", "timeout_s": 1},
    ]
    out = json.loads(mod.ios_run_sequence(steps))
    assert out["ok"] is True
    assert out["ran"] == 3
    assert out["total"] == 3
    assert [s["status"] for s in out["steps"]] == ["pass", "pass", "pass"]
    assert out["steps"][0]["detail"] == "tapped (1, 2)"
    assert out["steps"][1]["detail"] == "typed 2 char(s)"
    assert "found" in out["steps"][2]["detail"]


def test_run_sequence_aborts_on_failed_gate(mod, wda, monkeypatch):
    """A failing wait_for in the middle stops the sequence — the step after it
    (a spied ios_type) must never run."""
    wda.allow("/actions")
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    monkeypatch.setattr(mod, "_fetch_source_tree", lambda: {"type": "Application", "children": []})
    spy_calls = []
    monkeypatch.setattr(mod, "ios_type", lambda **kw: spy_calls.append(kw) or "typed")
    steps = [
        {"action": "tap", "x": 1, "y": 2},
        {"action": "wait_for", "text": "Ghost", "timeout_s": 0},
        {"action": "type", "text": "should-not-run"},
    ]
    out = json.loads(mod.ios_run_sequence(steps))
    assert out["ok"] is False
    assert out["ran"] == 2
    assert out["total"] == 3
    assert len(out["steps"]) == 2
    assert out["steps"][0]["status"] == "pass"
    assert out["steps"][1]["status"] == "fail"
    assert "did not appear" in out["steps"][1]["error"]
    assert spy_calls == []                   # step 3 never executed


def test_run_sequence_prevalidates_all_steps_before_running(mod, monkeypatch):
    """A typo'd action in a later step must be caught up front, naming that
    step, before anything on the device happens."""
    spy_calls = []
    monkeypatch.setattr(mod, "ios_tap", lambda **kw: spy_calls.append(kw) or "tapped")
    steps = [{"action": "tap", "x": 1, "y": 2} for _ in range(4)]
    steps.append({"action": "not_a_real_action", "text": "x"})
    with pytest.raises(RuntimeError, match="step 5"):
        mod.ios_run_sequence(steps)
    assert spy_calls == []                   # step 1's tool was never called


def test_run_sequence_rejects_bad_param_type_before_running(mod, monkeypatch):
    spy_calls = []
    monkeypatch.setattr(mod, "ios_tap", lambda **kw: spy_calls.append(kw) or "tapped")
    steps = [{"action": "tap", "x": "not-a-number", "y": 2}]
    with pytest.raises(RuntimeError, match=r"step 1.*must be"):
        mod.ios_run_sequence(steps)
    assert spy_calls == []


def test_run_sequence_rejects_missing_required_param(mod):
    with pytest.raises(RuntimeError, match="missing required param 'text'"):
        mod.ios_run_sequence([{"action": "wait_for"}])


def test_run_sequence_rejects_unexpected_param(mod):
    with pytest.raises(RuntimeError, match="unexpected param"):
        mod.ios_run_sequence([{"action": "tap", "x": 1, "y": 2, "bogus": True}])


def test_run_sequence_rejects_empty_list(mod):
    with pytest.raises(RuntimeError, match="non-empty list"):
        mod.ios_run_sequence([])


# ---- I8: structured per-step verdicts + auto-record-on-raise -------------------
#
# @_recorded wraps the interaction/assertion tools so a raised failure during an
# active run is captured as ONE fail step carrying a structured verdict, instead
# of relying on each tool to manually log a fail note before raising. This also
# CHANGES the report rollup: a step with verdict.kind=="fail" now counts as a
# failure in addition to the legacy note=="fail" marker, which flips a report
# that used to render PASS (because the raise was never recorded) to FAIL.

def test_recorded_decorator_is_a_noop_when_no_run_is_active(mod, wda):
    """No active run -> the decorator records nothing and re-raises unchanged."""
    assert mod._run["active"] is False
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    wda.script("/actions", (500, {"value": "boom"}))
    with pytest.raises(mod.MCPToolError, match="HTTP 500"):
        mod.ios_tap(1, 2)
    assert mod._run["steps"] == []


def test_raised_tap_failure_flips_report_from_pass_to_fail(mod, wda, monkeypatch, tmp_path):
    """An otherwise-clean sequence (a passing assert) plus one raised tap
    failure must render the report as FAIL — before I8, a raised failure with
    no manual fail-note went unrecorded and the report showed PASS. This is
    the intentional, non-backward-compatible rollup change."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/session", (200, {"value": {"sessionId": "s1"}}))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("mostly-clean")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: "e1")
    mod.ios_assert_visible("Home")           # records a pass note
    wda.script("/actions", (500, {"value": "boom"}))
    with pytest.raises(mod.MCPToolError):
        mod.ios_tap(1, 2)                    # raises -> auto-recorded fail verdict
    report = mod.ios_finish_run(video="none")
    htmltext = open(report, encoding="utf-8").read()
    assert ">FAIL<" in htmltext
    assert "1 failures" in htmltext


def test_mcp_tool_error_verdict_surfaces_error_kind_and_code_in_report(mod, wda, monkeypatch, tmp_path):
    """A failure that is an MCPToolError (not a bare RuntimeError) must carry
    its error_kind/error_code both in the recorded verdict and in the
    rendered HTML, so the report differentiates failure classes."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/session", (200, {"value": {"sessionId": "s1"}}))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("wda-error")
    wda.script("/actions", (500, {"value": "boom"}))
    with pytest.raises(mod.MCPToolError):
        mod.ios_tap(1, 2)
    fail_steps = [s for s in mod._run["steps"] if mod._step_is_fail(s)]
    assert len(fail_steps) == 1
    v = fail_steps[0]["verdict"]
    assert v["error_kind"] == "wda_http"
    assert v["error_code"] == "WDA_HTTP_500"
    report = mod.ios_finish_run(video="none")
    htmltext = open(report, encoding="utf-8").read()
    assert "wda_http" in htmltext
    assert "WDA_HTTP_500" in htmltext


# ---- I7: structured error layer (MCPToolError) ----------------------------------
#
# FastMCP serializes a raised exception back to the agent as `str(e)` — bare
# attributes like `.error_kind` never reach the agent over the wire. So
# MCPToolError encodes its classification into the message text itself (a
# trailing `[kind=...]`/`[kind=... code=...]` tag), on top of exposing
# `.error_kind`/`.error_code` for in-process use (e.g. the report).

def test_mcp_tool_error_is_a_runtime_error_with_kind_in_the_tail(mod):
    err = mod.MCPToolError("something broke", kind=mod.ErrorKind.VALIDATION)
    assert isinstance(err, RuntimeError)
    assert err.error_kind == "validation"
    assert err.error_code is None
    assert str(err) == "something broke [kind=validation]"


def test_mcp_tool_error_str_includes_code_when_present(mod):
    err = mod.MCPToolError("boom", kind=mod.ErrorKind.WDA_HTTP, code="WDA_HTTP_500")
    assert err.error_code == "WDA_HTTP_500"
    assert str(err) == "boom [kind=wda_http code=WDA_HTTP_500]"


def test_mcp_tool_error_rejects_a_kind_outside_the_closed_set(mod):
    with pytest.raises(ValueError):
        mod.MCPToolError("boom", kind="bogus")


def test_wda_http_failure_raises_mcp_tool_error_and_stays_backward_compatible(mod, wda):
    """A representative WDA-HTTP failure (a 500 on a gesture POST) now raises
    MCPToolError with error_kind=='wda_http' and a WDA_HTTP_<code> code, while
    str(e) still contains the OLD human-readable substring — the same
    "HTTP 500" text every pre-existing `pytest.raises(RuntimeError, match=...)`
    test in this file already relies on."""
    wda.script("/session", (200, {"value": {"sessionId": "s1"}}))
    wda.script("/actions", (500, {"value": "boom"}))
    with pytest.raises(mod.MCPToolError, match="HTTP 500") as exc_info:
        mod._session_post("/actions", {})
    err = exc_info.value
    assert isinstance(err, RuntimeError)
    assert err.error_kind == "wda_http"
    assert err.error_code == "WDA_HTTP_500"


def test_req_unreachable_raises_mcp_tool_error_preserving_cause(mod, monkeypatch):
    def refused(*a):
        raise ConnectionRefusedError("nope")

    monkeypatch.setattr(mod, "_http", refused)
    with pytest.raises(mod.MCPToolError, match="Cannot reach WDA") as exc_info:
        mod._req("GET", "/status")
    err = exc_info.value
    assert err.error_kind == "unreachable"
    assert isinstance(err.__cause__, ConnectionRefusedError)


def test_req_wedged_timeout_raises_mcp_tool_error_preserving_cause(mod, monkeypatch):
    """I2's _req_tree detects a timeout via
    `isinstance(exc.__cause__, (socket.timeout, TimeoutError))` — converting
    this raise site to MCPToolError must not drop that chaining."""
    import socket

    def slow(*a):
        raise socket.timeout("timed out")

    monkeypatch.setattr(mod, "_http", slow)
    with pytest.raises(mod.MCPToolError, match="timed out") as exc_info:
        mod._req("GET", "/source", timeout=1)
    err = exc_info.value
    assert err.error_kind == "wedged"
    assert isinstance(err.__cause__, (socket.timeout, TimeoutError))


def test_req_tree_ride_out_still_works_with_mcp_tool_error(mod, monkeypatch):
    """I2's ride-out-a-stall logic in _req_tree keeps working now that _req
    raises MCPToolError (a RuntimeError subclass) instead of a bare
    RuntimeError: a timeout still triggers the probe-and-retry dance."""
    import socket

    calls = []
    source_attempts = {"n": 0}

    def fake_req(method, path, body=None, timeout=None):
        calls.append((method, path, timeout))
        if path == "/source":
            source_attempts["n"] += 1
            if source_attempts["n"] == 1:
                raise mod.MCPToolError(
                    f"WDA timed out after 60s on {path}. wedged.",
                    kind=mod.ErrorKind.WEDGED) from socket.timeout("timed out")
            return 200, {"value": "<XCUIElementTypeApplication/>"}
        if path == "/status":
            return 200, {"value": {}}
        raise AssertionError(f"unexpected call {method} {path}")

    monkeypatch.setattr(mod, "_req", fake_req)
    code, j = mod._req_tree("/source")
    assert (code, j) == (200, {"value": "<XCUIElementTypeApplication/>"})
    assert source_attempts["n"] == 2


def test_validation_failure_raises_mcp_tool_error(mod, monkeypatch):
    monkeypatch.setattr(mod, "_win_size", lambda: (400.0, 800.0))
    with pytest.raises(mod.MCPToolError, match="direction must be one of") as exc_info:
        mod._scroll_geom("diagonal", 50, 50, 50)
    assert exc_info.value.error_kind == "validation"


def test_not_found_scroll_to_raises_mcp_tool_error(mod, monkeypatch):
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(mod.MCPToolError, match="not found after 3 swipes") as exc_info:
        mod.ios_scroll_to("Ghost", max_swipes=3)
    assert exc_info.value.error_kind == "not_found"
