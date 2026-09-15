// MJPEGClient — raw TCP client for WDA's built-in MJPEG mirror stream.
//
// WDA ships its own MJPEG server (separate from the appium/session HTTP API),
// serving a single long-lived multipart/x-mixed-replace response over
// HTTP/1.0-ish semantics: the server never closes the connection on its own,
// it just keeps appending new JPEG parts forever. The wire looks like:
//
//   HTTP/1.0 200 OK
//   Server: WDA MJPEG Server
//   Connection: close
//   Content-Type: multipart/x-mixed-replace; boundary=--BoundaryString
//
//   --BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: <N>\r\n\r\n<N bytes of JPEG><\r\n?>--BoundaryString\r\n...
//
// i.e. after the initial response headers, the body is an unbounded sequence
// of parts: a boundary marker, a small set of part headers terminated by a
// blank line, then exactly Content-Length bytes of raw JPEG, then (usually,
// not guaranteed) a trailing \r\n before the next boundary.
//
// Why NWConnection over TCP instead of URLSession: URLSession/CFNetwork is
// fussy against the go-ios forward this app talks through (that fussiness is
// exactly why Transport.swift already runs an in-process LocalRelay pump to
// keep CFNetwork happy for the WDA HTTP API). A raw NWConnection loopback
// socket doesn't route through CFNetwork at all, so it doesn't need that
// workaround: it can dial the go-ios "forward" port directly.
//
// SECURITY: loopback only, same rule as WDAClient — WDA has no auth on the
// wire, so this must never be pointed at anything but 127.0.0.1.

import Foundation
import Network
import CoreGraphics
import ImageIO

final class MJPEGClient {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "imirror.mjpeg")

    private let boundaryMarker = "--BoundaryString"
    private let headerTerminator = "\r\n\r\n"

    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = true
    private var reconnectDelay: TimeInterval = 0.5
    private let reconnectDelayCap: TimeInterval = 5.0

    // Parse state for the current response: have we consumed the initial
    // HTTP response headers yet (steps before the first boundary)?
    private var consumedResponseHeaders = false

    /// Called per decoded frame, on the internal `imirror.mjpeg` queue. Do not
    /// assume main thread; hop yourself if you touch UI from here.
    var onFrame: ((CGImage) -> Void)?
    /// Called on the internal queue whenever the stream connects or drops.
    /// true = connected/streaming, false = disconnected.
    var onStateChange: ((Bool) -> Void)?

    init(host: String = "127.0.0.1", port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Starts (or restarts) the stream. Calling start() again while already
    /// running tears down the old connection and opens a fresh one: simplest
    /// to reason about, and callers never need to check "is it already
    /// running" themselves before asking for a (re)start.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.reconnectDelay = 0.5
            self.openConnection()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.buffer.removeAll()
            self.consumedResponseHeaders = false
        }
    }

    // MARK: Connection lifecycle

    private func openConnection() {
        guard !stopped else { return }
        buffer.removeAll()
        consumedResponseHeaders = false
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleState(state, for: conn) }
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State, for conn: NWConnection) {
        // Ignore callbacks from a connection we've already moved past (an old
        // one still winding down after a reconnect kicked off a new one).
        guard conn === connection else { return }
        switch state {
        case .ready:
            reconnectDelay = 0.5
            sendRequest(on: conn)
            onStateChange?(true)
            receiveMore(on: conn)
        case .failed, .cancelled:
            onStateChange?(false)
            conn.cancel()
            if connection === conn { connection = nil }
            scheduleReconnect()
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, reconnectDelayCap)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.openConnection()
        }
    }

    private func sendRequest(on conn: NWConnection) {
        let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
            if let error {
                NSLog("iMirror: MJPEG request send failed: \(error.localizedDescription)")
            }
        })
    }

    // MARK: Receive loop

    private func receiveMore(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if isComplete || error != nil {
                    conn.cancel()
                    return
                }
                self.receiveMore(on: conn)
            }
        }
    }

    // MARK: Multipart parsing (runs on `queue` only)

    /// Consumes as many complete JPEG parts as the buffer currently holds,
    /// leaving any trailing partial data in place for the next receive.
    private func drainBuffer() {
        if !consumedResponseHeaders {
            guard let headerEnd = range(of: headerTerminator, in: buffer, from: 0) else { return }
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            consumedResponseHeaders = true
        }

        while true {
            guard let boundaryRange = range(of: boundaryMarker, in: buffer, from: buffer.startIndex) else {
                return   // no boundary buffered yet; wait for more data
            }
            guard let partHeaderEnd = range(of: headerTerminator, in: buffer, from: boundaryRange.upperBound) else {
                return   // boundary seen but part headers not fully buffered yet
            }
            let partHeaders = buffer[boundaryRange.upperBound..<partHeaderEnd.lowerBound]
            guard let contentLength = parseContentLength(partHeaders) else {
                // Malformed/unparseable part headers: resync on the next boundary
                // rather than getting stuck, and never trust attacker-controlled
                // bytes enough to force-unwrap them.
                resyncPastBoundary(after: boundaryRange.upperBound)
                continue
            }

            let payloadStart = partHeaderEnd.upperBound
            let payloadEnd = buffer.index(payloadStart, offsetBy: contentLength, limitedBy: buffer.endIndex)
            guard let payloadEnd else {
                return   // full JPEG payload not buffered yet; wait for more data
            }

            let payload = buffer[payloadStart..<payloadEnd]
            if let source = CGImageSourceCreateWithData(payload as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                onFrame?(image)
            }

            // Advance past the payload, tolerating an optional trailing \r\n
            // before the next boundary.
            var next = payloadEnd
            if buffer.distance(from: next, to: buffer.endIndex) >= 2,
               buffer[next] == 0x0D, buffer[buffer.index(after: next)] == 0x0A {
                next = buffer.index(next, offsetBy: 2)
            }
            buffer.removeSubrange(buffer.startIndex..<next)
        }
    }

    /// Drops everything up to and including the next boundary marker found
    /// at or after `from`, so a malformed part can't wedge the parser. If no
    /// further boundary is buffered yet, leaves the buffer as-is (from the
    /// search start onward) to wait for more data.
    private func resyncPastBoundary(after from: Data.Index) {
        guard let next = range(of: boundaryMarker, in: buffer, from: from) else {
            // Nothing to resync to yet; keep whatever's unread so a boundary
            // split across receives still gets found once more data arrives.
            if from > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<from) }
            return
        }
        buffer.removeSubrange(buffer.startIndex..<next.upperBound)
    }

    /// Case-insensitive, tolerant scan for "Content-Length: <N>" within a
    /// part-header slice. No general HTTP parser needed: these are a couple
    /// of short, known-shape lines.
    private func parseContentLength(_ headerBytes: Data.SubSequence) -> Int? {
        guard let text = String(data: Data(headerBytes), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Finds the first occurrence of `needle` in `haystack` at or after
    /// `start`. Small helper since Data has no built-in substring search.
    private func range(of needle: String, in haystack: Data, from start: Data.Index) -> Range<Data.Index>? {
        guard let needleData = needle.data(using: .utf8), !needleData.isEmpty else { return nil }
        guard start < haystack.endIndex else { return nil }
        return haystack.range(of: needleData, options: [], in: start..<haystack.endIndex)
    }
}
