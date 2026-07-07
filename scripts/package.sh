#!/usr/bin/env bash
# Package iMirror as a distributable DMG.
#
# - Builds a release .app (bundles go-ios + icon).
# - Signs with a Developer ID Application identity if one is installed (hardened
#   runtime + camera entitlement, nested go-ios signed too); otherwise falls back
#   to ad-hoc signing (works locally, will warn under Gatekeeper elsewhere).
# - Builds a DMG via hdiutil.
# - Notarizes + staples if a notarytool keychain profile is provided via
#   NOTARY_PROFILE; otherwise prints the exact commands to run.
#
# Usage:
#   ./scripts/package.sh                 # auto-detect signing identity
#   NOTARY_PROFILE=imirror ./scripts/package.sh   # also notarize + staple
#   WITH_WDA=build/WebDriverAgent.ipa ./scripts/package.sh
#
# One-time notary profile setup (per machine):
#   xcrun notarytool store-credentials imirror \
#       --apple-id you@example.com --team-id HOMEKARETEAMID --password <app-specific-pw>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/iMirror.app"
DMG="$ROOT/build/iMirror.dmg"
ENT="$ROOT/Resources/iMirror.entitlements"

echo "==> swift build (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/iMirror"

echo "==> assembling app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[[ -x "$ROOT/tools/go-ios/bin/ios" ]] && cp "$ROOT/tools/go-ios/bin/ios" "$APP/Contents/Resources/ios"

# Bundle the MCP server so the in-app one-click MCP install works from a DMG.
mkdir -p "$APP/Contents/Resources/mcp-server"
cp "$ROOT/mcp-server/imirror_mcp.py" "$APP/Contents/Resources/mcp-server/" 2>/dev/null || true
[[ -f "$ROOT/mcp-server/requirements.txt" ]] && \
    cp "$ROOT/mcp-server/requirements.txt" "$APP/Contents/Resources/mcp-server/" || true

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

# Pick a signing identity — by its SHA-1 hash, not its name. Two "Developer ID
# Application" certs with the same subject (e.g. after a renewal) make a
# name-based --sign ambiguous and codesign aborts; the hash is unique.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" | head -1 | grep -oE '[0-9A-F]{40}' | head -1 || true)"
IDENTITY_NAME="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" | head -1 | grep -oE '"[^"]+"' | tr -d '"' || true)"

if [[ -n "$IDENTITY" ]]; then
    echo "==> signing with: $IDENTITY_NAME [$IDENTITY] (hardened runtime)"
    # Sign nested helper first, then the app (deep is discouraged; sign inside-out).
    [[ -f "$APP/Contents/Resources/ios" ]] && \
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/ios"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENT" --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    SIGNED=1
else
    echo "==> no Developer ID identity found — ad-hoc signing (local use only)"
    [[ -f "$APP/Contents/Resources/ios" ]] && codesign --force --sign - "$APP/Contents/Resources/ios"
    codesign --force --sign - --entitlements "$ENT" "$APP"
    SIGNED=0
fi

echo "==> building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "iMirror" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $DMG"

if [[ "$SIGNED" == 1 ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "==> notarizing (profile: $NOTARY_PROFILE)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        echo "==> stapling"
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        echo "Done — notarized + stapled DMG ready for distribution."
    else
        cat <<EOF
==> signed but NOT notarized. To notarize:
    xcrun notarytool submit "$DMG" --keychain-profile <profile> --wait
    xcrun stapler staple "$DMG"
(see header of this script for one-time store-credentials setup)
EOF
    fi
else
    echo "==> ad-hoc DMG built (opens locally; other Macs will see a Gatekeeper warning)."
    echo "    For distribution, install a 'Developer ID Application' cert and re-run."
fi
