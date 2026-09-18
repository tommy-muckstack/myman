import Foundation
import Darwin

/// Only processes launched by this app instance belong to its quit path.
/// Never kill another app's server just because it uses the same port/name.
final class AppChildProcesses: @unchecked Sendable {
    static let shared = AppChildProcesses()
    private let lock = NSLock()
    private var processes: [Process] = []
    private var shuttingDown = false
    private struct Child {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }
    private var descendants: [Child] = []

    func run(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { throw CancellationError() }
        try process.run()
        processes.removeAll { !$0.isRunning }
        processes.append(process)
    }

    func prepareForQuit() {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { return }
        shuttingDown = true
        descendants = processes.filter(\.isRunning).flatMap { children(of: $0.processIdentifier) }
        for child in descendants { signal(child, SIGTERM) }
        for process in processes where process.isRunning { process.terminate() }
    }

    func finishQuitting() async {
        prepareForQuit()
        try? await Task.sleep(for: .milliseconds(500))
        forceStop()
    }

    func forceStop() {
        lock.lock(); defer { lock.unlock() }
        shuttingDown = true
        for process in processes where process.isRunning {
            for child in children(of: process.processIdentifier) { signal(child, SIGKILL) }
            kill(process.processIdentifier, SIGKILL)
        }
        for child in descendants { signal(child, SIGKILL) }
        descendants.removeAll()
        processes.removeAll()
    }

    private func children(of pid: pid_t, depth: Int = 0) -> [Child] {
        guard depth < 8 else { return [] }
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(min(pids.count, Int(count))).filter { $0 > 0 }.flatMap { childPID in
            guard let info = identity(childPID) else { return [Child]() }
            return children(of: childPID, depth: depth + 1) + [info]
        }
    }

    private func identity(_ pid: pid_t) -> Child? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Child(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private func signal(_ child: Child, _ signal: Int32) {
        // A PID may have been recycled during the grace period.
        guard let current = identity(child.pid), current.seconds == child.seconds,
              current.microseconds == child.microseconds else { return }
        kill(child.pid, signal)
    }
}
