import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class AppUpdateCoordinatorTests: XCTestCase {
    @MainActor func testRenderUpdatePrompt() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] else { throw XCTSkip("Opt-in native visual review") }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let host = NSHostingView(rootView: UpdateReadyView(version: "2.0", install: {}, later: {}).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 112), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 380, height: 112)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("update-prompt.png"))
    }

    @MainActor func testReadyUpdateWaitsForIdleAndRechecksAtClick() {
        var busy = true, shown = 0, hidden = 0, installed = 0
        var click: (() -> Void)?
        let coordinator = AppUpdateCoordinator(isBusy: { busy }, present: { version, install, _ in
            XCTAssertEqual(version, "2.0")
            shown += 1; click = install
        }, dismiss: { hidden += 1 })
        coordinator.updateReady(version: "2.0", install: { installed += 1 })
        XCTAssertEqual(shown, 0)
        busy = false; coordinator.refresh(); coordinator.refresh()
        XCTAssertEqual(shown, 1)
        busy = true; click?()
        XCTAssertEqual(installed, 0)
        XCTAssertEqual(hidden, 1)
        busy = false; coordinator.refresh(); click?(); click?()
        XCTAssertEqual(shown, 2)
        XCTAssertEqual(installed, 1)
    }

    @MainActor func testBusyHidesPromptAndLaterSnoozesForAnHour() {
        var busy = false, shown = 0, hidden = 0
        let coordinator = AppUpdateCoordinator(isBusy: { busy }, present: { _, _, _ in shown += 1 }, dismiss: { hidden += 1 })
        coordinator.updateReady(version: "2.0", install: {})
        busy = true; coordinator.refresh()
        XCTAssertEqual(hidden, 1)
        busy = false; coordinator.refresh()
        XCTAssertEqual(shown, 2)
        let now = Date()
        coordinator.remindLater(now: now)
        coordinator.refresh(now: now.addingTimeInterval(3599))
        XCTAssertEqual(shown, 2)
        coordinator.refresh(now: now.addingTimeInterval(3600))
        XCTAssertEqual(shown, 3)
    }

    @MainActor func testRelaunchWaitsForWorkThatStartedDuringInstallation() {
        var busy = false, resumed = 0
        let coordinator = AppUpdateCoordinator(isBusy: { busy }, present: { _, _, _ in }, dismiss: {})
        coordinator.updateReady(version: "2.0", install: {})
        coordinator.requestInstall()
        busy = true
        XCTAssertTrue(coordinator.postponeRelaunch(until: { resumed += 1 }))
        coordinator.refresh()
        XCTAssertEqual(resumed, 0)
        busy = false; coordinator.refresh(); coordinator.refresh()
        XCTAssertEqual(resumed, 1)
    }

    @MainActor func testFinalTerminationRaceCancelsAndAllowsRetryWhenIdle() {
        var busy = false, installed = 0, shown = 0
        let coordinator = AppUpdateCoordinator(isBusy: { busy }, present: { _, _, _ in shown += 1 }, dismiss: {})
        coordinator.updateReady(version: "2.0", install: { installed += 1 })
        coordinator.requestInstall()
        XCTAssertFalse(coordinator.postponeRelaunch(until: { XCTFail("Idle relaunch should not be deferred") }))
        busy = true
        XCTAssertTrue(coordinator.shouldCancelTermination())
        XCTAssertFalse(coordinator.isRestarting)
        busy = false; coordinator.refresh(); coordinator.requestInstall()
        XCTAssertEqual(shown, 2)
        XCTAssertEqual(installed, 2)
        XCTAssertFalse(coordinator.shouldCancelTermination())
    }

    @MainActor func testAbortedUpdateInvalidatesPromptAndDeferredRelaunch() {
        var busy = false, click: (() -> Void)?
        let coordinator = AppUpdateCoordinator(isBusy: { busy }, present: { _, install, _ in click = install }, dismiss: {})
        coordinator.updateReady(version: "2.0", install: { XCTFail("Aborted installer must not run") })
        busy = true
        XCTAssertTrue(coordinator.postponeRelaunch(until: { XCTFail("Aborted relaunch must not resume") }))
        coordinator.clear()
        busy = false; click?(); coordinator.refresh()
        XCTAssertFalse(coordinator.isRestarting)
        XCTAssertFalse(coordinator.shouldCancelTermination())
    }
}
