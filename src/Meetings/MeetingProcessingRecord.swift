import Foundation

/// Written before each attempt, so a process crash consumes an attempt too.
/// Restarting cannot create an infinite retry/crash loop.
struct MeetingProcessingRecord: Codable {
    enum Phase: String, Codable { case running, failed, complete }
    var phase: Phase = .running
    var attempts = 0
    var error = ""
    var regenerating = false
    var expectedTranscript = ""
    var micLag: Double = 0

    static func url(for meeting: Meeting) -> URL? {
        MeetingTranscriptCheckpoint.url(micPath: meeting.micAudioPath, systemPath: meeting.systemAudioPath)?
            .deletingPathExtension().appendingPathExtension("processing.json")
    }

    static func load(for meeting: Meeting) throws -> Self? {
        guard let url = url(for: meeting), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(for meeting: Meeting) throws {
        guard let url = Self.url(for: meeting) else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
