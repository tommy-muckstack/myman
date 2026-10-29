import AppKit
import SwiftUI

// Cursor presence for screen recordings: a subtle fading trail while the
// mouse moves, a ripple ring on every click, and a highlight wherever the
// mouse is shaken back and forth. Drawing (pen scribbles and rounded boxes)
// lives on the same panel. It is click-through except while a drawing tool
// is on, and sits INSIDE the captured area, so everything is baked into the
// video (unlike the region border, which deliberately lives outside the crop).

enum AnnotationTool: String {
    case pen, box
}

@MainActor
final class CursorEffects: ObservableObject {
    static let shared = CursorEffects()

    /// The active drawing tool; nil means the panel is click-through.
    @Published private(set) var tool: AnnotationTool?
    /// False for window recordings, which capture only the window itself.
    @Published private(set) var canDraw = false

    private var panel: NSPanel?
    private var model = CursorEffectsModel()
    private var clickMonitors: [Any] = []

    /// The panel IS the recorded region (whole display for full-screen
    /// recordings): effects clip at its bounds, so nothing ever draws — or
    /// distracts — outside the area being captured. `cursorEffects` turns the
    /// trail, ripple and shake highlight on; drawing is always available.
    func show(regionAppKit: CGRect?, cursorEffects: Bool) {
        hide()
        let screen = regionAppKit.flatMap { region in
            NSScreen.screens.first { $0.frame.intersects(region) }
        } ?? NSScreen.main
        guard let screen else { return }
        let frame = regionAppKit ?? screen.frame

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        model = CursorEffectsModel(cursorEffects: cursorEffects)
        let host = NSHostingView(rootView: CursorEffectsView(
            model: model, screenFrame: frame))
        let input = AnnotationInputView(frame: NSRect(origin: .zero, size: frame.size))
        input.model = model
        host.frame = input.bounds
        host.autoresizingMask = [.width, .height]
        input.addSubview(host)
        panel.contentView = input
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        canDraw = true

        guard cursorEffects else { return model.start() }
        // Mouse events don't need Accessibility the way keyboard taps do.
        // Both monitors: global for other apps, local for our own windows.
        let ripple: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tool == nil else { return }
                self.model.addRipple(at: NSEvent.mouseLocation)
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: ripple) {
            clickMonitors.append(global)
        }
        clickMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { event in
            ripple(event)
            return event
        } as Any)
        model.start()
    }

    func hide() {
        tool = nil
        canDraw = false
        model.stop()
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    /// Picking the active tool again turns drawing off, which fades the
    /// drawings out and hands the mouse back to the apps underneath.
    func toggle(_ next: AnnotationTool) {
        guard panel != nil else { return }
        tool = tool == next ? nil : next
        model.tool = tool
        panel?.ignoresMouseEvents = tool == nil
        if tool == nil {
            model.fadeAnnotations()
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
        Analytics.track("screen_recording_draw_tool", ["tool": tool?.rawValue ?? "off"])
    }

    /// Clicks on the drawing surface are strokes, not clicks in the recording.
    func isDrawingSurface(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }
}

/// Turns drags into strokes while a tool is on; otherwise it is invisible to
/// the mouse (the panel ignores mouse events then, too).
final class AnnotationInputView: NSView {
    weak var model: CursorEffectsModel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        MainActor.assumeIsolated { model?.tool == nil } ? nil : super.hitTest(point).map { _ in self }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        if MainActor.assumeIsolated({ model?.tool != nil }) { NSCursor.crosshair.set() }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = global(event)
        MainActor.assumeIsolated { model?.beginStroke(at: point) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = global(event)
        MainActor.assumeIsolated { model?.extendStroke(to: point) }
    }

    override func mouseUp(with event: NSEvent) {
        let point = global(event)
        MainActor.assumeIsolated { model?.endStroke(at: point) }
    }

    private func global(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}

/// Samples the cursor at display cadence; the view redraws from this state.
@MainActor
final class CursorEffectsModel: ObservableObject {
    struct TrailPoint: Equatable {
        let position: CGPoint // AppKit global
        let time: Date
    }
    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        let position: CGPoint // AppKit global
        let time: Date
    }
    struct Highlight: Equatable {
        var area: CGRect // AppKit global
        let appeared: Date
        var lastShake: Date
    }
    struct Annotation: Identifiable, Equatable {
        let id = UUID()
        let tool: AnnotationTool
        var points: [CGPoint] // AppKit global; a box keeps its two corners
        var fadeStarted: Date?
    }

    @Published private(set) var trail: [TrailPoint] = []
    @Published private(set) var ripples: [Ripple] = []
    @Published private(set) var highlight: Highlight?
    @Published private(set) var annotations: [Annotation] = []
    var tool: AnnotationTool?
    private var samples: [TrailPoint] = []
    private var timer: Timer?
    private let cursorEffects: Bool
    static let trailLife: TimeInterval = 0.4
    static let rippleLife: TimeInterval = 0.55
    /// How far back a shake is looked for, and how long a highlight lingers
    /// after the shaking stops.
    static let shakeWindow: TimeInterval = 0.7
    static let highlightHold: TimeInterval = 1.4
    static let highlightFade: TimeInterval = 0.45
    static let annotationFade: TimeInterval = 0.5

    init(cursorEffects: Bool = true) {
        self.cursorEffects = cursorEffects
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        trail = []
        ripples = []
        samples = []
        highlight = nil
        annotations = []
    }

    func addRipple(at position: CGPoint) {
        ripples.append(Ripple(position: position, time: Date()))
    }

    // MARK: Drawing

    func beginStroke(at point: CGPoint) {
        guard let tool else { return }
        annotations.append(Annotation(tool: tool, points: [point, point]))
    }

    func extendStroke(to point: CGPoint) {
        guard var current = annotations.last, current.fadeStarted == nil else { return }
        switch current.tool {
        case .pen:
            guard let last = current.points.last,
                  hypot(point.x - last.x, point.y - last.y) > 1.5 else { return }
            current.points.append(point)
        case .box:
            current.points[1] = point
        }
        annotations[annotations.count - 1] = current
    }

    func endStroke(at point: CGPoint) {
        extendStroke(to: point)
        // A click without a drag leaves nothing worth keeping on screen.
        if let last = annotations.last, last.fadeStarted == nil,
           Self.extent(of: last.points) < 4 {
            annotations.removeLast()
        }
    }

    func fadeAnnotations() {
        let now = Date()
        for index in annotations.indices where annotations[index].fadeStarted == nil {
            annotations[index].fadeStarted = now
        }
    }

    // MARK: Sampling

    private func tick() {
        let now = Date()
        annotations.removeAll { $0.fadeStarted.map { now.timeIntervalSince($0) > Self.annotationFade } ?? false }
        guard cursorEffects else { return }
        let location = NSEvent.mouseLocation
        // Only extend the trail while the mouse is actually moving, and not
        // while drawing: the stroke itself is the trail then.
        if tool == nil,
           trail.last.map({ hypot($0.position.x - location.x, $0.position.y - location.y) > 2 }) ?? true {
            trail.append(TrailPoint(position: location, time: now))
        }
        trail.removeAll { now.timeIntervalSince($0.time) > Self.trailLife || tool != nil }
        ripples.removeAll { now.timeIntervalSince($0.time) > Self.rippleLife }

        samples.append(TrailPoint(position: location, time: now))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.shakeWindow }
        if tool == nil, let area = Self.shakeArea(in: samples) {
            highlight(area, at: now)
            samples.removeAll()
        } else if let current = highlight,
                  now.timeIntervalSince(current.lastShake) > Self.highlightHold + Self.highlightFade {
            highlight = nil
        }
    }

    func highlight(_ area: CGRect, at now: Date) {
        if var current = highlight, now.timeIntervalSince(current.lastShake) < Self.highlightHold {
            // Keep shaking over the same thing and the box grows to cover
            // it; drift away and it follows instead.
            current.area = current.area.intersects(area) ? current.area.union(area) : area
            current.lastShake = now
            highlight = current
        } else {
            highlight = Highlight(area: area, appeared: now, lastShake: now)
        }
    }

    /// A shake is several quick reversals of direction inside a small area,
    /// like scrubbing a highlighter over a button or a line of text. Returns
    /// the padded area to highlight, or nil for ordinary movement.
    nonisolated static func shakeArea(in samples: [TrailPoint]) -> CGRect? {
        guard samples.count >= 6 else { return nil }
        let points = samples.map(\.position)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // Big sweeps across the screen are travel, not a shake.
        guard bounds.width <= 420, bounds.height <= 420,
              max(bounds.width, bounds.height) >= 30 else { return nil }
        let reversals = max(reversalCount(points.map(\.x)), reversalCount(points.map(\.y)))
        guard reversals >= 4 else { return nil }
        let padded = bounds.insetBy(dx: -18, dy: -14)
        // Shaking along one axis still needs a box with some height to it.
        let width = max(padded.width, 72), height = max(padded.height, 40)
        return CGRect(x: padded.midX - width / 2, y: padded.midY - height / 2,
                      width: width, height: height)
    }

    /// Direction changes along one axis, counting only legs of at least 14pt
    /// so hand jitter never adds up to a shake.
    nonisolated static func reversalCount(_ values: [CGFloat]) -> Int {
        var reversals = 0
        var direction: CGFloat = 0
        var anchor = values.first ?? 0
        var extreme = anchor
        for value in values.dropFirst() {
            if direction == 0 {
                if abs(value - anchor) >= 14 { direction = value > anchor ? 1 : -1; extreme = value }
            } else if (value - extreme) * direction > 0 {
                extreme = value
            } else if abs(extreme - value) >= 14 {
                reversals += 1
                direction = -direction
                anchor = extreme
                extreme = value
            }
        }
        return reversals
    }

    nonisolated static func extent(of points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        return points.map { hypot($0.x - first.x, $0.y - first.y) }.max() ?? 0
    }
}

