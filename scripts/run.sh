#!/usr/bin/env bash
# Build iMirror, wrap the executable into a proper .app bundle (so TCC camera
# permission works), ad-hoc sign it, and launch it.
#
# Pure Apple toolchain (swift, codec/codesign, /bin). No third-party tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GOIOS="${IMIRROR_IOS_BIN:-$ROOT/tools/go-ios/bin/ios}"
if [[ -n "${IMIRROR_IOS_BIN:-}" && ! -x "$GOIOS" ]]; then
    echo "IMIRROR_IOS_BIN is not executable: $GOIOS" >&2
    exit 1
fi

APP="$ROOT/build/iMirror.app"
if [[ -e "$GOIOS" && "$GOIOS" -ef "$APP/Contents/Resources/ios" ]]; then
    echo "IMIRROR_IOS_BIN must be outside the app being rebuilt." >&2
    exit 1
fi

CONFIG="${1:-debug}"   # debug | release

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/iMirror"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the go-ios binary so the app can manage the USB forward itself
# (no external relay script / terminal needed).
if [[ -x "$GOIOS" ]]; then
    cp "$GOIOS" "$APP/Contents/Resources/ios"
    echo "    bundled go-ios from $GOIOS"
else
    echo "    WARNING: $GOIOS not found — app will fall back to scripts/wda-up.sh"
fi

# Bundle the MCP server so the in-app one-click MCP install works from the .app.
mkdir -p "$APP/Contents/Resources/mcp-server"
cp "$ROOT/mcp-server/imirror_mcp.py" "$ROOT/mcp-server/wda_bringup.py" "$APP/Contents/Resources/mcp-server/"
[[ -f "$ROOT/mcp-server/requirements.txt" ]] && \
    cp "$ROOT/mcp-server/requirements.txt" "$APP/Contents/Resources/mcp-server/" || true

echo "==> ad-hoc signing (local dev)"
codesign --force --sign - --timestamp=none "$APP"

echo "==> launching"
if [[ "${IMIRROR_NO_LAUNCH:-0}" != 1 ]]; then open "$APP"; fi
echo "    (logs: Console.app, filter 'iMirror'; or: log stream --predicate 'eventMessage CONTAINS \"iMirror\"')"
