import AppKit
import CryptoKit

/// Geometry is always in source image pixels, with a top-left origin.
/// OCR line identifiers include the text and geometry, so a changed recognition
/// result cannot silently retarget an earlier selection.
enum AgentMarkup {
    struct Region {
        let id: String
        let text: String
        let rect: CGRect
        var granularity = "line"
        var json: [String: Any] { ["id": id, "text": text, "rect": [rect.minX, rect.minY, rect.width, rect.height].map(Double.init), "granularity": granularity] }
    }
    static func words(_ observations: [ImageAnalysis.TextObservation], size: CGSize) -> [Region] {
        regions(observations.flatMap { $0.words ?? [] }, size: size).map {
            Region(id: "word-" + $0.id, text: $0.text, rect: $0.rect, granularity: "word")
        }
    }
    static func regions(_ observations: [ImageAnalysis.TextObservation], size: CGSize) -> [Region] {
        observations.prefix(2000).map { line in
            let r = line.rect(in: size)
            let key = line.text + [r.minX, r.minY, r.width, r.height].map { String(format: "%.2f", $0) }.joined(separator: ",")
            let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return Region(id: "ocr-" + digest, text: line.text, rect: r)
        }
    }
    static func matches(_ regions: [Region], text: String) -> [Region] {
        regions.filter { $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    static func resolve(_ annotation: [String: Any], regions: [Region], size: CGSize) throws -> [String: Any] {
        guard annotation["target_text"] != nil || annotation["target_region"] != nil else { return annotation }
        guard (annotation["target_text"] != nil) != (annotation["target_region"] != nil), annotation["rect"] == nil, annotation["to"] == nil else {
            throw AgentError("INVALID_ARGUMENTS", "Choose target_text or target_region, without rect/to.")
        }
        let candidates: [Region]
        if let id = annotation["target_region"] as? String { candidates = regions.filter { $0.id == id } }
        else {
            let text = annotation["target_text"] as! String
            let exactWords = regions.filter { $0.granularity == "word" && $0.text.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            candidates = exactWords.isEmpty ? matches(regions.filter { $0.granularity == "line" }, text: text) : exactWords
        }
        guard candidates.count == 1 else {
            throw AgentError(candidates.isEmpty ? "TARGET_NOT_FOUND" : "AMBIGUOUS_TARGET",
                             "Select a region ID from capture targets; nothing was changed.",
                             details: ["candidates": candidates.prefix(50).map(\.json), "total": candidates.count])
        }
        var result = annotation
        let target = candidates[0].rect.insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: size))
        if annotation["type"] as? String == "arrow" {
            result["to"] = [Double(target.midX), Double(target.midY)]
            if result["from"] == nil {
                let x = max(2, target.minX - min(100, size.width / 5))
                let y = max(2, target.minY - min(70, size.height / 5))
                result["from"] = [Double(x), Double(y)]
            }
        } else { result["rect"] = [target.minX, target.minY, target.width, target.height].map(Double.init) }
        return result
    }
    /// Pick a readable, in-bounds label position with minimal overlap. Agents
    /// can still inspect the rendered preview before saving the result.
    static func labelRect(size: CGSize, target: CGRect, canvas: CGSize, occupied: [CGRect]) throws -> CGRect {
        guard size.width <= canvas.width, size.height <= canvas.height else {
            throw AgentError("INVALID_ARGUMENTS", "Callout label does not fit; shorten its text or reduce font_size.")
        }
        let positions = [CGPoint(x: target.minX, y: target.minY - size.height - 8),
                         CGPoint(x: target.maxX + 8, y: target.minY),
                         CGPoint(x: target.minX, y: target.maxY + 8),
                         CGPoint(x: target.minX - size.width - 8, y: target.minY),
                         .zero, CGPoint(x: canvas.width - size.width, y: 0),
                         CGPoint(x: 0, y: canvas.height - size.height),
                         CGPoint(x: canvas.width - size.width, y: canvas.height - size.height)]
        let rects = positions.map { p in CGRect(x: min(max(0, p.x), canvas.width - size.width), y: min(max(0, p.y), canvas.height - size.height), width: size.width, height: size.height) }
        func penalty(_ r: CGRect) -> CGFloat {
            ([target] + occupied).reduce(0) { value, other in
                let intersection = r.intersection(other)
                return value + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        return rects.min { penalty($0) < penalty($1) }!
    }
    @MainActor static func badge(_ text: String, fontSize: CGFloat, color: NSColor) throws -> NSImage {
        let font = NSFont(name: "Gellix-SemiBold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let measured = (text as NSString).size(withAttributes: attributes)
        let size = CGSize(width: ceil(measured.width + 20), height: ceil(measured.height + 12))
        return try AgentMediaStore.canvas(size: size) { _ in
            color.setFill(); NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(at: CGPoint(x: 10, y: 6), withAttributes: attributes)
        }
    }
    @MainActor static func circle(size: CGSize, color: NSColor) throws -> NSImage {
        guard size.width >= 8, size.height >= 8 else { throw AgentError("INVALID_ARGUMENTS", "Circle bounds must be at least 8 pixels in each dimension.") }
        return try AgentMediaStore.canvas(size: size) { _ in
            color.setStroke(); let path = NSBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)); path.lineWidth = 3; path.stroke()
        }
    }
}
