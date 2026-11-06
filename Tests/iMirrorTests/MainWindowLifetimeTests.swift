import XCTest

final class MainWindowLifetimeTests: XCTestCase {
    func testLateStatusUpdateAfterWindowClosesDoesNotAccessReleasedWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-window-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // AppKit drains its autorelease pools in NSApplication.run(). A plain
        // XCTest wait/RunLoop does not reproduce release-on-close, so exercise
        // the production window factory in a separate real application loop.
        let source = """
        import AppKit
        final class Owner: NSObject, NSApplicationDelegate {
            var window: NSWindow!
            let label = NSTextField(labelWithString: "Mirroring")
            func applicationDidFinishLaunching(_ notification: Notification) {
                window = makeMainWindow()
                window.contentView?.addSubview(label)
                window.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.window.close() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.label.stringValue = "Waiting for video"
                    guard self.window.contentView != nil else { exit(2) }
                    NSApp.terminate(nil)
                }
            }
            func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
        }
        let app = NSApplication.shared
        let owner = Owner()
        app.delegate = owner
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(3) }
        app.run()
        """
        let main = directory.appendingPathComponent("main.swift")
        try source.write(to: main, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("window-probe")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", root.appendingPathComponent("Sources/iMirror/MainWindow.swift").path,
                              main.path, "-o", binary.path]
        let compileOutput = Pipe()
        compiler.standardOutput = compileOutput
        compiler.standardError = compileOutput
        try compiler.run()
        let compileText = String(decoding: compileOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, compileText)
        guard compiler.terminationStatus == 0 else { return }

        let probe = Process()
        probe.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["NSZombieEnabled"] = "YES"
        probe.environment = environment
        let output = Pipe()
        probe.standardOutput = output
        probe.standardError = output
        try probe.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationReason, .exit, text)
        XCTAssertEqual(probe.terminationStatus, 0, text)
    }
}
