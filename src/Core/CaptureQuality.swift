import Foundation

/// How large the images a Paper doc gets are. Small is for quick notes, Balanced is the default,
/// and Best keeps the full 2400 px width the doc rules allow. The 4 MB cap applies at every setting.
enum CaptureQuality: String, CaseIterable, Identifiable {
    case small, balanced, best

    static let key = "captureQuality"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .balanced: return "Balanced"
        case .best: return "Best"
        }
    }

    var summary: String {
        switch self {
        case .small: return "Paper doc copies up to 1200 px wide. Saved screenshots are always full resolution."
        case .balanced: return "Paper doc copies up to 2400 px wide. Saved screenshots are always full resolution. The default."
        case .best: return "Paper doc copies up to 2400 px wide, the largest the doc rules allow. Saved screenshots are always full resolution."
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> CaptureQuality {
        CaptureQuality(rawValue: defaults.string(forKey: key) ?? "") ?? .balanced
    }
}
