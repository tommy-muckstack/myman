import AppKit
import SwiftUI

@MainActor final class WorkflowCenter {
    static let shared = WorkflowCenter()
    private var window: NSWindow?
    func open(tab: String = "activity") {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "My Man · Workflows"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 560)
            self.window = window; window.center()
        }
        window?.contentView = NSHostingView(rootView: WorkflowCenterView(initialTab: tab))
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WorkflowCenterView: View {
    var initialTab: String
    @State private var tab = "activity"
    private var navigation: some View {
        Picker("Workflow view", selection: $tab) {
            Text("Connection").tag("connection"); Text("Activity").tag("activity")
            Text("Dictation").tag("dictation"); Text("Meeting decisions").tag("meetings"); Text("Sharing").tag("sharing")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Your work, from capture to result").font(MM.Fonts.title)
            Group {
                if MM.Fonts.interfaceScale > 1.1 { navigation.pickerStyle(.menu) }
                else { navigation.pickerStyle(.segmented) }
            }.clickable()
            ScrollView {
                switch tab {
                case "connection": WorkflowConnectionView()
                case "dictation": DictationRecoveryView()
                case "meetings": MeetingDecisionsView()
                case "sharing": ShareSettingsView()
                default: WorkflowActivityView()
                }
            }
        }.padding(MM.Layout.paddingLarge).font(MM.Fonts.body).foregroundStyle(MM.Colors.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(MM.Colors.background)
            .onAppear { tab = initialTab }
    }
}

private struct WorkflowConnectionView: View {
    @ObservedObject private var connection = WorkflowConnection.shared
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Connect Grok Bot to this Mac").font(MM.Fonts.title)
            Text("Grok Bot's cloud computer is separate from this Mac. Enable its local-computer capability and approve access to this Mac in Grok Bot.")
            Text("1. In My Man Settings → Agents, choose the allowed actions and create a named agent. Save its credential in your host's secret settings as MYMAN_AGENT_TOKEN.")
            Button("Open agent settings") { SettingsController.shared.show() }.clickable()
            Text("2. Set MYMAN_MACHINE_ID in the host to this Mac ID:").font(MM.Fonts.secondary)
            Text(AgentIdentity.shared.machine["id"] as? String ?? "").textSelection(.enabled).font(MM.Fonts.metadata)
            Text("3. Run a connection check from your Bot. My Man must be open and this Mac available.")
            Button("Generate connection check") { connection.start() }.clickable()
            if !connection.challenge.isEmpty {
                Text(connection.prompt).font(MM.Fonts.secondary).textSelection(.enabled)
                Button("Copy check prompt") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(connection.prompt, forType: .string) }.clickable()
            }
            if let at = connection.connectedAt {
                Label("Mac command received from \(connection.agentName) at \(at.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                if connection.attachmentConfirmed { Label("You confirmed that the check image appeared in Grok Bot.", systemImage: "checkmark.circle") }
                else { Button("I can see the check image in Grok Bot") { connection.confirmAttachment() }.clickable() }
            } else { Text("Host connection has not been verified.").foregroundStyle(MM.Colors.textSecondary) }
            Divider()
            Text("Use selected files without a live connection").font(MM.Fonts.title)
            Text("Open a capture's preview and export the selected context. Drag the resulting files into Grok Bot. Review what is included before handing it off; this works without granting access to your full library.")
            Button("Choose captures to attach") { WorkflowContext.show() }.clickable()
            Button("Open recorded briefs") { AgentBriefWindow.shared.open() }.clickable()
            Link("Grok Bot local-computer instructions", destination: URL(string: "https://docs.x.ai/grok-bot/computer-and-apps")!).clickable()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkflowActivityView: View {
    @State private var selected: String?
    @State private var jobs: [[String: Any]] = []
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Activity and recovery").font(MM.Fonts.title)
            Button("Choose a window or area to capture") { CaptureChooser.shared.open() }.clickable()
            Text("Inspect the result of an interrupted command before starting new work. Requests are never replayed automatically.").font(MM.Fonts.secondary)
            if jobs.isEmpty { Text("Agent activity will appear here after a command runs.") }
            ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                let id = job["id"] as? String ?? ""
                VStack(alignment: .leading, spacing: 6) {
                    Button { selected = selected == id ? nil : id } label: {
                        HStack { Text(job["action"] as? String ?? "Command"); Spacer(); Text(job["state"] as? String ?? "Unknown") }
                    }.buttonStyle(.plain).clickable().accessibilityLabel("\(job["action"] as? String ?? "Command"), \(job["state"] as? String ?? "Unknown"). Show details")
                    if selected == id, let detail = AgentJournal.shared.job(id) {
                        Text("Request \(id)").font(MM.Fonts.metadata).textSelection(.enabled)
                        if let inputs = detail["inputs"] as? [String: Any] {
                            ForEach(inputs.keys.sorted(), id: \.self) { key in
                                Text("\(key.replacingOccurrences(of: "_", with: " ")): \(String(describing: inputs[key]!))").font(MM.Fonts.metadata).textSelection(.enabled)
                                if let itemID = inputs[key] as? String, let item = CaptureIndex.item(itemID) { Button("Inspect source: " + item.title) { CaptureDetailController.shared.open(item) }.clickable() }
                            }
                        }
                        if job["state"] as? String == "running", WorkflowActivity.cancellable.contains(job["action"] as? String ?? "") {
                            Button("Request stop") { do { try WorkflowActivity.cancel(id, true); Toast.show("Stop requested. Wait for the final activity status.") } catch { Toast.show(error.localizedDescription) } }.clickable()
                        }
                        if let error = detail["error"] as? [String: Any] { Text(error["message"] as? String ?? "The command failed.") }
                        if let result = detail["result"] as? [String: Any] {
                            if let itemID = result["id"] as? String, let item = CaptureIndex.item(itemID) {
                                Button("Inspect saved result") { CaptureDetailController.shared.open(item) }.clickable()
                            }
                            Text(Self.describe(result)).font(MM.Fonts.secondary).textSelection(.enabled)
                        }
                        Text("Resume from the saved result in a new brief, or ask the agent to inspect this request ID before continuing.").font(MM.Fonts.secondary)
                        Button("Copy continuation prompt") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(WorkflowActivity.continuation(detail), forType: .string) }.clickable()
                        Button("Open briefs to continue") { AgentBriefWindow.shared.open() }.clickable()
                    }
                }.padding(MM.Layout.spacing).background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            }
        }.onAppear { jobs = AgentJournal.shared.list() }.onReceive(timer) { _ in jobs = AgentJournal.shared.list() }
    }
    private static func describe(_ value: [String: Any]) -> String {
        let selected = value.filter { ["id", "kind", "path", "session_id", "state", "recovery_status", "message"].contains($0.key) }
        return selected.keys.sorted().map { "\($0): \(selected[$0]!)" }.joined(separator: "\n")
    }
}

