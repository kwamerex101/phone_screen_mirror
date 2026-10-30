import Foundation

/// Keeps simulator readiness honest after startup, including runner restarts.
/// All work and callbacks run on the supplied serial queue.
final class SimulatorHealthMonitor {
    private let queue: DispatchQueue
    private let check: () -> Bool
    private let interval: TimeInterval
    private let startupTimeout: TimeInterval
    private let recoveryTimeout: TimeInterval
    private let onState: (SimState) -> Void
    private let now: () -> TimeInterval
    private var generation = UUID()
    private var lastState: SimState?
    private var deadline: TimeInterval?
    private var hasBeenReady = false

    init(queue: DispatchQueue, interval: TimeInterval = 2,
         startupTimeout: TimeInterval = 300, recoveryTimeout: TimeInterval = 30,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         check: @escaping () -> Bool, onState: @escaping (SimState) -> Void) {
        self.queue = queue
        self.interval = interval
        self.startupTimeout = startupTimeout
        self.recoveryTimeout = recoveryTimeout
        self.check = check
        self.onState = onState
        self.now = now
    }

    func start() {
        generation = UUID()
        lastState = nil
        hasBeenReady = false
        deadline = now() + startupTimeout
        tick(generation)
    }

    func stop() { generation = UUID() }

    private func tick(_ token: UUID) {
        guard generation == token else { return }
        let ready = check()
        if ready {
            hasBeenReady = true
            deadline = nil
            emit(.ready)
        } else {
            if deadline == nil { deadline = now() + recoveryTimeout }
            if let deadline, now() >= deadline {
                emit(.failed(hasBeenReady
                    ? "Simulator connection lost. Enable it to reconnect."
                    : "WebDriverAgent did not become ready. Check the simulator and try again."))
                stop()
                return
            }
            emit(.starting)
        }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.tick(token) }
    }

    private func emit(_ state: SimState) {
        guard lastState != state else { return }
        lastState = state
        onState(state)
    }
}
