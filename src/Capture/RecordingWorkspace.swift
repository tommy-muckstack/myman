import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingProject: Codable, Equatable {
    struct Overlay: Codable, Equatable, Identifiable {
        var id = UUID()
        var kind = "caption"
        var text = ""
        var start = 0.0
        var end = 3.0
        var x = 0.0; var y = 0.0; var width = 200.0; var height = 100.0
        var json: [String: Any] {
            var value: [String: Any] = ["type": kind, "start": start, "end": end]
            if kind == "redact" || kind == "zoom" { value["rect"] = [x, y, width, height] }
            else { value["text"] = text }
            return value
        }
    }
    struct Polish: Codable, Equatable {
        var trimStart: Double; var trimEnd: Double?
        var backdrop: String
        var zoomOnClicks: Bool; var zoomScale: Double
        var drawCursor: Bool; var smoothCursor: Bool; var cursorSize: Double
        var showKeystrokes: Bool; var motionBlur: Bool
        init(_ value: PolishOptions) {
            trimStart = value.trimStart; trimEnd = value.trimEnd; backdrop = value.backdrop.rawValue
            zoomOnClicks = value.zoomOnClicks; zoomScale = Double(value.zoomScale)
            drawCursor = value.drawCursor; smoothCursor = value.smoothCursor; cursorSize = Double(value.cursorSize)
            showKeystrokes = value.showKeystrokes; motionBlur = value.motionBlur
        }
        var options: PolishOptions {
            var value = PolishOptions()
            value.trimStart = trimStart; value.trimEnd = trimEnd
            value.backdrop = BackdropStyle(rawValue: backdrop) ?? .ocean
            value.zoomOnClicks = zoomOnClicks; value.zoomScale = CGFloat(zoomScale)
            value.drawCursor = drawCursor; value.smoothCursor = smoothCursor; value.cursorSize = CGFloat(cursorSize)
            value.showKeystrokes = showKeystrokes; value.motionBlur = motionBlur
            return value
        }
    }
    var polish: Polish? = nil
    var version = 1
    var edits = RecordingEditList()
    var captions: [RecordingTranscript.Segment] = []
    var title = ""
    var end = ""
    var musicPath = ""
    var musicVolume = 0.12
    var burnCaptions = false
    var overlays: [Overlay] = []
    var sourceBytes: Int? = nil
    var sourceModifiedAt: Date? = nil
    func retimedCaptions(words: [RecordingTranscript.Segment], ranges: [RecordingEditList.Cut], offset: Double = 0) -> [RecordingTranscript.Segment] {
        captions.flatMap { caption -> [RecordingTranscript.Segment] in
            let aligned = words.filter { $0.start >= caption.start - 0.001 && $0.end <= caption.end + 0.001 }
            if !aligned.isEmpty, aligned.map(\.text).joined(separator: " ") == caption.text {
                let retainedWords = aligned.filter { word in ranges.contains { $0.start <= word.start && $0.end >= word.end } }
                return RecordingTranscript.captions(RecordingEditList.retime(retainedWords, ranges: ranges, offset: offset))
            }
            let completeRanges = ranges.filter { $0.start <= caption.start && $0.end >= caption.end }
            guard !completeRanges.isEmpty else { return [] }
            return RecordingEditList.retime([caption], ranges: ranges, offset: offset)
        }.sorted { $0.start < $1.start }
    }
    static func url(for movie: URL) -> URL { movie.appendingPathExtension("edits.json") }
    static func load(for movie: URL) -> Self? {
        guard let data = try? Data(contentsOf: url(for: movie)), data.count <= 20_000_000,
              let project = try? JSONDecoder().decode(Self.self, from: data), project.version == 1,
              let attributes = try? URL(fileURLWithPath: movie.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              project.sourceBytes == attributes.fileSize, project.sourceModifiedAt == attributes.contentModificationDate else { return nil }
        return project
    }
    func save(for movie: URL) throws {
        var copy = self
        let attributes = try URL(fileURLWithPath: movie.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        copy.sourceBytes = attributes.fileSize; copy.sourceModifiedAt = attributes.contentModificationDate
        try JSONEncoder().encode(copy).write(to: Self.url(for: movie), options: .atomic)
    }
}

@MainActor enum RecordingWorkspaceExport {
    static func destination(for source: URL) -> URL {
        let base = source.deletingPathExtension()
        for number in 1...1000 {
            let suffix = number == 1 ? "polished.mp4" : "polished-\(number).mp4"
            let url = base.appendingPathExtension(suffix)
            if artifacts(for: url).allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) { return url }
        }
        return base.appendingPathExtension(UUID().uuidString + ".mp4")
    }
    private static func artifacts(for url: URL) -> [URL] {
        [url, RecordingTranscript.url(for: url), url.deletingPathExtension().appendingPathExtension("vtt")]
    }
    static func export(source: URL, destination: URL, project: RecordingProject, options: PolishOptions,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let outputs = artifacts(for: destination)
        guard outputs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PersonalizationError.invalid("Choose a new output name; an export or subtitle already exists there.")
        }
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        guard project.overlays.count <= 20, project.captions.count <= 30_000,
              project.title.count <= 2000, project.end.count <= 2000,
              project.musicVolume.isFinite, (0...0.5).contains(project.musicVolume),
              project.captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.01 && $0.text.count <= 10_000 }),
              options.zoomScale.isFinite, (1...4).contains(options.zoomScale),
              options.cursorSize.isFinite, (1...3).contains(options.cursorSize) else {
            throw PersonalizationError.invalid("Review the edit ranges, caption lengths, zoom and music volume before exporting.")
        }
        var cuts = project.edits
        if options.trimStart > 0 { cuts.cuts.append(.init(start: 0, end: options.trimStart)) }
        if let end = options.trimEnd, end < duration { cuts.cuts.append(.init(start: end, end: duration)) }
        let ranges = try cuts.keptRanges(duration: duration)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("myman-edit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Burn original-coordinate redactions BEFORE cuts, reframing and zoom.
        // They cannot reveal original pixels through a subsequent transform.
        var input = source
        if !project.overlays.isEmpty {
            input = work.appendingPathComponent("overlays.mp4")
            try await AgentVideo.export(source, to: input, edits: project.overlays.map(\.json))
        }
        progress(0.15)
        let cut = work.appendingPathComponent("cut.mp4")
        try await assemble(input, ranges: ranges, to: cut)
        let clicks = ClickLog.load(for: source).compactMap { click in
            RecordingEditList.mappedTime(click.time, ranges: ranges).map { RecordedClick(time: $0, x: click.x, y: click.y) }
        }
        let cursor = RecordingSidecars.loadCursor(for: source).map { track in
            CursorTrack(separate: track.separate, samples: track.samples.compactMap { sample in
                RecordingEditList.mappedTime(sample.t, ranges: ranges).map { CursorSample(t: $0, x: sample.x, y: sample.y) }
            })
        }
        let keys = RecordingSidecars.loadKeys(for: source).compactMap { key in
            RecordingEditList.mappedTime(key.t, ranges: ranges).map { RecordedKeystroke(t: $0, label: key.label) }
        }
        var polish = options; polish.trimStart = 0; polish.trimEnd = nil
        let polished = work.appendingPathComponent("polished.mp4")
        try await RecordingPolish.export(source: cut, to: polished, options: polish, clicks: clicks, cursor: cursor, keystrokes: keys) { progress(0.2 + $0 * 0.55) }
        try Task.checkCancellation()
        let words = RecordingTranscript.load(for: source)?.segments ?? []
        let captions = project.retimedCaptions(words: words, ranges: ranges)
        let title: DemoFinish.Card? = project.title.isEmpty ? nil : .init(text: project.title, subtitle: nil, seconds: 3)
        let end: DemoFinish.Card? = project.end.isEmpty ? nil : .init(text: project.end, subtitle: nil, seconds: 3)
        let music: DemoFinish.Music? = project.musicPath.isEmpty ? nil : .init(file: project.musicPath, track: nil, volume: project.musicVolume)
        let finished = work.appendingPathComponent("finished.mp4")
        _ = try await DemoFinish.finish(input: polished, to: finished, title: title, end: end, music: music,
                                        captions: project.burnCaptions ? captions.map { .init(text: $0.text, start: $0.start, end: $0.end) } : [],
                                        options: polish, work: work)
        try Task.checkCancellation()
        // Publish the complete output only once every stage succeeded.
        try FileManager.default.moveItem(at: finished, to: destination)
        var complete = false
        defer { if !complete { for output in outputs { try? FileManager.default.removeItem(at: output) } } }
        let finalCaptions = project.retimedCaptions(words: words, ranges: ranges, offset: title?.seconds ?? 0)
        try RecordingTranscript.save(finalCaptions, for: destination)
        try RecordingTranscript.subtitles(finalCaptions, webVTT: true).write(to: destination.deletingPathExtension().appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
        var savedProject = project; savedProject.polish = .init(options)
        try savedProject.save(for: source)
        complete = true
        progress(1)
    }

    static func assemble(_ source: URL, ranges: [RecordingEditList.Cut], to destination: URL) async throws {
        let asset = AVURLAsset(url: source), composition = AVMutableComposition()
        for type in [AVMediaType.video, .audio] {
            for sourceTrack in try await asset.loadTracks(withMediaType: type) {
                guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
                if type == .video { target.preferredTransform = try await sourceTrack.load(.preferredTransform) }
                let available = try await sourceTrack.load(.timeRange)
                var cursor = CMTime.zero
                for range in ranges {
                    let selected = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
                    let intersection = CMTimeRangeGetIntersection(selected, otherRange: available)
                    if intersection.duration.seconds > 0 {
                        try target.insertTimeRange(intersection, of: sourceTrack, at: CMTimeAdd(cursor, CMTimeSubtract(intersection.start, selected.start)))
                    }
                    cursor = CMTimeAdd(cursor, selected.duration)
                }
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CocoaError(.fileWriteUnknown) }
        exporter.outputURL = destination; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
    }
}

struct RecordingTimelineControls: View {
    let movie: URL
    let duration: Double
    @Binding var project: RecordingProject
    var trimStart: Double
    var trimEnd: Double
    var seek: (Double) -> Void
    @State private var words: [RecordingTranscript.Segment] = []
    @State private var undo: [RecordingProject] = []
    @State private var restoring = false
    @State private var suggestions: [RecordingEditList.Cut] = []
    @State private var isTranscribing = false
    @State private var status = ""
    @State private var cutStart = 0.0
    @State private var cutEnd = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Text("Transcript and cuts").font(MM.Fonts.title)
                Spacer()
                Button("Undo edit") { if let prior = undo.popLast() { restoring = true; project = prior } }.disabled(undo.isEmpty).clickable()
                Button("Save edits") { do { try project.save(for: movie); status = "Edits saved. Original media is unchanged." } catch { status = error.localizedDescription } }.clickable()
            }
            Text("Cuts remove aligned words. A rewritten caption crossing a cut is omitted; keep that caption entirely inside a retained section.").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            HStack {
                Button(isTranscribing ? "Transcribing…" : "Generate timed transcript") {
                    isTranscribing = true; status = ""
                    Task {
                        do {
                            let next = try await RecordingTranscriber.transcribe(movie)
                            words = next; project.captions = RecordingTranscript.captions(next)
                            status = next.isEmpty ? "No timed speech was recognized." : "Transcript ready. Review captions before exporting."
                        } catch { status = error.localizedDescription }
                        isTranscribing = false
                    }
                }.disabled(isTranscribing).clickable()
                Menu("Export subtitles") {
                    Button("SRT…") { subtitles(webVTT: false) }.clickable()
                    Button("WebVTT…") { subtitles(webVTT: true) }.clickable()
                }.disabled(project.captions.isEmpty).clickable()
                Toggle("Burn captions into export", isOn: $project.burnCaptions).clickable()
            }
            if !project.captions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MM.Layout.spacing) {
                        ForEach($project.captions) { $caption in
                            HStack(alignment: .top) {
                                Button(MeetingSource.stamp(caption.start)) { seek(caption.start) }.clickable()
                                TextField("Caption", text: $caption.text, axis: .vertical).clickable()
                                Button("Cut") { project.edits.cuts.append(.init(start: caption.start, end: caption.end)) }.clickable()
                            }
                        }
                    }
                }.frame(height: 180)
                Menu("Chapter markers") {
                    ForEach(RecordingTranscript.chapters(project.captions)) { chapter in
                        Button(MeetingSource.stamp(chapter.start) + " " + chapter.text) { seek(chapter.start) }.clickable()
                    }
                }.clickable()
            }
            HStack {
                Text("Cut from")
                TextField("Start", value: $cutStart, format: .number).frame(width: 80).clickable()
                Text("to")
                TextField("End", value: $cutEnd, format: .number).frame(width: 80).clickable()
                Text("seconds")
                Spacer()
                Button("Add cut") {
                    var next = project; next.edits.cuts.append(.init(start: cutStart, end: cutEnd))
                    do { _ = try next.edits.keptRanges(duration: duration); project = next; status = "" }
                    catch { status = error.localizedDescription }
                }.clickable()
            }
            ForEach(project.edits.cuts) { cut in
                HStack {
                    Button("Review \(MeetingSource.stamp(cut.start))–\(MeetingSource.stamp(cut.end))") { seek(cut.start) }.clickable()
                    Spacer()
                    Button("Restore") { project.edits.cuts.removeAll { $0.id == cut.id } }.clickable()
                }
            }
            HStack {
                Button("Review gaps") { suggestions = RecordingEditList.gapSuggestions(words, duration: duration) }.disabled(words.isEmpty).clickable()
                Button("Review fillers") { suggestions = RecordingEditList.fillerSuggestions(words) }.disabled(words.isEmpty).clickable()
                Text("Suggestions require review; a gap in recognition may contain speech.").font(MM.Fonts.metadata)
            }
            ForEach(suggestions) { cut in
                HStack {
                    Button("Listen at \(MeetingSource.stamp(cut.start))") { seek(max(0, cut.start - 0.5)) }.clickable()
                    Text(String(format: "%.2f–%.2f s", cut.start, cut.end)).font(MM.Fonts.metadata)
                    Button("Remove this interval") { project.edits.cuts.append(cut); suggestions.removeAll { $0.id == cut.id } }.clickable()
                    Button("Keep") { suggestions.removeAll { $0.id == cut.id } }.clickable()
                }
            }
            DisclosureGroup("Titles, music and timed overlays") {
                VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                    TextField("Opening title (3 seconds)", text: $project.title).clickable()
                    TextField("Closing title (3 seconds)", text: $project.end).clickable()
                    HStack {
                        Button("Choose music…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; if panel.runModal() == .OK, let url = panel.url { project.musicPath = url.path } }.clickable()
                        Text(project.musicPath.isEmpty ? "No music" : URL(fileURLWithPath: project.musicPath).lastPathComponent).font(MM.Fonts.metadata)
                        Button("Remove music") { project.musicPath = "" }.disabled(project.musicPath.isEmpty).clickable()
                        Slider(value: $project.musicVolume, in: 0...0.5).clickable().accessibilityLabel("Music volume")
                    }
                    ForEach($project.overlays) { $overlay in
                        VStack(alignment: .leading) {
                            HStack {
                                Picker("Type", selection: $overlay.kind) { Text("Caption").tag("caption"); Text("Title").tag("title"); Text("Redact").tag("redact"); Text("Zoom").tag("zoom") }.clickable()
                                TextField("Start", value: $overlay.start, format: .number).clickable()
                                TextField("End", value: $overlay.end, format: .number).clickable()
                                Button("Remove") { project.overlays.removeAll { $0.id == overlay.id } }.clickable()
                            }
                            if overlay.kind == "redact" || overlay.kind == "zoom" {
                                HStack {
                                    Text("Source pixels: x, y, width, height").font(MM.Fonts.metadata)
                                    TextField("X", value: $overlay.x, format: .number).clickable()
                                    TextField("Y", value: $overlay.y, format: .number).clickable()
                                    TextField("Width", value: $overlay.width, format: .number).clickable()
                                    TextField("Height", value: $overlay.height, format: .number).clickable()
                                }
                            } else { TextField("Overlay text", text: $overlay.text).clickable() }
                        }
                    }
                    Button("Add overlay") { project.overlays.append(.init(end: min(3, duration))) }.disabled(project.overlays.count >= 20).clickable()
                }
            }.clickable()
            if !status.isEmpty { Text(status).font(MM.Fonts.metadata) }
        }.font(MM.Fonts.secondary).onChange(of: project) { old, _ in
            if restoring { restoring = false }
            else { undo = Array((undo + [old]).suffix(30)) }
        }.task {
            words = RecordingTranscript.load(for: movie)?.segments ?? []
        }
    }
    private func subtitles(webVTT: Bool) {
        do {
            var edits = project.edits
            if trimStart > 0 { edits.cuts.append(.init(start: 0, end: trimStart)) }
            if trimEnd < duration { edits.cuts.append(.init(start: trimEnd, end: duration)) }
            let ranges = try edits.keptRanges(duration: duration)
            let captions = project.retimedCaptions(words: words, ranges: ranges, offset: project.title.isEmpty ? 0 : 3)
            let panel = NSSavePanel(); panel.nameFieldStringValue = movie.deletingPathExtension().lastPathComponent + (webVTT ? ".vtt" : ".srt")
            if panel.runModal() == .OK, let url = panel.url { try RecordingTranscript.subtitles(captions, webVTT: webVTT).write(to: url, atomically: true, encoding: .utf8) }
        } catch { status = error.localizedDescription }
    }
}
