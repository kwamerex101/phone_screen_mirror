#!/usr/bin/env bash
# Bring up the WDA control channel, AFTER WebDriverAgent has been built, signed,
# and installed on the device via Xcode (see README "Phase 2 bring-up") and is
# currently running (Xcode → Product → Test, left running).
#
# Architecture (why the relay):
#   iMirror (CFNetwork) --> 127.0.0.1:8100 (relay) --> 127.0.0.1:8101 (go-ios) --USB--> device:8100
# go-ios `forward` alone is incompatible with macOS CFNetwork/URLSession (returns
# NSURLErrorNetworkConnectionLost -1005), though plain socket clients work. The
# loopback relay (scripts/wda_relay.py) normalises the connection so URLSession
# works, while keeping the USB transport and iMirror's loopback-only model.
#
# Prereqs: iPhone connected by USB, unlocked, Developer Mode ON; WDA running.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> starting WDA loopback bridge (go-ios forward :8101 + relay :8100)"
pkill -9 -f "bin/ios forward" 2>/dev/null || true
pkill -9 -f "wda_relay"       2>/dev/null || true
sleep 1

# The relay spawns `ios forward 8101 8100` itself and stays in the foreground.
python3 "$ROOT/scripts/wda_relay.py" 8100 8101 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null || true; pkill -9 -f "bin/ios forward" 2>/dev/null || true' EXIT
sleep 4

echo "==> WDA status:"
if python3 - <<'PY'
import urllib.request, json, sys
try:
    d = json.load(urllib.request.urlopen("http://127.0.0.1:8100/status", timeout=6))
    print("    ready:", d["value"]["ready"], "-", d["value"]["message"])
    sys.exit(0 if d["value"]["ready"] else 1)
except Exception as e:
    print("    no response:", e); sys.exit(1)
PY
then
    echo "WDA is up. Now: ./scripts/run.sh → Connect → tick Control → tap the preview."
else
    echo "  WDA not reachable — is WebDriverAgentRunner running on the device (Xcode Test)?"
fi

echo "Relay PID $RELAY — leave this terminal open while using control. Ctrl-C to stop."
wait $RELAY
