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

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename **Them** or **Speaker 1** to teach My Man who they are.")
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

enum MeetingSummarizer {
    /// Granola-style smart notes in markdown, generated on-device.
    static func summarize(_ transcript: String) async -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "" }
        guard case .available = SystemLanguageModel.default.availability else { return "" }
        let session = LanguageModelSession(instructions: """
            You write concise meeting notes in markdown from a transcript with \
            "You:" (the user) and "Others:" (other participants) sections. \
            Structure: "## Summary" (2-3 sentences), "## Key points" (bullets), \
            and "## Action items" (bullets, only real commitments) — omit any \
            section with nothing to say. Plain, specific language. No preamble.
            """)
        do {
            let response = try await session.respond(to: String(transcript.prefix(8000)))
            Analytics.track("meeting_summarized")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("My Man [Summary] failed: \(error)")
            return ""
        }
        #else
        return ""
        #endif
    }
}
