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
        let body: [String: Any] = ["capabilities": ["alwaysMatch": [:], "firstMatch": [[:]]]]
        send("POST", "/session", body) { [weak self] _, json, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            let value = (json?["value"] as? [String: Any]) ?? json ?? [:]
            guard let sid = (value["sessionId"] as? String) ?? (json?["sessionId"] as? String) else {
                completion(.failure(WDAError.badResponse("no sessionId")))
                return
            }
            self.sessionId = sid
            self.fetchWindowSize(completion: completion)
        }
    }

    private func fetchWindowSize(completion: @escaping (Result<CGSize, Error>) -> Void) {
        guard let sid = sessionId else { completion(.failure(WDAError.notConnected)); return }
        send("GET", "/session/\(sid)/window/size", nil) { [weak self] _, json, error in
            if let error { completion(.failure(error)); return }
            let v = (json?["value"] as? [String: Any]) ?? json ?? [:]
            guard let w = (v["width"] as? NSNumber)?.doubleValue,
                  let h = (v["height"] as? NSNumber)?.doubleValue else {
                completion(.failure(WDAError.badResponse("no window size")))
                return
            }
            let size = CGSize(width: w, height: h)
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
                   let v = (json?["value"] as? [String: Any]),
                   let w = (v["width"] as? NSNumber)?.doubleValue,
                   let h = (v["height"] as? NSNumber)?.doubleValue {
                    self.deviceSize = CGSize(width: w, height: h)
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
            if error != nil { completion(false); return }
            let v = json?["value"] as? [String: Any]
            completion((v?["ready"] as? Bool) ?? false)
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

    /// Drag through a path of device points (one continuous gesture). Following
    /// the real path — rather than a straight start→end line — makes scrolling
    /// and swipes track the cursor faithfully.
    func drag(path: [CGPoint], totalMs: Int = 300) {
        guard let sid = sessionId, let first = path.first else { return }
        var steps: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": first.x, "y": first.y],
            ["type": "pointerDown", "button": 0],
        ]
        let segments = max(1, path.count - 1)
        let perSegment = max(8, totalMs / segments)
        for p in path.dropFirst() {
            steps.append(["type": "pointerMove", "duration": perSegment, "x": p.x, "y": p.y])
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

    /// Sends an input request; a 404 means the session expired — drop it so the
    /// next health probe recreates it transparently.
    private func sendInput(_ path: String, _ body: [String: Any]) {
        send("POST", path, body) { [weak self] code, _, _ in
            if code == 404 { self?.sessionId = nil }
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
                      completion: @escaping (Int?, [String: Any]?, Error?) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        let oneShot = URLSession(configuration: cfg)
        oneShot.dataTask(with: req) { data, resp, error in
            defer { oneShot.finishTasksAndInvalidate() }
            let code = (resp as? HTTPURLResponse)?.statusCode
            if let error { completion(code, nil, error); return }
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            completion(code, json, nil)
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
