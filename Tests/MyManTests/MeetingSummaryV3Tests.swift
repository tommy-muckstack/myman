import XCTest
import GRDB
import FluidAudio
import AVFoundation
@testable import MyMan

final class MeetingSummaryV3Tests: XCTestCase {
    func testCompanyContextScopesFoldersAndExcludesCurrentCallNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-12T16:00:00Z"))
        let files = ["2026-05-11-notes.md": "Riley Smith uses PLG with **Review Guide**.",
                     "2026-05-12-peer-prep.md": "# Riley Smith\n1. How do product teams partner?\n2. What has been the biggest learning curve?",
                     "2026-05-12-peer-notes.md": "Riley Smith acceptance answers must not be context.",
                     "2026-05-13-notes.md": "Riley Smith future facts must not be context."]
        for (name, text) in files { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let meeting = Meeting(id: "scope-fixture", title: "CI: Alex Jones <> Riley Smith", startedAt: date, transcript: "", ownerName: "Alex Jones")
        let folders = ["example.test": root.path]
        let documents = MeetingCompanyContext.documents(for: meeting, folders: folders)
        XCTAssertEqual(Set(documents.map { $0.url.lastPathComponent }), ["2026-05-11-notes.md", "2026-05-12-peer-prep.md"])
        let prep = try XCTUnwrap(MeetingInterviewContext.discover(for: meeting, folders: folders))
        XCTAssertEqual(prep.questions.count, 2)
        var unrelated = meeting; unrelated.title = "CI: Alex Jones <> Morgan Brown"
        XCTAssertTrue(MeetingCompanyContext.documents(for: unrelated, folders: folders).isEmpty)
        try "Riley Smith\nWhy change the plan?".write(to: root.appendingPathComponent("2026-05-12-another-prep.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(MeetingInterviewContext.discover(for: meeting, folders: folders), "Ambiguous prep files must not be guessed")
    }

    func testLanguageGuardRetriesOnlyIsolatedSwitchesInEstablishedEnglish() {
        let english = "We have been discussing our product plans and the customer feedback for the next release. The team will review the onboarding changes and compare the results with the previous version before making a decision."
        XCTAssertTrue(MeetingLanguageGuard.shouldRetryEnglish("Что?", preceding: english))
        XCTAssertFalse(MeetingLanguageGuard.shouldRetryEnglish("This is ordinary English.", preceding: english))
        XCTAssertFalse(MeetingLanguageGuard.shouldRetryEnglish("Что?", preceding: ""))
        XCTAssertFalse(MeetingLanguageGuard.shouldRetryEnglish("Это настоящее русское предложение для разговора.", preceding: english))
        XCTAssertEqual(MeetingLanguageGuard.resolved(original: "Что?", retried: "Sure."), "Sure.")
        XCTAssertEqual(MeetingLanguageGuard.resolved(original: "Что?", retried: ""), "[unclear: language recognition]")
    }

    func testOptInEnglishAudioRetry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MAN_LANGUAGE_AUDIO"], let start = env["MAN_LANGUAGE_START"].flatMap(Double.init),
              let directory = env["MAN_INTERVIEW_REVIEW_DIR"] else { throw XCTSkip("Explicit private audio-slice review") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        file.framePosition = AVAudioFramePosition(start * file.processingFormat.sampleRate)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000 * 4))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        let text = await MeetingLanguageGuard.retryEnglish(samples)
        try JSONEncoder().encode(["start": String(start), "text": text, "engine": "Apple SpeechAnalyzer en-US"])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("language-retry.json"))
        print("LANGUAGE_RETRY \(text)")
    }

    func testCompanyTermsRequireLowConfidenceAndDoNotBiasCommonWords() {
        let terms: [MeetingContextTerm] = [.init(text: "PLG", kind: .acronym), .init(text: "Sandy", kind: .person),
            .init(text: "Review Guide", kind: .product), .init(text: "Looker", kind: .product)]
        let source = "PLD matters. Sundy's new too. The product review guy helps customers. Look at the market."
        let uncertain: Set<String> = ["PLD", "Sundy's", "guy", "Look"]
        let words = source.split(separator: " ").map { MeetingRecognizedWord(text: String($0), confidence: uncertain.contains(String($0)) ? 0.3 : 0.99) }
        let corrected = MeetingCompanyContext.correct(source, terms: terms, words: words)
        XCTAssertEqual(corrected.text, "PLG matters. Sandy's new too. The product Review Guide helps customers. Look at the market.")
        XCTAssertEqual(corrected.corrections.count, 3)
        XCTAssertEqual(MeetingCompanyContext.correct(source, terms: terms, words: []).text, source)
        XCTAssertEqual(MeetingCompanyContext.correct(source, terms: terms, words: words.map { .init(text: $0.text, confidence: 0.99) }).text, source)
        XCTAssertEqual(MeetingCompanyContext.correct("Ask the repair guy tomorrow.", terms: terms, words: words).text, "Ask the repair guy tomorrow.")
        let repeated: [MeetingRecognizedWord] = [.init(text: "PLD", confidence: 0.2), .init(text: "PLD", confidence: 0.99)]
        XCTAssertEqual(MeetingCompanyContext.correct("PLD PLD", terms: terms, words: repeated).text, "PLG PLD")
    }

    func testRecognizerSubwordConfidenceStaysWithItsWord() {
        let tokens = [TokenTiming(token: " El", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 0.9),
                      TokenTiming(token: "lie", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 0.3),
                      TokenTiming(token: " works", tokenId: 3, startTime: 0.4, endTime: 0.8, confidence: 0.95)]
        XCTAssertEqual(LiveMeetingTranscriptReader.recognizedWords(tokens), [.init(text: "Ellie", confidence: 0.3), .init(text: "works", confidence: 0.95)])
    }

    func testVocabularyNeedsCorroborationAndAuditIncludesLowercasePhrases() {
        let documents = ["Use **Review Guide** for PLG planning.", "The **Review Guide** product supports PLG."]
        let terms = MeetingCompanyContext.terms(in: documents)
        XCTAssertTrue(terms.contains(.init(text: "Review Guide", kind: .product)))
        XCTAssertTrue(terms.contains(.init(text: "PLG", kind: .acronym)))
        XCTAssertFalse(MeetingCompanyContext.terms(in: [documents[0]]).contains(.init(text: "Review Guide", kind: .product)))
        let before = "**Riley** [1:00]: What\n\n**Riley** [1:00]: Does PLD support the product review guy?"
        let after = before.replacingOccurrences(of: "PLD", with: "PLG").replacingOccurrences(of: "review guy", with: "Review Guide")
        let metadata = MeetingConversation.metadata(transcript: after, summary: "Notes", title: "Interview", owner: "Alex", started: .now, ended: .now, participants: [], originalTranscript: before)
        XCTAssertTrue(metadata.contains { $0.hasPrefix("flagged_hotwords:") && $0.contains("review guy") && $0.contains("Review Guide") })
    }

    func testQuotesPreferPrinciplesAndContrastsOverIntroductions() {
        XCTAssertEqual(MeetingNoteSections.quoteScore("I worked at a healthcare staffing company."), 0)
        XCTAssertEqual(MeetingNoteSections.quoteScore("Among the actual user base, the customer base."), 0)
        XCTAssertGreaterThan(MeetingNoteSections.quoteScore("You can automate delivery, but you cannot automate trust."), 0)
        XCTAssertGreaterThan(MeetingNoteSections.quoteScore("We need more thoughtful product planning."), 0)
        XCTAssertGreaterThan(MeetingNoteSections.quoteScore("It wasn't a bottom up strategy."), 0)
    }

    func testQuoteTimestampFollowsItsStartAcrossRecorderChunks() {
        let turns = [MeetingSourceTurn(id: 0, speaker: "Alex", timestamp: "1:00", text: "The introduction ended here."),
                     MeetingSourceTurn(id: 1, speaker: "Alex", timestamp: "1:05", text: "We need to simplify"),
                     MeetingSourceTurn(id: 2, speaker: "Alex", timestamp: "1:10", text: "the product before adding another feature.")]
        let paragraph = MeetingSource.paragraphs(turns)[0]
        XCTAssertEqual(MeetingNoteSections.quoteAnchor("We need to simplify the product before adding another feature.", paragraph: paragraph, originals: turns).timestamp, "1:05")
    }
    func testCompleteAnswersCrossAcknowledgmentsAndNestFollowUps() {
        let answer = "We started with a review of customer feedback and the support queue. The team found several problems with onboarding and decided to simplify the first session. I owned the scope and communication, and we shipped the smaller version the following week."
        let meeting = Meeting(id: "interview-fixture", title: "CI: Peer interview", startedAt: .now, transcript: """
        **Riley** [1:00]: Could you tell me about a project that slipped and what you did?

        **Alex** [1:10]: \(answer)

        **Riley** [1:40]: Sure, totally.

        **Alex** [2:00]: We also set a regular weekly update so everyone could see the progress and review the risks before the release.

        **Riley** [2:30]: In this project, what did you own versus what was outside of your control?

        **Alex** [2:40]: \(answer)

        **Riley** [3:30]: From your perspective, how do you see the responsibilities of growth managers?

        **Alex** [3:40]: \(answer)
        """, ownerName: "Alex")
        let exchanges = MeetingInterviewAnswers.exchanges(meeting)
        XCTAssertEqual(exchanges.count, 2)
        XCTAssertEqual(exchanges.first?.range, "[1:10–2:00]")
        XCTAssertTrue(exchanges.first?.turns.last?.text.contains("weekly update") == true)
        XCTAssertEqual(exchanges.first?.followUps.count, 1)
        XCTAssertEqual(exchanges.first?.followUps.first?.range, "[2:40–2:40]")
        XCTAssertFalse(MeetingInterviewAnswers.directedQuestion("They are mechanical engineers at heart, right?"))
        XCTAssertFalse(MeetingInterviewAnswers.directedQuestion("Is there anything I could answer for you about the company?"))
    }

    func testPhilosophyIsNotACommitmentAndThankYouIsExplicitlyInferred() {
        let turn = MeetingSourceTurn(id: 0, speaker: "Riley", timestamp: "3:00",
            text: "We need to find a balance between documents and live discussions.")
        XCTAssertNil(MeetingEvidence.literalFollowUp(in: turn))
        let meeting = Meeting(id: "interview-fixture", title: "CI: Peer interview", startedAt: .now, transcript: turn.prompt, ownerName: "Alex")
        let output = GroundedMeetingNotes.render(facts: [], actions: [], sources: [0: turn], meeting: meeting, privateOmitted: false)
        XCTAssertTrue(output.contains("**Alex** — Send a thank-you note (inferred-from-meeting-type; not a spoken commitment)."))
        XCTAssertFalse(output.contains("None agreed"))
        XCTAssertFalse(output.contains("find a balance"))
    }

    func testOptInPrivateInterviewSpans() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MAN_INTERVIEW_REVIEW_DIR"],
              let id = ProcessInfo.processInfo.environment["MAN_INTERVIEW_REVIEW_ID"] else { throw XCTSkip("Private supplied-call review") }
        let root = URL(fileURLWithPath: directory)
        let db = try DatabaseQueue(path: root.appendingPathComponent("input.sqlite").path)
        let fetched = try await db.read { try Meeting.fetchOne($0, key: id) }
        let meeting = try XCTUnwrap(fetched)
        var answers = MeetingInterviewAnswers.exchanges(meeting)
        if ProcessInfo.processInfo.environment["MAN_INTERVIEW_SUMMARIZE"] == "1" {
            answers = await MeetingInterviewAnswers.summarize(answers, useLanguageModel: true) { print($0); fflush(stdout) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(answers).write(to: root.appendingPathComponent("interview-spans.json"), options: .atomic)
        try MeetingInterviewAnswers.render(answers).write(to: root.appendingPathComponent("interview-answers.md"), atomically: true, encoding: .utf8)
        try MeetingNoteSections.quotes(meeting: meeting, limit: 10).write(to: root.appendingPathComponent("quotes.md"), atomically: true, encoding: .utf8)
        print("INTERVIEW_SPANS parents=\(answers.count) followups=\(answers.map { $0.followUps.count }) words=\(answers.map { MeetingSource.words($0.turns.map(\.text).joined(separator: " ")).count })")
    }
}
