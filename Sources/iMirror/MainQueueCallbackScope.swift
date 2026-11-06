import Foundation

/// Main-thread owner of callbacks belonging to one automation or video lifetime.
/// Invalidate before replacing the owner so already queued completions cannot
/// update a new connection or restore controls after automation was disabled.
final class MainQueueCallbackScope {
    private var generation = 0

    func invalidate() { generation += 1 }

    func deliveringLatest<Value>(_ callback: @escaping (Value) -> Void) -> (Value) -> Void {
        let expected = generation
        let delivery = LatestMainQueueValue<Value> { [weak self] value in
            guard let self, self.generation == expected else { return }
            callback(value)
        }
        return { delivery.submit($0) }
    }

    func delivering<Value>(_ callback: @escaping (Value) -> Void) -> (Value) -> Void {
        let expected = generation
        return { [weak self] value in
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                callback(value)
            }
        }
    }
}

/// Retain at most one pending video update while the UI thread is busy.
private final class LatestMainQueueValue<Value> {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let callback: (Value) -> Void

    init(callback: @escaping (Value) -> Void) { self.callback = callback }

    func submit(_ value: Value) {
        lock.lock()
        latest = value
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let value = latest
            latest = nil
            scheduled = false
            lock.unlock()
            if let value { callback(value) }
        }
    }
}
