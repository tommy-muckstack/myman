import Foundation

/// A stalled system-model request must not hold the UI/job queue forever.
/// Unlike a task group, this does not wait for an uncooperative cancelled task.
enum AsyncDeadline {
    struct TimedOut: Error {}

    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }

        func track(_ task: Task<Void, Never>) {
            lock.lock()
            if result != nil { lock.unlock(); task.cancel() }
            else { tasks.append(task); lock.unlock() }
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation, tasks = self.tasks
            self.continuation = nil; self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(with: result)
        }
    }

    static func run<Value: Sendable>(seconds: Double,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.track(Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                })
                race.track(Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        race.finish(.failure(TimedOut()))
                    } catch { /* The operation or caller already finished. */ }
                })
            }
        } onCancel: { race.finish(.failure(CancellationError())) }
    }
}
