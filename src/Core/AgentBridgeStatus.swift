import Foundation

/// What the menu bar says about the Brain folder: is My Man answering, when did the last request arrive,
/// and how many requests are waiting for the person. Reads files only; it never changes them.
struct AgentBridgeStatus: Equatable {
    enum Connection: Equatable { case off, connected, needsAttention }

    let connection: Connection
    let lastRequest: Date?
    let waitingForPerson: Int

    /// The menu line, in plain words.
    var line: String {
        switch connection {
        case .off: return "Brain folder: off"
        case .needsAttention: return "Brain folder: needs attention"
        case .connected:
            var text = "Brain folder: connected"
            if waitingForPerson > 0 { text += " · \(waitingForPerson) waiting for you" }
            if let lastRequest { text += " · last request \(Self.ago(lastRequest))" }
            return text
        }
    }

    static func read(root: URL, agentsOn: Bool, now: Date = Date()) -> AgentBridgeStatus {
        guard agentsOn else { return AgentBridgeStatus(connection: .off, lastRequest: nil, waitingForPerson: 0) }
        let fm = FileManager.default
        let heartbeat = root.appendingPathComponent("heartbeat.json")
        let beat = (try? fm.attributesOfItem(atPath: heartbeat.path)[.modificationDate]) as? Date
        let connected = beat.map { now.timeIntervalSince($0) < 30 } ?? false
        let inbox = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("inbox"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let outbox = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("outbox"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let requestTimes = (inbox + outbox).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let waiting = outbox.filter { url in
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["pending"] as? Bool == true
        }.count
        return AgentBridgeStatus(connection: connected ? .connected : .needsAttention,
                                 lastRequest: requestTimes.max(), waitingForPerson: waiting)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}
