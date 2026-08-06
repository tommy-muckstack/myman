import AppKit
import SwiftUI

// Cursor presence for screen recordings: a subtle fading trail while the
// mouse moves and a ripple ring on every click. Drawn on a click-through
// panel INSIDE the captured area, so the effects are baked into the video
// (unlike the region border, which deliberately lives outside the crop).

@MainActor
final class CursorEffects {
    static let shared = CursorEffects()

    private var panel: NSPanel?
    private var model = CursorEffectsModel()
    private var clickMonitors: [Any] = []

    /// The panel IS the recorded region (whole display for full-screen
    /// recordings): effects clip at its bounds, so nothing ever draws — or
    /// distracts — outside the area being captured.
    func show(regionAppKit: CGRect?) {
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
        model = CursorEffectsModel()
        let host = NSHostingView(rootView: CursorEffectsView(
            model: model, screenFrame: frame))
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // Mouse events don't need Accessibility the way keyboard taps do.
        // Both monitors: global for other apps, local for our own windows.
        let ripple: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.model.addRipple(at: NSEvent.mouseLocation) }
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
        model.stop()
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        panel?.orderOut(nil)
        panel = nil
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

    @Published private(set) var trail: [TrailPoint] = []
    @Published private(set) var ripples: [Ripple] = []
    private var timer: Timer?
    static let trailLife: TimeInterval = 0.4
    static let rippleLife: TimeInterval = 0.55

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
    }

    func addRipple(at position: CGPoint) {
        ripples.append(Ripple(position: position, time: Date()))
    }

    private func tick() {
        let now = Date()
        let location = NSEvent.mouseLocation
        // Only extend the trail while the mouse is actually moving.
        if trail.last.map({ hypot($0.position.x - location.x, $0.position.y - location.y) > 2 }) ?? true {
            trail.append(TrailPoint(position: location, time: now))
        }
        trail.removeAll { now.timeIntervalSince($0.time) > Self.trailLife }
        ripples.removeAll { now.timeIntervalSince($0.time) > Self.rippleLife }
    }
}

struct CursorEffectsView: View {
    @ObservedObject var model: CursorEffectsModel
    let screenFrame: CGRect

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, _ in
                let now = context.date
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
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// AppKit global (bottom-left origin) → view local (top-left origin).
    private func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenFrame.minX, y: screenFrame.maxY - global.y)
    }
}
