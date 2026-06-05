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
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    m._session["id"] = None
    return m


class FakeWDA:
    """Records requests and replies from a scripted (status, body) queue per route key."""

    def __init__(self):
        self.calls: list[tuple[str, str, dict | None]] = []
        self.replies: dict[str, list[tuple[int, dict]]] = {}

    def script(self, key: str, *responses: tuple[int, dict]):
        self.replies[key] = list(responses)

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        # Prefer an exact path match, then a suffix match (e.g. ".../actions"),
        # then a plain substring — so "/session" doesn't shadow "/session/s/actions".
        for match in (lambda k: k == path, path.endswith, lambda k: k in path):
            for key in sorted(self.replies, key=len, reverse=True):
                if self.replies[key] and match(key):
                    return self.replies[key].pop(0)
        return 200, {"value": {}}


@pytest.fixture()
def wda(mod, monkeypatch):
    fake = FakeWDA()
    monkeypatch.setattr(mod, "_req", fake)
    return fake


# ---- loopback guard ------------------------------------------------------------

@pytest.mark.parametrize("target", [
    "http://10.0.0.5:8100",
    "https://example.com",
    "http://evil.localhost.attacker.com",
])
def test_refuses_non_loopback_target(monkeypatch, target):
    monkeypatch.setenv("IMIRROR_WDA", target)
    sys.modules.pop("imirror_mcp", None)
    with pytest.raises(SystemExit):
        importlib.import_module("imirror_mcp")


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
    assert out == {"ready": True, "message": "ok", "ios": "17.4", "device": "iPhone"}


def test_source_truncates_large_output(mod, wda):
    wda.script("/source", (200, {"value": "x" * 25000}))
    out = mod.ios_source()
    assert out.endswith("… (truncated)")
    assert len(out) < 25000


def test_screenshot_decodes_base64(mod, wda):
    import base64
    png = b"\x89PNG\r\n\x1a\nfake"
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    img = mod.ios_screenshot()
    assert img.data == png


def test_screenshot_raises_when_empty(mod, wda):
    wda.script("/screenshot", (200, {"value": None}))
    with pytest.raises(RuntimeError, match="No screenshot"):
        mod.ios_screenshot()


# ---- gestures ------------------------------------------------------------------

def test_tap_emits_pointer_sequence(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_tap(10, 20)
    actions = next(b for m, p, b in wda.calls if p.endswith("/actions"))
    steps = actions["actions"][0]["actions"]
    assert steps[0] == {"type": "pointerMove", "duration": 0, "x": 10, "y": 20}
    assert any(s["type"] == "pointerDown" for s in steps)
    assert any(s["type"] == "pointerUp" for s in steps)


def test_swipe_clamps_zero_duration(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_swipe(0, 0, 5, 5, duration_ms=0)
    actions = next(b for m, p, b in wda.calls if p.endswith("/actions"))
    move = actions["actions"][0]["actions"][2]
    assert move["duration"] >= 1  # never zero — WDA rejects a 0-duration drag


def test_type_sends_char_list(mod, wda):
    wda.script("/session", (200, {"value": {"sessionId": "s"}}))
    mod.ios_type("hi")
    body = next(b for m, p, b in wda.calls if p.endswith("/wda/keys"))
    assert body == {"value": ["h", "i"]}


def test_press_button_rejects_unknown(mod, wda):
    with pytest.raises(RuntimeError, match="must be one of"):
        mod.ios_press_button("power")


def test_press_home_uses_homescreen_route(mod, wda):
    mod.ios_press_button("home")
    assert any(p == "/wda/homescreen" for m, p, _ in wda.calls)


# ---- find / wait ---------------------------------------------------------------

def test_find_and_tap_escapes_quotes(mod, wda):
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
    report = mod.ios_finish_run()

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


def test_failed_note_marks_report_fail(mod, wda, monkeypatch, tmp_path):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    wda.script("/status", (200, {"value": {}}))
    mod.ios_start_run("broken")
    mod.ios_run_note("button missing", status="fail")
    report = mod.ios_finish_run()
    htmltext = open(report, encoding="utf-8").read()
    assert "1 failures" in htmltext
    assert ">FAIL<" in htmltext


def test_start_run_survives_status_failure(mod, monkeypatch, tmp_path):
    """A flaky /status during start must not abort recording."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))

    def boom(method, path, body=None):
        raise RuntimeError("status down")

    monkeypatch.setattr(mod, "_req", boom)
    mod.ios_start_run("resilient")
    assert mod._run["active"] is True
    assert mod._run["device"] is None
