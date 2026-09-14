import AppKit
import Combine
import CryptoKit

enum WorkflowValues {
    static func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}

@MainActor final class WorkflowConnection: ObservableObject {
    static let shared = WorkflowConnection()
    @Published private(set) var challenge = ""
    @Published private(set) var issuedAt: Date?
    @Published private(set) var agentName = ""
    @Published private(set) var connectedAt: Date?
    @Published private(set) var attachmentConfirmed = false
    func start() {
        challenge = UUID().uuidString
        issuedAt = Date(); connectedAt = nil; agentName = ""; attachmentConfirmed = false
    }
    var prompt: String {
        """
        Verify My Man on my Mac using your approved local-computer execution. Run:
        myman workflow handshake --challenge \(challenge) --machine \(AgentIdentity.shared.machine["id"] as? String ?? "") --json
        Return the generated connection-check image as a visible attachment in this conversation. Do not claim delivery succeeded unless the attachment is displayed. If local execution is unavailable, explain the missing host capability and use a file I explicitly attach instead. Do not ask me to paste credentials into chat.
        """
    }
    func handshake(_ value: String) throws -> [String: Any] {
        guard !challenge.isEmpty, value == challenge, let issuedAt, Date().timeIntervalSince(issuedAt) < 600 else { throw AgentError("CONNECTION_CHECK_EXPIRED", "Generate a new connection check in My Man → Workflows → Connection.") }
        guard AgentContext.principal.id != "local" else { throw AgentError("IDENTITY_REQUIRED", "Use a named agent credential for this connection check.") }
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        NSColor(MM.Colors.background).setFill(); NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        let copy = "My Man\nConnection check\n\nMac command received\n\n\(String(challenge.prefix(8)))"
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (copy as NSString).draw(in: NSRect(x: 48, y: 100, width: 416, height: 320), withAttributes: [.paragraphStyle: paragraph, .font: MM.Fonts.native(26), .foregroundColor: NSColor(MM.Colors.textPrimary)])
        image.unlockFocus()
        let attachment = try AgentMediaStore.shared.image(image)
        connectedAt = Date()
        agentName = AgentIdentity.shared.agents.first { $0.id == AgentContext.principal.id }?.name ?? "Named agent"
        return ["machine": AgentIdentity.shared.machine, "local_command_received": true, "host_attachment_delivery": "awaiting_human_confirmation", "attachment": attachment, "challenge": String(challenge.prefix(8))]
    }
    func confirmAttachment() { if connectedAt != nil { attachmentConfirmed = true } }
}
