import AppKit
import SwiftUI

/// Draw shared vector checkboxes while preserving the underlying characters,
/// Markdown, selection, undo and accessibility in every rich note editor.
final class ChecklistLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let context = NSGraphicsContext.current?.cgContext else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let ns = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var at = characters.location
        var cursor = glyphsToShow.location
        while at < NSMaxRange(characters) {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            let prefix = storage.attribute(.manBlock, at: line.location, effectiveRange: nil) as? String ?? ""
            let checked = prefix.lowercased().contains("[x]")
            if checked || prefix.contains("[ ]") {
                let marker = ns.range(of: checked ? "☑" : "☐", range: line)
                if marker.location != NSNotFound {
                    let glyphs = glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
                    if glyphs.location >= cursor, NSMaxRange(glyphs) <= NSMaxRange(glyphsToShow),
                       let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) {
                        if glyphs.location > cursor {
                            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyphs.location - cursor), at: origin)
                        }
                        let bounds = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                        let size = (storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 19
                        let icon: MMIcon = checked ? .checklistChecked : .checklistUnchecked
                        context.saveGState()
                        context.translateBy(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
                        let color = storage.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor ?? .labelColor
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(size / 12)
                        context.setLineCap(.round)
                        context.setLineJoin(.round)
                        context.addPath(SVGShape(svgPath: icon.svgPath).path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath)
                        context.strokePath()
                        context.restoreGState()
                        cursor = NSMaxRange(glyphs)
                    }
                }
            }
            at = NSMaxRange(line)
        }
        if cursor < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphsToShow) - cursor), at: origin)
        }
    }
}
