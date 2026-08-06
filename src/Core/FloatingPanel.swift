import AppKit
import SwiftUI

// The one panel recipe that powers every My Man surface. Non-activating, so it
// appears over whatever app you're in without switching focus away from it —
// yet it can still become key, so you can type into it. Esc or clicking away
// dismisses it.
final class FloatingPanel: NSPanel {

    var onDismiss: (() -> Void)?

    /// Transient surfaces (launcher, pills) die on focus loss; composers
    /// (tasks, note capture) hold half-typed work while the user goes to
    /// copy something — those close only on a deliberate ✕/Esc.
    var dismissesOnResign = true

    /// Panels that should never take key focus (side panels, pills) — their
    /// clicks work without stealing focus from the main surface.
    private let becomesKey: Bool
    /// Fixed-size panels: the WINDOW owns its frame; content fills it.
    /// (Autolayout hosting lets content self-measurement override setFrame —
    /// the collapsed-pill / "S"-button / flicker family.)
    private let fixedSize: Bool

    init<Content: View>(content: Content, becomesKey: Bool = true, fixedSize: Bool = false) {
        self.becomesKey = becomesKey
        self.fixedSize = fixedSize
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: content)
        // THE panel rule (MYMAN-1's family): panels whose content CHANGES
        // size while visible (pills, toast, launcher) must own their window
        // frame — autolayout hosting resizes windows reentrantly during
        // layout flushes and AppKit converts that into a crash. Those pass
        // fixedSize: true and size themselves explicitly. Panels with STATIC
        // content (side panels, welcome, composers) keep autolayout hosting:
        // measurement works, and unchanging content can never trigger the
        // reentrant resize.
        if fixedSize {
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
        } else {
            hosting.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView = hosting
    }

    // Borderless panels refuse key status by default; we need it for text input.
    override var canBecomeKey: Bool { becomesKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        if dismissesOnResign { dismiss() }
    }

    func dismiss() {
        guard isVisible else { return }
        onDismiss?()
        orderOut(nil)
    }

    /// Show centered on the screen with the mouse, upper third — where the eye rests.
    /// The safe way to ask what the content wants: measured on demand,
    /// never wired into window-resizing constraints.
    var contentIdeal: NSSize {
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? .zero
        return (size.width > 1 && size.height > 1) ? size : frame.size
    }

    func present() {
        layoutIfNeeded()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let size = contentIdeal
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62 - size.height / 2
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
    }
}
