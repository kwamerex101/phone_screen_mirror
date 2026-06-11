<div align="center">

# iMirror

![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white)

**Mirror a USB-connected iPhone to a macOS window and control it from the Mac — while the phone stays physically usable.**

</div>

Unlike Apple's "iPhone Mirroring", the phone is never locked. iMirror is two
tools in one:

1. **A desktop mirror + remote control** — watch and drive the phone from a Mac
   window.
2. **An agent-driven test rig for real devices** — the bundled
   [MCP server](mcp-server/) lets an AI agent (e.g. Claude) run test flows on the
   physical phone — tap, scroll, type, assert by visible text — and emit a
   self-contained HTML report with screenshots, pass/fail sections, and a
   timelapse. Neither Appium nor Maestro packages real-device evidence reports
   this way; in practice this is the most distinctive part of the project.

Features:

- **Video + audio** — live mirror, optional phone-audio playback (muted by
  default), record to mp4, full-resolution PNG screenshots.
- **Control** — tap, drag, two-finger trackpad scroll (with flick detection),
  type, Home, driven from the preview.
- **Agent control + test reports** — 17 `ios_*` MCP tools, opt-in run recording,
  cover/TOC/infographics HTML reports (see [MCP server](#mcp-server-drive-the-phone-from-claude)).
- **Self-managed** — launch the app and it brings the control channel up itself
  (no Xcode, no sudo, no terminal). A toolbar health dot + auto-reconnect.

The app code is dependency-free Swift (AppKit, AVFoundation, CoreImage,
CoreMediaIO, Network). Control rides on two vetted, source-built tools —
[`go-ios`](https://github.com/danielpaulus/go-ios) and
[`WebDriverAgent`](https://github.com/appium/WebDriverAgent) — that live under
`tools/` (gitignored) and are bundled into the `.app` at package time.

## Screenshots

iPhone mirrored live to the Mac. The capture follows the phone's **physical
orientation**, and tap/drag coordinates adapt automatically — verified in both
portrait and landscape.

## Requirements

Fair warning: **setup is developer-grade**. The app itself is launch-and-go, but
the one-time WebDriverAgent install needs Xcode, a signing identity, and a USB
cable — this is an Apple platform constraint, not a choice. After that one-time
step, day-to-day use is just opening the app.

- macOS 14+ (built/tested on macOS 26, Xcode 26, Swift 6.3)
- An iPhone connected by USB, unlocked, "Trust This Computer" accepted, with
  **Developer Mode** on (Settings → Privacy & Security → Developer Mode)
- A **paid Apple Developer account** to sign WebDriverAgent (a free account works
  but its cert expires every 7 days)
- For building the `go-ios` helper from source: **Go** and **osv-scanner**
  (`brew install go osv-scanner`)

## Set up `tools/` (one-time)

`tools/` is not committed (it holds large third-party clones). Populate it at the
audited, pinned versions — see [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the
exact commits and scan results:

```bash
mkdir -p tools && cd tools
git clone --depth 1 --branch v1.1.0 https://github.com/danielpaulus/go-ios
git clone --depth 1 --branch v9.9.0 https://github.com/appium/WebDriverAgent

# (optional but recommended) scan before building:
osv-scanner scan source -r --no-ignore --include-git-root go-ios
osv-scanner scan source -r --no-ignore --include-git-root WebDriverAgent

# build the go-ios CLI from source, patching vulnerable transitive deps:
cd go-ios
GOWORK=off go get golang.org/x/crypto@v0.52.0 golang.org/x/net@v0.55.0 \
                  github.com/quic-go/quic-go@v0.49.1
GOWORK=off go mod tidy
GOWORK=off go build -o bin/ios .
```

Then install WebDriverAgent on the device once (Xcode):

1. Open `tools/WebDriverAgent/WebDriverAgent.xcodeproj`.
2. Scheme **WebDriverAgentRunner**, destination = your iPhone.
3. For targets **WebDriverAgentRunner** + **WebDriverAgentLib**: Signing &
   Capabilities → *Automatically manage signing* → select your paid Team.
4. **Product → Test (⌘U)** — builds, signs, installs WDA; trust the developer
   cert on the phone when prompted. You can stop the test afterward — the app
   relaunches WDA itself (see below).

   Note: on newer Xcode, WDA's vendored XCTest headers trip clang's
   `-Wreserved-identifier`. Add `-Wno-reserved-identifier` to `WARNING_CFLAGS`
   in `Configurations/IOSSettings.xcconfig` + the `project.pbxproj` if the build
   fails on that.

## Run

```bash
./scripts/run.sh            # debug build → bundle (with go-ios + icon) → launch
./scripts/run.sh release    # optimized build
```

First launch prompts for **Camera** permission (the iOS screen-capture device is
gated by the camera privilege — iMirror does not use the Mac camera). Grant it,
pick the iPhone, and the toolbar health dot turns green within ~30 s. Flip the
**Control** switch to drive the phone; **⤓ Shot** saves a screenshot; **● Record**
captures mp4.

## How it works

**Video.** `kCMIOHardwarePropertyAllowScreenCaptureDevices = 1` makes plugged-in
iPhones appear as `AVCaptureDevice`s; `DiscoverySession([.external], .muxed)`
finds the iPhone; `AVCaptureSession` + a preview layer render it;
`AVCaptureMovieFileOutput` records (no re-encode) and a video-data output feeds
full-res screenshots. The capture is passive — the phone is never locked.

**Control.** Clicks/keys on the preview are transformed to device points and sent
to WebDriverAgent (XCUITest) as W3C pointer/key actions. Control is off by
default and armed by the switch (only while the health dot is green).

Scrolling is two-finger trackpad scroll (or click-drag): the gesture is mapped to
a WDA swipe over the same path, respecting the system Natural-Scroll direction. A
fast release is detected as a *flick* and sent as one quick swipe so the scroll
jumps rather than crawling 1:1. Note WDA can't trigger iOS inertial momentum — a
swipe moves content ~1:1 and stops on release — so distance comes from a longer
swipe, not a faster one (the macOS momentum tail is intentionally dropped, since
the phone can't coast). The XCUITest "wait for quiescence" idle-wait is disabled
on session creation, which removes the multi-second stall that previously hit the
first swipe of a session.

**Self-managed transport.** On launch the app spawns `go-ios` as child processes
and runs an in-process loopback relay:

```
iMirror (CFNetwork) → 127.0.0.1:8100 (relay) → :8101 (ios forward) --USB--> WDA
   ios tunnel start --userspace   iOS 17+ RSD tunnel (userspace = no root)
   ios runwda                     launches WebDriverAgent (no Xcode)
   ios forward 8101 8100          USB relay of WDA's port
```

Children run with a writable working dir (`~/Library/Application Support/iMirror`),
auto-restart on crash, and a watchdog does a full-chain reset if WDA hangs
(rate-limited so it can't wedge `testmanagerd`). Before each bring-up the app also
sweeps any stray go-ios children left by a previously crashed instance — most
often a tunnel reparented to `launchd` that would otherwise keep holding the
device's RSD state and port 60105 and pin the dot on red. The health dot shows
**green**/**yellow**/**red** and the app auto-reconnects.

Why the relay: `go-ios forward` alone is incompatible with macOS CFNetwork
(URLSession gets `NSURLErrorNetworkConnectionLost` -1005, while plain socket
clients work). The loopback relay normalises the connection, keeping the USB
transport and loopback-only security. If the bundled go-ios is ever missing,
`scripts/wda-up.sh` + `scripts/wda_relay.py` are a manual fallback.

## Dependency security policy

Supply-chain risk is treated as a first-class constraint:

- **The app itself has zero third-party packages** — Apple system frameworks only.
- **The two control tools are vetted before use** (see [SECURITY-AUDIT.md](SECURITY-AUDIT.md)):
  pinned to exact tags + verified commits, scanned with `osv-scanner`, vulnerable
  transitive deps patched, and **built from source** (no prebuilt-binary trust).
- **No `curl | sh`, no unsigned binaries.** Anything executable is subject to
  macOS Gatekeeper / notarization.
- WebDriverAgent has no auth on the wire, so it is reached over **loopback only**;
  the go-ios host identity (`selfIdentity.plist`) is gitignored.

## MCP server (drive the phone from Claude)

[`mcp-server/`](mcp-server/) turns the phone into an **agent-driven test rig**.
An MCP client (e.g. Claude) controls the device directly — screenshot, tap,
swipe, scroll (by direction or until an element is visible), type, hardware
buttons, find-and-tap / wait-for by text, orientation, accessibility source —
17 tools in all.

The standout is **test-run recording**: the agent starts a run, names the
sections it tests, asserts checkpoints as pass/fail, and finishes with a
self-contained HTML report — cover page with verdict, pass/fail donut and stat
cards, a failures-first panel, a "what was tested" table of contents, every
step with embedded screenshots, and a looping timelapse of the whole run.
Ask Claude to "test the login flow and give me a report" and you get reviewable
evidence from a *real* device, not a simulator.

It talks to the same loopback WDA the app brings up (run the app + green dot
first). See [mcp-server/README.md](mcp-server/README.md) for the tool table and
report walkthrough.

## Packaging / distribution

```bash
swift scripts/make_icon.swift   # regenerate Resources/AppIcon.icns (one-off)
./scripts/package.sh            # build a DMG (build/iMirror.dmg)
```

`package.sh` builds the release `.app` (bundling go-ios + icon) and makes a DMG.
With a **Developer ID Application** certificate it signs with hardened runtime +
the camera entitlement (and signs the nested go-ios), ready for notarization:

```bash
# one-time:
xcrun notarytool store-credentials imirror --apple-id <id> --team-id <TEAMID> --password <app-pw>
# then:
NOTARY_PROFILE=imirror ./scripts/package.sh   # signs, notarizes, staples
```

Without that cert it ad-hoc signs (runs locally; other Macs show a Gatekeeper
warning). The Mac App Store is not a target — CoreMediaIO capture is incompatible
with the App Sandbox; distribute the notarized DMG directly.

## Status / limitations

- **Working:** video mirror, audio playback (Sound toggle — muted by default to
  avoid echo with the phone's own speaker), record, screenshot, and control (tap,
  drag, two-finger trackpad scroll with flick detection, type incl.
  backspace/return/tab, Home).
- **macOS only** by design. Cross-platform would mean the libusb /
  `quicktime_video_hack` path — a different architecture.
- **Latency:** video ~60–150 ms (USB capture); control adds a WDA round-trip
  (tens–hundreds of ms per action — fine, not frame-tight). Scrolling is not
  frame-tight and has no inertial coast (a WDA limitation, not a tuning knob).
- **Not reachable** (XCUITest limitation): App Switcher, Control Center, Siri.
- **One device at a time** — the transport assumes a single phone and fixed
  loopback ports (8100/8101). Multi-device would need per-device port plumbing.
- **Maintenance reality:** control depends on go-ios + WebDriverAgent tracking
  Apple's private wire protocols, so a new iOS major version can break the chain
  until those projects catch up. Pinned versions in
  [SECURITY-AUDIT.md](SECURITY-AUDIT.md) are what's actually tested.
- **Landscape** adapts via WDA `window/size` (refreshed each poll) but hasn't been
  physically rotation-tested.
- Relaunching the app in quick succession can briefly wedge the device's
  `testmanagerd`; the watchdog recovers within ~1–2 min, or just pause between
  launches. A hard crash (rather than a clean quit) can orphan a go-ios child;
  the next launch sweeps it automatically, but if the dot stays red, quitting and
  relaunching forces a clean chain.

## Credits

iMirror is independent software and contains no scrcpy source; it was inspired by
[scrcpy](https://github.com/Genymobile/scrcpy)'s "mirror + control over USB" idea
and applies the equivalent approach to iOS. Control is built on two open-source
tools, fetched into `tools/` at build time (see [SECURITY-AUDIT.md](SECURITY-AUDIT.md)):

- [go-ios](https://github.com/danielpaulus/go-ios) — MIT
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) — Apache-2.0

Distributions that bundle the `go-ios` binary should include its MIT notice.

## Author

Theophilus RexDanquah — [rexdanquah.dev](https://rexdanquah.dev)

## License

MIT — see [LICENSE](LICENSE).
