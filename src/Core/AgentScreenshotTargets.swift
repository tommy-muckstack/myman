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
    static func document(text: String, regions: [AgentMarkup.Region], size: CGSize, scale: Double, capturedAt: String) -> [String: Any] {
        [
            "version": 1,
            "text": text,
            "width": Int(size.width.rounded()),
            "height": Int(size.height.rounded()),
            "scale": scale,
            "captured_at": capturedAt,
            "coordinates": "image-pixels-top-left",
            "lines": regions.map { ["text": $0.text, "box": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].map(Double.init)] as [String: Any] },
        ]
    }
}
