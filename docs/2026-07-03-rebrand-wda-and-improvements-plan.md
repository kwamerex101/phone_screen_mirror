# Rebrand WDA + A/B/C Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand the vendored WebDriverAgent runner as "iMirror", bundle+install it without Xcode, and extend the MCP server with new automation tools + assertion/retry report features — all internal/dev-signed, no App Store.

**Architecture:** Three layers, changes isolated per layer. (1) **WDA runner** — cosmetic rebrand applied at build time, no fork. (2) **Mac app** (`Sources/iMirror`) — thread the branded bundle id through the single `runwda` call and install the bundled `.ipa` if missing. (3) **MCP server** (`mcp-server/imirror_mcp.py`) — new `ios_*` tools + assertion/retry, each unit-tested against the stubbed HTTP layer.

**Tech Stack:** Swift (AppKit/Foundation), Python 3.10+ stdlib + `mcp[cli]`, go-ios CLI, Xcode (WDA build), pytest.

**Two independent parts.** Part 1 (Swift/Xcode/packaging) and Part 2 (Python MCP) share no code and can be landed/executed separately. Part 1 requires a Mac with Xcode + a connected device + a **paid** Apple Team to verify (cannot be validated headlessly). Part 2 is fully unit-testable with no device.

**Part 1 lands as a unit.** Its three tasks are internally coupled: device bring-up only works when the *installed* runner's bundle id matches the *`runwda`* id. On a device already in use with the stock `com.facebook.*` runner, shipping any single Part-1 commit alone turns the health dot red. Execute in dependency order — **Task 1 (build the branded runner) → Task 2 (bundle + install it) → Task 3 (point `runwda` at it)** — and land all three together before testing on a real device.

## Global Constraints

Copied verbatim from the design + CLAUDE.md — every task must honor these:

- **No CI.** Before every commit touching `mcp-server/`: run `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py` and, when `imirror_mcp.py` changed, `mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`.
- **MCP server stays dependency-light:** standard library + `mcp[cli]` only. Anything heavier shells out and **degrades gracefully** (the ffmpeg precedent).
- **Unit tests need no device and no WDA** — stub the HTTP layer (`_req`). New tests must keep that property.
- **WDA is loopback-only.** Never relax the loopback guard in `imirror_mcp.py`. Never change the WDA HTTP **port 8100** or any **W3C path** — that is the wire the Mac app + MCP depend on.
- **Branding:** the name must not contain "Appium" or "Selenium". Retain WDA's on-disk `LICENSE` (BSD-3-Clause) and go-ios's MIT notice in any distribution.
- **Brand constants (this plan):** runner bundle id `com.local.imirror.WebDriverAgentRunner` → runner app id `com.local.imirror.WebDriverAgentRunner.xctrunner`; keep `PRODUCT_NAME = WebDriverAgentRunner` (so `xctestconfig` is unchanged); on-device display name `iMirror`.

## File Structure

| File | Responsibility | Part |
|---|---|---|
| `Sources/iMirror/Transport.swift` (modify) | `WDAIdentity` constants; branded `runwda` args; install-if-missing | 1 |
| `scripts/build-wda.sh` (create) | Build WDA at the pinned tag with branded bundle id / display name, emit an installable `.ipa` | 1 |
| `scripts/package.sh` (modify) | `WITH_WDA` env step copying the signed `.ipa` into the bundle + third-party license notices | 1 |
| `mcp-server/imirror_mcp.py` (modify) | New `ios_*` tools (app lifecycle, url, clipboard, install) + `ios_assert_*` + retry | 2 |
| `mcp-server/test_imirror_mcp.py` (modify) | Unit tests for every new tool/feature (stubbed HTTP) | 2 |

---

# PART 1 — Rebrand & Install (Swift / packaging)

> These tasks are verified by `swift build` (compile) and, for install/branding, on a Mac with Xcode + device + paid Team. They have no pytest gate.

### Task 1: Build script that rebrands WDA and produces a signed `.ipa`

**Files:**
- Create: `scripts/build-wda.sh`

