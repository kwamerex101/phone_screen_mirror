#!/usr/bin/env bash
# Bring up WebDriverAgent on an iOS *Simulator* and keep it running, so the MCP
# server can drive the sim exactly like a real device — but with none of the
# real-device transport (no go-ios tunnel/forward/relay; a simulator shares the
# Mac's loopback, so WDA is reachable directly). Simulator builds need NO signing
# and NO paid team (unlike scripts/build-wda.sh).
#
#   iMirror MCP (loopback) --> 127.0.0.1:$PORT --> WDA (in the simulator)
#
# The runner is rebranded to iMirror (app icon + "iMirror" display name + the
# com.local.imirror.WebDriverAgentRunner bundle id), matching the on-device build
# — so the sim's App Library / launch screen shows iMirror, not a stock
# "WebDriverAgentRunner-Runner". Because `xcodebuild test` rebuilds the runner each
# run, we split into build-for-testing -> brand -> test-without-building and re-apply
# the (cheap) branding patch on every launch.
#
# Usage:
#   ./scripts/sim-wda-up.sh                 # use the booted sim (or boot a default)
#   ./scripts/sim-wda-up.sh "iPhone 16 Pro" # boot that device by name
#   ./scripts/sim-wda-up.sh <UDID>          # boot that device by udid
#   PORT=8200 ./scripts/sim-wda-up.sh       # WDA on a non-default port
#
# Then, in another shell, point the MCP server at it:
#   IMIRROR_TARGET=simulator IMIRROR_WDA=http://127.0.0.1:$PORT \
#     mcp-server/.venv/bin/python mcp-server/imirror_mcp.py
#
# This runs `xcodebuild test-without-building` in the FOREGROUND and stays attached
# — WDA lives only as long as this process. Ctrl-C to stop. (Productizing this means
# supervising/relaunching it the way Transport.swift supervises go-ios.)
#
# NOTE: the branded "iMirror" icon this installs on the sim is the XCUITest RUNNER.
# Do NOT launch it by tapping the icon (or let the OS cold-launch it) — a test
# runner only works when xcodebuild starts it, which injects the toolchain dylibs
# (e.g. lib_TestingInterop.dylib). Launched standalone it aborts at load with a
# "Library not loaded" dyld error. Always bring WDA up through this script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The vendored WDA lives under the gitignored tools/ (see scripts/build-wda.sh).
# Allow an explicit override; a worktree won't carry tools/, so point WDA_PROJECT
# at your main checkout there.
PROJ="${WDA_PROJECT:-$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj}"
if [[ ! -d "$PROJ" ]]; then
    echo "WebDriverAgent project not found at: $PROJ" >&2
    echo "Set WDA_PROJECT=/path/to/WebDriverAgent.xcodeproj (the vendored copy under tools/)." >&2
    exit 1
fi

PORT="${PORT:-8100}"
DERIVED="$ROOT/build/wda-sim-derived"
BUNDLE_ID="com.local.imirror.WebDriverAgentRunner"   # matches WDAIdentity in Transport.swift
DISPLAY_NAME="iMirror"

# --- Resolve the target simulator to a UDID -------------------------------------
want="${1:-}"
udid=""
if [[ -n "$want" ]]; then
    # Accept a UDID directly, else resolve the newest device matching the name.
    if xcrun simctl list devices | grep -q "$want"; then
        udid="$(xcrun simctl list devices | grep "$want" | grep -oE '[0-9A-F-]{36}' | head -1)"
    fi
    [[ -n "$udid" ]] || { echo "No simulator matching '$want'." >&2; exit 1; }
else
    # No arg: prefer a currently-booted sim, else a sensible default device.
    udid="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
    if [[ -z "$udid" ]]; then
        udid="$(xcrun simctl list devices available | grep -iE 'iPhone' \
                | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
        [[ -n "$udid" ]] || { echo "No available iPhone simulators found." >&2; exit 1; }
    fi
fi

echo "==> target simulator: $udid"
xcrun simctl boot "$udid" 2>/dev/null || true   # no-op if already booted
open -a Simulator 2>/dev/null || true

