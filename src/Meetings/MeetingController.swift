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
// transcribe on-device (Parakeet) into a "You" / "Others" transcript stored
// in the shared database. Music auto-pauses while recording.

@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(start: Date)
    }

    @Published var phase: Phase = .idle
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
    private var sessionAttendeeNames: [String] = []
    /// End-of-meeting watch: once a call app has been seen on the mic,
    /// its sustained absence means everyone hung up.
    private var endWatchTimer: Timer?
    private var callAppSeenOnMic = false
    private var callAppMissingPolls = 0
    private var endNudgeShown = false
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
        endWatchTimer?.invalidate()
        endWatchTimer = nil
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
                self.startAuthorized(provisional: provisional)
            }
        }
    }

    private func startAuthorized(provisional: Bool = false) {
        // Permission callbacks can arrive more than once when a calendar
        // nudge and a manual click race. Only the first one may create a row.
        guard case .idle = phase else { return }
        guard SystemAudioTap.hasPermission() || promptForSystemAudio() else { return }

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
            micSession = try AudioCapture.shared.begin(.raw)
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
            try? Database.shared.write { [meeting] in
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
        endWatchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForMeetingEnd() }
        }
    }

    private func pollForMeetingEnd() {
        guard case .recording = phase else { return }
        let owners = AudioCapture.processesUsingMic()
            .filter { $0 != Bundle.main.bundleIdentifier }
        let callActive = owners.contains {
            MeetingDetector.strongApps.keys.contains($0)
                || MeetingDetector.browserBundles.contains($0)
        }
        if callActive {
            callAppSeenOnMic = true
            callAppMissingPolls = 0
            return
        }
        // When macOS did attribute the call app, three missing polls is a
        // high-confidence hang-up and can end the recording automatically.
        if callAppSeenOnMic {
            callAppMissingPolls += 1
            guard callAppMissingPolls >= 3 else { return } // ~30s after hang-up
            endWatchTimer?.invalidate()
            endWatchTimer = nil
            if isProvisional {
                // Never opted in — the ended call takes its audio with it.
                Analytics.track("meeting_auto_discarded")
                discardProvisional()
            } else {
                Analytics.track("meeting_auto_stopped")
                Toast.show("Meeting ended — transcribing", systemImage: "checkmark.circle")
                stop()
            }
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
        endWatchTimer?.invalidate()
        endWatchTimer = nil
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
        sessionAttendeeNames = []
        phase = .idle
        enqueueTranscription(job)
        applyPillFrame()
    }

    // MARK: Background transcription queue

    private struct TranscriptionJob {
        var record: Meeting
        let micPath: String?
        let systemPath: String?
        let candidates: [String]
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
        // Meetings favor Parakeet: hour-long audio needs its speed.
        if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != .parakeet {
            await TranscriptionService.shared.load(kind: .parakeet)
        }
        record.transcript = await Self.buildTranscript(
            micPath: job.micPath, systemPath: job.systemPath,
            candidates: job.candidates)
        Analytics.track("meeting_transcribed", ["transcript_chars": record.transcript.count])
        if record.transcript.isEmpty {
            // Nothing was said — keep nothing, but say so plainly.
            try? await Database.shared.write { [record] in
                _ = try Meeting.deleteOne($0, key: record.id)
            }
            if let path = record.micAudioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let path = record.systemAudioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        } else {
            try? await Database.shared.write { [record] in try record.update($0) }
            People.noteAttendees(job.attendees)
            Brain.syncMeeting(id: record.id, title: record.title,
                              startedAt: record.startedAt, endedAt: record.endedAt,
                              summary: record.summary, transcript: record.transcript)
        }
        notifyDone(record)
    }

    /// The calendar event happening right now (±10 min), if any — its name
    /// beats a timestamp as the meeting title.
    private static func currentCalendarEventTitle() -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(600) }
            .sorted { $0.startDate > $1.startDate }
            .first?.title
    }

    /// Calendar attendees are the best source of real speaker names. For a
    /// personal one-on-one titled like "Tommy Neith Weekly", calendars often
    /// omit attendees entirely; use the single non-owner name in that exact
    /// title pattern as equally bounded evidence.
    private static func speakerCandidates(eventTitle: String?, attendees: [String]) -> [String] {
        var names = attendees.compactMap { $0.split(separator: " ").first.map(String.init) }
        let uniqueAttendees = Array(Set(names)).sorted()
        guard uniqueAttendees.isEmpty, let eventTitle else { return uniqueAttendees }

        let titleWords = eventTitle.components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let ownerWords = NSFullUserName().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 2 }
        guard let ownerFirst = ownerWords.first,
              titleWords.contains(where: { $0.caseInsensitiveCompare(ownerFirst) == .orderedSame })
        else { return uniqueAttendees }

        let generic = Set(["weekly", "sync", "meeting", "call", "catch", "up", "with", "and"])
        let candidate = titleWords.filter { word in
            !ownerWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
                && !generic.contains(word.lowercased())
                && word.count >= 3
        }
        if candidate.count == 1 { names.append(candidate[0]) }
        return Array(Set(names)).sorted()
    }

    /// Stream the WAV from disk in 60s slices — an hour of audio is ~230MB
    /// decoded, and holding two full meetings' worth in RAM is exactly how
    /// transcription dies on long recordings. Peak memory here is one chunk.
    private static func transcribeWavFile(atPath path: String) async -> String {
        await transcribeWavChunks(atPath: path).map(\.text).joined(separator: " ")
    }

    /// 60s chunk transcriptions with their start offsets — the coarse
    /// fallback shape when turn detection fails on a track.
    private static func transcribeWavChunks(atPath path: String)
        async -> [(start: Double, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let headerBytes: UInt64 = 44
        let chunkBytes = 16000 * 60 * 2 // 60s of mono Int16
        var offset = headerBytes
        var parts: [(start: Double, text: String)] = []
        while true {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
            let samples = data.withUnsafeBytes { raw -> [Float] in
                let int16 = raw.bindMemory(to: Int16.self)
                return int16.map { Float($0) / Float(Int16.max) }
            }
            let start = Double(offset - headerBytes) / 32000
            let text = await TranscriptionService.shared.transcribe(samples)
            if !text.isEmpty { parts.append((start, text)) }
            if data.count < chunkBytes { break }
            offset += UInt64(data.count)
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
        async -> [(start: Double, speaker: String, text: String)] {
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
        return chunks.map { ($0.start, speaker, $0.text) }
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
        return segments.filter { $0.1 - $0.0 >= 0.4 }
    }

    /// Transcribe each speech turn of one track, tagged with speaker + start.
    private static func transcribeTurns(atPath path: String, speaker: String)
        async -> [(start: Double, speaker: String, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var turns: [(start: Double, speaker: String, text: String)] = []
        for segment in speechSegments(atPath: path) {
            var offset = segment.start
            var texts: [String] = []
            while offset < segment.end {
                let sliceEnd = min(offset + 55, segment.end) // ASR-safe length
                let byteStart = 44 + UInt64(offset * 16000) * 2
                let byteCount = Int((sliceEnd - offset) * 16000) * 2
                try? handle.seek(toOffset: byteStart)
                guard let data = try? handle.read(upToCount: byteCount), !data.isEmpty else { break }
                let samples = data.withUnsafeBytes { raw -> [Float] in
                    raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
                }
                let text = await TranscriptionService.shared.transcribe(samples)
                if !text.isEmpty { texts.append(text) }
                offset = sliceEnd
            }
            let joined = texts.joined(separator: " ")
            if !joined.isEmpty { turns.append((segment.start, speaker, joined)) }
        }
        return turns
    }

    /// The interleaved conversation — both tracks' turns merged by time:
    ///   **You** [3:12]: …
    ///   **Them** [3:19]: …
    /// Falls back to the old two-block format when turn detection finds
    /// nothing but whole-file transcription would (very quiet audio).
    static func buildTranscript(micPath: String?, systemPath: String?,
                                candidates: [String] = []) async -> String {
        var turns: [(start: Double, speaker: String, text: String)] = []
        if let micPath, FileManager.default.fileExists(atPath: micPath) {
            turns += await turnsWithFallback(atPath: micPath, speaker: "You")
        }
        if let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            var sysTurns = await turnsWithFallback(atPath: systemPath, speaker: "Them")
            if candidates.count == 1, let only = candidates.first {
                // A 1:1: exactly one person can be on the remote track.
                // Diarization can only hurt here — echo and noise split one
                // voice into "Speaker 1"/"Speaker 2" — so skip it and label
                // every remote turn with the known attendee.
                sysTurns = sysTurns.map { ($0.start, only, $0.text) }
            } else {
                let diarized = await Diarization.shared.speakerSegments(forWavAtPath: systemPath)
                sysTurns = label(turns: sysTurns, with: diarized)
            }
            turns += sysTurns
        }
        if !turns.isEmpty {
            turns.sort { $0.start < $1.start }
            turns = nameSpeakers(in: turns, candidates: candidates)
            return turns.map { turn in
                let m = Int(turn.start) / 60
                let s = Int(turn.start) % 60
                return "**\(turn.speaker)** [\(m):\(String(format: "%02d", s))]: \(turn.text)"
            }.joined(separator: "\n\n")
        }
        var sections: [String] = []
        if let micPath, FileManager.default.fileExists(atPath: micPath) {
            let text = await transcribeWavFile(atPath: micPath)
            if !text.isEmpty { sections.append("You:\n\(text)") }
        }
        if let systemPath, FileManager.default.fileExists(atPath: systemPath) {
            let text = await transcribeWavFile(atPath: systemPath)
            if !text.isEmpty { sections.append("Others:\n\(text)") }
        }
        return sections.joined(separator: "\n\n")
    }

    /// Rename "Them" turns to "Speaker N" (first-appearance order) by max
    /// time-overlap with the diarizer's segments. One distinct voice — or no
    /// diarization at all — keeps the plain "Them", which reads better.
    private static func label(
        turns: [(start: Double, speaker: String, text: String)],
        with segments: [(speaker: String, start: Double, end: Double)]
    ) -> [(start: Double, speaker: String, text: String)] {
        let distinct = Set(segments.map(\.speaker))
        guard distinct.count >= 2 else { return turns }
        var order: [String: Int] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) where order[segment.speaker] == nil {
            order[segment.speaker] = order.count + 1
        }
        return turns.enumerated().map { index, turn in
            let turnEnd = index + 1 < turns.count ? turns[index + 1].start : turn.start + 30
            var overlap: [String: Double] = [:]
            for segment in segments {
                let shared = min(turnEnd, segment.end) - max(turn.start, segment.start)
                if shared > 0 { overlap[segment.speaker, default: 0] += shared }
            }
            guard let best = overlap.max(by: { $0.value < $1.value })?.key,
                  let n = order[best] else { return turn }
            return (turn.start, "Speaker \(n)", turn.text)
        }
    }

    /// Turn "Speaker N" into real names from conversational evidence:
    /// self-introductions ("it's Amy") vote strongly for the speaking turn;
    /// addressing someone ("Amy, what do you think?") votes for the NEXT
    /// different speaker. Candidates come from calendar attendees only —
    /// this can mislabel, never invent. One name per speaker, ≥2 votes.
    static func nameSpeakers(
        in turns: [(start: Double, speaker: String, text: String)],
        candidates: [String]
    ) -> [(start: Double, speaker: String, text: String)] {
        let names = Array(Set(candidates.filter { $0.count >= 3 }))
        guard !names.isEmpty else { return turns }
        // A two-person call has a single remote audio stream, which is
        // intentionally left as "Them" by diarization. If the calendar gives
        // exactly one non-owner candidate, that label is evidence-based.
        if names.count == 1, turns.contains(where: { $0.speaker == "Them" }) {
            return turns.map { turn in
                (turn.start, turn.speaker == "Them" ? names[0] : turn.speaker, turn.text)
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
            (turn.start, assignment[turn.speaker] ?? turn.speaker, turn.text)
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
                if !TranscriptionService.shared.isReady || TranscriptionService.shared.kind != .parakeet {
                    await TranscriptionService.shared.load(kind: .parakeet)
                }
                orphan.transcript = await Self.buildTranscript(
                    micPath: orphan.micAudioPath, systemPath: orphan.systemAudioPath,
                    candidates: People.all().prefix(25).compactMap {
                        $0.name.split(separator: " ").first.map(String.init)
                    })
                if orphan.transcript.isEmpty {
                    try? await Database.shared.write { [orphan] in
                        _ = try Meeting.deleteOne($0, key: orphan.id)
                    }
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
