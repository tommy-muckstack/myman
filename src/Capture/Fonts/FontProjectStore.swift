import AppKit
import CoreText
import ImageIO
import GRDB

/// A saved font is a normal indexed note with document-owned assets. Deleting
/// that note uses CaptureLifecycle to trash the project, images and font too.
enum FontProjectStore {
    static func asset(_ noteID: String, _ name: String) -> URL? {
        guard UUID(uuidString: noteID) != nil else { return nil }
        return DocumentAssets.shared.resolve("../assets/note-\(noteID)/\(name)")
    }
    static func exists(_ id: String) -> Bool { asset(id, "font-project.json").map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static func load(_ id: String) throws -> [String: Any] {
        guard CaptureLifecycle.exists(kind: "note", id: id), let url = asset(id, "font-project.json"),
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 48 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], value["version"] as? Int == 1 else { throw AgentError("NOT_FOUND", "Saved font project is unavailable.") }
        guard let state = value["state"] as? [String: Any] else { throw AgentError("INVALID_PROJECT", "Missing saved state.") }
        try validateState(state)
        return value
    }
    static func validateState(_ state: [String: Any]) throws {
        guard state["version"] as? Int == 1, let name = state["name"] as? String, name.count <= 64,
              let mode = state["mode"] as? String, ["captured", "completed"].contains(mode),
              let samples = state["samples"] as? [[String: Any]], samples.count <= 1800,
              let preview = state["preview"] as? String, preview.count <= 20000,
              let excluded = state["excluded"] as? [String], excluded.count <= 95,
              let replacements = state["replacements"] as? [String], replacements.count <= 95 else { throw AgentError("INVALID_PROJECT", "Invalid saved font state.") }
        var pixels = 0
        for sample in samples {
            guard (sample["char"] is NSNull || (sample["char"] as? String).map { $0.count <= 1 && $0.unicodeScalars.allSatisfy { (33...126).contains($0.value) } } == true),
                  let imageID = sample["imageId"] as? Int, (0...2).contains(imageID),
                  let bbox = sample["bbox"] as? [String: Double], ["x", "y", "w", "h"].allSatisfy({ bbox[$0]?.isFinite == true }),
                  let encoded = sample["png"] as? String, encoded.count <= 4 * 1024 * 1024,
                  let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, Double(width) * Double(height) <= 4_000_000 else { throw AgentError("INVALID_PROJECT", "Invalid saved character sample.") }
            pixels += width * height
            guard pixels <= 32_000_000 else { throw AgentError("TOO_LARGE", "Saved character samples exceed the pixel limit.") }
        }
    }
    static func validate(_ font: Data) throws {
        guard font.count > 100, font.count <= 16 * 1024 * 1024, font.prefix(4) == Data("OTTO".utf8),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(font as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else { throw AgentError("INVALID_FONT", "The generated file is not a valid OpenType CFF font.") }
    }
    @MainActor static func save(font: Data, name: String, state: [String: Any], provenance: [[String: Any]], images: [Data], sourceTitle: String) throws -> (Note, URL) {
        try validate(font)
        try validateState(state)
        guard images.count <= 3, state["version"] as? Int == 1 else { throw AgentError("INVALID_PROJECT", "Invalid font project.") }
        let projectData = try JSONSerialization.data(withJSONObject: state)
        guard projectData.count <= 40 * 1024 * 1024 else { throw AgentError("TOO_LARGE", "Font project exceeds 40 MiB.") }
        var note = Note(body: "Font · " + String(name.prefix(64)))
        let documentID = "note-" + note.id
        var owned: [URL] = []
        do {
            var refs: [String] = []
            for data in images {
                let ref = try DocumentAssets.shared.importImage(data: data, documentID: documentID); refs.append(ref)
                if let url = DocumentAssets.shared.resolve(ref) { owned.append(url) }
            }
            guard let projectURL = asset(note.id, "font-project.json"), let fontURL = asset(note.id, "font.otf") else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: fontURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let container: [String: Any] = ["version": 1, "state": state, "images": refs, "provenance": provenance]
            try JSONSerialization.data(withJSONObject: container, options: [.sortedKeys]).write(to: projectURL, options: .atomic); owned.append(projectURL)
            try font.write(to: fontURL, options: .atomic); owned.append(fontURL)
            let counts = Dictionary(grouping: provenance, by: { $0["source"] as? String ?? "missing" }).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
            let matches = Set(provenance.compactMap { $0["sourceFont"] as? String }.filter { !$0.isEmpty }).sorted().joined(separator: ", ")
            note.body += "\n\nFonts · Screenshot typography · OpenType (.otf)\n\nSource: \(sourceTitle)\n\nCoverage: \(counts). Inferred letters are approximations; review before use.\n\nCaptured characters: \(provenance.filter { $0["source"] as? String == "traced" }.compactMap { $0["char"] as? String }.joined())\n\n"
            if !matches.isEmpty { note.body += "External fallback fonts: \(matches). Font file includes applicable license notices.\n\n" }
            note.body += "Open this note’s actions menu to edit the font or open it in Font Book.\n\n" + refs.enumerated().map { "![Font sample \($0.offset + 1)](\($0.element))" }.joined(separator: "\n\n")
            try Database.shared.write { try note.insert($0) }
            Brain.syncNote(id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
            return (note, fontURL)
        } catch { for url in owned { try? FileManager.default.removeItem(at: url) }; throw error }
    }
}
