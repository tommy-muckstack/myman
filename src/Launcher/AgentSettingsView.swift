import SwiftUI

struct AgentSettingsView: View {
    @AppStorage("agentActionsEnabled") private var enabled = true
    @AppStorage("agentCaptureEnabled") private var capture = false
    @AppStorage("agentMarkupEnabled") private var markup = false
    @AppStorage("agentRecordingEnabled") private var recording = false
    @AppStorage("agentLibraryEnabled") private var library = false
    @AppStorage("agentSharingEnabled") private var sharing = false
    @AppStorage("agentControlEnabled") private var control = false
    @AppStorage("agentCalendarReadEnabled") private var calendarRead = false
    @AppStorage("agentCalendarProposeEnabled") private var calendarPropose = false
    @AppStorage("agentSchedulingParseEnabled") private var schedulingParse = false
    @AppStorage("agentPeopleReadEnabled") private var peopleRead = false
    @AppStorage("agentCalendarWriteEnabled") private var calendarWrite = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text("Your tools, on your terms.").font(MM.Fonts.title)
            Text("Let an agent use My Man when you ask. Choose what it can do on this Mac.")
                .foregroundStyle(MM.Colors.textSecondary)
            Toggle("Allow local app commands", isOn: $enabled).clickable()
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Book events after I review and press Book", isOn: $calendarWrite).clickable()
                    .accessibilityHint("Also requires calendar read and macOS Calendar access. Agents can only open a preview. No invitations are sent.")
                Toggle("Prepare calendar event previews", isOn: $calendarPropose).clickable()
                    .accessibilityHint("Also requires calendar read access. Suggests times without booking or inviting guests.")
                Toggle("Read calendar free/busy", isOn: $calendarRead).clickable()
                    .accessibilityHint("Also requires Calendar access granted by you in macOS. Does not book meetings or send invitations.")
                Toggle("Parse meeting requests without accessing calendars", isOn: $schedulingParse).clickable()
                    .accessibilityHint("Only interprets supplied text. Does not read calendars, book events or invite guests.")
                Toggle("Resolve saved people and emails", isOn: $peopleRead).clickable()
                    .accessibilityHint("Reads saved People and meeting participants. Does not access Contacts or send invitations.")
                Toggle("Capture screenshots without the picker", isOn: $capture).clickable()
                Toggle("Edit screenshots and create fonts", isOn: $markup).clickable()
                Toggle("Control meetings, dictation and screen recordings", isOn: $recording).clickable()
                Toggle("Create and change notes, tasks and library items", isOn: $library).clickable()
                Toggle("Publish explicitly selected captures to shared links", isOn: $sharing).clickable()
                Toggle("Take over the mouse and keyboard to record app demos", isOn: $control).clickable()
            }.disabled(!enabled)
            Text("These permissions start off. Delete commands also require explicit confirmation. You can always stop an active recording, even after turning access off.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Text("Commands use a local connection under your Mac login. macOS permissions still apply. Brain retrieval is read-only; agents can read exported files independently of these settings. Content they request may be sent to their model provider.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Text("Agent setup: myman doctor --json\nCommand reference: myman --help\nNo screen to click? In Terminal on this Mac: myman agents grant capture (it asks you to confirm)")
                .font(MM.Fonts.metadata).textSelection(.enabled)
            Button("Recorded briefs and workflow templates…") { AgentBriefWindow.shared.open() }.clickable()
            Button("Connection checks and workflow activity…") { WorkflowCenter.shared.open(tab: "connection") }.clickable()
            AgentIdentitySettings()
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge) }
    }
}
