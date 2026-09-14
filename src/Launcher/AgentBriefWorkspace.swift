import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentBriefWindow {
    static let shared = AgentBriefWindow()
    private var window: NSWindow?
    func open(recording: CaptureItem? = nil, briefID: String? = nil) {
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "My Man · Agent briefs"
        window.contentView = NSHostingView(rootView: AgentBriefWorkspace(recording: recording, initialBriefID: briefID))
        window.minSize = NSSize(width: 820, height: 600)
        if self.window == nil { window.center() }
        self.window = window; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}

struct AgentBriefWorkspace: View {
    var recording: CaptureItem?
    var initialBriefID: String?
    @ObservedObject private var store = AgentBriefs.shared
    @State private var selected: String?
    @State private var creating = false
    @State private var error = ""
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                Text("Agent briefs").font(MM.Fonts.title)
                Text("Show your bots what you mean.").foregroundStyle(MM.Colors.textSecondary)
                Button("New recorded brief") { creating = true; selected = nil }.clickable()
                ScrollView {
                    VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                        ForEach((try? store.list(human: true)) ?? []) { brief in
                            Button { selected = brief.id; creating = false } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(brief.title).font(MM.Fonts.body).lineLimit(2)
                                    Text(brief.stage.replacingOccurrences(of: "_", with: " ").capitalized).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(MM.Layout.spacing)
                                    .background(selected == brief.id ? MM.Colors.surface : MM.Colors.background)
                                    .clipShape(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                            }.buttonStyle(.plain).clickable()
                        }
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(MM.Colors.textSecondary) }
            }.padding(MM.Layout.paddingLarge).frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            Group {
                if creating { AgentBriefComposer(recording: recording) { id in selected = id; creating = false } }
                else if let selected, let brief = try? store.read(selected, human: true) { AgentBriefDetail(brief: brief).id(brief.id + ":" + String(brief.revision)) }
                else {
                    VStack(alignment: .leading, spacing: MM.Layout.padding) {
                        Text("One recording. A clear result.").font(MM.Fonts.title)
                        Text("Choose a recording, describe the outcome, then assign a worker and an independent reviewer.").foregroundStyle(MM.Colors.textSecondary)
                        ForEach(AgentBriefs.recipes, id: \.self) { recipe in
                            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                                Text(AgentWorkflowTemplates.title(recipe)).font(MM.Fonts.body)
                                Text(AgentWorkflowTemplates.criteria(recipe).joined(separator: "\n")).foregroundStyle(MM.Colors.textSecondary)
                                Button("Copy starter prompt") { copyBriefText(AgentWorkflowTemplates.prompt(recipe)) }.clickable()
                            }.padding(MM.Layout.padding).background(MM.Colors.surface).clipShape(RoundedRectangle(cornerRadius: MM.Layout.radius))
                        }
                        Text("Assignments appear here. Your agent host starts the work and returns the files.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    }.padding(MM.Layout.paddingLarge).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(minWidth: 500)
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).background(MM.Colors.background)
            .onAppear {
                creating = recording != nil
                selected = initialBriefID
                do { _ = try store.list(human: true) } catch { self.error = error.localizedDescription }
            }
    }
}

private struct AgentBriefComposer: View {
    var recording: CaptureItem?
    var saved: (String) -> Void
    @State private var recordings: [CaptureItem] = []
    @State private var sourceID = ""
    @State private var title = ""
    @State private var outcome = ""
    @State private var recipe = "bug-fix"
    @State private var criteria = AgentWorkflowTemplates.criteria("bug-fix").joined(separator: "\n")
    @State private var times = ""
    @State private var error = ""
    @State private var saving = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MM.Layout.padding) {
                Text("Turn a recording into a brief").font(MM.Fonts.title)
                Text("The original recording stays in your library. Bots receive the context needed to do this job.").foregroundStyle(MM.Colors.textSecondary)
                Picker("Workflow", selection: $recipe) { ForEach(AgentBriefs.recipes, id: \.self) { Text(AgentWorkflowTemplates.title($0)).tag($0) } }.clickable()
                    .onChange(of: recipe) { _, value in criteria = AgentWorkflowTemplates.criteria(value).joined(separator: "\n") }
                Picker("Source recording", selection: $sourceID) {
                    Text("Choose a recording").tag("")
                    ForEach(recordings) { Text($0.title).tag($0.id) }
                }.clickable()
                if recordings.isEmpty { Text("Record a short walkthrough in My Man, then return here.").foregroundStyle(MM.Colors.textSecondary) }
                TextField("Brief title", text: $title).textFieldStyle(.roundedBorder)
                Text("What should be different when the work is finished?").font(MM.Fonts.body)
                TextEditor(text: $outcome).frame(minHeight: 80).accessibilityLabel("Desired outcome")
                Text("Acceptance criteria · one per line").font(MM.Fonts.body)
                TextEditor(text: $criteria).frame(minHeight: 100).accessibilityLabel("Acceptance criteria")
                TextField("Key moments in seconds, separated by commas (optional)", text: $times).textFieldStyle(.roundedBorder)
                Text("Leave key moments empty for four evenly sampled frames. Transcript text has no word-level timestamps.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                if !error.isEmpty { Text(error).foregroundStyle(MM.Colors.textSecondary).textSelection(.enabled) }
                Button(saving ? "Preparing recording…" : "Save brief") { Task { await save() } }.clickable().disabled(saving || sourceID.isEmpty || title.isEmpty || outcome.isEmpty)
            }.padding(MM.Layout.paddingLarge)
        }.task {
            let provided = recording
            recordings = (try? await Task.detached { try CaptureIndex.history(filter: CaptureFilter(kind: "recording"), limit: 200) }.value) ?? []
            if let provided, !recordings.contains(where: { $0.id == provided.id }) { recordings.insert(provided, at: 0) }
            if let provided { sourceID = provided.id; title = provided.title }
        }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let values = times.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try times.split(separator: ",", omittingEmptySubsequences: false).map { value -> Double in
                guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else { throw AgentError("INVALID_ARGUMENTS", "Use comma-separated seconds for key moments.") }; return number
            }
            let brief = try await AgentBriefs.shared.createValidated(title: title, outcome: outcome, recipe: recipe, criteria: criteria.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, sourceIDs: [sourceID], frameTimes: values, human: true)
            saved(brief.id)
        } catch { self.error = (error as? AgentError)?.message ?? error.localizedDescription }
    }
}

