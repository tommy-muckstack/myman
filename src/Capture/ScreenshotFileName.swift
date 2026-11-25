import Foundation

/// File names for saved screenshots, from a template such as "My Man {date} at {time}".
/// Tokens: {date} yyyy-MM-dd, {time} HH.mm.ss, {id} the first 8 characters of the capture ID.
/// Names never contain "/" or ":", and a name already on disk gets " 2", " 3", and so on.
enum ScreenshotFileName {
    static let key = "screenshotFileNameTemplate"
    static let defaultTemplate = "My Man {date} at {time}"

    static func template(_ defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultTemplate : value
    }

    static func render(_ template: String, date: Date, id: String, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.timeZone = timeZone; clock.dateFormat = "HH.mm.ss"
        var name = template
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: clock.string(from: date))
            .replacingOccurrences(of: "{id}", with: String(id.prefix(8)))
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\0")).joined(separator: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "My Man \(id.prefix(8))" : String(name.prefix(120))
    }

    /// A file URL in `folder` that does not exist yet.
    static func url(in folder: URL, template: String, date: Date, id: String, fileManager: FileManager = .default) -> URL {
        let base = render(template, date: date, id: id)
        var candidate = folder.appendingPathComponent(base + ".png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        return candidate
    }
}
