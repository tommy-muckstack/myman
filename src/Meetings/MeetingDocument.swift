import AppKit
import GRDB
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// The Granola page: one clean document per meeting — smart summary (editable
// markdown) with the raw transcript one toggle away. Paper-simple: a title,
// a divider, text.

@MainActor
final class MeetingDocumentController {
    static let shared = MeetingDocumentController()
    private var windows: [String: NSWindow] = [:]

    func open(meetingID: String) {
        if let existing = windows[meetingID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let meeting = try? Database.shared.read({ db in
            try Meeting.fetchOne(db, key: meetingID)
        }) else { return }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 640))
        window.center()
        window.contentView = NSHostingView(rootView: MeetingDocumentView(meeting: meeting))
        windows[meetingID] = window
        Analytics.track("meeting_document_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct MeetingDocumentView: View {
    let meeting: Meeting
    @State private var title: String
    @State private var summary: String
    @State private var transcript: String
    @State private var slidePaths: [String]
    @State private var showTranscript = false
    @State private var isSummarizing = false
    @State private var saveTask: Task<Void, Never>?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var saveState: SaveState = .idle
    @State private var linkCopied = false
    @Namespace private var tabNamespace
    @State private var headerHovering = false

    init(meeting: Meeting) {
        self.meeting = meeting
        _title = State(initialValue: meeting.title)
        _summary = State(initialValue: meeting.summary)
        _transcript = State(initialValue: meeting.transcript)
        _slidePaths = State(initialValue: meeting.slidePaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !slidePaths.isEmpty {
                slideCarousel
            }
            Divider().overlay(MM.Colors.border)
            if showTranscript {
                transcriptEditor
            } else if summary.isEmpty {
                summaryEmptyState
            } else {
                RichMarkdownEditor(markdown: $summary, firstLineIsTitle: false)
                    .onChange(of: summary) { _, newValue in
                        debouncedSave(newValue)
                    }
            }
        }
        .background(MM.Colors.background)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: generateSummaryIfMissing)
    }

