#!/usr/bin/env bash
# Build WebDriverAgent at the pinned upstream tag, fully rebranded to iMirror,
# WITHOUT forking. The bundle id is a build setting; the on-device display name and
# app icon are applied to Xcode's generated runner .app as a post-build patch and
# re-sign (Xcode's XCTest runner wrapper has a default name and no icon, and neither
# INFOPLIST_KEY_* nor the .xctest's own plist affect that wrapper). A WDA version
# bump is just a re-clone + re-run of this script. Produces one installable .ipa.
#
# Requires: Xcode, a connected iPhone (for provisioning), and a PAID Apple Team
# (DEVELOPMENT_TEAM). Re-signs with your "Apple Development" identity.
#
#   DEVELOPMENT_TEAM=<TEAMID> ./scripts/build-wda.sh
#   tools/go-ios/bin/ios install --path=build/WebDriverAgent.ipa
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your paid Apple Team id}"
DERIVED="$ROOT/build/wda-derived"
BUNDLE_ID="com.local.imirror.WebDriverAgentRunner"
DISPLAY_NAME="iMirror"

echo "==> building rebranded WebDriverAgentRunner (bundle id $BUNDLE_ID)"
# Xcode-26 build accommodations for the vendored WDA:
#   -allowProvisioningUpdates : register the new branded App ID + mint a dev profile
#       (else "No profiles for '<id>' were found").
#   GCC_TREAT_WARNINGS_AS_ERRORS=NO : WDA's vendored XCTest PrivateHeaders trip
#       clang's -Wreserved-identifier (35 errors on Xcode 26).
# Do NOT override PRODUCT_NAME (it applies to ALL targets, renaming
#   WebDriverAgentLib's header-map namespace and breaking <WebDriverAgentLib/*.h>
#   imports), and do NOT pass RUN_CLANG_STATIC_ANALYZER=NO or
#   CLANG_ENABLE_EXPLICIT_MODULES=NO (they break header-map lookups too).
xcodebuild build-for-testing \
    -project "$PROJ" \
    -scheme WebDriverAgentRunner \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO

PROD="$DERIVED/Build/Products/Debug-iphoneos"
RUNNER="$PROD/WebDriverAgentRunner-Runner.app"
[[ -d "$RUNNER" ]] || { echo "runner app not found at $RUNNER" >&2; exit 1; }

# --- Brand the generated runner .app: app icon + display name, then re-sign. ---
echo "==> branding the runner (icon + name '$DISPLAY_NAME') and re-signing"
ASSETS="$ROOT/build/wda-assets"
ICONSET="$ROOT/build/AppIcon.xcassets/AppIcon.appiconset"
rm -rf "$ROOT/build/AppIcon.xcassets" "$ASSETS"; mkdir -p "$ICONSET" "$ASSETS"

# 1024 iMirror icon (same artwork as the Mac app), flattened to opaque (iOS rejects
# alpha), compiled into an asset catalog with actool.
swift "$ROOT/scripts/make_ios_icon.swift" "$ASSETS/icon-1024.png"
sips -s format jpeg "$ASSETS/icon-1024.png" --out "$ASSETS/icon.jpg"      >/dev/null
sips -s format png  "$ASSETS/icon.jpg"      --out "$ICONSET/icon-1024.png" >/dev/null
cat > "$ICONSET/Contents.json" <<'JSON'
{ "images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
  "info":{"author":"xcode","version":1} }
JSON
xcrun actool "$ROOT/build/AppIcon.xcassets" --compile "$ASSETS" \
  --platform iphoneos --minimum-deployment-target 12.0 --app-icon AppIcon \
  --output-partial-info-plist "$ASSETS/partial.plist" >/dev/null

# Preserve the runner's entitlements (get-task-allow etc.) across the re-sign —
# without them the XCUITest runner can't attach and WDA never goes ready.
codesign -d --entitlements :- "$RUNNER" > "$ASSETS/ent.plist" 2>/dev/null
grep -q "get-task-allow" "$ASSETS/ent.plist" || { echo "runner entitlements missing get-task-allow" >&2; exit 1; }

# Inject icon + name into the wrapper, then merge actool's CFBundleIcons keys.
cp "$ASSETS/Assets.car" "$RUNNER/Assets.car"
cp "$ASSETS"/AppIcon*.png "$RUNNER/" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$RUNNER/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$RUNNER/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $ASSETS/partial.plist" "$RUNNER/Info.plist"

# Re-sign with the same Apple Development identity + preserved entitlements.
SIGNID="$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | grep -oE '[0-9A-F]{40}')"
[[ -n "$SIGNID" ]] || { echo "no 'Apple Development' signing identity found" >&2; exit 1; }
codesign --force --sign "$SIGNID" --entitlements "$ASSETS/ent.plist" "$RUNNER"
codesign --verify --deep --strict "$RUNNER"

# Package the runner .app into an installable .ipa (Payload/<App> then zip).
rm -rf "$ROOT/build/Payload" "$ROOT/build/WebDriverAgent.ipa"
mkdir -p "$ROOT/build/Payload"
cp -R "$RUNNER" "$ROOT/build/Payload/"
( cd "$ROOT/build" && zip -qr WebDriverAgent.ipa Payload )
rm -rf "$ROOT/build/Payload"
echo "==> ipa: $ROOT/build/WebDriverAgent.ipa  (id ${BUNDLE_ID}.xctrunner, name '$DISPLAY_NAME', branded icon)"
