import AppKit
import SwiftUI

struct MeetingLiveTranscriptView: View {
    @ObservedObject var transcript: LiveMeetingTranscript
    var saveFailed = false
    var retry: () -> Void
    var meetingID: String? = nil
    @ObservedObject private var notes = MeetingNotesService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            HStack {
                Text("Live transcript")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                if transcript.status == .preparing {
                    ProgressView().controlSize(.mini)
                }
                Text(statusLabel)
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textSecondary)
            }
            if saveFailed {
                Text("Edits haven’t saved yet. Stop will retry.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.danger)
            }
            Group {
                if transcript.rows.isEmpty {
                    VStack(spacing: MM.Layout.spacing / 2) {
                        Text(emptyMessage)
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        if transcript.status == .unavailable {
                            retryButton
                        }
                    }
                    .padding(MM.Layout.padding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LiveTranscriptScrollView(rows: transcript.rows, edit: { transcript.editingRowID = $0 })
                }
            }
            .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall)
                .strokeBorder(MM.Colors.border, lineWidth: 1))
            if transcript.status == .unavailable, !transcript.rows.isEmpty {
                HStack {
                    Text("Recording continues.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    Spacer()
                    retryButton
                }
            }
            if let message = transcript.voiceLearningMessage {
                Text(message).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            if let meetingID, let draft = notes.drafts[meetingID], !draft.isEmpty {
                DisclosureGroup("Summary so far · draft") {
                    ScrollView { Text(draft).font(MM.Fonts.secondary).textSelection(.enabled) }
                        .frame(maxHeight: 120)
                }.font(MM.Fonts.metadata)
            }
        }
        .sheet(isPresented: Binding(get: { transcript.editingRowID != nil },
                                    set: { if !$0 { transcript.editingRowID = nil } })) {
            if let row = transcript.rows.first(where: { $0.id == transcript.editingRowID }) {
                LiveTranscriptEditView(transcript: transcript, row: row)
            }
        }
    }

    private var retryButton: some View {
        Button("Retry live transcript", action: retry)
            .font(MM.Fonts.secondary)
            .foregroundStyle(MM.Colors.accent)
            .buttonStyle(.plain)
            .clickable()
    }

    private var statusLabel: String {
        switch transcript.status {
        case .waiting: "Listening"
        case .preparing: "Preparing…"
        case .live: "Updating live"
        case .unavailable: "Paused"
        }
    }

    private var emptyMessage: String {
        switch transcript.status {
        case .preparing: "Preparing on-device transcription…\nYour meeting is recording."
        case .unavailable: "Live transcription is unavailable.\nYour meeting is still recording."
        case .waiting, .live: "Speech will appear here with speaker names."
        }
    }
}

/// Native scrolling keeps selection and reading position stable as text
/// arrives. Follow new speech only when the reader was already at the bottom.
struct LiveTranscriptScrollView: NSViewRepresentable {
    let rows: [LiveMeetingTranscript.Row]
    var edit: (String) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var rows: [LiveMeetingTranscript.Row] = []
        var edit: (String) -> Void = { _ in }
        /// Pinned to the newest words until the reader scrolls up on
        /// purpose; scrolling back to the end re-pins.
        var followsLatest = true
        private var observer: NSObjectProtocol?

        func watchUserScrolling(_ scroll: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main
            ) { [weak self, weak scroll] _ in
                guard let self, let scroll, let text = scroll.documentView else { return }
                self.followsLatest = LiveTranscriptScrollView.isAtBottom(scroll, of: text)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host == "live-edit",
                  let id = components.queryItems?.first(where: { $0.name == "row" })?.value else { return false }
            edit(id)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = NSTextView(frame: .zero)
        context.coordinator.edit = edit
        text.delegate = context.coordinator
        text.linkTextAttributes = [.foregroundColor: NSColor(MM.Colors.accent), .underlineStyle: 0]
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: MM.Layout.spacing / 2, height: MM.Layout.spacing)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Live meeting transcript with speakers and timestamps")
        scroll.documentView = text
        context.coordinator.watchUserScrolling(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.edit = edit
        guard context.coordinator.rows != rows, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.rows = rows
        Self.update(text, in: scroll, rows: rows, follow: context.coordinator.followsLatest)
    }

    static func isAtBottom(_ scroll: NSScrollView, of text: NSView) -> Bool {
        scroll.contentView.bounds.maxY >= text.bounds.height - MM.Layout.padding
    }

