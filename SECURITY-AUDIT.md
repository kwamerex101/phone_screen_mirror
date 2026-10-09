# Dependency Security Audit

Record of every third-party dependency introduced, how it was vetted, and the
residual risk accepted. Re-run the scans on every version bump.

Scanner: `osv-scanner` 2.6.0 (Google, OSV database). Toolchain: Go 1.27.1.
Audit date: 2026-10-09.

## Policy (enforced)

Source-available · pinned to exact tag **and** verified commit hash · scanned
with `osv-scanner` · built from source (no prebuilt-binary trust) · loopback-only
at runtime. No `curl | sh`, no unsigned binaries.

## Dependencies

### WebDriverAgent — appium/WebDriverAgent
- Version: **v16.14.2**, commit `d15c0b2dbaa850fa712fba817e51cf8d5026d9f2` (verified).
- License: Apache-2.0.
- Role: on-device XCUITest control app (runs on the iPhone).
- Scan result: **No issues found.**
- Build: by the user in Xcode, signed with their paid Apple Developer account.
- Since v14 the project's deployment floor is iOS 15.0 (was 12.0). The build
  scripts' `proj_floor` follows it.

### go-ios — danielpaulus/go-ios
- Version: **v1.3.2**, commit `2fb34682ef12db97c9fafdf99f1dd1d3522604ad` (verified).
- License: MIT.
- Role: USB transport — tunnel (iOS 17+), launch WDA, forward port 8100. Runs on
  the Mac. We build ONLY the root `ios` CLI; the `ncm/` and `restapi/`
  submodules are not built or run.
- Built from source with `GOWORK=off` (root module only), cross-compiled for
  both `arm64` and `amd64` (`CGO_ENABLED=0`) and `lipo`-merged into a universal2
  binary by `scripts/build-go-ios.sh` — still source-built, no prebuilt-binary
  trust. Patched transitive deps (only crypto and net are pinned; Go's
  minimum-version selection raises the rest):

  | Package | Pinned in tag | Patched to | Status |
  |---|---|---|---|
  | golang.org/x/crypto | 0.52.0 | 0.57.0 | ✅ fixed (one residual, see below) |
  | golang.org/x/net | 0.55.0 | 0.60.0 | ✅ fixed |
  | golang.org/x/text | 0.37.0 | 0.42.0 | ✅ fixed |
  | golang.org/x/mod | 0.35.0 | 0.41.0 | ✅ fixed |
  | golang.org/x/sys | 0.45.0 | 0.48.0 | ✅ fixed |
  | stdlib | go 1.26.0 directive | built w/ Go 1.27.1 | ✅ moot (newer than all fixes) |
  | github.com/quic-go/quic-go | 0.59.1 | 0.59.1 | ✅ fixed upstream |

  The quic-go 0.49.1 residual recorded for v1.1.0 is gone: go-ios v1.3.x moved
  to the `quic.Conn` API and ships quic-go 0.59.1, past every listed advisory.

#### Residual risk: GO-2026-5932 (x/crypto/openpgp)
Flagged against every x/crypto version: the `openpgp` package is deprecated
and has no fix. **Accepted because** nothing in the built root module imports
`golang.org/x/crypto/openpgp` (verified by grep), so the vulnerable code is not
compiled into the binary. The `restapi/` submodule has many stale-dep findings
but is not built or shipped.

## Runtime security

- WDA's HTTP server (:8100) has **no authentication**. Only ever reached over
  USB-forwarded loopback. iMirror's WDAClient hard-rejects any non-127.0.0.1 host.
- Control is OFF by default; the user must explicitly connect + enable it.
