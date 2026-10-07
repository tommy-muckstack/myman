import Foundation
import CryptoKit
import Security
import Combine

/// Credentials distinguish cooperating clients. They do not sandbox processes
/// running under the same macOS login or restrict direct access to Brain files.
struct AgentPrincipal: Sendable {
    let id: String
    let name: String
    let scopes: Set<String>
    static let local = AgentPrincipal(id: "local", name: "Local client", scopes: ["capture", "markup", "recording", "library", "sharing", "scheduling_parse", "people_read", "control", "calendar_read", "calendar_write", "calendar_propose"])
}
enum AgentContext {
    @TaskLocal static var principal = AgentPrincipal.local
    @TaskLocal static var jobID = ""
}
@MainActor final class AgentIdentity: ObservableObject {
    static let shared = AgentIdentity()
    struct Registration: Codable, Identifiable {
        var id: String
        var name: String
        var scopes: [String]
        var digest: String
        var revoked: Bool = false
    }
    private struct State: Codable {
        var machineID = UUID().uuidString
        var required = false
        var agents: [Registration] = []
    }
    private var state = State()
    private var unavailable = false
    private let file: URL
    var agents: [Registration] { state.agents }
    var required: Bool { state.required }
    var machine: [String: Any] { ["id": state.machineID, "name": Host.current().localizedName ?? "This Mac", "transport": "local_socket", "remote_execution": "provided_by_host"] }
    init(root: URL? = nil) {
        let root = root ?? (VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan"))
        file = root.appendingPathComponent("AgentIdentity/identities.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { unavailable = true }
        } else { do { try save() } catch { unavailable = true } }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// Called only from human Settings or the app's own launch, never from
    /// the command catalog. `requireNamed` is what adding a first agent in
    /// Settings does: from then on unnamed callers are refused.
    func issue(name: String, scopes: Set<String>, requireNamed: Bool = true) throws -> (Registration, String) {
        guard !unavailable else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot read the agent registry.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, scopes.isSubset(of: AgentPrincipal.local.scopes), state.agents.count < 100 else { throw AgentError("INVALID_ARGUMENTS", "Use a name up to 80 characters and at most 100 registrations.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot create a credential.") }
        let token = Data(bytes).base64EncodedString(), old = state
        let agent = Registration(id: UUID().uuidString, name: name, scopes: scopes.sorted(), digest: Self.digest(token))
        state.agents.append(agent); state.required = state.required || requireNamed
        do { try save() } catch { state = old; throw error }
        objectWillChange.send(); return (agent, token)
    }
    func revoke(_ id: String) throws {
        let old = state
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { return }
        state.agents[index].revoked = true
        do { try save() } catch { state = old; throw error }; objectWillChange.send()
        if state.agents[index].name == Self.brainzAgentName { try? FileManager.default.removeItem(at: brainzCredentialFile) }
    }

    /// Brainz, the notes app that ships next to My Man, gets a standing
    /// identity without anyone pasting a credential: a registration under its
    /// name plus the credential in a file only this login can read, which
    /// Brainz hands to the companion servers it launches. The grants in
    /// Settings → Agents still decide what it may do, and revoking the Brainz
    /// agent there removes the file and is final until the person adds it back.
    static let brainzAgentName = "Brainz"
    var brainzCredentialFile: URL { file.deletingLastPathComponent().appendingPathComponent("brainz.env") }
    @discardableResult func ensureBrainzCredential() -> Bool {
        guard !unavailable else { return false }
        let registrations = state.agents.filter { $0.name == Self.brainzAgentName }
        let live = registrations.first { !$0.revoked }
        if live == nil, !registrations.isEmpty {
            try? FileManager.default.removeItem(at: brainzCredentialFile)
            return false
        }
        if let live {
            if FileManager.default.fileExists(atPath: brainzCredentialFile.path) { return true }
            // The file went missing; the old credential cannot be recovered
            // from its digest, so retire it and issue a fresh one.
            let old = state
            if let index = state.agents.firstIndex(where: { $0.id == live.id }) { state.agents[index].revoked = true }
            do { try save() } catch { state = old; return false }
        }
        guard let (_, token) = try? issue(name: Self.brainzAgentName, scopes: AgentPrincipal.local.scopes, requireNamed: false) else { return false }
        let contents = "MYMAN_AGENT_TOKEN=\(token)\nMYMAN_MACHINE_ID=\(state.machineID)\n"
        do {
            try Data(contents.utf8).write(to: brainzCredentialFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: brainzCredentialFile.path)
        } catch { return false }
        return true
    }
    func setRequired(_ value: Bool) throws {
        guard !unavailable else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot read the agent registry.") }
        let old = state; state.required = value
        do { try save() } catch { state = old; throw error }; objectWillChange.send()
    }
    func checkMachine(_ request: [String: Any]) throws {
        guard !unavailable else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot read the agent registry.") }
        if let target = request["machine_id"] as? String, target != state.machineID { throw AgentError("WRONG_MACHINE", "This is a different Mac. Select the intended host before retrying.", details: ["machine": machine]) }
    }
    func authenticate(_ request: [String: Any]) throws -> AgentPrincipal {
        guard !unavailable else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot read the agent registry.") }
        if let target = request["machine_id"] as? String, target != state.machineID { throw AgentError("WRONG_MACHINE", "This is a different Mac. Select the intended host before retrying.", details: ["machine": machine]) }
        guard let token = request["credential"] as? String else {
            guard !state.required else { throw AgentError("IDENTITY_REQUIRED", "Add an agent in Settings → Agents, then configure MYMAN_AGENT_TOKEN in that host.") }
            return .local
        }
        let hash = Self.digest(token)
        guard let agent = state.agents.first(where: { !$0.revoked && $0.digest == hash }) else { throw AgentError("INVALID_CREDENTIAL", "Agent credential is invalid or revoked.") }
        return AgentPrincipal(id: agent.id, name: agent.name, scopes: Set(agent.scopes))
    }
    func validate(_ principal: AgentPrincipal, action: String) throws {
        guard !unavailable else { throw AgentError("IDENTITY_UNAVAILABLE", "Cannot read the agent registry.") }
        if principal.id == "local" {
            guard !required else { throw AgentError("IDENTITY_REQUIRED", "Named agent credentials are now required.") }
        } else {
            guard state.agents.contains(where: { $0.id == principal.id && !$0.revoked }) else { throw AgentError("INVALID_CREDENTIAL", "This credential was revoked.") }
        }
        let scopes = Set(AgentConsent.requirements(action))
        guard scopes.isSubset(of: principal.scopes) else { throw AgentError("AGENT_SCOPE_DENIED", "This agent does not have access to this action.") }
    }
    func exists(_ id: String) -> Bool { state.agents.contains { $0.id == id && !$0.revoked } }
    var directory: [[String: Any]] { agents.filter { !$0.revoked }.map { ["id": $0.id, "name": $0.name] } }
}
