"""Live integration tests against a real WebDriverAgent.

These hit the actual device over loopback — they are the only coverage for the
real WDA wire and the _req retry/session handling that the stubbed unit tests in
test_imirror_mcp.py can't reach.

SKIPPED unless IMIRROR_LIVE=1. To run:

    1. Start the iMirror app; wait for the toolbar health dot to go green
       (WDA is then up at http://127.0.0.1:8100).
    2. IMIRROR_LIVE=1 mcp-server/.venv/bin/python -m pytest \
           mcp-server/test_integration.py -v

These tests are read-only by default (status / size / screenshot / source /
orientation read). Gesture tests that move the device are additionally gated on
IMIRROR_LIVE_MUTATE=1 so a plain live run can't disturb whatever is on screen.
"""
from __future__ import annotations

import json
import os

import pytest

pytestmark = pytest.mark.skipif(
    not os.environ.get("IMIRROR_LIVE"),
    reason="live device test; set IMIRROR_LIVE=1 with the iMirror app running",
)

MUTATE = bool(os.environ.get("IMIRROR_LIVE_MUTATE"))


@pytest.fixture(scope="module")
def m():
    import imirror_mcp
    return imirror_mcp


# ---- read-only wire coverage ---------------------------------------------------

def test_status_ready(m):
    st = json.loads(m.ios_status())
    assert st["ready"] is True, f"WDA not ready: {st}"
    assert st["ios"], "no iOS version reported"


def test_window_size(m):
    size = json.loads(m.ios_window_size())
    assert size["width"] > 0 and size["height"] > 0


def test_screenshot_is_png(m):
    img = m.ios_screenshot()
    assert img.data[:8] == b"\x89PNG\r\n\x1a\n", "screenshot is not a PNG"


def test_source_nonempty(m):
    src = m.ios_source()
    assert isinstance(src, str) and src.strip(), "empty accessibility source"


def test_orientation_read(m):
    o = json.loads(m.ios_orientation())
    assert o["orientation"] in {"PORTRAIT", "LANDSCAPE",
                                "UIA_DEVICE_ORIENTATION_LANDSCAPELEFT",
                                "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT",
                                "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN"}


def test_session_is_reused(m):
    """Two session-scoped calls must reuse one WDA session, exercising the
    create-once + cached-id path against real WDA."""
    m._session["id"] = None
    m.ios_window_size()
    first = m._session["id"]
    assert first
    m.ios_window_size()
    assert m._session["id"] == first


def test_full_recorded_run(m, tmp_path, monkeypatch):
    """End-to-end: record a couple of real screenshots and render the report
    (and a timelapse if ffmpeg is present)."""
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    m.ios_start_run("live-smoke")
    m.ios_screenshot()
    m.ios_run_note("first frame", status="info")
    m.ios_screenshot()
    report = m.ios_finish_run(video="gif")
    assert os.path.exists(report)
    html = open(report, encoding="utf-8").read()
    assert "live-smoke" in html
    assert m._run["active"] is False


# ---- gesture coverage (mutating; opt-in) ---------------------------------------

@pytest.mark.skipif(not MUTATE, reason="set IMIRROR_LIVE_MUTATE=1 to allow gestures")
def test_tap_center_does_not_error(m):
    size = json.loads(m.ios_window_size())
    m.ios_tap(size["width"] / 2, size["height"] / 2)


@pytest.mark.skipif(not MUTATE, reason="set IMIRROR_LIVE_MUTATE=1 to allow gestures")
def test_press_home(m):
    m.ios_press_button("home")
