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

    private var connection: NWConnection?
    private var parser = MJPEGStreamParser()
    private var generation: UInt64 = 0
    private var reconnectWork: DispatchWorkItem?
    private var stopped = true
    private var reconnectDelay: TimeInterval = 0.5
    private let reconnectDelayCap: TimeInterval = 5.0

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

    deinit {
        reconnectWork?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    /// Starts (or restarts) the stream. Calling start() again while already
    /// running tears down the old connection and opens a fresh one: simplest
    /// to reason about, and callers never need to check "is it already
    /// running" themselves before asking for a (re)start.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.closeConnection()
            self.stopped = false
            self.reconnectDelay = 0.5
            self.openConnection()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.stopped = true
            self.closeConnection()
        }
    }

    // MARK: Connection lifecycle

    private func openConnection() {
        guard !stopped else { return }
        closeConnection()
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
            disconnect(conn)
        default:
            break
        }
    }

    private func closeConnection() {
        reconnectWork?.cancel()
        reconnectWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = MJPEGStreamParser()
    }

    private func disconnect(_ conn: NWConnection) {
        guard connection === conn else { return }
        closeConnection()
        onStateChange?(false)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = reconnectDelay
        let expectedGeneration = generation
        reconnectDelay = min(reconnectDelay * 2, reconnectDelayCap)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.generation == expectedGeneration,
                  self.connection == nil else { return }
            self.openConnection()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
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
                    do {
                        if let payload = try self.parser.append(data),
                           let source = CGImageSourceCreateWithData(payload as CFData, nil),
                           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            self.onFrame?(image)
                        }
                    } catch {
                        NSLog("iMirror: invalid MJPEG stream: \(error)")
                        self.disconnect(conn)
                        return
                    }
                }
                if isComplete || error != nil {
                    self.disconnect(conn)
                    return
                }
                self.receiveMore(on: conn)
            }
        }
    }

}
