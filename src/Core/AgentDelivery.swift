import Foundation

/// Hands a finished capture, narration take or clip to Claude through the Brain folder.
/// Files are copied into artifacts/<id>/ with a result.json that names them, so Claude reads
/// one folder instead of hunting through the app's own storage. Each file is capped at the size
/// Claude's tool upload takes. Delivery is a sharing action: it always asks and is never remembered.
enum AgentDelivery {
    static let toolUploadLimit = 15_000_000
    static let targets = ["claude"]
    static let labelPattern = "^[A-Za-z0-9._-]{1,80}$"

    static func isValidLabel(_ label: String) -> Bool {
        label.range(of: labelPattern, options: .regularExpression) != nil
    }

    /// Writes the result beside the media it describes. Returns its path so the log can point at it.
    static func writeResult(_ result: [String: Any], id: String, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(id + ".result.json")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: .atomic)
        return url
    }

    static func deliver(id: String, to target: String,
                        brain: URL = Brain.root.appendingPathComponent("agent", isDirectory: true),
                        log: URL = AgentChangeLog.defaultURL) throws -> [String: Any] {
        guard targets.contains(target) else { throw AgentError("INVALID_ARGUMENTS", "to must be one of: \(targets.joined(separator: ", ")).") }
        guard let entry = try AgentChangeLog.load(log).last(where: { $0.id == id && $0.kind != "delivery" }) else {
            throw AgentError("NOT_FOUND", "Nothing recorded with id \(id). Use changes.since to find ids.")
        }
        let folder = brain.appendingPathComponent("artifacts/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [[String: Any]] = []
        // Check every file before copying any, so a refused delivery leaves nothing half-written.
        for (role, path) in entry.paths.sorted(by: { $0.key < $1.key }) {
            let bytes = fileSize(path)
            guard bytes > 0 else { throw AgentError("NOT_FOUND", "The \(role) file for \(id) is missing. Capture it again.") }
            guard bytes <= toolUploadLimit else {
                throw AgentError("TOO_LARGE", "The \(role) file is \(bytes / 1_000_000) MB. Claude takes files up to 15 MB. Capture a shorter or smaller version.")
            }
        }
        for (role, path) in entry.paths.sorted(by: { $0.key < $1.key }) {
            let source = URL(fileURLWithPath: path)
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            files.append(["role": role, "name": source.lastPathComponent, "bytes": fileSize(path), "path": "artifacts/\(id)/\(source.lastPathComponent)"])
        }
        let delivered = ISO8601DateFormatter().string(from: Date())
        let summary: [String: Any] = ["id": id, "kind": entry.kind, "delivered_to": target, "delivered_at": delivered, "files": files]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        try AgentChangeLog.append(kind: "delivery", id: id, readyFor: target, paths: ["folder": folder.path], at: delivered, url: log)
        return ["id": id, "folder": folder.path, "result": "artifacts/\(id)/result.json", "files": files, "ready_for": target]
    }

    private static func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}