**Interfaces:**
- Consumes: `tools/WebDriverAgent` at the pinned tag; env `DEVELOPMENT_TEAM`.
- Produces: `build/WebDriverAgent.ipa` — a signed runner whose bundle id is `com.local.imirror.WebDriverAgentRunner` (device id `…​.xctrunner`) and whose on-device display name is `iMirror`.

**Note (S3/S5):** the Runner target uses an explicit `INFOPLIST_FILE` with no `GENERATE_INFOPLIST_FILE`, so `INFOPLIST_KEY_CFBundleDisplayName` would be **ignored** — set the display name with PlistBuddy on the source `Info.plist` instead. A command-line `PRODUCT_BUNDLE_IDENTIFIER` override applies to *all* targets (WebDriverAgentLib gets the same base id); that is standard Appium practice and fine.

- [ ] **Step 1: Write the script.** Create `scripts/build-wda.sh`:

```bash
#!/usr/bin/env bash
# Build WebDriverAgent at the pinned upstream tag, rebranded to iMirror, WITHOUT
# forking: bundle id + display name are applied here so a WDA version bump is just
# a re-clone + re-run of this script. Produces a single installable .ipa.
#
# Requires: Xcode, a connected iPhone, and a PAID Apple Team (DEVELOPMENT_TEAM).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj"
PLIST="$ROOT/tools/WebDriverAgent/WebDriverAgentRunner/Info.plist"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your paid Apple Team id}"
DERIVED="$ROOT/build/wda-derived"

# Branded display name — the Runner uses an explicit Info.plist, so set it directly
# (INFOPLIST_KEY_* only applies to generated plists). Idempotent Add-or-Set.
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string iMirror' "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName iMirror' "$PLIST"

echo "==> building rebranded WebDriverAgentRunner (bundle id com.local.imirror.WebDriverAgentRunner)"
xcodebuild build-for-testing \
    -project "$PROJ" \
    -scheme WebDriverAgentRunner \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    PRODUCT_BUNDLE_IDENTIFIER=com.local.imirror.WebDriverAgentRunner \
    PRODUCT_NAME=WebDriverAgentRunner \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic

# Package the runner .app into an installable .ipa (Payload/<App> then zip).
PROD="$DERIVED/Build/Products/Debug-iphoneos"
RUNNER="$PROD/WebDriverAgentRunner-Runner.app"
[[ -d "$RUNNER" ]] || { echo "runner app not found at $RUNNER" >&2; exit 1; }
rm -rf "$ROOT/build/Payload" "$ROOT/build/WebDriverAgent.ipa"
mkdir -p "$ROOT/build/Payload"
cp -R "$RUNNER" "$ROOT/build/Payload/"
( cd "$ROOT/build" && zip -qr WebDriverAgent.ipa Payload )
rm -rf "$ROOT/build/Payload"
echo "==> ipa: $ROOT/build/WebDriverAgent.ipa"
```

- [ ] **Step 2: Make it executable.**

Run: `chmod +x scripts/build-wda.sh`

- [ ] **Step 3: (Live) build and verify id + name + ipa.** With a device + `DEVELOPMENT_TEAM` set, run `./scripts/build-wda.sh`, then:

```bash
APP="build/wda-derived/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier'  "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist"
test -f build/WebDriverAgent.ipa && echo "ipa OK"
```
Expected: `com.local.imirror.WebDriverAgentRunner.xctrunner`, then `iMirror`, then `ipa OK`.

- [ ] **Step 4: (Optional) add a branded icon.** Drop an `AppIcon` asset into the WDA Runner target's asset catalog before building. Cosmetic; skip if no artwork yet.

- [ ] **Step 5: Commit.**

```bash
git add scripts/build-wda.sh
git commit -m "build: rebrand WDA to iMirror + emit installable ipa (bundle id + display name)"
```

### Task 2: Bundle the `.ipa`, ship license notices, install it if missing

**Files:**
- Modify: `scripts/package.sh` (`WITH_WDA` copy step + third-party license notices)
- Modify: `Sources/iMirror/Transport.swift` (install the bundled `.ipa` once per launch if the runner is absent)

**Interfaces:**
- Consumes: `build/WebDriverAgent.ipa` (Task 1); go-ios `ios apps --list` / `ios install`.
- Produces: `iMirror.app/Contents/Resources/WebDriverAgent.ipa`; an `installRunnerIfMissing(bin:)` call in `startChildren()`.

