import XCTest
@testable import MyMan

final class AdaptiveLauncherVoiceTests: XCTestCase {
    func testEndpointBoundsIdleBuffersAndIgnoresClicks() {
        let start = Date(timeIntervalSince1970: 0)
        var endpoint = AdaptiveSpeechEndpoint(startedAt: start)
        XCTAssertEqual(endpoint.sample(level: 0.03, now: start.addingTimeInterval(0.1)), .keepListening)
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(1.2)), .keepListening)
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(5)), .discardSilence)
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(10)), .discardSilence)
    }

    func testEndpointRecognizesPausesAndCapsLongUtterances() {
        let start = Date(timeIntervalSince1970: 0)
        var endpoint = AdaptiveSpeechEndpoint(startedAt: start)
        for tick in 1...4 { XCTAssertEqual(endpoint.sample(level: 0.03, now: start.addingTimeInterval(Double(tick) / 10)), .keepListening) }
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(0.5)), .keepListening)
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(1.4)), .keepListening)
        XCTAssertEqual(endpoint.sample(level: 0, now: start.addingTimeInterval(1.6)), .transcribe)
        endpoint = AdaptiveSpeechEndpoint(startedAt: start)
        for tick in 1..<200 { _ = endpoint.sample(level: 0.03, now: start.addingTimeInterval(Double(tick) / 10)) }
        XCTAssertEqual(endpoint.sample(level: 0.03, now: start.addingTimeInterval(20)), .transcribe)
    }

    @MainActor func testDeniedPermissionDoesNotPrepareOrOpenMicrophone() async throws {
        let fake = FakeVoice()
        fake.allowed = false
        let voice = fake.controller()
        defer { voice.stop() }
        voice.start()
        try await eventually { voice.phase == .denied }
        XCTAssertFalse(voice.enabled)
        XCTAssertEqual(fake.preparations, 0)
        XCTAssertEqual(fake.beginnings, 0)
    }

    @MainActor func testCloseDuringModelPreparationDoesNotStartMicrophone() async throws {
        let fake = FakeVoice()
        fake.holdPreparation = true
        let voice = fake.controller()
        voice.start()
        try await eventually { fake.preparation != nil }
        voice.stop()
        fake.preparation?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(fake.beginnings, 0)
        XCTAssertFalse(voice.enabled)
        XCTAssertEqual(voice.phase, .off)
    }

    @MainActor func testLateMicrophoneStartupIsImmediatelyReleased() async throws {
        let fake = FakeVoice()
        fake.holdBegin = true
        let voice = fake.controller()
        voice.start()
        try await eventually { fake.beginning != nil }
        voice.stop()
        fake.beginning?.resume(returning: fake.session)
        try await eventually { fake.ended == [fake.session] }
        XCTAssertEqual(voice.phase, .off)
        XCTAssertNil(voice.utterance)
    }

    @MainActor func testCloseDiscardsLateTranscriptionAndDoesNotReopen() async throws {
        let fake = FakeVoice()
        fake.holdTranscription = true
        let voice = fake.controller()
        voice.start()
        try await eventually { voice.phase == .listening }
        speakThenPause(voice, fake: fake)
        try await eventually { fake.transcription != nil }
        voice.stop()
        fake.transcription?.resume(returning: "find my checklist")
        await Task.yield()
        XCTAssertNil(voice.utterance)
        XCTAssertEqual(fake.beginnings, 1)
        XCTAssertEqual(fake.ended, [fake.session])
        XCTAssertEqual(voice.phase, .off)
    }

    @MainActor func testSpeechIsDeliveredOnceAndListeningStopsAtThePause() async throws {
        let fake = FakeVoice()
        let voice = fake.controller()
        defer { voice.stop() }
        voice.start()
        try await eventually { voice.phase == .listening }
        speakThenPause(voice, fake: fake)
        try await eventually { voice.utterance != nil && voice.phase == .off }
        XCTAssertEqual(voice.utterance?.text, "find my checklist")
        XCTAssertEqual(fake.beginnings, 1)
        XCTAssertFalse(voice.enabled)
        fake.time = 10
        voice.sample()
        XCTAssertEqual(fake.beginnings, 1)
        voice.stop()
        XCTAssertEqual(fake.ended.count, 1)
        XCTAssertFalse(voice.enabled)
    }

    @MainActor func testExplicitlyResumedSpeechAppendsToExistingText() {
        XCTAssertEqual(AdaptiveLauncherVoice.appending(" launch notes ", to: "find my"), "find my launch notes")
        XCTAssertEqual(AdaptiveLauncherVoice.appending("launch notes", to: "find my "), "find my launch notes")
        XCTAssertEqual(AdaptiveLauncherVoice.appending("  ", to: "typed text"), "typed text")
        XCTAssertEqual(AdaptiveLauncherVoice.appending("find my notes", to: ""), "find my notes")
        XCTAssertEqual(AdaptiveLauncherIntent.resolve("Take a screenshot."), .action("screenshot"))
        XCTAssertEqual(QuickToolParser.parse("25 min focus."), .timer(1_500))
    }

    @MainActor func testListeningPausePersistsAcrossControllersExpiresAndCanBeReset() async throws {
        let suite = "AdaptiveListeningTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let fake = FakeVoice()
        let first = fake.controller(preferences: preferences)
        first.startAutomatically()
        try await eventually { first.phase == .listening }
        first.toggle()
        XCTAssertFalse(first.enabled)
        XCTAssertEqual(fake.ended, [fake.session])
        XCTAssertEqual(preferences.double(forKey: AdaptiveListeningPreference.key), 3_600)
        let reopened = fake.controller(preferences: preferences)
        reopened.startAutomatically()
        await Task.yield()
        XCTAssertFalse(reopened.enabled)
        XCTAssertEqual(fake.beginnings, 1)
        fake.time = 3_599
        reopened.startAutomatically()
        XCTAssertFalse(reopened.enabled)
        fake.time = 3_600
        reopened.startAutomatically()
        try await eventually { reopened.phase == .listening }
        reopened.pauseForOneHour()
        AdaptiveListeningPreference.reset(in: preferences)
        reopened.startAutomatically()
        try await eventually { reopened.phase == .listening }
        reopened.stop()
        XCTAssertFalse(AdaptiveListeningPreference.isPaused(in: preferences, now: Date(timeIntervalSince1970: fake.time)),
                       "Closing or typing must not create a one-hour pause")
    }

    @MainActor func testMicButtonResumesBeforeOneHourExpires() async throws {
        let suite = "AdaptiveListeningTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let fake = FakeVoice()
        let voice = fake.controller(preferences: preferences)
        voice.pauseForOneHour()
        voice.toggle()
        try await eventually { voice.phase == .listening }
        XCTAssertEqual(preferences.double(forKey: AdaptiveListeningPreference.key), 0)
        voice.stop()
    }

    @MainActor private func speakThenPause(_ voice: AdaptiveLauncherVoice, fake: FakeVoice) {
        fake.volume = 0.03
        for time in [0.1, 0.2, 0.3] { fake.time = time; voice.sample() }
        fake.volume = 0
        for time in [0.4, 1.5] { fake.time = time; voice.sample() }
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for voice lifecycle transition")
    }
}

