"""Unit tests for imirror_mcp.

No real device or WebDriverAgent needed: every test stubs the HTTP layer
(`_req`) so we exercise the server's own logic — session handling, retry on
stale 404, predicate building, gesture payloads, wait/poll, and the loopback
guard — in isolation.
"""
from __future__ import annotations

import importlib
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


def test_source_truncates_large_output(mod, wda):
    wda.script("/source", (200, {"value": "x" * 25000}))
    out = mod.ios_source()
    assert out.endswith("… (truncated)")
    assert len(out) < 25000


def test_source_uses_long_timeout(mod, wda):
    """A heavy accessibility tree can take >15s; ios_source must not use the
    default short timeout (regression: real device timed out at 15s)."""
    wda.script("/source", (200, {"value": "<XCUIElementTypeApplication/>"}))
    mod.ios_source()
    src_idx = next(i for i, (_, p, _) in enumerate(wda.calls) if p == "/source")
    assert wda.timeouts[src_idx] is not None and wda.timeouts[src_idx] >= 60


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


def test_img_kind_sniffs_magic_bytes(mod):
    assert mod._img_kind(b"\xff\xd8\xff\xe0stuff") == ("jpeg", ".jpg")
    assert mod._img_kind(b"\x89PNG\r\n\x1a\nfake") == ("png", ".png")
    assert mod._img_kind(b"garbage") == ("png", ".png")


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
    with pytest.raises(RuntimeError, match="did not appear"):
        m.ios_wait_for("Ghost", timeout_s=0)


def test_wait_for_polls_then_succeeds(mod, monkeypatch):
    m = mod
    seq = [None, None, "e1"]
    monkeypatch.setattr(m, "_find_element", lambda *a, **k: seq.pop(0))
    monkeypatch.setattr(m.time, "sleep", lambda *_: None)
    out = m.ios_wait_for("Later", timeout_s=10)
    assert "3 check(s)" in out


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
               (200, {"value": base64.b64encode(b"\x89PNGx").decode()}))
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
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("r")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod, "_scroll_once", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError):
        mod.ios_scroll_to("Ghost", max_swipes=2)
    fails = [s for s in mod._run["steps"] if s["action"] == "note" and s["note"] == "fail"]
    assert fails and "NOT found" in fails[0]["detail"]


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
    png = base64.b64encode(b"\x89PNGfake").decode()
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
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    monkeypatch.setattr(mod, "_req", lambda *a, **k: (200, {"value": {}}))
    mod.ios_start_run("asserts")
    monkeypatch.setattr(mod, "_find_element", lambda *a, **k: None)
    monkeypatch.setattr(mod.time, "sleep", lambda *_: None)
    with pytest.raises(RuntimeError, match="ASSERT FAILED"):
        mod.ios_assert_visible("Ghost", timeout_s=0)
    fails = [s for s in mod._run["steps"] if s["action"] == "note" and s["note"] == "fail"]
    assert fails and "Ghost" in fails[0]["detail"]


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
