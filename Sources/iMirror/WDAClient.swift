// WDAClient — minimal, self-healing HTTP client for WebDriverAgent (XCUITest),
// the only non-jailbreak path to inject input into a real iPhone.
//
// SECURITY: only ever talk to WDA over loopback (USB-forwarded localhost). WDA's
// HTTP server has NO authentication — exposing it on a routable interface hands
// full control of the phone to anyone who can reach it. Default base URL is
// 127.0.0.1; the initialiser refuses anything else.
//
// Robustness: WDA sessions are fragile (the runner can drop, restart, or expire).
// `probe()` validates the live session and reports one of three states so the UI
// can auto-reconnect. Input calls self-invalidate the session on a 404 so the
// next probe transparently recreates it.
//
// Dependency-free: Foundation URLSession only. A fresh ephemeral session is used
// per request because WDA's CocoaHTTPServer doesn't keep connections alive
// cleanly (a shared/pooled socket yields NSURLErrorNetworkConnectionLost).

import Foundation
import iMirrorCore

final class WDAClient {
    /// Result of a health probe.
    enum Health {
        case down          // WDA/relay unreachable
        case needsSession  // WDA is up but we have no valid session — create one
        case alive         // session valid, ready to drive
    }

    let base: URL
    private(set) var sessionId: String?
    private(set) var deviceSize: CGSize?   // logical points (portrait)

    init(base: URL = URL(string: "http://127.0.0.1:8100")!) {
        precondition(base.host == "127.0.0.1" || base.host == "localhost",
                     "WDA must be reached over loopback only (no auth on the wire).")
        self.base = base
    }

    // MARK: Session

    /// Creates a WDA session (system-wide, no specific app) and fetches the
    /// device's logical screen size in points.
    func connect(completion: @escaping (Result<CGSize, Error>) -> Void) {
        // shouldWaitForQuiescence:false is the single biggest latency win — measured
        // on-device, it drops a swipe's /actions round-trip from ~1300ms to ~10-200ms.
        // By default XCUITest blocks each gesture until the UI is "quiescent" (~1.2s
        // after a scroll's animation). We don't need that wait: the user watches the
        // live mirror, and agents can pass settle_ms when they need a stable frame.
        let body: [String: Any] = ["capabilities": [
            "alwaysMatch": ["shouldWaitForQuiescence": false], "firstMatch": [[:]]]]
        send("POST", "/session", body) { [weak self] _, json, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let sid = WDAParse.sessionId(json) else {
                completion(.failure(WDAError.badResponse("no sessionId")))
                return
            }
            self.sessionId = sid
            self.applyFastGestureSettings(sid: sid)
            self.fetchWindowSize(completion: completion)
        }
    }

