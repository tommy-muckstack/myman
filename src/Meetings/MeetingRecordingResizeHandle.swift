import AppKit
import SwiftUI

/// The window owns its frame during a drag, just as it does during collapse.
/// Using screen coordinates keeps the drag steady as the bottom edge moves.
struct MeetingRecordingResizeHandle: NSViewRepresentable {
    let controller: MeetingController

    func makeNSView(context: Context) -> RecordingResizeGrip {
        let grip = RecordingResizeGrip()
        grip.toolTip = "Drag to resize recording details"
        grip.setAccessibilityElement(true)
        grip.setAccessibilityRole(.splitter)
        grip.setAccessibilityLabel("Recording details height")
        updateNSView(grip, context: context)
        return grip
    }

    func updateNSView(_ grip: RecordingResizeGrip, context: Context) {
        grip.onBegin = { controller.beginResizingPill() }
        grip.onEnd = { controller.finishResizingPill(height: $0) }
        grip.onAdjust = { controller.adjustPillHeight(by: $0) }
        grip.needsDisplay = true
    }
}

final class RecordingResizeGrip: NSView {
    var onBegin: () -> Void = {}
    var onEnd: (CGFloat) -> Void = { _ in }
    var onAdjust: (CGFloat) -> Void = { _ in }
    private var dragOrigin: (point: NSPoint, frame: NSRect)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1.5,
                                        width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }

    static func resizedFrame(_ original: NSRect, verticalDelta: CGFloat, visibleFrame: NSRect) -> NSRect {
        let maximum = max(444, original.maxY - visibleFrame.minY - 24)
        let height = min(maximum, max(444, original.height + verticalDelta))
        return NSRect(x: original.minX, y: original.maxY - height,
                      width: original.width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragOrigin = (window.convertPoint(toScreen: event.locationInWindow), window.frame)
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin, let screen = window.screen ?? NSScreen.main else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let frame = Self.resizedFrame(dragOrigin.frame,
                                      verticalDelta: dragOrigin.point.y - point.y,
                                      visibleFrame: screen.visibleFrame)
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        if let window { onEnd(window.frame.height) }
    }

    override func accessibilityPerformIncrement() -> Bool { onAdjust(40); return true }
    override func accessibilityPerformDecrement() -> Bool { onAdjust(-40); return true }
}
