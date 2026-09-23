import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class SettingsDismissTests: XCTestCase {
    @MainActor func testCloseButtonRespondsAcrossItsPaddedTarget() async throws {
        guard ProcessInfo.processInfo.environment["MYMAN_VERIFY_SETTINGS_CLICK"] == "enabled" else {
            throw XCTSkip("Opt-in native mouse verification")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        // Exercise the real Settings view with clicks inside the advertised 32pt
        // target, including outside the 16pt icon's painted bounds.
        for offset in [NSPoint.zero, NSPoint(x: 11, y: 0), NSPoint(x: 0, y: -11)] {
            var dismissals = 0
            var panel: FloatingPanel!
            panel = FloatingPanel(content: SettingsPanelView(onDismiss: {
                dismissals += 1
                panel.dismiss()
            }))
            panel.isReleasedWhenClosed = false
            panel.dismissesOnResign = false
            defer { panel.contentView = nil; panel.close() }
            panel.present()
            try await Task.sleep(for: .milliseconds(200))
            let host = try XCTUnwrap(panel.contentView)
            let point = NSPoint(x: host.bounds.maxX - MM.Layout.paddingLarge - 16 + offset.x,
                                y: host.isFlipped ? MM.Layout.padding + 16 - offset.y
                                    : host.bounds.maxY - MM.Layout.padding - 16 + offset.y)
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                panel.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(dismissals, 1, "Close target offset \(offset)")
            XCTAssertFalse(panel.isVisible, "Close must dismiss Settings at offset \(offset)")
        }
    }
}
