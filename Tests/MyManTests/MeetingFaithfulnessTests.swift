import XCTest
@testable import MyMan

/// Regression cases from the 2026-09-15 two-person meeting review: notes
/// must keep what people meant, separate discussion from decisions, and
/// carry every follow-up. Names and companies here are fictional.
final class MeetingFaithfulnessTests: XCTestCase {
    private let transcript = """
    **Riley** [0:40]: So what do you want to talk about today?

    **Alex** [3:45]: As more customers use Claude with MCP, I think it changes where Amplitude should invest. I don't know where the resource allocation lands yet.

    **Riley** [11:15]: We've already committed heavily to Warehouse and Canvas, and the enterprise UI work still needs investment.

    **Riley** [11:48]: We don't need to necessarily

    **Riley** [12:11]: grow our existing team if we federate headless ownership across the product teams.

    **Alex** [15:15]: I can identify five or six broken headless workflows in each product area and ask for commitments.

    **Riley** [16:14]: The split is generative UI versus legacy UI, and the workflow agents sit between generative UI and headless.

    **Riley** [19:28]: Legacy UI stays; generative AI is the part we keep debating.

    **Riley** [22:46]: We should run a month-long showcase where each team shows one headless win.

    **Alex** [23:56]: I can bring that up with Ran and Gab.

    **Riley** [27:00]: For the deep research calls we use Opus for that, or Sonnet.

    **Alex** [28:10]: Would you PM that?

    **Riley** [29:56]: I'll talk to Pranjal about the design.
    """

    private var sources: [Int: MeetingSourceTurn] {
        Dictionary(uniqueKeysWithValues: MeetingSource.parse(transcript).map { ($0.id, $0) })
    }

    func testNegationSplitAcrossTurnsIsPreservedAndTeamIsNotEliminated() {
        let flipped = MeetingFact(sourceID: 4, text: "Proposes federating teams to reduce the need for an existing team.",
                                  quote: "We don't need to necessarily", importance: 3, kind: .proposal)
        XCTAssertNil(MeetingEvidence.fact(flipped, sources: sources), "a negated source cannot yield an un-negated claim")
        let kept = MeetingFact(sourceID: 4, text: "The existing team doesn't need to grow if headless ownership is federated across product teams.",
                               quote: "grow our existing team if we federate headless ownership", importance: 3, kind: .proposal)
        let fact = try! XCTUnwrap(MeetingEvidence.fact(kept, sources: sources))
        XCTAssertEqual(fact.resolvedKind, .proposal)
        // Wording spanning the split is grounded by reading the neighbour turn.
        XCTAssertTrue(MeetingEvidence.context(around: sources[4]!, in: sources).contains("don't need to necessarily"))
        // A quote that straddles the split resolves to the first half's turn.
        let spanning = "We don't need to necessarily grow our existing team if we federate headless ownership"
        XCTAssertEqual(MeetingEvidence.source(for: spanning, in: sources)?.id, 3)
        let whole = MeetingFact(sourceID: 3, text: "The existing team doesn't need to grow if headless ownership is federated across the product teams.",
                                quote: spanning, importance: 3, kind: .proposal)
        XCTAssertEqual(MeetingEvidence.fact(whole, sources: sources)?.sourceID, 3)
        XCTAssertNil(MeetingEvidence.fact(MeetingFact(sourceID: 3, text: "Suggests not growing the team by centralizing headless ownership.",
                                                      quote: spanning, importance: 3, kind: .proposal), sources: sources),
                     "centralizing is the opposite of what was said")
    }

