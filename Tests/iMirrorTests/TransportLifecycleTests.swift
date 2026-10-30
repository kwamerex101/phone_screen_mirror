import XCTest
@testable import iMirror

final class TransportLifecycleTests: XCTestCase {
    func testStopCancelsQueuedInitialBringUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-ios")
        let marker = root.appendingPathComponent("spawned")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let startup = DispatchQueue(label: "test.transport.startup")
        startup.suspend()
        let transport = Transport(goios: binary, startupQueue: startup)
        transport.start()
        transport.stop()
        startup.resume()
        defer { transport.stop() }
        // Let the queued sweep and its main-queue completion both drain.
        let settled = expectation(description: "startup drained")
        startup.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 3)
        XCTAssertFalse(transport.hasChildHandlesForTesting,
                       "automation off still launched a go-ios child")
    }

    func testStopAfterSweepCancelsAlreadyQueuedBringUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-ios")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let startup = DispatchQueue(label: "test.transport.startup-completion")
        let transport = Transport(goios: binary, startupQueue: startup)
        transport.start()
        // Hold main while sweep finishes and queues its completion onto main.
        startup.sync {}
        transport.stop()
        defer { transport.stop() }
        let drained = expectation(description: "main completion drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertFalse(transport.hasChildHandlesForTesting,
                       "a stale sweep completion launched children after stop")
    }

}
