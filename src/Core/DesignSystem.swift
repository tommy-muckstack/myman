import AppKit
import SwiftUI

// MM — My Man design tokens. Near-monochrome, weight-driven hierarchy
// (secondary text is Light, never grey Regular), both themes from day one.
// The only saturated color in the app is the accent, used sparingly.
enum MM {

    // MARK: Colors (semantic only — never use .black/.white in views)

    enum Colors {
        private static func dynamic(_ name: String,
                                    light: NSColor,
                                    dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }

        static let background = dynamic("mm.background",
            light: NSColor(white: 1.0, alpha: 1.0),
            dark: NSColor(white: 0.08, alpha: 1.0))
        static let surface = dynamic("mm.surface",
            light: NSColor(white: 0.975, alpha: 1.0),
            dark: NSColor(white: 0.12, alpha: 1.0))
        static let textPrimary = dynamic("mm.textPrimary",
            light: NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1),
            dark: NSColor(white: 0.96, alpha: 1))
        static let textSecondary = dynamic("mm.textSecondary",
            light: NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.7))
        static let textTertiary = dynamic("mm.textTertiary",
            light: NSColor(red: 0.60, green: 0.60, blue: 0.65, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.5))
        static let border = dynamic("mm.border",
            light: NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.12))
        static let accent = dynamic("mm.accent",
            light: NSColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1),
            dark: NSColor(red: 1.0, green: 0.78, blue: 0.40, alpha: 1))
        static let danger = dynamic("mm.danger",
            light: NSColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 1),
            dark: NSColor(red: 1.0, green: 0.35, blue: 0.32, alpha: 1))
        /// The mascot's fire — vermilion #E8442A, same in both themes (it
        /// draws over recorded screen content, not over our surfaces).
        static let flame = Color(red: 0.910, green: 0.267, blue: 0.165)
    }

    // MARK: Type — Outfit everywhere (the MuckStack family font); weight IS the hierarchy

    enum Fonts {
        static func registerFonts() {
            for weight in ["Light", "Regular", "Medium", "SemiBold", "Bold"] {
                guard let url = Bundle.module.url(
                    forResource: "Fonts/Outfit-\(weight)", withExtension: "ttf")
                    ?? Bundle.module.url(forResource: "Outfit-\(weight)", withExtension: "ttf")
                else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        static func outfit(_ size: CGFloat, _ weight: OutfitWeight = .regular) -> Font {
            .custom("Outfit-\(weight.rawValue)", size: size)
        }

        enum OutfitWeight: String {
            case light = "Light", regular = "Regular", medium = "Medium"
            case semiBold = "SemiBold", bold = "Bold"
        }

        static let title = outfit(20, .medium)
        static let body = outfit(15)
        static let bodyInput = outfit(16)
        static let secondary = outfit(13, .light)
        static let metadata = outfit(11.5, .light)
        static let hint = outfit(11, .light)
    }

    // MARK: Layout

    enum Layout {
        static let padding: CGFloat = 16
        static let paddingLarge: CGFloat = 20
        static let radius: CGFloat = 14
        static let radiusSmall: CGFloat = 8
        static let spacing: CGFloat = 12
        static let panelWidth: CGFloat = 620
    }

    // MARK: Motion — named springs; every state change animates with one of these


    enum Motion {
        static let gentle = Animation.easeInOut(duration: 0.25)
        static let elastic = Animation.spring(response: 0.3, dampingFraction: 0.6)
        static let silky = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.30)
        static let delightful = Animation.interpolatingSpring(stiffness: 300, damping: 30)
    }
}

// MARK: - Interaction standard

extension View {
    /// Every clickable in My Man: a hit area no smaller than `minSize` and a
    /// pointing-hand cursor on hover. Small icons stay visually small — the
    /// TARGET grows, not the glyph.
    func clickable(minSize: CGFloat = 24) -> some View {
        self
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
            // Cursor via an AppKit cursor RECT, not NSCursor.set() in onHover:
            // set() gets stomped by the window's cursor-update pass in our
            // non-activating panels (launcher, side panels), so the hand never
            // stuck there. Cursor rects are re-applied by AppKit itself.
            .overlay(CursorRectOverlay())
    }
}

/// Transparent, click-through view whose only job is showing the pointing
/// hand over its bounds. Plain cursor rects are NOT enough here: they only
/// fire for key windows, and My Man's panels are non-activating (the app is
/// usually inactive while you mouse over them). An .activeAlways tracking
/// area gets cursorUpdate regardless.
private struct CursorRectOverlay: NSViewRepresentable {
    final class RectView: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved,
                          .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }
        // AppKit's automatic cursor pass resets to arrow on every move over a
        // window with no matching cursor rect, so a single set-on-enter loses.
        // Re-assert on every tracked event inside the button instead.
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
        // Never intercept clicks — SwiftUI gestures underneath must fire.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RectView { RectView() }
    func updateNSView(_ nsView: RectView, context: Context) {}
}