@MainActor private final class FakeVoice {
    let session = UUID()
    var allowed = true
    var preparations = 0
    var beginnings = 0
    var ended: [UUID] = []
    var volume: Float = 0
    var time: TimeInterval = 0
    var holdPreparation = false
    var holdBegin = false
    var holdTranscription = false
    var preparation: CheckedContinuation<Bool, Never>?
    var beginning: CheckedContinuation<UUID, Never>?
    var transcription: CheckedContinuation<String, Never>?

    func controller(preferences: UserDefaults = .standard) -> AdaptiveLauncherVoice {
        AdaptiveLauncherVoice(dependencies: .init(
            authorize: { self.allowed },
            prepare: {
                self.preparations += 1
                if self.holdPreparation { return await withCheckedContinuation { self.preparation = $0 } }
                return true
            },
            begin: {
                self.beginnings += 1
                if self.holdBegin { return await withCheckedContinuation { self.beginning = $0 } }
                return self.session
            },
            end: { self.ended.append($0); return Array(repeating: 0.01, count: 16_000) },
            discard: { _ in },
            level: { _ in self.volume },
            transcribe: { _ in
                if self.holdTranscription { return await withCheckedContinuation { self.transcription = $0 } }
                return "find my checklist"
            },
            now: { Date(timeIntervalSince1970: self.time) }
        ), automaticallyPoll: false, preferences: preferences)
    }
}
