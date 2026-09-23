import Foundation

/// A small, deterministic vocabulary of useful cards. User input is data,
/// never executable code; incomplete requests stay editable.
enum QuickTool: Equatable {
    case note(String)
    case checklist([String])
    case timer(TimeInterval)
    case calculation(String, Double)
    case calculator
    case reminder(ReminderDraft)
    case conversion(String, Double, String)
    case timeZone(QuickTimeZone)
    case split(cents: Int, people: Int, currency: String)
    case color(String)
    case incomplete(String, String)

    var title: String {
        switch self {
        case .note: return "Note"
        case .checklist: return "Checklist"
        case .timer: return "Timer"
        case .calculation: return "Calculator"
        case .calculator: return "Calculator"
        case .reminder: return "Reminder"
        case .conversion: return "Converter"
        case .timeZone: return "Time zones"
        case .split: return "Split a bill"
        case .color: return "Color"
        case .incomplete(let title, _): return title
        }
    }

    var icon: MMIcon? {
        switch self {
        case .calculator, .calculation: return .calculator
        case .timer: return .timer
        case .reminder: return .reminder
        default: return nil
        }
    }

    var canSave: Bool {
        if case .calculator = self { return false }
        if case .reminder = self { return false }
        if case .incomplete = self { return false }
        if case .note(let text) = self { return !text.isEmpty }
        return true
    }

    var isTimer: Bool {
        if case .timer = self { return true }
        return false
    }

    func markdown(checked: Set<Int> = []) -> String {
        switch self {
        case .note(let text): return text
        case .checklist(let items):
            return "Checklist\n\n" + items.enumerated().map { "- [\(checked.contains($0.offset) ? "x" : " ")] \($0.element)" }.joined(separator: "\n")
        case .timer(let seconds): return "Timer\n\n\(Self.number(seconds / 60)) minutes"
        case .calculation(let expression, let result): return "\(expression) = \(Self.number(result))"
        case .calculator: return ""
        case .reminder(let draft): return "\(draft.title)\n\(draft.date.formatted())"
        case .conversion(let input, let value, let unit): return "\(input) = \(Self.number(value)) \(unit)"
        case .timeZone(let conversion): return conversion.markdown
        case .split(let cents, let people, let currency):
            return "Split a bill\n\n\(currency)\(Self.money(cents)) between \(people) people\n\n\(Self.splitSummary(cents: cents, people: people, currency: currency))"
        case .color(let hex): return hex
        case .incomplete(_, let help): return help
        }
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...10)))
    }

    static func money(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }

    static func splitSummary(cents: Int, people: Int, currency: String) -> String {
        let base = cents / people, remainder = cents % people
        if remainder == 0 { return "\(currency)\(money(base)) each" }
        return "\(people - remainder) × \(currency)\(money(base))\n\(remainder) × \(currency)\(money(base + 1))"
    }
}

enum QuickToolParser {
    static let examples = ["buy milk, eggs and coffee", "25 min focus", "18% of 240", "5 miles in km", "8am in Iceland", "split $120 between 3", "#ff6b35"]

