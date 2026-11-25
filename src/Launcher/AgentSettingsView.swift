import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// The Agents card: one switch-like preset, and the list of approvals remembered from prompts.
/// Individual grants are not shown here. They turn on when the person allows the matching prompt.
struct AgentSettingsView: View {
    @AppStorage(AgentAccessPreset.key) private var presetRaw = ""
    @AppStorage(AgentRules.key) private var rulesRaw = ""
    @AppStorage(PauseEverything.pausedKey) private var paused = false

    private var preset: AgentAccessPreset { AgentAccessPreset(rawValue: presetRaw) ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let Claude and other agents use MyMan").font(MM.Fonts.title)
            Text("Agents ask through this Mac and can only do what you allow here.")
                .foregroundStyle(MM.Colors.textSecondary)

            ClaudeDesktopConnectionCard()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(paused ? "Paused" : (preset == .off ? "Off" : "On: \(preset.title)"))
                        .font(MM.Fonts.secondary)
                    Spacer()
                    if preset == .off && !paused {
                        Button("Turn on") { AgentAccessPreset.ask.apply(); presetRaw = AgentAccessPreset.ask.rawValue }
                            .clickable()
                    }
                }
                Picker("Agent access", selection: Binding(
                    get: { preset },
                    set: { choice in choice.apply(); presetRaw = choice.rawValue })) {
                    ForEach(AgentAccessPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().clickable()
                .disabled(paused)
                Text(preset.summary)
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                if paused {
                    Text("Paused from Privacy. Resume there and these choices come back as they were.")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Always allowed").font(MM.Fonts.secondary)
                    Spacer()
                    if !AgentRules.decode(rulesRaw).isEmpty {
                        Button("Revoke all") { rulesRaw = AgentRules.encode([]) }.clickable()
                    }
                }
                if AgentRules.decode(rulesRaw).isEmpty {
                    Text("Nothing yet. Choose Always allow this action in a prompt to add one.")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
                ForEach(AgentRules.decode(rulesRaw)) { rule in
                    HStack {
                        Text("\(rule.requester): \(rule.action)").textSelection(.enabled)
                        Spacer()
                        Button("Revoke") { rulesRaw = AgentRules.encode(AgentRules.decode(rulesRaw).filter { $0.id != rule.id }) }.clickable()
                    }
                }
            }

            Text("Deletes, clipboard writes and sharing always ask. Your Mac's permissions still apply; see Privacy.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
        .padding(MM.Layout.paddingLarge)
    }
}

/// Advanced agent permissions that are not part of a preset. Each one asks in the moment too.
struct AgentAdvancedSettings: View {
    @AppStorage("agentControlEnabled") private var control = false
    @AppStorage("agentCalendarReadEnabled") private var calendarRead = false
    @AppStorage("agentCalendarProposeEnabled") private var calendarPropose = false
    @AppStorage("agentCalendarWriteEnabled") private var calendarWrite = false
    @AppStorage("agentSchedulingParseEnabled") private var schedulingParse = false
    @AppStorage("agentPeopleReadEnabled") private var peopleRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent permissions outside the presets").font(MM.Fonts.secondary)
            Toggle("Read calendar free and busy times", isOn: $calendarRead).clickable()
            Toggle("Prepare calendar event previews", isOn: $calendarPropose).clickable()
            Toggle("Book events after I review and press Book", isOn: $calendarWrite).clickable()
                .accessibilityHint("Agents only open a preview. No invitations are sent.")
            Toggle("Parse meeting requests from pasted text", isOn: $schedulingParse).clickable()
            Toggle("Look up saved people and emails", isOn: $peopleRead).clickable()
            Toggle("Take over the mouse and keyboard to record app demos", isOn: $control).clickable()
                .onChange(of: control) { _, on in if !on { AgentRules.removeGroup("control") } }
            Text("Each one is off until you turn it on. Agents still ask before they use it.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Button("Recorded briefs and workflow templates…") { AgentBriefWindow.shared.open() }.clickable()
            Button("Connection checks and workflow activity…") { WorkflowCenter.shared.open(tab: "connection") }.clickable()
            AgentIdentitySettings()
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
    }
}

/// Brain folder: where agents leave requests, and whether My Man is answering them.
struct BrainFolderSettings: View {
    @AppStorage(AgentAccessPreset.key) private var presetRaw = ""
    @State private var connected = false
    @State private var checked = false

    private var agentsOn: Bool { (AgentAccessPreset(rawValue: presetRaw) ?? .off) != .off }
    private var folder: URL { Brain.root.appendingPathComponent("agent", isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Brain folder").font(MM.Fonts.title)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(MM.Fonts.metadata).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Circle().fill(connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(!agentsOn ? "Off. Turn on agents to accept requests here."
                     : connected ? "Connected. My Man is answering requests."
                     : "Needs attention. Open MyMan once and check Privacy.")
                    .font(MM.Fonts.secondary)
            }
            Text("Agents that can only reach this Mac through a folder leave requests here. The same permissions apply as for direct access.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            Button("Open folder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }.clickable()
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
        .padding(MM.Layout.paddingLarge)
        .onAppear(perform: refresh)
    }

    /// Connected means the app wrote its heartbeat recently. Nothing else is checked here.
    private func refresh() {
        let heartbeat = folder.appendingPathComponent("heartbeat.json")
        let modified = (try? FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate]) as? Date
        connected = agentsOn && (modified.map { Date().timeIntervalSince($0) < 30 } ?? false)
        checked = true
    }
}

/// Privacy: what My Man can reach on this Mac, live, with a Fix button for each.
struct PrivacySettingsView: View {
    @State private var status: [PrivacyPermission: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy").font(MM.Fonts.title)
            Text("What My Man can reach on this Mac. Each Fix opens the right page in System Settings.")
                .foregroundStyle(MM.Colors.textSecondary)
            ForEach(PrivacyPermission.allCases) { permission in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill((status[permission] ?? false) ? Color.green : Color.orange).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(MM.Fonts.secondary)
                        Text(permission.why).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    }
                    Spacer()
                    if status[permission] == true {
                        Text("Allowed").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    } else {
                        Button("Fix") { NSWorkspace.shared.open(permission.settingsURL) }.clickable()
                    }
                }
            }
        }
        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary)
        .padding(MM.Layout.paddingLarge)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        status = [
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            .accessibility: AXIsProcessTrusted(),
        ]
    }
}
