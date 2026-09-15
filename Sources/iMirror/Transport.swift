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
import iMirrorCore

// MARK: - Branded WDA runner identity
//
// The runner is rebranded to iMirror at build time (see scripts/build-wda.sh).
// Xcode appends ".xctrunner" to the UI-test target's bundle id when it wraps it
// into the runner .app, so go-ios is told the *suffixed* id. PRODUCT_NAME stays
// WebDriverAgentRunner, so xctestConfig keeps the default name — but go-ios still
// requires it explicitly whenever bundleid/testrunnerbundleid are set.
enum WDAIdentity {
    static let runnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let testRunnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let xctestConfig = "WebDriverAgentRunner.xctest"
}

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
    // `stopped`/`process`/`generation`/`readySeen`/`killedUnready` are touched
    // from the caller's thread, the spawn-delay queue, the readiness-poll queue,
    // AND Process.terminationHandler's private queue — guard every access.
    private let lock = NSLock()

    // Circuit breaker: a child that can never start (bad signing, unsupported
    // iOS) would otherwise crash-loop at `restartDelay` forever. Count quick
    // deaths; back off exponentially, and after `maxQuickFailures` give up so the
    // app's slower chain-level watchdog takes over instead of a tight spin.
    private var spawnedAt: Date?
    private var consecutiveFailures = 0
    private let maxQuickFailures = 8
    // A child that stayed up at least this long was healthy — a later exit is a
    // normal drop (device asleep, WDA recycled), not a failed launch, so the
    // failure streak resets rather than marching toward the give-up cap.
    private let healthyRuntimeSec: TimeInterval = 20
    /// Called (once, on a background queue) when the breaker trips. Lets the
    /// Transport surface a terminal "this device/OS may not support WDA" state
    /// instead of the channel silently looping on red.
    var onGaveUp: ((String) -> Void)?

    // Readiness deadline: a wedged `runwda` never exits, so the exit-triggered
    // respawn above never fires for it. If a readiness check is supplied, poll it
    // after spawn and SIGKILL the child if it never reports ready within
    // `readyWithin`, so the existing termination handler respawns it anyway.
    private let readinessCheck: (() -> Bool)?
    private let readyWithin: TimeInterval
    // Production cadence is 2s so an idle readiness check (typically an HTTP
    // probe) doesn't spin. Tests inject a much shorter interval to exercise the
    // deadline without a multi-second sleep per case.
    private let readinessPollInterval: TimeInterval
    // Bumped on every spawn so a readiness poll from a previous spawn can never
    // act on (or kill) a newer process.
    private var generation = 0
    private var readySeen = false
    // Set right before a readiness-deadline kill and consumed by the termination
    // handler for that same spawn, so the failure counter can tell a wedge apart
    // from a normal exit — see the termination handler below.
    private var killedUnready = false

    init(binary: URL, args: [String], label: String, restartDelay: TimeInterval, workDir: URL,
         readinessCheck: (() -> Bool)? = nil, readyWithin: TimeInterval = 0,
         readinessPollInterval: TimeInterval = 2) {
        self.binary = binary
        self.args = args
        self.label = label
        self.restartDelay = restartDelay
        self.workDir = workDir
        self.readinessCheck = readinessCheck
        self.readyWithin = readyWithin
        self.readinessPollInterval = readinessPollInterval
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// The pid of the currently running spawn, if any. Test-only introspection.
    var currentPidForTesting: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true ? process?.processIdentifier : nil
    }

    func start() {
        lock.lock()
        stopped = false
        consecutiveFailures = 0
        killedUnready = false
        lock.unlock()
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
        // terminate() only sends SIGTERM; a wedged child that ignores it would
        // otherwise linger (and, on quit, reparent to launchd). Escalate to
        // SIGKILL shortly after if it hasn't exited — off the caller's thread so
        // neither app-quit nor a chain restart blocks waiting on it.
        if let p {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Kill the current instance so the termination handler respawns it. Used by
    /// the watchdog to recover a hung child (one that never exits on its own).
    func bounce() {
        NSLog("iMirror: bouncing \(label)")
        lock.lock(); let p = process; lock.unlock()
        p?.terminate()
        // terminate() only sends SIGTERM; a wedged child ignores it and would
        // never actually bounce. Escalate to SIGKILL shortly after if it's still
        // running, off the caller's thread, same pattern as stop().
        if let p {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Poll `readinessCheck` for the spawn identified by `myGeneration`, killing
    /// its process if it never reports ready within `readyWithin`. Stops on its
    /// own once ready, once a newer spawn replaces this one, or once stopped.
    private func scheduleReadinessPoll(process p: Process, generation myGeneration: Int,
                                       start: TimeInterval, check: @escaping () -> Bool) {
        DispatchQueue.global().asyncAfter(deadline: .now() + readinessPollInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == myGeneration && !self.stopped
            self.lock.unlock()
            guard stillCurrent else { return }

            if check() {
                self.lock.lock()
                if self.generation == myGeneration { self.readySeen = true }
                self.lock.unlock()
                return   // ready — poll is done
            }

            // Monotonic clock: ProcessInfo.systemUptime, never Date(), so a Mac
            // sleep between polls can't skew the elapsed time and trigger a
            // spurious kill right after wake.
            let uptime = ProcessInfo.processInfo.systemUptime - start
            self.lock.lock()
            let shouldKill = self.generation == myGeneration && !self.stopped
                && managedProcessShouldKillForUnreadiness(uptime: uptime, readySeen: self.readySeen, readyWithin: self.readyWithin)
            if shouldKill { self.killedUnready = true }
            self.lock.unlock()

            if shouldKill {
                NSLog("iMirror: \(self.label) not ready within \(Int(self.readyWithin))s — killing")
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                return
            }
            self.scheduleReadinessPoll(process: p, generation: myGeneration, start: start, check: check)
        }
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
            let ranFor = self.spawnedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.lock.lock()
            let wasKilledUnready = self.killedUnready
            self.killedUnready = false
            if wasKilledUnready {
                // A readiness-deadline kill is a failed launch no matter how long
                // the wedged process happened to sit there — it never actually
                // served WDA, so it must NOT reset the streak like a healthy exit
                // would, or a permanent wedge would never trip the give-up breaker.
                self.consecutiveFailures += 1
            } else if ranFor >= self.healthyRuntimeSec {
                self.consecutiveFailures = 0        // was healthy; this is a normal drop
            } else {
                self.consecutiveFailures += 1       // died fast; likely a failed launch
            }
            let failures = self.consecutiveFailures
            self.lock.unlock()
            // Exponential backoff capped at 60s so an unrecoverable child (bad
            // signing, unsupported iOS, or just an unplugged phone) can't spin at
            // the base delay (runwda: 6s) for the whole app lifetime. We keep
            // retrying at the cap — a later replug still recovers on its own —
            // but fire onGaveUp exactly once when we cross the threshold so the
            // app can surface a terminal-looking state instead of silent looping.
            let delay = min(self.restartDelay * pow(2.0, Double(max(0, failures - 1))), 60)
            if failures == self.maxQuickFailures {
                NSLog("iMirror: \(self.label) failed \(failures)x — backing off to "
                      + "\(Int(delay))s (device/OS may not support WDA, or phone is unplugged)")
                self.onGaveUp?(self.label)
            } else {
                NSLog("iMirror: \(self.label) exited — restarting in \(Int(delay))s (fail \(failures))")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.spawn()
            }
        }
        do {
            try p.run()
            lock.lock()
            process = p
            spawnedAt = Date()
            generation += 1
            let myGeneration = generation
            readySeen = false
            lock.unlock()
            NSLog("iMirror: started \(label) (pid \(p.processIdentifier))")
            if let readinessCheck, readyWithin > 0 {
                scheduleReadinessPoll(process: p, generation: myGeneration,
                                      start: ProcessInfo.processInfo.systemUptime, check: readinessCheck)
            }
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
    private var mjpegForward: ManagedProcess?

    /// Set by the app to surface a terminal state when the WDA runner can't be
    /// started at all (bad signing / unsupported device) — invoked on the main
    /// thread. Distinct from a transient drop, which self-heals silently.
    var onWDAUnrecoverable: (() -> Void)?

    /// Set by the app to reflect the runner check/install (progress + outcome) in
    /// the UI. Invoked on the main thread.
    var onRunnerInstall: ((RunnerInstallEvent) -> Void)?

    private func emitInstall(_ event: RunnerInstallEvent) {
        guard let cb = onRunnerInstall else { return }
        DispatchQueue.main.async { cb(event) }
    }

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
        // them before bringing up a clean chain — off the main thread, since it
        // fork/exec/waits three `pkill`s and start() is called from the UI (app
        // launch / Automation toggle).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.sweepStrayProcesses()
            DispatchQueue.main.async { self?.startChildren() }
        }
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
    /// startChildren()'s readiness window would still spawn runwda/forward as
    /// orphans (handles not yet assigned, so nothing would ever stop them).
    /// Written on main (from start/stop/restartChain), read from the background
    /// bring-up queue — guard both with a lock so the comparison can't tear.
    private let genLock = NSLock()
    private var _chainGeneration = 0
    private var chainGeneration: Int {
        get { genLock.lock(); defer { genLock.unlock() }; return _chainGeneration }
        set { genLock.lock(); _chainGeneration = newValue; genLock.unlock() }
    }

    /// Poll go-ios's tunnel agent for an *established device tunnel* — not just the
    /// agent process being up. The `/ready` endpoint returns 200 the moment the
    /// agent starts, well before the device tunnel exists, so `apps`/`install`
    /// (which route through the tunnel on iOS 17+) would run too early and fail.
    /// `/tunnels` instead returns a non-empty list (each entry carries a "udid"
    /// and "rsdPort") only once a device tunnel is actually established.
    private func tunnelReady() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:60105/tunnels") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        let sem = DispatchSemaphore(value: 0)
        var ready = false
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            if let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
               let data, let body = String(data: data, encoding: .utf8),
               body.contains("\"udid\"") {          // at least one device tunnel is up
                ready = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return ready
    }

    /// Start the go-ios children: the tunnel first, then — once the tunnel is
    /// actually ready — check/install the runner and launch runwda + forward.
    ///
    /// Ordering matters: on iOS 17+ go-ios routes `apps --list` and `install`
    /// through the tunnel agent, so they must run AFTER the tunnel is up. (An
    /// earlier version ran the install in parallel with tunnel bring-up on the
    /// assumption it was usbmuxd-only; in practice that made the check/install
    /// fail before the agent was ready.)
    private func startChildren() {
        guard let bin = goios else { return }
        let gen = chainGeneration
        tunnel = ManagedProcess(binary: bin, args: ["tunnel", "start", "--userspace"],
                                label: "tunnel", restartDelay: 15, workDir: workDir)
        tunnel?.start()
        DispatchQueue.global().async { [weak self] in
            guard let self, self.chainGeneration == gen else { return }
            // Wait for tunnel readiness (poll go-ios's own signal instead of a
            // blind sleep), capped so we still proceed if the endpoint never
            // answers on an odd setup.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if self.chainGeneration != gen { return }
                if self.tunnelReady() { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard self.chainGeneration == gen else { return }
            // Now that the tunnel is up, check/install the runner.
            let installResult = self.installRunnerIfMissing(bin: bin)
            guard self.chainGeneration == gen else { return }
            // A failed install with the runner still absent → don't launch runwda;
            // it would only fail-loop. The UI already showed the failure reason.
            guard shouldSpawnRunwda(after: installResult) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.chainGeneration == gen else { return }
                let wda = ManagedProcess(
                    binary: bin,
                    args: ["runwda",
                           "--bundleid=\(WDAIdentity.runnerBundleId)",
                           "--testrunnerbundleid=\(WDAIdentity.testRunnerBundleId)",
                           "--xctestconfig=\(WDAIdentity.xctestConfig)"],
                    label: "runwda", restartDelay: 6, workDir: self.workDir)
                wda.onGaveUp = { [weak self] _ in
                    DispatchQueue.main.async { self?.onWDAUnrecoverable?() }
                }
                self.wda = wda
                wda.start()
                self.forward = ManagedProcess(binary: bin, args: ["forward", "8101", "8100"],
                                              label: "forward", restartDelay: 3, workDir: self.workDir)
                self.forward?.start()
                self.mjpegForward = ManagedProcess(binary: bin, args: ["forward", "9110", "9100"],
                                                   label: "mjpeg-forward", restartDelay: 3, workDir: self.workDir)
                self.mjpegForward?.start()
            }
        }
    }

    /// Check for the branded runner and install the bundled ipa if it's missing.
    /// Runs on each bring-up (no once-per-launch guard) — the check is cheap and
    /// only shells `install` when the runner is actually absent. Emits progress
    /// via onRunnerInstall and returns the outcome so the caller can decide
    /// whether launching runwda is worthwhile.
    private func installRunnerIfMissing(bin: URL) -> RunnerInstall {
        emitInstall(.checking)
        guard let ipa = Bundle.main.url(forResource: "WebDriverAgent", withExtension: "ipa") else {
            // dev builds ship no bundled ipa; runner installed via build-wda.sh/Xcode
            emitInstall(.done(.noBundle))
            return .noBundle
        }
        if runnerIsInstalled(bin: bin) {
            emitInstall(.done(.alreadyPresent))
            return .alreadyPresent
        }
        emitInstall(.installing)
        // `install` routes through the RSD tunnel, which stays unusable for a few
        // seconds after it first appears in /tunnels — an attempt in that window
        // bails immediately (no zipconduit progress) rather than reaching the
        // device. Retry through that warmup, but stop early once we've reached a
        // real, classifiable failure (device-side ERROR) so we don't retry a
        // provisioning/lock error that will never succeed.
        // `install` routes through the RSD tunnel, which is briefly unusable right
        // after it comes up — an attempt in that window bails without a recognized
        // error (classifies as .other). Retry those (transient) but break
        // immediately on a definitive, actionable error (notProvisioned /
        // deviceLocked) or success — those won't change on retry. The window can
        // be a handful of seconds, so retry generously (the UI already says the
        // first install can take a while).
        let maxAttempts = 8
        var result: RunnerInstall = .failed(.other(raw: "install did not run"))
        for attempt in 0..<maxAttempts {
            let (status, stderr) = runInstallOnce(bin: bin, ipaPath: ipa.path)
            if status == 0 { result = .installed; break }
            let cls = classifyInstallError(stderr)
            result = .failed(cls)
            if case .other = cls {                          // unrecognized → likely transient
                if attempt < maxAttempts - 1 { Thread.sleep(forTimeInterval: 2.0); continue }
            } else {
                break                                       // definitive → stop now
            }
        }
        emitInstall(.done(result))
        return result
    }

    /// One `ios install` attempt. Returns the exit status and captured stderr
    /// (go-ios logs progress/errors there as JSON lines).
    private func runInstallOnce(bin: URL, ipaPath: String) -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["install", "--path=\(ipaPath)"]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do {
            try p.run()
            // Drain stderr before waiting so a full pipe buffer can't deadlock.
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }


    /// True if the branded runner id already appears in `ios apps --list`.
    private func runnerIsInstalled(bin: URL) -> Bool {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["apps", "--list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            return out.contains("com.local.imirror.WebDriverAgentRunner")
        } catch { return false }
    }

    func stop() {
        chainGeneration += 1
        relay.stop()
        forward?.stop()
        mjpegForward?.stop()
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
        forward?.stop(); mjpegForward?.stop(); wda?.stop(); tunnel?.stop()
        forward = nil; mjpegForward = nil; wda = nil; tunnel = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            // Our handles are stopped; reap any child that outlived its handle
            // (e.g. a tunnel reparented to launchd) so the fresh chain owns a
            // clean device + port 60105.
            self.sweepStrayProcesses()
            DispatchQueue.main.async { self.startChildren() }
        }
    }
}
