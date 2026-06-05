#!/usr/bin/env bash
# Build iMirror, wrap the executable into a proper .app bundle (so TCC camera
# permission works), ad-hoc sign it, and launch it.
#
# Pure Apple toolchain (swift, codec/codesign, /bin). No third-party tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"   # debug | release

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/iMirror"
APP="$ROOT/build/iMirror.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the go-ios binary so the app can manage the USB forward itself
# (no external relay script / terminal needed).
GOIOS="$ROOT/tools/go-ios/bin/ios"
if [[ -x "$GOIOS" ]]; then
    cp "$GOIOS" "$APP/Contents/Resources/ios"
    echo "    bundled go-ios"
else
    echo "    WARNING: $GOIOS not found — app will fall back to scripts/wda-up.sh"
fi

echo "==> ad-hoc signing (local dev)"
codesign --force --sign - --timestamp=none "$APP"

echo "==> launching"
open "$APP"
echo "    (logs: Console.app, filter 'iMirror'; or: log stream --predicate 'eventMessage CONTAINS \"iMirror\"')"
