import Foundation

struct QuickTimeZone: Equatable {
    let date: Date
    let source: TimeZone
    let destination: TimeZone
    let sourceName: String
    let destinationName: String

    /// Present the eastern (larger UTC offset) zone first, using the conversion
    /// date so regional daylight-saving rules are reflected in the ordering.
    var displayZones: [(zone: TimeZone, name: String)] {
        let from = (zone: source, name: sourceName)
        let to = (zone: destination, name: destinationName)
        return source.secondsFromGMT(for: date) >= destination.secondsFromGMT(for: date)
            ? [from, to] : [to, from]
    }

    func time(in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func day(in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    var markdown: String {
        "\(sourceName): \(time(in: source)), \(day(in: source))\n\(destinationName): \(time(in: destination)), \(day(in: destination))"
    }

    /// The date is today's date in the source zone. Region identifiers use
    /// macOS's time-zone database, including daylight saving for that date.
    static func parse(_ input: String, now: Date = Date(), local: TimeZone = .current) -> QuickTool? {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func result(_ date: Date, _ source: TimeZone, _ destination: TimeZone, _ from: String, _ to: String) -> QuickTool {
            .timeZone(Self(date: date, source: source, destination: destination,
                           sourceName: from, destinationName: to))
        }
        let localName = "Your time · " + localLabel(local)
        if let match = groups(#"^(?:what time is it|current time|time|now) in (.+?)[?]?$"#, text) {
            guard let destination = zone(match[1], local: local) else { return unknown }
            return result(now, local, destination, localName, label(destination))
        }
        guard let clock = groups(#"^(?:convert\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$"#, text) else { return nil }
        let rest = clock[4]
        // Do not intercept ordinary unit conversions, such as '8 m in km'.
        guard !clock[3].isEmpty || !clock[2].isEmpty || rest.hasPrefix("in ") || rest.hasPrefix("to ")
                || groups(#"^.+\s+(?:to|in)\s+.+$"#, rest) != nil && zone(rest.components(separatedBy: " ")[0], local: local) != nil
        else { return nil }
        var source = local
        var destination = local
        var sourceName = localName
        var destinationName = localName
        if let pair = groups(#"^(?:in\s+)?(.+?)\s+(?:to|in)\s+(.+)$"#, rest) {
            guard let from = zone(pair[1], local: local), let to = zone(pair[2], local: local) else { return unknown }
            source = from; destination = to
            sourceName = label(from); destinationName = label(to)
        } else if rest.hasPrefix("to ") {
            guard let to = zone(String(rest.dropFirst(3)), local: local) else { return unknown }
            destination = to; destinationName = label(to)
        } else {
            let name = rest.hasPrefix("in ") ? String(rest.dropFirst(3)) : rest
            guard let from = zone(name, local: local) else { return unknown }
            source = from; sourceName = label(from)
        }
        guard var hour = Int(clock[1]), let minute = Int(clock[2].isEmpty ? "0" : clock[2]), (0...59).contains(minute),
              clock[3].isEmpty ? (0...23).contains(hour) : (1...12).contains(hour) else {
            return .incomplete("Time zones", "Use a time such as 8am or 14:30.")
        }
        if !clock[3].isEmpty { hour = hour % 12 + (clock[3] == "pm" ? 12 : 0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour; parts.minute = minute; parts.second = 0
        guard let date = calendar.date(from: parts), calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute else {
            return .incomplete("Time zones", "That time is skipped by today's daylight saving change.")
        }
        // A fall-back hour occurs twice. Ask for a fixed offset rather than
        // quietly picking one of two different answers.
        if [1_800.0, 3_600, 7_200].contains(where: {
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date.addingTimeInterval($0)) == parts
        }) {
            return .incomplete("Time zones", "That time occurs twice today. Use an explicit UTC offset, such as UTC-04:00.")
        }
        return result(date, source, destination, sourceName, destinationName)
    }

    private static var unknown: QuickTool {
        .incomplete("Time zones", "Use a city or region, such as “8am in Iceland” or “8am New York to London”.")
    }

    static func zone(_ input: String, local: TimeZone) -> TimeZone? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["here", "local", "my time"].contains(key) { return local }
        if let id = aliases[key] { return TimeZone(identifier: id) }
        // Fixed abbreviations retain their literal offsets; use ET/PT or city
        // names when the region's daylight saving rules should apply.
        let offsets = ["utc": 0, "gmt": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5,
                       "mst": -7, "mdt": -6, "pst": -8, "pdt": -7]
        if let hours = offsets[key] { return TimeZone(secondsFromGMT: hours * 3_600) }
        if let offset = groups(#"^(?:utc|gmt)([+-])(\d{1,2})(?::(\d{2}))?$"#, key),
           let hours = Int(offset[2]), let minutes = Int(offset[3].isEmpty ? "0" : offset[3]),
           hours <= 14, minutes < 60, hours < 14 || minutes == 0 {
            return TimeZone(secondsFromGMT: (offset[1] == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60))
        }
        let matches = TimeZone.knownTimeZoneIdentifiers.filter {
            $0.lowercased() == key || $0.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ").lowercased() == key
        }
        return matches.count == 1 ? TimeZone(identifier: matches[0]) : nil
    }

    /// The Mac's own zone is named for the region, not a city: macOS stores
    /// Boston as America/New_York, so "New York" would name the wrong place.
    static func localLabel(_ zone: TimeZone) -> String {
        zone.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? label(zone)
    }

    private static func label(_ zone: TimeZone) -> String {
        if zone.identifier == "Atlantic/Reykjavik" { return "Iceland" }
        return zone.identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? zone.identifier
    }

    private static let aliases = [
        "iceland": "Atlantic/Reykjavik", "reykjavik": "Atlantic/Reykjavik",
        "new york": "America/New_York", "nyc": "America/New_York", "et": "America/New_York", "eastern": "America/New_York",
        "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles", "pt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "chicago": "America/Chicago", "ct": "America/Chicago",
        "denver": "America/Denver", "mt": "America/Denver", "london": "Europe/London", "uk": "Europe/London",
        "paris": "Europe/Paris", "france": "Europe/Paris", "berlin": "Europe/Berlin", "germany": "Europe/Berlin",
        "india": "Asia/Kolkata", "ist": "Asia/Kolkata", "delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai",
        "dubai": "Asia/Dubai", "singapore": "Asia/Singapore", "sydney": "Australia/Sydney",
        "auckland": "Pacific/Auckland", "new zealand": "Pacific/Auckland"
    ]

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
