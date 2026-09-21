import Foundation

/// Interview notes are organized around exchanges and speaker roles before
/// summarization. Historical answers cannot create present-day tasks.
enum MeetingInterviewNotes {
    static func storyIDs(_ answers: [MeetingInterviewAnswer]) -> Set<Int> {
        var ids = Set<Int>()
        for answer in answers {
            let question = MeetingSource.normalized(answer.question)
            let story = ["example", "your career", "tell me about a", "project you", "experience in your background"]
                .contains { question.contains($0) }
            if story {
                for span in [answer] + answer.followUps {
                    ids.formUnion(span.turns.map(\.id))
                }
            }
        }
        return ids
    }

    static func commitments(_ meeting: Meeting, answers: [MeetingInterviewAnswer]) -> [MeetingCommitment] {
        let stories = storyIDs(answers)
        let turns = MeetingSource.notesTurns(MeetingSource.parse(meeting.transcript)).filter { !stories.contains($0.id) }
        let paragraphs = MeetingSource.paragraphs(turns)
        var actions: [MeetingCommitment] = []
        for paragraph in paragraphs {
            for sentence in MeetingNoteSections.sentences(paragraph.text) {
                let normalized = MeetingSource.normalized(sentence)
                guard normalized.range(of: #"\bi (?:will|ll|m gonna|m going to|am going to)\b"#, options: .regularExpression) != nil,
                      !["i said", "we said", "i told", "back then", "at the time"].contains(where: normalized.contains) else { continue }
                let anchor = MeetingNoteSections.quoteAnchor(sentence, paragraph: paragraph, originals: turns)
                // Start at the actual promise, not an earlier first-person
                // clause such as "I finished the sketch, and I'm going to...".
                guard let promise = sentence.range(of: #"\bI(?:['’]ll| will|['’]m gonna|['’]m going to| am going to)\b"#, options: [.regularExpression, .caseInsensitive]) else { continue }
                let quote = String(sentence[promise.lowerBound...])
                let source = MeetingSourceTurn(id: anchor.id, speaker: anchor.speaker, timestamp: anchor.timestamp, text: quote)
                guard var action = MeetingEvidence.literalFollowUp(in: source), action.tentative != true else { continue }
                let task = MeetingSource.normalized(action.task)
                guard !["do a brief intro", "do brief intro", "start with", "share my screen", "give you background", "put it this way"].contains(where: task.hasPrefix) else { continue }
                // A deadline belongs to this promise. Another nearby event
                // (for example an onsite next week) must not date this task.
                let promiseClause = quote.components(separatedBy: CharacterSet(charactersIn: ".!?;")).first ?? quote
                let deadlineClause = promiseClause.range(of: #"\b(?:and|but|because)\b"#, options: [.regularExpression, .caseInsensitive])
                    .map { String(promiseClause[..<$0.lowerBound]) } ?? promiseClause
                for due in ["this week", "next week", "tomorrow", "today"] where deadlineClause.localizedCaseInsensitiveContains(due) {
                    action.due = due; break
                }
                actions.append(action)
            }
        }
        return GroundedMeetingNotes.selectActions(actions)
    }

    static func label(_ question: String) -> String {
        let text = MeetingSource.normalized(question)
        let labels: [(String, [String])] = [
            ("AI in product development", ["ai product", "use of ai", "artificial intelligence"]),
            ("API ecosystem", ["api", "webhook"]),
            ("Marketplace constraints", ["marketplace", "supplier", "bottleneck"]),
            ("Learning curve", ["learning curve"]),
            ("Product scope and organization", ["scope", "split", "product org"]),
            ("Working styles and leadership", ["working styles", "leadership"]),
            ("Motivation for joining", ["why this role", "why now", "motivations", "brought you"]),
            ("Experimentation", ["spectrum", "experimentation"]),
            ("Career example and lessons", ["example", "project you", "your career"]),
            ("Success conditions", ["needs to be true", "successful", "key elements", "prerequisites"]),
            ("Growth and product collaboration", ["collaborat", "growth pm", "classic product", "responsibilities"]),
            ("Building and shipping", ["built", "shipped", "building", "next thing"])
        ]
        return labels.first { item in item.1.contains(where: text.contains) }?.0 ?? "Interview discussion"
    }

    static func generate(_ meeting: Meeting, useLanguageModel: Bool,
                         progress: @escaping MeetingNotesService.Progress) async -> MeetingAnalysis {
        let raw = MeetingSource.parse(meeting.transcript)
        let visible = MeetingSource.notesTurns(raw)
        let detected = MeetingInterviewAnswers.exchanges(meeting)
        let answers = await MeetingInterviewAnswers.summarize(detected, useLanguageModel: useLanguageModel, progress: progress)
        guard !Task.isCancelled else { return .init(markdown: "") }
        let owner = meeting.resolvedOwner
        let ownerNames = Set([owner, meeting.ownerName, "You"])
        let remote = MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName)?.remote
            ?? visible.first(where: { !ownerNames.contains($0.speaker) && !MeetingSource.genericSpeaker($0.speaker) })?.speaker
            ?? "Interview participant"
        let firstQuestion = detected.first?.questionTime
        let intro = visible.prefix { $0.timestamp != firstQuestion }.filter { !ownerNames.contains($0.speaker) }
        let background = MeetingInterviewAnswers.excerpts(Array(intro))
        let labels = answers.reduce(into: [String]()) { labels, answer in
            let subject = label(answer.question)
            if !labels.contains(subject) { labels.append(subject) }
        }
        var markdown = "## Overview\n\n\(owner) and \(remote) discussed " + labels.map { $0.lowercased() }.joined(separator: "; ") + "."
        markdown += "\n\n## Main topics\n\n### Background and scope"
        if let first = intro.first, let last = intro.last { markdown += " [\(first.timestamp)–\(last.timestamp)]" }
        markdown += "\n\n" + (background.isEmpty ? "No complete background excerpt available." : background.map { "- " + $0 }.joined(separator: "\n"))
        for answer in answers {
            markdown += "\n\n### \(label(answer.question)) \(answer.range)\n\n"
            if answer.extractive == true { markdown += "*\(answer.speaker), source excerpts.*\n\n" }
            markdown += answer.bullets.isEmpty ? "Answer summary unavailable; see the complete timestamped answer." : answer.bullets.map { "- " + $0 }.joined(separator: "\n")
        }
        let actions = commitments(meeting, answers: detected)
        let sources = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let remainder = GroundedMeetingNotes.render(facts: [], actions: actions, sources: sources,
            meeting: meeting, privateOmitted: false, interviewAnswers: answers)
        if let start = remainder.range(of: "## Next steps") { markdown += "\n\n" + remainder[start.lowerBound...] }
        markdown += draft(meeting: meeting, remote: remote, background: background, answers: answers)
        var result = MeetingAnalysis(markdown: markdown, actions: actions)
        result.interviewAnswers = answers
        result.omissionEnabled = MeetingSource.omitPrivateNotes
        result.omittedPrivatePassages = MeetingSource.omitPrivateNotes && MeetingSource.publicTurns(raw).count < raw.filter { !MeetingSource.isBackchannel($0.text) }.count
        return result
    }

    static func draft(meeting: Meeting, remote: String, background: [String], answers: [MeetingInterviewAnswer]) -> String {
        let owner = meeting.resolvedOwner.split(separator: " ").first.map(String.init) ?? "Owner"
        func blocks(_ exchanges: [MeetingInterviewAnswer]) -> String {
            exchanges.map { answer in
                "#### " + label(answer.question) + " " + answer.range + "\n\n"
                    + answer.bullets.map { "- " + $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        return """


        ## Interview note draft

        ### Headline

        Interview with \(remote).

        ### What they said

        #### About themselves

        \(background.map { "- " + $0 }.joined(separator: "\n"))

        #### Product and org facts

        \(blocks(answers.filter { $0.ownerAnswer == false }))

        #### Leadership dynamics

        See the attributed company answers above; unstated relationships are not inferred.

        ### Their questions and what they were testing

        \(answers.filter { $0.ownerAnswer == true }.map { "- " + label($0.question) + " [" + $0.questionTime + "]. Testing intent not stated." }.joined(separator: "\n"))

        ### What \(owner) said

        \(blocks(answers.filter { $0.ownerAnswer == true }))

        ### Signal

        Review the attributed quotes and company answers above.

        ### \(owner)'s read

        ### Next steps

        See the owned commitments and explicitly inferred thank-you above.
        """
    }
}
