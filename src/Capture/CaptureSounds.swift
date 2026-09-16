import AppKit

/// The little noise a screenshot makes. Ported from Snabbit: the same six
/// clips, the same names, and Silent for people who work in shared rooms.
enum CaptureSound: String, CaseIterable, Identifiable, Sendable {
    case silent, bloop, water, arcade, whoosh, epic, cartoon
    var id: String { rawValue }

    var label: String {
        switch self {
        case .silent: "Silent"
        case .bloop: "Bloop"
        case .water: "Water"
        case .arcade: "Arcade"
        case .whoosh: "Whoosh"
        case .epic: "Epic"
        case .cartoon: "Cartoon"
        }
    }

    var fileName: String? {
        switch self {
        case .silent: nil
        case .water: "water.mp3"
        default: rawValue + ".wav"
        }
    }

    var url: URL? {
        guard let fileName else { return nil }
        return Bundle.module.url(forResource: "Sounds", withExtension: nil)?.appendingPathComponent(fileName)
    }
}

/// Plays capture sounds. Keeps the current sound alive until it finishes;
/// NSSound stops the instant its last reference goes away.
@MainActor
final class CaptureSoundPlayer {
    static let shared = CaptureSoundPlayer()
    private var current: NSSound?

    func play(_ sound: CaptureSound = SettingsStore.shared.captureSound) {
        guard let url = sound.url, let player = NSSound(contentsOf: url, byReference: true) else { return }
        current?.stop()
        current = player
        player.play()
    }
}
