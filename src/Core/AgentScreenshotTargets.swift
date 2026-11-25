import AppKit

/// Picks one shareable window for an agent from an app name, a title fragment
/// or a window id. Pure, so the rules can be tested without a screen. An
/// ambiguous query returns every candidate instead of guessing.
enum AgentWindowMatch {
    struct Window: Equatable {
        let id: String
        let app: String
        let title: String
    }
    enum Outcome: Equatable {
        case one(String)
        case none
        case many([Window])
    }
    static func resolve(_ query: String, in windows: [Window]) -> Outcome {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .none }
        if let exact = windows.first(where: { $0.id == needle }) { return .one(exact.id) }
        // An exact app name wins over a title that merely contains it, so "Safari"
        // does not match a page titled "Safari guide".
        let exactApp = windows.filter { $0.app.lowercased() == needle }
        let fragment = windows.filter { $0.app.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
        let chosen = exactApp.isEmpty ? fragment : exactApp
        switch chosen.count {
        case 0: return .none
        case 1: return .one(chosen[0].id)
        default: return .many(chosen)
        }
    }
}

/// The `.ocr.json` sidecar written next to a screenshot. Geometry is in image
/// pixels with a top-left origin, matching screenshot.ocr.
enum AgentOCRSidecar {
    static let maximumBytes = 8 * 1024 * 1024
    static func document(text: String, regions: [AgentMarkup.Region], size: CGSize, scale: Double, capturedAt: String,
                         app: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, url: String? = nil) -> [String: Any] {
        [
            "version": 2,
            "text": text,
            "width": Int(size.width.rounded()),
            "height": Int(size.height.rounded()),
            "scale": scale,
            "captured_at": capturedAt,
            "coordinates": "image-pixels-top-left",
            "lines": regions.map { ["text": $0.text, "box": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].map(Double.init)] as [String: Any] },
            // Null when unknown, and never filled from a window that was not selected for this capture.
            "metadata": [
                "app": app ?? NSNull(), "bundle_id": bundleID ?? NSNull(), "window_title": windowTitle ?? NSNull(), "url": url ?? NSNull(),
                "timestamp": capturedAt, "display_scale": scale,
            ] as [String: Any],
        ]
    }
}

/// One plain sentence describing a capture for alt text. It is built from the
/// app, the window title and the first words on screen. No model is involved,
/// so the text is predictable and says only what was recorded.
enum AgentAltText {
    static let maximumLength = 240
    static func make(app: String?, windowTitle: String?, text: String) -> String {
        let source = app.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let title = windowTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(12).joined(separator: " ")
        var sentence = "Screenshot of " + (source ?? "the screen")
        if let title, title != source { sentence += ", titled “\(title)”" }
        if !words.isEmpty { sentence += ", showing the text “\(words)”" }
        sentence += "."
        if sentence.count > maximumLength { sentence = String(sentence.prefix(maximumLength - 1)) + "…" }
        return sentence
    }
}

/// Flattened images for a Paper doc: at most 2400 px wide and under 4 MB, as PNG.
/// Width steps down until the file fits, and an image that still does not fit is refused.
enum AgentDocImage {
    static let maximumWidth: CGFloat = 2400
    static let maximumBytes = 4 * 1024 * 1024
    /// Widths to try, largest first, for the chosen quality. Balanced keeps the 2400 px limit from the doc rules.
    static func widths(for quality: CaptureQuality) -> [CGFloat] {
        switch quality {
        case .small: return [1200, 900, 600]
        case .balanced: return [2400, 2000, 1600, 1200, 900]
        case .best: return [2400, 2000, 1600, 1200, 900]
        }
    }

    /// Returns the width used and the PNG bytes, or nil when even the smallest step is too large.
    static func fit(width: Int, height: Int, quality: CaptureQuality = CaptureQuality.current(), encode: (CGFloat) -> Data?) -> (width: Int, data: Data)? {
        guard width > 0, height > 0 else { return nil }
        for target in widths(for: quality) {
            let scale = min(1, target / CGFloat(width))
            let outWidth = max(1, Int((CGFloat(width) * scale).rounded()))
            guard let data = encode(CGFloat(outWidth)), data.count <= maximumBytes else { continue }
            return (outWidth, data)
        }
        return nil
    }
}
