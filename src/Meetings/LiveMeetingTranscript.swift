import Foundation
import FluidAudio
import Combine
import GRDB

protocol LiveMeetingTranscriptReading: Sendable {
    func prepare() async throws
    func next() async throws -> [MeetingTurn]
    func rememberVoice(name: String, start: Double, end: Double) async throws
    func savedTurns() async -> [MeetingTurn]
}

extension LiveMeetingTranscriptReading {
    func savedTurns() async -> [MeetingTurn] { [] }
    func rememberVoice(name: String, start: Double, end: Double) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// Reads bounded slices of the WAVs already being recorded. This owns its
/// models: live decoding must never race dictation or final transcription.
actor LiveMeetingTranscriptReader: LiveMeetingTranscriptReading {
    private let micURL: URL?
    private let systemURL: URL?
    private let singleRemote: Bool
    private let profileDatabase: DatabaseQueue?
    private let startedAt: Date?
    private var micOffset = 0
    private var systemOffset = 0
    /// Seconds of real time per second of file audio, per track. 1 unless a
    /// track has more audio than the clock allows (see `wallClockScale`).
    private var micScale = 1.0
    private var systemScale = 1.0
    private var driftReported: Set<String> = []
    private var asr: AsrManager?
    private var diarizer: DiarizerManager?
    private var speakerNames: [String: String] = [:]
    private var unknownSpeakerCount = 0
    private let checkpointURL: URL?
    private let wallDuration: Double?
    private var checkpoint: MeetingTranscriptCheckpoint
    private var restoredCheckpoint = false

    private let micLag: Double

    init(micURL: URL?, systemURL: URL?, singleRemote: Bool, profileDatabase: DatabaseQueue? = nil,
         startedAt: Date? = nil, micLag: Double = 0, checkpointURL: URL? = nil,
         wallDuration: Double? = nil) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.singleRemote = singleRemote
        self.profileDatabase = profileDatabase
        self.startedAt = startedAt
        self.micLag = micLag
        self.checkpointURL = checkpointURL
        self.wallDuration = wallDuration
        self.checkpoint = MeetingTranscriptCheckpoint(micPath: micURL?.path, systemPath: systemURL?.path)
    }

    /// A track cannot legitimately hold more audio than time has passed.
    /// When it does (a device swap resampled at the wrong rate), stretch its
    /// timeline onto the clock so no line is ever dated in the future and
    /// both tracks still interleave in order. Lag is normal and left alone.
    static func wallClockScale(fileSeconds: Double, wallSeconds: Double?) -> Double {
        guard let wallSeconds, wallSeconds > 0, fileSeconds > wallSeconds + 1 else { return 1 }
        return wallSeconds / fileSeconds
    }

    private func align(_ turns: [MeetingTurn], track: String, fileSeconds: Double) -> [MeetingTurn] {
        let wall = wallDuration ?? startedAt.map { Date().timeIntervalSince($0) }
        let scale = Self.wallClockScale(fileSeconds: fileSeconds, wallSeconds: wall)
        if track == "mic" { micScale = scale } else { systemScale = scale }
        if scale < 1, driftReported.insert(track).inserted {
            Analytics.track("live_transcript_time_drift",
                            ["track": track, "file_s": Int(fileSeconds), "wall_s": Int(wall ?? 0)])
        }
        let lag = track == "mic" ? micLag : 0
        guard scale < 1 || lag > 0 else { return turns }
        return turns.map { MeetingTurn(start: $0.start * scale + lag, end: $0.end * scale + lag, speaker: $0.speaker, text: $0.text) }
    }

