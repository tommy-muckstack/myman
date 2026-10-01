import AppKit
import Foundation

/// AppleScript compilation can prompt for a missing application before any
/// `is running` guard executes (MYMAN-X). Only target running players, and run
/// OSA in a disposable child process with a deadline, never on the main thread.
final class MeetingMusicPlayback: @unchecked Sendable {
    enum Player: String, CaseIterable, Sendable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
    }

    enum Command: Sendable { case pause, resume }
    typealias Execute = @Sendable (Player, Command) -> Bool
    private let queue: DispatchQueue
    private let execute: Execute
    // Owned exclusively by queue. FIFO ordering also handles Stop while a
    // pause is still in flight, and a new meeting immediately after Stop.
    private var pausedPlayers: Set<Player> = []

    init(queue: DispatchQueue = DispatchQueue(label: "com.muckstack.myman.meeting-music"),
         execute: @escaping Execute = { player, command in MeetingMusicPlayback.execute(player, command) }) {
        self.queue = queue
        self.execute = execute
    }

    func pause() {
        queue.async { [self] in
            for player in Player.allCases where !pausedPlayers.contains(player) {
                if execute(player, .pause) { pausedPlayers.insert(player) }
            }
        }
    }

    func resume() {
        queue.async { [self] in
            for player in Player.allCases where pausedPlayers.contains(player) {
                _ = execute(player, .resume)
            }
            pausedPlayers.removeAll()
        }
    }

    private static func execute(_ player: Player, _ command: Command) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script(for: player, command: command)]
        return run(process, timeout: 2) == "changed"
    }

    static func script(for player: Player, command: Command) -> String {
        let action = command == .pause
            ? "if player state is playing then\npause\nreturn \"changed\"\nend if"
            : "if player state is paused then\nplay\nreturn \"changed\"\nend if"
        return """
        with timeout of 1 second
            if application id "\(player.rawValue)" is running then
                tell application id "\(player.rawValue)"
                    \(action)
                end tell
            end if
        end timeout
        """
    }

    /// Only for the small, fixed reply from our scripts. Called on queue.
    /// The outer deadline covers compilation, application lookup, and consent
    /// prompts too; AppleScript's timeout only bounds event delivery.
    static func run(_ process: Process, timeout: TimeInterval) -> String? {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try AppChildProcesses.shared.run(process) }
        catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.25)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
