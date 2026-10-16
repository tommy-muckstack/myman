import Foundation

/// Spoken deletion applies to the current sentence, never an entire take.
/// Quoted phrases are content. Raw recognition remains available in history.
enum DictationBacktrack {
    static func apply(_ input: String) -> String {
        guard let command = try? NSRegularExpression(pattern: #"(?i)\b(scratch that|clear this dictation)\b[,.!?]?\s*"#) else { return input }
        var text = input
        var searchStart = 0
        while searchStart < text.utf16.count,
              let match = command.firstMatch(in: text, range: NSRange(location: searchStart, length: text.utf16.count - searchStart)) {
            let ns = text as NSString
            let before = ns.substring(to: match.range.location)
            // Avoid interpreting prose such as ‘the phrase scratch that’ and
            // explicit quoted examples as editing instructions.
            let singleQuotes = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])'|'(?![\p{L}\p{N}])"#)
            let singleQuoted = (singleQuotes?.numberOfMatches(in: before, range: NSRange(before.startIndex..., in: before)) ?? 0) % 2 == 1
            let quoted = singleQuoted || before.filter { $0 == "\"" }.count % 2 == 1
                || before.filter { $0 == "“" }.count > before.filter { $0 == "”" }.count
                || before.filter { $0 == "‘" }.count > before.filter { $0 == "’" }.count
            let literal = before.range(of: #"(?i)\b(phrase|words|say|saying|called|means|type)\s*$"#, options: .regularExpression) != nil
            if quoted || literal {
                searchStart = NSMaxRange(match.range)
                continue
            }
            let cue = ns.substring(with: match.range(at: 1)).lowercased()
            var kept = ""
            if cue != "clear this dictation" {
                let preceding = before.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?;:")))
                if let endings = try? NSRegularExpression(pattern: #"[.!?](?=\s)|\n"#),
                   let last = endings.matches(in: preceding, range: NSRange(preceding.startIndex..., in: preceding)).last {
                    kept = (preceding as NSString).substring(to: NSMaxRange(last.range)) + " "
                }
            }
            let remainder = ns.substring(from: NSMaxRange(match.range))
            let next = remainder.first.map { String($0).uppercased() + remainder.dropFirst() } ?? ""
            text = kept + next
            searchStart = kept.utf16.count
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
