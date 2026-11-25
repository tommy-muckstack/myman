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
        case .small: return "Doc images up to 1200 px wide. Smallest files."
        case .balanced: return "Doc images up to 2400 px wide. The default."
        case .best: return "Doc images up to 2400 px wide, the largest the doc rules allow, and the least step-down."
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> CaptureQuality {
        CaptureQuality(rawValue: defaults.string(forKey: key) ?? "") ?? .balanced
    }
}