DEST="platform=iOS Simulator,id=$udid"
# Xcode-26 accommodations mirror scripts/build-wda.sh:
#   CODE_SIGNING_ALLOWED=NO         : simulators don't need code signing
#   GCC_TREAT_WARNINGS_AS_ERRORS=NO : WDA's vendored headers trip -Wreserved-identifier
# Do NOT override PRODUCT_NAME (renames WebDriverAgentLib's header namespace and
# breaks <WebDriverAgentLib/*.h>); the display name is patched post-build instead.
echo "==> build-for-testing (bundle id $BUNDLE_ID, no signing)"
xcodebuild build-for-testing \
    -project "$PROJ" \
    -scheme WebDriverAgentRunner \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO

RUNNER="$DERIVED/Build/Products/Debug-iphonesimulator/WebDriverAgentRunner-Runner.app"
[[ -d "$RUNNER" ]] || { echo "runner app not found at $RUNNER" >&2; exit 1; }

# --- Brand the generated runner: app icon + "iMirror" name, then ad-hoc re-sign. -
# Same patch as scripts/build-wda.sh, adapted for the simulator: actool targets the
# iphonesimulator platform, and we ad-hoc sign (`-`) since simulators don't use a
# team identity. Re-applied every launch because build-for-testing may rebuild the
# runner and wipe the patch.
echo "==> branding the runner (icon + name '$DISPLAY_NAME'), ad-hoc re-sign"
ASSETS="$ROOT/build/wda-sim-assets"
ICONSET="$ROOT/build/wda-sim-AppIcon.xcassets/AppIcon.appiconset"
rm -rf "$ROOT/build/wda-sim-AppIcon.xcassets" "$ASSETS"; mkdir -p "$ICONSET" "$ASSETS"

# 1024 iMirror icon, flattened to opaque (iOS rejects alpha), compiled with actool.
swift "$ROOT/scripts/make_ios_icon.swift" "$ASSETS/icon-1024.png"
sips -s format jpeg "$ASSETS/icon-1024.png" --out "$ASSETS/icon.jpg"      >/dev/null
sips -s format png  "$ASSETS/icon.jpg"      --out "$ICONSET/icon-1024.png" >/dev/null
cat > "$ICONSET/Contents.json" <<'JSON'
{ "images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
  "info":{"author":"xcode","version":1} }
JSON
xcrun actool "$ROOT/build/wda-sim-AppIcon.xcassets" --compile "$ASSETS" \
  --platform iphonesimulator --minimum-deployment-target 12.0 --app-icon AppIcon \
  --output-partial-info-plist "$ASSETS/partial.plist" >/dev/null

# Preserve the runner's entitlements (get-task-allow etc.) across the re-sign — the
# XCUITest runner can't attach without them.
codesign -d --entitlements :- "$RUNNER" > "$ASSETS/ent.plist" 2>/dev/null || : > "$ASSETS/ent.plist"

# Inject icon + name, merge actool's CFBundleIcons keys.
cp "$ASSETS/Assets.car" "$RUNNER/Assets.car"
cp "$ASSETS"/AppIcon*.png "$RUNNER/" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$RUNNER/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$RUNNER/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $ASSETS/partial.plist" "$RUNNER/Info.plist"

# Ad-hoc re-sign so the modified bundle stays valid for the simulator.
if [[ -s "$ASSETS/ent.plist" ]]; then
    codesign --force --sign - --entitlements "$ASSETS/ent.plist" "$RUNNER"
else
    codesign --force --sign - "$RUNNER"
fi

echo "==> launching WebDriverAgent (port $PORT); leave running, Ctrl-C to stop."
# TEST_RUNNER_USE_PORT must be a real ENVIRONMENT variable (not a trailing
# KEY=VALUE build setting): xcodebuild forwards env vars whose names start with
# TEST_RUNNER_ into the test runner's environment with the prefix stripped, so WDA
# reads USE_PORT=$PORT and binds it. As a build setting it is ignored and WDA falls
# back to its compiled-in default (8100).
export TEST_RUNNER_USE_PORT="$PORT"
exec xcodebuild test-without-building \
    -project "$PROJ" \
    -scheme WebDriverAgentRunner \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO
