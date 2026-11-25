import AppKit
import AVFoundation

/// The round camera preview shown while a narration take records. It floats above other windows, can be
/// dragged anywhere, and stays up when focus moves to the page being narrated. It only shows; it does not record.
@MainActor
enum NarrationBubble {
    private static var panel: NSPanel?
    static let diameter: CGFloat = 180

    static func show(session: AVCaptureSession) {
        close()
        let frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.cornerRadius = diameter / 2
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 3
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = frame
        content.layer?.addSublayer(preview)
        window.contentView = content

        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - diameter - 24, y: screen.minY + 24))
        }
        window.orderFrontRegardless()
        panel = window
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
