import SwiftUI
import AppKit

struct ShareSettingsView: View {
    @ObservedObject private var sharing = SharePublishing.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message = ""
    @State private var busy = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Shared links").font(MM.Fonts.title)
            Text("Sharing is optional. A link gives anyone holding it access until it expires or you revoke it. Downloaded copies remain with their recipients.").font(MM.Fonts.secondary)
            DisclosureGroup("Configure your sharing service") {
                TextField("HTTPS service address", text: $endpoint).textFieldStyle(.roundedBorder)
                SecureField("Publishing credential", text: $token).textFieldStyle(.roundedBorder)
                Button("Save connection in Keychain") { do { try sharing.configure(endpoint: endpoint, token: token); token = ""; message = "Sharing connection saved." } catch { message = error.localizedDescription } }.clickable()
                Link("Service setup instructions", destination: URL(string: "https://github.com/tommy-muckstack/myman/tree/main/integrations/share-service")!).clickable()
            }.clickable()
            if sharing.receipts.isEmpty { Text("Choose Share from a capture's menu to publish it.") }
            ForEach(sharing.receipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Text(receipt.title).font(MM.Fonts.body)
                    Text("\(receipt.state.replacingOccurrences(of: "_", with: " ").capitalized) · Expires \(receipt.expiresAt.formatted())").font(MM.Fonts.metadata)
                    if receipt.state == "published", receipt.expiresAt > Date() {
                        Text(receipt.url).textSelection(.enabled).font(MM.Fonts.secondary)
                        Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(receipt.url, forType: .string) }.clickable()
                    }
                    if receipt.state != "revoked" {
                        Button("Revoke link") { busy.insert(receipt.id); Task { do { try await sharing.revoke(receipt.id); message = "The server confirmed revocation." } catch { message = error.localizedDescription }; busy.remove(receipt.id) } }.disabled(busy.contains(receipt.id)).clickable()
                    }
                }.padding(MM.Layout.spacing).background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            }
            Text(message).font(MM.Fonts.secondary)
        }.onAppear { endpoint = sharing.endpoint }
    }
}

@MainActor enum CaptureShare {
    static func open(_ item: CaptureItem) {
        guard !SharePublishing.shared.endpoint.isEmpty else { WorkflowCenter.shared.open(tab: "sharing"); return }
        let alert = NSAlert(); alert.messageText = "Share this capture?"
        alert.informativeText = "\(item.title)\n\n\(item.kind == "screenshot" ? "The original screenshot" : "The title and captured text") will be uploaded. Anyone with the link can view it. The link expires in 24 hours, and you can revoke it in Workflows → Sharing."
        alert.addButton(withTitle: "Publish for 24 hours"); alert.addButton(withTitle: "Preview first"); alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if result == .alertSecondButtonReturn { CaptureDetailController.shared.open(item); return }
        guard result == .alertFirstButtonReturn else { return }
        Task {
            do { let receipt = try await SharePublishing.shared.publish(item: item, seconds: 86400); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(receipt.url, forType: .string); Toast.show("Share link copied. Expires in 24 hours.", actionLabel: "Manage", action: { WorkflowCenter.shared.open(tab: "sharing") }) }
            catch { Toast.show(error.localizedDescription, actionLabel: "Review", action: { WorkflowCenter.shared.open(tab: "sharing") }, duration: 12) }
        }
    }
}
