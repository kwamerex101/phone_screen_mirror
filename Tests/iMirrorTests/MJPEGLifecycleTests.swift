import XCTest
import Network
@testable import iMirror

final class MJPEGLifecycleTests: XCTestCase {
    func testRepeatedStartClosesPreviousSocket() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.mjpeg.server")
        let ready = expectation(description: "listener ready")
        let first = expectation(description: "first stream")
        let second = expectation(description: "replacement stream")
        let closed = expectation(description: "previous stream closed")
        final class SocketStore: @unchecked Sendable { var values: [NWConnection] = [] }
        let sockets = SocketStore()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { socket in
            sockets.values.append(socket)
            let index = sockets.values.count
            socket.start(queue: queue)
            if index == 1 {
                @Sendable func receive() {
                    socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, complete, error in
                        if complete || error != nil { closed.fulfill() } else { receive() }
                    }
                }
                receive()
                first.fulfill()
            } else { second.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        let client = MJPEGClient(port: try XCTUnwrap(listener.port).rawValue)
        defer {
            client.stop()
            queue.sync { sockets.values.forEach { $0.cancel() }; listener.cancel() }
        }
        client.start()
        wait(for: [first], timeout: 2)
        client.start()
        wait(for: [second, closed], timeout: 2)
    }

    func testExplicitRestartInvalidatesQueuedReconnect() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.mjpeg.reconnect")
        let ready = expectation(description: "listener ready")
        let dropped = expectation(description: "first stream dropped")
        let replacement = expectation(description: "explicit replacement")
        let unexpected = expectation(description: "stale reconnect replaced healthy stream")
        unexpected.isInverted = true
        final class SocketStore: @unchecked Sendable { var values: [NWConnection] = [] }
        let sockets = SocketStore()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { socket in
            sockets.values.append(socket)
            let index = sockets.values.count
            if index == 1 {
                socket.stateUpdateHandler = { state in
                    if case .ready = state { socket.cancel() }
                }
            }
            socket.start(queue: queue)
            if index == 2 { replacement.fulfill() }
            if index > 2 { unexpected.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        let client = MJPEGClient(port: try XCTUnwrap(listener.port).rawValue)
        client.onStateChange = { connected in if !connected { dropped.fulfill() } }
        defer {
            client.stop()
            queue.sync {
                sockets.values.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
                listener.cancel()
            }
        }
        client.start()
        wait(for: [dropped], timeout: 2)
        client.start()
        wait(for: [replacement], timeout: 2)
        wait(for: [unexpected], timeout: 0.8)
    }


    func testMalformedLengthDisconnectsStream() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.mjpeg.malformed")
        let ready = expectation(description: "listener ready")
        let disconnected = expectation(description: "invalid stream disconnected")
        final class SocketStore: @unchecked Sendable { var values: [NWConnection] = [] }
        let sockets = SocketStore()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { socket in
            sockets.values.append(socket)
            socket.start(queue: queue)
            let response = "HTTP/1.0 200 OK\r\n\r\n--BoundaryString\r\nContent-Length: -1\r\n\r\n"
            socket.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        let client = MJPEGClient(port: try XCTUnwrap(listener.port).rawValue)
        client.onStateChange = { connected in if !connected { disconnected.fulfill() } }
        defer {
            client.stop()
            queue.sync { sockets.values.forEach { $0.cancel() }; listener.cancel() }
        }
        client.start()
        wait(for: [disconnected], timeout: 2)
    }

}
