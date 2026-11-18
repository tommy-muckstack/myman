import Foundation
import Darwin

/// Only optional indexing uses this policy. Capture, dictation and user searches
/// must never wait for the machine to become idle.
enum BackgroundMaintenance {
    static var shouldDefer: Bool {
        let info = ProcessInfo.processInfo
        var load = 0.0
        _ = getloadavg(&load, 1)
        return shouldDefer(load: load, cores: info.activeProcessorCount,
                           thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
    }

    static func shouldDefer(load: Double, cores: Int, thermal: ProcessInfo.ThermalState, lowPower: Bool) -> Bool {
        lowPower || thermal == .serious || thermal == .critical || load > Double(max(1, cores)) * 1.5
    }
}

/// Coalesces requests even while work is running. At most one follow-up pass
/// survives a burst of database/file changes; delayed work does not busy-poll.
final class CoalescingMaintenance: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let retryDelay: TimeInterval
    private let shouldDefer: () -> Bool
    private let work: (String) -> Void
    private var scheduled = false
    private var requested: String?

    init(label: String, delay: TimeInterval = 0.35, retryDelay: TimeInterval = 30,
         shouldDefer: @escaping () -> Bool = { BackgroundMaintenance.shouldDefer },
         work: @escaping (String) -> Void) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.delay = delay
        self.retryDelay = retryDelay
        self.shouldDefer = shouldDefer
        self.work = work
    }

    func request(reason: String = "change") {
        lock.lock()
        requested = reason
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { enqueue(after: delay) }
    }

    private func enqueue(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.run() }
    }

    private func run() {
        if shouldDefer() { enqueue(after: retryDelay); return }
        lock.lock()
        let reason = requested
        requested = nil
        lock.unlock()
        if let reason { work(reason) }
        lock.lock()
        let again = requested != nil
        if !again { scheduled = false }
        lock.unlock()
        if again { enqueue(after: delay) }
    }
}
