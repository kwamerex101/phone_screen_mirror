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
    wda.script("/screenshot", (200, {"value": base64.b64encode(png).decode()}))
    img = mod.ios_screenshot()
    assert img.data == png


def test_screenshot_raises_when_empty(mod, wda):
    wda.script("/screenshot", (200, {"value": None}))
    with pytest.raises(RuntimeError, match="No screenshot"):
        mod.ios_screenshot()


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
    wda.script("/screenshot", *[(200, {"value": png})] * 4)
    mod.ios_start_run("capped")
    for _ in range(4):
        mod.ios_screenshot()                      # all 4 still return an image
    saved = [f for f in _os.listdir(mod._run["dir"]) if f.endswith(".png")]
    assert len(saved) == 2                        # only the first 2 persisted
    notes = [s for s in mod._run["steps"] if s["action"] == "note"]
    assert len(notes) == 1 and "cap reached" in notes[0]["detail"]