struct CursorEffectsView: View {
    @ObservedObject var model: CursorEffectsModel
    let screenFrame: CGRect

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, _ in
                let now = context.date
                drawHighlight(in: &canvas, now: now)
                // Trail: dots along the recent path, newest largest, all
                // fading out — reads as motion, never obscures content.
                for point in model.trail {
                    let age = now.timeIntervalSince(point.time)
                    let life = CursorEffectsModel.trailLife
                    guard age >= 0, age < life else { continue }
                    let fade = 1 - age / life
                    let radius = 3 + 5 * fade
                    let local = localPoint(point.position)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: local.x - radius, y: local.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(MM.Colors.flame.opacity(0.30 * fade)))
                }
                // Ripple: one ring expanding out from the click point.
                for ripple in model.ripples {
                    let age = now.timeIntervalSince(ripple.time)
                    let life = CursorEffectsModel.rippleLife
                    guard age >= 0, age < life else { continue }
                    let progress = age / life
                    let radius = 6 + 34 * progress
                    let local = localPoint(ripple.position)
                    canvas.stroke(
                        Path(ellipseIn: CGRect(x: local.x - radius, y: local.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(MM.Colors.flame.opacity(0.7 * (1 - progress))),
                        lineWidth: 2.5 * (1 - progress) + 0.5)
                }
                for annotation in model.annotations {
                    let fade = annotation.fadeStarted.map {
                        max(0, 1 - now.timeIntervalSince($0) / CursorEffectsModel.annotationFade)
                    } ?? 1
                    canvas.stroke(path(for: annotation),
                                  with: .color(MM.Colors.flame.opacity(fade)),
                                  style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Soft marker wash with a firm edge: pops in slightly large, settles,
    /// then fades once the shaking stops.
    private func drawHighlight(in canvas: inout GraphicsContext, now: Date) {
        guard let highlight = model.highlight else { return }
        let age = now.timeIntervalSince(highlight.appeared)
        let idle = now.timeIntervalSince(highlight.lastShake) - CursorEffectsModel.highlightHold
        let appear = min(1, max(0, age / 0.18))
        let fade = idle > 0 ? max(0, 1 - idle / CursorEffectsModel.highlightFade) : 1
        let opacity = appear * fade
        guard opacity > 0 else { return }
        let grow = 1.08 - 0.08 * appear
        let area = localRect(highlight.area)
        let rect = CGRect(x: area.midX - area.width * grow / 2, y: area.midY - area.height * grow / 2,
                          width: area.width * grow, height: area.height * grow)
        let shape = Path(roundedRect: rect, cornerRadius: MM.Layout.radius)
        canvas.fill(shape, with: .color(MM.Colors.flame.opacity(0.16 * opacity)))
        canvas.stroke(shape, with: .color(MM.Colors.flame.opacity(0.9 * opacity)), lineWidth: 3)
    }

    private func path(for annotation: CursorEffectsModel.Annotation) -> Path {
        let points = annotation.points.map(localPoint)
        switch annotation.tool {
        case .box:
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            return Path(roundedRect: rect,
                        cornerRadius: min(MM.Layout.radius, rect.width / 2, rect.height / 2))
        case .pen:
            // Curves through the midpoints keep a fast scribble smooth.
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first)
            for index in 1..<points.count {
                let previous = points[index - 1], current = points[index]
                path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2),
                                  control: previous)
            }
            if let last = points.last { path.addLine(to: last) }
            return path
        }
    }

    /// AppKit global (bottom-left origin) → view local (top-left origin).
    private func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenFrame.minX, y: screenFrame.maxY - global.y)
    }

    private func localRect(_ global: CGRect) -> CGRect {
        CGRect(x: global.minX - screenFrame.minX, y: screenFrame.maxY - global.maxY,
               width: global.width, height: global.height)
    }
}