    /// One centralized rename spot: every speaker in the transcript, as an
    /// editable chip. Renaming rewrites every transcript line, the summary,
    /// the person registry, and the brain file in one go.
    private var speakerLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Speakers")
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textTertiary)
                ForEach(speakerLabels, id: \.self) { label in
                    SpeakerChip(label: label) { old, new in
                        renameSpeaker(from: old, to: new)
                    }
                    .id(label)
                }
            }
        }
        .padding(.top, 4)
    }

    /// Distinct speaker labels in first-appearance order, from the
    /// interleaved `**Name** [m:ss]:` transcript form.
    private var speakerLabels: [String] {
        let pattern = #"\*\*([^*\n]{1,80})\*\*\s*\[\d+:\d{2}\]:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: transcript,
                                   range: NSRange(transcript.startIndex..., in: transcript)) {
            guard let range = Range(match.range(at: 1), in: transcript) else { continue }
            let label = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(label).inserted { ordered.append(label) }
        }
        return ordered
    }

    private func renameSpeaker(from old: String, to newRaw: String) {
        let new = newRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old, !new.contains("*") else { return }
        transcript = transcript.replacingOccurrences(of: "**\(old)**", with: "**\(new)**")
        // The summary was written against the old label — keep it in step.
        if !summary.isEmpty, summary.contains(old) {
            summary = summary.replacingOccurrences(of: old, with: new)
        }
        People.renameSpeaker(from: old, to: new)
        saveEverything()
        Analytics.track("meeting_speaker_renamed", ["was_email": old.contains("@")])
    }

    /// One explicit write for renames: the summary editor's onChange only
    /// exists while the Summary tab is showing, so a rename made from the
    /// Transcript tab must not rely on the debounced per-field saves.
    private func saveEverything() {
        saveTask?.cancel()
        saveState = .pending
        let id = meeting.id
        let transcript = transcript
        let summary = summary
        saveTask = Task { @MainActor in
            try? await Database.shared.write { db in
                try db.execute(sql: "UPDATE meeting SET transcript = ?, summary = ? WHERE id = ?",
                               arguments: [transcript, summary, id])
            }
            People.learnSpeakerNames(from: transcript)
            Brain.syncMeeting(id: id, title: title,
                              startedAt: meeting.startedAt, endedAt: meeting.endedAt,
                              summary: summary, transcript: transcript)
            saveState = .saved
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = .idle }
            }
        }
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename speakers above — every line updates everywhere.")
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textTertiary)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            TextEditor(text: $transcript)
                .font(MM.Fonts.body)
                .foregroundStyle(MM.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .onChange(of: transcript) { _, newValue in
                    debouncedSaveTranscript(newValue)
                }
        }
    }

    /// What was on screen during the call — deduped captures of the meeting
    /// window, in order. Click one to open it full size.
    private var slideCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(slidePaths, id: \.self) { path in
                    if let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MM.Colors.border, lineWidth: 1))
                            .clickable(minSize: 44)
                            .onTapGesture {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    removeSlide(path)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(MM.Colors.textPrimary)
                                        .background(Circle().fill(MM.Colors.background))
                                        .clickable(minSize: 24)
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .help("Remove screenshot from this meeting")
                            }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled meeting", text: $title)
                .font(MM.Fonts.outfit(24, .semiBold))
                .foregroundStyle(MM.Colors.textPrimary)
                .textFieldStyle(.plain)
                .onChange(of: title) { _, newValue in
                    debouncedSaveTitle(newValue)
                }
            HStack(spacing: MM.Layout.spacing) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                if let ended = meeting.endedAt {
                    Text("\(Int(ended.timeIntervalSince(meeting.startedAt) / 60)) min")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textTertiary)
                }
                copyLinkButton
                    .opacity(headerHovering ? 1 : 0)
                    .animation(MM.Motion.gentle, value: headerHovering)
                Spacer()
                SaveIndicator(state: saveState)
                HStack(spacing: 3) {
                    tab("Summary", active: !showTranscript) {
                        withAnimation(MM.Motion.silky) { showTranscript = false }
                    }
                    tab("Transcript", active: showTranscript) {
                        withAnimation(MM.Motion.silky) { showTranscript = true }
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MM.Colors.surface)
                )
            }
            if !speakerLabels.isEmpty {
                speakerLegend
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onHover { headerHovering = $0 }
    }

    private var copyLinkButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                Brain.meetingFilePath(id: meeting.id, startedAt: meeting.startedAt),
                forType: .string)
            linkCopied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                linkCopied = false
            }
        } label: {
            HStack(spacing: 4) {
                IconView(icon: .copy, size: 12,
                         color: linkCopied ? .green : MM.Colors.textTertiary)
                Text(linkCopied ? "Copied" : "Copy link")
            }
            .font(MM.Fonts.metadata)
            .foregroundStyle(linkCopied ? .green : MM.Colors.textTertiary)
            .clickable(minSize: 22)
        }
        .buttonStyle(.plain)
        .help("Copy this meeting's file path — paste it to Claude or any agent")
    }

    private func tab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MM.Fonts.secondary)
                .foregroundStyle(active ? MM.Colors.background : MM.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    // One shared pill that SLIDES between tabs.
                    if active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(MM.Colors.textPrimary)
                            .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                    }
                }
                .clickable(minSize: 24)
        }
        .buttonStyle(.plain)
    }

    private var summaryEmptyState: some View {
        VStack(spacing: 8) {
            if isSummarizing {
                ProgressView().controlSize(.small)
                Text("Writing your summary…")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
            } else {
                Text("No summary yet.")
                    .font(MM.Fonts.body)
                    .foregroundStyle(MM.Colors.textSecondary)
                Text("Summaries are written on-device right after a meeting ends (macOS 26+). The transcript is always available.")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func debouncedSave(_ text: String) {
        saveTask?.cancel()
        saveState = .pending
        let id = meeting.id
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            defer {
                saveState = .saved
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if saveState == .saved { saveState = .idle }
                }
            }
            try? await Database.shared.write { db in
                try db.execute(sql: "UPDATE meeting SET summary = ? WHERE id = ?",
                               arguments: [text, id])
            }
            Brain.syncMeeting(id: id, title: title,
                              startedAt: meeting.startedAt, endedAt: meeting.endedAt,
                              summary: text, transcript: meeting.transcript)
        }
    }

    private func debouncedSaveTitle(_ text: String) {
        titleSaveTask?.cancel()
        saveState = .pending
        let id = meeting.id
        titleSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            try? await Database.shared.write { db in
                try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?",
                               arguments: [text, id])
            }
            Brain.syncMeeting(id: id, title: text,
                              startedAt: meeting.startedAt, endedAt: meeting.endedAt,
                              summary: summary, transcript: meeting.transcript)
            saveState = .saved
        }
    }

    private func debouncedSaveTranscript(_ text: String) {
        saveTask?.cancel()
        saveState = .pending
        let id = meeting.id
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            try? await Database.shared.write { db in
                try db.execute(sql: "UPDATE meeting SET transcript = ? WHERE id = ?",
                               arguments: [text, id])
            }
            // This only extracts explicit transcript speaker labels. It never
            // mines arbitrary spoken text for names.
            People.learnSpeakerNames(from: text)
            Brain.syncMeeting(id: id, title: title,
                              startedAt: meeting.startedAt, endedAt: meeting.endedAt,
                              summary: summary, transcript: text)
            saveState = .saved
        }
    }

    private func removeSlide(_ path: String) {
        guard let index = slidePaths.firstIndex(of: path) else { return }
        slidePaths.remove(at: index)
        let encoded = (try? JSONEncoder().encode(slidePaths))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        try? FileManager.default.trashItem(
            at: URL(fileURLWithPath: path), resultingItemURL: nil)
        try? Database.shared.write { db in
            try db.execute(sql: "UPDATE meeting SET slides = ? WHERE id = ?",
                           arguments: [encoded, meeting.id])
        }
        Analytics.track("meeting_slide_removed")
    }

    private func generateSummaryIfMissing() {
        guard summary.isEmpty, !meeting.transcript.isEmpty, !isSummarizing else { return }
        isSummarizing = true
        let transcript = meeting.transcript
        let id = meeting.id
        Task { @MainActor in
            let generated = await MeetingSummarizer.summarize(transcript)
            isSummarizing = false
            guard !generated.isEmpty else { return }
            summary = generated
            try? await Database.shared.write { db in
                try db.execute(sql: "UPDATE meeting SET summary = ? WHERE id = ?",
                               arguments: [generated, id])
            }
            Brain.syncMeeting(id: id, title: title,
                              startedAt: meeting.startedAt, endedAt: meeting.endedAt,
                              summary: generated, transcript: meeting.transcript)
        }
    }
}

