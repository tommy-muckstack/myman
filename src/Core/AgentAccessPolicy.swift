import Foundation

/// The one-switch access presets for agents, the rules that let the folder bridge
/// skip a prompt, and the grant check that asks for a missing grant in the same
/// dialog as the action. Grants themselves stay person-only: a preset is applied
/// from Settings, and nothing an agent sends can change one.
enum AgentAccessPreset: String, CaseIterable {
    case off, ask, trusted

    static let key = "agentAccessPreset"
    /// Grants a preset turns on. Sharing and mouse/keyboard control are never part of a preset.
    static let presetGrants = ["capture", "markup", "recording", "library"]

    var title: String {
        switch self { case .off: return "Off"; case .ask: return "Ask each time"; case .trusted: return "Trusted" }
    }
    var summary: String {
        switch self {
        case .off: return "Agents cannot use My Man. The Brain folder bridge is off and every grant is off."
        case .ask: return "Agents can use the Brain folder. My Man asks you before each screenshot, recording, clipboard use, or sharing."
        case .trusted: return "Screenshots and recordings run without asking. Clipboard, mouse and keyboard, deletes and sharing still ask you. Sharing stays off."
        }
    }
    static func current(_ defaults: UserDefaults = .standard) -> AgentAccessPreset? {
        AgentAccessPreset(rawValue: defaults.string(forKey: key) ?? "")
    }
    /// Sets the switch, the bridge, and the grants a preset owns. Everything else is left as the person set it.
    @MainActor func apply(_ defaults: UserDefaults = .standard) {
        let on = self != .off
        defaults.set(on, forKey: "agentActionsEnabled")
        defaults.set(on, forKey: AgentFolderBridge.enabledKey)
        for grant in AgentAccessPreset.presetGrants { defaults.set(on, forKey: AgentConsent.keys[grant]!) }
        if !on { for grant in AgentConsent.keys.keys where !AgentAccessPreset.presetGrants.contains(grant) { defaults.set(false, forKey: AgentConsent.keys[grant]!) } }
        else { defaults.set(false, forKey: AgentConsent.keys["sharing"]!); defaults.set(false, forKey: AgentConsent.keys["control"]!) }
        defaults.set(rawValue, forKey: AgentAccessPreset.key)
    }
}

/// A remembered approval: one agent, one action. Groups that must always ask
/// (delete, clipboard, sharing) are refused here as well as in the dialog.
struct AgentRule: Codable, Equatable, Identifiable {
    let id: String
    let requester: String
    let action: String
    let group: String
    let created: String
}

enum AgentRules {
    static let key = "agentAlwaysAllowRules"
    static let neverRemembered: Set<String> = ["delete", "clipboard", "sharing"]

    static func decode(_ text: String) -> [AgentRule] {
        guard let data = text.data(using: .utf8), let rules = try? JSONDecoder().decode([AgentRule].self, from: data) else { return [] }
        return rules
    }
    static func encode(_ rules: [AgentRule]) -> String {
        String(decoding: (try? JSONEncoder().encode(rules)) ?? Data("[]".utf8), as: UTF8.self)
    }
    static func all(_ defaults: UserDefaults = .standard) -> [AgentRule] { decode(defaults.string(forKey: key) ?? "") }
    static func save(_ rules: [AgentRule], _ defaults: UserDefaults = .standard) { defaults.set(encode(rules), forKey: key) }
    /// Returns nil when the group must keep asking.
    @discardableResult
    static func add(requester: String, action: String, group: String, created: String, _ defaults: UserDefaults = .standard) -> AgentRule? {
        guard !neverRemembered.contains(group) else { return nil }
        var rules = all(defaults)
        if let existing = rules.first(where: { $0.requester == requester && $0.action == action }) { return existing }
        let rule = AgentRule(id: UUID().uuidString, requester: requester, action: action, group: group, created: created)
        rules.append(rule)
        save(rules, defaults)
        return rule
    }
    static func match(requester: String, action: String, _ defaults: UserDefaults = .standard) -> AgentRule? {
        all(defaults).first { $0.requester == requester && $0.action == action }
    }
    static func remove(id: String, _ defaults: UserDefaults = .standard) { save(all(defaults).filter { $0.id != id }, defaults) }
    static func removeAll(_ defaults: UserDefaults = .standard) { save([], defaults) }
    /// A revoked grant takes its rules with it.
    static func removeGroup(_ group: String, _ defaults: UserDefaults = .standard) { save(all(defaults).filter { $0.group != group }, defaults) }
}

enum AgentApprovalVerdict: Equatable {
    case ask
    case approved(by: String, ruleID: String?)
}

enum AgentAccessPolicy {
    /// Decides whether a request the bridge would ask about may run without a prompt.
    static func verdict(action: String, group: String, requester: String, _ defaults: UserDefaults = .standard) -> AgentApprovalVerdict {
        if AgentAccessPreset.current(defaults) == .trusted, ["capture", "recording"].contains(group) {
            return .approved(by: "trusted_preset", ruleID: nil)
        }
        if let rule = AgentRules.match(requester: requester, action: action, defaults) {
            return .approved(by: "always_allow", ruleID: rule.id)
        }
        return .ask
    }

    /// Grants the action needs that are off. A global "Allow local app commands"
    /// switch that is off is not a grant to ask for, so nothing is offered then.
    @MainActor static func missingGrants(_ action: String, _ defaults: UserDefaults = .standard) -> [String] {
        guard defaults.object(forKey: "agentActionsEnabled") as? Bool ?? true else { return [] }
        if AgentConsent.cleanup.contains(action) || AgentConsent.diagnostic.contains(action) { return [] }
        return AgentConsent.requirements(action).filter { group in
            guard let key = AgentConsent.keys[group] else { return false }
            return !defaults.bool(forKey: key)
        }
    }

    static func grantTitle(_ grant: String) -> String {
        switch grant {
        case "capture": return "Screen capture"
        case "markup": return "Markup"
        case "recording": return "Recording"
        case "library": return "Library"
        case "sharing": return "Sharing"
        case "control": return "Mouse and keyboard"
        default: return grant.capitalized
        }
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
}
