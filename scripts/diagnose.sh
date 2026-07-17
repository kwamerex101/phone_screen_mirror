#!/usr/bin/env bash
# iMirror diagnostics — read-only. Tells you WHICH subsystem is failing when
# "it won't connect to my phone":
#
#   A. video/mirror = CoreMediaIO + AVCaptureDevice + Camera (TCC) — no go-ios
#   B. control      = go-ios chain (tunnel -> runwda -> forward) + WDA
#
# Nothing here kills processes or changes state.
#
#   ./scripts/diagnose.sh          # writes ~/Desktop/imirror-diagnostics.txt
set -uo pipefail

OUT="${1:-$HOME/Desktop/imirror-diagnostics.txt}"
APP="${IMIRROR_APP:-/Applications/iMirror.app}"
SUPPORT="$HOME/Library/Application Support/iMirror"

exec > >(tee "$OUT") 2>&1

section() { printf '\n===== %s =====\n' "$1"; }

echo "iMirror diagnostics — $(date)"

section "1. Mac + architecture"
sw_vers
echo "native arch : $(uname -m)"
echo "cpu         : $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
pgrep -q oahd && echo "rosetta     : installed" || echo "rosetta     : not running"

section "2. App bundle"
if [[ -d "$APP" ]]; then
  echo "path: $APP"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null | sed 's/^/version: /'
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null | sed 's/^/build:   /'
  echo "--- app binary slices (MUST include x86_64 on Intel) ---"
  lipo -archs "$APP/Contents/MacOS/iMirror" 2>&1
  echo "--- bundled go-ios slices (MUST include x86_64 on Intel) ---"
  lipo -archs "$APP/Contents/Resources/ios" 2>&1
  echo "--- bundled WDA ipa present? ---"
  ls -la "$APP/Contents/Resources/WebDriverAgent.ipa" 2>&1
  echo "--- signature / gatekeeper ---"
  codesign -dv --verbose=2 "$APP" 2>&1 | sed -n '1,6p'
  spctl -a -vv "$APP" 2>&1 | head -3
  echo "--- quarantine (set if opened straight from the DMG) ---"
  xattr -l "$APP" 2>&1 | grep -i quarantine || echo "(no quarantine attr)"
else
  echo "NOT FOUND at $APP  (set IMIRROR_APP=/path/to/iMirror.app and re-run)"
fi

section "3. SUBSYSTEM A — video / mirror (CoreMediaIO + Camera)"
echo "--- is the iPhone on the USB bus at all? ---"
system_profiler SPUSBDataType 2>/dev/null | grep -iA6 'iphone' | head -30 || echo "(no iPhone on USB)"
echo "--- does it enumerate as a capture device? (only while iMirror runs) ---"
system_profiler SPCameraDataType 2>/dev/null | head -30
echo "--- camera TCC decision for iMirror ---"
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select service, client, auth_value from access where service='kTCCServiceCamera';" 2>&1 | sed 's/^/  /' || true
echo "  (auth_value: 0=denied 2=allowed; 'unable to open' => give Terminal Full Disk Access, or just check System Settings > Privacy > Camera)"

section "4. SUBSYSTEM B — control (go-ios chain)"
echo "--- stray/orphaned go-ios children (a leftover tunnel blocks a fresh one) ---"
pgrep -fl "ios tunnel|ios runwda|ios forward" 2>/dev/null || echo "(none running)"
echo "--- who holds the tunnel agent port 60105? ---"
lsof -nP -iTCP:60105 2>/dev/null || echo "(nobody on 60105)"
echo "--- relay 8100 / forward 8101 ---"
lsof -nP -iTCP:8100 -sTCP:LISTEN 2>/dev/null || echo "(nothing listening on 8100)"
lsof -nP -iTCP:8101 -sTCP:LISTEN 2>/dev/null || echo "(nothing listening on 8101)"
echo "--- tunnel agent: any established device tunnel? ---"
curl -sS --max-time 3 http://127.0.0.1:60105/tunnels 2>&1 | head -5 || echo "(agent not answering)"
echo "--- is WDA reachable through the relay? ---"
curl -sS --max-time 3 http://127.0.0.1:8100/status 2>&1 | head -20 || echo "(WDA not reachable on 8100)"

section "5. go-ios working dir + child logs"
echo "path: $SUPPORT"
ls -la "$SUPPORT" 2>&1
for f in tunnel runwda forward; do
  if [[ -f "$SUPPORT/$f.log" ]]; then
    echo "--- last 40 lines of $f.log ---"
    tail -40 "$SUPPORT/$f.log"
  fi
done
echo "(child logs only exist if the app ran with IMIRROR_DEBUG=1 — see step 7)"

section "6. App log (NSLog -> unified logging)"
log show --predicate 'process == "iMirror"' --last 45m --info 2>/dev/null | tail -80 || echo "(no log entries)"

section "7. Next step if the cause is still unclear"
cat <<'EOF'
Quit iMirror, then run it from Terminal with child logging on:

    IMIRROR_DEBUG=1 /Applications/iMirror.app/Contents/MacOS/iMirror

Reproduce the failure (turn Automation on, wait ~60s), quit, then re-run this
script. Step 5 will then contain the tunnel/runwda/forward logs, which say
exactly why the chain won't come up.
EOF

echo
echo "===== done -> $OUT ====="
echo "Send that file back."
