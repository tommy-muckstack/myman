import Foundation

/// Quit must finish capture, but must never wait indefinitely for a device
/// driver or an on-device model. The deadline is independent of the cleanup
/// task: a task group would keep waiting for an uncooperative child.
@MainActor
final class AppTerminationCoordinator {
    private(set) var isTerminating = false
    private var replied = false
    private var cleanup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func begin(timeout: Duration = .seconds(8),
               prepare: () -> Void,
               finish: @escaping @MainActor () async -> Void,
               reply: @escaping @MainActor () -> Void) {
        guard !isTerminating else { return }
        isTerminating = true
        prepare()
        cleanup = Task { @MainActor in
            await finish()
            complete(reply)
        }
        deadline = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            NSLog("My Man: quit cleanup reached its deadline; saved audio remains recoverable")
            complete(reply)
        }
    }

    private func complete(_ reply: () -> Void) {
        guard !replied else { return }
        replied = true
        deadline?.cancel(); deadline = nil
        cleanup?.cancel(); cleanup = nil
        reply()
    }
}
