import XCTest
import AppKit
import SwiftUI
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
    func testMeetingLinksPreserveJoinDetailsAndRejectLookalikeHosts() {
        XCTAssertEqual(CalendarWatcher.meetingURL(in: "Join https://acme.zoom.us/j/123456?pwd=secret.")?.absoluteString,
                       "https://acme.zoom.us/j/123456?pwd=secret")
        XCTAssertEqual(CalendarWatcher.meetingURL(in: "Meet: <https://meet.google.com/abc-defg-hij>")?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(CalendarWatcher.meetingURL(in: "https://example.com/meet.google.com then https://meet.google.com/abc-defg-hij")?.host,
                       "meet.google.com")
        XCTAssertNil(CalendarWatcher.meetingURL(in: "https://zoom.us.example.com/j/123"))
        XCTAssertNil(CalendarWatcher.meetingURL(in: "https://example.com/?next=zoom.us"))
        XCTAssertNil(CalendarWatcher.meetingURL(in: "Conference room 2"))
    }

    @MainActor func testRenderCalendarActionsInBothThemes() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            CalendarPanelView.EventLite(id: "zoom", start: start, end: start.addingTimeInterval(1800), title: "Design review with the product team", notes: "", attendeeNames: [], joinURL: URL(string: "https://acme.zoom.us/j/123"), meetingID: "notes"),
            CalendarPanelView.EventLite(id: "meet", start: start, end: start.addingTimeInterval(1800), title: "Weekly planning", notes: "", attendeeNames: [], joinURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            CalendarPanelView.EventLite(id: "local", start: start, end: start.addingTimeInterval(1800), title: "Coffee break", notes: "", attendeeNames: [])
        ]
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let content = VStack(spacing: 6) {
                ForEach(events) { event in
                    CalendarEventCard(event: event, onOpen: {}, onJoin: {}, onBrief: {}, onNotes: {}, hovered: true)
                }
            }
            .padding(MM.Layout.padding)
            .background(MM.Colors.background)
            .preferredColorScheme(scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 330)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("calendar-actions-\(scheme == .dark ? "dark" : "light").png"))
            window.contentView = nil
            window.close()
        }
    }

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
