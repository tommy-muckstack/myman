import SwiftUI

struct AgentIdentitySettings: View {
    @ObservedObject private var registry = AgentIdentity.shared
    @State private var name = ""
    @State private var scopes: Set<String> = []
    @State private var credential = ""
    @State private var message = ""
    @State private var confirmReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Divider()
            Text("Your agents").font(MM.Fonts.title)
            Text("Give each bot its own credential. Its access is also limited by the switches above.")
                .foregroundStyle(MM.Colors.textSecondary)
            Toggle("Require named agent credentials", isOn: Binding(get: { registry.required }, set: { value in attempt { try registry.setRequired(value) } })).clickable()
            Text("Adding your first agent turns this on. Configure existing hosts before using them again.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            ForEach(registry.agents.filter { !$0.revoked }) { agent in
                HStack {
                    VStack(alignment: .leading) {
                        Text(agent.name)
                        Text(agent.scopes.joined(separator: ", ")).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    }
                    Spacer()
                    Button("Revoke") { attempt { try registry.revoke(agent.id) } }.clickable()
                }
            }
            TextField("Agent name, e.g. Capture Agent", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                ForEach(["capture", "markup", "recording", "library", "sharing", "control"], id: \.self) { scope in
                    Toggle(scope.capitalized, isOn: Binding(get: { scopes.contains(scope) }, set: { if $0 { scopes.insert(scope) } else { scopes.remove(scope) } })).clickable()
                }
            }
            Button("Add agent") {
                attempt { let (_, token) = try registry.issue(name: name, scopes: scopes); credential = token; name = ""; scopes = [] }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).clickable()
            if !credential.isEmpty {
                Text("Save this credential in your agent host as MYMAN_AGENT_TOKEN. It is shown only here until you dismiss it.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                Text(credential).font(MM.Fonts.metadata).textSelection(.enabled)
                Button("Done") { credential = "" }.clickable()
            }
            Text("Mac ID: \(registry.machine["id"] as? String ?? "")")
                .font(MM.Fonts.metadata).textSelection(.enabled)
            Text("Set MYMAN_MACHINE_ID in the host to verify this Mac before acting. Credentials coordinate app tools; they do not isolate programs sharing your macOS login or protect Brain files from those programs.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Button("Clear collaboration records…") { confirmReset = true }.clickable()
                .confirmationDialog("Clear bundles, handoffs, leases and session ownership? Captured items and active recordings remain. Use the recording controls to stop any active session.", isPresented: $confirmReset) {
                    Button("Clear records", role: .destructive) { attempt { try AgentCollaboration.shared.reset() } }
                }
            if !message.isEmpty { Text(message).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary) }
        }
    }
    private func attempt(_ body: () throws -> Void) { do { try body(); message = "" } catch { message = error.localizedDescription } }
}
