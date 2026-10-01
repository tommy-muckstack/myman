import XCTest
@testable import MyMan

final class MeetingMusicPlaybackTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testResumesOnlyThePlayerSuccessfullyPaused() async {
        let calls = Calls()
        let queue = DispatchQueue(label: "music-test")
        let playback = MeetingMusicPlayback(queue: queue) { player, command in
            XCTAssertFalse(Thread.isMainThread)
            calls.append("\(player.rawValue):\(command)")
            return player == .spotify
        }
        playback.pause()
        playback.resume()
        playback.resume() // A repeated Stop must not start music again.
        await drain(queue)
        XCTAssertEqual(calls.all, ["com.apple.Music:pause", "com.spotify.client:pause", "com.spotify.client:resume"])
    }

    @MainActor
    func testStopDuringSlowPauseReturnsImmediatelyAndThenRestoresPlayback() async {
        let entered = expectation(description: "background pause entered")
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let queue = DispatchQueue(label: "slow-music-test")
        let playback = MeetingMusicPlayback(queue: queue) { player, command in
            XCTAssertFalse(Thread.isMainThread)
            calls.append("\(player.rawValue):\(command)")
            if player == .music, command == .pause {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return player == .music
        }
        playback.pause()
        await fulfillment(of: [entered], timeout: 1)
        // Both calls execute on the main actor while the worker is blocked.
        playback.resume()
        release.signal()
        await drain(queue)
        XCTAssertEqual(calls.all, ["com.apple.Music:pause", "com.spotify.client:pause", "com.apple.Music:resume"])
    }

    func testFailedOrUnavailablePlayersAreNeverResumed() async {
        let calls = Calls()
        let queue = DispatchQueue(label: "unavailable-music-test")
        let playback = MeetingMusicPlayback(queue: queue) { player, command in
            calls.append("\(player.rawValue):\(command)")
            return false
        }
        playback.pause()
        playback.resume()
        await drain(queue)
        XCTAssertEqual(calls.all, ["com.apple.Music:pause", "com.spotify.client:pause"])
    }

    func testSuccessfulChildReplyAndFailureExit() async {
        let success = await Task.detached {
            MeetingMusicPlayback.run(Self.child("printf changed"), timeout: 1)
        }.value
        XCTAssertEqual(success, "changed")
        let failure = await Task.detached {
            MeetingMusicPlayback.run(Self.child("printf changed; exit 1"), timeout: 1)
        }.value
        XCTAssertNil(failure)
    }

    func testHungChildIsTerminatedWithinDeadline() async {
        let process = Self.child("exec /bin/sleep 30")
        let start = Date()
        let result = await Task.detached {
            MeetingMusicPlayback.run(process, timeout: 0.1)
        }.value
        XCTAssertNil(result)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testChildIgnoringTerminationIsKilledWithinDeadline() async {
        let process = Self.child("trap '' TERM; exec /bin/sleep 30")
        let start = Date()
        let result = await Task.detached {
            MeetingMusicPlayback.run(process, timeout: 0.2)
        }.value
        XCTAssertNil(result)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRapidNewMeetingPreservesPauseResumeOrder() async {
        let calls = Calls()
        let queue = DispatchQueue(label: "rapid-music-test")
        let playback = MeetingMusicPlayback(queue: queue) { player, command in
            guard player == .spotify else { return false }
            calls.append("\(command)")
            return true
        }
        playback.pause()
        playback.resume()
        playback.pause()
        playback.resume()
        await drain(queue)
        XCTAssertEqual(calls.all, ["pause", "resume", "pause", "resume"])
    }

    private static func child(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return process
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
