import Foundation
import NaturalLanguage

struct MeetingContextTerm: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case person, product, acronym }
    var text: String
    var kind: Kind
}

struct MeetingRecognizedWord: Codable, Equatable, Sendable {
    var text: String
    var confidence: Float
}

/// Context is spelling evidence, never a global hotword boost. Only explicitly
/// configured company folders participate, and product/acronym repairs require
/// uncertainty reported by the recognizer for that occurrence.
enum MeetingCompanyContext {
    struct Document {
        var url: URL
        var text: String
    }

    static func documents(for meeting: Meeting, folders: [String: String]? = nil) -> [Document] {
        let configured = folders ?? UserDefaults.standard.dictionary(forKey: "meetingPeopleFolders") as? [String: String] ?? [:]
        let domains = MeetingPeopleContext.domains(meeting)
        let pair = MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName)
        let names = meeting.participants.filter { !$0.isOwner }.map(\.name) + [pair?.remote].compactMap { $0 }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: meeting.startedAt)
        var result: [Document] = []
        for (domain, path) in configured.sorted(by: { $0.key < $1.key }) {
            let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            var found: [Document] = []; var bytes = 0
            for case let file as URL in files {
                guard found.count < 150, bytes < 2_000_000 else { break }
                guard file.pathExtension.lowercased() == "md", file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size < 300_000 else { continue }
                // Current-call reconciliations must not leak acceptance answers
                // into context. Today's prep is allowed; today's notes are not.
                let dated = file.pathComponents.first { $0.range(of: #"^\d{4}-\d{2}-\d{2}(?:$|[-.])"#, options: .regularExpression) != nil }.map { String($0.prefix(10)) }
                if let dated, dated > day || (dated == day && !file.lastPathComponent.localizedCaseInsensitiveContains("prep")) { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                bytes += size; found.append(Document(url: file, text: text))
            }
            let titleMatch = meeting.title.localizedCaseInsensitiveContains(root.lastPathComponent)
            let personMatch = names.contains { name in
                MeetingSource.words(name).count >= 2 && found.contains { $0.text.localizedCaseInsensitiveContains(name) }
            }
            if domains.contains(domain.lowercased()) || titleMatch || personMatch { result += found }
        }
        return result
    }

    static func terms(for meeting: Meeting, folders: [String: String]? = nil) -> [MeetingContextTerm] {
        let documents = documents(for: meeting, folders: folders)
        var result = terms(in: documents.map(\.text))
        if MeetingInterviewContext.isInterview(meeting.title) {
            result += standingTerms
            let pair = MeetingConversation.explicitPair(title: meeting.title, owner: meeting.ownerName)
            let names = meeting.participants.map(\.name) + [pair?.remote].compactMap { $0 }
            result += names.flatMap { name in
                name.split(separator: " ").filter { $0.count >= 4 }.map { .init(text: String($0), kind: .person) }
            }
        }
        return Array(Dictionary(grouping: result, by: { $0.text.lowercased() }).values.compactMap(\.first))
    }

    static let standingTerms: [MeetingContextTerm] =
        ["Claude", "Cursor", "Grokbot", "Figma", "Statsig", "Mixpanel"].map { .init(text: $0, kind: .product) }
        + ["PLG", "SVP", "MCP"].map { .init(text: $0, kind: .acronym) }

    static func terms(in documents: [String]) -> [MeetingContextTerm] {
        var counts: [String: Int] = [:]; var terms: [String: MeetingContextTerm] = [:]
        for document in documents {
            var found: [MeetingContextTerm] = MeetingPeopleContext.personNames(in: document).flatMap {
                $0.split(separator: " ").filter { $0.count >= 4 }.map { MeetingContextTerm(text: String($0), kind: .person) }
            }
            for (pattern, kind) in [(#"\b[A-Z]{2,6}\b"#, MeetingContextTerm.Kind.acronym),
                                    (#"\*\*([A-Z][\p{L}]+(?: [A-Z][\p{L}]+){0,3})\*\*"#, .product)] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: document, range: NSRange(document.startIndex..., in: document)) {
                    let index = kind == .product ? 1 : 0
                    if let range = Range(match.range(at: index), in: document) {
                        found.append(.init(text: String(document[range]), kind: kind))
                    }
                }
            }
            var seen = Set<String>()
            for term in found {
                let key = term.text.lowercased()
                if seen.insert(key).inserted { counts[key, default: 0] += 1; terms[key] = term }
            }
        }
        return counts.filter { $0.value >= 2 }.keys.sorted().compactMap { terms[$0] }
    }

    static func correct(_ text: String, terms: [MeetingContextTerm], words: [MeetingRecognizedWord]) -> MeetingVocabulary.Correction {
        guard !terms.isEmpty, !words.isEmpty else { return .init(text: text, corrections: []) }
        guard let regex = try? NSRegularExpression(pattern: #"\b[\p{L}]+\b"#) else { return .init(text: text, corrections: []) }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ns = text as NSString
        // Confidence belongs to an occurrence, not a spelling. One uncertain
        // token must never authorize changing a later, confidently heard word.
        let recognized = words.flatMap { word in
            regex.matches(in: word.text, range: NSRange(word.text.startIndex..., in: word.text)).map {
                ((word.text as NSString).substring(with: $0.range).lowercased(), word.confidence)
            }
        }
        guard recognized.count == matches.count,
              zip(matches, recognized).allSatisfy({ ns.substring(with: $0.0.range).lowercased() == $0.1.0 }) else {
            return .init(text: text, corrections: [])
        }
        let known = Set(terms.map { MeetingSource.normalized($0.text) })
        var edits: [(NSRange, String, String)] = []
        for index in matches.indices {
            var candidates: [(NSRange, String, String)] = []
            for term in terms {
                let canonical = MeetingSource.words(term.text)
                guard index + canonical.count <= matches.count else { continue }
                let slice = matches[index..<(index + canonical.count)]
                let range = NSRange(location: slice.first!.range.location, length: NSMaxRange(slice.last!.range) - slice.first!.range.location)
                let heard = ns.substring(with: range)
                let tokens = MeetingSource.words(heard)
                guard tokens != canonical, !known.contains(tokens.joined(separator: " ")), recognized[index..<(index + canonical.count)].contains(where: {
                    $0.1.isFinite && $0.1 < 0.6
                }) else { continue }
                switch term.kind {
                case .acronym:
                    // Edit distance alone confuses valid abbreviations (IPO/CPO,
                    // SAS/SMS, EPD/EOD). Only recognized confusion pairs qualify.
                    let confusions = ["PLD": "PLG", "SPP": "SVP"]
                    guard confusions[heard] == term.text else { continue }
                    guard heard == heard.uppercased(), (2...6).contains(heard.count), DictationCleanup.editDistance(heard.lowercased(), term.text.lowercased()) == 1 else { continue }
                case .person:
                    guard canonical.count == 1, tokens.count == 1, heard.count >= 4,
                          heard.first?.isUppercase == true else { continue }
                    let before = ns.substring(with: NSRange(location: max(0, range.location - 30), length: min(30, range.location)))
                    let after = ns.substring(from: NSMaxRange(range)).prefix(3)
                    guard before.range(of: #"(?i)(?:with|to|ask|from|by|hey|hello|hi|thanks)\s+$"#, options: .regularExpression) != nil || after.hasPrefix("'s") || after.hasPrefix("’s") else { continue }
                    guard sound(tokens[0]) == sound(canonical[0]), DictationCleanup.editDistance(tokens[0], canonical[0]) <= 2 else { continue }
                case .product:
                    if tokens.count == 1 {
                        // A near spelling of a distinctive product is eligible;
                        // ordinary English words stay untouched even when uncertain.
                        guard heard.first?.isUppercase == true, heard.count >= 5,
                              !["cloud", "clot", "notion", "looker", "roof", "roofer", "market", "motion", "design", "cursor"].contains(heard.lowercased()),
                              DictationCleanup.editDistance(tokens[0], canonical[0]) <= 1 else { continue }
                    } else {
                    guard tokens.first == canonical.first else { continue }
                    let contextStart = max(0, range.location - 45)
                    let context = ns.substring(with: NSRange(location: contextStart, length: range.location - contextStart)).lowercased()
                    guard ["product", "called", "named", "suite", "tool", "platform"].contains(where: context.contains),
                          zip(tokens, canonical).allSatisfy({ $0 == $1 || (abs($0.count - $1.count) <= 2 && DictationCleanup.editDistance(sound($0), sound($1)) <= 1) }) else { continue }
                    }
                }
                candidates.append((range, heard, term.text))
            }
            let unique = Dictionary(grouping: candidates, by: { $0.2 })
            guard unique.count == 1, let edit = candidates.first,
                  !edits.contains(where: { NSIntersectionRange($0.0, edit.0).length > 0 }) else { continue }
            edits.append(edit)
        }
        var result = text
        for edit in edits.reversed() {
            if let range = Range(edit.0, in: result) { result.replaceSubrange(range, with: edit.2) }
        }
        return .init(text: result, corrections: edits.map { "\($0.1) → \($0.2)" })
    }

    private static func sound(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "k", with: "g").filter { !"aeiouy".contains($0) }
    }
}
