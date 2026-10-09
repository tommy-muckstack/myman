import Foundation

struct QuickTimeZone: Equatable {
    let date: Date
    let source: TimeZone
    let destination: TimeZone
    let sourceName: String
    let destinationName: String

    /// Match the conversion direction. Implicit conversions start with the
    /// person's local time, so the arrow always reads input → answer.
    var displayZones: [(zone: TimeZone, name: String)] {
        let from = (zone: source, name: sourceName)
        let to = (zone: destination, name: destinationName)
        return [from, to]
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
        func result(_ date: Date, _ source: TimeZone, _ destination: TimeZone, _ from: String?, _ to: String?) -> QuickTool {
            .timeZone(Self(date: date, source: source, destination: destination,
                           sourceName: (from == nil ? "Your time · " : "") + label(source, requested: from, date: date),
                           destinationName: (to == nil ? "Your time · " : "") + label(destination, requested: to, date: date)))
        }
        if let match = groups(#"^(?:what time is it|current time|time|now) in (.+?)[?]?$"#, text) {
            guard let destination = zone(match[1], local: local) else { return unknown }
            return result(now, local, destination, nil, match[1])
        }
        guard let clock = groups(#"^(?:convert\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$"#, text) else { return nil }
        let rest = clock[4]
        // Do not intercept ordinary unit conversions, such as '8 m in km'.
        guard !clock[3].isEmpty || !clock[2].isEmpty || rest.hasPrefix("in ") || rest.hasPrefix("to ")
                || zone(rest, local: local) != nil
                || groups(#"^.+\s+(?:to|in)\s+.+$"#, rest) != nil && zone(rest.components(separatedBy: " ")[0], local: local) != nil
        else { return nil }
        var source = local
        var destination = local
        var sourceName: String?
        var destinationName: String?
        if let pair = groups(#"^(?:in\s+)?(.+?)\s+(?:to|in)\s+(.+)$"#, rest) {
            guard let from = zone(pair[1], local: local), let to = zone(pair[2], local: local) else { return unknown }
            source = from; destination = to
            sourceName = pair[1]; destinationName = pair[2]
        } else if rest.hasPrefix("to ") {
            guard let to = zone(String(rest.dropFirst(3)), local: local) else { return unknown }
            destination = to; destinationName = String(rest.dropFirst(3))
        } else {
            let name = rest.hasPrefix("in ") ? String(rest.dropFirst(3)) : rest
            guard let to = zone(name, local: local) else { return unknown }
            destination = to; destinationName = name
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
        if let city = cityAliases[cityKey(key)] { return TimeZone(identifier: city.zone) }
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

    private static func label(_ zone: TimeZone, requested: String?, date: Date) -> String {
        let key = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Foundation names fixed-offset EST/CST/PST zones GMT-0500/etc.
        // Keep the user's abbreviation: equal offsets do not imply equal names.
        if ["est", "edt", "cst", "cdt", "mst", "mdt", "pst", "pdt", "utc", "gmt"].contains(key) {
            return key.uppercased()
        }
        if key.hasPrefix("utc+") || key.hasPrefix("utc-") || key.hasPrefix("gmt+") || key.hasPrefix("gmt-") {
            return key.uppercased()
        }
        if let city = cityAliases[cityKey(key)] {
            return city.name + (zone.abbreviation(for: date).map { " · " + $0 } ?? "")
        }
        if let abbreviation = zone.abbreviation(for: date),
           ["EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT", "AKST", "AKDT", "HST"].contains(abbreviation),
           usRegions.contains(zone.identifier) || zone.identifier.hasPrefix("US/")
               || zone.identifier.hasPrefix("America/Indiana/") || zone.identifier.hasPrefix("America/Kentucky/")
               || zone.identifier.hasPrefix("America/North_Dakota/") {
            return abbreviation
        }
        if zone.identifier == "Atlantic/Reykjavik" { return "Iceland" }
        return zone.identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? zone.identifier
    }

    private static let usRegions: Set<String> = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
        "America/Detroit", "America/Phoenix", "America/Boise", "America/Anchorage",
        "America/Juneau", "America/Metlakatla", "America/Nome", "America/Sitka",
        "America/Yakutat", "America/Adak", "Pacific/Honolulu"
    ]

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

    /// IANA uses representative cities: Houston and DC don't have their own
    /// identifiers. Resolve common destinations to regional rules, not fixed
    /// offsets, and keep the requested city's name on the answer.
    private static let cityAliases: [String: (zone: String, name: String)] = [
        "houston": ("America/Chicago", "Houston"),
        "houston tx": ("America/Chicago", "Houston"),
        "houston texas": ("America/Chicago", "Houston"),
        "dallas": ("America/Chicago", "Dallas"),
        "austin": ("America/Chicago", "Austin"),
        "san antonio": ("America/Chicago", "San Antonio"),
        "fort worth": ("America/Chicago", "Fort Worth"),
        "dc": ("America/New_York", "Washington, DC"),
        "washington dc": ("America/New_York", "Washington, DC"),
        "washington d c": ("America/New_York", "Washington, DC"),
        "district of columbia": ("America/New_York", "Washington, DC"),
        "boston": ("America/New_York", "Boston"),
        "philadelphia": ("America/New_York", "Philadelphia"),
        "philly": ("America/New_York", "Philadelphia"),
        "baltimore": ("America/New_York", "Baltimore"),
        "atlanta": ("America/New_York", "Atlanta"),
        "miami": ("America/New_York", "Miami"),
        "orlando": ("America/New_York", "Orlando"),
        "tampa": ("America/New_York", "Tampa"),
        "charlotte": ("America/New_York", "Charlotte"),
        "raleigh": ("America/New_York", "Raleigh"),
        "pittsburgh": ("America/New_York", "Pittsburgh"),
        "new york city": ("America/New_York", "New York"),
        "nashville": ("America/Chicago", "Nashville"),
        "memphis": ("America/Chicago", "Memphis"),
        "new orleans": ("America/Chicago", "New Orleans"),
        "minneapolis": ("America/Chicago", "Minneapolis"),
        "st louis": ("America/Chicago", "St. Louis"),
        "saint louis": ("America/Chicago", "St. Louis"),
        "kansas city": ("America/Chicago", "Kansas City"),
        "milwaukee": ("America/Chicago", "Milwaukee"),
        "oklahoma city": ("America/Chicago", "Oklahoma City"),
        "salt lake city": ("America/Denver", "Salt Lake City"),
        "slc": ("America/Denver", "Salt Lake City"),
        "seattle": ("America/Los_Angeles", "Seattle"),
        "portland": ("America/Los_Angeles", "Portland"),
        "portland oregon": ("America/Los_Angeles", "Portland"),
        "portland maine": ("America/New_York", "Portland, Maine"),
        "las vegas": ("America/Los_Angeles", "Las Vegas"),
        "san diego": ("America/Los_Angeles", "San Diego"),
        "san jose": ("America/Los_Angeles", "San Jose"),
        "sacramento": ("America/Los_Angeles", "Sacramento"),
        "oakland": ("America/Los_Angeles", "Oakland"),
        "sf": ("America/Los_Angeles", "San Francisco"),
        "ottawa": ("America/Toronto", "Ottawa"),
        "calgary": ("America/Edmonton", "Calgary"),
        "manchester": ("Europe/London", "Manchester"),
        "edinburgh": ("Europe/London", "Edinburgh")
    ]

    private static func cityKey(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
