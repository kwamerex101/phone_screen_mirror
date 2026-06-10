// Transport — fully self-managed USB control channel for iMirror.
//
// The app spawns everything needed for headless control (no Xcode, no sudo):
//
//   ios tunnel start --userspace   RSD tunnel for iOS 17+ (userspace = no root)
//   ios runwda                     launches WebDriverAgent on the device
//   ios forward 8101 8100          USB relay of WDA's port to localhost:8101
//   LocalRelay 8100 -> 8101        in-process loopback pump (CFNetwork-friendly)
//
//   iMirror (CFNetwork) -> 127.0.0.1:8100 (relay) -> :8101 (forward) --USB--> WDA
//
// Each child is auto-restarted if it dies, so the channel self-heals (a wedged
// WDA — the recurring failure under Xcode — just respawns). All children are
// terminated when the app quits.
//
// SECURITY: the relay binds 127.0.0.1 only. WDA has no auth on the wire, so it is
// never exposed beyond loopback.

import Foundation
import Network

// MARK: - Locate the bundled go-ios binary

func locateGoIOS() -> URL? {
    if let bundled = Bundle.main.url(forResource: "ios", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    if let env = ProcessInfo.processInfo.environment["IMIRROR_IOS_BIN"],
       FileManager.default.isExecutableFile(atPath: env) {
        return URL(fileURLWithPath: env)
    }
    // Dev fallback: <repo>/ios-mirror/tools/go-ios/bin/ios relative to this source.
    let dev = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/go-ios/bin/ios")
    return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
}

// MARK: - A child process that respawns if it exits

final class ManagedProcess {
    private let binary: URL
    private let args: [String]
    private let label: String
    private let restartDelay: TimeInterval
    private let workDir: URL
    private var process: Process?
    private var stopped = false
    // `stopped`/`process` are touched from the caller's thread, the spawn-delay
    // queue, AND Process.terminationHandler's private queue — guard every access.
    private let lock = NSLock()

    init(binary: URL, args: [String], label: String, restartDelay: TimeInterval, workDir: URL) {
        self.binary = binary
        self.args = args
        self.label = label
        self.restartDelay = restartDelay
        self.workDir = workDir
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func start() {
        lock.lock(); stopped = false; lock.unlock()
        spawn()
    }

    func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        lock.unlock()
        p?.terminationHandler = nil
        p?.terminate()
    }

    /// Kill the current instance so the termination handler respawns it. Used by
    /// the watchdog to recover a hung child (one that never exits on its own).
    func bounce() {
        NSLog("iMirror: bouncing \(label)")
        lock.lock(); let p = process; lock.unlock()
        p?.terminate()
    }

    private func spawn() {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        // go-ios writes selfIdentity.plist + pair records into its cwd; the app's
        // default cwd is "/" (read-only), so point it at a writable dir.
        p.currentDirectoryURL = workDir
        // Child output is discarded by default. Set IMIRROR_DEBUG=1 to capture it
        // to <workDir>/<label>.log (truncated per spawn, so it stays bounded).
        if ProcessInfo.processInfo.environment["IMIRROR_DEBUG"] != nil {
            let logURL = workDir.appendingPathComponent("\(label).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logURL) {
                p.standardOutput = fh
                p.standardError = fh
            }
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.isStopped else { return }
            NSLog("iMirror: \(self.label) exited — restarting in \(Int(self.restartDelay))s")
            DispatchQueue.global().asyncAfter(deadline: .now() + self.restartDelay) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.spawn()
            }
        }
        do {
            try p.run()
            lock.lock(); process = p; lock.unlock()
            NSLog("iMirror: started \(label) (pid \(p.processIdentifier))")
        } catch {
            NSLog("iMirror: failed to start \(label): \(error.localizedDescription)")
        }
    }
}

// MARK: - In-process loopback TCP relay

final class LocalRelay {
    private let listenPort: UInt16
    private let backendPort: UInt16
    private let queue = DispatchQueue(label: "imirror.relay")
    private var listener: NWListener?

