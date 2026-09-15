import Foundation

struct LiveTranscriptCorrection: Codable, Equatable, Sendable {
    let id: String
    let sourceSpeaker: String
    let start: Double
    let end: Double
    var text: String?
    var speakerName: String?

    func matchesChannel(_ turn: MeetingTurn) -> Bool {
        (sourceSpeaker == MeetingController.ownerLabel) == (turn.speaker == MeetingController.ownerLabel)
    }
}

enum MeetingLiveEdits {
    /// A human edit owns its exact audio interval. Re-decode only the edges
    /// of machine turns crossing that interval so replacing a sentence cannot
    /// erase untouched words elsewhere in a longer final-transcription turn.
    static func apply(_ corrections: [LiveTranscriptCorrection], to source: [MeetingTurn],
                      readEdge: (MeetingTurn) async -> [MeetingTurn]) async -> [MeetingTurn] {
        var turns = source
        for edit in corrections.filter({ $0.text != nil }).sorted(by: { $0.start < $1.start }) {
            var retained: [MeetingTurn] = []
            for turn in turns {
                guard edit.matchesChannel(turn), turn.end > edit.start, turn.start < edit.end else {
                    retained.append(turn)
                    continue
                }
                if turn.start < edit.start {
                    retained += await readEdge(MeetingTurn(start: turn.start, end: edit.start, speaker: turn.speaker, text: ""))
                }
                if turn.end > edit.end {
                    retained += await readEdge(MeetingTurn(start: edit.end, end: turn.end, speaker: turn.speaker, text: ""))
                }
            }
            if let text = edit.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                retained.append(MeetingTurn(start: edit.start, end: edit.end,
                                           speaker: edit.sourceSpeaker == MeetingController.ownerLabel ? MeetingController.ownerLabel : (edit.speakerName ?? edit.sourceSpeaker),
                                           text: text))
            }
            turns = retained
        }
        return turns.map { turn in
            var votes: [String: Double] = [:]
            for edit in corrections where edit.matchesChannel(turn) {
                guard let name = edit.speakerName, !name.isEmpty else { continue }
                votes[name, default: 0] += max(0, min(turn.end, edit.end) - max(turn.start, edit.start))
            }
            let ranked = votes.sorted { $0.value > $1.value }
            guard let best = ranked.first, best.value >= (turn.end - turn.start) * 0.5,
                  ranked.count == 1 || best.value > ranked[1].value else { return turn }
            var named = turn
            named.speaker = best.key
            return named
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }
}
