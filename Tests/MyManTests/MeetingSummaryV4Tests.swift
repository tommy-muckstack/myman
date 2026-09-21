import XCTest
import GRDB
@testable import MyMan

final class MeetingSummaryV4Tests: XCTestCase {
    func testInterleavedNoiseDoesNotEraseShortCorrectionsOrRawWords() {
        let turns = [
            MeetingSourceTurn(id: 0, speaker: "Riley", timestamp: "1:00", text: "We need the new product to"),
            MeetingSourceTurn(id: 1, speaker: "Alex", timestamp: "1:01", text: "Let's do it."),
            MeetingSourceTurn(id: 2, speaker: "Riley", timestamp: "1:03", text: "help customers find the right parts."),
            MeetingSourceTurn(id: 3, speaker: "Alex", timestamp: "1:04", text: "No, not Friday."),
            MeetingSourceTurn(id: 4, speaker: "Riley", timestamp: "1:06", text: "Then we should discuss a different date.")]
        XCTAssertEqual(MeetingSource.contextualBackchannelIDs(turns), [1])
        XCTAssertEqual(MeetingSource.notesTurns(turns, omitPrivate: false).map(\.id), [0, 2, 3, 4])
        XCTAssertEqual(turns[1].text, "Let's do it.")
        let joined = MeetingSource.paragraphs(MeetingSource.notesTurns(turns, omitPrivate: false))
        XCTAssertEqual(joined[0].timestamp, "1:00")
        XCTAssertTrue(joined[0].text.contains("to help customers"))
    }

    func testReadingParagraphsRespectTimeGaps() {
        let turns = [MeetingSourceTurn(id: 0, speaker: "Alex", timestamp: "1:00", text: "First thought."),
                     MeetingSourceTurn(id: 1, speaker: "Alex", timestamp: "1:03", text: "Same thought."),
                     MeetingSourceTurn(id: 2, speaker: "Alex", timestamp: "2:00", text: "After a pause.")]
        XCTAssertEqual(MeetingSource.paragraphs(turns).count, 2)
    }

    func testQuestionStemsDoNotNeedPunctuation() {
        for question in ["How do you see that one.", "Is there an example in your career where",
                         "I'd love to hear your biggest learning curve.", "What makes you interested in this role.",
                         "Share with me a little more about your scope."] {
            XCTAssertTrue(MeetingInterviewAnswers.directedQuestion(question), question)
        }
        XCTAssertFalse(MeetingInterviewAnswers.directedQuestion("How can I help be helpful for you?"))
    }

    func testBothDirectionsKeepLongAnswersAndNestOnlyRelatedFollowUps() {
        let answer = "We built a careful plan for the new service. Our team reviewed customer feedback and tested several versions before choosing the final approach. The customers wanted a simple way to find the right product and understand the cost before committing to it."
        let meeting = Meeting(id: "two-directions", title: "CI: Alex Jones <> Riley Smith", startedAt: .now,
            transcript: """
            **Riley Smith** [1:00]: Is there an example in your career where the launch did not work.

            **Alex Jones** [1:10]: \(answer)

            **Riley Smith** [2:00]: What did you own in that project?

            **Alex Jones** [2:10]: \(answer)

            **Alex Jones** [3:00]: Share with me a little more about your scope.

            **Riley Smith** [3:10]: \(answer)

            **Alex Jones** [4:00]: Last question: have you been happy with the use of AI across your team?

            **Riley Smith** [4:10]: \(answer)
            """, ownerName: "Alex Jones")
        let answers = MeetingInterviewAnswers.exchanges(meeting)
        XCTAssertEqual(answers.filter { $0.ownerAnswer == true }.count, 1)
        XCTAssertEqual(answers.filter { $0.ownerAnswer == false }.count, 2)
        XCTAssertEqual(answers.first?.followUps.count, 1)
        let rendered = MeetingInterviewAnswers.render(answers, owner: "Alex Jones")
        XCTAssertTrue(rendered.contains("They asked Alex"))
        XCTAssertTrue(rendered.contains("Alex asked them"))
    }

