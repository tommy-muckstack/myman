import Foundation

/// Share a costly download/compile/warmup between launch and the first take.
/// A failed attempt remains retryable. No caller cancels another's warmup.
final class ModelLoadCoordinator<Value: Sendable>: @unchecked Sendable {
    // Every access to these fields is protected by lock; work runs outside it.
    private let lock = NSLock()
    private var loaded: Value?
    private var loading: (id: UUID, task: Task<Value?, Never>)?

    var value: Value? { lock.withLock { loaded } }

    func load(_ operation: @escaping @Sendable () async -> Value?) async -> Value? {
        if let value { return value }
        let attempt = lock.withLock {
            if let loading { return loading }
            // A previous waiter may have installed the result since our read.
            let cached = loaded
            let next = (id: UUID(), task: Task<Value?, Never> {
                if let cached { return cached }
                return await operation()
            })
            loading = next
            return next
        }
        let result = await attempt.task.value
        lock.withLock {
            guard loading?.id == attempt.id else { return }
            loaded = result
            loading = nil
        }
        return result
    }
}
