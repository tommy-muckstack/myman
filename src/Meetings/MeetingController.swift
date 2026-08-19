import AppKit
import AVFoundation
import ScreenCaptureKit
import EventKit
import GRDB
import SwiftUI

struct Meeting: Codable, FetchableRecord, PersistableRecord {
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

    var slidePaths: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(slides.utf8))) ?? []
    }
}

// Meeting recording v1: system audio (CoreAudio process tap) + mic, each to
// its own 16kHz WAV, with a floating recording pill. On stop, both tracks
/// One utterance: who said it, and the window it occupies. Turns carry their
/// END as well as their start so overlapping speech can be ordered, and so
/// fragments of one sentence can be recognised by the gap between them.
struct MeetingTurn: Sendable, Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// Who the far side might be — and how much that is worth.
///
/// Attendee lists are evidence. A name inferred from an event title is a
/// guess, and the two must never be treated alike: a recording that spans two
/// calendar slots picks up the wrong title, and a guess stamped onto every
/// remote turn misfiles the whole conversation against a real person.
struct SpeakerCandidates: Sendable, Equatable {
    var names: [String] = []
    /// True only when these came from an actual attendee list.
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
    private var isStarting = false
    /// Meetings whose audio is still being transcribed in the background.
    /// Transcription never occupies the recorder: stopping a meeting returns
    /// the phase to .idle immediately, so a back-to-back call can start while
    /// the previous transcript is still being built. Jobs run one at a time —
    /// the ASR models aren't safe to share across concurrent transcriptions.
    @Published private(set) var transcribingTitles: [String] = []
    private var transcriptionChain: Task<Void, Never>?
    var isTranscribing: Bool { !transcribingTitles.isEmpty }
    /// Quill-style detection capture: recording is already running, but
    /// NOTHING persists unless the user clicks Save. Discard (or the safety
    /// timeout) deletes the audio with no database row, no transcription.
    @Published var isProvisional = false
    @Published var levels: [Float] = []
    private var provisionalTimeout: Timer?
    private var lastAudibleAt = Date()
    /// Remote/system audio is a stronger end-of-call clue than our own mic:
    /// the user may keep speaking or typing after everyone else leaves.
    private var lastRemoteAudibleAt = Date()
    private var slideTimer: Timer?
    private var slidePaths: [String] = []
    private var lastSlideFingerprint: [Float]?
    private var systemLevel: Float = 0
    private var levelTimer: Timer?

