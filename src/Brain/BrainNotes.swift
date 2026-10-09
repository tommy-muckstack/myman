import AppKit
import CryptoKit
import Foundation
import GRDB

// Brainz (the notes app next to My Man) keeps a person's brain as a folder
// of Markdown files. My Man mirrors those files into its own capture index
// so search, the pre-meeting brief and the in-meeting context stream can
// point back at them. The files are read, never written.

struct BrainNote: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "brainNote"
    var id: String
    var path: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var mtime: Double
    var size: Int

    /// Stable, path-derived id so a rename produces a new row and the old
    /// one is removed on the same scan.
    static func id(forPath path: String) -> String {
        String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Title from the first `# ` heading, else a `title:` front-matter key,
    /// else the file name. Body drops a leading `---` front-matter block.
    static func parse(markdown: String, filename: String) -> (title: String, body: String) {
        var lines = markdown.components(separatedBy: .newlines)
        var frontMatterTitle: String?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                for line in lines[1..<end] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().hasPrefix("title:") {
                        frontMatterTitle = String(trimmed.dropFirst("title:".count))
                            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                }
                lines.removeSubrange(0...end)
            }
        }
        var heading: String?
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }) {
            heading = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.remove(at: index)
        }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let title = [heading, frontMatterTitle].compactMap { $0 }.first { !$0.isEmpty } ?? stem
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }
}

/// Where the Brainz app's workspace folder is, and how to open a note in it.
enum BrainWorkspace {
    /// Written by Brainz when it opens a brain: `{"root": "/path/to/brain"}`.
    static var pointerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brainz/workspace.json")
    }

    /// The folder to index. A folder the person picked wins; otherwise the
    /// pointer Brainz wrote; otherwise Brainz's default `~/brain` when it
    /// holds a `brainz.toml`.
    static func discover(pickedPath: String?, fileManager: FileManager = .default,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         pointer: URL? = nil) -> URL? {
        if let pickedPath, !pickedPath.isEmpty {
            let url = URL(fileURLWithPath: (pickedPath as NSString).expandingTildeInPath)
            if isWorkspace(url, fileManager: fileManager) { return url }
        }
        if let data = try? Data(contentsOf: pointer ?? pointerURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = object["root"] as? String, !root.isEmpty {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            if isWorkspace(url, fileManager: fileManager) { return url }
        }
        let fallback = home.appendingPathComponent("brain", isDirectory: true)
        if fileManager.fileExists(atPath: fallback.appendingPathComponent("brainz.toml").path) { return fallback }
        return nil
    }

    /// A brain is a folder with `brainz.toml` or Markdown files in its top
    /// two levels. An empty folder is not one.
    static func isWorkspace(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if fileManager.fileExists(atPath: url.appendingPathComponent("brainz.toml").path) { return true }
        guard let top = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { return false }
        for entry in top {
            if isMarkdown(entry) { return true }
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
               nested.contains(where: isMarkdown) { return true }
        }
        return false
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    static var brainzApplication: URL? {
        let candidates = ["/Applications/Brainz.app",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Brainz.app").path]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Opens the note in Brainz when it is installed, otherwise in whatever
    /// handles Markdown. A missing file shows a toast rather than nothing.
    @MainActor static func open(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            Toast.show("The original note is missing", systemImage: "exclamationmark.triangle")
            return
        }
        if let app = brainzApplication {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
