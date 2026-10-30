import Foundation

/// Main-thread owner of callbacks belonging to one automation or video lifetime.
/// Invalidate before replacing the owner so already queued completions cannot
/// update a new connection or restore controls after automation was disabled.
final class MainQueueCallbackScope {
    private var generation = 0

    func invalidate() { generation += 1 }

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
