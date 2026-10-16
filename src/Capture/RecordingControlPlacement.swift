import AppKit

enum RecordingControlPlacement {
    static var size: CGSize { CGSize(width: 360 * MM.Fonts.interfaceScale, height: 48 * MM.Fonts.interfaceScale) }

    /// AppKit coordinates: below the selected area first, then the nearest
    /// available edge. Clamp to the same display, including negative origins.
    static func frame(size: CGSize, selection: CGRect?, screens: [CGRect]) -> CGRect {
        let fallback = screens.first ?? CGRect(origin: .zero, size: size)
        let screen = selection.flatMap { region in
            screens.max { intersectionArea($0, region) < intersectionArea($1, region) }
        } ?? fallback
        let gap = MM.Layout.spacing
        let region = selection ?? screen
        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(x: max(screen.minX, min(rect.minX, screen.maxX - rect.width)),
                   y: max(screen.minY, min(rect.minY, screen.maxY - rect.height)),
                   width: rect.width, height: rect.height)
        }
        let x = clamped(CGRect(x: region.midX - size.width / 2, y: screen.minY, width: size.width, height: size.height)).minX
        let y = clamped(CGRect(x: screen.minX, y: region.midY - size.height / 2, width: size.width, height: size.height)).minY
        let candidates = [
            CGRect(x: x, y: region.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: x, y: region.maxY + gap, width: size.width, height: size.height),
            CGRect(x: region.maxX + gap, y: y, width: size.width, height: size.height),
            CGRect(x: region.minX - gap - size.width, y: y, width: size.width, height: size.height)
        ]
        return candidates.first(where: { screen.contains($0) }) ?? clamped(candidates[0])
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
