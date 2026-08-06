import AppKit
import ScreenCaptureKit

/// One display, with the SCDisplay ↔ NSScreen pairing needed for capture.
struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let scDisplay: SCDisplay
    let nsScreen: NSScreen

    /// Bounds in virtual desktop coordinates (points, bottom-left origin).
    var frame: CGRect { nsScreen.frame }
    var scaleFactor: CGFloat { nsScreen.backingScaleFactor }
    var pixelWidth: Int { Int(CGFloat(scDisplay.width) * scaleFactor) }
    var pixelHeight: Int { Int(CGFloat(scDisplay.height) * scaleFactor) }
}

@MainActor
enum DisplayLayout {
    /// Pair each SCDisplay with its NSScreen by CGDirectDisplayID. Displays
    /// with no NSScreen match (mirroring/hotplug transitions) are skipped.
    static func allDisplays(from content: SCShareableContent) -> [DisplayInfo] {
        var screensByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screensByID[id] = screen
            }
        }
        return content.displays.compactMap { scDisplay in
            screensByID[scDisplay.displayID].map {
                DisplayInfo(id: scDisplay.displayID, scDisplay: scDisplay, nsScreen: $0)
            }
        }
        .sorted { $0.frame.origin.x < $1.frame.origin.x }
    }

    static func combinedFrame(of displays: [DisplayInfo]) -> CGRect {
        guard let first = displays.first else { return .zero }
        return displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
