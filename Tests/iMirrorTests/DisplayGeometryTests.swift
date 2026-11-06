import XCTest
import Network
import AppKit
@testable import iMirror

final class DisplayGeometryTests: XCTestCase {
    @MainActor
    func testNativeWindowFollowsActiveDisplayShape() {
        _ = NSApplication.shared
        let window = makeMainWindow()
        window.contentMinSize = NSSize(width: 260, height: 200)
        defer { window.close() }
        for size in [NSSize(width: 1170, height: 2532), NSSize(width: 2100, height: 1800),
                     NSSize(width: 2532, height: 1170), NSSize(width: 1170, height: 2532)] {
            adaptPreviewWindow(window, to: size)
            let content = window.contentRect(forFrameRect: window.frame).size
            XCTAssertEqual(content.width / content.height, size.width / size.height, accuracy: 0.01)
            XCTAssertTrue(window.frame.width.isFinite)
        }
    }

    func testDisplayRefreshDropsCachedPointsAndIgnoresOlderProbe() throws {
        let server = try GeometryServer()
        defer { server.stop() }
        let settingsApplied = expectation(description: "orientation-aware video configured")
        server.onSettings = { settings in
            if settings["mjpegServerFramerate"] != nil {
                XCTAssertEqual(settings["mjpegFixOrientation"] as? Bool, true)
                settingsApplied.fulfill()
            }
        }
        let ready = expectation(description: "server ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let client = WDAClient(base: URL(string: "http://127.0.0.1:\(port)")!)
        let connected = expectation(description: "initial phone geometry")
        client.connect { result in
            XCTAssertEqual(try? result.get(), CGSize(width: 390, height: 844))
            connected.fulfill()
        }
        wait(for: [connected, settingsApplied], timeout: 2)

        let oldProbeArrived = expectation(description: "old probe pending")
        server.queue.sync { server.onDeferredProbe = { oldProbeArrived.fulfill() } }
        let oldProbeFinished = expectation(description: "old probe returned")
        client.probe { _ in oldProbeFinished.fulfill() }
        wait(for: [oldProbeArrived], timeout: 2)

        let refreshed = expectation(description: "opened display geometry")
        client.refreshDisplayGeometry { result in
            XCTAssertEqual(try? result.get(), CGSize(width: 700, height: 600))
            refreshed.fulfill()
        }
        XCTAssertNil(client.deviceSize, "Old touch coordinates must be revoked immediately")
        wait(for: [refreshed], timeout: 2)
        server.queue.sync { server.deferredResponse?() }
        wait(for: [oldProbeFinished], timeout: 2)
        XCTAssertEqual(client.deviceSize, CGSize(width: 700, height: 600),
                       "A request started before opening must not restore the closed display size")
    }
}

private final class GeometryServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.display-geometry")
    let listener: NWListener
    var onDeferredProbe: (() -> Void)?
    var deferredResponse: (() -> Void)?
    var onSettings: (([String: Any]) -> Void)?
    private var windows = 0
    private var sockets: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] socket in
            guard let self else { socket.cancel(); return }
            self.sockets.append(socket)
            socket.start(queue: self.queue)
            self.receive(socket, accumulated: Data())
        }
    }

    private func receive(_ socket: NWConnection, accumulated: Data) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let bytes = accumulated + (data ?? Data())
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !done, error == nil { self.receive(socket, accumulated: bytes) }
                return
            }
            let parts = request.components(separatedBy: "\r\n\r\n")
            let lengthLine = parts[0].components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            let expected = lengthLine.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if parts.dropFirst().joined(separator: "\r\n\r\n").utf8.count < expected {
                if !done, error == nil { self.receive(socket, accumulated: bytes) }
                return
            }
            if request.hasPrefix("GET /session/test/window/size ") {
                self.windows += 1
                if self.windows == 2 {
                    self.deferredResponse = { self.reply(socket, json: "{\"value\":{\"width\":390,\"height\":844}}") }
                    self.onDeferredProbe?()
                } else {
                    let size = self.windows == 1 ? "\"width\":390,\"height\":844" : "\"width\":700,\"height\":600"
                    self.reply(socket, json: "{\"value\":{\(size)}}")
                }
            } else if request.hasPrefix("POST /session ") {
                self.reply(socket, json: "{\"value\":{\"sessionId\":\"test\"}}")
            } else {
                if request.hasPrefix("POST /session/test/appium/settings "),
                   let body = parts.last?.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let settings = json["settings"] as? [String: Any] {
                    self.onSettings?(settings)
                }
                self.reply(socket, json: "{\"value\":{}}")
            }
        }
    }

    private func reply(_ socket: NWConnection, json: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        socket.send(content: Data(response.utf8), completion: .contentProcessed { _ in socket.cancel() })
    }

    func stop() {
        queue.sync {
            deferredResponse = nil
            sockets.forEach { $0.cancel() }
            listener.cancel()
        }
    }
}
