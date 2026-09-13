import AppKit
import AVFoundation
import CoreImage

/// A bounded, explicit timeline applied only to exported copies. Coordinates
/// use the oriented source image; times use the original recording timeline.
enum AgentVideoEdits {
    struct Edit: @unchecked Sendable {
        let type: String
        let start: Double
        let end: Double
        let rect: CGRect?
        let overlay: CIImage?
    }
    @MainActor static func prepare(_ inputs: [[String: Any]], size: CGSize, duration: Double) throws -> [Edit] {
        guard inputs.count <= 20 else { throw AgentError("INVALID_ARGUMENTS", "Use at most 20 timed edits.") }
        let bounds = CGRect(origin: .zero, size: size)
        var result: [Edit] = []
        for input in inputs {
            guard let type = input["type"] as? String, ["caption", "step", "title", "zoom", "redact"].contains(type),
                  let start = input["start"] as? Double, let end = input["end"] as? Double,
                  start.isFinite, end.isFinite, start >= 0, start < end, end <= duration + 0.001 else { throw AgentError("INVALID_ARGUMENTS", "Every edit needs a valid type and start/end inside the original recording.") }
            let rect = try (input["rect"] as? [Double]).map { try AgentImages.rect($0) }
            if let rect, !bounds.contains(rect) || rect.width < 2 || rect.height < 2 { throw AgentError("INVALID_ARGUMENTS", "Edit rectangles must fit the oriented source video.") }
            var overlay: CIImage?
            if ["zoom", "redact"].contains(type) {
                guard let rect, input["text"] == nil, input["number"] == nil else { throw AgentError("INVALID_ARGUMENTS", "Zoom and redact require rect, without text or number.") }
                if type == "zoom", max(size.width / rect.width, size.height / rect.height) > 8 { throw AgentError("INVALID_ARGUMENTS", "Zoom is limited to 8×.") }
                if type == "zoom", result.contains(where: { $0.type == "zoom" && start < $0.end && end > $0.start }) { throw AgentError("INVALID_ARGUMENTS", "Zoom intervals cannot overlap.") }
            } else {
                guard let text = input["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200,
                      rect == nil, type == "step" || input["number"] == nil else { throw AgentError("INVALID_ARGUMENTS", "Captions, steps and titles require text, without rect. Only steps accept number.") }
                let label: String
                if type == "step" {
                    guard let n = input["number"] as? Double, n.rounded() == n, (1...99).contains(n) else { throw AgentError("INVALID_ARGUMENTS", "Steps require an integer number from 1 to 99.") }
                    label = "\(Int(n)). \(text)"
                } else { label = text }
                let fontSize = max(14, min(type == "title" ? 64 : 36, size.width / 28))
                let font = NSFont(name: "Gellix-SemiBold", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
                let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style]
                let width = floor(size.width * 0.9)
                let measured = (label as NSString).boundingRect(with: CGSize(width: width - 24, height: size.height), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
                let height = ceil(measured.height + 24)
                guard width >= 40, height <= size.height * 0.6 else { throw AgentError("INVALID_ARGUMENTS", "Overlay text does not fit the video; shorten it.") }
                let image = try AgentMediaStore.canvas(size: CGSize(width: width, height: height)) { context in
                    context.setFillColor(NSColor.black.withAlphaComponent(type == "title" ? 1 : 0.85).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    (label as NSString).draw(with: CGRect(x: 12, y: 12, width: width - 24, height: height - 24), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
                }
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AgentError("INVALID_IMAGE", "Cannot render video text.") }
                let y = type == "title" ? (size.height - height) / 2 : type == "step" ? size.height - height - 16 : 16
                overlay = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: (size.width - width) / 2, y: y))
            }
            // Multiple captions/steps/title cards in the same slot would obscure
            // one another; fail before exporting rather than dropping labels.
            if !["zoom", "redact"].contains(type), result.contains(where: { $0.type == type && start < $0.end && end > $0.start }) { throw AgentError("INVALID_ARGUMENTS", "Overlays of the same type cannot overlap in time.") }
            result.append(Edit(type: type, start: start, end: end, rect: rect, overlay: overlay))
        }
        return result
    }
    static func render(_ image: CIImage, time: Double, edits: [Edit]) -> CIImage {
        let bounds = image.extent
        let active = edits.filter { time >= $0.start && time < $0.end }
        func bottomLeft(_ rect: CGRect) -> CGRect { CGRect(x: bounds.minX + rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height) }
        var output = image
        // Redact BEFORE zoom, so magnification cannot reveal covered pixels.
        for edit in active where edit.type == "redact" {
            output = CIImage(color: .black).cropped(to: bottomLeft(edit.rect!)).composited(over: output)
        }
        if let zoom = active.first(where: { $0.type == "zoom" }), let rect = zoom.rect {
            let region = bottomLeft(rect), scale = min(bounds.width / region.width, bounds.height / region.height)
            let enlarged = output.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: bounds.minX + (bounds.width - region.width * scale) / 2, y: bounds.minY + (bounds.height - region.height * scale) / 2))
            output = enlarged.composited(over: CIImage(color: .black).cropped(to: bounds))
        }
        for edit in active where edit.type != "title" {
            if let overlay = edit.overlay { output = overlay.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).composited(over: output) }
        }
        if let title = active.first(where: { $0.type == "title" }), let overlay = title.overlay {
            output = overlay.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY)).composited(over: CIImage(color: .black).cropped(to: bounds))
        }
        return output.cropped(to: bounds)
    }
}
