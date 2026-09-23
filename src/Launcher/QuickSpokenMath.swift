import Foundation

/// Only normalize a complete arithmetic vocabulary; prose remains prose.
enum QuickSpokenMath {
    static func expression(_ input: String) -> String? {
        var text = input.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^(?:please\s+)?(?:what(?:'s|s| is)|how much is|calculate)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        let operators = [("multiplied by", "*"), ("divided by", "/"), ("times", "*"), ("plus", "+"), ("minus", "-"), ("negative", "-"), ("percent", "%")]
        for (word, symbol) in operators {
            text = text.replacingOccurrences(of: "\\b" + word + "\\b", with: " " + symbol + " ", options: .regularExpression)
        }
        let small = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                     "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
                     "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        // A hyphen inside a spelled-out number is not subtraction.
        text = text.replacingOccurrences(of: #"([a-z])-([a-z])"#, with: "$1 $2", options: .regularExpression)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var output: [String] = []
        var group: [String] = []
        func number(_ words: [String]) -> String? {
            guard !words.isEmpty else { return nil }
            let parts = words.split(separator: "point", omittingEmptySubsequences: false)
            guard parts.count <= 2, !parts[0].isEmpty else { return nil }
            var total = 0, current = 0
            var previous: String?
            for word in parts[0] {
                if word == "and", previous == "hundred" || previous == "thousand" { previous = word; continue }
                if let value = small[word] {
                    if let previous, let before = small[previous], !(before >= 20 && before % 10 == 0 && value < 10) { return nil }
                    current += value
                } else if word == "hundred", (1...9).contains(current) { current *= 100 }
                else if word == "thousand", current > 0, total == 0 { total = current * 1000; current = 0 }
                else { return nil }
                previous = word
            }
            guard previous != "and" else { return nil }
            var result = String(total + current)
            if parts.count == 2 {
                guard !parts[1].isEmpty else { return nil }
                for word in parts[1] { guard let digit = small[word], digit < 10 else { return nil } }
                result += "." + parts[1].map { String(small[$0]!) }.joined()
            }
            return result
        }
        func flush() -> Bool {
            guard !group.isEmpty else { return true }
            guard let value = number(group) else { return false }
            output.append(value); group = []
            return true
        }
        for token in tokens {
            if small[token] != nil || ["hundred", "thousand", "and", "point"].contains(token) { group.append(token) }
            else {
                guard flush() else { return nil }
                guard ["+", "-", "*", "/", "%", "of", "off", "(", ")"].contains(token)
                        || token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.+-*/()×÷").contains($0) }) else { return nil }
                output.append(token)
            }
        }
        guard flush(), output.contains(where: { $0.contains(where: { "+-*/%×÷".contains($0) }) }) else { return nil }
        return output.joined(separator: " ")
    }
}
