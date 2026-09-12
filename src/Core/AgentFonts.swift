import AppKit
import CoreText

@MainActor enum AgentFonts {
    static func specimen(data: Data, text: String) throws -> [String: Any] {
        try FontProjectStore.validate(data)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let descriptor = descriptors.first else { throw AgentError("INVALID_FONT", "Cannot read font descriptors.") }
        let font = CTFontCreateWithFontDescriptor(descriptor, 54, nil)
        let lines = stride(from: 0, to: min(text.count, 160), by: 32).map { start in String(text.dropFirst(start).prefix(32)) }
        let height = CGFloat(max(180, 80 + lines.count * 85))
        let size = CGSize(width: 1200, height: height)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            .foregroundColor: NSColor.black
        ]
        let image = try AgentMediaStore.canvas(size: size) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: attributes)
                let rendered = CTLineCreateWithAttributedString(attributed)
                let width = CTLineGetTypographicBounds(rendered, nil, nil, nil)
                let scale = CGFloat(min(1.0, 1140.0 / max(1.0, width)))
                context.saveGState()
                let baseline = height - CGFloat(85 + index * 85)
                context.translateBy(x: 30, y: baseline)
                context.scaleBy(x: scale, y: scale); context.textPosition = .zero
                CTLineDraw(rendered, context)
                context.restoreGState()
            }
        }
        return try AgentMediaStore.shared.image(image, prefix: "font-specimen")
    }
    static func file(noteID: String, text: String? = nil) throws -> [String: Any] {
        let project = try FontProjectStore.load(noteID)
        guard let url = FontProjectStore.asset(noteID, "font.otf") else { throw AgentError("NOT_FOUND", "Font file unavailable.") }
        let data = try Data(contentsOf: url); try FontProjectStore.validate(data)
        let provenance = project["provenance"] as? [[String: Any]] ?? []
        let characters = provenance.compactMap { $0["char"] as? String }.sorted()
        let counts = Dictionary(grouping: provenance, by: { $0["source"] as? String ?? "unknown" }).mapValues(\.count)
        let sample = text ?? "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !?&@"
        let missing = Set(sample.map(String.init).filter { !characters.contains($0) && $0 != "\n" }).sorted()
        var attachment: [String: Any] = ["path":url.path, "mime_type":"font/otf", "file_size":data.count, "width":NSNull(), "height":NSNull(), "duration":NSNull(), "preview_path":NSNull()]
        do {
            let preview = try specimen(data: data, text: sample.replacingOccurrences(of: "\n", with: " "))
            attachment["preview_path"] = preview["path"]; attachment["preview_expires_at"] = preview["expires_at"]
        } catch { attachment["preview_status"] = "unavailable" }
        return ["id":"note-" + noteID, "path":url.path, "attachment":attachment, "coverage":counts, "characters":characters,
                "provenance":provenance, "matches":project["matches"] ?? [], "approximate":(counts["inferred"] ?? 0) > 0 || (counts["base"] ?? 0) > 0,
                "missing_from_specimen":missing, "exact_identity_verified":false, "specimen_text":sample,
                "limitations":"Generated from screenshot shapes. Missing specimen characters may appear as replacement glyphs; inferred letters are approximations."]
    }
}