private struct AgentBriefDetail: View {
    let brief: AgentBriefs.Brief
    @ObservedObject private var identities = AgentIdentity.shared
    @State private var worker = ""
    @State private var reviewer = ""
    @State private var error = ""
    @State private var sharing = false
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MM.Layout.padding) {
                Text(brief.title).font(MM.Fonts.title)
                Text(brief.stage.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(MM.Colors.accent)
                Text(brief.outcome).textSelection(.enabled)
                Text("Acceptance criteria").font(MM.Fonts.body)
                ForEach(Array(brief.criteria.enumerated()), id: \.offset) { index, criterion in
                    let check = brief.checks.first { $0.criterion == index }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(check.map { $0.passed ? "✓" : "↻" } ?? "○")  \(criterion)")
                        if let check { Text(check.note).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary) }
                    }
                }
                Text("Original context").font(MM.Fonts.body)
                ForEach(brief.sources, id: \.id) { ref in
                    if let item = CaptureIndex.item(ref.id) { Button(item.title) { CaptureActions.open(item) }.clickable() }
                }
                if !AgentBriefs.shared.sourcesCurrent(brief) {
                    Text("Source material changed. Refresh the brief and request a new review.").foregroundStyle(MM.Colors.textSecondary)
                }
                if ["draft", "changes_requested"].contains(brief.stage) {
                    Picker("Worker", selection: $worker) { agentOptions }.clickable()
                    Picker("Reviewer", selection: $reviewer) { agentOptions }.clickable()
                    Button("Assign brief") { perform { _ = try AgentBriefs.shared.handoff(brief.id, expected: brief.revision, worker: worker, reviewer: reviewer, human: true) } }.clickable().disabled(worker.isEmpty || reviewer.isEmpty || worker == reviewer)
                    Text("Add named agents with library access in Settings → Agents. The reviewer must be a different agent.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
                if let worker = brief.worker, let reviewer = brief.reviewer {
                    Text("Worker: \(name(worker))\nReviewer: \(name(reviewer))").foregroundStyle(MM.Colors.textSecondary)
                    Button(copied ? "Copied" : "Copy handoff for Grok Bot") {
                        copyBriefText("Use My Man on my selected Mac. Brief ID: \(brief.id). Worker: \(name(worker)) (\(worker)); reviewer: \(name(reviewer)) (\(reviewer)). Read it with `myman brief read --id \(brief.id) --include-context --json`. Have the assigned worker complete the outcome and submit visual results, then have the independent reviewer check every acceptance criterion. Use each agent's configured identity. My Man stores the assignment; dispatch the work through this host. Return the results here. Inspect the current stage and revision before acting.")
                        copied = true
                    }.clickable()
                }
                if !brief.outputs.isEmpty {
                    Text("Submitted evidence").font(MM.Fonts.body)
                    Text(brief.summary).textSelection(.enabled)
                    ForEach(brief.outputs, id: \.id) { ref in
                        if let item = CaptureIndex.item(ref.id) { Button(item.title) { CaptureActions.open(item) }.clickable() }
                    }
                }
                if brief.stage == "reviewed" { Button("Prepare share page…") { sharing = true }.clickable() }
                HStack {
                    Button("Refresh and restart review") { perform { _ = try AgentBriefs.shared.refresh(brief.id, expected: brief.revision, human: true) } }.clickable()
                    Button("Delete brief…") {
                        let alert = NSAlert(); alert.messageText = "Delete this brief?"; alert.informativeText = "Recordings and result files remain in your library."; alert.addButton(withTitle: "Delete brief"); alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { perform { try AgentBriefs.shared.delete(brief.id, expected: brief.revision, human: true) } }
                    }.clickable()
                }
                if !error.isEmpty { Text(error).foregroundStyle(MM.Colors.textSecondary).textSelection(.enabled) }
            }.padding(MM.Layout.paddingLarge)
        }.onAppear { worker = brief.worker ?? ""; reviewer = brief.reviewer ?? "" }
            .sheet(isPresented: $sharing) { AgentBriefShareForm(brief: brief) }
    }
    @ViewBuilder private var agentOptions: some View {
        Text("Choose an agent").tag("")
        ForEach(identities.agents.filter { !$0.revoked && $0.scopes.contains("library") }) { Text($0.name).tag($0.id) }
    }
    private func name(_ id: String) -> String { identities.agents.first { $0.id == id }?.name ?? "Unavailable agent" }
    private func perform(_ action: () throws -> Void) { do { try action(); error = "" } catch { self.error = (error as? AgentError)?.message ?? error.localizedDescription } }
}