    func prepare() async throws {
        if !restoredCheckpoint {
            if let checkpointURL, let saved = try MeetingTranscriptCheckpoint.load(
                at: checkpointURL, micPath: micURL?.path, systemPath: systemURL?.path) {
                checkpoint = saved
                micOffset = saved.micOffset
                systemOffset = saved.systemOffset
                // Fresh diarizer state cannot establish continuity with old
                // anonymous voice IDs. Allocate new labels after a restart.
                unknownSpeakerCount = saved.unknownSpeakerCount
            }
            restoredCheckpoint = true
        }
        guard asr == nil else { return }
        let models = try await AsrModels.downloadAndLoad()
        try Task.checkCancellation()
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asr = asr
        if systemURL != nil, !singleRemote {
            // Unavailable speaker models should not hide readable words.
            if let models = try? await DiarizerModels.downloadIfNeeded() {
                try Task.checkCancellation()
                let diarizer = DiarizerManager()
                diarizer.initialize(models: models)
                let known = (try? VoiceProfiles.all(database: profileDatabase ?? Database.shared)) ?? []
                diarizer.initializeKnownSpeakers(known.filter { $0.embedding.count == 256 }.map {
                    Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
                })
                speakerNames = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0.name) })
                self.diarizer = diarizer
            }
        }
    }

    func savedTurns() async -> [MeetingTurn] { checkpoint.turns }

    func hasUnreadAudio() -> Bool {
        micOffset < MeetingTranscriptCheckpoint.samples(at: micURL?.path)
            || systemOffset < MeetingTranscriptCheckpoint.samples(at: systemURL?.path)
    }

    func next() async throws -> [MeetingTurn] { try await next(final: false) }

    func next(final: Bool) async throws -> [MeetingTurn] {
        try Task.checkCancellation()
        let oldMic = micOffset, oldSystem = systemOffset
        var committed = false
        defer { if !committed { micOffset = oldMic; systemOffset = oldSystem } }
        var mic: [MeetingTurn] = []
        var remote: [MeetingTurn] = []
        if let micURL, let chunk = try Self.readChunk(at: micURL, offset: micOffset, final: final) {
            mic = try await decode(chunk, speaker: MeetingController.ownerLabel)
            micOffset += chunk.samples.count
            mic = align(mic, track: "mic", fileSeconds: Double(micOffset) / 16000)
        }
        try Task.checkCancellation()
        if let systemURL, let chunk = try Self.readChunk(at: systemURL, offset: systemOffset, final: final) {
            if singleRemote {
                remote = try await decode(chunk, speaker: MeetingController.remoteLabel)
            } else if Self.hasSpeech(chunk.samples), let diarizer {
                let result = try? diarizer.performCompleteDiarization(chunk.samples, sampleRate: 16000)
                let voices = (result?.segments ?? []).map { segment -> MeetingTurn in
                    let id = String(segment.speakerId)
                    if speakerNames[id] == nil {
                        unknownSpeakerCount += 1
                        speakerNames[id] = "Speaker \(unknownSpeakerCount + 1)"
                    }
                    return MeetingTurn(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds),
                                       speaker: speakerNames[id]!, text: "")
                }
                for interval in Self.intervals(voices: voices, duration: Double(chunk.samples.count) / 16000) {
                    let lower = max(0, Int(interval.start * 16000))
                    let upper = min(chunk.samples.count, Int(interval.end * 16000))
                    guard upper - lower >= 6400 else { continue }
                    let part = Chunk(offset: chunk.offset + lower, samples: Array(chunk.samples[lower..<upper]))
                    remote += try await decode(part, speaker: interval.speaker)
                }
            } else {
                remote = try await decode(chunk, speaker: "Speaker unclear")
            }
            systemOffset += chunk.samples.count
            remote = align(remote, track: "system", fileSeconds: Double(systemOffset) / 16000)
        }
        // Suppress microphone copies of the remote speech using the same
        // conservative textual evidence as the final transcript.
        let batch = (mic + remote).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        try Task.checkCancellation()
        var saved = checkpoint
        saved.micOffset = micOffset
        saved.systemOffset = systemOffset
        saved.unknownSpeakerCount = unknownSpeakerCount
        saved.turns += batch
        if micOffset != oldMic || systemOffset != oldSystem, let checkpointURL {
            try saved.save(to: checkpointURL)
        }
        checkpoint = saved
        committed = true
        return batch
    }

    struct Chunk: Sendable {
        let offset: Int
        let samples: [Float]
    }

    func rememberVoice(name: String, start: Double, end: Double) async throws {
        // Rows carry clock time; the WAV is addressed in file time.
        let start = start / systemScale, end = end / systemScale
        guard let systemURL, end - start >= 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
        if diarizer == nil {
            let models = try await DiarizerModels.downloadIfNeeded()
            try Task.checkCancellation()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
        }
        guard let diarizer else { throw CocoaError(.featureUnsupported) }
        let file = try FileHandle(forReadingFrom: systemURL)
        defer { try? file.close() }
        try file.seek(toOffset: 44 + UInt64(max(0, start) * 16000) * 2)
        let data = try file.read(upToCount: Int(min(12, end - start) * 16000) * 2) ?? Data()
        let samples = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
        guard samples.count >= 32000, Self.hasSpeech(samples) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        try Task.checkCancellation()
        try VoiceProfiles.remember(name: name, embedding: embedding, database: profileDatabase ?? Database.shared)
        // Keep the current session's voice IDs stable; this confirmed profile
        // is loaded at the start of the next meeting.
    }

    /// Our writer's header is finalized only on stop. Read raw PCM after the
    /// fixed header using the actual file length, leaving partial samples and
    /// short tails for the next read. Memory stays below twelve seconds/track.
    static func readChunk(at url: URL, offset: Int, final: Bool = false) throws -> Chunk? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: 44 + UInt64(offset) * 2)
        let data = try file.read(upToCount: 12 * 16000 * 2) ?? Data()
        guard data.count >= (final ? 2 : 4 * 16000 * 2) else { return nil }
        var samples = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
        if samples.count == 12 * 16000 {
            let cut = MeetingController.quietestCutSample(in: samples, from: 8 * 16000)
            samples.removeLast(samples.count - cut)
        }
        return Chunk(offset: offset, samples: samples)
    }

    static func hasSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        return sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)) > 0.0015
    }

    /// Preserve stable voice IDs across windows, and mark overlapping voices
    /// as uncertain instead of attributing a mixed sentence to one person.
    static func intervals(voices: [MeetingTurn], duration: Double) -> [MeetingTurn] {
        let points = Set([0, duration] + voices.flatMap { [max(0, min(duration, $0.start)), max(0, min(duration, $0.end))] }).sorted()
        var intervals: [MeetingTurn] = []
        for (start, end) in zip(points, points.dropFirst()) where end > start {
            let speakers = Set(voices.filter { $0.start < end && $0.end > start }.map(\.speaker))
            let speaker = speakers.count == 1 ? speakers.first! : "Speaker unclear"
            if intervals.last?.speaker == speaker {
                intervals[intervals.count - 1].end = end
            } else {
                intervals.append(MeetingTurn(start: start, end: end, speaker: speaker, text: ""))
            }
        }
        return intervals
    }

    private func decode(_ chunk: Chunk, speaker: String) async throws -> [MeetingTurn] {
        try Task.checkCancellation()
        guard Self.hasSpeech(chunk.samples), let asr else { return [] }
        var state = TdtDecoderState.make()
        // Speaker splits and the final tail can be shorter than the model's
        // minimum input. Pad silence without changing the source timestamps.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
        let input = chunk.samples + [Float](repeating: 0, count: max(0, minimum - chunk.samples.count))
        let result = try await asr.transcribe(input, decoderState: &state)
        try Task.checkCancellation()
        let text = TranscriptionService.discardTaskHallucination(result.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let duration = Double(chunk.samples.count) / 16000
        let timings = (result.tokenTimings ?? []).filter { $0.token.contains(where: { $0.isLetter || $0.isNumber }) }
        let audible = MeetingController.audibleBounds(chunk.samples)
        let first = max(0, min(duration, timings.first?.startTime ?? audible?.start ?? 0))
        let last = max(first, min(duration, timings.last?.endTime ?? audible?.end ?? duration))
        return [MeetingTurn(start: Double(chunk.offset) / 16000 + first,
                            end: Double(chunk.offset) / 16000 + last,
                            speaker: speaker, text: text)]
    }
}

@MainActor
final class LiveMeetingTranscript: ObservableObject {
    enum Status: Equatable { case waiting, preparing, live, unavailable }
    /// One block per run of speech: the speaker, when they STARTED, and
    /// everything they said until someone else spoke. `turnIDs` lists the
    /// machine turns folded into the block, first one giving the row its id.
    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let speaker: String
        let timestamp: String
        let text: String
        var suggestedName: String? = nil
        var turnIDs: [String] = []
        /// Names read off the call window, offered as one-tap choices.
        var callParticipants: [String] = []
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var status: Status = .waiting
    @Published var editingRowID: String?
    @Published private(set) var voiceLearningMessage: String?
    var onEditsChanged: ([LiveTranscriptCorrection]) -> Void = { _ in }
    var onTextCorrected: (String) -> Void = { _ in }
    private var turns: [MeetingTurn] = []
    /// Human text, keyed by the row (group) id it replaced.
    private var correctedText: [String: String] = [:]
    /// Where a corrected group's audio ends — the correction owns the whole
    /// interval, not just the first machine turn.
    private var correctedEnd: [String: Double] = [:]
    /// Machine turns whose words a group correction already replaced.
    private var absorbed: [String: String] = [:]
    private var confirmedNames: [String: String] = [:]
    private var ownerName = ""
    private var candidates = SpeakerCandidates.none
    private(set) var callParticipants: [String] = []
    private var reader: (any LiveMeetingTranscriptReading)?
    private var learningTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var rowTask: Task<Void, Never>?
    private var rowRevision = UUID()
    var onProgress: ([MeetingTurn]) -> Void = { _ in }
    private let automaticRetryDelays: [Double]

    init(automaticRetryDelays: [Double] = [2, 4]) {
        self.automaticRetryDelays = automaticRetryDelays
    }

    func start(reader: any LiveMeetingTranscriptReading, ownerName: String, candidates: SpeakerCandidates) {
        stop()
        self.ownerName = ownerName
        self.candidates = candidates
        self.reader = reader
        resume(reader: reader)
    }

    /// Retry the same reader at its current audio offsets, keeping human
    /// corrections and stable speaker IDs already shown in this meeting.
    func retry() {
        guard status == .unavailable, let reader else { return }
        task?.cancel()
        generation = UUID()
        resume(reader: reader)
    }

    private func resume(reader: any LiveMeetingTranscriptReading) {
        let generation = self.generation
        status = .preparing
        task = Task { [weak self] in
            do {
                for attempt in 0...(self?.automaticRetryDelays.count ?? 0) {
                    do { try await reader.prepare(); break }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        guard let self, attempt < self.automaticRetryDelays.count else { throw error }
                        try await Task.sleep(for: .seconds(self.automaticRetryDelays[attempt]))
                    }
                }
                try Task.checkCancellation()
                guard self?.generation == generation else { return }
                let saved = await reader.savedTurns()
                try Task.checkCancellation()
                guard self?.generation == generation else { return }
                if self?.turns.isEmpty == true {
                    self?.append(saved, ownerName: self?.ownerName ?? "", candidates: self?.candidates ?? .none)
                }
                self?.status = .live
                var failures = 0
                while !Task.isCancelled, self?.generation == generation {
                    let next: [MeetingTurn]
                    do {
                        next = try await reader.next()
                        failures = 0
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failures += 1
                        guard let self, failures <= self.automaticRetryDelays.count else { throw error }
                        self.status = .preparing
                        try await Task.sleep(for: .seconds(self.automaticRetryDelays[failures - 1]))
                        continue
                    }
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    self.status = .live
                    // Names can arrive mid-meeting (calendar refresh, the
                    // call window): always label with the latest evidence.
                    self.append(next, ownerName: self.ownerName, candidates: self.candidates)
                    if !next.isEmpty { self.onProgress(await reader.savedTurns()) }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                // Stop/discard/new recording owns the visible state.
            } catch {
                guard self?.generation == generation else { return }
                self?.status = .unavailable
            }
        }
    }

    @discardableResult func stop() -> Task<Void, Never>? {
        let finishing = task
        task?.cancel()
        rowTask?.cancel()
        rowTask = nil
        rowRevision = UUID()
        learningTask?.cancel()
        learningTask = nil
        reader = nil
        voiceLearningMessage = nil
        task = nil
        generation = UUID()
        turns = []
        correctedText = [:]
        correctedEnd = [:]
        absorbed = [:]
        confirmedNames = [:]
        callParticipants = []
        editingRowID = nil
        rows = []
        status = .waiting
        return finishing
    }

    /// New speaker evidence for a meeting already in progress.
    func updateCandidates(_ candidates: SpeakerCandidates) {
        guard self.candidates != candidates else { return }
        self.candidates = candidates
        rebuildRows()
    }

    /// Names visible on the call window. They never label a line on their
    /// own; they become one-tap choices and a "Possibly" hint when only one
    /// other person is on the call.
    func updateCallParticipants(_ names: [String], candidates: SpeakerCandidates? = nil) {
        let cleaned = names.filter { !$0.isEmpty && !MeetingSource.genericSpeaker($0) }
        guard callParticipants != cleaned || (candidates != nil && candidates != self.candidates) else { return }
        if let candidates { self.candidates = candidates }
        callParticipants = cleaned
        rebuildRows()
    }

    func append(_ batch: [MeetingTurn], ownerName: String, candidates: SpeakerCandidates) {
        guard !batch.isEmpty else { return }
        turns += batch
        self.ownerName = ownerName
        self.candidates = candidates
        turns.sort { ($0.start, $0.end, $0.speaker) < ($1.start, $1.end, $1.speaker) }
        rebuildRows()
        if !confirmedNames.isEmpty { onEditsChanged(corrections) }
    }

    private func rowID(_ turn: MeetingTurn) -> String { Self.identifier(turn) }
    nonisolated private static func identifier(_ turn: MeetingTurn) -> String { "\(turn.speaker)-\(turn.start)-\(turn.end)" }

    var corrections: [LiveTranscriptCorrection] {
        turns.compactMap { turn in
            let id = rowID(turn)
            // A group correction already covers this turn's interval.
            if absorbed[id] != nil { return nil }
            let name = confirmedNames[turn.speaker == "Speaker unclear" ? id : turn.speaker]
            guard correctedText[id] != nil || name != nil else { return nil }
            return LiveTranscriptCorrection(id: id, sourceSpeaker: turn.speaker, start: turn.start,
                                            end: correctedEnd[id] ?? turn.end,
                                            text: correctedText[id], speakerName: name)
        }
    }

    /// The machine turns shown as one block, first one first.
    private func groupTurns(rowID: String) -> [MeetingTurn] {
        let ids = rows.first { $0.id == rowID }?.turnIDs ?? [rowID]
        let byID = Dictionary(turns.map { (self.rowID($0), $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func edit(rowID: String, text: String, speakerName: String) {
        let group = groupTurns(rowID: rowID)
        guard let first = group.first, let row = rows.first(where: { $0.id == rowID }) else { return }
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !MeetingSource.genericSpeaker(name) {
            for turn in group {
                confirmedNames[turn.speaker == "Speaker unclear" ? self.rowID(turn) : turn.speaker] = name
            }
        }
        // Clear any earlier correction of this group before re-deriving it.
        for (turnID, groupID) in absorbed where groupID == rowID { absorbed.removeValue(forKey: turnID) }
        if text != row.text {
            correctedText[rowID] = text
            correctedEnd[rowID] = group.map(\.end).max() ?? first.end
            for turn in group.dropFirst() { absorbed[self.rowID(turn)] = rowID }
            onTextCorrected(text)
        } else {
            correctedText.removeValue(forKey: rowID)
            correctedEnd.removeValue(forKey: rowID)
        }
        rebuildRows()
        onEditsChanged(corrections)
        editingRowID = nil
    }

    /// The clearest stretch of one voice in a block: the longest turn, if it
    /// is long enough to fingerprint.
    private func voiceSample(rowID: String) -> MeetingTurn? {
        groupTurns(rowID: rowID)
            .filter { $0.speaker != MeetingController.ownerLabel && $0.speaker != "Speaker unclear" && $0.end - $0.start >= 2 }
            .max { $0.end - $0.start < $1.end - $1.start }
    }

    func canRememberVoice(rowID: String) -> Bool { voiceSample(rowID: rowID) != nil }

    func rememberVoice(rowID: String, name: String) {
        guard let reader, let turn = voiceSample(rowID: rowID) else { return }
        learningTask?.cancel()
        let generation = self.generation
        voiceLearningMessage = "Remembering voice…"
        learningTask = Task { [weak self] in
            do {
                try await reader.rememberVoice(name: name, start: turn.start, end: turn.end)
                try Task.checkCancellation()
                guard self?.generation == generation else { return }
                self?.voiceLearningMessage = "Voice remembered on this Mac"
            } catch {
                guard self?.generation == generation else { return }
                self?.voiceLearningMessage = "Couldn’t remember this voice. Try another clear passage."
            }
        }
    }

    private struct RenderState: Sendable {
        let turns: [MeetingTurn]
        let candidates: SpeakerCandidates
        let callParticipants: [String]
        let ownerName: String
        let confirmedNames: [String: String]
        let correctedText: [String: String]
        let absorbed: [String: String]
    }

    private func rebuildRows() {
        rowTask?.cancel()
        rowTask = nil
        rowRevision = UUID()
        let snapshot = RenderState(turns: turns, candidates: candidates, callParticipants: callParticipants,
                                   ownerName: ownerName, confirmedNames: confirmedNames,
                                   correctedText: correctedText, absorbed: absorbed)
        // Keep small edits immediate. Full meeting histories run off the UI
        // thread; an obsolete refresh can never replace newer edits or a stop.
        if turns.count <= 100, candidates.names.count + callParticipants.count <= 32,
           turns.reduce(0, { $0 + $1.text.utf8.count }) <= 16_000 {
            rows = Self.buildRows(snapshot)
            return
        }
        let revision = rowRevision
        let worker = Task.detached(priority: .userInitiated) { Self.buildRows(snapshot) }
        rowTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.rowRevision == revision else { return }
            self.rows = result
            self.rowTask = nil
        }
    }

    nonisolated private static func buildRows(_ input: RenderState) -> [Row] {
        let turns = input.turns, candidates = input.candidates, callParticipants = input.callParticipants
        let ownerName = input.ownerName, confirmedNames = input.confirmedNames
        let correctedText = input.correctedText, absorbed = input.absorbed
        guard !Task.isCancelled else { return [] }
        let named = MeetingController.nameSpeakers(in: turns, candidates: candidates)
        var suggestions = MeetingSpeakerHints.suggestions(in: turns, names: candidates.names + callParticipants)
        let others = callParticipants.filter { !Self.sameName($0, ownerName) }
        let remoteVoices = Set(turns.map(\.speaker).filter { $0.hasPrefix("Speaker ") && $0 != "Speaker unclear" })
        if others.count == 1, remoteVoices.count == 1, let voice = remoteVoices.first, suggestions[voice] == nil {
            suggestions[voice] = others[0]
        }
        let ids = turns.map(identifier)
        var membersByGroup: [String: [String]] = [:]
        for id in ids {
            if let group = absorbed[id] { membersByGroup[group, default: []].append(id) }
        }
        var built: [Row] = []
        var pending: Row?
        var fragments: [String] = []
        var members: [String] = []
        func flush() {
            guard let row = pending else { return }
            built.append(Row(id: row.id, speaker: row.speaker, timestamp: row.timestamp,
                             text: fragments.joined(separator: " "), suggestedName: row.suggestedName,
                             turnIDs: members, callParticipants: row.callParticipants))
        }
        for (index, pair) in zip(turns, named).enumerated() {
            if Task.isCancelled { return [] }
            let (raw, named) = pair, id = ids[index]
            if absorbed[id] != nil { continue }
            let confirmed = confirmedNames[raw.speaker == "Speaker unclear" ? id : raw.speaker]
            let speaker = confirmed ?? (raw.speaker == "Speaker unclear" ? raw.speaker : named.speaker == MeetingController.ownerLabel
                ? (ownerName.isEmpty ? "You" : "\(ownerName) (you)") : named.speaker)
            let suggested = confirmed == nil && speaker.hasPrefix("Speaker ") ? suggestions[raw.speaker] : nil
            let corrected = correctedText[id]
            if corrected == nil, let last = pending, last.speaker == speaker, speaker != "Speaker unclear",
               correctedText[last.id] == nil {
                // Accumulate fragments/IDs in place; copying the whole block
                // for every turn made long uninterrupted speech quadratic.
                if fragments.count == 1 {
                    fragments[0] = fragments[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    if fragments[0].isEmpty { fragments.removeAll(keepingCapacity: true) }
                }
                let text = named.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { fragments.append(text) }
                pending?.suggestedName = last.suggestedName ?? suggested
                members.append(id)
                continue
            }
            flush()
            pending = Row(id: id, speaker: speaker, timestamp: MeetingSource.stamp(named.start),
                          text: "", suggestedName: suggested,
                          callParticipants: speaker == MeetingController.ownerLabel || speaker.hasSuffix("(you)") ? [] : others)
            fragments = [corrected ?? named.text]
            members = [id] + (membersByGroup[id] ?? [])
        }
        flush()
        return built
    }

    nonisolated static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(whereSeparator: \.isWhitespace), y = b.lowercased().split(whereSeparator: \.isWhitespace)
        guard let xf = x.first, let yf = y.first else { return false }
        return x == y || (xf == yf && (x.count == 1 || y.count == 1))
    }
}
