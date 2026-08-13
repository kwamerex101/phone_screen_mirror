// Runs an external process and collects its combined stdout+stderr. Split out
// of MCPInstaller so the client adapters can share it and, in tests, swap in
// a stub instead of spawning a real process.

import Foundation

struct ProcessRunner {
    var run: (_ launch: String, _ args: [String]) -> (code: Int32, out: String)

    static let live = ProcessRunner(run: spawn)

    @discardableResult
    static func spawn(_ launch: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