    func testExistingInvestmentDoesNotBecomeANewCommitment() {
        let invented = MeetingFact(sourceID: 2, text: "Commits to the heavy investment in warehouse cameras.",
                                   quote: "We've already committed heavily to Warehouse and Canvas", importance: 3, kind: .decision)
        XCTAssertNil(MeetingEvidence.fact(invented, sources: sources), "cameras were never said")
        let honest = MeetingFact(sourceID: 2, text: "Already committed heavily to Warehouse and Canvas; the enterprise UI work still needs investment.",
                                 quote: "We've already committed heavily to Warehouse and Canvas", importance: 3, kind: .decision)
        XCTAssertEqual(MeetingEvidence.fact(honest, sources: sources)?.resolvedKind, .existingCommitment)
        XCTAssertEqual(MeetingEvidence.supportedKind(.decision, quote: "we should probably do that", claim: "Do that"), .proposal)
        XCTAssertEqual(MeetingEvidence.supportedKind(.decision, quote: "let's go with the federated model", claim: "Go with the federated model"), .decision)
    }

    func testAllThreeStrategicFollowUpsSurviveWithOwnershipUncertaintyKept() {
        let owned = [
            MeetingCommitment(sourceID: 5, owner: "Alex", task: "Identify five or six broken headless workflows in each product area",
                              quote: "I can identify five or six broken headless workflows in each product area", due: "", confidence: 0.9),
            MeetingCommitment(sourceID: 9, owner: "Alex", task: "Bring the showcase up with Ran and Gab",
                              quote: "I can bring that up with Ran and Gab", due: "", confidence: 0.9),
            MeetingCommitment(sourceID: 12, owner: "Riley", task: "Talk to Pranjal about the design",
                              quote: "I'll talk to Pranjal about the design", due: "", confidence: 0.95),
        ].compactMap { MeetingEvidence.commitment($0, sources: sources) }
        XCTAssertEqual(owned.map(\.owner), ["Alex", "Alex", "Riley"])
        XCTAssertTrue(owned.allSatisfy { $0.tentative == false && $0.due.isEmpty })
        let shared = MeetingEvidence.commitment(MeetingCommitment(sourceID: 8, owner: "Riley", task: "Run a month-long showcase of headless wins",
                                                                  quote: "We should run a month-long showcase where each team shows one headless win",
                                                                  due: "month-long", confidence: 0.9, tentative: true), sources: sources)
        XCTAssertEqual(shared?.owner, MeetingCommitment.unassignedOwner)
        XCTAssertEqual(shared?.tentative, true)
        XCTAssertEqual(shared?.due, "", "a duration is not a deadline")
        XCTAssertTrue(DueDate.isDuration("month-long")); XCTAssertTrue(DueDate.isDuration("Q4")); XCTAssertFalse(DueDate.isDuration("by Friday"))
        // A shared "we should" the model pinned on its speaker keeps the
        // follow-up and loses the invented owner.
        let claimed = MeetingEvidence.commitment(MeetingCommitment(sourceID: 8, owner: "Riley", task: "Run a month-long showcase of headless wins",
                                                                   quote: "We should run a month-long showcase where each team shows one headless win",
                                                                   due: "", confidence: 0.9), sources: sources)
        XCTAssertEqual(claimed?.owner, MeetingCommitment.unassignedOwner)
        XCTAssertEqual(claimed?.tentative, true)
        // An aspiration is not a follow-up at all.
        XCTAssertNil(MeetingEvidence.commitment(MeetingCommitment(sourceID: 8, owner: "Riley", task: "Explore robotics",
                                                                  quote: "We should explore robotics one day", due: "", confidence: 0.9), sources: [8: MeetingSourceTurn(id: 8, speaker: "Riley", timestamp: "1:00", text: "We should explore robotics one day, but we haven't decided.")]))
        let selected = GroundedMeetingNotes.selectActions(owned + [shared!])
        XCTAssertEqual(selected.count, 4)
        XCTAssertEqual(selected.last?.owner, MeetingCommitment.unassignedOwner)
    }

