#!/usr/bin/env python3
"""WDA loopback bridge.

go-ios `forward` relays the device's WDA port over USB, but its relay is
incompatible with CFNetwork/URLSession (returns NSURLErrorNetworkConnectionLost
-1005), while plain socket clients work. So we put a clean loopback TCP relay in
front of it:

    iMirror (CFNetwork) --> 127.0.0.1:8100 (this relay) --> 127.0.0.1:8101 (go-ios forward) --USB--> device:8100

This keeps the USB transport and iMirror's loopback-only security model intact;
the relay is a dumb byte pump that normalises the TCP connection CFNetwork opens.

Usage: wda_relay.py [LISTEN_PORT=8100] [BACKEND_PORT=8101]
Run go-ios separately:  ios forward 8101 8100
"""
import os, socket, subprocess, sys, threading, time

LISTEN = int(sys.argv[1]) if len(sys.argv) > 1 else 8100
BACKEND = int(sys.argv[2]) if len(sys.argv) > 2 else 8101

# Path to the go-ios binary we built from source.
IOS_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "tools", "go-ios", "bin", "ios")


def start_go_ios_forward():
    """Spawn `ios forward BACKEND device:8100` as a child so it dies with us."""
    proc = subprocess.Popen([IOS_BIN, "forward", str(BACKEND), "8100"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # wait until the backend port is accepting
    for _ in range(20):
        try:
            socket.create_connection(("127.0.0.1", BACKEND), timeout=1).close()
            print(f"go-ios forward up on {BACKEND} (pid {proc.pid})", flush=True)
            return proc
        except OSError:
            time.sleep(0.3)
    print("warning: go-ios forward backend not reachable yet", flush=True)
    return proc


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        backend = socket.create_connection(("127.0.0.1", BACKEND), timeout=10)
    except OSError as e:
        client.close()
        print(f"backend connect failed: {e}", flush=True)
        return
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    backend.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    threading.Thread(target=pump, args=(client, backend), daemon=True).start()
    pump(backend, client)


def main():
    start_go_ios_forward()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN))   # loopback only
    srv.listen(64)
    print(f"WDA relay: 127.0.0.1:{LISTEN} -> 127.0.0.1:{BACKEND}", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
