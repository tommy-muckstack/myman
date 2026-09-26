import Foundation

/// Deterministic "write it the way a person types it" rules for dictation:
/// spoken numbers, money, percentages, clock times, dates, phone numbers,
/// domains, URLs, and code identifiers. The on-device model was too slow and
/// too unreliable for this (it timed out on every number-heavy passage), so
/// these run before and after it and never depend on it.
///
/// Conservative by design: numbers below ten stay words ("three of them",
/// "First, fix…") unless a unit, clock suffix, or month makes the intent clear.
enum SpokenForms {
    static func apply(_ text: String) -> String {
        joinIdentifiers(joinPaths(joinDomains(numbers(text))))
    }

    // MARK: Numbers

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
    private static let clockSuffixes: Set<String> = ["a.m.", "p.m.", "am", "pm"]

    private struct Token {
        var word: String      // lowercased, no surrounding punctuation
        var raw: String
        var trailing: String  // punctuation after the word
    }

    private static func tokenize(_ piece: String) -> Token {
        // Keep "a.m." / "p.m." intact; strip other trailing punctuation.
        let lower = piece.lowercased()
        for suffix in ["a.m.", "p.m."] where lower.hasPrefix(suffix) {
            return Token(word: suffix, raw: String(piece.prefix(4)), trailing: String(piece.dropFirst(4)))
        }
        let trailing = String(piece.reversed().prefix { ",.;:!?\"”)".contains($0) }.reversed())
        let core = String(piece.dropLast(trailing.count))
        return Token(word: core.lowercased(), raw: core, trailing: trailing)
    }