    func testFollowUpsAreRecoveredFromTheSpeakersOwnSentence() {
        let identify = try! XCTUnwrap(MeetingEvidence.literalFollowUp(in: sources[5]!))
        XCTAssertEqual(identify.owner, "Alex")
        XCTAssertEqual(identify.task, "Identify five or six broken headless workflows in each product area")
        XCTAssertEqual(identify.tentative, false)
        let showcase = try! XCTUnwrap(MeetingEvidence.literalFollowUp(in: sources[8]!))
        XCTAssertEqual(showcase.owner, MeetingCommitment.unassignedOwner)
        XCTAssertEqual(showcase.task, "Run a month-long showcase where each team shows one headless win")
        XCTAssertEqual(showcase.tentative, true)
        XCTAssertNil(MeetingEvidence.literalFollowUp(in: sources[11]!), "a question is not a promise")
        XCTAssertNil(MeetingEvidence.literalFollowUp(in: MeetingSourceTurn(id: 20, speaker: "Alex", timestamp: "5:00", text: "Let me know what you think.")))
        // A misquoted candidate is re-anchored to the promise sentence of its turn.
        let misquoted = MeetingCommitment(sourceID: 5, owner: "Alex", task: "Identify broken headless workflows in each product area",
                                          quote: "Nobody has capacity locked in yet.", due: "", confidence: 0.6)
        XCTAssertEqual(MeetingEvidence.commitment(misquoted, sources: sources)?.quote, "I can identify five or six broken headless workflows in each product area and ask for commitments.")
    }

    func testUnsupportedPrecisionAndDisputedRolesAbstain() {
        let version = MeetingFact(sourceID: 10, text: "Deep research calls use Opus 4.8 or Sonnet.",
                                  quote: "we use Opus for that, or Sonnet", importance: 2, kind: .discussion)
        XCTAssertNil(MeetingEvidence.fact(version, sources: sources), "4.8 was never said")
        let plain = MeetingFact(sourceID: 10, text: "Deep research calls use Opus or Sonnet.",
                                quote: "we use Opus for that, or Sonnet", importance: 2, kind: .discussion)
        XCTAssertNotNil(MeetingEvidence.fact(plain, sources: sources))
        let role = MeetingEvidence.commitment(MeetingCommitment(sourceID: 11, owner: "Riley", task: "PM the showcase",
                                                                quote: "Would you PM that?", due: "", confidence: 0.9), sources: sources)
        XCTAssertNil(role, "a disputed one-line question is not a role assignment")
    }

    func testMeetingWideCorroborationRepairsUIButNeverGuessesClientOrCameras() {
        let lines = ["The split is generative UI versus legacy UI.", "Workflow agents sit between generative UI and headless.",
                     "Legacy UI stays; generative AI is the part we keep debating.", "The client asked about cameras in the warehouse.",
                     "We use Claude and Canvas every day; Claude and Canvas again."]
        let aliases = MeetingVocabulary.corroboratedPhrases(in: lines)
        XCTAssertEqual(aliases["generative AI"], "generative UI")
        XCTAssertFalse(aliases.keys.contains { $0.lowercased().contains("client") || $0.lowercased().contains("cameras") })
        let corrected = MeetingVocabulary.correct(lines[2], terms: [], aliases: aliases)
        XCTAssertEqual(corrected.text, "Legacy UI stays; generative UI is the part we keep debating.")
        XCTAssertEqual(corrected.corrections, ["generative AI → generative UI"])
        // Both readings frequent: genuinely different ideas, nothing changes.
        let both = MeetingVocabulary.corroboratedPhrases(in: lines + ["generative AI here", "generative AI there"])
        XCTAssertNil(both["generative AI"])
    }

    func testLateFollowUpsSurviveAndAgendaPromptsNeverLead() {
        let facts = (0..<30).map { index in
            MeetingFact(sourceID: index, text: "Point number \(index) about workflow \(index) ownership.", quote: "passage \(index) covers area\(index) with team\(index) and owner\(index) details",
                        importance: index % 5 == 0 ? 3 : 2, kind: .discussion)
        }
        let selected = GroundedMeetingNotes.selectFacts(facts)
        XCTAssertEqual(selected.count, 12)
        XCTAssertGreaterThan(selected.last!.sourceID, 25, "the closing minutes keep their place")
        let agenda = MeetingFact(sourceID: 0, text: "Asks what to talk about today.", quote: "So what do you want to talk about today?", importance: 3, kind: .discussion)
        let opening = MeetingEvidence.fact(agenda, sources: sources)
        XCTAssertEqual(opening?.resolvedKind, .openQuestion)
        XCTAssertEqual(opening?.importance, 1)
        XCTAssertTrue(GroundedMeetingNotes.leadFacts([opening!] + Array(selected.prefix(3))).allSatisfy { $0.quote != opening!.quote })
        let rendered = GroundedMeetingNotes.render(facts: [opening!], actions: [], sources: sources,
                                                   meeting: Meeting(id: "m", title: "t", startedAt: Date(), transcript: transcript), privateOmitted: false)
        XCTAssertTrue(rendered.contains("## Open questions"))
        XCTAssertFalse(rendered.contains("## Main topics"))
    }