    func testStoryPromisesCannotBecomeCurrentNextSteps() {
        let storyTurn = MeetingSourceTurn(id: 0, speaker: "Alex Jones", timestamp: "1:10", text: "I will send the revised release plan next week.")
        let answer = MeetingInterviewAnswer(question: "Tell me about a project that slipped.", questionTime: "1:00", speaker: "Alex Jones", turns: [storyTurn])
        let meeting = Meeting(id: "story", title: "CI: Interview", startedAt: .now, transcript: """
        **Alex Jones** [1:10]: I will send the revised release plan next week.

        **Riley Smith** [4:00]: I will of course share the feedback after our call.

        **Riley Smith** [4:05]: I'm gonna record the product video this week.
        """, ownerName: "Alex Jones")
        let actions = MeetingInterviewNotes.commitments(meeting, answers: [answer])
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { $0.owner == "Riley Smith" })
        XCTAssertFalse(actions.contains { $0.task.contains("release plan") })
        XCTAssertTrue(actions.contains { $0.task.contains("video") && $0.due == "this week" })
    }

    func testConversationalPromisesAndNearbyEventDatesAreNotTasks() {
        let meeting = Meeting(id: "current-promises", title: "CI: Interview", startedAt: .now, transcript: """
        **Riley Smith** [1:00]: I'll do a brief intro.

        **Riley Smith** [1:03]: I'll start with the second half.

        **Riley Smith** [2:00]: I will share the feedback and then you will hear back. Good luck with the onsite next week.

        **Riley Smith** [2:03]: The onsite is next week.

        **Riley Smith** [3:00]: I finished the sketch and I'm gonna record the product video this week.
        """, ownerName: "Alex Jones")
        let actions = MeetingInterviewNotes.commitments(meeting, answers: [])
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.first(where: { $0.task.contains("feedback") })?.due, "")
        XCTAssertEqual(actions.first(where: { $0.task.contains("video") })?.due, "this week")
    }

    func testPrepUsesQuestionsSectionAndDoesNotMatchUnaskedNarration() {
        let content = """
        ## Research
        Is the company profitable? This is a research note.
        ## Questions to ask the peer
        1. What is your biggest learning curve?
        1b. Who do the growth managers report to?
        ## After the call
        What should I do next?
        """
        let questions = MeetingInterviewContext.preparedPrompts(in: content)
        XCTAssertEqual(questions.count, 2)
        XCTAssertFalse(questions[1].hasPrefix("1b"))
        let answer = MeetingInterviewAnswer(question: "I'd love to hear your biggest learning curve.", ownerAnswer: false,
            questionTime: "2:00", speaker: "Riley", turns: [])
        let compared = MeetingInterviewContext.comparison(.init(prepPath: "prep.md", questions: questions), answers: [answer])
        XCTAssertTrue(compared.contains("What is your biggest learning curve? [2:00]"))
        XCTAssertTrue(compared.contains("### Not asked / not matched\n\n- Who do the growth managers report to?"))
    }

    func testStandingTermsStillRequireConfidenceForEachOccurrence() {
        let terms = MeetingCompanyContext.standingTerms
        let words = [MeetingRecognizedWord(text: "Fighma", confidence: 0.2), .init(text: "PLD", confidence: 0.3), .init(text: "PLD", confidence: 0.99)]
        XCTAssertEqual(MeetingCompanyContext.correct("Fighma PLD PLD", terms: terms, words: words).text, "Figma PLG PLD")
        XCTAssertEqual(MeetingCompanyContext.correct("Fighma PLD", terms: terms, words: []).text, "Fighma PLD")
        XCTAssertEqual(MeetingCompanyContext.correct("PLG", terms: terms + [.init(text: "SLG", kind: .acronym)], words: [.init(text: "PLG", confidence: 0.1)]).text, "PLG")
        XCTAssertEqual(MeetingCompanyContext.correct("IPO SAS", terms: [.init(text: "CPO", kind: .acronym), .init(text: "SMS", kind: .acronym)], words: [.init(text: "IPO", confidence: 0.1), .init(text: "SAS", confidence: 0.1)]).text, "IPO SAS")
        XCTAssertEqual(MeetingCompanyContext.correct("with AI capabilities", terms: [.init(text: "O'Reilly", kind: .person)], words: [.init(text: "with", confidence: 0.99), .init(text: "AI", confidence: 0.1), .init(text: "capabilities", confidence: 0.99)]).text, "with AI capabilities")
        XCTAssertEqual(MeetingCompanyContext.correct("Cloud", terms: terms, words: [.init(text: "Cloud", confidence: 0.1)]).text, "Cloud")
    }

    /// Runs the production generation entry point on copies. Expected answers
    /// stay outside this repository, and no hand-authored correction is input.
    func testOptInBothInterviewRecordings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["MAN_INTERVIEW_V4_DIR"], let ids = env["MAN_INTERVIEW_V4_IDS"] else {
            throw XCTSkip("Set private review directory and comma-separated meeting IDs")
        }
        let oldExperimental = UserDefaults.standard.object(forKey: "meetingInterviewNotesExperimental")
        UserDefaults.standard.set(true, forKey: "meetingInterviewNotesExperimental")
        defer {
            if let oldExperimental { UserDefaults.standard.set(oldExperimental, forKey: "meetingInterviewNotesExperimental") }
            else { UserDefaults.standard.removeObject(forKey: "meetingInterviewNotesExperimental") }
        }
        let oldFolders = UserDefaults.standard.object(forKey: "meetingPeopleFolders")
        if let folder = env["MAN_INTERVIEW_COMPANY_FOLDER"] {
            UserDefaults.standard.set(["review.invalid": folder], forKey: "meetingPeopleFolders")
        }
        defer {
            if let oldFolders { UserDefaults.standard.set(oldFolders, forKey: "meetingPeopleFolders") }
            else { UserDefaults.standard.removeObject(forKey: "meetingPeopleFolders") }
        }
        let root = URL(fileURLWithPath: directory)
        let db = try DatabaseQueue(path: root.appendingPathComponent("input.sqlite").path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for id in ids.split(separator: ",").map(String.init) {
            let found = try await db.read { try Meeting.fetchOne($0, key: id) }
            var meeting = try XCTUnwrap(found)
            let output = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if env["MAN_INTERVIEW_RETRANSCRIBE"] == "1" {
                let reader = LiveMeetingTranscriptReader(
                    micURL: meeting.micAudioPath.map { URL(fileURLWithPath: $0) },
                    systemURL: meeting.systemAudioPath.map { URL(fileURLWithPath: $0) },
                    singleRemote: true, profileDatabase: db,
                    checkpointURL: output.appendingPathComponent("redecoded.json"),
                    wallDuration: meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) }, contextMeeting: meeting)
                try await reader.prepare()
                var batches = 0
                while await reader.hasUnreadAudio() {
                    _ = try await reader.next(final: true)
                    batches += 1
                    if batches % 60 == 0 { print("AUDIO_REVIEW \(id) batches=\(batches)"); fflush(stdout) }
                }
                let turns = await reader.savedTurns()
                meeting.originalTranscript = MeetingSource.render(turns.map {
                    var turn = $0; turn.text = turn.originalText ?? turn.text; return turn
                })
                meeting.transcript = MeetingConversation.finish(MeetingSource.render(turns), meeting: meeting)
                try encoder.encode(meeting).write(to: output.appendingPathComponent("redecoded-meeting.json"))
            }
            if env["MAN_INTERVIEW_USE_REDECODED"] == "1" {
                meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: output.appendingPathComponent("redecoded-meeting.json")))
            }
            let checkpointURL = output.appendingPathComponent("redecoded.json")
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                let checkpoint = try JSONDecoder().decode(MeetingTranscriptCheckpoint.self, from: Data(contentsOf: checkpointURL))
                let terms = MeetingCompanyContext.terms(for: meeting)
                let audit = checkpoint.turns.compactMap { turn -> [String: String]? in
                    let original = turn.originalText ?? turn.text
                    let result = MeetingCompanyContext.correct(original, terms: terms, words: turn.recognizedWords ?? [])
                    guard result.text != original else { return nil }
                    return ["timestamp": MeetingSource.stamp(turn.start), "original": original,
                            "corrected": result.text, "changes": result.corrections.joined(separator: "; ")]
                }
                try encoder.encode(audit).write(to: output.appendingPathComponent("confidence-corrections.json"))
                try encoder.encode(terms).write(to: output.appendingPathComponent("scoped-terms.json"))
            }
            // Never let note caches write beside live audio during a review.
            meeting.micAudioPath = nil; meeting.systemAudioPath = nil
            let analysis = await MeetingNotesService.generateBounded(meeting) { print($0); fflush(stdout) }
            let answers = analysis.interviewAnswers ?? []
            try encoder.encode(answers).write(to: output.appendingPathComponent("answers.json"))
            try MeetingInterviewAnswers.render(answers, owner: meeting.resolvedOwner).write(to: output.appendingPathComponent("answers.md"), atomically: true, encoding: .utf8)
            try MeetingNoteSections.quotes(meeting: meeting).write(to: output.appendingPathComponent("quotes.md"), atomically: true, encoding: .utf8)
            meeting.summary = analysis.markdown
            meeting.analysisJSON = String(decoding: try encoder.encode(analysis), as: UTF8.self)
            try Brain.meetingMarkdown(meeting).write(to: output.appendingPathComponent("automatic-after.md"), atomically: true, encoding: .utf8)
            try MeetingInterviewContext.unmatchedQuestions(for: meeting).write(to: output.appendingPathComponent("prep-comparison.md"), atomically: true, encoding: .utf8)
            try encoder.encode(analysis).write(to: output.appendingPathComponent("analysis.json"))
            let raw = MeetingSource.parse(meeting.transcript)
            let noise = MeetingSource.contextualBackchannelIDs(raw)
            try encoder.encode(raw.filter { noise.contains($0.id) }).write(to: output.appendingPathComponent("backchannels.json"))
            try MeetingSource.paragraphs(raw.filter { !noise.contains($0.id) }).map {
                "**\($0.speaker)** [\($0.timestamp)]: \($0.text)"
            }.joined(separator: "\n\n").write(to: output.appendingPathComponent("reading-transcript.md"), atomically: true, encoding: .utf8)
            print("INTERVIEW_V4 \(id) questions=\(answers.map { $0.questionTime }) ownerAnswers=\(answers.filter { $0.ownerAnswer == true }.count) remoteAnswers=\(answers.filter { $0.ownerAnswer == false }.count)")
        }
    }
}
