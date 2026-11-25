import XCTest
@testable import MyMan

final class HotkeyDefaultsTests: XCTestCase {
    /// Two actions with the same default combo means one of them never registers.
    func testEveryDefaultHotkeyIsUnique() {
        var seen: [String: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            let combo = action.defaultCombo
            let key = "\(combo.keyCode)-\(combo.carbonModifiers)"
            if let other = seen[key] {
                XCTFail("\(action) and \(other) share the default hotkey \(key)")
            }
            seen[key] = action
        }
    }

    func testMarkZoomPointHasADefault() {
        XCTAssertEqual(HotkeyAction.markZoomPoint.label, "Mark Zoom Point While Recording")
    }
}
