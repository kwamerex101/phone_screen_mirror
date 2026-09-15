"""wda_bringup - bring WebDriverAgent up on a real iPhone via go-ios, headless.

Replicates, in Python, the child-process chain the iMirror macOS app runs
itself (see Sources/iMirror/Transport.swift): a userspace RSD tunnel, an
install of the branded WebDriverAgentRunner if it is missing, runwda, and a
USB port forward. This lets the MCP server bring WDA up on its own, with no
GUI app running, when a caller opts in via IMIRROR_AUTOWDA.

Every subprocess spawn goes through an injectable `popen` factory and every
HTTP poll through an injectable `http_get`, so `WDABringup` can be exercised
in tests with no device, no go-ios binary, and no network (see
test_wda_bringup.py).
"""
from __future__ import annotations

import atexit
import json
import signal
import subprocess
import time
import urllib.error
import urllib.request
from typing import Callable

# Matches Sources/iMirror/Transport.swift's WDAIdentity. The runner is
# rebranded to iMirror at build time (scripts/build-wda.sh); Xcode appends
# ".xctrunner" to the UI-test target's bundle id when it wraps it into the
# runner .app, so go-ios is told that suffixed id for both flags.
RUNNER_BUNDLE_ID = "com.local.imirror.WebDriverAgentRunner.xctrunner"
TEST_RUNNER_BUNDLE_ID = "com.local.imirror.WebDriverAgentRunner.xctrunner"
XCTEST_CONFIG = "WebDriverAgentRunner.xctest"

_POLL_INTERVAL = 0.5


class WDABringupError(RuntimeError):
    """Raised when WDABringup cannot get WebDriverAgent into a ready state."""


def _default_http_get(url: str, timeout: float | None = None) -> tuple[int, bytes]:
    """Plain stdlib GET. Returns (status_code, body_bytes).

    Never raises for a non-2xx response: an HTTPError still carries a status
    and body, and the caller treats anything but 200 as "not ready yet".
    A connection failure (device not there, tunnel not up) is left to raise,
    and callers that poll wrap this in their own try/except.
    """
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _default_log(message: str) -> None:
    print(f"[wda_bringup] {message}")