    /// `follow` nil keeps the older rule (follow only when already at the
    /// end); the live view passes its explicit pin state instead.
    static func update(_ text: NSTextView, in scroll: NSScrollView, rows: [LiveMeetingTranscript.Row], follow: Bool? = nil) {
        let wasAtBottom = follow ?? isAtBottom(scroll, of: text)
        let position = scroll.contentView.bounds.origin
        let selection = text.selectedRange()
        let content = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { content.append(NSAttributedString(string: "\n\n")) }
            content.append(NSAttributedString(string: row.speaker, attributes: [
                .font: MM.Fonts.native(13, .semiBold), .foregroundColor: NSColor(MM.Colors.textPrimary)
            ]))
            content.append(NSAttributedString(string: "  \(row.timestamp)", attributes: [
                .font: MM.Fonts.native(11.5), .foregroundColor: NSColor(MM.Colors.textSecondary)
            ]))
            var link = URLComponents()
            link.scheme = "myman"
            link.host = "live-edit"
            link.queryItems = [URLQueryItem(name: "row", value: row.id)]
            if let url = link.url {
                content.append(NSAttributedString(string: "  Edit", attributes: [
                    .font: MM.Fonts.native(11.5), .link: url
                ]))
            }
            if let suggested = row.suggestedName {
                content.append(NSAttributedString(string: "\nPossibly \(suggested)", attributes: [
                    .font: MM.Fonts.native(11.5), .foregroundColor: NSColor(MM.Colors.textSecondary)
                ]))
            }
            content.append(NSAttributedString(string: "\n"))
            content.append(NSAttributedString(string: row.text, attributes: [
                .font: MM.Fonts.native(13), .foregroundColor: NSColor(MM.Colors.textPrimary)
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MM.Layout.spacing / 4
        content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
        text.textStorage?.setAttributedString(content)
        text.setSelectedRange(NSRange(location: min(selection.location, content.length),
                                      length: min(selection.length, max(0, content.length - selection.location))))
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        if wasAtBottom {
            // Scroll directly without changing the user's text selection.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, text.bounds.height - scroll.contentSize.height)))
        } else {
            scroll.contentView.scroll(to: position)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

struct LiveTranscriptEditView: View {
    @ObservedObject var transcript: LiveMeetingTranscript
    let row: LiveMeetingTranscript.Row
    @State private var name: String
    @State private var text: String
    @State private var remember = false
    @State private var forgetMessage: String?

    init(transcript: LiveMeetingTranscript, row: LiveMeetingTranscript.Row) {
        self.transcript = transcript
        self.row = row
        _name = State(initialValue: row.speaker)
        _text = State(initialValue: row.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Edit transcript · \(row.timestamp)").font(MM.Fonts.title)
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(MM.Fonts.secondary)
                .accessibilityLabel("Speaker name")
            if let suggested = row.suggestedName {
                Button("Use suggested name: \(suggested)") { name = suggested }
                    .font(MM.Fonts.metadata).buttonStyle(.plain).foregroundStyle(MM.Colors.accent).clickable()
            }
            if !row.callParticipants.isEmpty {
                VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                    Text("On the call").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    FlowingPills(names: row.callParticipants, selected: name) { name = $0 }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Names seen on the call window")
            }
            TextEditor(text: $text)
                .font(MM.Fonts.body)
                .scrollContentBackground(.hidden)
                .padding(MM.Layout.spacing / 2)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .frame(height: 150)
                .accessibilityLabel("Transcript text")
            if transcript.canRememberVoice(rowID: row.id) {
                Toggle("Remember this voice on this Mac", isOn: $remember)
                    .font(MM.Fonts.secondary)
                    .disabled(MeetingSource.genericSpeaker(name))
                Button("Forget remembered voice for this name") {
                    do { try VoiceProfiles.forget(name: name); forgetMessage = "Remembered voice removed." }
                    catch { forgetMessage = "Couldn’t forget this voice. Please try again." }
                }
                .font(MM.Fonts.metadata).buttonStyle(.plain).foregroundStyle(MM.Colors.textSecondary).clickable()
            }
            if let forgetMessage { Text(forgetMessage).font(MM.Fonts.metadata) }
            HStack {
                Button("Cancel") { transcript.editingRowID = nil }
                    .keyboardShortcut(.cancelAction).clickable()
                Spacer()
                Button("Save changes") {
                    transcript.edit(rowID: row.id, text: text, speakerName: name)
                    if remember { transcript.rememberVoice(rowID: row.id, name: name) }
                }
                .keyboardShortcut(.defaultAction).clickable()
            }
        }
        .foregroundStyle(MM.Colors.textPrimary)
        .padding(MM.Layout.paddingLarge)
        .frame(width: 380)
        .background(MM.Colors.background)
    }
}

/// Names as tappable pills, wrapping onto new lines as needed.
struct FlowingPills: View {
    let names: [String]
    var selected: String = ""
    var choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MM.Layout.spacing / 2) {
                ForEach(names, id: \.self) { name in
                    let isSelected = LiveMeetingTranscript.sameName(name, selected)
                    Button { choose(name) } label: {
                        Text(name)
                            .font(MM.Fonts.metadata)
                            .foregroundStyle(isSelected ? MM.Colors.background : MM.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isSelected ? MM.Colors.accent : MM.Colors.surface))
                            .overlay(Capsule().strokeBorder(isSelected ? MM.Colors.accent : MM.Colors.border, lineWidth: 1))
                            .clickable()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use name \(name)")
                }
            }
        }
    }
}
