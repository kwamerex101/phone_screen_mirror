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
