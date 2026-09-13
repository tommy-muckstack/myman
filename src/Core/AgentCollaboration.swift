import Foundation

/// Durable, bounded coordination metadata outside the searchable Brain. It
/// stores source references, never duplicate transcripts or image contents.
@MainActor final class AgentCollaboration {
    static let shared = AgentCollaboration()
    struct Reference: Codable { var id: String; var revision: Int }
    struct Bundle: Codable {
        var id: String; var title: String; var owner: String; var members: [String]
        var items: [Reference]; var revision = 1
    }
    struct Handoff: Codable {
        var id: String; var bundleID: String; var sender: String; var recipient: String
        var instruction: String; var state = "pending"; var revision = 1
        var outputs: [Reference] = []
    }
    struct Lease: Codable { var id: String; var resource: String; var owner: String; var expires: Date }
    struct Event: Codable {
        var cursor: Int; var type: String; var actor: String; var subject: String
        var audience: [String]; var date: Date; var jobID: String
    }
    private struct State: Codable {
        var bundles: [String: Bundle] = [:]
        var handoffs: [String: Handoff] = [:]
        var sessions: [String: String] = [:]
        var leases: [String: Lease] = [:]
        var events: [Event] = []
        var cursor = 0
    }
    private var state = State()
    private var unavailable = false
    private let file: URL
    private var busy: Set<String> = []
    private let lookup: (String) -> CaptureItem?
    private let registered: (String) -> Bool
    private let recordingAllowed: (String) -> Bool
    init(root: URL? = nil, lookup: @escaping (String) -> CaptureItem? = { CaptureIndex.item($0) }, registered: ((String) -> Bool)? = nil) {
        self.lookup = lookup; self.registered = registered ?? { AgentIdentity.shared.exists($0) }
        self.recordingAllowed = registered ?? { id in AgentIdentity.shared.agents.contains { $0.id == id && !$0.revoked && $0.scopes.contains("recording") } }
        let root = root ?? (VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan"))
        file = root.appendingPathComponent("AgentCollaboration/state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            } catch { unavailable = true }
        }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        guard data.count <= 8 * 1024 * 1024 else { throw AgentError("COORDINATION_FULL", "Clear old bundles and handoffs in Settings.") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !unavailable else { throw AgentError("COORDINATION_UNAVAILABLE", "Cannot read collaboration state. Inspect existing work before retrying.") }
        let old = state
        do { let result = try body(); try save(); return result }
        catch { state = old; throw error }
    }
    private func event(_ type: String, subject: String, audience: [String]) {
        state.cursor += 1
        state.events.append(Event(cursor: state.cursor, type: type, actor: AgentContext.principal.id, subject: subject, audience: audience, date: Date(), jobID: AgentContext.jobID))
        if state.events.count > 1000 { state.events.removeFirst(state.events.count - 1000) }
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func bundle(_ id: String) throws -> Bundle {
        guard let value = state.bundles[id], value.members.contains(AgentContext.principal.id) else { throw AgentError("NOT_FOUND", "Bundle is unavailable to this agent.") }; return value
    }
    private func references(_ ids: [String]) throws -> [Reference] {
        guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else { throw AgentError("INVALID_ARGUMENTS", "Provide 1–100 distinct item IDs.") }
        return try ids.map {
            guard let item = lookup($0), !item.excluded else { throw AgentError("NOT_FOUND", "A referenced item is unavailable.") }
            return Reference(id: item.id, revision: item.revision)
        }
    }
    func execute(_ action: String, _ args: [String: Any]) throws -> Any {
        guard !unavailable else { throw AgentError("COORDINATION_UNAVAILABLE", "Cannot read collaboration state.") }
        let actor = AgentContext.principal.id
        guard actor != "local" else { throw AgentError("IDENTITY_REQUIRED", "Collaboration requires a named agent credential from Settings.") }
        switch action {
        case "agent.whoami": return ["id": actor, "name": AgentContext.principal.name, "scopes": AgentContext.principal.scopes.sorted(), "machine": AgentIdentity.shared.machine]
        case "agent.list": return AgentIdentity.shared.directory
        case "bundle.create":
            let refs = try references(args["item_ids"] as! [String])
            let members = Array(Set((args["members"] as? [String] ?? []) + [actor])).sorted()
            guard members.allSatisfy({ registered($0) }), state.bundles.count < 100 else { throw AgentError("INVALID_ARGUMENTS", "Use registered members; at most 100 bundles are retained.") }
            let value = Bundle(id: UUID().uuidString, title: args["title"] as! String, owner: actor, members: members, items: refs)
            return try transaction { state.bundles[value.id] = value; event("bundle.created", subject: value.id, audience: members); return try json(value) }
        case "bundle.list": return try json(state.bundles.values.filter { $0.members.contains(actor) }.sorted { $0.title < $1.title })
        case "bundle.read":
            let value = try bundle(args["id"] as! String)
            let items: [[String: Any]] = value.items.map { ref in
                guard let item = lookup(ref.id), !item.excluded else { return ["id": ref.id, "status": "unavailable"] }
                return ["id": ref.id, "revision": ref.revision, "current_revision": item.revision, "status": ref.revision == item.revision ? "current" : "changed", "title": item.title, "kind": item.kind]
            }
            return ["bundle": try json(value), "items": items, "immutable_snapshot": false]
        case "bundle.update", "bundle.delete":
            var value = try bundle(args["id"] as! String)
            guard args["expected_revision"] as? Int == value.revision else { throw AgentError("EDIT_CONFLICT", "Bundle changed; read it again.") }
            if action == "bundle.delete" {
                guard args["confirm"] as? Bool == true else { throw AgentError("CONFIRMATION_REQUIRED", "Deleting a bundle requires confirm=true.") }
                guard value.owner == actor else { throw AgentError("NOT_OWNER", "Only the bundle creator can delete it.") }
                return try transaction {
                    state.bundles[value.id] = nil
                    state.handoffs = state.handoffs.filter { $0.value.bundleID != value.id }
                    event("bundle.deleted", subject: value.id, audience: value.members)
                    return ["deleted": value.id]
                }
            }
            if let title = args["title"] as? String { value.title = title }
            if let ids = args["item_ids"] as? [String] { value.items = try references(ids) }
            if let members = args["members"] as? [String] {
                guard value.owner == actor, members.allSatisfy({ registered($0) }) else { throw AgentError("NOT_OWNER", "Only the creator can change registered members.") }
                value.members = Array(Set(members + [actor])).sorted()
            }
            value.revision += 1
            return try transaction { state.bundles[value.id] = value; event("bundle.updated", subject: value.id, audience: value.members); return try json(value) }
        case "handoff.create":
            let value = try bundle(args["bundle_id"] as! String), recipient = args["recipient"] as! String
            guard value.members.contains(recipient), registered(recipient), state.handoffs.count < 200 else { throw AgentError("INVALID_ARGUMENTS", "Recipient must be a registered bundle member; at most 200 handoffs are retained.") }
            let handoff = Handoff(id: UUID().uuidString, bundleID: value.id, sender: actor, recipient: recipient, instruction: args["instruction"] as! String)
            return try transaction { state.handoffs[handoff.id] = handoff; event("handoff.created", subject: handoff.id, audience: [actor, recipient]); return try json(handoff) }
        case "handoff.list":
            return try json(state.handoffs.values.filter { ($0.sender == actor || $0.recipient == actor) && state.bundles[$0.bundleID]?.members.contains(actor) == true }.sorted { $0.id < $1.id })
        case "handoff.read", "handoff.update":
            guard var value = state.handoffs[args["id"] as! String], value.sender == actor || value.recipient == actor else { throw AgentError("NOT_FOUND", "Handoff is unavailable to this agent.") }
            _ = try bundle(value.bundleID)
            if action == "handoff.read" { return try json(value) }
            guard args["expected_revision"] as? Int == value.revision else { throw AgentError("EDIT_CONFLICT", "Handoff changed; read it again.") }
            let next = args["state"] as! String
            let allowed = (value.recipient == actor && ((value.state == "pending" && ["accepted", "declined"].contains(next)) || (value.state == "accepted" && ["completed", "failed"].contains(next)))) || (value.sender == actor && ["pending", "accepted"].contains(value.state) && next == "cancelled")
            guard allowed else { throw AgentError("INVALID_TRANSITION", "This actor cannot make that handoff transition.") }
            if let ids = args["output_ids"] as? [String] {
                guard next == "completed" else { throw AgentError("INVALID_ARGUMENTS", "Outputs belong to completed handoffs.") }
                value.outputs = try references(ids)
            }
            value.state = next; value.revision += 1
            return try transaction { state.handoffs[value.id] = value; event("handoff." + next, subject: value.id, audience: [value.sender, value.recipient]); return try json(value) }
        case "collaboration.events":
            let after = args["after_cursor"] as? Int ?? 0
            guard after <= state.cursor, after == 0 || after >= (state.events.first?.cursor ?? 1) - 1 else { throw AgentError("CURSOR_EXPIRED", "Refresh bundles and handoffs, then resume from the returned cursor.", details: ["cursor": state.cursor]) }
            let visible = state.events.filter { $0.cursor > after && $0.audience.contains(actor) }
            return ["events": try json(Array(visible.prefix(100))), "cursor": visible.count > 100 ? visible[99].cursor : state.cursor, "has_more": visible.count > 100]
        case "lease.acquire", "lease.release":
            let resource = args["resource"] as! String
            guard resource == "clipboard" || resource.hasPrefix("item:") else { throw AgentError("INVALID_ARGUMENTS", "Lease clipboard or item:ITEM-ID. Recording ownership is automatic.") }
            if resource.hasPrefix("item:") { _ = try references([String(resource.dropFirst(5))]) }
            if let prior = state.leases[resource], prior.expires > Date() {
                guard prior.owner == actor else { throw AgentError("RESOURCE_OWNED", "Resource is reserved by another agent.", details: ["owner": prior.owner, "expires_at": AgentActions.date(prior.expires)]) }
            }
            if action == "lease.release" {
                guard let prior = state.leases[resource], prior.owner == actor, prior.id == args["lease_id"] as? String else { throw AgentError("LEASE_EXPIRED", "This lease is no longer yours.") }
                return try transaction { state.leases[resource] = nil; return ["released": resource] }
            }
            guard !busy.contains(resource) else { throw AgentError("BUSY", "An operation is already using this resource.") }
            let value = Lease(id: UUID().uuidString, resource: resource, owner: actor, expires: Date().addingTimeInterval(args["seconds"] as? Double ?? 60))
            return try transaction { state.leases = state.leases.filter { $0.value.expires > Date() }; state.leases[resource] = value; return try json(value) }
        case "session.transfer":
            let id = args["session_id"] as! String, recipient = args["recipient"] as! String
            guard state.sessions[id] == actor, registered(recipient), recordingAllowed(recipient) else { throw AgentError("NOT_OWNER", "Only the session owner can transfer to a registered agent.") }
            guard !busy.contains("session:" + id) else { throw AgentError("BUSY", "A session command is in progress.") }
            return try transaction { state.sessions[id] = recipient; event("session.transferred", subject: id, audience: [actor, recipient]); return ["session_id": id, "owner": recipient] }
        default: throw AgentError("UNKNOWN_ACTION", "Unknown collaboration action.")
        }
    }
    /// Reserves actual in-flight operations even if a cooperative lease expires.
    func begin(resource: String, leaseID: String?) throws {
        guard !unavailable else { throw AgentError("COORDINATION_UNAVAILABLE", "Cannot read collaboration state.") }
        guard !busy.contains(resource) else { throw AgentError("BUSY", "Another command is using this resource.") }
        if let lease = state.leases[resource], lease.expires > Date() {
            guard lease.owner == AgentContext.principal.id, lease.id == leaseID else { throw AgentError("RESOURCE_OWNED", "Supply the current owner's lease_id before changing this resource.") }
        } else if leaseID != nil { throw AgentError("LEASE_EXPIRED", "Lease expired; inspect the resource before acquiring it again.") }
        busy.insert(resource)
    }
    func end(resource: String) { busy.remove(resource) }
    func checkSession(_ id: String) throws {
        guard !unavailable else { throw AgentError("COORDINATION_UNAVAILABLE", "Cannot read session ownership.") }
        if let owner = state.sessions[id] {
            guard owner == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "Another agent owns this session. Ask its owner to transfer it or use MyMan's recording controls.", details: ["owner": owner]) }
        } else if AgentContext.principal.id != "local" { throw AgentError("NOT_OWNER", "This session was started outside this agent connection. Use MyMan's recording controls.") }
    }
    func pruneSessions(active: Set<String>) throws {
        try transaction { state.sessions = state.sessions.filter { active.contains($0.key) } }
    }
    func ownSession(_ id: String) throws {
        try transaction {
            guard state.sessions.count < 256 else { throw AgentError("COORDINATION_FULL", "Clear old session ownership in Settings.") }
            state.sessions[id] = AgentContext.principal.id
            event("session.started", subject: id, audience: [AgentContext.principal.id])
        }
    }
    func sessionOwner(_ id: String) -> String? { state.sessions[id] }
    func completed(action: String, result: Any) throws {
        let object = result as? [String: Any] ?? [:]
        let subject = object["id"] as? String ?? object["session_id"] as? String ?? AgentContext.jobID
        try transaction { event("action.completed:" + action, subject: subject, audience: [AgentContext.principal.id]) }
    }
    func purge(itemID: String?) {
        do { try transaction {
            let audience = Array(Set(state.bundles.values.flatMap(\.members) + state.events.flatMap(\.audience)))
            if let id = itemID {
                let affected = Set(state.bundles.values.filter { $0.items.contains { $0.id == id } }.map(\.id))
                state.bundles = state.bundles.filter { !affected.contains($0.key) }
                state.handoffs = state.handoffs.filter { !affected.contains($0.value.bundleID) && !$0.value.outputs.contains { $0.id == id } }
                state.leases["item:" + id] = nil
            } else { state.bundles.removeAll(); state.handoffs.removeAll(); state.leases.removeAll() }
            // Instructions and event associations can indirectly contain deleted
            // material; remove retained event payloads on every deletion.
            state.events.removeAll()
            event("references.invalidated", subject: "", audience: audience)
        } } catch { try? FileManager.default.removeItem(at: file); unavailable = true }
    }
    /// Human-only reset; never exposed as a tool. Does not stop active captures.
    func reset() throws { let old = state; state = State(); state.cursor = old.cursor + 1; do { try save(); unavailable = false } catch { state = old; throw error } }
}