/// An editable speaker name. Click to edit in place; ⏎ or clicking away
/// commits, Esc cancels. `.id(label)` upstream resets state after a rename.
private struct SpeakerChip: View {
    let label: String
    let onRename: (String, String) -> Void
    @State private var text = ""
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .frame(width: max(64, CGFloat(text.count) * 7.5 + 20))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
                    .onExitCommand {
                        editing = false
                    }
            } else {
                HStack(spacing: 4) {
                    Text(label)
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                    IconView(icon: .write, size: 10,
                             color: hovering ? MM.Colors.textSecondary : MM.Colors.textTertiary)
                }
                .clickable(minSize: 24)
                .onTapGesture {
                    text = label
                    editing = true
                    focused = true
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(MM.Colors.surface)
                .overlay(Capsule().strokeBorder(
                    editing ? MM.Colors.accent : MM.Colors.border, lineWidth: 1))
        )
        .onHover { hovering = $0 }
        .help("Rename this speaker — updates every line, the summary, and your people list")
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onRename(label, text)
    }
}

enum MeetingSummarizer {
    /// Granola-style smart notes in markdown, generated on-device.
    ///
    /// Long meetings are summarized map-reduce style: the transcript is
    /// windowed on turn boundaries, each window compressed to dense notes,
    /// then a final pass writes the document. The old single-pass version
    /// read only the first 8,000 characters — a 44-minute meeting's summary
    /// knew nothing past minute ten, which is where the decisions live.
    static func summarize(_ transcript: String) async -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "" }
        guard case .available = SystemLanguageModel.default.availability else { return "" }
        let windowSize = 7000
        let finalInstructions = """
            You write concise meeting notes in markdown from a transcript \
            where lines look like "**Name** [minute:second]: what they said" \
            ("You" is the user). Structure: "## Summary" (2-3 sentences), \
            "## Key points" (bullets), and "## Action items" (bullets, only \
            real commitments, with the owner's name) — omit any section with \
            nothing to say. Keep concrete decisions, numbers, and names; \
            plain, specific language. No preamble.
            """
        do {
            if transcript.count <= windowSize {
                let session = LanguageModelSession(instructions: finalInstructions)
                let response = try await session.respond(to: transcript)
                Analytics.track("meeting_summarized", ["windows": 1])
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var notes: [String] = []
            for window in windows(of: transcript, size: windowSize).prefix(12) {
                // Fresh session per window — context does not accumulate.
                let session = LanguageModelSession(instructions: """
                    Compress this slice of a meeting transcript (lines are \
                    "**Name** [minute:second]: what they said"; "You" is the \
                    user) into dense bullet notes. Keep every decision, \
                    commitment, number, and name exactly; drop filler. \
                    Bullets only, no headings, no preamble.
                    """)
                if let response = try? await session.respond(to: window) {
                    notes.append(response.content)
                }
            }
            guard !notes.isEmpty else { return "" }
            let session = LanguageModelSession(instructions: finalInstructions + """
                 The input is sequential bullet notes covering the whole \
                meeting, not raw transcript lines.
                """)
            let response = try await session.respond(
                to: String(notes.joined(separator: "\n").prefix(windowSize)))
            Analytics.track("meeting_summarized", ["windows": notes.count])
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("My Man [Summary] failed: \(error)")
            return ""
        }
        #else
        return ""
        #endif
    }

    /// Split on turn boundaries (blank lines) so no utterance is cut mid-way.
    private static func windows(of transcript: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for block in transcript.components(separatedBy: "\n\n") {
            if current.count + block.count + 2 > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? block : "\n\n" + block
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
