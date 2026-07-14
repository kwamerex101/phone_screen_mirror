# Dependency Security Audit

Record of every third-party dependency introduced, how it was vetted, and the
residual risk accepted. Re-run the scans on every version bump.

Scanner: `osv-scanner` 2.3.8 (Google, OSV database). Toolchain: Go 1.26.4.
Audit date: 2026-06-05.

## Policy (enforced)

Source-available · pinned to exact tag **and** verified commit hash · scanned
with `osv-scanner` · built from source (no prebuilt-binary trust) · loopback-only
at runtime. No `curl | sh`, no unsigned binaries.

## Dependencies

### WebDriverAgent — appium/WebDriverAgent
- Version: **v9.9.0**, commit `99c52473bc2d5ca0379a21432f53edd8eeee9021` (verified).
- License: Apache-2.0.
- Role: on-device XCUITest control app (runs on the iPhone).
- Scan result: **No issues found.**
- Build: by the user in Xcode, signed with their paid Apple Developer account.

### go-ios — danielpaulus/go-ios
- Version: **v1.1.0**, commit `3661ad60e066231c9fb38b3a492117d730580882` (verified).
- License: MIT.
- Role: USB transport — tunnel (iOS 17+), launch WDA, forward port 8100. Runs on
  the Mac. We build ONLY the root `ios` CLI; the `ncm/` and `restapi/`
  submodules are not built or run.
- Built from source with `GOWORK=off` (root module only), cross-compiled for
  both `arm64` and `amd64` (`CGO_ENABLED=0`) and `lipo`-merged into a universal2
  binary by `scripts/build-go-ios.sh` — still source-built, no prebuilt-binary
  trust. Patched transitive deps:

  | Package | Pinned in tag | Patched to | Status |
  |---|---|---|---|
  | golang.org/x/crypto | 0.24.0 | 0.52.0 | ✅ fixed |
  | golang.org/x/net | 0.26.0 | 0.55.0 | ✅ fixed |
  | golang.org/x/sys | 0.21.0 | 0.45.0 | ✅ fixed |
  | stdlib | go 1.24.13 directive | built w/ Go 1.26.4 | ✅ moot (newer than all fixes) |
  | github.com/quic-go/quic-go | 0.40.1-pre | 0.49.1 | ⚠️ residual (see below) |

#### Residual risk: quic-go 0.49.1
quic-go renamed `quic.Connection` → `quic.Conn` in v0.50, which breaks go-ios
v1.1.0's tunnel code. v0.49.1 is the highest fixed version that keeps the old
API and compiles. A few advisories require v0.57+ and remain unpatched.

**Accepted because:** quic-go is used only for the iOS 17+ developer tunnel —
go-ios acts as a QUIC *client* to the user's own USB-connected device. The
residual advisories are remote-attacker QUIC *server* DoS / handshake issues,
not reachable in this client-to-own-device-over-USB usage. Revisit if go-ios
upgrades its quic-go API usage, or if the tunnel is ever exposed beyond USB.

## Runtime security

- WDA's HTTP server (:8100) has **no authentication**. Only ever reached over
  USB-forwarded loopback. iMirror's WDAClient hard-rejects any non-127.0.0.1 host.
- Control is OFF by default; the user must explicitly connect + enable it.