    private let tap = SystemAudioTap()
    private var micSession: UUID?
    private var micDrainTimer: Timer?
    private var systemWriter: WavWriter?
    private var micWriter: WavWriter?
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

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyMan/meetings", isDirectory: true)
    }

    /// Raw meeting audio is ~230MB/hour and only needed until it's
    /// transcribed. The transcript (DB + brain) is the durable artifact;
    /// WAVs older than 30 days get swept at launch.
    static func cleanupOldRecordings(olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let folder = recordingsFolder
        Task.detached(priority: .background) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            for file in files where file.pathExtension == "wav" {
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

    /// Detection fires this: capture starts NOW so no words are lost, but
    /// only Save makes it real.
    func startProvisional(title: String? = nil, joinURL: URL? = nil) {
        guard case .idle = phase else { return }
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
        guard isProvisional, let meeting else { return }
        isProvisional = false
        defer { applyPillFrame() }
        provisionalJoinURL = nil
        provisionalTimeout?.invalidate()
        provisionalTimeout = nil
        try? Database.shared.write { try meeting.insert($0) }
        Analytics.track("meeting_started", ["has_system_audio": tap.isRunning,
                                            "from_detection": true])
    }

    func discardProvisional() {
        guard isProvisional else { return }
        discardRecording()
    }

    /// Cancel an in-flight take without transcribing or retaining any audio.
    /// Auto-recorded detections are committed immediately, so this must work
    /// for both provisional and already-saved meeting rows.
    func discardRecording() {
        guard case .recording = phase else { return }
        let wasProvisional = isProvisional
        let discardedMeeting = meeting
        isProvisional = false
        provisionalJoinURL = nil
        stopEndWatch()
        provisionalTimeout?.invalidate()
        provisionalTimeout = nil
        slideTimer?.invalidate()
        slideTimer = nil
        for path in slidePaths { try? FileManager.default.removeItem(atPath: path) }
        slidePaths = []
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
        resumeMusicIfPaused()
        phase = .idle
        if isTranscribing { applyPillFrame() } else { dismissPill() }
        Analytics.track("meeting_discarded", ["provisional": wasProvisional])
        Toast.show("Recording cancelled — nothing was saved", systemImage: "xmark.circle")
    }

    private func start(provisional: Bool = false) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { return }
                await self.startAuthorized(provisional: provisional)
            }
        }
    }

    private func startAuthorized(provisional: Bool = false) async {
        // Permission callbacks can arrive more than once when a calendar
        // nudge and a manual click race. Only the first one may create a row —
        // and since starting the mic suspends, `phase` alone can't hold that
        // line: the second caller would sail past before the first sets it.
        guard case .idle = phase, !isStarting else { return }
        guard SystemAudioTap.hasPermission() || promptForSystemAudio() else { return }
        isStarting = true
        defer { isStarting = false }

        let id = UUID().uuidString
        let folder = Self.recordingsFolder
        systemWriter = WavWriter(url: folder.appendingPathComponent("\(id)-others.wav"))
        micWriter = WavWriter(url: folder.appendingPathComponent("\(id)-you.wav"))

        tap.onSamples = { [weak self] samples in
            self?.systemWriter?.append(samples)
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
            try tap.start()
            micSession = try await AudioCapture.shared.begin(.raw)
        } catch {
            NSLog("My Man [Meeting] start failed: \(error)")
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

        pauseMusicIfPlaying()

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
        pendingAttendees = People.currentEventAttendees()
        sessionAttendeeNames = Self.speakerCandidates(
            eventTitle: title, attendees: pendingAttendees.map(\.name))
        if provisional {
            isProvisional = true
            // Unclaimed for 90 minutes = not wanted. Quietly clean up.
            provisionalTimeout = Timer.scheduledTimer(withTimeInterval: 90 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.discardProvisional() }
            }
        } else {
            try? await Database.shared.write { [meeting] in
                if let meeting { try meeting.insert($0) }
            }
            Analytics.track("meeting_started", ["has_system_audio": tap.isRunning])
        }
        phase = .recording(start: started)
        applyPillFrame()
        levels = Array(repeating: 0, count: 16)
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
        slidePaths = []
        lastSlideFingerprint = nil
        slideTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureSlide(meetingID: meetingID) }
        }
    }

    private func captureSlide(meetingID: String) async {
        guard case .recording = phase, slidePaths.count < 24 else { return }
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let callBundles = Set(MeetingDetector.strongApps.keys)
            .union(MeetingDetector.browserBundles)
        let candidates = content.windows.filter { window in
            guard let bundle = window.owningApplication?.bundleIdentifier else { return false }
            return callBundles.contains(bundle) && window.isOnScreen
                && window.frame.width > 400 && window.frame.height > 300
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return }

        let config = SCStreamConfiguration()
        // Cap by SCALE, never by independent width/height — mismatched caps
        // make SCK letterbox the content into a corner (the wonky slides).
        let scaleFactor = min(2, 2560 / max(window.frame.width, 1),
                              1600 / max(window.frame.height, 1))
        config.width = max(2, Int(window.frame.width * scaleFactor))
        config.height = max(2, Int(window.frame.height * scaleFactor))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config) else { return }

        // Keep a frame only when the window meaningfully changed — slides
        // flipping, screen shares starting — never 90 copies of one face.
        let fingerprint = Self.fingerprint(image)
        if let last = lastSlideFingerprint, last.count == fingerprint.count {
            let diff = zip(fingerprint, last).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
                / Float(max(fingerprint.count, 1))
            guard diff > 0.04 else { return }
        }
        lastSlideFingerprint = fingerprint

        let url = Self.recordingsFolder
            .appendingPathComponent("\(meetingID)-slide-\(slidePaths.count).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        slidePaths.append(url.path)
    }

    /// 32×32 grayscale mean fingerprint — cheap frame-change detector.
    private static func fingerprint(_ image: CGImage) -> [Float] {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.map { Float($0) / 255 }
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

    private func stop() {
        stopEndWatch()
        levelTimer?.invalidate()
        levelTimer = nil
        slideTimer?.invalidate()
        slideTimer = nil
        micDrainTimer?.invalidate()
        micDrainTimer = nil
        tap.stop()
        drainMic(final: true)

        let systemURL = systemWriter?.close()
        let micURL = micWriter?.close()
        systemWriter = nil
        micWriter = nil

        resumeMusicIfPaused()

        guard var finished = meeting else {
            phase = .idle
            if isTranscribing { applyPillFrame() } else { dismissPill() }
            return
        }
        finished.endedAt = Date()
        if let data = try? JSONEncoder().encode(slidePaths) {
            finished.slides = String(decoding: data, as: UTF8.self)
        }
        slidePaths = []
        Analytics.track("meeting_stopped",
                        ["duration_s": Int(Date().timeIntervalSince(finished.startedAt)),
                         "slide_count": finished.slidePaths.count])
        // Everything the transcription needs travels with the job — the
        // controller's per-take state resets NOW so the next meeting can
        // start while this one transcribes.
        let job = TranscriptionJob(
            record: finished,
            micPath: micURL?.path, systemPath: systemURL?.path,
            candidates: sessionAttendeeNames, attendees: pendingAttendees)
        meeting = nil
        pendingAttendees = []
        sessionAttendeeNames = .none
        phase = .idle
        enqueueTranscription(job)
        applyPillFrame()
    }

    // MARK: Background transcription queue

    private struct TranscriptionJob {
        var record: Meeting
        let micPath: String?
        let systemPath: String?
        let candidates: SpeakerCandidates
        let attendees: [(name: String, email: String?)]
    }

    private func enqueueTranscription(_ job: TranscriptionJob) {
        transcribingTitles.append(job.record.title)
        Analytics.track("meeting_transcription_queued",
                        ["queue_depth": transcribingTitles.count])
        let previous = transcriptionChain
        transcriptionChain = Task { @MainActor in
            await previous?.value
            await self.runTranscription(job)
            if let index = self.transcribingTitles.firstIndex(of: job.record.title) {
                self.transcribingTitles.remove(at: index)
            }
            // The pill outlives the job only if something else needs it:
            // another queued transcript, or a recording that started meanwhile.
            if case .idle = self.phase, !self.isTranscribing {
                self.dismissPill()
            } else {
                self.applyPillFrame()
            }
        }
    }

    private func runTranscription(_ job: TranscriptionJob) async {
        var record = job.record
        // Meetings favor Qwen3 (~4x fewer word errors): transcription runs in
        // the background, so its slower decode costs nothing the user waits
        // on. load() falls back to Parakeet on its own when Qwen3 can't load
        // (download failure, macOS < 15).
        if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != .qwen3 {
            await TranscriptionService.shared.load(kind: .qwen3)
        }
        record.transcript = await Self.buildTranscript(
            micPath: job.micPath, systemPath: job.systemPath,
            candidates: job.candidates)
        Analytics.track("meeting_transcribed",
                        ["transcript_chars": record.transcript.count,
                         "engine": TranscriptionService.shared.kind.rawValue])
        if record.transcript.isEmpty || Self.isNoiseFragment(record) {
            // Nothing was said — or an aborted sliver of a recording that
            // would land in the brain looking like a real meeting. Keep
            // nothing, but say so plainly.
            if !record.transcript.isEmpty {
                Analytics.track("meeting_noise_discarded",
                                ["words": record.transcript
                                    .split(whereSeparator: \.isWhitespace).count])
            }
            await Self.deleteArtifacts(of: record)
        } else {
            try? await Database.shared.write { [record] in try record.update($0) }
            People.noteAttendees(job.attendees)
            Brain.syncMeeting(id: record.id, title: record.title,
                              startedAt: record.startedAt, endedAt: record.endedAt,
                              summary: record.summary, transcript: record.transcript)
        }
        notifyDone(record)
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
    /// often a bare email address, and `"michael.bird@amplitude.com"` has no
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
    /// personal one-on-one titled like "Tommy Neith Weekly", calendars often
    /// omit attendees entirely; use the single non-owner name in that exact
    /// title pattern as equally bounded evidence.
    nonisolated static func speakerCandidates(eventTitle: String?, attendees: [String]) -> SpeakerCandidates {
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
    private static func transcribeWavFile(atPath path: String) async -> String {
        await transcribeWavChunks(atPath: path).map(\.text).joined(separator: " ")
    }

    /// Max seconds per ASR slice for the ACTIVE engine. Qwen3 is built for
    /// ~30s utterances — longer input silently truncates its tail (the same
    /// defect dictation hit; see VoiceController.chunkSeconds). Parakeet
    /// handles a minute comfortably. Slices stay 5s under each ceiling so a
    /// pause-seeking cut has room to move the boundary.
    private static var maxSliceSeconds: Double {
        TranscriptionService.shared.kind == .qwen3 ? 25 : 55
    }

    /// Whole-chunk fallback size for the active engine, same ceilings.
    private static var chunkSeconds: Int {
        TranscriptionService.shared.kind == .qwen3 ? 30 : 60
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
    private static func transcribeWavChunks(atPath path: String)
        async -> [(start: Double, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let headerBytes: UInt64 = 44
        let seconds = chunkSeconds
        let chunkBytes = 16000 * seconds * 2 // one chunk of mono Int16
        var offset = headerBytes
        var parts: [(start: Double, text: String)] = []
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
            let start = Double(offset - headerBytes) / 32000
            let text = await TranscriptionService.shared.transcribe(samples)
            if !text.isEmpty { parts.append((start, text)) }
            if isFinal { break }
            offset += UInt64(consumedBytes)
        }
        return parts
    }

    /// Seconds of audio in a 16k mono Int16 WAV.
    private static func wavDuration(atPath path: String) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        return size > 44 ? Double(size - 44) / 32000 : 0
    }

    /// Turn detection with a safety net: when the energy gate finds little
    /// or nothing in a track that whole-file transcription CAN read, fall
    /// back to coarse 60s turns rather than dropping that side of the
    /// conversation. Real failure mode: a quiet mic track losing every one
    /// of the user's turns while the remote track came through fine.
    private static func turnsWithFallback(atPath path: String, speaker: String)
        async -> [MeetingTurn] {
        let turns = await transcribeTurns(atPath: path, speaker: speaker)
        let duration = wavDuration(atPath: path)
        let covered = turns.reduce(0.0) { $0 + Double($1.text.count) }
        // Under ~2 chars of text per second of audio across a multi-minute
        // track means the gate missed most speech (normal speech is ~12/s;
        // one quiet side of a call still produces well above 2).
        let sparse = duration > 120 && covered / duration < 2
        guard turns.isEmpty || sparse else { return turns }
        let chunks = await transcribeWavChunks(atPath: path)
        let chunkChars = chunks.reduce(0) { $0 + $1.text.count }
        guard chunkChars > Int(covered) * 2, chunkChars > 40 else { return turns }
        Analytics.track("meeting_track_fallback",
                        ["speaker": speaker, "turn_chars": Int(covered),
                         "chunk_chars": chunkChars, "duration_s": Int(duration)])
        let chunkLength = Double(chunkSeconds)
        return chunks.map {
            MeetingTurn(start: $0.start, end: $0.start + chunkLength, speaker: speaker, text: $0.text)
        }
    }

    /// Speech turns in a 16k WAV via energy gating, streamed — frame RMS at
    /// 0.1s, threshold adaptive over the track's noise floor, 1s of silence
    /// closes a turn. Memory cost: one float per frame.
    private static func speechSegments(atPath path: String) -> [(start: Double, end: Double)] {
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
        let threshold = max(0.002, min(max(0.004, noiseFloor * 2.5), peak * 0.25))
        var segments: [(Double, Double)] = []
        var current: (first: Int, last: Int)?
        var silentFrames = 0
        for (i, energy) in energies.enumerated() {
            if energy >= threshold {
                silentFrames = 0
                if current == nil { current = (i, i) } else { current?.last = i }
            } else if current != nil {
                silentFrames += 1
                if silentFrames >= 10 {
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
        let maxGap = 2.0
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
    private static func transcribeTurns(atPath path: String, speaker: String)
        async -> [MeetingTurn] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var turns: [MeetingTurn] = []
        for segment in speechSegments(atPath: path) {
            var offset = segment.start
            var texts: [String] = []
            while offset < segment.end {
                let maxSlice = maxSliceSeconds
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
                let text = await TranscriptionService.shared.transcribe(samples)
                if !text.isEmpty { texts.append(text) }
                offset = sliceEnd
            }
            let joined = texts.joined(separator: " ")
            if !joined.isEmpty {
                turns.append(MeetingTurn(start: segment.start, end: segment.end,
                                         speaker: speaker, text: joined))
            }
        }
        return turns
    }

    /// The interleaved conversation — both tracks' turns merged by time:
    ///   **You** [3:12]: …
    ///   **Speaker 2** [3:19]: …
    /// Falls back to the old two-block format when turn detection finds
    /// nothing but whole-file transcription would (very quiet audio).
    static func buildTranscript(micPath: String?, systemPath: String?,
                                candidates: SpeakerCandidates = .none) async -> String {
        var turns: [MeetingTurn] = []
        if let micPath, FileManager.default.fileExists(atPath: micPath) {
            turns += await turnsWithFallback(atPath: micPath, speaker: Self.ownerLabel)
        }
        if let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            var sysTurns = await turnsWithFallback(atPath: systemPath, speaker: Self.remoteLabel)
            if candidates.fromAttendees, candidates.names.count == 1,
               let only = candidates.names.first {
                // A 1:1 with a KNOWN attendee: exactly one person can be on
                // the remote track. Diarization can only hurt here — echo and
                // noise split one voice into "Speaker 1"/"Speaker 2" — so
                // skip it and label every remote turn with that attendee.
                // Only ever on attendee-list evidence: a name guessed from an
                // event title is not enough to put on someone's words.
                sysTurns = sysTurns.map {
                    MeetingTurn(start: $0.start, end: $0.end, speaker: only, text: $0.text)
                }
            } else {
                let diarized = await Diarization.shared.speakerSegments(forWavAtPath: systemPath)
                sysTurns = label(turns: sysTurns, with: collapsePhantomSpeakers(in: diarized))
            }
            turns += sysTurns
        }
        let terms = vocabularyTerms(candidates: candidates)
        if !turns.isEmpty {
            // Strictly chronological, and a turn that starts with another
            // resolves by which one finishes first.
            turns.sort { ($0.start, $0.end) < ($1.start, $1.end) }
            turns = nameSpeakers(in: turns, candidates: candidates)
            turns = mergeConsecutive(turns)
            return turns.map { turn in
                let m = Int(turn.start) / 60
                let s = Int(turn.start) % 60
                let text = DictationCleanup.applyVocabulary(turn.text, terms: terms)
                return "**\(turn.speaker)** [\(m):\(String(format: "%02d", s))]: \(text)"
            }.joined(separator: "\n\n")
        }
        var sections: [String] = []
        if let micPath, FileManager.default.fileExists(atPath: micPath) {
            let text = await transcribeWavFile(atPath: micPath)
            if !text.isEmpty {
                sections.append("\(Self.ownerLabel):\n\(DictationCleanup.applyVocabulary(text, terms: terms))")
            }
        }
        if let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            let text = await transcribeWavFile(atPath: systemPath)
            if !text.isEmpty {
                sections.append("\(Self.remoteLabel):\n\(DictationCleanup.applyVocabulary(text, terms: terms))")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    /// The same deterministic dictionary dictation already trusts —
    /// vocabulary.md + the people registry — plus this meeting's own attendee
    /// names. ASR mangles recurring proper nouns the same few ways every
    /// meeting ("Sneehith", "stat sig"); the restore pass puts the canonical
    /// spelling back without asking a model to rewrite anything.
    nonisolated static func vocabularyTerms(candidates: SpeakerCandidates) -> [String] {
        var terms = DictationCleanup.vocabulary()
        for name in candidates.names
        where !terms.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            terms.append(name)
        }
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
            phantoms = Set(total.filter { $0.key != dominant.key &&
                ($0.value < dominant.value * 0.10 || $0.value < 8) }.keys)
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
        let maxGap = 6.0
        var merged: [MeetingTurn] = []
        for turn in turns {
            guard var last = merged.last, last.speaker == turn.speaker,
                  turn.start - last.end <= maxGap else {
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
        var votes: [String: [String: Int]] = [:]
        for (index, turn) in turns.enumerated() {
            let lower = turn.text.lowercased()
            for name in names {
                let escaped = NSRegularExpression.escapedPattern(for: name.lowercased())
                if turn.speaker.hasPrefix("Speaker"),
                   lower.range(of: "\\b(i'm|i am|this is|it's) \\b" + escaped + "\\b",
                               options: .regularExpression) != nil {
                    votes[turn.speaker, default: [:]][name, default: 0] += 3
                }
                if lower.range(of: "\\b" + escaped + "[,?]", options: .regularExpression) != nil {
                    if let next = turns[(index + 1)...].first(where: { $0.speaker != turn.speaker }),
                       next.speaker.hasPrefix("Speaker") {
                        votes[next.speaker, default: [:]][name, default: 0] += 1
                    }
                }
            }
        }
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
        // Ride the same serial chain as live transcription jobs — the ASR
        // models can't take interleaved calls from two transcriptions.
        let previous = transcriptionChain
        transcriptionChain = Task { @MainActor in
            await previous?.value
            let orphans: [Meeting] = (try? await Database.shared.read { db in
                try Meeting.filter(Column("transcript") == "").fetchAll(db)
            }) ?? []
            for var orphan in orphans {
                guard case .idle = phase else { return }
                let micOK = orphan.micAudioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let sysOK = orphan.systemAudioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                guard micOK || sysOK else {
                    // Audio gone — the row is unrecoverable noise.
                    try? await Database.shared.write { [orphan] in
                        _ = try Meeting.deleteOne($0, key: orphan.id)
                    }
                    continue
                }
                if orphan.endedAt == nil, let path = orphan.micAudioPath,
                   let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                    orphan.endedAt = mtime
                }
                // Same engine policy as live jobs: accuracy first, with
                // load()'s own fallback to Parakeet when Qwen3 can't load.
                if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != .qwen3 {
                    await TranscriptionService.shared.load(kind: .qwen3)
                }
                orphan.transcript = await Self.buildTranscript(
                    micPath: orphan.micAudioPath, systemPath: orphan.systemAudioPath,
                    // Known people, not this meeting's attendee list —
                    // usable as naming hints, never as proof of who spoke.
                    candidates: SpeakerCandidates(
                        names: People.all().prefix(25).compactMap {
                            $0.name.split(separator: " ").first.map(String.init)
                        },
                        fromAttendees: false))
                if orphan.transcript.isEmpty || Self.isNoiseFragment(orphan) {
                    await Self.deleteArtifacts(of: orphan)
                } else {
                    try? await Database.shared.write { [orphan] in try orphan.update($0) }
                    Brain.syncMeeting(id: orphan.id, title: orphan.title,
                                      startedAt: orphan.startedAt, endedAt: orphan.endedAt,
                                      summary: orphan.summary, transcript: orphan.transcript)
                    Analytics.track("meeting_transcription_recovered")
                    let meetingID = orphan.id
                    Toast.show("Recovered meeting: \(orphan.title)",
                               actionLabel: "Open",
                               action: { MeetingDocumentController.shared.open(meetingID: meetingID) })
                }
            }
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
    static func pillSize(provisional: Bool, transcribing: Bool) -> CGSize {
        // Height covers header + waveform + action row + text-only Cancel.
        if provisional { return CGSize(width: 320, height: 186) }
        if transcribing { return CGSize(width: 216, height: 40) }
        return CGSize(width: 248, height: 76)
    }

    /// The pill shows the transcribing spinner only when nothing is being
    /// recorded — a new meeting takes the pill over while jobs finish behind it.
    var pillShowsTranscribing: Bool {
        if case .idle = phase { return isTranscribing }
        return false
    }

    func applyPillFrame() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = Self.pillSize(provisional: isProvisional, transcribing: pillShowsTranscribing)
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 24,
                           y: visible.maxY - size.height - 24,
                           width: size.width, height: size.height)
        guard panel.frame != frame else { return }
        DispatchQueue.main.async { [weak self] in
            self?.panel?.setFrame(frame, display: true)
        }
    }

    private func showPill() {
        guard panel == nil else { return }
        let pill = FloatingPanel(content: MeetingPillView(controller: self), becomesKey: false, fixedSize: true)
        pill.onDismiss = { [weak self] in self?.panel = nil }
        panel = pill
        // Top-right, out of the way — a meeting indicator, not a dialog.
        // Frame comes from the fixed size table, never from measurement.
        let size = Self.pillSize(provisional: isProvisional, transcribing: pillShowsTranscribing)
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
                       systemImage: "waveform.slash")
            return
        }
        let transcript = meeting.transcript
        TaskExtractor.run(text: transcript, source: .meeting)
        let meetingID = meeting.id
        Toast.show("Meeting transcribed",
                   actionLabel: "Open",
                   action: {
                       MeetingDocumentController.shared.open(meetingID: meetingID)
                   },
                   secondaryLabel: "Copy",
                   secondaryAction: {
                       NSPasteboard.general.clearContents()
                       NSPasteboard.general.setString(transcript, forType: .string)
                   })
    }
}

struct MeetingPillView: View {
    @ObservedObject var controller: MeetingController
    @State private var now = Date()

    private var fixedSize: CGSize {
        MeetingController.pillSize(provisional: controller.isProvisional,
                                   transcribing: controller.pillShowsTranscribing)
    }
    private var isRecording: Bool {
        if case .recording = controller.phase { return true }
        return false
    }
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if case .recording(let start) = controller.phase, controller.isProvisional {
                provisionalCard(start: start)
            } else {
                pillRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
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
        .frame(width: fixedSize.width, height: fixedSize.height)
        .onReceive(clock) { now = $0 }
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
                        .font(MM.Fonts.outfit(16, .semiBold))
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
                Circle().fill(.red).frame(width: 8, height: 8)
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

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(Array(controller.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(MM.Colors.accent)
                    .frame(width: 2, height: 3 + CGFloat(min(1, level * 6)) * 12)
            }
        }
        .animation(.linear(duration: 0.08), value: controller.levels)
        // Fixed container: dancing bars must NEVER change the card's size —
        // size changes resize the window, and that loop reads as flicker.
        .frame(height: 18)
    }

    private var pillRow: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
            switch controller.phase {
            case .idle:
                if controller.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text(controller.transcribingTitles.count > 1
                         ? "Transcribing \(controller.transcribingTitles.count) meetings…"
                         : "Transcribing meeting…")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textSecondary)
                } else {
                    EmptyView()
                }
            case .recording(let start):
                Circle().fill(.red).frame(width: 8, height: 8)
                waveform
                timerText(since: start)
                Button {
                    controller.toggle()
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
            }
            }
            if isRecording {
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

    /// Fixed-width timer: Outfit has no monospaced digits, so free-width
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
