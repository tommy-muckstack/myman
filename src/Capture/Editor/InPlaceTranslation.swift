import AppKit
import SwiftUI

// Lens-style in-place translation: every OCR line gets a patch that erases
// the original (background-sampled fill) and redraws the translated text
// matched on the axes that sell the illusion — position, size, color,
// weight. Font *identity* isn't detectable; those four are, and they're
// what the eye checks.

struct TranslationPatch: Identifiable {
    let id = UUID()
    /// Image coordinates, top-left origin, points.
    let rect: CGRect
    let background: NSColor
    let textColor: NSColor
    let text: String
    let fontSize: CGFloat
    let bold: Bool

    var font: NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular)
    }
}

enum InPlaceTranslation {
    /// Build patches for each (observation, translation) pair.
    static func patches(image: NSImage,
                        observations: [ImageAnalysis.TextObservation],
                        translations: [String]) -> [TranslationPatch] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sampler = PixelSampler(cg) else { return [] }
        let pixelScale = CGFloat(cg.width) / image.size.width
        var patches: [TranslationPatch] = []
        for (observation, translated) in zip(observations, translations) {
            let text = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let rect = observation.rect(in: image.size)
            guard rect.width > 4, rect.height > 4 else { continue }
            let pixelRect = CGRect(x: rect.minX * pixelScale, y: rect.minY * pixelScale,
                                   width: rect.width * pixelScale, height: rect.height * pixelScale)
            let (background, textColor, inkRatio) = sampler.colors(in: pixelRect)
            patches.append(TranslationPatch(
                rect: rect,
                background: background,
                textColor: textColor,
                text: text,
                fontSize: fittedFontSize(for: text, in: rect, bold: inkRatio > 0.30),
                bold: inkRatio > 0.30
            ))
        }
        return patches
    }

    /// Largest size that fills the line height and still fits the width.
    private static func fittedFontSize(for text: String, in rect: CGRect, bold: Bool) -> CGFloat {
        var size = max(7, rect.height * 0.78)
        while size > 6 {
            let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width <= rect.width * 1.04 { break }
            size -= 1
        }
        return size
    }

    /// Draw a patch into an AppKit context (bottom-left origin) whose image
    /// content occupies `imageRect` at 1:1 point scale — renderFinal's case.
    static func draw(_ patch: TranslationPatch, imageRect: CGRect, imageHeight: CGFloat) {
        let flippedY = imageRect.minY + (imageHeight - patch.rect.maxY)
        let target = CGRect(x: imageRect.minX + patch.rect.minX, y: flippedY,
                            width: patch.rect.width, height: patch.rect.height)
        let pad = target.insetBy(dx: -3, dy: -2)
        patch.background.setFill()
        NSBezierPath(roundedRect: pad, xRadius: 3, yRadius: 3).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: patch.font,
            .foregroundColor: patch.textColor,
        ]
        let textHeight = (patch.text as NSString).size(withAttributes: attributes).height
        let textRect = CGRect(x: target.minX,
                              y: target.minY + (target.height - textHeight) / 2,
                              width: target.width, height: textHeight)
        (patch.text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

/// Direct pixel access for background/text color sampling.
private struct PixelSampler {
    let data: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    private func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let i = y * bytesPerRow + x * 4
        return (Float(data[i]) / 255, Float(data[i + 1]) / 255, Float(data[i + 2]) / 255)
    }

    /// (background, text color, ink ratio) for a text box: the border ring
    /// votes for background; interior pixels far from it vote for the glyph
    /// color; their share of the box estimates stroke weight.
    func colors(in rect: CGRect) -> (NSColor, NSColor, Float) {
        let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return (.white, .black, 0) }

        var bg: (Float, Float, Float) = (0, 0, 0)
        var bgCount: Float = 0
        let step = max(1, (x1 - x0) / 64)
        for x in stride(from: x0, through: x1, by: step) {
            for y in [max(0, y0 - 2), min(height - 1, y1 + 2)] {
                if let p = pixel(x, y) { bg.0 += p.0; bg.1 += p.1; bg.2 += p.2; bgCount += 1 }
            }
        }
        guard bgCount > 0 else { return (.white, .black, 0) }
        bg = (bg.0 / bgCount, bg.1 / bgCount, bg.2 / bgCount)

        var ink: (Float, Float, Float) = (0, 0, 0)
        var inkCount: Float = 0
        var total: Float = 0
        let stepY = max(1, (y1 - y0) / 24)
        for x in stride(from: x0, through: x1, by: step) {
            for y in stride(from: y0, through: y1, by: stepY) {
                guard let p = pixel(x, y) else { continue }
                total += 1
                let distance = abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2)
                if distance > 0.45 {
                    ink.0 += p.0; ink.1 += p.1; ink.2 += p.2; inkCount += 1
                }
            }
        }
        let background = NSColor(red: CGFloat(bg.0), green: CGFloat(bg.1),
                                 blue: CGFloat(bg.2), alpha: 1)
        guard inkCount > 0 else {
            // No contrasting pixels — pick whatever contrasts the background.
            let luminance = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2
            return (background, luminance > 0.5 ? .black : .white, 0)
        }
        let textColor = NSColor(red: CGFloat(ink.0 / inkCount), green: CGFloat(ink.1 / inkCount),
                                blue: CGFloat(ink.2 / inkCount), alpha: 1)
        return (background, textColor, total > 0 ? inkCount / total : 0)
    }
}
