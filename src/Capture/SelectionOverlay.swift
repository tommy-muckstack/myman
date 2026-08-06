import AppKit

@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    func selectionOverlayDidComplete(with rect: CGRect)
    func selectionOverlayDidCancel()
}

/// The freeze-then-select overlay: one panel per screen drawing its slice of a
/// frozen composite, dimmed, with crosshair + drag selection. Selection rects
/// are in virtual-desktop points (bottom-left origin).
@MainActor
final class SelectionOverlayCoordinator {
    private var childWindows: [SelectionOverlayWindow] = []
    weak var delegate: SelectionOverlayDelegate?

    private var selectionStart: CGPoint?

    /// Guards hideAll() so the crosshair-cursor pop can never run twice — an
    /// unbalanced NSCursor.pop() corrupts the cursor stack.
    private(set) var isShowing = false

    init(frozenCapture: CompositeCapture?) {
        for screen in NSScreen.screens {
            childWindows.append(
                SelectionOverlayWindow(screen: screen, coordinator: self, frozenCapture: frozenCapture)
            )
        }
    }

    func showAll() {
        selectionStart = nil
        for window in childWindows {
            window.clearSelection()
            window.orderFrontRegardless()
            window.makeKey()
        }
        isShowing = true
        NSCursor.crosshair.push()
    }

    func hideAll() {
        guard isShowing else { return }
        isShowing = false
        for window in childWindows {
            window.orderOut(nil)
        }
        NSCursor.pop()
    }

    func handleSelectionStart(at point: CGPoint) {
        selectionStart = point
        updateAll(current: point)
    }

    func handleSelectionDrag(to point: CGPoint) {
        updateAll(current: point)
    }

    func handleSelectionEnd(at point: CGPoint) {
        guard let start = selectionStart else {
            delegate?.selectionOverlayDidCancel()
            return
        }
        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        selectionStart = nil
        if rect.width > 10 && rect.height > 10 {
            delegate?.selectionOverlayDidComplete(with: rect)
        } else {
            delegate?.selectionOverlayDidCancel()
        }
    }

    func handleCancel() {
        selectionStart = nil
        delegate?.selectionOverlayDidCancel()
    }

    private func updateAll(current: CGPoint) {
        guard let start = selectionStart else { return }
        for window in childWindows {
            window.updateSelection(start: start, current: current)
        }
    }
}

@MainActor
final class SelectionOverlayWindow: NSPanel {
    private weak var coordinator: SelectionOverlayCoordinator?
    private var overlayView: SelectionOverlayView!

    init(screen: NSScreen, coordinator: SelectionOverlayCoordinator, frozenCapture: CompositeCapture?) {
        self.coordinator = coordinator
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // NSPanel with these flags receives mouse events immediately without
        // consuming the first click for app activation.
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        alphaValue = 0.999
        acceptsMouseMovedEvents = true
        animationBehavior = .none

        overlayView = SelectionOverlayView(
            screenFrame: screen.frame, coordinator: coordinator, frozenCapture: frozenCapture
        )
        contentView = overlayView
    }

    func updateSelection(start: CGPoint, current: CGPoint) {
        overlayView.updateSelection(start: start, current: current)
    }

    func clearSelection() {
        overlayView.clearSelection()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            coordinator?.handleCancel()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class SelectionOverlayView: NSView {
    private weak var coordinator: SelectionOverlayCoordinator?
    private let screenFrame: CGRect
    private var selectionStart: CGPoint?
    private var selectionCurrent: CGPoint?
    private var mousePosition: CGPoint?
    private let croppedScreenshot: NSImage?

    init(screenFrame: CGRect, coordinator: SelectionOverlayCoordinator, frozenCapture: CompositeCapture?) {
        self.screenFrame = screenFrame
        self.coordinator = coordinator
        // Crop this screen's slice using the composite's OWN geometry —
        // recomputing from NSScreen.screens could disagree with the captured
        // display set during clamshell/hotplug transitions.
        self.croppedScreenshot = frozenCapture?.crop(to: screenFrame)
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NSCursor.crosshair.set()
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate],
            owner: self, userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    private func toDesktopCoords(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + screenFrame.origin.x, y: p.y + screenFrame.origin.y)
    }

    private func toViewCoords(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.origin.x, y: p.y - screenFrame.origin.y)
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        mousePosition = viewPoint
        coordinator?.handleSelectionStart(at: toDesktopCoords(viewPoint))
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        mousePosition = viewPoint
        coordinator?.handleSelectionDrag(to: toDesktopCoords(viewPoint))
    }

    override func mouseMoved(with event: NSEvent) {
        mousePosition = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        coordinator?.handleSelectionEnd(at: toDesktopCoords(viewPoint))
    }

    func updateSelection(start: CGPoint, current: CGPoint) {
        selectionStart = toViewCoords(start)
        selectionCurrent = toViewCoords(current)
        needsDisplay = true
    }

    func clearSelection() {
        selectionStart = nil
        selectionCurrent = nil
        mousePosition = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let frozen = croppedScreenshot {
            frozen.draw(in: bounds, from: NSRect(origin: .zero, size: frozen.size),
                        operation: .copy, fraction: 1.0)
        }

        if let start = selectionStart, let current = selectionCurrent {
            let selection = CGRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y)
            ).intersection(bounds)

            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            context.fill(bounds)
            if !selection.isEmpty {
                // Cut out the selection to show the frozen screenshot beneath.
                context.setBlendMode(.clear)
                context.fill(selection)
            }
            context.restoreGState()

            guard !selection.isEmpty else { return }

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(selection.insetBy(dx: -1, dy: -1))

            drawDimensionLabel(for: selection, context: context)
        } else {
            context.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
            context.fill(bounds)

            if let mouse = mousePosition {
                context.saveGState()
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: bounds.minX, y: mouse.y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: mouse.y))
                context.strokePath()
                context.move(to: CGPoint(x: mouse.x, y: bounds.minY))
                context.addLine(to: CGPoint(x: mouse.x, y: bounds.maxY))
                context.strokePath()
                context.restoreGState()
            }
        }
    }

    private func drawDimensionLabel(for selection: CGRect, context: CGContext) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let labelSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        var labelY = selection.minY - labelSize.height - 6
        if labelY < bounds.minY + 4 { labelY = selection.maxY + 6 }
        let labelRect = CGRect(
            x: selection.midX - labelSize.width / 2, y: labelY,
            width: labelSize.width, height: labelSize.height
        )

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: CGPoint(x: labelRect.minX + padding, y: labelRect.minY + padding / 2),
            withAttributes: attributes
        )
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
