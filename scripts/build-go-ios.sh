#!/usr/bin/env bash
# Build a universal2 (arm64 + x86_64) go-ios `ios` binary from the pinned,
# audited source already cloned into tools/go-ios (see README "Set up tools/"
# and SECURITY-AUDIT.md). Produces tools/go-ios/bin/ios — a fat Mach-O that
# runs on both Intel and Apple Silicon Macs. scripts/package.sh bundles it into
# the .app so one DMG works everywhere.
#
# CGO is disabled so both slices cross-compile with the stock Go toolchain and
# no C cross-compiler. go-ios talks to usbmuxd over sockets and needs no cgo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/tools/go-ios"
[[ -d "$SRC" ]] || { echo "tools/go-ios not found — clone it first (see README)" >&2; exit 1; }
cd "$SRC"

# Same patched transitive deps the security audit records (SECURITY-AUDIT.md).
GOWORK=off go get golang.org/x/crypto@v0.52.0 golang.org/x/net@v0.55.0 \
                  github.com/quic-go/quic-go@v0.49.1
GOWORK=off go mod tidy

echo "==> building go-ios arm64 + amd64 (CGO off, root module only)"
GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o bin/ios-arm64 .
GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o bin/ios-amd64 .

echo "==> lipo -> universal bin/ios"
lipo -create -output bin/ios bin/ios-arm64 bin/ios-amd64
rm -f bin/ios-arm64 bin/ios-amd64

echo "==> result:"
lipo -archs bin/ios
file bin/ios
