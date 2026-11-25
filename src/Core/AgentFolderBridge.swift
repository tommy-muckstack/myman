import AppKit
import CryptoKit
import Foundation
import Darwin

/// What the person is asked before a sensitive folder request runs.
struct AgentApprovalRequest: Sendable {
    let id: String
    let action: String
    let summary: String
    let detail: String
    let group: String
    let requester: String
    /// Deletes are asked every time; other groups may be always allowed, until revoked in Settings.
    let canRemember: Bool
}
enum AgentApprovalDecision: Sendable { case deny, allowOnce, allowAlways, expired }

/// Pure rules for the folder bridge, kept apart from file watching so they can
/// be tested without an app, a Brain folder or a person.
enum AgentFolderBridgePolicy {
    static let staleAfter: TimeInterval = 600
    /// Groups the person chose "Always allow" for. Stored in preferences, so they
    /// last across launches until revoked in Settings → Agents. Never includes delete.
    static let alwaysAllowedKey = "agentFolderBridgeAlwaysGroups"
    static let askedEveryTimeGroups: Set<String> = ["delete"]
    static func parseAlways(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { !$0.isEmpty && !askedEveryTimeGroups.contains($0) }
    }
    static func alwaysAllowed(_ defaults: UserDefaults = .standard) -> [String] {
        parseAlways(defaults.string(forKey: alwaysAllowedKey) ?? "")
    }
    static func withAlways(_ group: String, in raw: String) -> String {
        var groups = parseAlways(raw)
        if !groups.contains(group), !askedEveryTimeGroups.contains(group) { groups.append(group) }
        return groups.joined(separator: ",")
    }
    static func withoutAlways(_ group: String, in raw: String) -> String {
        parseAlways(raw).filter { $0 != group }.joined(separator: ",")
    }
    static func groupTitle(_ group: String) -> String {
        switch group {
        case "capture": return "Looking at your screen"
        case "recording": return "Recording and meetings"
        case "control": return "Mouse and keyboard"
        case "clipboard": return "Clipboard"
        case "sharing": return "Publishing shared links"
        default: return group
        }
    }
    static let maximumRequestBytes = 1024 * 1024
    static let maximumArtifactBytes = 1 << 30
    static let maximumArtifacts = 32
    static let artifactExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "mp4", "mov", "m4v", "m4a", "wav", "md", "html", "otf", "pdf"]

    struct Request {
        let id: String
        let action: String
        let args: [String: Any]
        let created: Date
        /// The same key gets the same response and runs once, whatever the id.
        let idempotencyKey: String?
        /// Passed to the dispatcher unchanged and never written to the log or the outbox.
        let identity: [String: Any]
    }

    static func isRequestName(_ name: String) -> Bool {
        name.hasSuffix(".json") && !name.hasPrefix(".") && UUID(uuidString: String(name.dropLast(5))) != nil
    }

    static func parse(_ data: Data, name: String) throws -> Request {
        guard isRequestName(name) else { throw AgentError("INVALID_REQUEST", "Name the request file <id>.json, where id is a UUID.") }
        guard data.count <= maximumRequestBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("INVALID_REQUEST", "The request must be one JSON object up to 1 MiB.")
        }
        guard Set(object.keys).isSubset(of: ["id", "action", "args", "created", "idempotencyKey", "credential", "machine_id"]) else {
            throw AgentError("INVALID_REQUEST", "Use only id, action, args, created and idempotencyKey (credential and machine_id when this Mac requires named agents).")
        }
        guard let id = object["id"] as? String, id == String(name.dropLast(5)) else { throw AgentError("INVALID_REQUEST", "id must match the file name.") }
        guard let action = object["action"] as? String, !action.isEmpty, action.count <= 100 else { throw AgentError("INVALID_REQUEST", "action must be an action name from manifest.json.") }
        guard object["args"] == nil || object["args"] is [String: Any] else { throw AgentError("INVALID_REQUEST", "args must be a JSON object.") }
        guard let created = date(object["created"]) else { throw AgentError("INVALID_REQUEST", "created must be an ISO 8601 time with a time zone, or Unix seconds.") }
        let idempotency = object["idempotencyKey"] as? String
        guard object["idempotencyKey"] == nil || (idempotency.map { !$0.isEmpty && $0.count <= 200 } ?? false) else { throw AgentError("INVALID_REQUEST", "idempotencyKey must be a string of up to 200 characters.") }
        var identity: [String: Any] = [:]
        for key in ["credential", "machine_id"] {
            guard let value = object[key] else { continue }
            guard let text = value as? String, text.count <= 512 else { throw AgentError("INVALID_REQUEST", "\(key) must be a string.") }
            identity[key] = text
        }
        return Request(id: id, action: action, args: object["args"] as? [String: Any] ?? [:], created: created, idempotencyKey: idempotency, identity: identity)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
            // Milliseconds are a common mistake; anything this large cannot be seconds.
            return Date(timeIntervalSince1970: number.doubleValue > 100_000_000_000 ? number.doubleValue / 1000 : number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A request older than ten minutes is a backlog from before the app or the
    /// bridge was on. A request from the future means the sender's clock is wrong.
    static func isStale(_ created: Date, now: Date) -> Bool { abs(now.timeIntervalSince(created)) > staleAfter }

    /// The folder bridge asks the person before these run. It adds to the
    /// grants in Settings → Agents and never replaces them. Stopping a
    /// session is never held back, as with a revoked grant.
    static func approvalGroup(action: String, info: [String: Any], args: [String: Any]) -> String? {
        if AgentConsent.cleanup.contains(action) { return nil }
        let grants = Set(info["permissions"] as? [String] ?? [])
        if info["destructive"] as? Bool == true { return "delete" }
        if action.hasPrefix("clipboard.") || args["clipboard"] as? Bool == true { return "clipboard" }
        if grants.contains("control") { return "control" }
        if grants.contains("capture") { return "capture" }
        if grants.contains("recording") { return "recording" }
        if grants.contains("sharing"), info["readOnly"] as? Bool != true { return "sharing" }
        return nil
    }

    /// read and write run once their grants are on. capture and destructive also ask the person.
    static func tier(action: String, info: [String: Any]) -> String {
        if let group = approvalGroup(action: action, info: info, args: [:]) { return group == "delete" ? "destructive" : "capture" }
        return info["readOnly"] as? Bool == true ? "read" : "write"
    }

    static func fingerprint(action: String, args: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["action": action, "args": args] as [String: Any], options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The log records what was asked without keeping what was written: long
    /// or free-text values are replaced by their length.
    static func redacted(_ value: Any, key: String = "") -> Any {
        if let object = value as? [String: Any] { return Dictionary(uniqueKeysWithValues: object.map { ($0.key, redacted($0.value, key: $0.key)) }) }
        if let list = value as? [Any] { return list.map { redacted($0, key: key) } }
        if let text = value as? String, ["text", "body", "notes", "message", "quote"].contains(key) || text.count > 120 { return "<\(text.count) characters>" }
        return value
    }

    static func manifestActions(_ catalog: [[String: Any]], grants: [String: Bool] = [:]) -> [[String: Any]] {
        catalog.compactMap { info -> [String: Any]? in
            guard let name = info["name"] as? String else { return nil }
            var entry = info
            entry["tier"] = tier(action: name, info: info)
            entry["requires_approval"] = approvalGroup(action: name, info: info, args: [:]) != nil
            // Whether its grants are on right now, so an agent need not find out by trying.
            entry["available"] = (info["permissions"] as? [String] ?? []).allSatisfy { grants[$0] == true }
            entry["approval_group"] = approvalGroup(action: name, info: info, args: [:]) as Any? ?? NSNull()
            entry["requires_confirm"] = ["item.delete", "task.delete", "history.clear", "share.publish"].contains(name)
            return entry
        }
    }

    static func hint(_ code: String) -> String? {
        switch code {
        case "AWAITING_USER": return "My Man is showing the person a prompt. Read this file again after they answer; do not send the request again."
        case "USER_DENIED": return "The person said no. Ask them before sending a new request."
        case "IDEMPOTENCY_KEY_USED": return "That key already ran and its response is no longer kept. Check what was saved before sending new work."
        case "ID_CONFLICT": return "Use a new idempotencyKey for a different action or arguments."
        case "APPROVAL_EXPIRED": return "Nobody answered within ten minutes. Ask the person to be at the Mac, then send a new request with a new id."
        case "AGENT_DISABLED": return "Agents cannot enable this. A person turns it on in My Man Settings → Agents."
        case "BRIDGE_DISABLED": return "A person turns on \"Accept commands through the Brain folder\" in My Man Settings → Agents."
        case "STALE_REQUEST": return "Write a new request with a new id and the current time in created. Check the Mac's time in heartbeat.json."
        case "ID_ALREADY_USED": return "Each request needs a new UUID. Read the earlier result in outbox/ instead of sending it again."
        case "UNKNOWN_ACTION": return "Read manifest.json for the actions this app supports."
        case "INVALID_ARGUMENTS": return "Compare args with the action's inputSchema in manifest.json."
        case "INVALID_REQUEST": return "Write {\"id\",\"action\",\"args\",\"created\"} to a temporary name, then rename it to inbox/<id>.json."
        case "IDENTITY_REQUIRED", "INVALID_CREDENTIAL": return "This Mac requires named agents. Add the agent's credential and machine_id to the request."
        case "PERMISSION_REQUIRED": return "A person grants this macOS permission to My Man in System Settings."
        case "APP_RESTARTED": return "My Man restarted while this ran. Check what was saved before sending anything again."
        case "BUSY": return "Wait for an earlier request to finish, then send a new one."
        default: return nil
        }
    }

    @MainActor static func error(_ error: Error) -> [String: Any] { withHint(AgentActions.error(error)) }
    static func withHint(_ error: [String: Any]) -> [String: Any] {
        var value = error
        if value["hint"] == nil, let code = value["code"] as? String, let text = hint(code) { value["hint"] = text }
        return value
    }

    /// Short, bounded view of the arguments for the prompt and the log.
    static func preview(_ args: [String: Any], limit: Int = 600) -> String {
        guard !args.isEmpty, let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    struct Extraction {
        var result: Any
        var files: [(source: String, name: String)] = []
        var blobs: [(data: Data, name: String)] = []
    }

    /// Finds the files a result points at and takes inline image data out of
    /// it. Only values under `path`, `*_path` and `*_paths` keys count, so text
    /// an agent supplied (a note body, a title) can never name a file to copy.
    static func extract(_ result: Any, action: String, folder: String) -> Extraction {
        var names = Set<String>()
        var found = Extraction(result: NSNull())
        func unique(_ wanted: String) -> String {
            let cleaned = String(wanted.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" })
            let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
            var candidate = base, count = 1
            while names.contains(candidate.lowercased()) {
                count += 1
                let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem)-\(count)" : "\(stem)-\(count).\(ext)"
            }
            names.insert(candidate.lowercased()); return candidate
        }
        var sources: [String: String] = [:]
        func note(_ path: String) {
            guard path.hasPrefix("/"), sources[path] == nil else { return }
            let name = unique((path as NSString).lastPathComponent)
            sources[path] = name; found.files.append((path, name))
        }
        func walk(_ value: Any) -> Any {
            if let list = value as? [Any] { return list.map(walk) }
            guard var object = value as? [String: Any] else { return value }
            if let mime = object["mimeType"] as? String, let encoded = object["data"] as? String {
                object["data"] = nil
                if let data = Data(base64Encoded: encoded) {
                    let name = unique("inline." + (mime.split(separator: "/").last.map(String.init) ?? "bin"))
                    found.blobs.append((data, name)); object["artifact"] = folder + "/" + name
                } else { object["artifact_status"] = "unreadable" }
                return object
            }
            for (key, child) in object {
                if key == "path" || key.hasSuffix("_path") {
                    if let path = child as? String { note(path) }
                } else if key.hasSuffix("_paths"), let paths = child as? [String] { paths.forEach(note) }
                else { object[key] = walk(child) }
            }
            return object
        }
        found.result = walk(result)
        if action == "meeting.notes", let notes = (result as? [String: Any])?["notes"] as? String, !notes.isEmpty {
            found.blobs.append((Data(notes.utf8), unique("notes.md")))
        }
        return found
    }

    /// Copies result files into the request's artifact folder. Runs off the
    /// main thread: a recording on another volume is a real copy.
    static func materialize(files: [(source: String, name: String)], blobs: [(data: Data, name: String)], into directory: URL, relative: String, roots: [String]) -> (written: [String], skipped: [[String: String]]) {
        var written: [String] = [], skipped: [[String: String]] = []
        let fm = FileManager.default
        func skip(_ name: String, _ reason: String) { skipped.append(["name": name, "reason": reason]) }
        guard !files.isEmpty || !blobs.isEmpty else { return ([], []) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { return ([], (files.map(\.name) + blobs.map(\.name)).map { ["name": $0, "reason": "The artifact folder could not be created."] }) }
        func keep(_ name: String) { written.append(relative + "/" + name); chmod(directory.appendingPathComponent(name).path, 0o600) }
        for blob in blobs {
            guard written.count < maximumArtifacts else { skip(blob.name, "More than \(maximumArtifacts) files."); continue }
            guard blob.data.count <= maximumArtifactBytes else { skip(blob.name, "Larger than 1 GiB."); continue }
            do { try blob.data.write(to: directory.appendingPathComponent(blob.name), options: .withoutOverwriting); keep(blob.name) }
            catch { skip(blob.name, "The file could not be written.") }
        }
        for file in files {
            guard written.count < maximumArtifacts else { skip(file.name, "More than \(maximumArtifacts) files."); continue }
            let real = URL(fileURLWithPath: file.source).resolvingSymlinksInPath().path
            var info = stat()
            guard lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { skip(file.name, "Not a file that still exists."); continue }
            guard artifactExtensions.contains((real as NSString).pathExtension.lowercased()) else { skip(file.name, "Not an image, video, audio or document type."); continue }
            guard roots.contains(where: { real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { skip(file.name, "Outside the folders My Man saves to."); continue }
            guard Int(info.st_size) <= maximumArtifactBytes else { skip(file.name, "Larger than 1 GiB; ask the person for the file."); continue }
            // On the same APFS volume this is a clone: instant and no extra space.
            do { try fm.copyItem(atPath: real, toPath: directory.appendingPathComponent(file.name).path); keep(file.name) }
            catch { skip(file.name, "The file could not be copied.") }
        }
        return (written, skipped)
    }
}

/// Request/response through `~/MyManBrain/agent` for agents that cannot reach
/// the local socket: a cloud agent whose only way into this Mac is a connected
/// folder. Requests run through the same dispatcher as the CLI, so grants,
/// schemas, named credentials and receipts behave the same.
///
/// The folder is a wider door than the socket, which only same-login processes
/// can open. So the bridge has its own switch that starts off, and it asks the
/// person before anything that looks at the screen, records, touches the
/// clipboard or deletes.
@MainActor final class AgentFolderBridge {
    static let enabledKey = "agentFolderBridgeEnabled"
    static weak var current: AgentFolderBridge?

    struct Hooks {
        var catalog: @MainActor () -> [[String: Any]]
        /// Throws what the dispatcher would throw, before anyone is asked. Returns who is asking.
        var preflight: @MainActor (_ action: String, _ args: [String: Any], _ identity: [String: Any]) throws -> String
        var dispatch: @MainActor ([String: Any]) -> [String: Any]
        var priorJob: @MainActor (String) -> [String: Any]?
        var approve: @MainActor (AgentApprovalRequest, Date) async -> AgentApprovalDecision
        var dismissApprovals: @MainActor () -> Void = {}
        var artifactRoots: @MainActor () -> [URL]
        var namedAgentsRequired: @MainActor () -> Bool = { false }
        var appVersion = "development"
        var launchID = UUID().uuidString
        var now: @MainActor () -> Date = { Date() }
        var pollInterval: Duration = .milliseconds(200)
    }

    let root: URL
    private let defaults: UserDefaults
    private var hooks: Hooks
    private(set) var running = false
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var ticks = 0
    private var active = Set<String>()
    private var seen = Set<String>()
    private var keys: [String: [String: Any]] = [:]
    private var signature = ""
    private var observers: [NSObjectProtocol] = []

    private var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    private var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    private var artifacts: URL { root.appendingPathComponent("artifacts", isDirectory: true) }

    init(root: URL = Brain.root.appendingPathComponent("agent", isDirectory: true), defaults: UserDefaults = .standard, hooks: Hooks) {
        self.root = root; self.defaults = defaults; self.hooks = hooks
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    var enabled: Bool { Self.enabled(defaults) }
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey) && (defaults.object(forKey: "agentActionsEnabled") as? Bool ?? true)
    }
    static func status(_ defaults: UserDefaults = .standard) -> [String: Any] {
        ["enabled": enabled(defaults), "watching": current?.running ?? false,
         "path": (current?.root ?? Brain.root.appendingPathComponent("agent")).path, "requires_approval": ["capture", "recording", "control", "clipboard", "sharing", "delete"]]
    }

    /// The only places a result file may be copied from: where My Man saves
    /// captures and recordings, its temporary previews, and its own data.
    static var savedMediaRoots: [URL] {
        let support = VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        return [SettingsStore.shared.screenshotFolderURL, AgentMediaStore.shared.root, Brain.root, support]
    }

    /// Follows the Settings switch for the life of the app.
    func start() {
        Self.current = self
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        // Deleting or hiding a capture must not leave copies or its text behind here.
        for name in [Notification.Name.captureDeleted, .captureExcluded] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.purgeResults() }
            })
        }
        reconcile()
    }

    /// Any preference write lands here, so do nothing unless the switch or a grant changed.
    func reconcile() {
        let grants = AgentConsent.status(defaults)
        let next = "\(enabled)|" + grants.keys.sorted().map { "\($0)=\(grants[$0] == true)" }.joined(separator: ",")
        guard next != signature else { return }
        signature = next
        if enabled { open() } else { close() }
    }

    private func open() {
        do { try prepare() } catch {
            NSLog("My Man: Brain folder bridge unavailable: %@", error.localizedDescription)
            running = false; signature = ""; return
        }
        writeManifest()
        guard !running else { return }
        source?.cancel(); source = nil
        keys = (readJSON(root.appendingPathComponent(".idempotency.json"), limit: 1024 * 1024) as? [String: [String: Any]]) ?? [:]
        running = true; heartbeat()
        let fd = Darwin.open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source; source.resume()
        }
        // Folder events from a mounted or synced folder are not guaranteed, so
        // the heartbeat tick also looks at the inbox.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        scan()
    }

    private func close() {
        let wasRunning = running
        running = false
        source?.cancel(); source = nil; timer?.invalidate(); timer = nil
        if wasRunning { hooks.dismissApprovals() }
        // Say why nothing answers, but never create the folder while off.
        guard isOwnedDirectory(root) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("heartbeat.json"))
        writeManifest()
        // A request that arrives anyway is told why and removed. Nothing is
        // parsed beyond its name and nothing runs.
        guard isOwnedDirectory(inbox), isOwnedDirectory(outbox) else { return }
        let fd = Darwin.open(inbox.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refusePending() } }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source; source.resume()
        }
        refusePending()
    }

    func refusePending() {
        guard !running, isOwnedDirectory(inbox), isOwnedDirectory(outbox), let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return }
        let master = defaults.object(forKey: "agentActionsEnabled") as? Bool ?? true
        let error: [String: Any] = master ? ["code": "BRIDGE_DISABLED", "message": "The Brain folder bridge is turned off in My Man."]
                                          : ["code": "AGENT_DISABLED", "message": "Local app actions are disabled in Settings → Agents."]
        for name in names where AgentFolderBridgePolicy.isRequestName(name) {
            let stem = String(name.dropLast(5)), target = outbox.appendingPathComponent(name)
            if readJSON(target) == nil {
                try? writeJSON(["ok": false, "id": stem, "error": AgentFolderBridgePolicy.withHint(error), "artifacts": [String](), "finished_at": AgentActions.date(hooks.now())], to: target)
            }
            audit("rejected", id: stem, ["code": error["code"] ?? ""])
            unlink(inbox.appendingPathComponent(name).path)
        }
    }

    private func tick() {
        guard running else { return }
        ticks += 1; heartbeat(); scan()
        if ticks % 6 == 0 { expire() }
    }

    // MARK: Folder

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR
    }
    /// Every folder must be a real directory owned by this login. A link here
    /// could send results, or copies of captures, somewhere else.
    private func prepare() throws {
        let fm = FileManager.default
        // The Brain folder is created in the background at launch; this may run first.
        try Brain.prepareRoot(root.deletingLastPathComponent())
        for folder in [root, inbox, outbox, artifacts] {
            if !fm.fileExists(atPath: folder.path) { try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            guard isOwnedDirectory(folder) else { throw AgentError("BRIDGE_UNAVAILABLE", "\(folder.lastPathComponent) must be a folder owned by this login, not a link.") }
        }
        // The Brain is a git repository people push. Requests, results and
        // copied captures stay out of it.
        let ignore = root.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) { try? writeFile(Data("*\n".utf8), to: ignore) }
    }

    /// Write beside the target, then rename, so a reader never sees half a file.
    private func writeFile(_ data: Data, to url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw AgentError("BRIDGE_UNAVAILABLE", "\(url.lastPathComponent) is not a regular file.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentError("BRIDGE_UNAVAILABLE", "Cannot write to the bridge folder.") }
        let complete = data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { return false }; sent += count
            }
            return true
        }
        Darwin.close(fd)
        guard complete, rename(temporary.path, url.path) == 0 else { unlink(temporary.path); throw AgentError("BRIDGE_UNAVAILABLE", "Cannot write to the bridge folder.") }
    }
    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try writeFile(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: url)
    }
    private func readJSON(_ url: URL, limit: Int = 64 * 1024 * 1024) -> [String: Any]? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func audit(_ event: String, id: String, _ fields: [String: Any] = [:]) {
        var line: [String: Any] = ["at": AgentActions.date(hooks.now()), "event": event, "id": id]
        line.merge(fields) { current, _ in current }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(10)
        let fd = Darwin.open(root.appendingPathComponent("audit.log").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        Darwin.close(fd)
    }

    private func heartbeat() {
        let now = hooks.now()
        try? writeJSON(["at": AgentActions.date(now), "updated": AgentActions.date(now), "epoch": now.timeIntervalSince1970, "interval_seconds": 10, "launch_id": hooks.launchID,
                        "pid": Int(ProcessInfo.processInfo.processIdentifier), "app_version": hooks.appVersion, "enabled": true], to: root.appendingPathComponent("heartbeat.json"))
    }

    private func writeManifest() {
        let on = enabled && isOwnedDirectory(inbox)
        var manifest: [String: Any] = [
            "version": 1, "bridge_version": 1, "app_version": hooks.appVersion, "enabled": on, "launch_id": hooks.launchID, "updated_at": AgentActions.date(hooks.now()),
            "grants": AgentConsent.status(defaults), "named_agents_required": hooks.namedAgentsRequired(),
            "request": ["path": "inbox/<id>.json", "fields": ["id": "a new UUID, also the file name", "action": "an action name below", "args": "an object matching that action's inputSchema", "created": "ISO 8601 time with a time zone",
                                              "idempotencyKey": "optional; the same key returns the same response and runs once"],
                        "write": "Write to a name starting with a dot, then rename to <id>.json.", "stale_after_seconds": Int(AgentFolderBridgePolicy.staleAfter)] as [String: Any],
            "response": ["path": "outbox/<id>.json", "success": ["ok": true, "result": "the action's result", "artifacts": "paths relative to this folder"] as [String: Any],
                         "failure": ["ok": false, "error": ["code": "stable code", "message": "what happened", "hint": "what to do next"]] as [String: Any],
                         "waiting": "pending is true while the code is AWAITING_USER. Read the file again; do not resend."] as [String: Any],
            "tiers": ["read": "Reads state or saved items. Runs when its permissions are on.", "write": "Creates or changes notes, tasks and library items. Runs when its permissions are on.",
                      "capture": "Looks at the screen, records, uses the clipboard or shares. Needs its permissions, and My Man asks the person each time, or keeps an \"always allow\" the person chose until they revoke it.",
                      "destructive": "Deletes. Needs its permissions and confirm, and My Man asks the person every time."],
            "always_allowed": AgentFolderBridgePolicy.alwaysAllowed(defaults),
            "async": "Every request is asynchronous: write it, then poll outbox/<id>.json. Nothing blocks the sender.",
            "files": ["heartbeat": "heartbeat.json", "audit": "audit.log", "artifacts": "artifacts/<id>/"],
            "actions": AgentFolderBridgePolicy.manifestActions(hooks.catalog(), grants: AgentConsent.status(defaults)),
        ]
        if !on { manifest["hint"] = AgentFolderBridgePolicy.hint("BRIDGE_DISABLED") ?? "" }
        try? writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
    }

    // MARK: Requests

    func scan() {
        guard running, let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard active.count < 16 else { break }
            guard !active.contains(name) else { continue }
            Task { @MainActor in await self.handle(name) }
        }
    }

    private enum Outcome { case respond([String: Any]), silent(String) }

    func handle(_ name: String) async {
        // The request file stays until its result is written, so every scan sees it again.
        guard running, active.insert(name).inserted else { return }
        defer { active.remove(name) }
        let file = inbox.appendingPathComponent(name)
        let stem = String(name.dropLast(5))
        var action = ""
        let outcome: Outcome
        do { outcome = try await process(name, file: file, action: &action) }
        catch { outcome = .respond(["ok": false, "error": AgentFolderBridgePolicy.error(error), "artifacts": [String]()]) }
        switch outcome {
        case .silent(let code):
            audit("rejected", id: stem, ["code": code])
        case .respond(var response):
            response["id"] = stem; response["finished_at"] = AgentActions.date(hooks.now()); response["launch_id"] = hooks.launchID
            if !action.isEmpty { response["action"] = action }
            let failure = response["error"] as? [String: Any]
            // Only a UUID names an outbox file. Anything else is logged and removed.
            if AgentFolderBridgePolicy.isRequestName(name) {
                do { try writeJSON(response, to: outbox.appendingPathComponent(name)) }
                catch { NSLog("My Man: could not write a Brain folder result: %@", error.localizedDescription) }
            }
            audit("result", id: stem, ["action": action, "ok": response["ok"] as? Bool ?? false, "code": failure?["code"] ?? NSNull(), "artifacts": response["artifacts"] ?? [String]()])
        }
        unlink(file.path)
    }

    private func process(_ name: String, file: URL, action: inout String) async throws -> Outcome {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= AgentFolderBridgePolicy.maximumRequestBytes,
              let data = try? Data(contentsOf: file) else { throw AgentError("INVALID_REQUEST", "The request must be a regular file up to 1 MiB.") }
        let request = try AgentFolderBridgePolicy.parse(data, name: name)
        action = request.action
        audit("request", id: request.id, ["action": request.action, "args": AgentFolderBridgePolicy.redacted(request.args), "created": AgentActions.date(request.created), "idempotency_key": request.idempotencyKey ?? NSNull()])

        // An id runs once. A finished result is never overwritten by a repeat.
        if let earlier = readJSON(outbox.appendingPathComponent(name)), earlier["pending"] as? Bool != true { return .silent("ID_ALREADY_USED") }
        if let job = hooks.priorJob(request.id) {
            if job["state"] as? String == "interrupted", let error = job["error"] as? [String: Any] {
                return .respond(["ok": false, "error": AgentFolderBridgePolicy.withHint(error), "artifacts": [String]()])
            }
            throw AgentError("ID_ALREADY_USED", "This id was already used for a request.")
        }
        guard !seen.contains(request.id) else { throw AgentError("ID_ALREADY_USED", "This id was already used for a request.") }
        guard !AgentFolderBridgePolicy.isStale(request.created, now: hooks.now()) else {
            throw AgentError("STALE_REQUEST", "This request is more than ten minutes from the Mac's clock, so it was not run.", details: ["mac_time": AgentActions.date(hooks.now())])
        }
        // The same key gets the first request's response; the action does not run again.
        let digest = AgentFolderBridgePolicy.fingerprint(action: request.action, args: request.args)
        if let key = request.idempotencyKey, let first = keys[key], let original = first["id"] as? String, original != request.id {
            guard first["fingerprint"] as? String == digest else { throw AgentError("ID_CONFLICT", "This idempotencyKey was used with a different action or arguments.") }
            audit("replayed", id: request.id, ["action": request.action, "original": original])
            while true {
                if var earlier = readJSON(outbox.appendingPathComponent(original + ".json")), earlier["pending"] as? Bool != true {
                    earlier["idempotent_replay_of"] = original
                    return .respond(earlier)
                }
                guard active.contains(original + ".json") else { throw AgentError("IDEMPOTENCY_KEY_USED", "This idempotencyKey already ran and its response is no longer kept.") }
                try? await Task.sleep(for: hooks.pollInterval)
            }
        }
        guard let details = hooks.catalog().first(where: { $0["name"] as? String == request.action }) else { throw AgentError("UNKNOWN_ACTION", "Use manifest.json to discover actions and arguments.") }
        // Everything the dispatcher would refuse is refused here first, so the
        // person is never asked about a request that could not run anyway.
        let requester = try hooks.preflight(request.action, request.args, request.identity)
        if seen.count > 4096 { seen.removeAll() }
        seen.insert(request.id)
        if let key = request.idempotencyKey {
            let cutoff = hooks.now().timeIntervalSince1970 - 86400
            keys = keys.filter { ($0.value["at"] as? Double ?? 0) >= cutoff }
            if keys.count >= 512 { keys.removeAll() }
            keys[key] = ["id": request.id, "fingerprint": digest, "at": hooks.now().timeIntervalSince1970]
            try? writeJSON(keys, to: root.appendingPathComponent(".idempotency.json"))
        }

        if let group = AgentFolderBridgePolicy.approvalGroup(action: request.action, info: details, args: request.args), !AgentFolderBridgePolicy.alwaysAllowed(defaults).contains(group) {
            try writeJSON(["ok": false, "pending": true, "id": request.id, "action": request.action, "artifacts": [String](),
                           "error": AgentFolderBridgePolicy.withHint(["code": "AWAITING_USER", "message": "Waiting for the person to allow or deny this in My Man."])], to: outbox.appendingPathComponent(name))
            audit("awaiting_user", id: request.id, ["action": request.action, "group": group])
            let ask = AgentApprovalRequest(id: request.id, action: request.action, summary: details["description"] as? String ?? "", detail: AgentFolderBridgePolicy.preview(request.args),
                                           group: group, requester: requester, canRemember: group != "delete")
            let decision = await hooks.approve(ask, request.created.addingTimeInterval(AgentFolderBridgePolicy.staleAfter))
            switch decision {
            case .deny: audit("denied", id: request.id, ["action": request.action]); throw AgentError("USER_DENIED", "The person did not allow this request.")
            case .expired: audit("expired", id: request.id, ["action": request.action]); throw AgentError("APPROVAL_EXPIRED", "Nobody answered the prompt in time, so nothing ran.")
            case .allowAlways where ask.canRemember:
                defaults.set(AgentFolderBridgePolicy.withAlways(group, in: defaults.string(forKey: AgentFolderBridgePolicy.alwaysAllowedKey) ?? ""), forKey: AgentFolderBridgePolicy.alwaysAllowedKey)
                audit("approved", id: request.id, ["action": request.action, "group": group, "always": true])
                writeManifest()
            case .allowOnce, .allowAlways: audit("approved", id: request.id, ["action": request.action, "group": group])
            }
        }
        guard running, enabled else { throw AgentError("BRIDGE_DISABLED", "The Brain folder bridge was turned off before this ran.") }

        var payload: [String: Any] = ["method": "invoke", "id": request.id, "action": request.action, "arguments": request.args]
        payload.merge(request.identity) { current, _ in current }
        var reply = hooks.dispatch(payload)
        var job: [String: Any] = [:]
        while true {
            guard reply["ok"] as? Bool == true, let current = reply["job"] as? [String: Any] else {
                let error = reply["error"] as? [String: Any] ?? ["code": "ACTION_FAILED", "message": "My Man did not accept the request."]
                return .respond(["ok": false, "error": AgentFolderBridgePolicy.withHint(error), "artifacts": [String]()])
            }
            job = current
            if job["state"] as? String != "running" { break }
            try? await Task.sleep(for: hooks.pollInterval)
            var poll: [String: Any] = ["method": "job", "id": request.id]
            poll.merge(request.identity) { current, _ in current }
            reply = hooks.dispatch(poll)
        }
        guard job["state"] as? String == "succeeded" else {
            let error = job["error"] as? [String: Any] ?? ["code": "ACTION_FAILED", "message": "The action did not finish."]
            return .respond(["ok": false, "error": AgentFolderBridgePolicy.withHint(error), "artifacts": [String]()])
        }
        let relative = "artifacts/" + request.id
        let extraction = AgentFolderBridgePolicy.extract(job["result"] ?? NSNull(), action: request.action, folder: relative)
        let files = extraction.files, blobs = extraction.blobs, directory = artifacts.appendingPathComponent(request.id, isDirectory: true)
        let roots = hooks.artifactRoots().map { $0.resolvingSymlinksInPath().path }
        let copied = await Task.detached(priority: .userInitiated) {
            AgentFolderBridgePolicy.materialize(files: files, blobs: blobs, into: directory, relative: relative, roots: roots)
        }.value
        var response: [String: Any] = ["ok": true, "result": extraction.result, "artifacts": copied.written]
        if !copied.skipped.isEmpty { response["artifacts_skipped"] = copied.skipped }
        return .respond(response)
    }

    // MARK: Housekeeping

    /// Results and copied files are for the agent to pick up, not an archive.
    private func expire() {
        let fm = FileManager.default, now = hooks.now()
        func old(_ url: URL, _ seconds: TimeInterval) -> Bool {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            return now.timeIntervalSince(date) > seconds
        }
        for folder in [outbox, artifacts] {
            for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where old(entry, 86400) { try? fm.removeItem(at: entry) }
        }
        // Half-written or misnamed requests nobody renamed.
        for entry in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !active.contains(entry.lastPathComponent) && old(entry, 3600) { try? fm.removeItem(at: entry) }
        let log = root.appendingPathComponent("audit.log")
        if let size = (try? fm.attributesOfItem(atPath: log.path)[.size]) as? NSNumber, size.intValue > 5 * 1024 * 1024 {
            let previous = root.appendingPathComponent("audit.log.1")
            try? fm.removeItem(at: previous); try? fm.moveItem(at: log, to: previous)
        }
    }

    private func purgeResults() {
        guard isOwnedDirectory(root) else { return }
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: entry) }
        for entry in (try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? [] {
            // A request still waiting for an answer keeps its placeholder.
            if readJSON(entry)?["pending"] as? Bool == true { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
