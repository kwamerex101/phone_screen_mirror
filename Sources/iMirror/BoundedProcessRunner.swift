import Foundation

/// Blocking helper for background queues. A regular output file avoids pipe
/// backpressure and inherited pipe descriptors keeping a read alive forever.
enum BoundedProcessRunner {
    static func run(_ launch: String, _ args: [String], timeout: TimeInterval = 3,
                    maxOutputBytes: Int = 65_536, captureStandardError: Bool = true) -> (code: Int32, out: String, timedOut: Bool) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-process-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forUpdating: outputURL) else {
            return (-1, "Could not create process output file.", false)
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        process.standardOutput = output
        process.standardError = captureStandardError ? output : FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return (-1, error.localizedDescription, false) }
        let timedOut = exited.wait(timeout: .now() + max(0, timeout)) == .timedOut
        if timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.seek(toOffset: 0)
        let data = (try? output.read(upToCount: max(0, maxOutputBytes))) ?? Data()
        return (timedOut ? -1 : process.terminationStatus,
                String(data: data, encoding: .utf8) ?? "", timedOut)
    }
}