    func testDuplicateQuotesCollapseAndStoredAnalysesStillDecode() throws {
        let a = MeetingFact(sourceID: 3, text: "Federate headless ownership across product teams.", quote: "federate headless ownership across the product teams", importance: 3, kind: .proposal)
        let b = MeetingFact(sourceID: 4, text: "“grow our existing team if we federate headless ownership across the product teams.”", quote: "grow our existing team if we federate headless ownership across the product teams", importance: 1, kind: .discussion)
        XCTAssertEqual(GroundedMeetingNotes.selectFacts([a, b]).count, 1)
        let legacy = try JSONDecoder().decode(MeetingAnalysis.self, from: Data(#"{"markdown":"x","facts":[{"sourceID":1,"text":"t","quote":"q","importance":2}],"actions":[{"sourceID":1,"owner":"A","task":"Send it","quote":"q","due":"","confidence":0.9,"isRequest":false}],"omittedPrivatePassages":false}"#.utf8))
        XCTAssertEqual(legacy.unclearPassages, 0)
        XCTAssertEqual(legacy.facts.first?.resolvedKind, .discussion)
        XCTAssertNil(legacy.actions.first?.tentative)
    }
}

/// Generated notes on a sanitized fixture shaped like the reviewed meeting.
/// Stochastic, so it runs only on request and reports over several runs.
final class MeetingNotesSemanticEvalTests: XCTestCase {
    @MainActor func testSanitizedTwoPersonMeetingRecap() async throws {
        guard ProcessInfo.processInfo.environment["MAN_SEMANTIC_EVAL"] == "1" else {
            throw XCTSkip("Set MAN_SEMANTIC_EVAL=1 to generate notes with the on-device model")
        }
        let fixture = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/two-person-strategy-meeting.md"), encoding: .utf8)
        var meeting = Meeting(id: "eval", title: "Alex / Riley", startedAt: Date(timeIntervalSince1970: 1_789_000_000), transcript: fixture)
        meeting.ownerName = "Alex"
        var failures: [String] = []
        for run in 1...2 {
            let analysis = await GroundedMeetingNotes.generate(meeting)
            let notes = analysis.markdown
            print("SEMANTIC_EVAL run \(run)\n\(notes)\n"); fflush(stdout)
            if let out = ProcessInfo.processInfo.environment["MAN_SEMANTIC_EVAL_OUT"] {
                try? (notes + "\n").write(to: URL(fileURLWithPath: out).appendingPathComponent("run-\(run).md"), atomically: true, encoding: .utf8)
            }
            func check(_ condition: Bool, _ label: String) { if !condition { failures.append("run \(run): \(label)") } }
            check(!notes.lowercased().contains("cameras"), "invented hardware")
            check(!notes.lowercased().contains("reduce the need"), "negation flipped")
            check(!notes.lowercased().contains("eliminat"), "team elimination invented")
            check(!notes.contains("4.8"), "unsupported model version")
            check(!notes.lowercased().hasPrefix("## overview\n\n- riley: asks what"), "agenda prompt leads the recap")
            check(notes.contains("## Follow-ups"), "follow-ups missing")
            check(notes.lowercased().contains("pranjal") || notes.lowercased().contains("design"), "final-minute design follow-up lost")
            check(!notes.contains("— due"), "invented deadline")
            check(analysis.actions.allSatisfy { $0.tentative == true || ["Alex", "Riley"].contains($0.owner) }, "invented owner")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