class WDABringup:
    """Brings a real iPhone's WebDriverAgent up over USB via go-ios, or
    reuses one that is already running (e.g. started by the iMirror app).

    Coexistence: if `base_url`/status already reports ready when `ensure_up`
    is called, nothing is spawned and that URL is returned as-is.

    Every process spawn goes through the injected `popen` and every HTTP
    poll through the injected `http_get`, so this class never touches the
    network or the OS process table except through those two seams.
    """

    def __init__(self, ios_bin: str, *, udid: str | None = None,
                 wda_ipa: str | None = None,
                 device_wda_port: int = 8100, host_forward_port: int = 8101,
                 tunnel_agent_url: str = "http://127.0.0.1:60105",
                 base_url: str | None = None,
                 popen: Callable[..., subprocess.Popen] = subprocess.Popen,
                 http_get: Callable[..., tuple[int, bytes]] = _default_http_get,
                 sleep: Callable[[float], None] = time.sleep,
                 log: Callable[[str], None] = _default_log):
        self._ios_bin = ios_bin
        self._udid = udid
        self._wda_ipa = wda_ipa
        self._device_wda_port = device_wda_port
        self._host_forward_port = host_forward_port
        self._tunnel_agent_url = tunnel_agent_url.rstrip("/")
        self.base_url = (base_url or f"http://127.0.0.1:{host_forward_port}").rstrip("/")
        self._popen = popen
        self._http_get = http_get
        self._sleep = sleep
        self._log = log

        self._children: list[subprocess.Popen] = []
        self._up = False
        self._teardown_registered = False

    # -- public API -----------------------------------------------------

    def ensure_up(self, timeout: float = 60.0) -> str:
        """Bring WDA up if it is not already, and return its base URL.

        Idempotent: once up, a later call returns the same URL and spawns
        nothing new.
        """
        if self._up:
            return self.base_url

        if self._status_ready():
            self._log(f"WDA already answering at {self.base_url}; leaving it as-is")
            self._up = True
            return self.base_url

        self._start_tunnel()
        self._poll_until(self._tunnel_ready, timeout,
                          "timed out waiting for the go-ios userspace tunnel to come up")

        if not self._runner_present():
            if not self._wda_ipa:
                raise WDABringupError(
                    "WebDriverAgentRunner is not installed; install it or set "
                    "IMIRROR_WDA_IPA to a WebDriverAgent.ipa so it can be "
                    "installed automatically.")
            self._install_runner()
            if not self._runner_present():
                raise WDABringupError(
                    "WebDriverAgentRunner install did not take; check the "
                    "ipa's code signature and try again.")

        self._start_runwda()
        self._start_forward()
        self._poll_until(self._status_ready, timeout,
                          "timed out waiting for WebDriverAgent to report ready")

        self._register_teardown()
        self._up = True
        return self.base_url

    def shutdown(self) -> None:
        """Terminate every long-running child process this instance started."""
        for proc in self._children:
            if proc.poll() is None:
                proc.terminate()
        for proc in self._children:
            try:
                proc.wait(timeout=3)
            except Exception:
                pass
            if proc.poll() is None:
                proc.kill()
        self._children = []
        self._sweep_stray_processes()
        self._up = False

    # -- tunnel -----------------------------------------------------------

    def _start_tunnel(self) -> None:
        args = [self._ios_bin, "tunnel", "start", "--userspace"] + self._udid_args()
        self._log(f"starting: {' '.join(args)}")
        self._children.append(self._popen(args))

    def _tunnel_ready(self) -> bool:
        """A non-empty /tunnels list means a device tunnel actually exists,
        not just that the tunnel agent process is up (see Transport.swift's
        tunnelReady, which explains why /ready is too early a signal)."""
        status, body = self._safe_get(f"{self._tunnel_agent_url}/tunnels")
        if status != 200:
            return False
        try:
            tunnels = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            return False
        if not tunnels:
            return False
        if self._udid:
            return any(t.get("udid") == self._udid for t in tunnels)
        return True

    # -- runner check / install -------------------------------------------

    def _runner_present(self) -> bool:
        args = [self._ios_bin, "apps", "--list"] + self._udid_args()
        out = self._run_and_capture(args)
        return RUNNER_BUNDLE_ID in out

    def _install_runner(self) -> None:
        self._log(f"WebDriverAgentRunner missing; installing {self._wda_ipa}")
        args = [self._ios_bin, "install", f"--path={self._wda_ipa}"]
        self._run_and_capture(args)

    def _run_and_capture(self, args: list[str]) -> str:
        proc = self._popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _err = proc.communicate()
        return out or ""

    # -- runwda / forward ---------------------------------------------------

    def _start_runwda(self) -> None:
        args = [self._ios_bin, "runwda",
                f"--bundleid={RUNNER_BUNDLE_ID}",
                f"--testrunnerbundleid={TEST_RUNNER_BUNDLE_ID}",
                f"--xctestconfig={XCTEST_CONFIG}"] + self._udid_args()
        self._log(f"starting: {' '.join(args)}")
        self._children.append(self._popen(args))

    def _start_forward(self) -> None:
        args = [self._ios_bin, "forward",
                str(self._host_forward_port), str(self._device_wda_port)] + self._udid_args()
        self._log(f"starting: {' '.join(args)}")
        self._children.append(self._popen(args))

    # -- status -------------------------------------------------------------

    def _status_ready(self) -> bool:
        status, body = self._safe_get(f"{self.base_url}/status")
        if status != 200:
            return False
        try:
            data = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            return False
        return bool(data.get("value", {}).get("ready"))

    # -- shared helpers -------------------------------------------------------

    def _udid_args(self) -> list[str]:
        return [f"--udid={self._udid}"] if self._udid else []

    def _safe_get(self, url: str, timeout: float = 2.0) -> tuple[int, bytes]:
        try:
            return self._http_get(url, timeout=timeout)
        except Exception:
            return 0, b""

    def _poll_until(self, check: Callable[[], bool], timeout: float,
                     timeout_message: str) -> None:
        elapsed = 0.0
        while not check():
            if elapsed >= timeout:
                raise WDABringupError(timeout_message)
            self._sleep(_POLL_INTERVAL)
            elapsed += _POLL_INTERVAL

    def _sweep_stray_processes(self) -> None:
        """Best-effort cleanup of any go-ios child left behind, mirroring
        Transport.swift's sweepStrayProcesses. Fire-and-forget: never blocks
        shutdown and never raises."""
        pattern = f"{self._ios_bin} (tunnel|runwda|forward)"
        try:
            self._popen(["pkill", "-f", pattern],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    # -- teardown registration ------------------------------------------------

    def _register_teardown(self) -> None:
        if self._teardown_registered:
            return
        self._teardown_registered = True
        atexit.register(self.shutdown)
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                previous = signal.getsignal(sig)
            except ValueError:
                continue  # not the main thread; signal handlers can't be set here

            def _handler(signum, frame, _previous=previous):
                self.shutdown()
                if callable(_previous) and _previous not in (signal.SIG_DFL, signal.SIG_IGN):
                    _previous(signum, frame)
                else:
                    raise SystemExit(128 + signum)

            try:
                signal.signal(sig, _handler)
            except (ValueError, OSError):
                pass
