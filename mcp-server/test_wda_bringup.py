"""Unit tests for wda_bringup.

No real device, process, or network needed: every test injects fake `popen`
and `http_get` doubles so WDABringup's chain (tunnel -> runner check/install ->
runwda -> forward -> /status poll) is exercised in isolation.
"""
from __future__ import annotations

import json

import pytest

from wda_bringup import (
    RUNNER_BUNDLE_ID,
    TEST_RUNNER_BUNDLE_ID,
    XCTEST_CONFIG,
    WDABringup,
    WDABringupError,
)

IOS_BIN = "/path/to/ios"
BASE_URL = "http://127.0.0.1:8101"
TUNNEL_AGENT = "http://127.0.0.1:60105"


class FakeProcess:
    """Stand-in for a subprocess.Popen handle.

    Long-running children (tunnel, runwda, forward) are spawned and left
    running; blocking children (apps --list, install) are spawned and then
    have `communicate()` called on them for their output. `FakePopen` decides
    which canned (returncode, stdout, stderr) a given argv gets.
    """

    def __init__(self, args, reply, **kwargs):
        self.args = args
        self.kwargs = kwargs
        self.terminated = False
        self.killed = False
        self._returncode = None
        self._reply = reply  # (returncode, stdout, stderr) or None

    def communicate(self, timeout=None):
        if self._reply is None:
            raise AssertionError(f"no fake reply scripted for {self.args}")
        rc, out, err = self._reply
        self._returncode = rc
        return out, err

    @property
    def returncode(self):
        return self._returncode

    def poll(self):
        return self._returncode

    def terminate(self):
        self.terminated = True
        self._returncode = 0

    def kill(self):
        self.killed = True
        self._returncode = -9

    def wait(self, timeout=None):
        return self._returncode


class FakePopen:
    """Records every spawn and hands back a FakeProcess.

    `script(prefix, returncode, stdout, stderr)` registers the reply used for
    any argv starting with `prefix` (e.g. `(IOS_BIN, "apps")`); argv that
    doesn't match a script and is never `communicate()`-d (long-running
    children) needs no entry. Pass a list of replies to consume them in
    order (the last one repeats for any further call).
    """

    def __init__(self):
        self.spawned: list[FakeProcess] = []
        self._scripts: dict[tuple, list[tuple]] = {}

    def script(self, prefix, returncode, stdout, stderr=""):
        self._scripts[tuple(prefix)] = [(returncode, stdout, stderr)]

    def script_sequence(self, prefix, replies):
        self._scripts[tuple(prefix)] = list(replies)

    def __call__(self, args, **kwargs):
        reply = None
        for prefix, scripted in self._scripts.items():
            if tuple(args[: len(prefix)]) == prefix:
                reply = scripted.pop(0) if len(scripted) > 1 else scripted[0]
                break
        proc = FakeProcess(args, reply, **kwargs)
        self.spawned.append(proc)
        return proc

    @property
    def argvs(self):
        return [p.args for p in self.spawned]


class ScriptedHttpGet:
    """Fake http_get(url, timeout) -> (status, body_bytes).

    `responses` maps a URL to either a single (status, body) reply reused for
    every call, or a list of replies consumed in order (last one repeats).
    """

    def __init__(self):
        self.responses: dict[str, object] = {}
        self.calls: list[str] = []

    def set(self, url, status, body):
        self.responses[url] = (status, body)

    def set_sequence(self, url, replies):
        self.responses[url] = list(replies)

    def __call__(self, url, timeout=None):
        self.calls.append(url)
        reply = self.responses.get(url)
        if reply is None:
            raise ConnectionRefusedError(f"no fake reply scripted for {url}")
        if isinstance(reply, list):
            if len(reply) > 1:
                return reply.pop(0)
            return reply[0]
        return reply


def _status_body(ready):
    return json.dumps({"value": {"ready": ready, "message": ""}}).encode()


def _tunnels_body(udid=None):
    if udid is None:
        return b"[]"
    return json.dumps([{"udid": udid, "rsdPort": 12345}]).encode()


def _apps_list_output(has_runner):
    lines = ["com.apple.mobilesafari"]
    if has_runner:
        lines.append(RUNNER_BUNDLE_ID)
    return "\n".join(lines)


class FakeClock:
    """Deterministic clock/sleep pair so polling loops run instantly in tests."""

    def __init__(self):
        self.now = 0.0
        self.sleeps: list[float] = []

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


def _make_bringup(popen, http_get, clock, *, udid=None, wda_ipa=None, **kwargs):
    kwargs.setdefault("udid", udid)
    kwargs.setdefault("wda_ipa", wda_ipa)
    kwargs.setdefault("tunnel_agent_url", TUNNEL_AGENT)
    kwargs.setdefault("base_url", BASE_URL)
    kwargs.setdefault("popen", popen)
    kwargs.setdefault("http_get", http_get)
    kwargs.setdefault("sleep", clock.sleep)
    kwargs.setdefault("log", lambda *a, **k: None)
    return WDABringup(IOS_BIN, **kwargs)


def test_coexistence_skips_bringup_when_already_up():
    popen = FakePopen()
    http_get = ScriptedHttpGet()
    http_get.set(f"{BASE_URL}/status", 200, _status_body(True))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock)
    url = bringup.ensure_up(timeout=10)

    assert url == BASE_URL
    assert popen.spawned == []


