import Foundation
import CryptoKit

/// Owner-only, bounded receipts outside Brain. A receipt is written before a
/// mutation starts. Interrupted work is never replayed on the agent's behalf.
@MainActor final class AgentJournal {
    static let shared = AgentJournal()
    let root: URL
    private var entries: [String: [String: Any]] = [:]
    private var sessions: [String: [String: Any]] = [:]
    private var loadError = false
    private var timer: Timer?
    init(root: URL? = nil) {
        self.root = root ?? (VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")).appendingPathComponent("AgentReceipts")
        let file = self.root.appendingPathComponent("receipts.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 32 * 1024 * 1024,
                      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], value["version"] as? Int == 1,
                      let jobs = value["jobs"] as? [String: [String: Any]], let saved = value["sessions"] as? [String: [String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                entries = jobs; sessions = saved
                for id in entries.keys {
                    guard var job = entries[id]?["job"] as? [String: Any] else { continue }
                    if job["state"] as? String == "running" { job["state"] = "interrupted"; job["error"] = ["code":"APP_RESTARTED", "message":"Work was interrupted. Inspect saved artifacts; do not replay this request."] }
                    entries[id]?["job"] = Self.expirePreviews(job)
                }
                prune(); try save()
            } catch { loadError = true }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.prune() else { return }
                try? self.save()
            }
        }
    }
    deinit { timer?.invalidate() }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func prior(_ id: String, fingerprint: Data) throws -> [String: Any]? {
        guard !loadError else { throw AgentError("RECOVERY_UNAVAILABLE", "The receipt store cannot be read. Inspect saved artifacts before retrying work.") }
        prune()
        guard let entry = entries[id] else { return nil }
        guard entry["fingerprint"] as? String == Self.digest(fingerprint) else { throw AgentError("ID_CONFLICT", "This request ID was used with different arguments.") }
        return entry["job"] as? [String: Any]
    }
    func begin(_ id: String, action: String, fingerprint: Data, owner: String = "local") throws {
        guard !loadError else { throw AgentError("RECOVERY_UNAVAILABLE", "Cannot safely record this request.") }
        entries[id] = ["at": Date().timeIntervalSince1970, "fingerprint": Self.digest(fingerprint), "job": ["id": id, "action": action, "state": "running", "owner": owner]]
        do { try save() } catch { entries[id] = nil; throw AgentError("RECOVERY_UNAVAILABLE", "Cannot save the request receipt; no action started.") }
    }
    func finish(_ id: String, job: [String: Any]) -> Bool {
        guard entries[id] != nil else { return false }
        var result = job
        if let data = try? JSONSerialization.data(withJSONObject: result), data.count > 64 * 1024 {
            let original = result["result"] as? [String: Any] ?? [:]
            result["result"] = original.filter { ["id","path","session_id","kind"].contains($0.key) }.merging(["recovery_status":"large_result_omitted", "message":"Read the saved item again; inline data was not persisted."]) { a, _ in a }
        }
        entries[id]?["job"] = result
        do { try save(); return true } catch { return false }
    }
    func job(_ id: String) -> [String: Any]? { prune(); return entries[id]?["job"] as? [String: Any] }
    func list() -> [[String: Any]] {
        prune()
        return entries.values.sorted { ($0["at"] as? Double ?? 0) > ($1["at"] as? Double ?? 0) }.compactMap { entry in
            guard let job = entry["job"] as? [String: Any] else { return nil }
            return ["id":job["id"] ?? NSNull(), "action":job["action"] ?? NSNull(), "state":job["state"] ?? NSNull(), "owner":job["owner"] ?? "local", "created_at":AgentActions.date(Date(timeIntervalSince1970: entry["at"] as? Double ?? 0))]
        }
    }
    func saveSession(_ id: String, result: [String: Any]) -> Bool {
        sessions[id] = ["at":Date().timeIntervalSince1970, "result":result]
        do { try save(); return true } catch { return false }
    }
    func session(_ id: String) -> [String: Any]? { prune(); return sessions[id]?["result"] as? [String: Any] }
    func purgeContent() {
        for id in entries.keys {
            guard var job = entries[id]?["job"] as? [String: Any], job["state"] as? String != "running" else { continue }
            job["result"] = nil; job["state"] = "failed"
            job["error"] = ["code":"CONTENT_REMOVED", "message":"Results were cleared after content was deleted or excluded. Do not replay this request."]
            entries[id]?["job"] = job
        }
        sessions.removeAll()
        do { try save() } catch {
            // Remove stale content on disk even if an atomic rewrite failed.
            try? FileManager.default.removeItem(at: root.appendingPathComponent("receipts.json")); loadError = true
        }
    }
    @discardableResult private func prune() -> Bool {
        let oldJobs = entries.count, oldSessions = sessions.count
        let cutoff = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        entries = entries.filter { ($0.value["at"] as? Double ?? 0) >= cutoff }
        sessions = sessions.filter { ($0.value["at"] as? Double ?? 0) >= cutoff }
        let terminal = entries.filter { ($0.value["job"] as? [String: Any])?["state"] as? String != "running" }.sorted { ($0.value["at"] as? Double ?? 0) > ($1.value["at"] as? Double ?? 0) }
        for pair in terminal.dropFirst(256) { entries[pair.key] = nil }
        for pair in sessions.sorted(by: { ($0.value["at"] as? Double ?? 0) > ($1.value["at"] as? Double ?? 0) }).dropFirst(32) { sessions[pair.key] = nil }
        return entries.count != oldJobs || sessions.count != oldSessions
    }
    private func save() throws {
        prune()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let data = try JSONSerialization.data(withJSONObject: ["version":1,"jobs":entries,"sessions":sessions], options: [.sortedKeys])
        guard data.count <= 32 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let file = root.appendingPathComponent("receipts.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: file.path)
    }
    private static func expirePreviews(_ value: Any) -> Any {
        if let values = value as? [Any] { return values.map(expirePreviews) }
        guard var object = value as? [String: Any] else { return value }
        for (key, value) in object {
            if let path = value as? String, ["path","preview_path"].contains(key), path.contains("/AgentMedia/") { object[key] = NSNull(); object["preview_status"] = "expired" }
            else { object[key] = expirePreviews(value) }
        }
        return object
    }
}