    init(listen: UInt16 = 8100, backend: UInt16 = 8101) {
        self.listenPort = listen
        self.backendPort = backend
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                  port: NWEndpoint.Port(rawValue: listenPort)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("iMirror: relay 127.0.0.1:\(listenPort) -> 127.0.0.1:\(backendPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ client: NWConnection) {
        let backend = NWConnection(host: "127.0.0.1",
                                   port: NWEndpoint.Port(rawValue: backendPort)!,
                                   using: .tcp)
        client.start(queue: queue)
        backend.start(queue: queue)
        pump(client, backend)
        pump(backend, client)
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                from.cancel(); to.cancel()
                return
            }
            self.pump(from, to)
        }
    }
}

// MARK: - Transport facade

final class Transport {
    private let relay = LocalRelay(listen: 8100, backend: 8101)
    private let goios: URL?
    private let workDir: URL
    private var tunnel: ManagedProcess?
    private var wda: ManagedProcess?
    private var forward: ManagedProcess?

    init() {
        goios = locateGoIOS()
        // Writable working dir for go-ios (selfIdentity.plist, pair records).
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("iMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        workDir = support
    }

    /// True if the go-ios binary was found, so the app can run WDA headless. If
    /// false, the user must bring up WDA themselves (Xcode or scripts/wda-up.sh).
    var canSelfManage: Bool { goios != nil }

    func start() {
        do { try relay.start() }
        catch { NSLog("iMirror: relay failed: \(error.localizedDescription)") }
        guard goios != nil else {
            NSLog("iMirror: go-ios not found — relying on external WDA bring-up")
            return
        }
        // A previous instance that crashed (rather than quit cleanly) can leave a
        // go-ios child reparented to launchd — most often the tunnel, which then
        // holds the device's RSD state and port 60105 so a fresh tunnel can't
        // bind. Those orphans are invisible to our ManagedProcess handles, so
        // restartChain() can never kill them and WDA loops on red forever. Sweep
        // them before bringing up a clean chain.
        sweepStrayProcesses()
        startChildren()
    }

    /// Kill stray go-ios children left over from a previous app instance, matched
    /// by our own binary path so unrelated processes are never touched. Only safe
    /// to call when our own handles are stopped/nil — otherwise it would kill the
    /// children we just spawned.
    private func sweepStrayProcesses() {
        guard let bin = goios else { return }
        for sub in ["tunnel", "runwda", "forward"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "\(bin.path) \(sub)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() }
            catch { NSLog("iMirror: sweep of stray \(sub) failed: \(error.localizedDescription)") }
        }
    }

    /// Bumped on every stop/restart. Delayed bring-up closures capture the value
    /// at schedule time and abort if it moved — otherwise a stop() landing inside
    /// startChildren()'s 8s window would still spawn runwda/forward as orphans
    /// (handles not yet assigned, so nothing would ever stop them).
    private var chainGeneration = 0

    /// Start the go-ios children in order: tunnel first, then (after it has had
    /// time to establish) runwda + forward.
    private func startChildren() {
        guard let bin = goios else { return }
        let gen = chainGeneration
        tunnel = ManagedProcess(binary: bin, args: ["tunnel", "start", "--userspace"],
                                label: "tunnel", restartDelay: 15, workDir: workDir)
        tunnel?.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.chainGeneration == gen else { return }
            self.wda = ManagedProcess(binary: bin, args: ["runwda"],
                                      label: "runwda", restartDelay: 6, workDir: self.workDir)
            self.wda?.start()
            self.forward = ManagedProcess(binary: bin, args: ["forward", "8101", "8100"],
                                          label: "forward", restartDelay: 3, workDir: self.workDir)
            self.forward?.start()
        }
    }

    func stop() {
        chainGeneration += 1
        relay.stop()
        forward?.stop()
        wda?.stop()
        tunnel?.stop()
    }

    /// Full chain reset for the watchdog: when WDA is wedged early (often the
    /// tunnel/testmanagerd state), bouncing runwda alone isn't enough — tear the
    /// whole chain down, let the device settle, then bring it back up in order.
    /// This mirrors the manual recovery that reliably works.
    func restartChain() {
        NSLog("iMirror: restarting full go-ios chain")
        chainGeneration += 1
        forward?.stop(); wda?.stop(); tunnel?.stop()
        forward = nil; wda = nil; tunnel = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            // Our handles are stopped; reap any child that outlived its handle
            // (e.g. a tunnel reparented to launchd) so the fresh chain owns a
            // clean device + port 60105.
            self.sweepStrayProcesses()
            self.startChildren()
        }
    }
}