private struct DictationRecoveryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @State private var selected: String?
    @State private var correction = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Dictation delivery and corrections").font(MM.Fonts.title)
            Text("Unverified means the app could not confirm insertion. Inspect the destination before pasting again. Correct text here to keep the final version and teach vocabulary from your own edits.").font(MM.Fonts.secondary)
            if history.entries.isEmpty { Text("Your next dictation will appear here with its delivery status.") }
            ForEach(history.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(entry.createdAt.formatted()); Spacer(); Text(entry.outcome.state.capitalized) }.font(MM.Fonts.metadata)
                    Text(entry.correctedText ?? entry.text).textSelection(.enabled)
                    Text(entry.outcome.reason).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                    HStack {
                        Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.correctedText ?? entry.text, forType: .string) }.clickable()
                        Button("Correct") { selected = entry.id; correction = entry.correctedText ?? entry.text }.clickable()
                    }
                    if selected == entry.id {
                        TextEditor(text: $correction).font(MM.Fonts.body).frame(minHeight: 110).accessibilityLabel("Corrected dictation")
                        Button("Save correction") { do { try history.correct(entry.id, text: correction); selected = nil; message = "Correction saved." } catch { message = error.localizedDescription } }.clickable()
                    }
                }.padding(MM.Layout.spacing).background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            }
            Text(message).font(MM.Fonts.secondary)
        }
    }
}
