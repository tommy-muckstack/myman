import AppKit
import SwiftUI

/// Asks the person about one Brain folder request at a time. The window floats
/// without taking keyboard focus, so a key pressed mid-sentence in another app
/// can never allow a request. Closing it is the same as Deny.
@MainActor final class AgentApprovalWindow: NSObject, NSWindowDelegate {
    static let shared = AgentApprovalWindow()
    private struct Pending {
        let request: AgentApprovalRequest
        let deadline: Date
        let continuation: CheckedContinuation<AgentApprovalDecision, Never>
    }
    private var queue: [Pending] = []
    private var window: NSWindow?
    private var timer: Timer?
    private var closing = false

    func ask(_ request: AgentApprovalRequest, deadline: Date) async -> AgentApprovalDecision {
        guard queue.count < 8 else { return .deny }
        return await withCheckedContinuation { continuation in
            queue.append(Pending(request: request, deadline: deadline, continuation: continuation))
            if queue.count == 1 { present() }
        }
    }

    func dismissAll() { while !queue.isEmpty { resolve(.deny) } }

    private func present() {
        guard let pending = queue.first else { return }
        guard pending.deadline > Date() else { resolve(.expired); return }
        let view = AgentApprovalView(request: pending.request) { [weak self] decision in self?.resolve(decision) }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "An agent is asking"; window.isReleasedWhenClosed = false; window.delegate = self
        window.level = .floating; window.contentView = hosting
        self.window = window; window.center(); window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, pending.deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resolve(.expired) }
        }
    }

    private func resolve(_ decision: AgentApprovalDecision) {
        guard !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        timer?.invalidate(); timer = nil
        closing = true; window?.close(); window = nil; closing = false
        pending.continuation.resume(returning: decision)
        // "Always allow this action" also answers the same agent's waiting requests for that action.
        if decision == .allowAlways {
            while let next = queue.first, next.request.action == pending.request.action, next.request.requester == pending.request.requester, next.request.canRemember {
                queue.removeFirst(); next.continuation.resume(returning: .allowOnce)
            }
        }
        present()
    }

    func windowWillClose(_ notification: Notification) { if !closing { resolve(.deny) } }
}

struct AgentApprovalView: View {
    let request: AgentApprovalRequest
    let decide: (AgentApprovalDecision) -> Void
    /// Plain words for what will happen, from the grant or group the request needs.
    private var kind: String {
        if !request.grants.isEmpty {
            let names = request.grants.map { grant -> String in
                switch grant {
                case "recording": return "record"
                case "capture": return "look at your screen"
                case "control": return "move the mouse and type"
                case "sharing": return "publish a shared link"
                default: return "use \(AgentAccessPolicy.grantTitle(grant).lowercased())"
                }
            }
            return names.joined(separator: " and ")
        }
        switch request.group {
        case "capture": return "look at your screen"
        case "recording": return "record or use a meeting or dictation"
        case "control": return "move the mouse and type"
        case "clipboard": return "use your clipboard"
        case "sharing": return "publish a shared link"
        default: return "delete something"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.paddingLarge) {
            HStack {
                Image(systemName: "hand.raised.fill").font(MM.Fonts.result).foregroundStyle(MM.Colors.accent)
                Spacer()
                Text("BRAIN FOLDER REQUEST").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text("Allow this?").font(MM.Fonts.result)
                Text(request.grants.isEmpty
                     ? "\(request.requester) wants to \(kind). The request came through your Brain folder."
                     : "\(request.requester) wants to \(kind). Turn on \(request.grants.map(AgentAccessPolicy.grantTitle).joined(separator: ", ")) and allow this?")
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text(request.action).font(MM.Fonts.title).textSelection(.enabled)
                if !request.summary.isEmpty { Text(request.summary).fixedSize(horizontal: false, vertical: true) }
                if !request.detail.isEmpty {
                    Text(request.detail).font(.system(.caption, design: .monospaced)).foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.font(MM.Fonts.body).padding(MM.Layout.padding).frame(maxWidth: .infinity, alignment: .leading)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
            Text("Nothing runs until you choose. Closing this window denies it.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            HStack(spacing: MM.Layout.spacing) {
                Button("Deny") { decide(.deny) }.keyboardShortcut(.cancelAction).clickable()
                Spacer()
                if request.canRemember && request.grants.isEmpty {
                    Button("Always allow this action") { decide(.allowAlways) }.clickable()
                        .accessibilityHint("Lets \(request.requester) run \(request.action) from the Brain folder without asking again. Revoke it in Settings → Agents.")
                }
                Button { decide(.allowOnce) } label: {
                    Text(request.grants.isEmpty ? "Allow once" : "Turn on and allow").font(MM.Fonts.body).foregroundStyle(MM.Colors.onAccent)
                        .padding(.horizontal, MM.Layout.paddingLarge).padding(.vertical, MM.Layout.spacing)
                        .background(MM.Colors.accent, in: Capsule()).clickable()
                }.accessibilityLabel(request.grants.isEmpty ? "Allow this request once" : "Turn on the permission and allow this request")
            }.buttonStyle(.plain)
        }.padding(MM.Layout.paddingLarge).frame(width: MM.Layout.bookingWidth)
            .foregroundStyle(MM.Colors.textPrimary).background(MM.Colors.background)
    }
}