def test_happy_path_spawns_exact_chain_in_order():
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(True))
    http_get = ScriptedHttpGet()
    udid = "abc123"
    http_get.set_sequence(f"{BASE_URL}/status", [
        (200, _status_body(False)),
        (200, _status_body(False)),
        (200, _status_body(True)),
    ])
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body(udid))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock, udid=udid)
    url = bringup.ensure_up(timeout=10)

    assert url == BASE_URL
    assert popen.argvs == [
        [IOS_BIN, "tunnel", "start", "--userspace", f"--udid={udid}"],
        [IOS_BIN, "apps", "--list", f"--udid={udid}"],
        [IOS_BIN, "runwda",
         f"--bundleid={RUNNER_BUNDLE_ID}",
         f"--testrunnerbundleid={TEST_RUNNER_BUNDLE_ID}",
         f"--xctestconfig={XCTEST_CONFIG}",
         f"--udid={udid}"],
        [IOS_BIN, "forward", "8101", "8100", f"--udid={udid}"],
    ]


def test_default_base_url_and_forward_port_match_with_no_base_url_arg():
    """With no base_url kwarg, WDABringup must default to the forward port.

    Constructs WDABringup directly (not via _make_bringup, which always
    injects a base_url) to prove the class's own default of
    http://127.0.0.1:8101 is what ensure_up() actually polls and returns,
    and that it lines up with the forward command's "8101 8100" argv.
    """
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(True))
    http_get = ScriptedHttpGet()
    udid = "abc123"
    http_get.set_sequence(f"{BASE_URL}/status", [
        (200, _status_body(False)),
        (200, _status_body(False)),
        (200, _status_body(True)),
    ])
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body(udid))
    clock = FakeClock()

    bringup = WDABringup(
        IOS_BIN,
        udid=udid,
        tunnel_agent_url=TUNNEL_AGENT,
        popen=popen,
        http_get=http_get,
        sleep=clock.sleep,
        log=lambda *a, **k: None,
    )
    assert bringup.base_url == "http://127.0.0.1:8101"

    url = bringup.ensure_up(timeout=10)

    assert url == "http://127.0.0.1:8101"
    forward_call = next(a for a in popen.argvs if a[1] == "forward")
    assert forward_call == [IOS_BIN, "forward", "8101", "8100", f"--udid={udid}"]


def test_runner_missing_without_ipa_raises_and_skips_runwda_forward():
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(False))
    http_get = ScriptedHttpGet()
    http_get.set(f"{BASE_URL}/status", 200, _status_body(False))
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body("dead-beef"))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock)

    with pytest.raises(WDABringupError, match="not installed"):
        bringup.ensure_up(timeout=10)

    subcommands = [args[1] for args in popen.argvs]
    assert "runwda" not in subcommands
    assert "forward" not in subcommands


def test_runner_missing_with_ipa_installs_before_runwda():
    popen = FakePopen()
    popen.script_sequence((IOS_BIN, "apps"), [
        (0, _apps_list_output(False), ""),
        (0, _apps_list_output(True), ""),
    ])
    ipa = "/tmp/WebDriverAgent.ipa"
    popen.script((IOS_BIN, "install"), 0, "")
    http_get = ScriptedHttpGet()
    http_get.set_sequence(f"{BASE_URL}/status", [
        (200, _status_body(False)),
        (200, _status_body(True)),
    ])
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body("dead-beef"))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock, wda_ipa=ipa)
    url = bringup.ensure_up(timeout=10)

    assert url == BASE_URL
    install_calls = [a for a in popen.argvs if a[1] == "install"]
    assert install_calls == [[IOS_BIN, "install", f"--path={ipa}"]]
    install_idx = popen.argvs.index(install_calls[0])
    runwda_idx = next(i for i, a in enumerate(popen.argvs) if a[1] == "runwda")
    assert install_idx < runwda_idx


def test_status_never_ready_times_out():
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(True))
    http_get = ScriptedHttpGet()
    http_get.set(f"{BASE_URL}/status", 200, _status_body(False))
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body("dead-beef"))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock)

    with pytest.raises(WDABringupError, match="timed out|timeout"):
        bringup.ensure_up(timeout=5)

    # The clock only advances through injected sleeps, so this ran instantly
    # in wall-clock terms yet still consumed the full timeout budget.
    assert clock.now >= 5


def test_shutdown_terminates_every_spawned_child():
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(True))
    http_get = ScriptedHttpGet()
    udid = "abc123"
    http_get.set_sequence(f"{BASE_URL}/status", [
        (200, _status_body(False)),
        (200, _status_body(True)),
    ])
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body(udid))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock, udid=udid)
    bringup.ensure_up(timeout=10)
    long_running = [p for p in popen.spawned if p.args[1] in ("tunnel", "runwda", "forward")]
    assert len(long_running) == 3

    bringup.shutdown()

    assert all(p.terminated for p in long_running)


def test_ensure_up_is_idempotent_spawns_chain_once():
    popen = FakePopen()
    popen.script((IOS_BIN, "apps"), 0, _apps_list_output(True))
    http_get = ScriptedHttpGet()
    udid = "abc123"
    http_get.set_sequence(f"{BASE_URL}/status", [
        (200, _status_body(False)),
        (200, _status_body(True)),
    ])
    http_get.set(f"{TUNNEL_AGENT}/tunnels", 200, _tunnels_body(udid))
    clock = FakeClock()

    bringup = _make_bringup(popen, http_get, clock, udid=udid)

    first = bringup.ensure_up(timeout=10)
    spawned_after_first = len(popen.spawned)
    second = bringup.ensure_up(timeout=10)

    assert first == second == BASE_URL
    assert len(popen.spawned) == spawned_after_first