    static func parse(_ input: String) -> QuickTool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2_000 else { return .incomplete("Quick Tools", "Keep this request under 2,000 characters.") }
        let lower = QuickTimerRequest.commandText(text).lowercased().replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)

        if ["calculator", "calc", "calculate"].contains(lower) { return .calculator }
        if ["convert", "converter", "unit converter"].contains(lower) { return .incomplete("Converter", "Enter a conversion, such as 5 miles in km.") }
        if ["time zones", "timezone", "time zone"].contains(lower) { return .incomplete("Time zones", "Enter a time and place, such as 8am in Iceland.") }
        if ["color", "colour", "color palette"].contains(lower) { return .incomplete("Color", "Enter a hex color, such as #ff6b35.") }
        if lower == "checklist" { return .incomplete("Checklist", "Add items separated by commas.") }
        if let prefix = ["calculator ", "calc "].first(where: lower.hasPrefix) {
            return parse("calculate " + String(lower.dropFirst(prefix.count)))
        }
        if let draft = ReminderDraft.parse(text) { return .reminder(draft) }

        if lower.hasPrefix("split ") || lower == "split" {
            guard let parts = groups(#"^split\s+([$€£]?)\s*(\d+(?:\.\d{1,2})?)\s+(?:between|among|by)\s+(\d+)\s*(?:people)?$"#, lower),
                  let amount = Double(parts[2]), amount > 0, amount <= 1_000_000_000,
                  let people = Int(parts[3]), (1...1_000).contains(people) else {
                return .incomplete("Split a bill", "Try “split $120 between 3” with 1–1,000 people and at most two decimal places.")
            }
            return .split(cents: Int((amount * 100).rounded()), people: people, currency: parts[1])
        }

        if lower.hasPrefix("#") || lower.hasPrefix("color ") || lower.hasPrefix("colour ") {
            let hex = lower.replacingOccurrences(of: #"^colou?r\s+"#, with: "", options: .regularExpression)
            guard groups(#"^#([0-9a-f]{3}|[0-9a-f]{6})$"#, hex) != nil else {
                return .incomplete("Color", "Enter a hex color, such as #ff6b35 or #abc.")
            }
            let digits = String(hex.dropFirst())
            return .color("#" + (digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits).uppercased())
        }

        if let parts = groups(#"^(?:buy|groceries|checklist|todo|to do)\s*:?\s+(.+)$"#, text, dotMatchesNewlines: true) {
            let items = parts[1].components(separatedBy: try! NSRegularExpression(pattern: #",|\n|\s+and\s+"#, options: .caseInsensitive))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !items.isEmpty { return .checklist(items) }
        }

        if let seconds = duration(lower) { return .timer(seconds) }
        if lower == "timer" || lower.hasPrefix("timer ") || lower.hasPrefix("set a timer") {
            return .incomplete("Timer", "Try “25 min focus” or “timer 1 hour 30 minutes” (up to 24 hours).")
        }

        if let timeZone = QuickTimeZone.parse(lower) { return timeZone }

        if let parts = groups(#"^(?:convert\s+)?(-?\d+(?:\.\d+)?)\s*([a-z°]+)\s+(?:in|to|into)\s+([a-z°]+)$"#, lower),
           let value = Double(parts[1]), value.isFinite {
            guard let from = units[parts[2]], let to = units[parts[3]], from.family == to.family else {
                return .incomplete("Converter", "Use compatible length, weight, or temperature units, such as “5 miles in km” or “72 f to c”.")
            }
            let result = (value * from.scale + from.offset - to.offset) / to.scale
            guard result.isFinite else { return .incomplete("Converter", "That value is too large.") }
            return .conversion("\(parts[1]) \(parts[2])", result, parts[3])
        }
        if lower.hasPrefix("convert ") { return .incomplete("Converter", "Try “5 miles in km”, “150 lb to kg”, or “72 f to c”.") }

        let expression = QuickSpokenMath.expression(lower) ?? lower.replacingOccurrences(of: #"^(?:calculate|what is|what[’']?s)\s+"#, with: "", options: .regularExpression)
        if let parts = groups(#"^(-?\d+(?:\.\d+)?)\s*%\s+(of|off)\s+(-?\d+(?:\.\d+)?)$"#, expression),
           let percent = Double(parts[1]), let amount = Double(parts[3]) {
            let result = parts[2] == "off" ? amount * (1 - percent / 100) : amount * percent / 100
            if result.isFinite { return .calculation(expression, result) }
        }
        let mathCharacters = CharacterSet(charactersIn: "0123456789.+-*/() ×÷x\t")
        let isMath = !expression.isEmpty && expression.unicodeScalars.allSatisfy { mathCharacters.contains($0) }
        let hasOperator = expression.contains { "+-*/()×÷x".contains($0) }
        if (isMath && hasOperator) || lower.hasPrefix("calculate ") {
            var calculator = QuickCalculator(expression)
            if let result = calculator.result() { return .calculation(expression, result) }
            return .incomplete("Calculator", "Use numbers with +, −, *, / and parentheses. Division by zero has no result.")
        }
        return .note(text)
    }

    static func duration(_ text: String) -> TimeInterval? {
        var rest = QuickTimerRequest.commandText(text).lowercased()
            .replacingOccurrences(of: #"^(?:(?:set|start)\s+(?:me\s+)?(?:a\s+)?)?timer(?:\s+for)?\s+"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"\s+(?:focus|break|timer)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
        let regex = try! NSRegularExpression(pattern: #"^((?:\d+(?:\.\d+)?|[a-z]+)(?:\s+[a-z]+)*?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#)
        var seconds = 0.0
        while !rest.isEmpty {
            guard let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return nil }
            guard let numberRange = Range(match.range(at: 1), in: rest), let unitRange = Range(match.range(at: 2), in: rest),
                  let amount = QuickSpokenMath.numberValue(String(rest[numberRange])), amount >= 0 else { return nil }
            let unit = rest[unitRange]
            seconds += amount * (unit.hasPrefix("h") ? 3_600 : unit.hasPrefix("m") ? 60 : 1)
            guard let matched = Range(match.range, in: rest) else { return nil }
            rest = String(rest[matched.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("and ") { rest = String(rest.dropFirst(4)) }
        }
        guard seconds.isFinite, seconds >= 1, seconds <= 86_400 else { return nil }
        return seconds.rounded()
    }

    private struct Unit {
        let family: Int
        let scale: Double
        var offset: Double = 0
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        let definitions: [(String, Unit)] = [
            ("m meter meters metre metres", Unit(family: 0, scale: 1)),
            ("km kilometer kilometers kilometre kilometres", Unit(family: 0, scale: 1_000)),
            ("cm", Unit(family: 0, scale: 0.01)), ("mm", Unit(family: 0, scale: 0.001)),
            ("mi mile miles", Unit(family: 0, scale: 1_609.344)),
            ("ft foot feet", Unit(family: 0, scale: 0.3048)), ("in inch inches", Unit(family: 0, scale: 0.0254)),
            ("yd yard yards", Unit(family: 0, scale: 0.9144)),
            ("kg kilogram kilograms", Unit(family: 1, scale: 1)),
            ("g gram grams", Unit(family: 1, scale: 0.001)),
            ("lb lbs pound pounds", Unit(family: 1, scale: 0.45359237)),
            ("oz ounce ounces", Unit(family: 1, scale: 0.028349523125)),
            ("c °c celsius", Unit(family: 2, scale: 1)),
            ("f °f fahrenheit", Unit(family: 2, scale: 5.0 / 9, offset: -32 * 5.0 / 9)),
            ("k kelvin", Unit(family: 2, scale: 1, offset: -273.15))
        ]
        for (aliases, unit) in definitions {
            for alias in aliases.split(separator: " ") { result[String(alias)] = unit }
        }
        return result
    }()

    private static func groups(_ pattern: String, _ text: String, dotMatchesNewlines: Bool = false) -> [String]? {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: "\u{001F}")
            .components(separatedBy: "\u{001F}")
    }
}

/// Bounded recursive descent; no NSExpression, JavaScript, or shell evaluation.
private struct QuickCalculator {
    private var characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text.filter { !$0.isWhitespace }.map { char -> Character in
            if char == "×" || char == "x" { return "*" }
            if char == "÷" { return "/" }
            return char
        })
    }

    mutating func result() -> Double? {
        guard !characters.isEmpty, characters.count <= 300,
              let value = sum(depth: 0), index == characters.count, value.isFinite else { return nil }
        return value
    }

    private mutating func sum(depth: Int) -> Double? {
        guard var value = product(depth: depth) else { return nil }
        while index < characters.count, characters[index] == "+" || characters[index] == "-" {
            let operation = characters[index]; index += 1
            guard let right = product(depth: depth) else { return nil }
            value = operation == "+" ? value + right : value - right
        }
        return value
    }

    private mutating func product(depth: Int) -> Double? {
        guard var value = atom(depth: depth) else { return nil }
        while index < characters.count, characters[index] == "*" || characters[index] == "/" {
            let operation = characters[index]; index += 1
            guard let right = atom(depth: depth), operation != "/" || right != 0 else { return nil }
            value = operation == "*" ? value * right : value / right
        }
        return value
    }

    private mutating func atom(depth: Int) -> Double? {
        guard depth < 32, index < characters.count else { return nil }
        let char = characters[index]
        if char == "+" || char == "-" {
            index += 1
            return atom(depth: depth + 1).map { char == "-" ? -$0 : $0 }
        }
        if char == "(" {
            index += 1
            guard let value = sum(depth: depth + 1), index < characters.count, characters[index] == ")" else { return nil }
            index += 1
            return value
        }
        let start = index
        while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
        guard start != index else { return nil }
        return Double(String(characters[start..<index]))
    }
}