- [ ] **Step 1: Copy the `.ipa` + licenses into the bundle in `package.sh`.** In `scripts/package.sh`, in the "assembling app" block (right after the `ios` binary copy, ~`:36`), add:

```bash
# Optional: bundle a pre-signed branded WDA .ipa so first run installs it with no Xcode.
if [[ -n "${WITH_WDA:-}" ]]; then
    [[ -f "$WITH_WDA" ]] || { echo "WITH_WDA=$WITH_WDA not found" >&2; exit 1; }
    cp "$WITH_WDA" "$APP/Contents/Resources/WebDriverAgent.ipa"
    echo "    bundled WDA ipa: $WITH_WDA"
fi

# Third-party license notices (WDA BSD-3-Clause, go-ios MIT) — required for redistribution.
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/tools/WebDriverAgent/LICENSE" "$APP/Contents/Resources/licenses/WebDriverAgent-LICENSE.txt" 2>/dev/null || true
cp "$ROOT/tools/go-ios/LICENSE"        "$APP/Contents/Resources/licenses/go-ios-LICENSE.txt" 2>/dev/null || true
```

Header usage note (add near the top usage comment): `WITH_WDA=build/WebDriverAgent.ipa ./scripts/package.sh`. The `.ipa` is already signed with the paid Team and is **not** re-signed with the Mac Developer ID.

- [ ] **Step 2: Install-if-missing in the Mac app.** In `Transport.swift`, add the helpers near `locateGoIOS()` and a once-per-launch guard field on the transport type. `ios install` always re-transfers (it is *not* a no-op), so this must run at most once per launch and never repeatedly on the watchdog `restartChain()` path:

```swift
private var runnerInstallAttempted = false

/// Install the bundled branded WDA .ipa once per launch, and only if the runner
/// isn't already on the device. Guarded so it never re-runs on restartChain().
private func installRunnerIfMissing(bin: URL) {
    guard !runnerInstallAttempted else { return }
    runnerInstallAttempted = true
    guard let ipa = Bundle.main.url(forResource: "WebDriverAgent", withExtension: "ipa") else {
        return  // dev builds ship no bundled ipa; runner installed via build-wda.sh/Xcode
    }
    if runnerIsInstalled(bin: bin) { return }
    let p = Process()
    p.executableURL = bin
    p.arguments = ["install", "--path=\(ipa.path)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() }
    catch { NSLog("iMirror: WDA install attempt failed: \(error.localizedDescription)") }
}

/// True if the branded runner id already appears in `ios apps --list`.
private func runnerIsInstalled(bin: URL) -> Bool {
    let p = Process()
    p.executableURL = bin
    p.arguments = ["apps", "--list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return out.contains("com.local.imirror.WebDriverAgentRunner")
    } catch { return false }
}
```

