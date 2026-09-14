import SwiftUI

struct AgentSettingsView: View {
    @AppStorage("agentActionsEnabled") private var enabled = true
    @AppStorage("agentCaptureEnabled") private var capture = false
    @AppStorage("agentMarkupEnabled") private var markup = false
    @AppStorage("agentRecordingEnabled") private var recording = false
    @AppStorage("agentLibraryEnabled") private var library = false
    @AppStorage("agentSharingEnabled") private var sharing = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text("Your tools, on your terms.").font(MM.Fonts.title)
            Text("Let an agent use My Man when you ask. Choose what it can do on this Mac.")
                .foregroundStyle(MM.Colors.textSecondary)
            Toggle("Allow local app commands", isOn: $enabled).clickable()
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Capture screenshots without the picker", isOn: $capture).clickable()
                Toggle("Edit screenshots and create fonts", isOn: $markup).clickable()
                Toggle("Control meetings, dictation and screen recordings", isOn: $recording).clickable()
                Toggle("Create and change notes, tasks and library items", isOn: $library).clickable()
                Toggle("Publish explicitly selected captures to shared links", isOn: $sharing).clickable()
            }.disabled(!enabled)
            Text("These permissions start off. Delete commands also require explicit confirmation. You can always stop an active recording, even after turning access off.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Text("Commands use a local connection under your Mac login. macOS permissions still apply. Brain retrieval is read-only; agents can read exported files independently of these settings. Content they request may be sent to their model provider.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Text("Agent setup: myman doctor --json\nCommand reference: myman --help")
                .font(MM.Fonts.metadata).textSelection(.enabled)
            Button("Recorded briefs and workflow templates…") { AgentBriefWindow.shared.open() }.clickable()
            Button("Connection checks and workflow activity…") { WorkflowCenter.shared.open(tab: "connection") }.clickable()
            AgentIdentitySettings()
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge) }
    }
}