    /// Splits "forty-five" into its parts; nil when a part is not a number word.
    private static func numberParts(_ word: String) -> [String]? {
        let parts = word.split(separator: "-").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ units[$0] != nil || tens[$0] != nil || scales[$0] != nil || ordinalUnits[$0] != nil || ordinalTens($0) != nil }) else { return nil }
        return parts
    }

    private static func ordinalTens(_ word: String) -> Int? {
        guard word.hasSuffix("ieth") else { return nil }
        return tens[String(word.dropLast(4)) + "y"]
    }

    /// Strict cardinal/ordinal grammar: "forty five hundred", "twenty eighth",
    /// "one thousand two hundred". Returns nil for sequences like "two thirty"
    /// or "one two" that are not a single number.
    private static func value(_ parts: [String]) -> (value: Int, ordinal: Bool)? {
        var total = 0, current = 0, last = ""
        var ordinal = false
        for (index, part) in parts.enumerated() {
            guard !ordinal else { return nil } // nothing may follow an ordinal
            if let unit = units[part] ?? ordinalUnits[part] {
                if ordinalUnits[part] != nil { ordinal = true }
                if last == "unit" || (last == "tens" && unit >= 10) { return nil }
                current += unit; last = "unit"
            } else if let ten = tens[part] ?? ordinalTens(part) {
                if ordinalTens(part) != nil { ordinal = true }
                if last == "unit" || last == "tens" { return nil }
                current += ten; last = "tens"
            } else if let scale = scales[part] {
                guard index > 0, last != "scale" || scale > 100 else { return nil }
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale; current = 0
                }
                last = "scale"
            } else { return nil }
        }
        return (total + current, ordinal)
    }

    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }

    private static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    static func numbers(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map(numbersInLine).joined(separator: "\n")
    }

    private static func numbersInLine(_ line: String) -> String {
        let pieces = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let tokens = pieces.map(tokenize)
        var out: [String] = []
        var i = 0
        func emit(_ text: String, trailing: String) { out.append(text + trailing) }
        while i < tokens.count {
            // Phone numbers and other digit strings: "six one seven … O one four two".
            if let (digits, end) = digitRun(tokens, from: i), [7, 10, 11].contains(digits.count) {
                emit(phone(digits), trailing: tokens[end].trailing)
                i = end + 1; continue
            }
            // Clock times: "two thirty p.m.", "three pm", "four o'clock".
            if let (time, end) = clockTime(tokens, from: i) {
                emit(time, trailing: tokens[end].trailing)
                i = end + 1; continue
            }
            // Longest valid number-word run starting here, stopping at punctuation.
            var parts: [String] = [], best: (value: Int, ordinal: Bool, end: Int)?
            var j = i, runEnd = i
            while j < tokens.count, let more = numberParts(tokens[j].word) {
                parts += more
                runEnd = j
                if let parsed = value(parts) { best = (parsed.value, parsed.ordinal, j) }
                if !tokens[j].trailing.isEmpty { break }
                j += 1
            }
            guard let best else { out.append(pieces[i]); i += 1; continue }
            // "twenty twenty six" or "two thirty": several numbers spoken back
            // to back are ambiguous (a year? a time?), so leave them as said.
            guard best.end == runEnd else {
                for k in i...runEnd { out.append(pieces[k]) }
                i = runEnd + 1; continue
            }
            let end = best.end
            let next = end + 1 < tokens.count ? tokens[end + 1].word : ""
            let previous = i > 0 ? tokens[i - 1].word : ""
            let trailing = tokens[end].trailing
            if trailing.isEmpty, next == "percent" {
                emit("\(grouped(best.value))%", trailing: tokens[end + 1].trailing); i = end + 2; continue
            }
            if trailing.isEmpty, next == "dollars" || next == "dollar" {
                emit("$\(grouped(best.value))", trailing: tokens[end + 1].trailing); i = end + 2; continue
            }
            if best.ordinal {
                if months.contains(previous) || best.value >= 10 {
                    emit(months.contains(previous) ? String(best.value) : "\(best.value)\(ordinalSuffix(best.value))", trailing: trailing)
                    i = end + 1; continue
                }
            } else if best.value >= 10 {
                emit(grouped(best.value), trailing: trailing); i = end + 1; continue
            }
            // Small numbers and small ordinals stay words.
            for k in i...end { out.append(pieces[k]) }
            i = end + 1
        }
        return out.joined(separator: " ")
    }

    /// A run of single spoken digits; "O"/"oh" counts as zero once a run has begun.
    private static func digitRun(_ tokens: [Token], from start: Int) -> (String, Int)? {
        var digits = "", i = start, end = start
        while i < tokens.count {
            let word = tokens[i].word
            if let digit = digitWords[word] { digits += digit }
            else if !digits.isEmpty, word == "o" || word == "oh" { digits += "0" }
            else { break }
            end = i
            if !tokens[i].trailing.isEmpty { break }
            i += 1
        }
        guard digits.count >= 3 else { return nil }
        return (digits, end)
    }

    private static func phone(_ d: String) -> String {
        let c = Array(d)
        func s(_ r: Range<Int>) -> String { String(c[r]) }
        switch c.count {
        case 7: return "\(s(0..<3))-\(s(3..<7))"
        case 10: return "\(s(0..<3))-\(s(3..<6))-\(s(6..<10))"
        default: return "\(s(0..<1))-\(s(1..<4))-\(s(4..<7))-\(s(7..<11))"
        }
    }

    private static func clockTime(_ tokens: [Token], from start: Int) -> (String, Int)? {
        guard let hour = units[tokens[start].word], (1...12).contains(hour) else { return nil }
        // "four o'clock"
        if tokens[start].trailing.isEmpty, start + 1 < tokens.count, tokens[start + 1].word == "o'clock" {
            return ("\(hour) o'clock", start + 1)
        }
        // "three p.m."
        if tokens[start].trailing.isEmpty, start + 1 < tokens.count, clockSuffixes.contains(tokens[start + 1].word) {
            return ("\(hour) \(tokens[start + 1].raw)", start + 1)
        }
        // "two thirty p.m.", "nine oh five am", "ten forty five pm"
        var minuteParts: [String] = [], i = start + 1
        guard tokens[start].trailing.isEmpty else { return nil }
        var leadingOh = false
        while i < tokens.count, minuteParts.count < 2 {
            let word = tokens[i].word
            if minuteParts.isEmpty, word == "oh" || word == "o" { leadingOh = true; i += 1; continue }
            guard units[word] != nil || tens[word] != nil else { break }
            minuteParts.append(word)
            if !tokens[i].trailing.isEmpty { break }
            i += 1
        }
        guard !minuteParts.isEmpty, i < tokens.count, clockSuffixes.contains(tokens[i].word),
              tokens[i - 1].trailing.isEmpty,
              let minutes = value(minuteParts)?.value, minutes < 60,
              leadingOh ? minutes < 10 : minutes >= 10 else { return nil }
        return ("\(hour):\(String(format: "%02d", minutes)) \(tokens[i].raw)", i)
    }

    // MARK: Domains, paths, identifiers

    private static let tlds = "com|org|net|io|ai|co|app|dev|edu|gov|us|me|ly|so|xyz|tv|fm"

    /// "muckstack dot com" → "muckstack.com"; domains are lowercased.
    static func joinDomains(_ text: String) -> String {
        var result = replace(text, "(?i)\\b([a-z0-9-]+)\\s+dot\\s+(\(tlds))\\b") { groups in
            "\(groups[1].lowercased()).\(groups[2].lowercased())"
        }
        result = replace(result, "(?i)\\b([a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:\(tlds)))\\b") { $0[0].lowercased() }
        return result
    }

    /// "muckstack.com slash download" → "muckstack.com/download"; any spoken
    /// "slash" between two words becomes "/".
    static func joinPaths(_ text: String) -> String {
        var result = text
        for _ in 0..<6 {
            let next = replace(result, "(?i)(\\S+?)[,]?\\s+slash\\s+([A-Za-z0-9][\\w.-]*)") { "\($0[1])/\($0[2])" }
            if next == result { break }
            result = next
        }
        return result
    }

    /// "session underscore ID" → "session_id".
    static func joinIdentifiers(_ text: String) -> String {
        var result = text
        for _ in 0..<4 {
            let next = replace(result, "(?i)\\b([A-Za-z0-9_]+)\\s+underscore\\s+([A-Za-z0-9]+)\\b") { "\($0[1].lowercased())_\($0[2].lowercased())" }
            if next == result { break }
            result = next
        }
        return result
    }

    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            let replacement = transform(groups)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }
}
