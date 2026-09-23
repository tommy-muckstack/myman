import AppKit
import AVFoundation
import Foundation

/// Speech goes only into the visible adaptive launcher's input. This never
/// pastes into another app, saves audio, or executes the recognized request.
@MainActor
final class AdaptiveLauncherVoice: ObservableObject {
    enum Phase { case off, preparing, listening, transcribing, denied, unavailable }
    struct Utterance: Equatable {
        let id = UUID()
        let text: String
    }

    struct Dependencies {
        var authorize: () async -> Bool
        var prepare: () async -> Bool
        var begin: () async throws -> UUID
        var end: (UUID) -> [Float]
        var discard: (UUID) -> Void
        var level: (UUID) -> Float
        var transcribe: ([Float]) async -> String
        var now: () -> Date = Date.init

        static var live: Self {
            let audio = AudioCapture.shared
            let engine = TranscriptionService.shared.parakeet
            return Self(
                authorize: {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: return true
                    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
                    default: return false
                    }
                },
                prepare: { await engine.load(); return engine.isReady },
                // Raw capture shares the app's one engine without requesting
                // voice processing or ducking another app's audio.
                begin: { try await audio.begin(.raw) },
                end: { audio.end($0) },
                discard: { _ = audio.drain($0) },
                level: { audio.currentLevel(for: $0) },
                transcribe: {
                    let text = TranscriptionService.discardTaskHallucination(await engine.transcribe($0))
                    return DictationCleanup.applyVocabulary(text, terms: DictationCleanup.vocabulary())
                }
            )
        }
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var enabled = false
    @Published private(set) var level: Float = 0
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 16)
    @Published private(set) var utterance: Utterance?
    private let dependencies: Dependencies
    private let automaticallyPoll: Bool
    private let preferences: UserDefaults
    private var session: UUID?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var meter: Timer?
    private var endpoint = AdaptiveSpeechEndpoint(startedAt: .now)

    init(dependencies: Dependencies = .live, automaticallyPoll: Bool = true, preferences: UserDefaults = .standard) {
        self.dependencies = dependencies
        self.automaticallyPoll = automaticallyPoll
        self.preferences = preferences
    }

    var status: String {
        switch phase {
        case .off: return "Microphone off — type or turn it on"
        case .preparing: return "Preparing local dictation…"
        case .listening: return "Speak or type"
        case .transcribing: return "Turning speech into text…"
        case .denied: return "Allow microphone access to speak here"
        case .unavailable: return "Voice unavailable — you can still type"
        }
    }

    func start() {
        guard !enabled else { return }
        utterance = nil
        enabled = true
        phase = .preparing
        let current = UUID()
        generation = current
        task = Task { [weak self] in
            guard let self else { return }
            let allowed = await dependencies.authorize()
            guard isCurrent(current) else { return }
            guard allowed else { enabled = false; phase = .denied; return }
            let ready = await dependencies.prepare()
            guard isCurrent(current) else { return }
            guard ready else { enabled = false; phase = .unavailable; return }
            await begin(current)
        }
    }

    func startAutomatically() {
        guard !AdaptiveListeningPreference.isPaused(in: preferences, now: dependencies.now()) else { return }
        start()
    }

    func pauseForOneHour() {
        AdaptiveListeningPreference.pause(in: preferences, now: dependencies.now())
        stop()
    }

    /// Called by the panel controller, not only SwiftUI onDisappear: ordering
    /// an NSPanel out does not necessarily unmount its hosted SwiftUI view.
    func stop() {
        enabled = false
        utterance = nil
        generation = UUID()
        task?.cancel(); task = nil
        meter?.invalidate(); meter = nil
        if let session { _ = dependencies.end(session) }
        session = nil
        phase = .off
        level = 0
        levels = Array(repeating: 0, count: 16)
    }

    func toggle() {
        if enabled { pauseForOneHour() }
        else {
            AdaptiveListeningPreference.reset(in: preferences)
            start()
        }
    }

    private func isCurrent(_ current: UUID) -> Bool {
        enabled && generation == current && !Task.isCancelled
    }

    private func begin(_ current: UUID) async {
        guard isCurrent(current) else { return }
        do {
            let started = try await dependencies.begin()
            guard isCurrent(current) else { _ = dependencies.end(started); return }
            session = started
            endpoint = AdaptiveSpeechEndpoint(startedAt: dependencies.now())
            phase = .listening
            if automaticallyPoll {
                meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sample() }
                }
            }
        } catch {
            guard isCurrent(current) else { return }
            enabled = false
            phase = .unavailable
        }
    }

    func sample() {
        guard enabled, phase == .listening, let session else { return }
        let rawLevel = dependencies.level(session)
        level = min(1, rawLevel * 15)
        levels = Array(levels.dropFirst()) + [level / 6]
        switch endpoint.sample(level: rawLevel, now: dependencies.now()) {
        case .keepListening: break
        case .discardSilence: dependencies.discard(session)
        case .transcribe:
            meter?.invalidate(); meter = nil
            let samples = dependencies.end(session)
            self.session = nil
            level = 0
            phase = .transcribing
            let current = generation
            task = Task { [weak self] in
                guard let self else { return }
                let text = samples.count >= 4_800 ? await dependencies.transcribe(samples) : ""
                guard isCurrent(current) else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                enabled = false
                phase = .off
                levels = Array(repeating: 0, count: 16)
                task = nil
                if !trimmed.isEmpty { utterance = Utterance(text: trimmed) }
            }
        }
    }

    static func appending(_ speech: String, to typed: String) -> String {
        let text = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return typed }
        guard !typed.isEmpty else { return text }
        return typed + (typed.last?.isWhitespace == true ? "" : " ") + text
    }
}

enum AdaptiveListeningPreference {
    static let key = "adaptiveListeningPausedUntil"

    static func isPaused(in defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        defaults.double(forKey: key) > now.timeIntervalSince1970
    }

    static func pause(in defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.addingTimeInterval(3_600).timeIntervalSince1970, forKey: key)
    }

    static func reset(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// Keep idle microphone buffers bounded, ignore isolated clicks, and end an
/// utterance after a short pause. A single request ends after a pause or the 20-second limit.
struct AdaptiveSpeechEndpoint {
    enum Decision { case keepListening, discardSilence, transcribe }
    private var startedAt: Date
    private var lastSample: Date
    private var silenceSince: Date?
    private var voicedSeconds: TimeInterval = 0
    private var peak: Float = 0

    init(startedAt: Date) { self.startedAt = startedAt; lastSample = startedAt }

    mutating func sample(level: Float, now: Date) -> Decision {
        let elapsed = max(0, min(0.2, now.timeIntervalSince(lastSample)))
        lastSample = now
        peak = max(peak, level)
        if level > max(0.0035, peak * 0.12) {
            voicedSeconds += elapsed
            silenceSince = nil
        } else if silenceSince == nil { silenceSince = now }
        if voicedSeconds >= 0.2,
           now.timeIntervalSince(startedAt) >= 20 || silenceSince.map({ now.timeIntervalSince($0) >= 1 }) == true {
            return .transcribe
        }
        if voicedSeconds < 0.2, now.timeIntervalSince(startedAt) >= 5 {
            self = Self(startedAt: now)
            return .discardSilence
        }
        return .keepListening
    }
}
