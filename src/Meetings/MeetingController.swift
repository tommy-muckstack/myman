import AppKit
import AVFoundation
import ScreenCaptureKit
import EventKit
import GRDB
import SwiftUI
import QuartzCore

struct Meeting: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting"
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var micAudioPath: String?
    var systemAudioPath: String?
    var transcript: String
    var summary: String = ""
    /// JSON array of slide-screenshot paths captured during the meeting.
    var slides: String = ""
    var kind: String = MeetingKind.meeting.rawValue
    var ownerName: String = ""
    var participantsJSON: String = "[]"
    var originalTranscript: String = ""
    var analysisJSON: String = ""
    var liveCorrectionsJSON: String = "[]"

    var liveCorrections: [LiveTranscriptCorrection] {
        (try? JSONDecoder().decode([LiveTranscriptCorrection].self, from: Data(liveCorrectionsJSON.utf8))) ?? []
    }

    var captureKind: MeetingKind { MeetingKind(rawValue: kind) ?? .meeting }
    var participants: [MeetingParticipant] {
        (try? JSONDecoder().decode([MeetingParticipant].self, from: Data(participantsJSON.utf8))) ?? []
    }
    var resolvedOwner: String {
        let full = ownerName.isEmpty ? NSFullUserName() : ownerName
        return full.split(separator: " ").first.map(String.init) ?? "Owner"
    }

    var slidePaths: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(slides.utf8))) ?? []
    }
}

// Meeting recording v1: system audio (CoreAudio process tap) + mic, each to
// its own 16kHz WAV, with a floating recording pill. On stop, both tracks
/// One utterance: who said it, and the window it occupies. Turns carry their
/// END as well as their start so overlapping speech can be ordered, and so
/// fragments of one sentence can be recognised by the gap between them.
struct MeetingTurn: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    var recognizedWords: [MeetingRecognizedWord]? = nil
    var originalText: String? = nil
}

/// Who the far side might be — and how much that is worth.
///
/// Attendee lists are evidence. A name inferred from an event title is a
/// guess, and the two must never be treated alike: a recording that spans two
/// calendar slots picks up the wrong title, and a guess stamped onto every
/// remote turn misfiles the whole conversation against a real person.
struct SpeakerCandidates: Sendable, Equatable {
    var names: [String] = []
    /// True for an attendee list or an explicit Owner <> Remote title.
    var fromAttendees = false

    static let none = SpeakerCandidates()
    var isEmpty: Bool { names.isEmpty }
}

// transcribe on-device (Qwen3, Parakeet fallback) into a "You" / "Speaker 2" transcript stored
// in the shared database. Music auto-pauses while recording.

@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(start: Date)
    }

    @Published var phase: Phase = .idle
    /// True from the first permission callback until `phase` is set, which is
    /// no longer the same instant: bringing the mic up awaits CoreAudio.
    private(set) var isStarting = false
    private var startupTask: Task<Void, Never>?
    private let requestMicrophoneAccess: () async -> Bool
    private(set) var isShuttingDown = false
    var canStartRecording: Bool { !isShuttingDown && phase == .idle && !isStarting }
    /// Meetings whose audio is still being transcribed in the background.
    /// Transcription never occupies the recorder: stopping a meeting returns
    /// the phase to .idle immediately, so a back-to-back call can start while
    /// the previous transcript is still being built. Jobs run one at a time —
    /// the ASR models aren't safe to share across concurrent transcriptions.
    @Published private(set) var transcribingTitles: [String] = []
    private var transcriptionChain: Task<Void, Never>?
    private var transcriptionTasks: [String: Task<Void, Never>] = [:]
    private var transcriptionRevision = 0
    private let transcriptionWorker = MeetingTranscriptionWorker()
    private let transcriptionRunner: ((TranscriptionJob) async -> Void)?
    private let transcriptionProcessor: ((TranscriptionJob) async throws -> MeetingTranscriptResult)?
    private var isRecoveringTranscripts = false
    var isTranscribing: Bool { !transcribingTitles.isEmpty || isRecoveringTranscripts }
    /// Quill-style detection capture: recording is already running, but
    /// NOTHING persists unless the user clicks Save. Discard (or the safety
    /// timeout) deletes the audio with no database row, no transcription.
    @Published var isProvisional = false
    @Published var levels: [Float] = []
    @Published private(set) var recordingTitle = ""
    @Published private(set) var titleEditorVisible = false
    @Published var stopConfirmationVisible = false
    let liveTranscript = LiveMeetingTranscript()
    let recordingNote: MeetingRecordingNote
    @Published private(set) var liveEditSaveFailed = false
    private var titleSaveTask: Task<Void, Never>?
    private var titleNeedsSaving = false
    private let titleDatabase: DatabaseQueue?
    private var provisionalTimeout: Timer?
    private var lastAudibleAt = Date()
    /// Remote/system audio is a stronger end-of-call clue than our own mic:
    /// the user may keep speaking or typing after everyone else leaves.
    private var lastRemoteAudibleAt = Date()
    private var slideTimer: Timer?
    private let slideCapture = MeetingSlideCapture()
    private var systemLevel: Float = 0
    private var levelTimer: Timer?

    private let tap = SystemAudioTap()
    private var micSession: UUID?
    /// Seconds the microphone file starts after the system-audio file. The
    /// tap is running before the mic engine finishes starting, so mic
    /// timestamps sit this far behind the remote track unless corrected.
    private var micStartLag = 0.0
    private var micDrainTimer: Timer?
    private var systemWriter: WavWriter?
    private var micWriter: WavWriter?
    var activeCaptureMeetingID: String? {
        guard case .recording = phase, !isProvisional else { return nil }
        return meeting?.id
    }
    private var meeting: Meeting?
    private var panel: FloatingPanel?
    private var pausedMusic = false
    /// Set by the calendar nudge before starting — the event's real name.
    var pendingTitle: String?
    /// Attendees captured at recording start; counted only if it's KEPT.
    private var pendingAttendees: [(name: String, email: String?)] = []
    /// First names of this session's attendees — candidates for turning
    /// "Speaker 2" into "Amy" from conversational context.
    private var sessionAttendeeNames = SpeakerCandidates.none
    /// End-of-meeting watch: once a call app has been seen on the mic,
    /// its sustained absence means everyone hung up.
    private var endWatchTimer: Timer?
    private var callAppSeenOnMic = false
    private var callAppMissingPolls = 0
    private var endNudgeShown = false
    /// Call bundles actually attributed on the mic during THIS recording —
    /// the only apps whose quitting is evidence the call ended.
    private var seenCallBundles: Set<String> = []
    /// Second end signal, for the calls mic attribution can't see (Bluetooth
    /// mics, some browser stacks): a meeting-titled window was on screen and
    /// then wasn't.
    private var meetingWindowSeen = false
    private var meetingWindowMissingPolls = 0
    private var appTerminationObserver: NSObjectProtocol?
    /// Meeting link for the provisional card's Join & Start button.
    @Published var provisionalJoinURL: URL?

    /// Supplying an existing take allows previews and title-persistence tests
    /// without starting microphones, process taps, or transcription models.
    init(recording: Meeting? = nil, titleDatabase: DatabaseQueue? = nil,
         transcriptionRunner: ((TranscriptionJob) async -> Void)? = nil,
         transcriptionProcessor: ((TranscriptionJob) async throws -> MeetingTranscriptResult)? = nil,
         requestMicrophoneAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.transcriptionRunner = transcriptionRunner
        self.transcriptionProcessor = transcriptionProcessor
        self.titleDatabase = titleDatabase
        recordingNote = MeetingRecordingNote(database: titleDatabase)
        meeting = recording
        recordingTitle = recording?.title ?? ""
        if let recording {
            phase = .recording(start: recording.startedAt)
            recordingNote.reset(meetingID: recording.id)
        }
        liveTranscript.onEditsChanged = { [weak self] edits in self?.saveLiveEdits(edits) }
        liveTranscript.onTextCorrected = { text in DictationCleanup.learn(from: text) }
        liveTranscript.onProgress = { [weak self] turns in
            guard let self, var record = self.meeting, !self.isProvisional else { return }
            let cleaned = MeetingChannelDedupe.clean(mic: turns.filter { $0.speaker == Self.ownerLabel },
                                                     system: turns.filter { $0.speaker != Self.ownerLabel })
            let sorted = (cleaned.mic + cleaned.system).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            record.kind = cleaned.kind.rawValue
            record.transcript = MeetingSource.render(Self.nameSpeakers(in: sorted, candidates: self.sessionAttendeeNames))
            MeetingNotesService.shared.updateDraft(record)
        }
    }

    private func saveLiveEdits(_ edits: [LiveTranscriptCorrection]) {
        guard var meeting, !isProvisional,
              let data = try? JSONEncoder().encode(edits) else { return }
        meeting.liveCorrectionsJSON = String(decoding: data, as: UTF8.self)
        self.meeting = meeting
        do {
            try (titleDatabase ?? Database.shared).write { db in
                try db.execute(sql: "UPDATE meeting SET liveCorrectionsJSON = ? WHERE id = ?",
                               arguments: [meeting.liveCorrectionsJSON, meeting.id])
                guard db.changesCount > 0 else { throw CocoaError(.fileNoSuchFile) }
            }
            liveEditSaveFailed = false
        } catch { liveEditSaveFailed = true }
    }

    func updateRecordingTitle(_ text: String) {
        guard case .recording = phase, var current = meeting, text != current.title else { return }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty draft is allowed in the field while replacing a title, but
        // must never erase the saved name if recording stops mid-edit.
        guard !title.isEmpty, title != current.title else { return }
        current.title = title
        meeting = current
        recordingTitle = title
        titleNeedsSaving = !isProvisional
        titleSaveTask?.cancel()
        guard !isProvisional else { return }
        titleSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flushRecordingTitle()
        }
    }

    func flushRecordingTitle() {
        titleSaveTask?.cancel(); titleSaveTask = nil
        guard titleNeedsSaving, !isProvisional, let current = meeting else { return }
        do {
            try (titleDatabase ?? Database.shared).write { db in
                // Only change the name; never overwrite concurrent notes or
                // recreate a meeting deleted elsewhere.
                try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [current.title, current.id])
            }
            titleNeedsSaving = false
        } catch {
            Toast.show("Couldn’t save the meeting name. Finish editing to retry.", systemImage: "exclamationmark.triangle")
        }
    }

    func setTitleEditorVisible(_ visible: Bool) {
        guard visible || (!stopConfirmationVisible && liveTranscript.editingRowID == nil) else { return }
        let visible = visible && !isProvisional && phase != .idle
        guard titleEditorVisible != visible else { return }
        titleEditorVisible = visible
        applyPillFrame(animated: true)
    }

    func finishTitleEditing() {
        flushRecordingTitle()
        guard recordingNote.flush() else { return }
        panel?.makeFirstResponder(nil)
        panel?.resignKey()
        setTitleEditorVisible(false)
    }

    func requestStopRecording() {
        guard case .recording = phase, !isProvisional else { return }
        stopConfirmationVisible = true
    }

    func confirmStopRecording() {
        guard case .recording = phase, !isProvisional else { return }
        stopConfirmationVisible = false
        stop()
    }

    func startLiveTranscript() {
        guard case .recording = phase, !isProvisional, let meeting,
              micWriter != nil || systemWriter != nil else { return }
        let reader = LiveMeetingTranscriptReader(
            micURL: micWriter?.url, systemURL: systemWriter?.url,
            singleRemote: sessionAttendeeNames.fromAttendees && Set(sessionAttendeeNames.names).count == 1,
            startedAt: meeting.startedAt, micLag: micStartLag,
            checkpointURL: MeetingTranscriptCheckpoint.url(micPath: micWriter?.url.path, systemPath: systemWriter?.url.path), contextMeeting: meeting)
        MeetingTranscriptionStatus.shared.recordingIDs.insert(meeting.id)
        liveTranscript.start(reader: reader, ownerName: meeting.resolvedOwner, candidates: sessionAttendeeNames)
    }

    static var recordingsFolder: URL {
        if let root = VerificationPaths.root { return root.appendingPathComponent("MeetingAudio") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyMan/meetings", isDirectory: true)
    }

    /// Raw meeting audio is ~230MB/hour and only needed until it's
    /// transcribed. The transcript (DB + brain) is the durable artifact;
    /// WAVs older than 30 days get swept at launch.
    static func cleanupOldRecordings(olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let folder = recordingsFolder
        Task.detached(priority: .background) {
            // Never age out the only source of a failed or unfinished job.
            guard let records = try? await Database.shared.read({ try Meeting.fetchAll($0) }) else { return }
            let protected = Set(records.filter { record in
                if record.transcript.isEmpty { return true }
                do { return try MeetingProcessingRecord.load(for: record).map { $0.phase != .complete } ?? false }
                catch { return true }
            }.flatMap { [$0.micAudioPath, $0.systemAudioPath].compactMap { $0 } })
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            for file in files where file.pathExtension == "wav" {
                guard !protected.contains(file.path) else { continue }
                let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func toggle() {
        switch phase {
        case .idle: start()
        // The meeting hotkey during a provisional take means "yes, record
        // this" — convert and keep rolling, don't stop.
        case .recording: isProvisional ? keepProvisional() : stop()
        }
    }

    func startForAgent(title: String?) async throws {
        guard canStartRecording else { throw AgentError("BUSY", "A meeting is recording, starting, or My Man is quitting.") }
        isStarting = true
        let allowed = await requestMicrophoneAccess()
        isStarting = false
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        guard allowed else { throw AgentError("PERMISSION_REQUIRED", "Allow Microphone access in macOS settings.") }
        guard SystemAudioTap.hasPermission() else { throw AgentError("PERMISSION_REQUIRED", "Allow System Audio Recording access in My Man before starting a meeting through an agent.") }
        // A human may start recording while the permission prompt is open.
        // Never claim that unrelated take as the agent's new session.
        guard canStartRecording else { throw AgentError("BUSY", "Meeting startup was cancelled or another meeting started.") }
        pendingTitle = title
        await startAuthorized(pauseMusic: false)
        guard activeCaptureMeetingID != nil else { throw AgentError("CAPTURE_FAILED", "Meeting audio could not start. Inspect permissions and the selected microphone.") }
    }

    /// Detection fires this: capture starts NOW so no words are lost, but
    /// only Save makes it real.
    func startProvisional(title: String? = nil, joinURL: URL? = nil) {
        guard canStartRecording else { return }
        if let title { pendingTitle = title }
        provisionalJoinURL = joinURL
        start(provisional: true)
    }

    /// Evidence that this take contains an actual call, not just an armed
    /// mic: a call app attributed on the mic, a meeting-titled window on
    /// screen, or the far side audible on the system track. The auto-record
    /// commit waits for this — a calendar nudge for an event the user never
    /// joined must evaporate, not become a phantom meeting.
    var hasCallEvidence: Bool {
        guard case .recording(let start) = phase else { return false }
        return callAppSeenOnMic || meetingWindowSeen || lastRemoteAudibleAt > start
    }

    func keepProvisional() {
        guard !isShuttingDown, isProvisional, let meeting else { return }
        isProvisional = false
        defer { applyPillFrame() }
        provisionalJoinURL = nil
        provisionalTimeout?.invalidate()
        provisionalTimeout = nil
        try? Database.shared.write { try meeting.insert($0) }
        Analytics.track("meeting_started", ["has_system_audio": tap.isRunning,
                                            "from_detection": true])
        recordingNote.reset(meetingID: meeting.id)
        startLiveTranscript()
    }

    func discardProvisional() {
        guard isProvisional else { return }
        discardRecording()
    }

    /// Cancel an in-flight take without transcribing or retaining any audio.
    /// Auto-recorded detections are committed immediately, so this must work
    /// for both provisional and already-saved meeting rows.
    func discardRecording(quitting: Bool = false) {
        guard !isShuttingDown || quitting else { return }
        guard case .recording = phase else { return }
        guard recordingNote.discard() || quitting else {
            Toast.show("Couldn’t discard the note. Please try again.", systemImage: "exclamationmark.triangle")
            return
        }
        stopConfirmationVisible = false
        let liveCompletion = liveTranscript.stop()
        if let record = meeting {
            MeetingTranscriptionStatus.shared.recordingIDs.remove(record.id)
            MeetingNotesService.shared.cancel(meetingID: record.id)
            Task {
                await liveCompletion?.value
                let folder = Self.recordingsFolder
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix(record.id + "-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        titleSaveTask?.cancel(); titleSaveTask = nil
        titleNeedsSaving = false; titleEditorVisible = false
        let wasProvisional = isProvisional
        let discardedMeeting = meeting
        isProvisional = false
        provisionalJoinURL = nil
        stopEndWatch()
        provisionalTimeout?.invalidate()
        provisionalTimeout = nil
        slideTimer?.invalidate()
        slideTimer = nil
        for path in slideCapture.finish() { try? FileManager.default.removeItem(atPath: path) }
        levelTimer?.invalidate()
        levelTimer = nil
        micDrainTimer?.invalidate()
        micDrainTimer = nil
        tap.stop()
        if let micSession { _ = AudioCapture.shared.end(micSession) }
        micSession = nil
        _ = systemWriter?.close()
        _ = micWriter?.close()
        if let url = systemWriter?.url { try? FileManager.default.removeItem(at: url) }
        if let url = micWriter?.url { try? FileManager.default.removeItem(at: url) }
        systemWriter = nil
        micWriter = nil
        meeting = nil
        pendingAttendees = []
        if !wasProvisional, let discardedMeeting {
            try? Database.shared.write { _ = try Meeting.deleteOne($0, key: discardedMeeting.id) }
            Brain.deleteMeeting(id: discardedMeeting.id, startedAt: discardedMeeting.startedAt)
        }
        if !quitting { resumeMusicIfPaused() }
        phase = .idle
        dismissPill()
        Analytics.track("meeting_discarded", ["provisional": wasProvisional])
        Toast.show("Recording cancelled — nothing was saved", systemImage: "xmark.circle")
    }

    private func start(provisional: Bool = false) {
        guard canStartRecording else { return }
        isStarting = true
        startupTask = Task { @MainActor in
            let granted = await requestMicrophoneAccess()
            isStarting = false
            guard granted, !isShuttingDown, !Task.isCancelled else { return }
            await startAuthorized(provisional: provisional)
        }
    }

    private func startAuthorized(provisional: Bool = false, pauseMusic: Bool = true) async {
        // Permission callbacks can arrive more than once when a calendar
        // nudge and a manual click race. Only the first one may create a row —
        // and since starting the mic suspends, `phase` alone can't hold that
        // line: the second caller would sail past before the first sets it.
        guard canStartRecording else { return }
        guard SystemAudioTap.hasPermission() || promptForSystemAudio() else { return }
        guard canStartRecording else { return }
        isStarting = true
        defer { isStarting = false }

        let id = UUID().uuidString
        let folder = Self.recordingsFolder
        systemWriter = WavWriter(url: folder.appendingPathComponent("\(id)-others.wav"))
        micWriter = WavWriter(url: folder.appendingPathComponent("\(id)-you.wav"))

        let writer = systemWriter
        tap.onSamples = { [weak self] samples in
            writer?.append(samples)
            // Cheap RMS of this chunk feeds the pill waveform.
            guard !samples.isEmpty else { return }
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            Task { @MainActor in
                guard let self else { return }
                self.systemLevel = max(self.systemLevel, rms)
                if rms > 0.012 { self.lastRemoteAudibleAt = Date() }
            }
        }
        do {
            let tapStarted = Date()
            try tap.start()
            let session = try await AudioCapture.shared.begin(.raw)
            guard !isShuttingDown else {
                _ = AudioCapture.shared.end(session)
                return
            }
            micSession = session
            micStartLag = min(10, max(0, Date().timeIntervalSince(tapStarted)))
        } catch {
            NSLog("My Man [Meeting] start failed: \(error)")
            guard !isShuttingDown else { return }
            tap.stop()
            _ = systemWriter?.close()
            _ = micWriter?.close()
            systemWriter = nil
            micWriter = nil
            return
        }

        // Drain the dictation-style mic buffer into the WAV periodically so
        // hour-long meetings never hold audio in memory.
        micDrainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainMic(final: false) }
        }

        if pauseMusic, VerificationPaths.root == nil { pauseMusicIfPlaying() }

        let started = Date()
        let title = pendingTitle
            ?? Self.currentCalendarEventTitle()
            ?? "Meeting \(started.formatted(date: .abbreviated, time: .shortened))"
        pendingTitle = nil
        meeting = Meeting(
            id: id,
            title: title,
            startedAt: started, endedAt: nil,
            micAudioPath: micWriter?.url.path,
            systemAudioPath: systemWriter?.url.path,
            transcript: "", summary: ""
        )
        recordingTitle = title
        titleEditorVisible = false
        titleNeedsSaving = false
        var identities = People.currentEventParticipants(matchingTitle: title)
        pendingAttendees = identities.filter { !$0.isOwner }.map { ($0.name, $0.email) }
        if !identities.contains(where: \.isOwner) { identities.insert(MeetingParticipant(name: NSFullUserName(), isOwner: true), at: 0) }
        meeting?.ownerName = identities.first(where: \.isOwner)?.name ?? NSFullUserName()
        meeting?.participantsJSON = (try? JSONEncoder().encode(identities)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        sessionAttendeeNames = Self.speakerCandidates(
            eventTitle: title, attendees: pendingAttendees.map(\.name))
        if let meeting { MeetingInterviewContext.capture(for: meeting) }
        if provisional {
            isProvisional = true
            // Unclaimed for 90 minutes = not wanted. Quietly clean up.
            provisionalTimeout = Timer.scheduledTimer(withTimeInterval: 90 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.discardProvisional() }
            }
        } else {
            // This small commit must not suspend between constructing the
            // recording and publishing its phase; quit could otherwise end
            // it, then a late continuation would resurrect the busy state.
            persistStartingMeeting()
            Analytics.track("meeting_started", ["has_system_audio": tap.isRunning])
        }
        phase = .recording(start: started)
        liveEditSaveFailed = false
        recordingNote.reset(meetingID: provisional ? nil : id)
        stopConfirmationVisible = false
        if !provisional { startLiveTranscript() }
        applyPillFrame()
        levels = Array(repeating: 0, count: 64)
        lastAudibleAt = started
        lastRemoteAudibleAt = started
        endNudgeShown = false
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.phase else { return }
                // The pill is the recording indicator — as long as we record,
                // it exists. Whatever closed it, bring it back.
                if self.panel == nil { self.showPill() }
                // Whichever side is louder — you or them — drives the bars.
                let level = max(self.micSession.map { AudioCapture.shared.currentLevel(for: $0) } ?? 0, self.systemLevel)
                self.systemLevel *= 0.7 // decay between tap callbacks
                var next = self.levels
                next.removeFirst()
                next.append(level)
                self.levels = next

                // Silence watchdog. Provisional: 30s of nothing (no voices,
                // no system audio) means it wasn't a meeting — vanish quietly.
                // Committed: real meetings have quiet stretches, so give it
                // 5 minutes before concluding everyone hung up.
                if level > 0.012 {
                    self.lastAudibleAt = Date()
                } else {
                    let silent = Date().timeIntervalSince(self.lastAudibleAt)
                    if self.isProvisional, silent > 30 {
                        Analytics.track("meeting_silence_timeout", ["provisional": true])
                        self.discardProvisional()
                    } else if !self.isProvisional, silent > 300 {
                        Analytics.track("meeting_silence_timeout", ["provisional": false])
                        Toast.show("Meeting ended after 5 minutes of silence")
                        self.stop()
                    }
                }
            }
        }
        showPill()
        startSlideCapture(meetingID: id)
        startEndWatch()
    }

    // MARK: Meeting-end detection — the inverse of meeting-start

    private func persistStartingMeeting() {
        try? (titleDatabase ?? Database.shared).write { [meeting] in
            if let meeting { try meeting.insert($0) }
        }
    }

    private func startEndWatch() {
        callAppSeenOnMic = false
        callAppMissingPolls = 0
        endNudgeShown = false
        seenCallBundles = []
        meetingWindowSeen = false
        meetingWindowMissingPolls = 0
        endWatchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollForMeetingEnd() }
        }
        // Quitting the call app is the one unambiguous, instant hang-up
        // signal — Granola stops here too. Only apps this recording actually
        // saw on the mic count; an idle Zoom quitting during a Meet call
        // must not end the meeting.
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier else { return }
            Task { @MainActor in await self?.callAppTerminated(bundle) }
        }
    }

    private func stopEndWatch() {
        endWatchTimer?.invalidate()
        endWatchTimer = nil
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
    }

    /// A call app the mic had attributed just quit. If no other call app is
    /// still holding the mic, everyone hung up — end now, not 30s from now.
    private func callAppTerminated(_ bundle: String) async {
        guard case .recording = phase, seenCallBundles.contains(bundle) else { return }
        let owners = await AudioCapture.processesUsingMicOffMain()
            .filter { $0 != Bundle.main.bundleIdentifier }
        guard case .recording = phase else { return }
        guard !owners.contains(where: { MeetingDetector.isCallBundle($0) && $0 != bundle })
        else { return }
        endBecauseCallEnded(reason: "app_quit")
    }

    /// The single hang-up exit: a committed meeting stops and transcribes, a
    /// provisional one that was never opted into vanishes with its audio.
    private func endBecauseCallEnded(reason: String) {
        stopEndWatch()
        if isProvisional {
            Analytics.track("meeting_auto_discarded", ["reason": reason])
            discardProvisional()
        } else {
            Analytics.track("meeting_auto_stopped", ["reason": reason])
            Toast.show("Meeting ended — transcribing", systemImage: "checkmark.circle")
            stop()
        }
    }

    private func pollForMeetingEnd() async {
        guard case .recording = phase else { return }
        // Window-title signal, tracked every tick regardless of what the mic
        // says — it must be armed before it can fire.
        let windowPresent = await MeetingDetector.meetingWindowPresent()
        guard case .recording = phase else { return }
        if windowPresent {
            meetingWindowSeen = true
            meetingWindowMissingPolls = 0
        } else if meetingWindowSeen {
            meetingWindowMissingPolls += 1
        }

        let owners = await AudioCapture.processesUsingMicOffMain()
            .filter { $0 != Bundle.main.bundleIdentifier }
        guard case .recording = phase else { return }
        let callOwners = owners.filter { MeetingDetector.isCallBundle($0) }
        if !callOwners.isEmpty {
            callAppSeenOnMic = true
            callAppMissingPolls = 0
            seenCallBundles.formUnion(callOwners)
            return
        }
        // When macOS did attribute the call app, three missing polls is a
        // high-confidence hang-up and can end the recording automatically.
        if callAppSeenOnMic {
            callAppMissingPolls += 1
            guard callAppMissingPolls >= 3 else { return } // ~30s after hang-up
            endBecauseCallEnded(reason: "mic_attribution")
            return
        }

        // Attribution never worked this call (Bluetooth mic, some browser
        // stacks) but a meeting-titled window WAS here and is now gone. The
        // window alone can lie — a Meet tab in the background loses its title
        // spot to the foreground tab — so require the far side to have gone
        // quiet too before calling it a hang-up.
        if meetingWindowSeen, meetingWindowMissingPolls >= 2,
           Date().timeIntervalSince(lastRemoteAudibleAt) > 20 {
            endBecauseCallEnded(reason: "window_closed")
            return
        }

        // Attribution is unavailable for many browser calls and Bluetooth
        // devices. In that case do not silently stop a meeting on quiet; give
        // the user an accurate, reversible end-of-call nudge instead.
        let quietFor = Date().timeIntervalSince(lastAudibleAt)
        let remoteQuietFor = Date().timeIntervalSince(lastRemoteAudibleAt)
        guard !endNudgeShown, !isProvisional,
              quietFor > 45, remoteQuietFor > 45 else { return }
        endNudgeShown = true
        Analytics.track("meeting_end_nudged", ["source": "quiet_call"])
        Toast.show("Looks like you just ended a call", systemImage: "phone.down.fill",
                   actionLabel: "Stop & save", action: { [weak self] in self?.stop() },
                   secondaryLabel: "Keep recording", secondaryAction: { [weak self] in
                       self?.endNudgeShown = false
                   }, duration: 14)
    }

    // MARK: Slides — periodic captures of the call window, deduped

    private func startSlideCapture(meetingID: String) {
        slideCapture.start(meetingID: meetingID, folder: Self.recordingsFolder)
        participantScanner = CallParticipantScanner()
        slideTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureSlide(meetingID: meetingID) }
        }
    }

    private var participantScanner = CallParticipantScanner()

    private func captureSlide(meetingID: String) async {
        guard case .recording = phase, meeting?.id == meetingID else { return }
        await slideCapture.capture(meetingID: meetingID, image: {
            await self.captureCallWindow()
        }, inspect: { image in
            await self.scanCallParticipants(image, meetingID: meetingID)
        })
    }

    /// Names on the call window are the best evidence of who is talking.
    /// They become one-tap choices and hints; a name never lands on a line
    /// without a person confirming it.
    private func scanCallParticipants(_ image: CGImage, meetingID: String) async {
        let known = sessionAttendeeNames.names
        let owner = meeting?.resolvedOwner ?? NSFullUserName()
        let names = await participantScanner.ingest(image, owner: owner, knownNames: known)
        guard case .recording = phase, meeting?.id == meetingID,
              !names.isEmpty, names != liveTranscript.callParticipants else { return }
        var merged = sessionAttendeeNames
        for name in names where !merged.names.contains(where: { LiveMeetingTranscript.sameName($0, name) }) {
            merged.names.append(name)
        }
        if merged != sessionAttendeeNames {
            sessionAttendeeNames = merged
            Analytics.track("meeting_call_names_seen", ["count": names.count])
        }
        liveTranscript.updateCallParticipants(names, candidates: merged)
    }

    private func captureCallWindow() async -> CGImage? {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let callBundles = Set(MeetingDetector.strongApps.keys)
            .union(MeetingDetector.browserBundles)
        let candidates = content.windows.filter { window in
            guard let bundle = window.owningApplication?.bundleIdentifier else { return false }
            return callBundles.contains(bundle) && window.isOnScreen
                && window.frame.width > 400 && window.frame.height > 300
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return nil }

        let config = SCStreamConfiguration()
        // Cap by SCALE, never by independent width/height — mismatched caps
        // make SCK letterbox the content into a corner (the wonky slides).
        let scaleFactor = min(2, 2560 / max(window.frame.width, 1),
                              1600 / max(window.frame.height, 1))
        config.width = max(2, Int(window.frame.width * scaleFactor))
        config.height = max(2, Int(window.frame.height * scaleFactor))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config)
    }

    private func drainMic(final: Bool) {
        // Session drain never touches the engine — no churn, no dropped audio,
        // and nothing for a concurrent call app to fight with.
        guard let micSession else { return }
        let samples = final
            ? AudioCapture.shared.end(micSession)
            : AudioCapture.shared.drain(micSession)
        micWriter?.append(samples)
        if final { self.micSession = nil }
    }

    /// Seal the recorder before any asynchronous shutdown work can yield.
    func prepareForQuit() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        startupTask?.cancel(); startupTask = nil
        isStarting = false
        stopEndWatch()
        provisionalTimeout?.invalidate(); provisionalTimeout = nil
        slideTimer?.invalidate(); slideTimer = nil
        levelTimer?.invalidate(); levelTimer = nil
        micDrainTimer?.invalidate(); micDrainTimer = nil
        if liveEditSaveFailed { saveLiveEdits(liveTranscript.corrections) }
        liveTranscript.stop()
        // Seal valid WAV headers before waiting on HAL teardown. A stuck
        // driver must not leave the last recording unreadable at the deadline.
        drainMic(final: true)
        _ = systemWriter?.close()
        _ = micWriter?.close()
        flushRecordingTitle()
        _ = recordingNote.flush()
        for (id, task) in transcriptionTasks {
            task.cancel()
            MeetingTranscriptionStatus.shared.finish(meetingID: id)
        }
        transcriptionTasks.removeAll()
        transcriptionChain = nil
        transcribingTitles = []
    }

    func finishQuitting() async {
        prepareForQuit()
        // CoreAudio IPC may stall. Never put that wait on AppKit's thread,
        // which also owns the bounded quit deadline.
        await tap.stopForQuit()
        if isProvisional { discardRecording(quitting: true) }
        else { stop(quitting: true) }
    }

    private func stop(quitting: Bool = false) {
        guard !isShuttingDown || quitting else { return }
        if liveEditSaveFailed {
            saveLiveEdits(quitting ? (meeting?.liveCorrections ?? []) : liveTranscript.corrections)
        }
        guard !liveEditSaveFailed || quitting else {
            Toast.show("Couldn’t save transcript edits. Recording continues so you can retry.", systemImage: "exclamationmark.triangle")
            return
        }
        guard recordingNote.flush() || quitting else {
            Toast.show("Couldn’t save your note. Recording continues so you can retry.", systemImage: "exclamationmark.triangle")
            return
        }
        stopConfirmationVisible = false
        let liveCompletion = liveTranscript.stop()
        if let id = meeting?.id { MeetingTranscriptionStatus.shared.recordingIDs.remove(id) }
        flushRecordingTitle()
        titleEditorVisible = false
        stopEndWatch()
        levelTimer?.invalidate()
        levelTimer = nil
        slideTimer?.invalidate()
        slideTimer = nil
        let slidePaths = slideCapture.finish()
        micDrainTimer?.invalidate()
        micDrainTimer = nil
        tap.stop()
        drainMic(final: true)

        let systemURL = systemWriter?.close()
        let micURL = micWriter?.close()
        systemWriter = nil
        micWriter = nil

        if !quitting { resumeMusicIfPaused() }

        guard var finished = meeting else {
            phase = .idle
            dismissPill()
            return
        }
        finished.endedAt = Date()
        if let data = try? JSONEncoder().encode(slidePaths) {
            finished.slides = String(decoding: data, as: UTF8.self)
        }
        Analytics.track("meeting_stopped",
                        ["duration_s": Int(Date().timeIntervalSince(finished.startedAt)),
                         "slide_count": finished.slidePaths.count])
        // Everything the transcription needs travels with the job — the
        // controller's per-take state resets NOW so the next meeting can
        // start while this one transcribes.
        let job = TranscriptionJob(
            record: finished,
            micPath: micURL?.path, systemPath: systemURL?.path,
            candidates: sessionAttendeeNames, attendees: pendingAttendees, micLag: micStartLag, liveCompletion: liveCompletion)
        // Save the end time and slides BEFORE decoding; these survive a crash.
        do {
            try (titleDatabase ?? Database.shared).write { db in
                try db.execute(sql: "UPDATE meeting SET endedAt = ?, slides = ? WHERE id = ?",
                               arguments: [finished.endedAt, finished.slides, finished.id])
            }
        } catch {
            NSLog("My Man [Meeting] could not save recording metadata: %@", error.localizedDescription)
        }
        meeting = nil
        pendingAttendees = []
        sessionAttendeeNames = .none
        phase = .idle
        if quitting {
            // The WAVs and endedAt are durable. Leave a zero-attempt job for
            // normal startup recovery, including any live partial transcript.
            if micURL != nil || systemURL != nil {
                try? MeetingProcessingRecord(micLag: micStartLag).save(for: finished)
            }
        } else { enqueueTranscription(job) }
        dismissPill()
    }

    // MARK: Background transcription queue

    struct TranscriptionJob: Sendable {
        var record: Meeting
        let micPath: String?
        let systemPath: String?
        let candidates: SpeakerCandidates
        let attendees: [(name: String, email: String?)]
        var micLag: Double = 0
        var liveCompletion: Task<Void, Never>? = nil
        var regenerating = false
        var expectedTranscript = ""
    }

    func enqueueTranscription(_ job: TranscriptionJob) {
        guard !isShuttingDown, !MeetingTranscriptionStatus.shared.isPending(job.record.id) else { return }
        transcriptionRevision += 1
        let revision = transcriptionRevision
        transcribingTitles.append(job.record.title)
        MeetingTranscriptionStatus.shared.begin(meetingID: job.record.id, title: job.record.title)
        Analytics.track("meeting_transcription_queued",
                        ["queue_depth": transcribingTitles.count])
        let previous = transcriptionChain
        let queueTimer = MeetingProcessingTimer()
        transcriptionChain = Task(priority: .utility) { @MainActor in
            defer { self.transcriptionTasks.removeValue(forKey: job.record.id) }
            await previous?.value
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            await job.liveCompletion?.value
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            queueTimer.finish("transcription_queue")
            if let runner = self.transcriptionRunner { await runner(job) }
            else { await self.runTranscription(job) }
            if let index = self.transcribingTitles.firstIndex(of: job.record.title) {
                self.transcribingTitles.remove(at: index)
            }
            MeetingTranscriptionStatus.shared.finish(meetingID: job.record.id)
            // Completion never touches the next meeting's recording widget.
            if self.transcriptionRevision == revision { self.transcriptionChain = nil }
        }
        transcriptionTasks[job.record.id] = transcriptionChain
    }

    private func runTranscription(_ job: TranscriptionJob) async {
        var record = job.record
        let totalTimer = MeetingProcessingTimer()
        defer { totalTimer.finish("transcription_total") }
        var state: MeetingProcessingRecord
        do {
            state = try MeetingProcessingRecord.load(for: record) ?? MeetingProcessingRecord(
                regenerating: job.regenerating, expectedTranscript: job.expectedTranscript, micLag: job.micLag)
        } catch {
            MeetingTranscriptionStatus.shared.fail(meetingID: record.id, message: "Couldn’t read recovery progress. Your audio is saved. Choose Regenerate transcript to start again.")
            return
        }
        while state.attempts < 3 {
            guard !Task.isCancelled, !isShuttingDown else { return }
            state.attempts += 1
            state.phase = .running
            do {
                try state.save(for: record)
                if state.attempts > 1 {
                    MeetingTranscriptionStatus.shared.stage("Retrying transcription · attempt \(state.attempts) of 3…", meetingID: record.id)
                    try await Task.sleep(for: .seconds(2 * (state.attempts - 1)))
                }
                let processed: MeetingTranscriptResult
                if let transcriptionProcessor { processed = try await transcriptionProcessor(job) }
                else { processed = try await transcriptionWorker.process(job) }
                try Task.checkCancellation()
                guard !processed.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "MyMan.Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "No readable speech was returned. Your audio is saved."])
                }
                record.transcript = processed.transcript
                record.originalTranscript = processed.originalTranscript
                record.kind = processed.kind.rawValue
                guard let saved = try await (titleDatabase ?? Database.shared).write({ [record] in
                    try Self.saveTranscription(record, in: $0, replacing: job.expectedTranscript)
                }) else { return }
                state.phase = .complete
                state.error = ""
                try state.save(for: saved)
                if titleDatabase != nil { return }
                People.noteAttendees(job.attendees)
                Brain.syncMeeting(id: saved.id, title: saved.title, startedAt: saved.startedAt,
                                  endedAt: saved.endedAt, summary: saved.summary, transcript: saved.transcript)
                MeetingNotesService.shared.prepare(meetingID: saved.id)
                notifyDone(saved)
                return
            } catch is CancellationError {
                // A normal quit is not an ASR failure and must not consume
                // one of the recording's three automatic recovery attempts.
                state.attempts = max(0, state.attempts - 1)
                try? state.save(for: record)
                return
            }
            catch {
                state.error = error.localizedDescription
                NSLog("My Man [Meeting] transcription attempt %d failed: %@", state.attempts, error.localizedDescription)
            }
        }
        state.phase = .failed
        try? state.save(for: record)
        MeetingTranscriptionStatus.shared.fail(meetingID: record.id, message: "Transcription needs another try. Your recording is saved.")
    }

    func retryTranscription(meetingID: String, regenerate: Bool) {
        guard meeting?.id != meetingID, !MeetingTranscriptionStatus.shared.isPending(meetingID),
              var record = try? Database.shared.read({ try Meeting.fetchOne($0, key: meetingID) }) else { return }
        do {
            let previous = try? MeetingProcessingRecord.load(for: record)
            let regenerating = regenerate || previous?.regenerating == true
            if regenerate {
                // Keep the complete previous document available for undo/recovery.
                if let checkpoint = MeetingTranscriptCheckpoint.url(micPath: record.micAudioPath, systemPath: record.systemAudioPath, regenerating: true) {
                    let backup = checkpoint.deletingLastPathComponent().appendingPathComponent("\(record.id)-before-regeneration-\(UUID().uuidString).json")
                    try JSONEncoder().encode(record).write(to: backup, options: .atomic)
                    if FileManager.default.fileExists(atPath: checkpoint.path) { try FileManager.default.removeItem(at: checkpoint) }
                }
            }
            if record.endedAt == nil {
                let duration = max(record.micAudioPath.map(Self.wavDuration(atPath:)) ?? 0,
                                   record.systemAudioPath.map(Self.wavDuration(atPath:)) ?? 0)
                record.endedAt = record.startedAt.addingTimeInterval(duration)
            }
            let state = MeetingProcessingRecord(regenerating: regenerating, expectedTranscript: record.transcript,
                                                micLag: previous?.micLag ?? 0)
            try state.save(for: record)
            enqueueTranscription(TranscriptionJob(record: record, micPath: record.micAudioPath,
                systemPath: record.systemAudioPath, candidates: Self.speakerCandidates(eventTitle: record.title, attendees: record.participants.filter { !$0.isOwner }.map(\.name)), attendees: [], micLag: state.micLag,
                regenerating: regenerating, expectedTranscript: record.transcript))
        } catch {
            MeetingTranscriptionStatus.shared.fail(meetingID: meetingID, message: "Couldn’t prepare recovery. Your recording and existing transcript are unchanged.")
        }
    }

    /// The user may already be editing notes while audio is processing.
    /// Update only the unfinished transcript and retain the latest document.
    nonisolated static func saveTranscription(_ record: Meeting, in db: GRDB.Database, replacing expected: String = "") throws -> Meeting? {
        try db.execute(sql: """
            UPDATE meeting SET transcript = ?, endedAt = COALESCE(endedAt, ?),
                kind = ?, originalTranscript = ?, ownerName = ?, participantsJSON = ?
            WHERE id = ? AND transcript = ? AND liveCorrectionsJSON = ?
            """, arguments: [record.transcript, record.endedAt, record.kind, record.originalTranscript,
                              record.ownerName, record.participantsJSON, record.id, expected, record.liveCorrectionsJSON])
        return try Meeting.fetchOne(db, key: record.id)
    }

    /// An aborted or duplicate take, not a meeting: under a minute AND under
    /// 100 words. Both conditions on purpose — a long recording whose ASR
    /// failed also has few words, and deleting IT would destroy a real
    /// meeting, while a short take someone actually talked through is dense
    /// enough to clear the word floor and stay.
    nonisolated static func isNoiseFragment(_ record: Meeting) -> Bool {
        let duration = (record.endedAt ?? record.startedAt)
            .timeIntervalSince(record.startedAt)
        guard duration < 60 else { return false }
        return record.transcript.split(whereSeparator: \.isWhitespace).count < 100
    }

    /// Remove every trace of a recording that turned out to be nothing: the
    /// row, both audio tracks, and any captured slides.
    private static func deleteArtifacts(of record: Meeting) async {
        try? await Database.shared.write { [record] in
            _ = try Meeting.deleteOne($0, key: record.id)
        }
        for path in [record.micAudioPath, record.systemAudioPath].compactMap({ $0 })
            + record.slidePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// The calendar event this recording most plausibly IS — its name beats
    /// a timestamp as the meeting title.
    private static func currentCalendarEventTitle() -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-1200),
            end: now.addingTimeInterval(600), calendars: nil)
        let candidates = store.events(matching: predicate).map { event in
            EventTitleCandidate(
                title: event.title ?? "",
                start: event.startDate ?? .distantPast,
                isAllDay: event.isAllDay,
                hasLink: CalendarWatcher.meetingURL(in: event) != nil,
                declined: CalendarWatcher.isDeclined(event))
        }
        return bestEventTitle(candidates, now: now)
    }

    struct EventTitleCandidate {
        let title: String
        let start: Date
        let isAllDay: Bool
        let hasLink: Bool
        let declined: Bool
    }

    /// Which event should name a recording starting NOW. The old rule ("any
    /// event overlapping ±10 min, latest start wins") let a 3-hour focus
    /// block that began hours ago name a Zoom call, and let declined and
    /// linkless events outrank the actual meeting. Now: the event must have
    /// STARTED within the last 20 minutes (or start within 10), declined
    /// invites never name anything, and an event carrying a meeting link
    /// beats any bare calendar block.
    nonisolated static func bestEventTitle(_ events: [EventTitleCandidate], now: Date) -> String? {
        let plausible = events.filter {
            !$0.title.isEmpty && !$0.isAllDay && !$0.declined
                && $0.start > now.addingTimeInterval(-1200)
                && $0.start <= now.addingTimeInterval(600)
        }
        let linked = plausible.filter(\.hasLink)
        return (linked.isEmpty ? plausible : linked)
            .sorted { $0.start > $1.start }
            .first?.title
    }

    /// A usable first name from one attendee entry. A calendar attendee is
    /// often a bare email address, and `"alex.rivera@example.com"` has no
    /// space — taking its "first word" put a raw address in the transcript as
    /// a speaker label. Derive a name from the local part instead, or nothing.
    nonisolated static func firstName(fromAttendee raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains("@") else {
            return trimmed.split(separator: " ").first.map(String.init)
        }
        let local = trimmed.split(separator: "@").first.map(String.init) ?? ""
        let token = local.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        guard let token, token.count >= 2 else { return nil }
        return token.prefix(1).uppercased() + token.dropFirst().lowercased()
    }

    /// Calendar attendees are the best source of real speaker names. For a
    /// personal one-on-one titled like "Alex Morgan Weekly", calendars often
    /// omit attendees entirely; use the single non-owner name in that exact
    /// title pattern as equally bounded evidence.
    nonisolated static func speakerCandidates(eventTitle: String?, attendees: [String]) -> SpeakerCandidates {
        if attendees.isEmpty, let eventTitle,
           let pair = MeetingConversation.explicitPair(title: eventTitle, owner: NSFullUserName()) {
            return SpeakerCandidates(names: [pair.remote], fromAttendees: true)
        }
        var names = attendees.compactMap(firstName(fromAttendee:))
        let uniqueAttendees = Array(Set(names)).sorted()
        guard uniqueAttendees.isEmpty, let eventTitle else {
            return SpeakerCandidates(names: uniqueAttendees, fromAttendees: true)
        }

        let titleWords = eventTitle.components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let ownerWords = NSFullUserName().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 2 }
        guard let ownerFirst = ownerWords.first,
              titleWords.contains(where: { $0.caseInsensitiveCompare(ownerFirst) == .orderedSame })
        else { return SpeakerCandidates(names: uniqueAttendees, fromAttendees: true) }

        let generic = Set(["weekly", "sync", "meeting", "call", "catch", "up", "with", "and"])
        let candidate = titleWords.filter { word in
            !ownerWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
                && !generic.contains(word.lowercased())
                && word.count >= 3
        }
        if candidate.count == 1 { names.append(candidate[0]) }
        // A name pulled out of an event title is a GUESS, not an attendee
        // list. Titles drift when a recording spans two calendar slots, and
        // stamping a guess on every remote turn is how a 1:1 was filed
        // against someone who was never in the room.
        return SpeakerCandidates(names: Array(Set(names)).sorted(), fromAttendees: false)
    }

    /// Stream the WAV from disk in 60s slices — an hour of audio is ~230MB
    /// decoded, and holding two full meetings' worth in RAM is exactly how
    /// transcription dies on long recordings. Peak memory here is one chunk.
    nonisolated private static func transcribeWavFile(atPath path: String, service: TranscriptionService) async -> String {
        await transcribeWavChunks(atPath: path, service: service).map(\.text).joined(separator: " ")
    }

    /// Max seconds per ASR slice for the ACTIVE engine. Qwen3 is built for
    /// ~30s utterances — longer input silently truncates its tail (the same
    /// defect dictation hit; see VoiceController.chunkSeconds). Parakeet
    /// handles a minute comfortably. Slices stay 5s under each ceiling so a
    /// pause-seeking cut has room to move the boundary.
    nonisolated private static func maxSliceSeconds(_ service: TranscriptionService) -> Double {
        service.kind == .qwen3 ? 25 : 55
    }

    /// Whole-chunk fallback size for the active engine, same ceilings.
    nonisolated private static func chunkSeconds(_ service: TranscriptionService) -> Int {
        service.kind == .qwen3 ? 30 : 60
    }

    /// Where to end a slice that must be cut before the speech does: the
    /// start of the quietest 0.1s frame in the tail window, so the cut lands
    /// in a breath or pause instead of mid-word. A hard cut at exactly 55s
    /// splits whatever word straddles it, and the recognizer garbles BOTH
    /// halves — one boundary error per minute of continuous speech.
    /// Returns `samples.count` when the tail is too short to search.
    nonisolated static func quietestCutSample(in samples: [Float], from lowerBound: Int) -> Int {
        let frame = 1600 // 0.1s at 16kHz
        guard lowerBound >= 0, samples.count - lowerBound >= frame else { return samples.count }
        var best = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = lowerBound
        while index + frame <= samples.count {
            var sum: Float = 0
            for sample in samples[index ..< index + frame] { sum += sample * sample }
            if sum < bestEnergy {
                bestEnergy = sum
                best = index
            }
            index += frame
        }
        return best
    }

    /// 60s chunk transcriptions with their start offsets — the coarse
    /// fallback shape when turn detection fails on a track.
    nonisolated private static func transcribeWavChunks(atPath path: String, service: TranscriptionService)
        async -> [(start: Double, end: Double, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let headerBytes: UInt64 = 44
        // Short chunks bound how far a line can sit from its real moment;
        // a 60s chunk stamped at its start put answers before questions.
        let seconds = min(20, chunkSeconds(service))
        let chunkBytes = 16000 * seconds * 2 // one chunk of mono Int16
        var offset = headerBytes
        var parts: [(start: Double, end: Double, text: String)] = []
        while true {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
            var samples = data.withUnsafeBytes { raw -> [Float] in
                let int16 = raw.bindMemory(to: Int16.self)
                return int16.map { Float($0) / Float(Int16.max) }
            }
            let isFinal = data.count < chunkBytes
            var consumedBytes = data.count
            if !isFinal {
                // More audio follows, so this cut lands mid-speech unless we
                // move it: end the chunk at the quietest instant of its last
                // 10 seconds instead of at an arbitrary sample.
                let cut = Self.quietestCutSample(in: samples, from: (seconds - 10) * 16000)
                if cut < samples.count {
                    samples.removeLast(samples.count - cut)
                    consumedBytes = cut * 2
                }
            }
            let chunkStart = Double(offset - headerBytes) / 32000
            let text = await service.transcribe(samples)
            if !text.isEmpty {
                // Stamp where the speech is, not where the chunk begins.
                let bounds = audibleBounds(samples) ?? (0, Double(samples.count) / 16000)
                parts.append((chunkStart + bounds.start, chunkStart + bounds.end, text))
            }
            if isFinal { break }
            offset += UInt64(consumedBytes)
        }
        return parts
    }

    /// First and last audible instants of a clip (0.1s frames against the
    /// clip's own peak), so a chunk's words are dated to its speech.
    nonisolated static func audibleBounds(_ samples: [Float]) -> (start: Double, end: Double)? {
        let frame = 1600
        guard samples.count >= frame else { return nil }
        var energies: [Float] = []
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for value in samples[index..<(index + frame)] { sum += value * value }
            energies.append(sqrt(sum / Float(frame)))
            index += frame
        }
        guard let peak = energies.max(), peak > 0.0015 else { return nil }
        let threshold = max(0.002, peak * 0.2)
        guard let first = energies.firstIndex(where: { $0 >= threshold }),
              let last = energies.lastIndex(where: { $0 >= threshold }) else { return nil }
        return (Double(first) * 0.1, Double(last + 1) * 0.1)
    }

    /// Seconds of audio in a 16k mono Int16 WAV.
    nonisolated private static func wavDuration(atPath path: String) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        return size > 44 ? Double(size - 44) / 32000 : 0
    }

    /// Turn detection with a safety net: when the energy gate finds little
    /// or nothing in a track that whole-file transcription CAN read, fall
    /// back to coarse 60s turns rather than dropping that side of the
    /// conversation. Real failure mode: a quiet mic track losing every one
    /// of the user's turns while the remote track came through fine.
    nonisolated private static func turnsWithFallback(atPath path: String, speaker: String, service: TranscriptionService)
        async -> [MeetingTurn] {
        let timer = MeetingProcessingTimer()
        defer { timer.finish(speaker == Self.ownerLabel ? "mic_transcription" : "remote_transcription") }
        let turns = await transcribeTurns(atPath: path, speaker: speaker, service: service)
        let duration = wavDuration(atPath: path)
        let covered = turns.reduce(0.0) { $0 + Double($1.text.count) }
        // Under ~2 chars of text per second of audio across a multi-minute
        // track means the gate missed most speech (normal speech is ~12/s;
        // one quiet side of a call still produces well above 2).
        let sparse = duration > 120 && covered / duration < 2
        guard turns.isEmpty || sparse else { return turns }
        // Before giving up on turn timing, listen harder: a quiet track
        // usually still has turns, just under the normal gate.
        let quiet = await transcribeTurns(atPath: path, speaker: speaker,
                                          segments: speechSegments(atPath: path, sensitive: true), service: service)
        let quietChars = quiet.reduce(0) { $0 + $1.text.count }
        if quietChars > Int(covered) * 2, quietChars > 40, Double(quietChars) / max(duration, 1) >= 2 {
            Analytics.track("meeting_track_sensitive_gate", ["speaker": speaker, "chars": quietChars])
            return quiet
        }
        let chunks = await transcribeWavChunks(atPath: path, service: service)
        let chunkChars = chunks.reduce(0) { $0 + $1.text.count }
        guard chunkChars > Int(covered) * 2, chunkChars > 40 else { return turns }
        Analytics.track("meeting_track_fallback",
                        ["speaker": speaker, "turn_chars": Int(covered),
                         "chunk_chars": chunkChars, "duration_s": Int(duration)])
        return chunks.map {
            MeetingTurn(start: $0.start, end: $0.end, speaker: speaker, text: $0.text)
        }
    }

    /// Speech turns in a 16k WAV via energy gating, streamed — frame RMS at
    /// 0.1s, threshold adaptive over the track's noise floor, 1s of silence
    /// closes a turn. Memory cost: one float per frame.
    nonisolated private static func speechSegments(atPath path: String, sensitive: Bool = false) -> [(start: Double, end: Double)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 44)
        let frameSamples = 1600 // 0.1s
        var energies: [Float] = []
        while let data = try? handle.read(upToCount: frameSamples * 2), !data.isEmpty {
            let energy = data.withUnsafeBytes { raw -> Float in
                let int16 = raw.bindMemory(to: Int16.self)
                var sum: Float = 0
                for value in int16 {
                    let f = Float(value) / Float(Int16.max)
                    sum += f * f
                }
                return int16.count > 0 ? sqrt(sum / Float(int16.count)) : 0
            }
            energies.append(energy)
            if data.count < frameSamples * 2 { break }
        }
        guard !energies.isEmpty else { return [] }
        let sorted = energies.sorted()
        let noiseFloor = sorted[energies.count / 2]
        let peak = sorted[Int(Double(energies.count - 1) * 0.99)] // robust peak
        // Scale the gate to the track, never to an absolute level: a quiet
        // mic (raw capture, no gain) can put ALL speech under a fixed 0.004
        // floor — that silently drops one entire side of a meeting (found by
        // diffing a real 44-min call against two other recorders). The gate
        // must sit between this track's noise floor and its own peak.
        guard peak > 0.0015 else { return [] } // genuinely silent track
        let threshold = sensitive
            ? max(0.0015, min(max(0.0025, noiseFloor * 1.5), peak * 0.12))
            : max(0.002, min(max(0.004, noiseFloor * 2.5), peak * 0.25))
        let closeAfterFrames = sensitive ? 15 : 10
        var segments: [(Double, Double)] = []
        var current: (first: Int, last: Int)?
        var silentFrames = 0
        for (i, energy) in energies.enumerated() {
            if energy >= threshold {
                silentFrames = 0
                if current == nil { current = (i, i) } else { current?.last = i }
            } else if current != nil {
                silentFrames += 1
                if silentFrames >= closeAfterFrames {
                    if let c = current {
                        segments.append((Double(c.first) * 0.1, Double(c.last + 1) * 0.1))
                    }
                    current = nil
                    silentFrames = 0
                }
            }
        }
        if let c = current {
            segments.append((Double(c.first) * 0.1, Double(c.last + 1) * 0.1))
        }
        return mergeSegments(segments.filter { $0.1 - $0.0 >= 0.4 })
    }

    /// Glue segments separated by a short pause back into one utterance.
    ///
    /// The energy gate closes a turn after 1s of silence, but a person
    /// pausing mid-sentence — "You'd have a PM… a designer… four to six
    /// engineers" — trips it repeatedly. That produced one transcript line
    /// per fragment AND, worse, handed the recognizer 1-2 second clips with
    /// no surrounding context, which is how "four to six engineers" came back
    /// as the single word "Six". Feeding the whole phrase as one slice fixes
    /// both the shredding and the accuracy.
    nonisolated static func mergeSegments(_ segments: [(Double, Double)])
        -> [(start: Double, end: Double)] {
        let maxGap = 1.5
        var merged: [(start: Double, end: Double)] = []
        for segment in segments {
            if let last = merged.last, segment.0 - last.end <= maxGap {
                merged[merged.count - 1].end = segment.1
            } else {
                merged.append((segment.0, segment.1))
            }
        }
        return merged
    }

    /// Transcribe each speech turn of one track, tagged with speaker + start.
    nonisolated private static func transcribeTurns(atPath path: String, speaker: String,
                                        segments: [(start: Double, end: Double)]? = nil, service: TranscriptionService)
        async -> [MeetingTurn] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var turns: [MeetingTurn] = []
        for segment in segments ?? speechSegments(atPath: path) {
            var offset = segment.start
            while offset < segment.end {
                let maxSlice = maxSliceSeconds(service)
                let hardEnd = min(offset + maxSlice, segment.end) // ASR-safe length
                let byteStart = 44 + UInt64(offset * 16000) * 2
                let byteCount = Int((hardEnd - offset) * 16000) * 2
                try? handle.seek(toOffset: byteStart)
                guard let data = try? handle.read(upToCount: byteCount), !data.isEmpty else { break }
                var samples = data.withUnsafeBytes { raw -> [Float] in
                    raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
                }
                var sliceEnd = hardEnd
                if hardEnd < segment.end {
                    // The segment continues past this slice, so a cut here is
                    // mid-speech by definition. Land it on the quietest
                    // instant of the slice's last 10 seconds — a breath, not
                    // the middle of a word — and resume the next slice there.
                    let cut = Self.quietestCutSample(in: samples, from: Int((maxSlice - 10) * 16000))
                    if cut < samples.count {
                        samples.removeLast(samples.count - cut)
                        sliceEnd = offset + Double(cut) / 16000
                    }
                }
                let text = await service.transcribe(samples)
                if !text.isEmpty {
                    turns.append(MeetingTurn(start: offset, end: sliceEnd, speaker: speaker, text: text))
                }
                offset = sliceEnd
            }
        }
        return turns
    }

    /// The interleaved conversation — both tracks' turns merged by time:
    ///   **You** [3:12]: …
    ///   **Speaker 2** [3:19]: …
    /// Falls back to the old two-block format when turn detection finds
    /// nothing but whole-file transcription would (very quiet audio).
    nonisolated static func buildTranscript(micPath: String?, systemPath: String?,
                                candidates: SpeakerCandidates = .none,
                                overlapDiarization: Bool = true) async -> String {
        await buildTranscriptResult(micPath: micPath, systemPath: systemPath,
                                    candidates: candidates, overlapDiarization: overlapDiarization).transcript
    }

    nonisolated static func buildTranscriptResult(micPath: String?, systemPath: String?,
                                      candidates: SpeakerCandidates = .none,
                                      overlapDiarization: Bool = true,
                                      corrections: [LiveTranscriptCorrection] = [],
                                      wallDuration: Double? = nil,
                                      micLag: Double = 0,
                                      title: String = "",
                                      service: TranscriptionService = .shared,
                                      pretranscribedTurns: [MeetingTurn]? = nil) async -> MeetingTranscriptResult {
        // A track with more audio than the meeting lasted was resampled at
        // the wrong rate after a device swap. Put it back on the clock, per
        // track, before anything is ordered, matched, or stamped.
        let micScale = LiveMeetingTranscriptReader.wallClockScale(
            fileSeconds: micPath.map(wavDuration(atPath:)) ?? 0, wallSeconds: wallDuration)
        let systemScale = LiveMeetingTranscriptReader.wallClockScale(
            fileSeconds: systemPath.map(wavDuration(atPath:)) ?? 0, wallSeconds: wallDuration)
        func onClock(_ turns: [MeetingTurn], _ scale: Double) -> [MeetingTurn] {
            guard scale < 1 else { return turns }
            return turns.map { MeetingTurn(start: $0.start * scale, end: $0.end * scale, speaker: $0.speaker, text: $0.text) }
        }
        if micScale < 1 || systemScale < 1 {
            Analytics.track("meeting_transcript_time_drift",
                            ["mic_scale": micScale, "system_scale": systemScale, "wall_s": Int(wallDuration ?? 0)])
        }
        // The diarizer owns separate models/state. Start it while the ASR
        // processes the tracks, then join before assigning any speaker labels.
        // ASR slices themselves remain serial on the supplied speech engine.
        let knownRemote = candidates.fromAttendees && candidates.names.count == 1
        async let diarized = diarizeRemote(path: systemPath, skip: pretranscribedTurns != nil || knownRemote || !overlapDiarization)
        async let echo = AudioEchoEvidence.analyze(micPath: micPath, systemPath: systemPath)
        var turns: [MeetingTurn] = pretranscribedTurns ?? []
        if pretranscribedTurns == nil, let micPath, FileManager.default.fileExists(atPath: micPath) {
            // The mic file starts once its engine is up; the tap was already
            // rolling. Put the owner's words back on the shared timeline.
            turns += onClock(await turnsWithFallback(atPath: micPath, speaker: Self.ownerLabel, service: service), micScale)
                .map { MeetingTurn(start: $0.start + micLag, end: $0.end + micLag, speaker: $0.speaker, text: $0.text) }
        }
        if pretranscribedTurns == nil, let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            var sysTurns: [MeetingTurn]
            if candidates.fromAttendees, candidates.names.count == 1,
               let only = candidates.names.first {
                // A 1:1 with a KNOWN attendee: exactly one person can be on
                // the remote track. Diarization can only hurt here — echo and
                // noise split one voice into "Speaker 1"/"Speaker 2" — so
                // skip it and label every remote turn with that attendee.
                // Only ever on attendee-list evidence: a name guessed from an
                // event title is not enough to put on someone's words.
                sysTurns = await turnsWithFallback(atPath: systemPath, speaker: only, service: service)
                sysTurns = sysTurns.map {
                    MeetingTurn(start: $0.start, end: $0.end, speaker: only, text: $0.text)
                }
            } else {
                let segments = overlapDiarization ? await diarized
                    : await diarizeRemote(path: systemPath, skip: false)
                let voices = collapsePhantomSpeakers(in: segments)
                if Set(voices.map(\.speaker)).count >= 2 {
                    sysTurns = []
                    for interval in Self.speakerIntervals(speech: speechForDiarized(path: systemPath, voices: voices), voices: voices) {
                        sysTurns += await transcribeTurns(atPath: systemPath, speaker: interval.speaker,
                                                          segments: [(interval.start, interval.end)], service: service)
                    }
                    if sysTurns.isEmpty { sysTurns = await turnsWithFallback(atPath: systemPath, speaker: Self.remoteLabel, service: service) }
                } else {
                    let known = voices.first?.speaker
                    let speaker = known?.hasPrefix("known:") == true ? String(known!.dropFirst(6)) : Self.remoteLabel
                    sysTurns = await turnsWithFallback(atPath: systemPath, speaker: speaker, service: service)
                }
            }
            turns += onClock(sysTurns, systemScale)
        }
        if !turns.isEmpty {
            // Strictly chronological, and a turn that starts with another
            // resolves by which one finishes first.
            turns.sort { ($0.start, $0.end) < ($1.start, $1.end) }
            let original = MeetingSource.render(turns.map { turn in
                var original = turn; original.text = turn.originalText ?? turn.text; return original
            })
            // Restore known spellings AFTER the raw record is kept: the
            // original transcript stays exactly what the recognizer heard.
            let terms = vocabularyTerms(candidates: candidates, title: title)
            turns = turns.map { turn in
                var fixed = turn
                fixed.text = MeetingVocabulary.correct(turn.text, terms: terms).text
                return fixed
            }
            let cleaned = MeetingChannelDedupe.clean(mic: turns.filter { $0.speaker == Self.ownerLabel },
                                                    system: turns.filter { $0.speaker != Self.ownerLabel }, echo: await echo)
            turns = (cleaned.mic + cleaned.system).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            // Apply human edits before automatic naming so channel identity
            // is still available for matching the microphone and remote audio.
            if !corrections.isEmpty {
                turns = await MeetingLiveEdits.apply(corrections, to: turns) { edge in
                    let isMic = edge.speaker == Self.ownerLabel
                    let path = isMic ? micPath : systemPath
                    guard let path else { return [] }
                    // Edges are clock time; the WAV is addressed in file time.
                    let scale = isMic ? micScale : systemScale
                    return onClock(await transcribeTurns(atPath: path, speaker: edge.speaker,
                                                         segments: [(edge.start / scale, edge.end / scale)], service: service), scale)
                }
            }
            if cleaned.kind == .listening {
                var labels: [String: String] = [:]
                turns = turns.map { turn in
                    var copy = turn
                    if turn.speaker == "Speaker unclear" || !MeetingSource.genericSpeaker(turn.speaker) { return copy }
                    if labels[turn.speaker] == nil { labels[turn.speaker] = "Speaker \(labels.count + 1)" }
                    copy.speaker = labels[turn.speaker]!
                    return copy
                }
            }
            if cleaned.kind == .meeting { turns = nameSpeakers(in: turns, candidates: candidates) }
            if pretranscribedTurns == nil { turns = mergeConsecutive(turns) }
            return MeetingTranscriptResult(transcript: MeetingSource.render(turns), originalTranscript: original, kind: cleaned.kind)
        }
        if pretranscribedTurns != nil {
            let edited = await MeetingLiveEdits.apply(corrections, to: []) { _ in [] }
            return MeetingTranscriptResult(transcript: MeetingSource.render(edited), originalTranscript: "", kind: .meeting)
        }
        var sections: [String] = []
        if let micPath, FileManager.default.fileExists(atPath: micPath) {
            let text = await transcribeWavFile(atPath: micPath, service: service)
            if !text.isEmpty {
                sections.append("\(Self.ownerLabel):\n\(text)")
            }
        }
        if let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            let text = await transcribeWavFile(atPath: systemPath, service: service)
            if !text.isEmpty {
                sections.append("\(Self.remoteLabel):\n\(text)")
            }
        }
        let fallback = sections.joined(separator: "\n\n")
        if !corrections.isEmpty, !corrections.compactMap(\.text).isEmpty {
            let edited = await MeetingLiveEdits.apply(corrections, to: []) { _ in [] }
            let rendered = MeetingSource.render(edited)
            return MeetingTranscriptResult(transcript: fallback.isEmpty ? rendered : fallback + "\n\nCorrections made during recording:\n\n" + rendered,
                                           originalTranscript: fallback, kind: .meeting)
        }
        return MeetingTranscriptResult(transcript: fallback, originalTranscript: fallback, kind: .meeting)
    }

    nonisolated private static func diarizeRemote(path: String?, skip: Bool)
        async -> [(speaker: String, start: Double, end: Double)] {
        guard !skip, let path, FileManager.default.fileExists(atPath: path) else { return [] }
        let timer = MeetingProcessingTimer()
        defer { timer.finish("speaker_identification") }
        return await Diarization.shared.speakerSegments(forWavAtPath: path)
    }

    /// The energy gate decides what gets recognized; the speaker model has
    /// its own voice activity detection. When the gate hears far less than
    /// the voices say was spoken (a quiet remote track), the voices are the
    /// better map of where speech is — dropping to whole-track chunks would
    /// lose both timing and speaker boundaries.
    nonisolated static func speechForDiarized(path: String, voices: [(speaker: String, start: Double, end: Double)])
        -> [(start: Double, end: Double)] {
        let gated = speechSegments(atPath: path)
        let gatedTotal = gated.reduce(0) { $0 + ($1.end - $1.start) }
        let voiced = mergeSegments(voices.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 })
        let voicedTotal = voiced.reduce(0) { $0 + ($1.end - $1.start) }
        guard voicedTotal > 30, gatedTotal < voicedTotal * 0.5 else { return gated }
        let quiet = speechSegments(atPath: path, sensitive: true)
        let quietTotal = quiet.reduce(0) { $0 + ($1.end - $1.start) }
        Analytics.track("meeting_remote_gate_sparse", ["gated_s": Int(gatedTotal), "voiced_s": Int(voicedTotal), "quiet_s": Int(quietTotal)])
        return quietTotal >= voicedTotal * 0.5 ? quiet : voiced
    }

    /// Split audio BEFORE recognition when the remote stream has multiple
    /// voices. A majority-overlap label on a long mixed turn attributes the
    /// host's question to the guest. Overlapping voices stay visibly uncertain.
    nonisolated static func speakerIntervals(speech: [(start: Double, end: Double)],
                                             voices: [(speaker: String, start: Double, end: Double)]) -> [MeetingTurn] {
        var names: [String: String] = [:]
        for voice in voices.sorted(by: { $0.start < $1.start }) where names[voice.speaker] == nil {
            names[voice.speaker] = voice.speaker.hasPrefix("known:") ? String(voice.speaker.dropFirst(6)) : "Speaker \(names.count + 2)"
        }
        var result: [MeetingTurn] = []
        for segment in speech {
            let active = voices.filter { $0.end > segment.start && $0.start < segment.end }
            let boundaries = Set([segment.start, segment.end] + active.flatMap { [max(segment.start, $0.start), min(segment.end, $0.end)] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let labels = Set(active.filter { $0.start < end && $0.end > start }.map(\.speaker))
                let speaker = labels.count == 1 ? names[labels.first!]! : "Speaker unclear"
                if let last = result.last, last.speaker == speaker, start - last.end < 0.05 {
                    result[result.count - 1].end = end
                } else { result.append(MeetingTurn(start: start, end: end, speaker: speaker, text: "")) }
            }
        }
        return result
    }

    /// Names available for vocabulary auditing. Meetings never apply fuzzy
    /// spelling restoration to this list; approved aliases are exact matches.
    nonisolated static func vocabularyTerms(candidates: SpeakerCandidates, title: String = "") -> [String] {
        var terms = DictationCleanup.vocabulary()
        func add(_ term: String) {
            guard term.count >= 3, !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
            terms.append(term)
        }
        candidates.names.forEach(add)
        // Proper nouns in the meeting's own name: a company or product the
        // recognizer has never heard of is usually written right there.
        MeetingVocabulary.properNouns(in: title).forEach(add)
        MeetingVocabulary.commonTerms.forEach(add)
        return terms
    }

    /// The user's own track. The far side, before identification.
    nonisolated static let ownerLabel = "You"
    /// Never "Them" or "Others": those read as a group, so a two-person call
    /// looked like three people once a real name was resolved alongside them.
    /// One positional format, used everywhere, or a real name.
    nonisolated static let remoteLabel = "Speaker 2"

    /// Fold a diarized voice that is almost certainly an artefact back into
    /// the speaker it was split from.
    ///
    /// On one remote stream, echo of the user's own voice and brief
    /// backchannel ("yeah", "mm-hmm") routinely come back as a second
    /// speaker id holding a few seconds of audio. Labeling that as its own
    /// participant invented a third person in a 1:1. A voice is real if it
    /// holds a meaningful share of the conversation.
    nonisolated static func collapsePhantomSpeakers(
        in segments: [(speaker: String, start: Double, end: Double)]
    ) -> [(speaker: String, start: Double, end: Double)] {
        var total: [String: Double] = [:]
        for segment in segments {
            total[segment.speaker, default: 0] += max(0, segment.end - segment.start)
        }
        guard let dominant = total.max(by: { $0.value < $1.value }) else { return segments }
        // Under a tenth of the leading voice, or under 8 seconds all told, is
        // backchannel and echo — not a participant. But that share test only
        // holds for the two-voice case it was written for: in a GROUP call a
        // quiet participant can easily sit under 10% of the loudest voice,
        // and folding them puts their words in someone else's mouth — the
        // worst failure a transcript can have. With three or more substantial
        // voices, only sub-8s blips fold; low-share voices stay their own
        // speaker, visibly separate rather than silently merged.
        let substantial = total.filter {
            $0.key == dominant.key
                || ($0.value >= 8 && $0.value >= dominant.value * 0.10)
        }
        let phantoms: Set<String>
        if substantial.count >= 3 {
            phantoms = Set(total.filter { $0.key != dominant.key && $0.value < 8 }.keys)
        } else {
            // Two voices on the remote stream: the second is only an artefact
            // when it is BOTH a small share and short. A colleague who asks a
            // few questions in a 20-minute interview holds under a tenth of
            // the lead voice yet is very much a person — folding them put the
            // interviewer's questions in the interviewee's mouth.
            phantoms = Set(total.filter { $0.key != dominant.key &&
                ($0.value < 8 || ($0.value < dominant.value * 0.05 && $0.value < 30)) }.keys)
        }
        guard !phantoms.isEmpty else { return segments }
        Analytics.track("meeting_phantom_speaker_collapsed", ["count": phantoms.count])
        return segments.map {
            phantoms.contains($0.speaker)
                ? (dominant.key, $0.start, $0.end) : $0
        }
    }

    /// Rename remote turns to "Speaker N" (first-appearance order) by max
    /// time-overlap with the diarizer's segments. One distinct voice — or no
    /// diarization at all — keeps the single remote label.
    nonisolated private static func label(
        turns: [MeetingTurn],
        with segments: [(speaker: String, start: Double, end: Double)]
    ) -> [MeetingTurn] {
        let distinct = Set(segments.map(\.speaker))
        guard distinct.count >= 2 else { return turns }
        var order: [String: Int] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) where order[segment.speaker] == nil {
            // The user is Speaker 1 by convention, so the far side starts at 2.
            order[segment.speaker] = order.count + 2
        }
        return turns.map { turn in
            var overlap: [String: Double] = [:]
            for segment in segments {
                let shared = min(turn.end, segment.end) - max(turn.start, segment.start)
                if shared > 0 { overlap[segment.speaker, default: 0] += shared }
            }
            guard let best = overlap.max(by: { $0.value < $1.value })?.key,
                  let n = order[best] else { return turn }
            return MeetingTurn(start: turn.start, end: turn.end,
                               speaker: "Speaker \(n)", text: turn.text)
        }
    }

    /// One utterance per thought, not one per pause. Consecutive turns from
    /// the same speaker close together are the same utterance broken up by
    /// the energy gate; joining them is what turns four stranded fragments
    /// back into a sentence.
    nonisolated static func mergeConsecutive(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        let maxGap = 1.5
        var merged: [MeetingTurn] = []
        for turn in turns {
            guard var last = merged.last, last.speaker == turn.speaker,
                  turn.start - last.end <= maxGap,
                  max(last.end, turn.end) - last.start <= 45,
                  last.text.count + turn.text.count + 1 <= 1200 else {
                merged.append(turn)
                continue
            }
            last.end = max(last.end, turn.end)
            last.text = joinUtterance(last.text, turn.text)
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// Join two halves of a broken-up utterance without inventing punctuation
    /// the speaker did not use, and without doubling what is already there.
    nonisolated private static func joinUtterance(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespaces)
        let right = rhs.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// Turn "Speaker N" into real names from conversational evidence:
    /// self-introductions ("it's Amy") vote strongly for the speaking turn;
    /// addressing someone ("Amy, what do you think?") votes for the NEXT
    /// different speaker. Candidates come from calendar attendees only —
    /// this can mislabel, never invent. One name per speaker, ≥2 votes.
    nonisolated static func nameSpeakers(
        in turns: [MeetingTurn],
        candidates: SpeakerCandidates
    ) -> [MeetingTurn] {
        let names = Array(Set(candidates.names.filter { $0.count >= 3 }))
        guard !names.isEmpty else { return turns }
        // A two-person call has a single remote audio stream, which
        // diarization intentionally leaves under one label. One candidate
        // from the attendee LIST is evidence enough to name it; one guessed
        // from an event title is not, and stays positional.
        if names.count == 1, candidates.fromAttendees,
           turns.contains(where: { $0.speaker == Self.remoteLabel }) {
            return turns.map { turn in
                turn.speaker == Self.remoteLabel
                    ? MeetingTurn(start: turn.start, end: turn.end,
                                  speaker: names[0], text: turn.text)
                    : turn
            }
        }
        let votes = MeetingSpeakerHints.votes(in: turns, names: names)
        var assignment: [String: String] = [:]
        var usedNames: Set<String> = []
        let ranked = votes
            .flatMap { label, tally in tally.map { (label: label, name: $0.key, count: $0.value) } }
            .sorted { $0.count > $1.count }
        for vote in ranked where vote.count >= 2 {
            guard assignment[vote.label] == nil, !usedNames.contains(vote.name) else { continue }
            assignment[vote.label] = vote.name
            usedNames.insert(vote.name)
        }
        guard !assignment.isEmpty else { return turns }
        return turns.map { turn in
            guard let named = assignment[turn.speaker] else { return turn }
            return MeetingTurn(start: turn.start, end: turn.end,
                               speaker: named, text: turn.text)
        }
    }

    /// Meetings whose transcription never finished (crash, quit, model
    /// failure): audio on disk + empty transcript. Finish the job at launch —
    /// a recording must never quietly rot into the 30-day sweep.
    func recoverOrphanedTranscriptions() {
        guard !isShuttingDown, !isRecoveringTranscripts else { return }
        isRecoveringTranscripts = true
        defer { isRecoveringTranscripts = false }
        let records = (try? Database.shared.read { try Meeting.fetchAll($0) }) ?? []
        for var record in records where record.id != meeting?.id {
            let state: MeetingProcessingRecord?
            do { state = try MeetingProcessingRecord.load(for: record) }
            catch {
                MeetingTranscriptionStatus.shared.fail(meetingID: record.id, message: "Recovery progress could not be read. Choose Regenerate transcript; your audio is saved.")
                continue
            }
            guard record.transcript.isEmpty || state?.phase == .running || state?.phase == .failed else { continue }
            guard state?.attempts ?? 0 < 3 else {
                MeetingTranscriptionStatus.shared.fail(meetingID: record.id, message: "Automatic retries stopped. Your recording is saved; retry when ready.")
                continue
            }
            guard [record.micAudioPath, record.systemAudioPath].compactMap({ $0 }).contains(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            if record.endedAt == nil {
                let duration = max(record.micAudioPath.map(Self.wavDuration(atPath:)) ?? 0,
                                   record.systemAudioPath.map(Self.wavDuration(atPath:)) ?? 0)
                record.endedAt = record.startedAt.addingTimeInterval(duration)
            }
            enqueueTranscription(TranscriptionJob(record: record, micPath: record.micAudioPath,
                systemPath: record.systemAudioPath, candidates: Self.speakerCandidates(eventTitle: record.title, attendees: record.participants.filter { !$0.isOwner }.map(\.name)), attendees: [], micLag: state?.micLag ?? 0,
                regenerating: state?.regenerating ?? false, expectedTranscript: state?.expectedTranscript ?? ""))
        }
    }

    // MARK: Music pause (Do Not Disturb comes later — needs a Shortcuts hook)

    private func pauseMusicIfPlaying() {
        pausedMusic = runAppleScript(
            "tell application \"Music\" to if it is running and player state is playing then\npause\nreturn \"paused\"\nend if"
        ) == "paused"
        if runAppleScript(
            "tell application \"Spotify\" to if it is running and player state is playing then\npause\nreturn \"paused\"\nend if"
        ) == "paused" {
            pausedMusic = true
        }
    }

    private func resumeMusicIfPaused() {
        guard pausedMusic else { return }
        pausedMusic = false
        _ = runAppleScript("tell application \"Music\" to if it is running then play")
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }

    // MARK: Pill

    /// Explicit size per state — this window is NEVER sized by measurement.
    /// fittingSize lies pre-layout (collapsed pill, "S" button) and
    /// GeometryReader only reports the space it was GIVEN, so a too-small
    /// panel stays crushed and thrashes. Fixed sizes end the whole saga.
    static func pillSize(provisional: Bool, editingTitle: Bool = false) -> CGSize {
        // The provisional card includes Cancel; a kept recording reveals
        // its name editor and Cancel together when expanded on hover.
        if provisional { return CGSize(width: 320, height: 186) }
        if editingTitle { return CGSize(width: 400, height: 444) }
        return CGSize(width: 186, height: 44)
    }

    var pointerIsInsidePill: Bool { panel?.frame.contains(NSEvent.mouseLocation) == true }

    private var pillFrameRevision = 0
    func applyPillFrame(animated: Bool = false) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        pillFrameRevision += 1
        let revision = pillFrameRevision
        let size = Self.pillSize(provisional: isProvisional, editingTitle: titleEditorVisible)
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 24,
                           y: visible.maxY - size.height - 24,
                           width: size.width, height: size.height)
        guard panel.frame != frame else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pillFrameRevision == revision, self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.30 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    private func showPill() {
        guard panel == nil else { return }
        let pill = FloatingPanel(content: MeetingPillView(controller: self), becomesKey: true, fixedSize: true)
        pill.becomesKeyOnlyIfNeeded = true
        pill.dismissesOnResign = false
        pill.isMovableByWindowBackground = false
        pill.onCancel = { [weak self] in self?.finishTitleEditing() }
        pill.onResignKey = { [weak self] in
            self?.flushRecordingTitle()
            guard self?.recordingNote.flush() != false else { return }
            guard self?.stopConfirmationVisible != true else { return }
            self?.setTitleEditorVisible(false)
        }
        pill.onDismiss = { [weak self] in self?.panel = nil }
        panel = pill
        // Top-right, out of the way — a meeting indicator, not a dialog.
        // Frame comes from the fixed size table, never from measurement.
        let size = Self.pillSize(provisional: isProvisional)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            pill.setFrame(
                NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                       width: size.width, height: size.height),
                display: true
            )
        }
        pill.orderFrontRegardless()
    }

    private func dismissPill() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func promptForSystemAudio() -> Bool {
        // Trigger the TCC prompt by attempting a start; if it fails, point at
        // the settings pane.
        do {
            try tap.start()
            tap.stop()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "My Man needs System Audio Recording access"
            alert.informativeText = "To hear the other side of your meetings, allow My Man under System Settings → Privacy & Security → Screen & System Audio Recording."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Record mic only")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
                return false
            }
            return true // mic-only fallback
        }
    }

    private func notifyDone(_ meeting: Meeting) {
        if meeting.transcript.isEmpty {
            Toast.show("No speech detected — nothing was saved",
                       systemImage: "waveform.slash", duration: 4, position: .bottomRight)
            return
        }
        Toast.show("Transcript ready: \(meeting.title)", duration: 4, position: .bottomRight)
    }
}

struct MeetingPillView: View {
    @ObservedObject var controller: MeetingController
    @State private var now = Date()
    @State private var titleDraft = ""
    @State private var hovering = false
    @State private var noteFocused = false
    @State private var showingNote = false
    @State private var collapseTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: MeetingController, showingNote: Bool = false) {
        self.controller = controller
        _showingNote = State(initialValue: showingNote)
    }

    private var fixedSize: CGSize {
        MeetingController.pillSize(provisional: controller.isProvisional,
                                   editingTitle: controller.titleEditorVisible)
    }
    private var isRecording: Bool {
        if case .recording = controller.phase { return true }
        return false
    }
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // The AppKit window is the only animation driver. Fill its actual
        // bounds instead of immediately laying out at the destination size.
        GeometryReader { _ in
            Group {
                if case .recording(let start) = controller.phase, controller.isProvisional {
                    provisionalCard(start: start)
                } else {
                    pillRow
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(width: fixedSize.width, height: fixedSize.height, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .clipped()
        .background(
            Group {
                if controller.isProvisional || isRecording {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MM.Colors.background)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(MM.Colors.border, lineWidth: 1))
                } else {
                    Capsule()
                        .fill(MM.Colors.background)
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                }
            }
        )
        .contentShape(Rectangle())
        .onAppear { titleDraft = controller.recordingTitle }
        .onHover { inside in
            hovering = inside
            collapseTask?.cancel()
            if inside {
                controller.setTitleEditorVisible(true)
            } else if !titleFocused && !noteFocused {
                // Resizing under the pointer can briefly produce an exit.
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, !hovering, !titleFocused, !noteFocused,
                          !controller.stopConfirmationVisible, !controller.pointerIsInsidePill else { return }
                    controller.setTitleEditorVisible(false)
                }
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused {
                controller.flushRecordingTitle()
                titleDraft = controller.recordingTitle
                if !hovering && !noteFocused && !controller.pointerIsInsidePill { controller.setTitleEditorVisible(false) }
            }
        }
        .onChange(of: controller.recordingTitle) { _, title in
            if !titleFocused { titleDraft = title }
        }
        .onChange(of: controller.titleEditorVisible) { _, visible in
            if !visible {
                titleFocused = false
                titleDraft = controller.recordingTitle
            }
        }
        .onChange(of: controller.stopConfirmationVisible) { _, visible in
            if !visible && !hovering && !titleFocused && !noteFocused { controller.setTitleEditorVisible(false) }
        }
        .confirmationDialog("Stop this meeting?", isPresented: $controller.stopConfirmationVisible,
                            titleVisibility: .visible) {
            Button("Stop & transcribe") { controller.confirmStopRecording() }
            Button("Keep recording", role: .cancel) { }
        } message: {
            Text("Recording will end and My Man will prepare the full transcript. Your recording will be saved.")
        }
        .onKeyPress(.escape) {
            guard controller.titleEditorVisible, !controller.stopConfirmationVisible else { return .ignored }
            finishEditing()
            return .handled
        }
        .onDisappear { collapseTask?.cancel() }
        .onReceive(clock) { now = $0 }
    }

    private func finishEditing() {
        guard controller.recordingNote.flush() else { return }
        hovering = false
        titleFocused = false
        controller.finishTitleEditing()
    }

    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 3) {
            Text("Meeting name")
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textSecondary)
            TextField("Meeting name", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textPrimary)
                .focused($titleFocused)
                .onChange(of: titleDraft) { _, text in controller.updateRecordingTitle(text) }
                .onSubmit { finishEditing() }
                .padding(MM.Layout.padding / 2)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                    .strokeBorder(titleFocused ? MM.Colors.accent : MM.Colors.border, lineWidth: 1))
                .accessibilityLabel("Meeting name")
                .help("Changes save while recording. Press Return to finish editing.")
        }
    }

    /// The in-your-face pre-meeting card: logo, live waveform, one obvious
    /// action. Capture is already rolling; only Start makes it real.
    private func provisionalCard(start: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use My Man")
                        .font(MM.Fonts.gellix(16, .semiBold))
                        .foregroundStyle(MM.Colors.textPrimary)
                    Text("Listening — nothing is saved unless you start")
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer()
                IconView(icon: .close, size: 13, color: MM.Colors.textTertiary)
                    .clickable(minSize: 32)
                    .onTapGesture { controller.discardProvisional() }
                    .help("Dismiss — nothing is saved")
            }
            HStack(spacing: 8) {
                MeetingRecordingIndicator()
                waveform
                timerText(since: start)
                Spacer()
            }
            .frame(height: 20)
            HStack(spacing: 8) {
                if let joinURL = controller.provisionalJoinURL {
                    Button {
                        NSWorkspace.shared.open(joinURL)
                        controller.keepProvisional()
                    } label: {
                        Text("Join & Start")
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(MM.Colors.textPrimary))
                            .clickable(minSize: 30)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    controller.keepProvisional()
                } label: {
                    Text("Start Meeting")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(controller.provisionalJoinURL == nil
                                         ? MM.Colors.background : MM.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(controller.provisionalJoinURL == nil
                                           ? AnyShapeStyle(MM.Colors.textPrimary)
                                           : AnyShapeStyle(MM.Colors.surface))
                        )
                        .overlay(Capsule().strokeBorder(
                            controller.provisionalJoinURL == nil ? Color.clear : MM.Colors.border,
                            lineWidth: 1))
                        .clickable(minSize: 30)
                }
                .buttonStyle(.plain)
                .help("Keep this recording — everything since it started listening")
            }
            Button {
                controller.discardProvisional()
            } label: {
                Text("Cancel")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .clickable(minSize: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss — nothing is saved")
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Collapsed: a compact 16-bar pulse. Expanded: the bars run the width
    /// of the header, stretching and folding back with the card. The pill
    /// window animates its frame at the same pace, so both move together.
    private var waveform: some View {
        let expanded = controller.titleEditorVisible && !controller.isProvisional
        return WaveformBars(levels: controller.levels)
            .frame(maxWidth: expanded ? .infinity : WaveformBars.compactWidth, alignment: .leading)
            // Fixed height: dancing bars must NEVER change the card's size —
            // size changes resize the window, and that loop reads as flicker.
            .frame(height: 18)
            .animation(reduceMotion ? nil : MM.Motion.silky, value: expanded)
    }

    private var pillRow: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
            switch controller.phase {
            case .idle:
                EmptyView()
            case .recording(let start):
                MeetingRecordingIndicator()
                waveform
                timerText(since: start)
                if controller.titleEditorVisible {
                    Spacer(minLength: 0)
                    Button {
                        controller.requestStopRecording()
                    } label: {
                        Text("Stop")
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.background)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(MM.Colors.textPrimary))
                            .clickable(minSize: 26)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            }
            if isRecording && controller.titleEditorVisible {
                titleEditor
                VStack(spacing: MM.Layout.spacing / 2) {
                    Picker("Recording details", selection: $showingNote) {
                        Text("Transcript").tag(false)
                        Text("My note").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if showingNote {
                        MeetingRecordingNoteView(draft: controller.recordingNote) { focused in
                            noteFocused = focused
                        }
                    } else {
                        MeetingLiveTranscriptView(transcript: controller.liveTranscript,
                                                  saveFailed: controller.liveEditSaveFailed,
                                                  retry: { controller.liveTranscript.retry() },
                                                  meetingID: controller.activeCaptureMeetingID)
                    }
                }
                    .frame(height: 302)
                    .transition(.opacity)
                Button {
                    controller.discardRecording()
                } label: {
                    Text("Cancel")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .clickable(minSize: 24)
                }
                .buttonStyle(.plain)
                .help("Discard this recording without saving or transcribing")
            }
        }
    }

    /// Fixed-width timer: use monospaced digits so free-width
    /// text changed size every second — and a size change means a window
    /// re-layout, which reads as flicker. The frame pins it.
    private func timerText(since start: Date) -> some View {
        Text(elapsed(since: start))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(MM.Colors.textSecondary)
            .frame(width: 42, alignment: .leading)
    }

    private func elapsed(since start: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Level history drawn newest-on-the-right, as many bars as the width holds.
struct WaveformBars: View {
    let levels: [Float]
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 2
    static let compactWidth: CGFloat = 16 * (barWidth + gap) - gap

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int((geo.size.width + Self.gap) / (Self.barWidth + Self.gap)))
            let shown = Array(levels.suffix(count))
            HStack(spacing: Self.gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(MM.Colors.accent)
                        .frame(width: Self.barWidth, height: 3 + CGFloat(min(1, level * 6)) * 12)
                }
            }
            .animation(.linear(duration: 0.08), value: shown)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }
}

struct MeetingRecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(MM.Colors.danger)
            .frame(width: 8, height: 8)
            .scaleEffect(reduceMotion || pulsing ? 1 : 0.85)
            .opacity(reduceMotion || pulsing ? 1 : 0.55)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = !reduceMotion }
            .onChange(of: reduceMotion) { _, value in pulsing = !value }
            .accessibilityLabel("Recording")
    }
}