Then in `startChildren()`, inside the delayed block just before `self.wda = ManagedProcess(...)` (Task 3's edit), add:

```swift
            self.installRunnerIfMissing(bin: bin)
```

- [ ] **Step 3: Compile.**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: (Live) fresh-device install.** On a dev-trusted device without the runner installed, build with `WITH_WDA=build/WebDriverAgent.ipa ./scripts/package.sh`, launch the app, and confirm the branded runner installs and (with Task 3 landed) the health dot goes green — no Xcode. (Developer-Mode enable + first trust/Local-Network prompts still require a human.)

- [ ] **Step 5: Commit.**

```bash
git add scripts/package.sh Sources/iMirror/Transport.swift
git commit -m "feat: bundle + auto-install the branded WDA ipa once per launch (no Xcode)"
```

### Task 3: Thread the branded runner id through `runwda`

**Files:**
- Modify: `Sources/iMirror/Transport.swift` (add constants near top; change args at `:256-257`)

**Interfaces:**
- Produces: `enum WDAIdentity { static let runnerBundleId, testRunnerBundleId, xctestConfig: String }` used by `startChildren()`.

**Why:** `go-ios runwda` is currently called with no args. go-ios (`main.go:1951-1958`) falls back to the stock `com.facebook.*` defaults only when **all three** of `--bundleid`/`--testrunnerbundleid`/`--xctestconfig` are empty, and **errors out** ("either NONE … or ALL of them") if exactly one is missing — so the rebranded runner needs **all three** flags, or `runwda` fails and respawns forever on a red dot.

- [ ] **Step 1: Add the identity constants.** After the imports block (after `import Network`, ~line 20) insert:

```swift
// MARK: - Branded WDA runner identity
//
// The runner is rebranded to iMirror at build time (see scripts/build-wda.sh).
// Xcode appends ".xctrunner" to the UI-test target's bundle id when it wraps it
// into the runner .app, so go-ios is told the *suffixed* id. PRODUCT_NAME stays
// WebDriverAgentRunner, so xctestConfig keeps the default name — but go-ios still
// requires it explicitly whenever bundleid/testrunnerbundleid are set.
enum WDAIdentity {
    static let runnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let testRunnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let xctestConfig = "WebDriverAgentRunner.xctest"
}
```

- [ ] **Step 2: Pass all three flags to `runwda`.** Replace the `self.wda = ManagedProcess(...)` call at `Transport.swift:256-257` with:

```swift
            self.wda = ManagedProcess(
                binary: bin,
                args: ["runwda",
                       "--bundleid=\(WDAIdentity.runnerBundleId)",
                       "--testrunnerbundleid=\(WDAIdentity.testRunnerBundleId)",
                       "--xctestconfig=\(WDAIdentity.xctestConfig)"],
                label: "runwda", restartDelay: 6, workDir: self.workDir)
```

- [ ] **Step 3: Compile.**

Run: `swift build`
Expected: build succeeds with no errors.

- [ ] **Step 4: (Live, with the branded runner installed from Tasks 1–2) confirm bring-up.** Launch iMirror; the toolbar health dot reaches green within ~30 s (go-ios launches the renamed runner via the matching id).

- [ ] **Step 5: Commit.**

```bash
git add Sources/iMirror/Transport.swift
git commit -m "feat(transport): launch runwda with the branded iMirror runner id (all three flags)"
```

---

# PART 2 — MCP features (Python, TDD)

> Every task: write the failing test, run it red, implement, run it green, `py_compile`, commit. Tests stub `_req` via the existing `FakeWDA` fixture — no device.

### Task 4: App-lifecycle tools (`launch` / `terminate` / `activate` / `state`)

**Files:**
- Modify: `mcp-server/imirror_mcp.py` (add four tools after `ios_orientation`, ~`:509`)
- Test: `mcp-server/test_imirror_mcp.py`

**Interfaces:**
- Consumes: `_session_post(subpath, body)`, `_record(action, detail)`.
- Produces: `ios_launch_app(bundle_id)`, `ios_terminate_app(bundle_id)`, `ios_activate_app(bundle_id)`, `ios_app_state(bundle_id)` (returns JSON `{"bundleId","state","code"}`).

- [ ] **Step 1: Write the failing tests.** Append to `test_imirror_mcp.py`:

```python
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
```

- [ ] **Step 2: Run them red.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k "launch_app or terminate_app or activate_app or app_state" -v`
Expected: FAIL — `AttributeError: module 'imirror_mcp' has no attribute 'ios_launch_app'`.

- [ ] **Step 3: Implement.** Insert after `ios_orientation` (before the `# ---- Test-run recording` banner, ~`:510`):

```python
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
```

- [ ] **Step 4: Run them green + compile.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k "launch_app or terminate_app or activate_app or app_state" -v && mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`
Expected: PASS; no compile error.

- [ ] **Step 5: Commit.**

```bash
git add mcp-server/imirror_mcp.py mcp-server/test_imirror_mcp.py
git commit -m "feat(mcp): app lifecycle tools (launch/terminate/activate/state)"
```

### Task 5: `ios_open_url` + clipboard get/set

**Files:**
- Modify: `mcp-server/imirror_mcp.py` (three tools after `ios_app_state`)
- Test: `mcp-server/test_imirror_mcp.py`

**Interfaces:**
- Consumes: `_session_post`, `base64` (already imported), `_record`.
- Produces: `ios_open_url(url)`, `ios_clipboard_set(text)`, `ios_clipboard_get() -> str`.

- [ ] **Step 1: Write the failing tests.** Append:

```python
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
```

- [ ] **Step 2: Run them red.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k "open_url or clipboard" -v`
Expected: FAIL — `ios_open_url` not found.

- [ ] **Step 3: Implement.** Insert after `ios_app_state`:

```python
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
```

- [ ] **Step 4: Run them green + compile.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k "open_url or clipboard" -v && mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add mcp-server/imirror_mcp.py mcp-server/test_imirror_mcp.py
git commit -m "feat(mcp): open-url + clipboard get/set tools"
```

### Task 6: `ios_install_app` (shell out to go-ios, degrade gracefully)

**Files:**
- Modify: `mcp-server/imirror_mcp.py` (helper `_ios_bin()` + tool)
- Test: `mcp-server/test_imirror_mcp.py`

**Interfaces:**
- Consumes: `subprocess` (already imported), env `IMIRROR_IOS_BIN`.
- Produces: `ios_install_app(path) -> str`; `_ios_bin() -> str`.

- [ ] **Step 1: Write the failing tests.** Append:

```python
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
```

- [ ] **Step 2: Run them red.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k install_app -v`
Expected: FAIL — `ios_install_app` not found.

- [ ] **Step 3: Implement.** Insert after `ios_clipboard_get`:

```python
def _ios_bin() -> str:
    """Path to the go-ios `ios` binary (bundled by the app, or on PATH)."""
    return os.environ.get("IMIRROR_IOS_BIN", "ios")


@mcp.tool()
def ios_install_app(path: str) -> str:
    """Install an .ipa (or .app) on the device via the bundled go-ios.

    Requires the go-ios `ios` binary on PATH or IMIRROR_IOS_BIN, and a signature
    already valid for the device. Shell-out (not WDA); degrades with a clear error
    if go-ios is absent.
    """
    if not os.path.exists(path):
        raise RuntimeError(f"No such file: {path}")
    try:
        subprocess.run([_ios_bin(), "install", f"--path={path}"],
                       check=True, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise RuntimeError("go-ios 'ios' binary not found (set IMIRROR_IOS_BIN).") from e
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"install failed: {(e.stderr or '').strip() or e}") from e
    _record("install_app", path)
    return f"installed {os.path.basename(path)}"
```

- [ ] **Step 4: Run them green + compile.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k install_app -v && mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add mcp-server/imirror_mcp.py mcp-server/test_imirror_mcp.py
git commit -m "feat(mcp): ios_install_app via bundled go-ios"
```

### Task 7: Assertion tools (`ios_assert_visible` / `ios_assert_not_visible`)

**Files:**
- Modify: `mcp-server/imirror_mcp.py` (two tools after `ios_finish_run`, ~`:607`)
- Test: `mcp-server/test_imirror_mcp.py`

**Interfaces:**
- Consumes: `_find_element(text)`, `_record(action, detail, note)`, `time`.
- Produces: `ios_assert_visible(text, timeout_s=5.0)`, `ios_assert_not_visible(text, timeout_s=3.0)`.

**Design note:** the report tallies pass/fail on steps where `action == "note"` (`_render_report:773`, `_split_sections:763`). Assertions therefore record with **`action="note"`** so they flow into the donut, per-section rollup, TOC status, and failures panel — exactly like `ios_run_note`.

- [ ] **Step 1: Write the failing tests.** Append:

```python
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
```

- [ ] **Step 2: Run them red.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k assert -v`
Expected: FAIL — `ios_assert_visible` not found.

- [ ] **Step 3: Implement.** Insert immediately after `ios_finish_run` (before `_make_timelapse`, ~`:608`):

```python
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
```

- [ ] **Step 4: Run them green + full suite + compile.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -v && mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`
Expected: PASS (all tests, including the pre-existing ones).

- [ ] **Step 5: Commit.**

```bash
git add mcp-server/imirror_mcp.py mcp-server/test_imirror_mcp.py
git commit -m "feat(mcp): ios_assert_visible / ios_assert_not_visible with report rollup"
```

### Task 8: Flaky-retry on `ios_find_and_tap`

**Files:**
- Modify: `mcp-server/imirror_mcp.py` (`ios_find_and_tap`, `:449-464`)
- Test: `mcp-server/test_imirror_mcp.py`

**Interfaces:**
- Produces: `ios_find_and_tap(text, retries=0, retry_delay_s=0.5)` — default `retries=0` preserves current behavior.

- [ ] **Step 1: Write the failing test.** Append:

```python
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
```

- [ ] **Step 2: Run it red.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k find_and_tap_retries -v`
Expected: FAIL — `ios_find_and_tap()` got an unexpected keyword argument `retries` (or the element-absent path raises without retrying).

- [ ] **Step 3: Implement.** Replace the body of `ios_find_and_tap` (`:449-464`) with:

```python
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
```

- [ ] **Step 4: Run the new test + the existing find/tap tests + compile.**

Run: `mcp-server/.venv/bin/python -m pytest mcp-server/test_imirror_mcp.py -k "find_and_tap" -v && mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py`
Expected: PASS — including the pre-existing `test_find_and_tap_escapes_quotes`, `test_find_and_tap_raises_when_absent`, `test_find_and_tap_raises_on_click_error`.

- [ ] **Step 5: Commit.**

```bash
git add mcp-server/imirror_mcp.py mcp-server/test_imirror_mcp.py
git commit -m "feat(mcp): retry option on ios_find_and_tap for slow-appearing elements"
```

---

## Deferred (not in this plan)

- **Theme C metrics (CPU/mem/fps):** requires a spike to confirm the pinned go-ios's metric interface before writing correct code. The design flags it as best-effort/verify; do it as a follow-up once the go-ios command surface is confirmed.
- **Embed real mp4 recording** in reports (the ffmpeg timelapse already covers the video need; embedding the Mac-app recording needs cross-process path plumbing).
- OCR/image-find, network-condition simulation, full network-request logs, multi-device, companion app — all explicitly out of scope per the design.

## Self-review notes

- **Spec coverage:** Rebrand (Component 1) → Tasks 1 (build/rebrand) + 3 (`runwda` id); Theme A install/polish (Component 2) → Tasks 1–2; Theme B tools (Component 3, OCR dropped) → Tasks 4–6; Theme C assertions+retry (Component 4) → Tasks 7–8; metrics/video explicitly deferred above.
- **`runwda` flags (verified `main.go:1951-1958`):** go-ios needs NONE or ALL of `--bundleid`/`--testrunnerbundleid`/`--xctestconfig`; Task 3 passes all three.
- **Report-tally correctness:** assertions record `action="note"` so they count in `_render_report`/`_split_sections` (verified against `imirror_mcp.py:763,773`). They render as "note" steps (benign; the detail prefix says "assert …").
- **Install safety:** `installRunnerIfMissing` is guarded once-per-launch and checks `ios apps --list` first — it must not re-run on the `restartChain()` watchdog path (`ios install` always re-transfers).
- **Backward compatibility:** `ios_find_and_tap` keeps `retries=0` default; existing find/tap tests still pass (asserted in Task 8 Step 4).
- **Dependency-light:** only `subprocess`/`base64`/`time` (all already imported); go-ios install degrades with a clear error.
- **Licensing:** Task 2 ships WDA (BSD-3) + go-ios (MIT) license notices in the bundle, per the design checklist.

## Fable 5 review — applied fixes

Reviewed against the actual repo; corrections folded in:
- **B1 (blocker):** Task 3 now passes all three `runwda` flags (was two → go-ios would error and loop red).
- **B2 (blocker):** Task 1 now packages the runner into `build/WebDriverAgent.ipa` (Task 2's input previously had no producer).
- **S1:** Part 1 reordered (build → bundle → `runwda`) with a "lands as a unit" note.
- **S2:** install helper guarded once-per-launch + `ios apps --list` check; no longer reinstalls on every watchdog recovery.
- **S3:** display name set via PlistBuddy on the explicit `Info.plist` (INFOPLIST_KEY would be ignored); verification checks it.
- **S4:** added `test_activate_app_posts_bundle_id` and included it in the `-k` filters.
- **N3/N4/S5:** `WITH_WDA` naming consistent; license-notice step added; bundle-id-applies-to-all-targets noted.
