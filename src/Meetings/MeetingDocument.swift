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

/// Slide thumbnails without the dead space: captured call windows routinely
/// carry big uniform margins (letterboxed screen shares, empty chrome), and a
/// center-crop of THAT shows mostly margin. Trim the uniform border first so
/// the thumbnail is all content.
enum SlideThumbnailer {
    private static let cache = NSCache<NSString, NSImage>()

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
    @State private var saveTask: Task<Void, Never>?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var saveState: SaveState = .idle
    @State private var linkCopied = false
    @Namespace private var tabNamespace
    @State private var headerHovering = false
    /// Transcript tab defaults to the formatted reading view; this flips to
    /// the raw text editor for corrections.
    @State private var editingTranscript = false

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
                                .font(MM.Fonts.outfit(13, .semiBold))
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
            let generated = await MeetingSummarizer.summarize(
                transcript, meetingDate: meeting.startedAt)
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
    static func summarize(_ transcript: String, meetingDate: Date = Date()) async -> String {
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
                let notes = await compress(transcript)
                guard !notes.isEmpty else { return "" }
                windowCount = notes.count
                body = await reduceToFit(notes)
            }
            let session = LanguageModelSession(
                instructions: transcript.count <= windowSize ? finalInstructions
                    : finalInstructions + """
                         The input is sequential bullet notes covering the \
                        whole meeting start to finish, not raw transcript \
                        lines. Represent the end as fully as the beginning.
                        """)
            let response = try await session.respond(to: body)
            // The write-up pass is told not to produce action items, but a
            // model that ignores that would reintroduce exactly the invented
            // topic-restatements this replaced. Only the extractor's list ships.
            var document = stripActionItems(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            let actions = await ActionItemExtractor.extract(
                from: transcript, meetingDate: meetingDate)
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
    private static func compress(_ transcript: String) async -> [String] {
        var notes: [String] = []
        let all = windows(of: transcript, size: windowSize)
        for (index, window) in all.enumerated() {
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
            pass += 1
            var folded: [String] = []
            for group in windows(of: current.joined(separator: "\n\n"), size: windowSize) {
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