private struct AgentBriefShareForm: View {
    let brief: AgentBriefs.Brief
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var summary = ""
    @State private var botURL = ""
    @State private var publishing = false
    @State private var selection = Set<String>()
    @State private var error = ""
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: MM.Layout.padding) {
            Text("Choose what to share").font(MM.Fonts.title)
            Text("Write public copy and select the finished visuals. The original brief and transcript are left out. Review video audio as well as its image before sharing.").foregroundStyle(MM.Colors.textSecondary)
            TextField("Public title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $summary).frame(height: 100).accessibilityLabel("Public summary")
            ForEach(brief.outputs, id: \.id) { ref in
                if let item = CaptureIndex.item(ref.id), ["screenshot", "recording"].contains(item.kind) {
                    HStack {
                        Toggle(item.title, isOn: Binding(get: { selection.contains(ref.id) }, set: { if $0 { selection.insert(ref.id) } else { selection.remove(ref.id) } })).clickable()
                        Button("Inspect") { CaptureActions.open(item) }.clickable()
                    }
                }
            }
            TextField("Public Grok Bot share link (optional)", text: $botURL).textFieldStyle(.roundedBorder)
            Text("Save a local HTML page, or publish selected results for 24 hours. Published pages are limited to 3 MB. Anyone with the link can view them until expiry or revocation.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            if !error.isEmpty { Text(error).foregroundStyle(MM.Colors.textSecondary) }
            HStack {
                Button("Cancel") { dismiss() }.clickable()
                Spacer()
                Button("Publish for 24 hours") { publish() }.clickable().disabled(publishing || title.isEmpty || selection.isEmpty || selection.count > 4)
                Button("Save share page…") { save() }.clickable().disabled(publishing || title.isEmpty || selection.isEmpty || selection.count > 4)
            }
        }.font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textPrimary).padding(MM.Layout.paddingLarge)
        }.frame(width: 640, height: 600).background(MM.Colors.background)
    }
    private func publish() {
        guard !publishing else { return }
        guard !SharePublishing.shared.endpoint.isEmpty else { WorkflowCenter.shared.open(tab: "sharing"); return }
        publishing = true
        Task {
            defer { publishing = false }
            do {
                let result = try AgentBriefs.shared.exportForHuman(brief.id, expected: brief.revision, args: ["public_title": title, "public_summary": summary, "output_ids": brief.outputs.map(\.id).filter { selection.contains($0) }, "bot_url": botURL])
                guard let attachment = result["attachment"] as? [String: Any], let path = attachment["path"] as? String else { return }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let receipt = try await SharePublishing.shared.publish(data: data, mime: "text/html", sourceID: brief.sources.first?.id ?? brief.id, title: title, seconds: 86400, sourceIDs: brief.sources.map(\.id) + Array(selection))
                copyBriefText(receipt.url); Toast.show("Share link copied. Manage it in Workflows → Sharing."); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do {
            let result = try AgentBriefs.shared.exportForHuman(brief.id, expected: brief.revision, args: ["public_title": title, "public_summary": summary, "output_ids": brief.outputs.map(\.id).filter { selection.contains($0) }, "bot_url": botURL])
            guard let attachment = result["attachment"] as? [String: Any], let path = attachment["path"] as? String else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "my-man-result.html"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do { try Data(contentsOf: URL(fileURLWithPath: path)).write(to: url, options: .atomic); NSWorkspace.shared.open(url); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = (error as? AgentError)?.message ?? error.localizedDescription }
    }
}

@MainActor private func copyBriefText(_ text: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
}
