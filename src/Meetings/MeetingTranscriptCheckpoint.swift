import Foundation

/// Audio offsets and decoded words are one atomic write: after a crash we
/// either replay the last slice or resume after it, never skip unsaved words.
struct MeetingTranscriptCheckpoint: Codable, Sendable {
    var micPath: String?
    var systemPath: String?
    var micOffset = 0
    var systemOffset = 0
    var turns: [MeetingTurn] = []
    var unknownSpeakerCount = 0

    static func url(micPath: String?, systemPath: String?, regenerating: Bool = false) -> URL? {
        guard let path = micPath ?? systemPath else { return nil }
        let audio = URL(fileURLWithPath: path)
        let name = audio.deletingPathExtension().lastPathComponent
        let id = name.hasSuffix("-you") ? String(name.dropLast(4))
            : name.hasSuffix("-others") ? String(name.dropLast(7)) : name
        return audio.deletingLastPathComponent().appendingPathComponent(id + (regenerating ? "-regenerated.json" : "-transcript.json"))
    }

    static func load(at url: URL, micPath: String?, systemPath: String?) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard saved.micPath == micPath, saved.systemPath == systemPath,
              saved.micOffset >= 0, saved.systemOffset >= 0,
              saved.micOffset <= samples(at: micPath), saved.systemOffset <= samples(at: systemPath) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return saved
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func samples(at path: String?) -> Int {
        guard let path, let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else { return 0 }
        return max(0, (size.intValue - 44) / 2)
    }
}
