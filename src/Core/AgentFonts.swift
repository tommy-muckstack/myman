import AppKit
import CoreText

@MainActor enum AgentFonts {
    /// Evidence quality is deliberately heuristic, never an identification or
    /// a probability that a reconstructed letter matches the original font.
    static func quality(project: [String: Any], text: String) -> [String: Any] {
        let provenance = project["provenance"] as? [[String: Any]] ?? []
        let samples = (project["state"] as? [String: Any])?["samples"] as? [[String: Any]] ?? []
        let wanted = Set(text.filter { !$0.isWhitespace }.map(String.init)).sorted()
        var reports: [[String: Any]] = []
        var recapture: [String] = []
        for char in wanted {
            let source = provenance.first { $0["char"] as? String == char }?["source"] as? String ?? "missing"
            let candidates = samples.filter { $0["char"] as? String == char }
            func evidence(_ sample: [String: Any]) -> (Double, Double) {
                let height = (sample["bbox"] as? [String: Double])?["h"] ?? 0
                let confidence = sample["confidence"] as? Double ?? 0
                return (height, confidence)
            }
            let best = candidates.max { a, b in let x = evidence(a), y = evidence(b); return min(x.0, 80) * x.1 < min(y.0, 80) * y.1 }
            let (height, confidence) = best.map(evidence) ?? (0, 0)
            let supported = source == "traced" && height >= 24 && confidence >= 80
            let status = source == "missing" ? "missing" : source != "traced" ? "approximate" : supported ? "supported" : "weak_sample"
            if !supported { recapture.append(char) }
            reports.append(["char": char, "source": source, "status": status, "sample_count": candidates.count,
                            "best_sample_height_px": height, "ocr_confidence": confidence,
                            "reason": source == "missing" ? "No exported glyph" : source != "traced" ? "Not directly traced from a screenshot" : supported ? "Larger recognized sample available; inspect the specimen" : "Small or uncertain recognized sample"])
        }
        return ["assessment": recapture.isEmpty ? "supported_samples" : "more_samples_recommended", "heuristic": true,
                "characters": reports, "capture_next": recapture,
                "suggested_sample_text": (["HEIM", "mnrx", "bdhkl", "gpqy"] + recapture).joined(separator: " "),
                "guidance": "Capture the suggested letters in one typeface and weight at a larger size, ideally with at least 32 pixels of actual letter height. Include capitals, lowercase and descenders together. OCR confidence describes recognition, not outline accuracy. Inspect the actual-font specimen before sharing."]
    }
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
                "missing_from_specimen":missing, "exact_identity_verified":false, "specimen_text":sample, "quality": quality(project: project, text: sample),
                "limitations":"Generated from screenshot shapes. Missing specimen characters may appear as replacement glyphs; inferred letters are approximations."]
    }
}
