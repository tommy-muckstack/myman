import XCTest
@testable import MyMan

private final class CalendarReadProbe: @unchecked Sendable {
    let firstReadStarted = XCTestExpectation(description: "Calendar read started")
    let releaseFirstRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func load() -> [CalendarMeetingSnapshot] {
        XCTAssertFalse(Thread.isMainThread, "A slow calendar query must never block the UI")
        lock.lock()
        reads += 1
        let read = reads
        lock.unlock()
        if read == 1 {
            firstReadStarted.fulfill()
            XCTAssertEqual(releaseFirstRead.wait(timeout: .now() + 5), .success)
        }
        let now = Date()
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        var events = [
            CalendarMeetingSnapshot(id: "current", title: "Current meeting", joinURL: url,
                                    startsAt: now),
            CalendarMeetingSnapshot(id: "expired", title: "Expired meeting", joinURL: url,
                                    startsAt: now.addingTimeInterval(-121))
        ]
        if read > 1 {
            events.append(CalendarMeetingSnapshot(id: "follow-up", title: "Follow-up meeting",
                                                  joinURL: url, startsAt: now))
        }
        return events
    }
}

final class CalendarWatcherTests: XCTestCase {
    @MainActor func testSlowCalendarReadKeepsUIResponsiveAndCoalescesRefreshBurst() async {
        let probe = CalendarReadProbe()
        let watcher = CalendarWatcher(loadEvents: { probe.load() })
        let nudged = expectation(description: "Current and follow-up meetings delivered")
        nudged.expectedFulfillmentCount = 2
        var titles: [String?] = []
        watcher.onPreMeeting = { title, url, _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(url?.host, "meet.google.com")
            titles.append(title)
            nudged.fulfill()
        }

        watcher.refresh()
        await fulfillment(of: [probe.firstReadStarted], timeout: 2)
        // These calls and the main-queue heartbeat must run while the reader
        // is blocked, without launching more queries or scheduling a nudge.
        for _ in 0..<30 { watcher.refresh() }
        let responsive = expectation(description: "Main queue remains responsive")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        XCTAssertEqual(probe.readCount, 1)
        XCTAssertTrue(titles.isEmpty)

        probe.releaseFirstRead.signal()
        await fulfillment(of: [nudged], timeout: 2)
        XCTAssertEqual(probe.readCount, 2)
        XCTAssertEqual(titles, ["Current meeting", "Follow-up meeting"])
    }
}
