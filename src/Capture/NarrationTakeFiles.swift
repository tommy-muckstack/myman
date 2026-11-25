import Foundation

/// Plain files for narration takes, in MyManBrain/narrations, so an agent or a Paper doc can read them
/// without the bridge: each take's video and metadata, a copy of the newest take's metadata as latest.json,
/// and a current.json while a take is running.
enum NarrationTakeFiles {
    /// Newest takes kept in the folder; older ones are removed.
    static let keep = 20

    static var folder: URL { Brain.root.appendingPathComponent("narrations", isDirectory: true) }
    static var currentURL: URL { folder.appendingPathComponent("current.json") }

    /// Written when a take starts and updated when it pauses or resumes.
    static func writeCurrent(id: String, label: String?, request: String?, state: String, startedAtEpochMs: Int64?) {
        let body: [String: Any] = [
            "id": id,
            "label": label ?? NSNull(),
            "request": request ?? NSNull(),
            "state": state,
            "startedAtEpochMs": startedAtEpochMs ?? NSNull(),
        ]
        write(body, to: currentURL)
    }

    static func clearCurrent() {
        try? FileManager.default.removeItem(at: currentURL)
    }

    /// Copies a finished take into the folder with its metadata, updates latest.json, and keeps the newest takes.
    /// `metadata` is the take's result (id, label, request, startedAtEpochMs, durationMs, bytes, mimeType,
    /// width, height, stoppedBy, stopReason).
    @discardableResult
    static func publish(movie: URL, metadata: [String: Any], in folder: URL = folder) throws -> URL {
        guard let id = metadata["id"] as? String else { throw AgentError("INTERNAL", "Take has no id.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent(id + ".mp4")
        if FileManager.default.fileExists(atPath: video.path) { try FileManager.default.removeItem(at: video) }
        try FileManager.default.copyItem(at: movie, to: video)
        let json = folder.appendingPathComponent(id + ".json")
        write(metadata, to: json)
        write(metadata, to: folder.appendingPathComponent("latest.json"))
        prune(in: folder)
        return video
    }

    /// Removes takes beyond the newest `keep`, by when their video was written.
    static func prune(in folder: URL = folder) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let videos = files.filter { $0.pathExtension == "mp4" }
            .sorted { modified($0) > modified($1) }
        for old in videos.dropFirst(keep) {
            let id = old.deletingPathExtension().lastPathComponent
            for url in [old, folder.appendingPathComponent(id + ".json")] {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func write(_ body: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
