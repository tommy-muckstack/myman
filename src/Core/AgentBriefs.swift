import Foundation
import Combine
import AVFoundation

/// Briefs retain references and explicitly authored instructions, not copies of
/// recordings or transcripts. Deleting/excluding any source invalidates the brief.
@MainActor final class AgentBriefs: ObservableObject {
    static let shared = AgentBriefs(observe: false)
    struct Reference: Codable, Equatable { var id: String; var revision: Int }
    struct Check: Codable, Equatable {
        var criterion: Int
        var passed: Bool
        var evidenceIDs: [String]
        var note: String
    }
    struct Brief: Codable, Identifiable {
        var id: String
        var title: String
        var outcome: String
        var recipe: String
        var criteria: [String]
        var sources: [Reference]
        var owner: String
        var worker: String?
        var reviewer: String?
        var frameTimes: [Double]
        var revision = 1
        var stage = "draft"
        var outputs: [Reference] = []
        var summary = ""
        var checks: [Check] = []
        var updatedAt = Date()
    }
    private struct State: Codable { var briefs: [Brief] = [] }
    private var state = State()
    private var unavailable = false
    private let file: URL
    private let lookup: (String) -> CaptureItem?
    private let registered: (String) -> Bool
    private var observers: [NSObjectProtocol] = []
    static let recipes = ["bug-fix", "launch-kit"]
    init(root: URL? = nil, lookup: @escaping (String) -> CaptureItem? = { CaptureIndex.item($0) }, registered: ((String) -> Bool)? = nil, observe: Bool = true) {
        self.lookup = lookup
        self.registered = registered ?? { id in AgentIdentity.shared.agents.contains { $0.id == id && !$0.revoked && $0.scopes.contains("library") } }
        let root = root ?? (VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan"))
        file = root.appendingPathComponent("AgentBriefs/state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            } catch { unavailable = true }
        }
        if observe {
            for name in [Notification.Name.captureDeleted, .captureExcluded] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                    MainActor.assumeIsolated { self?.purge(itemID: event.object as? String) }
                })
            }
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !unavailable else { throw AgentError("BRIEFS_UNAVAILABLE", "Cannot read saved briefs.") }
        let old = state
        do {
            let value = try body()
            let data = try JSONEncoder().encode(state)
            guard data.count <= 4 * 1024 * 1024 else { throw AgentError("BRIEFS_FULL", "Delete old briefs before creating more.") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            objectWillChange.send()
            return value
        } catch { state = old; throw error }
    }
    func purge(itemID: String?) {
        do {
            try transaction { state.briefs.removeAll { brief in
                guard let itemID else { return true }
                return (brief.sources + brief.outputs).contains { $0.id == itemID }
            } }
        } catch { unavailable = true; objectWillChange.send() }
    }
    private func source(_ id: String) throws -> CaptureItem {
        guard let item = lookup(id), !item.excluded else { throw AgentError("NOT_FOUND", "A brief source is unavailable.") }
        return item
    }
    private func references(_ ids: [String]) throws -> [Reference] {
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count else { throw AgentError("INVALID_ARGUMENTS", "Choose 1–20 distinct captures.") }
        return try ids.map { let item = try source($0); return Reference(id: item.id, revision: item.revision) }
    }
    func sourcesCurrent(_ brief: Brief) -> Bool {
        (brief.sources + brief.outputs).allSatisfy { ref in
            guard let item = lookup(ref.id), !item.excluded else { return false }
            return item.revision == ref.revision
        }
    }
    private func requireCurrent(_ brief: Brief) throws {
        guard sourcesCurrent(brief) else { throw AgentError("SOURCE_CHANGED", "A source or result changed. The brief owner must refresh it and request a new review.") }
    }
    func list(human: Bool = false) throws -> [Brief] {
        guard !unavailable else { throw AgentError("BRIEFS_UNAVAILABLE", "Cannot read saved briefs.") }
        let actor = AgentContext.principal.id
        return state.briefs.filter { human || [$0.owner, $0.worker, $0.reviewer].contains(actor) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func read(_ id: String, human: Bool = false) throws -> Brief {
        guard let brief = try list(human: human).first(where: { $0.id == id }) else { throw AgentError("NOT_FOUND", "Brief is unavailable to this agent.") }
        // This also catches removal while the app was not observing notifications.
        for ref in brief.sources + brief.outputs { _ = try source(ref.id) }
        return brief
    }
    private func owner(_ brief: Brief, human: Bool) throws {
        guard human || brief.owner == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "Only the brief owner can change its assignment.") }
    }
    func create(title: String, outcome: String, recipe: String, criteria: [String], sourceIDs: [String], frameTimes: [Double], human: Bool = false) throws -> Brief {
        guard human || AgentContext.principal.id != "local" else { throw AgentError("IDENTITY_REQUIRED", "Create a named agent in Settings before making a shared brief.") }
        guard state.briefs.count < 100, Self.recipes.contains(recipe), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 160,
              !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, outcome.count <= 8000,
              (1...12).contains(criteria.count), criteria.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 }),
              frameTimes.count <= 6, Set(frameTimes).count == frameTimes.count, frameTimes.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw AgentError("INVALID_ARGUMENTS", "Use a title, an outcome, 1–12 acceptance criteria and at most six distinct frame times.") }
        let refs = try references(sourceIDs)
        guard try source(refs[0].id).kind == "recording" else { throw AgentError("INVALID_ARGUMENTS", "The first source must be a saved screen recording.") }
        let brief = Brief(id: UUID().uuidString, title: title, outcome: outcome, recipe: recipe, criteria: criteria, sources: refs, owner: human ? "human" : AgentContext.principal.id, frameTimes: frameTimes.sorted())
        let saved = try transaction { state.briefs.append(brief); return brief }
        Analytics.track("agent_brief_created", ["recipe": recipe, "criteria_count": criteria.count, "source_count": refs.count])
        return saved
    }
    func createValidated(title: String, outcome: String, recipe: String, criteria: [String], sourceIDs: [String], frameTimes: [Double], human: Bool = false) async throws -> Brief {
        guard let first = sourceIDs.first else { throw AgentError("INVALID_ARGUMENTS", "Choose a source recording.") }
        let recording = try source(first)
        guard recording.kind == "recording" else { throw AgentError("INVALID_ARGUMENTS", "The first source must be a saved recording.") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: recording.sourcePath))
        let duration = try await asset.load(.duration).seconds
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw AgentError("INVALID_VIDEO", "Choose a playable recording.") }
        _ = try AgentVideo.sampleTimes(frameTimes.isEmpty ? nil : frameTimes, count: 4, duration: duration)
        guard try source(first).revision == recording.revision else { throw AgentError("SOURCE_CHANGED", "The recording changed while preparing the brief. Select it again.") }
        return try create(title: title, outcome: outcome, recipe: recipe, criteria: criteria, sourceIDs: sourceIDs, frameTimes: frameTimes, human: human)
    }
    func change(_ id: String, expected: Int, human: Bool = false, edit: (inout Brief) throws -> Void) throws -> Brief {
        var brief = try read(id, human: human)
        guard brief.revision == expected else { throw AgentError("EDIT_CONFLICT", "Brief changed; read it again before editing.") }
        try edit(&brief)
        brief.revision += 1; brief.updatedAt = Date()
        let saved = try transaction {
            guard let index = state.briefs.firstIndex(where: { $0.id == id }) else { throw AgentError("NOT_FOUND", "Brief was removed.") }
            state.briefs[index] = brief; return brief
        }
        Analytics.track("agent_brief_stage_changed", ["recipe": saved.recipe, "stage": saved.stage, "output_count": saved.outputs.count])
        return saved
    }
    func handoff(_ id: String, expected: Int, worker: String, reviewer: String, human: Bool = false) throws -> Brief {
        try change(id, expected: expected, human: human) { brief in
            try owner(brief, human: human); try requireCurrent(brief)
            guard ["draft", "changes_requested"].contains(brief.stage), worker != reviewer, registered(worker), registered(reviewer) else { throw AgentError("INVALID_ARGUMENTS", "Assign two different registered agents with library access to a draft or returned brief.") }
            brief.worker = worker; brief.reviewer = reviewer; brief.stage = "assigned"
            brief.outputs = []; brief.checks = []; brief.summary = ""
        }
    }
    func refresh(_ id: String, expected: Int, human: Bool = false) throws -> Brief {
        try change(id, expected: expected, human: human) { brief in
            try owner(brief, human: human)
            brief.sources = try references(brief.sources.map(\.id))
            brief.outputs = []; brief.checks = []; brief.summary = ""; brief.stage = "draft"
            brief.worker = nil; brief.reviewer = nil
        }
    }
    func submit(_ id: String, expected: Int, outputIDs: [String], summary: String) throws -> Brief {
        try change(id, expected: expected) { brief in
            guard brief.worker == AgentContext.principal.id, brief.stage == "assigned" else { throw AgentError("NOT_OWNER", "Only the assigned worker can submit results for this brief.") }
            try requireCurrent(brief)
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 8000 else { throw AgentError("INVALID_ARGUMENTS", "Describe the result in up to 8,000 characters.") }
            let refs = try references(outputIDs)
            guard Set(outputIDs).intersection(brief.sources.map(\.id)).isEmpty else { throw AgentError("INVALID_ARGUMENTS", "Submit new results rather than the original sources.") }
            guard try outputIDs.contains(where: { ["screenshot", "recording"].contains(try source($0).kind) }) else { throw AgentError("VISUAL_PROOF_REQUIRED", "Include a saved screenshot comparison or demonstration recording.") }
            brief.outputs = refs; brief.summary = summary; brief.stage = "awaiting_review"
        }
    }
    func review(_ id: String, expected: Int, checks: [Check]) throws -> Brief {
        try change(id, expected: expected) { brief in
            guard brief.reviewer == AgentContext.principal.id, brief.stage == "awaiting_review" else { throw AgentError("NOT_OWNER", "Only the assigned reviewer can review submitted results.") }
            try requireCurrent(brief)
            guard checks.count == brief.criteria.count, Set(checks.map(\.criterion)) == Set(brief.criteria.indices) else { throw AgentError("INVALID_ARGUMENTS", "Review every acceptance criterion exactly once, using its zero-based index.") }
            let outputs = Set(brief.outputs.map(\.id))
            for check in checks {
                guard check.note.count <= 2000, !check.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      check.evidenceIDs.count <= 20, Set(check.evidenceIDs).isSubset(of: outputs),
                      !check.passed || !check.evidenceIDs.isEmpty else { throw AgentError("INVALID_ARGUMENTS", "Explain each check; a passing check must cite submitted evidence IDs.") }
            }
            brief.checks = checks.sorted { $0.criterion < $1.criterion }
            brief.stage = checks.allSatisfy(\.passed) ? "reviewed" : "changes_requested"
        }
    }
    func delete(_ id: String, expected: Int, human: Bool = false) throws {
        guard let brief = try list(human: human).first(where: { $0.id == id }) else { throw AgentError("NOT_FOUND", "Brief not found.") }
        try owner(brief, human: human)
        guard brief.revision == expected else { throw AgentError("EDIT_CONFLICT", "Brief changed; read it again.") }
        try transaction { state.briefs.removeAll { $0.id == id } }
    }
    func context(_ id: String, human: Bool = false) async throws -> [String: Any] {
        let brief = try read(id, human: human)
        let recording = try source(brief.sources[0].id)
        var value: [String: Any] = ["brief": try Self.json(brief), "sources_current": sourcesCurrent(brief), "transcript": String(recording.body.prefix(50000)), "transcript_truncated": recording.body.count > 50000,
            "transcript_timing": "unavailable", "transcript_status": recording.body.isEmpty ? "empty_or_pending" : "available", "dispatch": "host_required"]
        value["sources"] = try brief.sources.map { ref -> [String: Any] in
            let item = try source(ref.id)
            return ["id": item.id, "kind": item.kind, "title": item.title, "path": item.sourcePath, "revision": item.revision, "expected_revision": ref.revision]
        }
        let args: [String: Any] = brief.frameTimes.isEmpty ? ["count": 4.0, "width": 640.0] : ["times": brief.frameTimes, "width": 640.0]
        value["visual_context"] = try await AgentVideo.frames(URL(fileURLWithPath: recording.sourcePath), args: args)
        // Rendering suspends; don't return removed content or stale assignment.
        let current = try read(id, human: human)
        guard current.revision == brief.revision, current.sources == brief.sources,
              try source(recording.id).revision == recording.revision else { throw AgentError("EDIT_CONFLICT", "Brief or recording changed during frame extraction. Read again.") }
        return value
    }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    func exportForHuman(_ id: String, expected: Int, args: [String: Any]) throws -> [String: Any] {
        let brief = try read(id, human: true); try requireCurrent(brief)
        guard brief.revision == expected else { throw AgentError("EDIT_CONFLICT", "Brief changed; review it again before sharing.") }
        return try AgentBriefShare.export(brief, args: args, lookup: lookup)
    }
    func execute(_ action: String, _ args: [String: Any]) async throws -> Any {
        guard AgentContext.principal.id != "local" else { throw AgentError("IDENTITY_REQUIRED", "Shared briefs require a named agent credential.") }
        let id = args["id"] as? String ?? "", expected = args["expected_revision"] as? Int ?? 0
        switch action {
        case "brief.open":
            _ = try read(id); AgentBriefWindow.shared.open(briefID: id); return ["opened": id]
        case "brief.create": return try await Self.json(createValidated(title: args["title"] as! String, outcome: args["outcome"] as! String, recipe: args["recipe"] as! String, criteria: args["criteria"] as! [String], sourceIDs: args["source_ids"] as! [String], frameTimes: args["frame_times"] as? [Double] ?? []))
        case "brief.list": return ["briefs": try Self.json(list())]
        case "brief.read":
            if args["include_context"] as? Bool == true { return try await context(id) }
            let brief = try read(id); return ["brief": try Self.json(brief), "sources_current": sourcesCurrent(brief), "dispatch": "host_required"]
        case "brief.handoff": return try Self.json(handoff(id, expected: expected, worker: args["worker"] as! String, reviewer: args["reviewer"] as! String))
        case "brief.refresh": return try Self.json(refresh(id, expected: expected))
        case "brief.submit": return try Self.json(submit(id, expected: expected, outputIDs: args["output_ids"] as! [String], summary: args["summary"] as! String))
        case "brief.review":
            let checks = try JSONDecoder().decode([Check].self, from: JSONSerialization.data(withJSONObject: args["checks"]!))
            return try Self.json(review(id, expected: expected, checks: checks))
        case "brief.delete":
            guard args["confirm"] as? Bool == true else { throw AgentError("CONFIRMATION_REQUIRED", "Deleting a brief requires confirm=true.") }
            try delete(id, expected: expected); return ["deleted": id]
        case "brief.export":
            guard args["confirm"] as? Bool == true else { throw AgentError("CONFIRMATION_REQUIRED", "Review the selected public text and visuals, then set confirm=true to export.") }
            let brief = try read(id); try owner(brief, human: false); try requireCurrent(brief)
            guard brief.revision == expected else { throw AgentError("EDIT_CONFLICT", "Brief changed; read it again.") }
            return try AgentBriefShare.export(brief, args: args, lookup: lookup)
        default: throw AgentError("UNKNOWN_ACTION", "Unknown brief action.")
        }
    }
}