    /// Disable XCUITest's idle/animation wait so gestures return promptly. THE big
    /// latency win, measured on-device: a swipe over animating content drops from
    /// ~13s to ~1s, and a static-list swipe from ~1.3s toward the ~10ms floor.
    /// (XCUITest otherwise blocks each gesture until the app goes "idle"; over
    /// autoplaying video it never does, so it waits out the full timeout.)
    /// Best-effort, fire-and-forget — the WDA `appium/settings` route, set per
    /// session right after connect. The shouldWaitForQuiescence capability is
    /// ignored by this WDA build, so this endpoint is the working lever.
    private func applyFastGestureSettings(sid: String) {
        send("POST", "/session/\(sid)/appium/settings",
             ["settings": ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0]]) { _, _, _ in }
    }

    private func fetchWindowSize(completion: @escaping (Result<CGSize, Error>) -> Void) {
        guard let sid = sessionId else { completion(.failure(WDAError.notConnected)); return }
        send("GET", "/session/\(sid)/window/size", nil) { [weak self] _, json, error in
            if let error { completion(.failure(error)); return }
            guard let size = WDAParse.windowSize(json) else {
                completion(.failure(WDAError.badResponse("no window size")))
                return
            }
            self?.deviceSize = size
            completion(.success(size))
        }
    }

    // MARK: Health

    /// Validates the current session (if any) and reports health. If a session
    /// call fails, falls back to /status to distinguish a dead session (WDA up)
    /// from WDA being unreachable.
    func probe(completion: @escaping (Health) -> Void) {
        if let sid = sessionId {
            send("GET", "/session/\(sid)/window/size", nil) { [weak self] code, json, error in
                guard let self else { return }
                if error == nil, let code, (200..<300).contains(code),
                   let size = WDAParse.windowSize(json) {
                    self.deviceSize = size
                    completion(.alive)
                } else {
                    self.sessionId = nil                       // session gone
                    self.statusReady { completion($0 ? .needsSession : .down) }
                }
            }
        } else {
            statusReady { completion($0 ? .needsSession : .down) }
        }
    }

    private func statusReady(_ completion: @escaping (Bool) -> Void) {
        send("GET", "/status", nil) { _, json, error in
            completion(error == nil && WDAParse.ready(json))
        }
    }

    // MARK: Input (fire-and-forget — taps must feel responsive)

    func tap(at p: CGPoint) {
        guard let sid = sessionId else { return }
        sendInput("/session/\(sid)/actions", pointer([
            ["type": "pointerMove", "duration": 0, "x": p.x, "y": p.y],
            ["type": "pointerDown", "button": 0],
            ["type": "pause", "duration": 40],
            ["type": "pointerUp", "button": 0],
        ]))
    }

    /// Move through a path of device points (one continuous gesture).
    ///
    /// `flick = false` → faithful slow drag: replay the whole path so content tracks
    /// the cursor (precise dragging, picking, slow scrub).
    ///
    /// `flick = true` → one quick straight swipe (first→last) for a snappy scroll.
    ///
    /// IMPORTANT: WDA/XCUITest injects *synthetic* touches that do not carry liftoff
    /// velocity, so iOS scroll **momentum never triggers** — measured directly: a
    /// ~18,000 pt/s swipe coasts no further than a slow one. Scrolling is therefore a
    /// discrete 1:1 jump per gesture; a fast swipe only animates quicker, it doesn't
    /// glide. To cover distance we amplify the swipe length upstream (scroll gain),
    /// not the velocity. (Apple's iPhone-Mirroring smoothness comes from realtime HID
    /// injection + native momentum — a layer WDA can't reach.)
    func drag(path: [CGPoint], flick: Bool = false, totalMs: Int = 300) {
        guard let sid = sessionId, let first = path.first, let last = path.last else { return }
        var steps: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": first.x, "y": first.y],
            ["type": "pointerDown", "button": 0],
        ]
        if flick {
            // 150ms = ~9 XCUITest interpolation frames: a visible slide, not a
            // teleport. (Velocity is irrelevant — WDA can't trigger momentum.)
            steps.append(["type": "pointerMove", "duration": 150, "x": last.x, "y": last.y])
        } else {
            let segments = max(1, path.count - 1)
            let perSegment = max(8, totalMs / segments)
            for p in path.dropFirst() {
                steps.append(["type": "pointerMove", "duration": perSegment, "x": p.x, "y": p.y])
            }
        }
        steps.append(["type": "pointerUp", "button": 0])
        sendInput("/session/\(sid)/actions", pointer(steps))
    }

    func typeText(_ text: String) {
        guard let sid = sessionId else { return }
        sendInput("/session/\(sid)/wda/keys", ["value": Array(text.map { String($0) })])
    }

    func home() {
        sendInput("/wda/homescreen", [:])
    }

    /// True while a gesture POST (/actions) is outstanding. Concurrent gestures are
    /// dropped rather than queued: serial HTTP round-trips would land hundreds of ms
    /// after the hand stopped, reading as sticky lag — and an in-flight flick's iOS
    /// momentum already covers the user's intent.
    private var gestureInFlight = false
    /// Read-only view for the health monitor so it can skip probing mid-gesture.
    /// Set/cleared only on DispatchQueue.main — main-thread access only.
    var isGestureInFlight: Bool { gestureInFlight }

    /// Gesture request timeout: short enough to recover fast if WDA wedges, long
    /// enough not to cancel a legitimately slow swipe on a heavy/throttled screen.
    private let gestureTimeoutSec: TimeInterval = 4.0

    /// Sends an input request; a 404 means the session expired — drop it so the
    /// next health probe recreates it transparently. "Gesture" posts (/actions and
    /// the home-screen press) use the short timeout and a single-in-flight guard so
    /// they can't overlap and stall WDA; taps go through /actions too, so they're
    /// covered. Keys are not gestures.
    private func sendInput(_ path: String, _ body: [String: Any]) {
        let isGesture = path.hasSuffix("/actions") || path == "/wda/homescreen"
        if isGesture {
            if gestureInFlight {
                NSLog("[iMirror] gesture dropped — one already in flight: \(path)")
                return
            }
            gestureInFlight = true
            // Backstop only — the request completion (below) is the real clear. It
            // MUST exceed the gesture request timeout, or it races a still-executing
            // gesture and lets a second one fire concurrently, which stalls WDA
            // (single XCUITest queue) and trips the health probe into a false .down.
            DispatchQueue.main.asyncAfter(deadline: .now() + gestureTimeoutSec + 2) { [weak self] in
                self?.gestureInFlight = false
            }
        }
        send("POST", path, body, timeout: isGesture ? gestureTimeoutSec : 8) { [weak self] code, _, _ in
            DispatchQueue.main.async {
                if isGesture { self?.gestureInFlight = false }
                if code == 404 { self?.sessionId = nil }
            }
        }
    }

    private func pointer(_ steps: [[String: Any]]) -> [String: Any] {
        ["actions": [[
            "type": "pointer",
            "id": "finger1",
            "parameters": ["pointerType": "touch"],
            "actions": steps,
        ]]]
    }

    // MARK: HTTP core (fresh connection per request)

    private func send(_ method: String, _ path: String, _ body: [String: Any]?,
                      timeout: TimeInterval = 8,
                      completion: @escaping (Int?, [String: Any]?, Error?) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        let oneShot = URLSession(configuration: cfg)
        oneShot.dataTask(with: req) { data, resp, error in
            oneShot.finishTasksAndInvalidate()
            let code = (resp as? HTTPURLResponse)?.statusCode
            // Parse off the main thread, then deliver the completion ON main.
            // Completions mutate shared state (sessionId, deviceSize) that the UI
            // event handlers and the health-probe timer read on the main thread;
            // hopping here confines those writes to main so reads can't tear.
            // (sendInput already main-hops its own state; this generalises it.)
            let json = error == nil
                ? data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                : nil
            DispatchQueue.main.async {
                if let error { completion(code, nil, error); return }
                completion(code, json, nil)
            }
        }.resume()
    }
}

enum WDAError: LocalizedError {
    case notConnected
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WDA not connected"
        case .badResponse(let s): return "WDA bad response: \(s)"
        }
    }
}
