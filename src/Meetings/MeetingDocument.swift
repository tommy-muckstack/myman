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
    func close(id: String) {
        MeetingNotesService.shared.cancel(meetingID: id)
        let window = windows.removeValue(forKey: id)
        (window as? DocumentWindow)?.autosave?.discardPendingChanges()
        window?.contentView = nil; window?.close()
    }

    func open(meetingID: String) {
        if let existing = windows[meetingID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let meeting = try? Database.shared.read({ db in
            try Meeting.fetchOne(db, key: meetingID)
        }) else { return }

        let window = DocumentWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setContentSize(MM.Document.windowSize)
        window.minSize = NSSize(width: 560, height: 420)
        let autosave = DocumentAutosave()
        window.autosave = autosave
        window.center()
        window.contentView = NSHostingView(rootView: MeetingDocumentView(meeting: meeting, autosave: autosave))
        windows[meetingID] = window
        Analytics.track("meeting_document_opened")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Slide thumbnails without the dead space: captured call windows routinely
/// carry big uniform margins (letterboxed screen shares, empty chrome), and a
/// center-crop of THAT shows mostly margin. Trim the uniform border first so
/// the thumbnail is all content.
enum SlideThumbnailer {
    private static let cache = NSCache<NSString, NSImage>()
    static func clear() { cache.removeAllObjects() }

    static func thumbnail(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var result = image
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let rect = contentCropRect(of: cg),
           let cropped = cg.cropping(to: rect) {
            result = NSImage(cgImage: cropped,
                             size: NSSize(width: cropped.width, height: cropped.height))
        }
        cache.setObject(result, forKey: path as NSString)
        return result
    }

    /// The bounding box of actual content, or nil when there's nothing worth
    /// trimming. Works on a ≤128px grayscale copy: the border shade is the
    /// modal value of the outermost pixel ring, and a row/column is "empty"
    /// when under 2% of its pixels depart from that shade.
    static func contentCropRect(of image: CGImage) -> CGRect? {
        let maxSide: CGFloat = 128
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(8, Int(CGFloat(image.width) * scale))
        let h = max(8, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var histogram = [Int](repeating: 0, count: 256)
        for x in 0 ..< w {
            histogram[Int(pixels[x])] += 1
            histogram[Int(pixels[(h - 1) * w + x])] += 1
        }
        for y in 0 ..< h {
            histogram[Int(pixels[y * w])] += 1
            histogram[Int(pixels[y * w + w - 1])] += 1
        }
        guard let border = histogram.indices.max(by: { histogram[$0] < histogram[$1] })
        else { return nil }

        func rowIsEmpty(_ y: Int) -> Bool {
            var busy = 0
            for x in 0 ..< w where abs(Int(pixels[y * w + x]) - border) > 12 { busy += 1 }
            return busy * 50 < w
        }
        func colIsEmpty(_ x: Int) -> Bool {
            var busy = 0
            for y in 0 ..< h where abs(Int(pixels[y * w + x]) - border) > 12 { busy += 1 }
            return busy * 50 < h
        }
        var top = 0
        while top < h - 1, rowIsEmpty(top) { top += 1 }
        var bottom = h - 1
        while bottom > top, rowIsEmpty(bottom) { bottom -= 1 }
        var left = 0
        while left < w - 1, colIsEmpty(left) { left += 1 }
        var right = w - 1
        while right > left, colIsEmpty(right) { right -= 1 }

        let cw = right - left + 1
        let ch = bottom - top + 1
        // A near-blank frame is not "all margin" — trimming it to a sliver
        // would show garbage. And a trim under ~2% isn't worth a re-crop.
        guard cw >= w / 4, ch >= h / 4 else { return nil }
        guard (w - cw) + (h - ch) >= max(2, (w + h) / 50) else { return nil }

        let sx = CGFloat(image.width) / CGFloat(w)
        let sy = CGFloat(image.height) / CGFloat(h)
        // One coarse pixel of slack each side so round-off never shaves
        // real content.
        let x = max(0, (CGFloat(left) - 1) * sx)
        let y = max(0, (CGFloat(top) - 1) * sy)
        return CGRect(
            x: x, y: y,
            width: min(CGFloat(image.width) - x, (CGFloat(cw) + 2) * sx),
            height: min(CGFloat(image.height) - y, (CGFloat(ch) + 2) * sy)
        )
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
    @StateObject private var autosave: DocumentAutosave
    @StateObject private var editor = RichEditorSession()
    @StateObject private var notesService: MeetingNotesService
    @State private var hasEditedNotes = false
    @State private var showRelated = false
    @State private var showSlides = false
    private let database: DatabaseQueue?
    private let automaticallySummarize: Bool
    private var db: DatabaseQueue { database ?? Database.shared }
    @Namespace private var tabNamespace
    /// Transcript tab defaults to the formatted reading view; this flips to
    /// the raw text editor for corrections.
    @State private var editingTranscript = false

    init(meeting: Meeting, autosave: DocumentAutosave? = nil, database: DatabaseQueue? = nil, automaticallySummarize: Bool = true) {
        self.meeting = meeting
        self.database = database
        self.automaticallySummarize = automaticallySummarize
        _autosave = StateObject(wrappedValue: autosave ?? DocumentAutosave())
        _notesService = StateObject(wrappedValue: database == nil ? .shared : MeetingNotesService(database: database))
        _title = State(initialValue: meeting.title)
        _summary = State(initialValue: meeting.summary)
        _transcript = State(initialValue: meeting.transcript)
        _slidePaths = State(initialValue: meeting.slidePaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showSlides, !slidePaths.isEmpty { slideCarousel }
            if showTranscript {
                transcriptEditor
                HStack { Spacer(); SaveIndicator(state: autosave.state) }
                    .padding(.horizontal, MM.Document.margin).padding(.vertical, MM.Layout.spacing)
            } else {
                if isSummarizing {
                    HStack(spacing: MM.Layout.spacing) {
                        ProgressView().controlSize(.mini)
                        Text(notesService.stages[meeting.id] ?? "Preparing notes…")
                            .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                    }.padding(.horizontal, MM.Document.margin)
                }
                RichMarkdownEditor(markdown: Binding(get: { summary }, set: { text in
                    notesService.cancel(meetingID: meeting.id)
                    summary = text; hasEditedNotes = true; debouncedSave(text)
                }), firstLineIsTitle: false, session: editor,
                                   placeholder: "Write your notes…", documentID: "meeting-" + meeting.id)
                DocumentFooter(session: editor, text: summary, autosave: autosave)
            }
            if showRelated { CaptureRelatedSection(itemID: "meeting-" + meeting.id).padding(MM.Layout.padding) }
        }
        .background(MM.Colors.background)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { if automaticallySummarize { generateSummaryIfMissing() } }
        .task {
            let id = meeting.id
            let observation = ValueObservation.tracking { db in try Meeting.fetchOne(db, key: id) }
            do {
                for try await saved in observation.values(in: db) {
                    guard let saved else { return }
                    // A document can already be open when transcription finishes.
                    if transcript.isEmpty { transcript = saved.transcript }
                    if !hasEditedNotes, summary.isEmpty { summary = saved.summary }
                    if automaticallySummarize { generateSummaryIfMissing() }
                }
            } catch { /* Keep the editable document available if observation fails. */ }
        }
        .onChange(of: showTranscript) { _, _ in autosave.flush() }
        .onDisappear { autosave.flush() }
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
        notesService.cancel(meetingID: meeting.id)
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
        debouncedSaveTranscript(transcript)
        debouncedSave(summary)
        autosave.flush()
    }

    private var transcriptEditor: some View {
        let turns = Self.parseTurns(transcript)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editingTranscript || turns == nil
                     ? "Rename speakers above — every line updates everywhere."
                     : "Reading view — Edit to correct the text.")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                if turns != nil {
                    Button(editingTranscript ? "Done" : "Edit") {
                        withAnimation(MM.Motion.gentle) { editingTranscript.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .help(editingTranscript
                          ? "Back to the formatted view"
                          : "Edit the raw transcript text")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            if let turns, !editingTranscript {
                formattedTranscript(turns)
            } else {
                TextEditor(text: Binding(get: { transcript }, set: { text in
                    notesService.cancel(meetingID: meeting.id)
                    transcript = text; debouncedSaveTranscript(text)
                }))
                    .font(MM.Fonts.body)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

            }
        }
    }

    // MARK: Formatted transcript

    /// One parsed `**Name** [m:ss]: text` turn.
    struct TranscriptTurn: Equatable {
        let speaker: String
        let time: String
        let text: String
    }

    /// The interleaved transcript, parsed — nil when the text isn't in the
    /// turn format (old two-block transcripts, hand-edited text), in which
    /// case the raw editor is the honest view.
    nonisolated static func parseTurns(_ transcript: String) -> [TranscriptTurn]? {
        let pattern = #"\*\*([^*\n]{1,80})\*\*\s*\[(\d+:\d{2})\]:\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var turns: [TranscriptTurn] = []
        for (index, match) in matches.enumerated() {
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            turns.append(TranscriptTurn(
                speaker: ns.substring(with: match.range(at: 1)),
                time: ns.substring(with: match.range(at: 2)),
                text: text))
        }
        return turns
    }

    /// Muted, readable hues — one per speaker in first-appearance order.
    nonisolated static let speakerPalette: [Color] = [
        Color(red: 0.36, green: 0.56, blue: 0.94),  // blue
        Color(red: 0.87, green: 0.47, blue: 0.34),  // coral
        Color(red: 0.36, green: 0.69, blue: 0.52),  // green
        Color(red: 0.66, green: 0.48, blue: 0.90),  // purple
        Color(red: 0.88, green: 0.42, blue: 0.60),  // pink
        Color(red: 0.33, green: 0.68, blue: 0.72),  // teal
    ]

    nonisolated static func speakerColors(for turns: [TranscriptTurn]) -> [String: Color] {
        var colors: [String: Color] = [:]
        for turn in turns where colors[turn.speaker] == nil {
            colors[turn.speaker] = speakerPalette[colors.count % speakerPalette.count]
        }
        return colors
    }

    /// The clean reading view: bold colored speaker names, quiet timestamps,
    /// plain paragraphs — no markup on screen.
    private func formattedTranscript(_ turns: [TranscriptTurn]) -> some View {
        let colors = Self.speakerColors(for: turns)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(turns.indices, id: \.self) { index in
                    let turn = turns[index]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(turn.speaker)
                                .font(MM.Fonts.gellix(13, .semiBold))
                                .foregroundStyle(colors[turn.speaker] ?? MM.Colors.textPrimary)
                            Text(turn.time)
                                .font(MM.Fonts.metadata)
                                .foregroundStyle(MM.Colors.textTertiary)
                        }
                        Text(turn.text)
                            .font(MM.Fonts.body)
                            .foregroundStyle(MM.Colors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    /// What was on screen during the call — deduped captures of the meeting
    /// window, in order. Click one to open it full size.
    private var slideCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(slidePaths, id: \.self) { path in
                    if let image = SlideThumbnailer.thumbnail(atPath: path) {
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
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack(spacing: MM.Layout.spacing) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let ended = meeting.endedAt { Text("\(Int(ended.timeIntervalSince(meeting.startedAt) / 60)) min") }
                Spacer()
                if !slidePaths.isEmpty {
                    Button { showSlides.toggle() } label: { Label("\(slidePaths.count)", systemImage: "photo.on.rectangle").clickable(minSize: 28) }
                        .buttonStyle(.plain).help("Show captured slides")
                }
                Button { showRelated.toggle() } label: { IconView(icon: .related).clickable(minSize: 28) }
                    .buttonStyle(.plain).help("Related captures").accessibilityLabel("Related captures")
                Menu {
                    Button("Copy notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MarkdownRich.plainText(summary), forType: .string)
                    }
                    Button("Copy Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }
                    Button("Copy file path") {
                        autosave.flush()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Brain.meetingFilePath(id: meeting.id, startedAt: meeting.startedAt), forType: .string)
                    }
                } label: { Image(systemName: "ellipsis").clickable(minSize: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Meeting actions").accessibilityLabel("Meeting actions")
            }
            .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            TextField("Untitled meeting", text: Binding(get: { title }, set: { text in
                title = text; debouncedSaveTitle(text)
            }), axis: .vertical)
                .font(MM.Document.title)
                .foregroundStyle(MM.Colors.textPrimary)
                .textFieldStyle(.plain)
            HStack(spacing: MM.Layout.paddingLarge) {
                tab("Notes", active: !showTranscript) { showTranscript = false }
                tab("Transcript", active: showTranscript) { showTranscript = true }
                Spacer()
                if autosave.state == .failed {
                    Button("Retry save") { autosave.flush() }.buttonStyle(.plain).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.danger).clickable()
                }
            }.padding(.top, MM.Layout.spacing)
            if showTranscript, !speakerLabels.isEmpty { speakerLegend }
        }
        .padding(.horizontal, MM.Document.margin)
        .padding(.top, MM.Layout.paddingLarge)
        .padding(.bottom, MM.Layout.spacing)
        .frame(maxWidth: MM.Document.columnWidth + MM.Document.margin * 2)
        .frame(maxWidth: .infinity)
    }

    private func tab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(MM.Fonts.secondary)
                .foregroundStyle(active ? MM.Colors.textPrimary : MM.Colors.textTertiary)
                .padding(.vertical, MM.Layout.spacing)
                .overlay(alignment: .bottom) {
                    if active { Capsule().fill(MM.Colors.textPrimary).frame(height: 2).matchedGeometryEffect(id: "activeTab", in: tabNamespace) }
                }
                .clickable(minSize: 28)
        }.buttonStyle(.plain)
    }

    private func debouncedSave(_ text: String) { saveField("summary", text: text) }
    private func debouncedSaveTitle(_ text: String) { saveField("title", text: text) }
    private func debouncedSaveTranscript(_ text: String) { saveField("transcript", text: text) }

    private func saveField(_ field: String, text: String) {
        guard ["title", "summary", "transcript"].contains(field) else { return }
        autosave.submit(field) {
            try db.write { db in
                try db.execute(sql: "UPDATE meeting SET \(field) = ? WHERE id = ?", arguments: [text, meeting.id])
                guard db.changesCount > 0 else { throw CocoaError(.fileNoSuchFile) }
            }
            if database == nil {
                if field == "transcript" { People.learnSpeakerNames(from: text) }
                syncSavedMeeting()
            }
        }
    }

    private func syncSavedMeeting() {
        guard let saved = try? db.read({ try Meeting.fetchOne($0, key: meeting.id) }) else { return }
        Brain.syncMeeting(id: saved.id, title: saved.title, startedAt: saved.startedAt, endedAt: saved.endedAt,
                          summary: saved.summary, transcript: saved.transcript)
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
        guard summary.isEmpty, !transcript.isEmpty, !isSummarizing, !hasEditedNotes else { return }
        isSummarizing = true
        let sourceTranscript = transcript
        Task { @MainActor in
            let generated = await notesService.notes(meetingID: meeting.id)
            isSummarizing = false
            guard !generated.isEmpty, summary.isEmpty, !hasEditedNotes,
                  transcript == sourceTranscript else { return }
            summary = generated
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
    static func summarize(_ transcript: String, meetingDate: Date = Date(),
                          progress: @escaping MeetingNotesService.Progress = { _ in }) async -> String {
        let totalTimer = MeetingProcessingTimer()
        defer { totalTimer.finish("notes_total") }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "" }
        guard case .available = SystemLanguageModel.default.availability else { return "" }
        let finalInstructions = """
            You write concise meeting notes in markdown from a transcript \
            where lines look like "**Name** [minute:second]: what they said" \
            ("You" is the user). Structure: "## Summary" (2-3 sentences) and \
            "## Key points" (bullets). Do NOT write an action items section. \
            Cover the WHOLE meeting: the later half of a conversation carries \
            the decisions, and a summary that stops early is wrong. \
            Greetings, weekend and family chat, scheduling, and audio checks \
            are noise — they usually open a meeting, and they never belong in \
            the notes. Keep concrete decisions, numbers, and names; plain, \
            specific language. No preamble.
            """
        do {
            let body: String
            var windowCount = 1
            if transcript.count <= windowSize {
                body = transcript
            } else {
                let compressionTimer = MeetingProcessingTimer()
                let notes = await compress(transcript, progress: progress)
                compressionTimer.finish("notes_compression")
                guard !Task.isCancelled, !notes.isEmpty else { return "" }
                windowCount = notes.count
                await progress("Combining meeting details…")
                body = await reduceToFit(notes)
            }
            guard !Task.isCancelled else { return "" }
            await progress("Writing notes…")
            let writingTimer = MeetingProcessingTimer()
            let session = LanguageModelSession(
                instructions: transcript.count <= windowSize ? finalInstructions
                    : finalInstructions + """
                         The input is sequential bullet notes covering the \
                        whole meeting start to finish, not raw transcript \
                        lines. Represent the end as fully as the beginning.
                        """)
            let response = try await session.respond(to: body)
            writingTimer.finish("notes_writing")
            // The write-up pass is told not to produce action items, but a
            // model that ignores that would reintroduce exactly the invented
            // topic-restatements this replaced. Only the extractor's list ships.
            var document = stripActionItems(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !Task.isCancelled else { return "" }
            let actions = await ActionItemExtractor.extract(
                from: transcript, meetingDate: meetingDate, progress: progress)
            guard !Task.isCancelled else { return "" }
            if !actions.isEmpty { document += "\n\n## Action items\n\n" + actions }
            Analytics.track("meeting_summarized",
                            ["windows": windowCount,
                             "has_action_items": !actions.isEmpty])
            return document
        } catch {
            NSLog("My Man [Summary] failed: \(error)")
            return ""
        }
        #else
        return ""
        #endif
    }

    private static let windowSize = 7000

    /// Drop any "## Action items" heading and everything under it, up to the
    /// next heading.
    static func stripActionItems(_ markdown: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in markdown.components(separatedBy: "\n") {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("#") {
                skipping = heading.lowercased()
                    .contains("action item") || heading.lowercased().contains("next step")
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(FoundationModels)
    /// Dense bullet notes for every window of the transcript, in order.
    @available(macOS 26.0, *)
    private static func compress(_ transcript: String,
                                 progress: MeetingNotesService.Progress) async -> [String] {
        var notes: [String] = []
        let all = windows(of: transcript, size: windowSize)
        for (index, window) in all.enumerated() {
            guard !Task.isCancelled else { return [] }
            await progress("Reading transcript · \(index + 1) of \(all.count)…")
            // Fresh session per window — context does not accumulate.
            let session = LanguageModelSession(instructions: """
                Compress this slice of a meeting transcript (lines are \
                "**Name** [minute:second]: what they said"; "You" is the \
                user) into dense bullet notes. Keep every decision, \
                commitment, number, name, and deadline exactly; drop \
                greetings, small talk and filler. Bullets only, no headings, \
                no preamble.
                """)
            if let response = try? await session.respond(to: window) {
                notes.append(response.content)
            } else {
                // A dropped window is a hole in the middle of the meeting —
                // worth knowing about, since the summary will read as if
                // that stretch never happened.
                Analytics.track("meeting_window_compression_failed",
                                ["window": index, "of": all.count])
            }
        }
        return notes
    }

    /// Fold notes down until they fit the model's window — by summarizing
    /// again, never by cutting.
    ///
    /// This used to be `prefix(windowSize)`. On any meeting long enough to
    /// need windowing, that silently threw away the tail before the write-up
    /// pass ever saw it, which is exactly why summaries of long meetings
    /// stopped around the halfway mark.
    @available(macOS 26.0, *)
    private static func reduceToFit(_ notes: [String]) async -> String {
        var current = notes
        var pass = 0
        while current.joined(separator: "\n").count > windowSize, pass < 3 {
            guard !Task.isCancelled else { return "" }
            pass += 1
            var folded: [String] = []
            for group in windows(of: current.joined(separator: "\n\n"), size: windowSize) {
                guard !Task.isCancelled else { return "" }
                let session = LanguageModelSession(instructions: """
                    Condense these meeting notes by about half. Keep every \
                    decision, commitment, number, name, and deadline. Bullets \
                    only, no headings, no preamble.
                    """)
                if let response = try? await session.respond(to: group) {
                    folded.append(response.content)
                } else {
                    folded.append(group)
                }
            }
            guard folded.joined().count < current.joined().count else { break }
            current = folded
        }
        let joined = current.joined(separator: "\n")
        // Only if condensing genuinely could not converge; keeping the END is
        // the lesser evil, because that is where the commitments are.
        return joined.count <= windowSize ? joined : String(joined.suffix(windowSize))
    }
    #endif

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
