import XCTest
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import AppKit
@testable import MyMan

final class RecordingPolishTests: XCTestCase {
    func testClicksClusterIntoZoomWindowsThatEaseInAndOut() {
        let clicks = [RecordedClick(time: 2.0, x: 0.2, y: 0.3), RecordedClick(time: 2.5, x: 0.3, y: 0.3),
                      RecordedClick(time: 9.0, x: 0.8, y: 0.8)]
        let windows = ZoomTimeline.windows(for: clicks)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, 1.65, accuracy: 0.001)
        XCTAssertEqual(windows[0].end, 4.3, accuracy: 0.001)
        XCTAssertEqual(windows[0].x, 0.25, accuracy: 0.001)
        XCTAssertEqual(ZoomTimeline.zoom(at: 0, windows: windows, scale: 2).scale, 1)
        XCTAssertEqual(ZoomTimeline.zoom(at: 3, windows: windows, scale: 2).scale, 2)
        let mid = ZoomTimeline.zoom(at: 1.85, windows: windows, scale: 2)
        XCTAssertGreaterThan(mid.scale, 1); XCTAssertLessThan(mid.scale, 2)
        XCTAssertEqual(ZoomTimeline.zoom(at: 6, windows: windows, scale: 2).scale, 1, "full view between clicks")
        XCTAssertEqual(ZoomTimeline.zoom(at: 9.5, windows: windows, scale: 2).x, 0.8)
        // The crop never leaves the frame, even for a click at the edge.
        let crop = ZoomTimeline.cropRect(for: .init(scale: 2, x: 0.98, y: 0.02), in: CGSize(width: 1000, height: 600))
        XCTAssertEqual(crop, CGRect(x: 500, y: 0, width: 500, height: 300))
    }

    func testClickLogRoundTripsAndDropsGarbage() throws {
        let movie = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clicklog-\(UUID().uuidString).mov")
        ClickLog.save([RecordedClick(time: 1, x: 0.5, y: 0.5)], for: movie)
        XCTAssertEqual(ClickLog.load(for: movie), [RecordedClick(time: 1, x: 0.5, y: 0.5)])
        try Data(#"[{"time":1,"x":1.5,"y":0.2},{"time":0.5,"x":0.1,"y":0.1}]"#.utf8).write(to: ClickLog.url(for: movie))
        XCTAssertEqual(ClickLog.load(for: movie).map(\.x), [0.1])
        try? FileManager.default.removeItem(at: ClickLog.url(for: movie))
    }

    @MainActor func testClickRecorderNormalizesToTheRecordedArea() {
        let recorder = ClickRecorder(regionAppKit: CGRect(x: 100, y: 100, width: 400, height: 200), startedAt: Date(timeIntervalSince1970: 0))
        recorder.record(CGPoint(x: 300, y: 250), at: Date(timeIntervalSince1970: 3))
        recorder.record(CGPoint(x: 10, y: 10), at: Date(timeIntervalSince1970: 4))
        let clicks = recorder.stop()
        XCTAssertEqual(clicks.count, 1, "clicks outside the area are ignored")
        XCTAssertEqual(clicks[0].time, 3); XCTAssertEqual(clicks[0].x, 0.5); XCTAssertEqual(clicks[0].y, 0.25, accuracy: 0.0001)
    }

    @MainActor func testPolishedExportHasBackdropTrimAndZoom() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("take.mov")
        try await fixtureVideo(source)
        var options = PolishOptions()
        options.backdrop = .ocean; options.trimStart = 0.5; options.trimEnd = 1.5; options.zoomScale = 2
        let clicks = [RecordedClick(time: 1.0, x: 0.05, y: 0.05)]
        let destination = RecordingPolish.outputURL(for: source)
        XCTAssertTrue(destination.lastPathComponent.hasSuffix("take.polished.mp4"))
        var last = 0.0
        try await RecordingPolish.export(source: source, to: destination, options: options, clicks: clicks) { last = $0 }
        XCTAssertEqual(last, 1)
        let asset = AVURLAsset(url: destination)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 1.0, accuracy: 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let frame = RecordingPolish.frame(for: CGSize(width: 320, height: 200), options: options)
        XCTAssertEqual(size.width, frame.output.width, accuracy: 2); XCTAssertEqual(size.height, frame.output.height, accuracy: 2)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let (cg, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(corner.redComponent, 0.5, "the corner is backdrop, not the red/blue frame")
        XCTAssertGreaterThan(corner.blueComponent, 0.2)
        let centre = try XCTUnwrap(bitmap.colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB))
        XCTAssertTrue(centre.redComponent > 0.8 || centre.blueComponent > 0.8, "the card shows the recording")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClickLog.url(for: destination).path))
    }

    @MainActor private func fixtureVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<20 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData { guard Date() < deadline else { throw AgentError("TEST_TIMEOUT", "Video writer stalled") }; try await Task.sleep(for: .milliseconds(10)) }
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &value), kCVReturnSuccess)
            let buffer = try XCTUnwrap(value); CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor((index < 10 ? NSColor.red : NSColor.blue).cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
}

final class RecordingPolishStudioTests: XCTestCase {
    func testCursorTrackSmoothsJitterAndStopsAtTheEnds() {
        let samples = (0..<30).map { i in CursorSample(t: Double(i) / 60, x: 0.5 + (i % 2 == 0 ? 0.02 : -0.02), y: 0.5) }
        let track = CursorTrack(separate: true, samples: samples)
        let smoothed = try! XCTUnwrap(track.position(at: 0.25, smoothed: true))
        XCTAssertEqual(smoothed.x, 0.5, accuracy: 0.006, "jitter averages out")
        let raw = try! XCTUnwrap(track.position(at: 0.25, smoothed: false))
        XCTAssertEqual(abs(raw.x - 0.5), 0.02, accuracy: 0.0001, "nearest sample keeps the jitter")
        XCTAssertNil(track.position(at: 5, smoothed: true), "nothing after the last sample")
    }

    func testOnlyShortcutsAndNavigationKeysAreLoggedNeverTyping() {
        XCTAssertEqual(KeystrokeRecorder.label(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command]), "⌘S")
        XCTAssertEqual(KeystrokeRecorder.label(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift]), "⇧⌘S")
        XCTAssertEqual(KeystrokeRecorder.label(keyCode: UInt32(kVK_Escape), modifiers: []), "esc")
        XCTAssertEqual(KeystrokeRecorder.label(keyCode: UInt32(kVK_Return), modifiers: [.option]), "⌥⏎")
        XCTAssertNil(KeystrokeRecorder.label(keyCode: UInt32(kVK_ANSI_S), modifiers: []), "plain typing is never recorded")
        XCTAssertNil(KeystrokeRecorder.label(keyCode: UInt32(kVK_ANSI_S), modifiers: [.shift]), "capital letters are typing too")
    }

    @MainActor func testCursorRecorderNormalizesAndSidecarsRoundTrip() {
        let recorder = CursorTrackRecorder(regionAppKit: CGRect(x: 0, y: 0, width: 200, height: 100), startedAt: Date(timeIntervalSince1970: 0), separate: true)
        recorder.record(CGPoint(x: 50, y: 75), at: Date(timeIntervalSince1970: 1))
        recorder.record(CGPoint(x: 500, y: 75), at: Date(timeIntervalSince1970: 2))
        let track = recorder.stop()
        XCTAssertEqual(track.samples, [CursorSample(t: 1, x: 0.25, y: 0.25)])
        let movie = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidecar-\(UUID().uuidString).mov")
        RecordingSidecars.save(cursor: track, for: movie)
        RecordingSidecars.save(keys: [RecordedKeystroke(t: 1, label: "⌘S")], for: movie)
        XCTAssertEqual(RecordingSidecars.loadCursor(for: movie), track)
        XCTAssertEqual(RecordingSidecars.loadKeys(for: movie).map(\.label), ["⌘S"])
        try? FileManager.default.removeItem(at: RecordingSidecars.cursorURL(for: movie))
        try? FileManager.default.removeItem(at: RecordingSidecars.keysURL(for: movie))
    }

    @MainActor func testRendererDrawsCursorKeystrokesAndBlurWithoutChangingTheFrame() {
        var options = PolishOptions()
        options.backdrop = .none; options.drawCursor = true; options.cursorSize = 2; options.showKeystrokes = true; options.zoomScale = 2
        let cursor = CursorTrack(separate: true, samples: [CursorSample(t: 0, x: 0.5, y: 0.5), CursorSample(t: 2, x: 0.5, y: 0.5)])
        let renderer = RecordingPolish.Renderer(size: CGSize(width: 320, height: 200), options: options,
                                                clicks: [RecordedClick(time: 1, x: 0.5, y: 0.5)], cursor: cursor,
                                                keystrokes: [RecordedKeystroke(t: 0.2, label: "⌘S")])
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let context = CIContext()
        for time in [0.3, 0.75, 1.0] {
            let output = renderer.render(source, at: time)
            XCTAssertEqual(output.extent.size, CGSize(width: 320, height: 200), "time \(time)")
            let cg = try! XCTUnwrap(context.createCGImage(output, from: output.extent))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let corner = try! XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(corner.blueComponent, 0.8, "the frame itself survives at time \(time)")
        }
        // At 0.3s the keystroke pill sits near the bottom centre: darker than the blue frame.
        let withPill = renderer.render(source, at: 0.3)
        let cg = try! XCTUnwrap(context.createCGImage(withPill, from: withPill.extent))
        let pill = try! XCTUnwrap(NSBitmapImageRep(cgImage: cg).colorAt(x: 160, y: 200 - Int(200 * 0.06) - 6)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(pill.blueComponent, 0.7)
    }
}

// MARK: - record polish for agents (same recipe as the Linux companion)

extension RecordingPolishTests {
    func testAgentPolishFlagsMergeIntoTheLinuxRecipe() throws {
        let recipe = try AgentPolish.recipe(from: ["id": "x", "auto_zoom": "strong", "cursor": "big", "background": "dusk", "corner_radius": 24.0,
                                                   "recipe": ["zoom": ["auto": false]] as [String: Any]])
        let plan = try AgentPolish.plan(recipe)
        XCTAssertTrue(plan.zoom); XCTAssertTrue(plan.autoZoom, "the flag overrides the recipe, like Linux")
        XCTAssertEqual(plan.level, 2.4); XCTAssertEqual(plan.options.zoomScale, 2.4, accuracy: 0.001)
        XCTAssertTrue(plan.cursor); XCTAssertEqual(plan.cursorSize, 2)
        XCTAssertEqual(plan.options.backdrop, .dusk); XCTAssertEqual(plan.options.cornerRadius, 24)
        XCTAssertFalse(plan.options.drawCursor, "drawn only once a hidden-cursor track is found")
        XCTAssertEqual((plan.recipe["background"] as? [String: Any])?["style"] as? String, "dusk")
    }

    func testAgentPolishValidatesLikeLinux() throws {
        func code(_ recipe: [String: Any]) -> String? {
            do { _ = try AgentPolish.plan(recipe); return nil } catch { return (error as? AgentError)?.code }
        }
        XCTAssertEqual(code(["zoom": ["auto": true, "speed": 2] as [String: Any]]), "INVALID_ARGUMENTS", "unknown keys are errors")
        XCTAssertEqual(code(["zoom": ["level": 9] as [String: Any]]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["background": ["style": "neon"]]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["background": ["style": "custom"]]), "INVALID_ARGUMENTS", "custom needs a colour")
        XCTAssertEqual(code(["cursor": ["size": true, "smooth": 1] as [String: Any]]), nil, "a JSON true size means normal")
        XCTAssertEqual(code(["cursor": ["size": 1] as [String: Any]]), nil, "1 is a size, not true")
        XCTAssertEqual(code([:]), "INVALID_ARGUMENTS", "nothing to polish")
        XCTAssertEqual(code(["music": "upbeat"]), "UNSUPPORTED", "built-in tracks are rendered by the companion")
        XCTAssertEqual(code(["music": ["track": "polka"]]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["music": "relative/song.wav"]), "INVALID_ARGUMENTS", "a bare name is a track, and polka-style names fail")
        XCTAssertEqual(code(["music": ["file": "/nonexistent/song.wav"]]), "NOT_FOUND")
        XCTAssertEqual(code(["title": String(repeating: "x", count: 81)]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["title": "one\ntwo\nthree"]), "INVALID_ARGUMENTS", "at most two lines")
        XCTAssertEqual(code(["end": ["text": "Bye", "seconds": 20] as [String: Any]]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["title": ["text": "Hi", "colour": "red"]]), "INVALID_ARGUMENTS", "unknown keys are errors")
        XCTAssertEqual(code(["title": "Hi"]), nil, "a card alone is enough to polish")
        let custom = try AgentPolish.plan(try AgentPolish.recipe(from: ["id": "x", "background_color": "#1E293B"]))
        XCTAssertEqual(custom.background, "custom"); XCTAssertEqual(AgentPolish.hex(custom.options.customColor), "#1E293B")
    }

    func testCardsAndMusicParseLikeLinux() throws {
        let song = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("song-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: song.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: song) }
        let flags = try AgentPolish.plan(try AgentPolish.recipe(from: ["id": "x", "title": "Launch day", "end": "Thanks",
                                                                      "music": song.path, "music_volume": 0.3, "music_track": "calm"]))
        XCTAssertEqual(flags.title?.text, "Launch day"); XCTAssertEqual(flags.title?.seconds, 2.5)
        XCTAssertEqual(flags.end?.seconds, 2)
        XCTAssertEqual(flags.music?.file, song.path); XCTAssertEqual(flags.music?.track, "calm"); XCTAssertEqual(flags.music?.volume, 0.3)
        XCTAssertFalse(flags.reframes); XCTAssertTrue(flags.finishes)
        XCTAssertEqual((flags.recipe["music"] as? [String: Any])?["fade_out"] as? Double, 2.5)
        let recipe = try AgentPolish.plan(["zoom": true, "title": ["text": "Hi", "subtitle": "A demo", "seconds": 1] as [String: Any],
                                           "music": ["file": song.path, "duck": false, "start": 4] as [String: Any]])
        XCTAssertEqual(recipe.title?.subtitle, "A demo"); XCTAssertEqual(recipe.title?.seconds, 1)
        XCTAssertEqual(recipe.music?.duck, false); XCTAssertEqual(recipe.music?.start, 4)
        XCTAssertNil(recipe.music?.volume)
        XCTAssertEqual(DemoFinish.volume(recipe.music!, recordingHasAudio: false), 0.8)
        XCTAssertEqual(DemoFinish.volume(recipe.music!, recordingHasAudio: true), 0.4)
    }

    @MainActor func testTitleCardAndMusicAreJoinedAroundTheVideo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("take.mov"), song = dir.appendingPathComponent("song.wav")
        try await fixtureVideo(source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: song, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for ch in 0..<2 { for i in 0..<44_100 { buffer.floatChannelData![ch][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44_100) } }
        try file.write(from: buffer)
        let plan = try AgentPolish.plan(["title": ["text": "Launch day", "seconds": 1] as [String: Any], "end": "Thanks", "music": ["file": song.path]])
        let destination = dir.appendingPathComponent("finished.mp4")
        let length = try await AVURLAsset(url: source).load(.duration).seconds
        let done = try await DemoFinish.finish(input: source, to: destination, title: plan.title, end: plan.end, music: plan.music,
                                               options: plan.options, work: dir)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, length + 3, accuracy: 0.2, "title and end cards add their seconds")
        XCTAssertFalse(try await asset.loadTracks(withMediaType: .audio).isEmpty, "music is mixed in")
        XCTAssertEqual((done["cards"] as? [String: Any])?["video_starts_at"] as? Double, 1)
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 200), "cards match the video frame")
    }

    func testHandWrittenMomentsBecomeFractionsOfTheFrame() throws {
        let plan = try AgentPolish.plan(["zoom": ["moments": [["start": 0.5, "end": 1.5, "x": 80, "y": 50]]] as [String: Any]])
        XCTAssertFalse(plan.autoZoom)
        let windows = AgentPolish.windows(plan.moments, size: CGSize(width: 320, height: 200))
        XCTAssertEqual(windows, [ZoomTimeline.Window(start: 0.5, end: 1.5, x: 0.25, y: 0.25)])
    }

    @MainActor func testPolishRendersHandWrittenZoomWithoutClicks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("take.mov")
        try await fixtureVideo(source)
        let plan = try AgentPolish.plan(try AgentPolish.recipe(from: ["id": "x", "background": "slate",
                                                                     "recipe": ["zoom": ["level": 2, "moments": [["start": 0.2, "end": 1.6, "x": 16, "y": 10]]]] as [String: Any]]))
        let size = try await AgentPolish.videoSize(source)
        XCTAssertEqual(size, CGSize(width: 320, height: 200))
        let destination = dir.appendingPathComponent("polished.mp4")
        try await RecordingPolish.export(source: source, to: destination, options: plan.options, clicks: [],
                                         zoomWindows: AgentPolish.windows(plan.moments, size: size))
        let track = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first
        let rendered = try await track?.load(.naturalSize)
        XCTAssertEqual(rendered, RecordingPolish.frame(for: size, options: plan.options).output, "backdrop padding grows the frame")
    }

    func testCaptionsParseLikeLinuxAndMakeRoomUnderTheVideo() throws {
        let plan = try AgentPolish.plan(["captions": [["text": "Second", "start": 3, "end": 5], ["text": "First", "start": 0.5, "end": 2]]])
        XCTAssertTrue(plan.finishes, "captions alone are work for the joining step")
        XCTAssertEqual(plan.captions.map(\.text), ["First", "Second"], "sorted by start")
        XCTAssertEqual((plan.recipe["captions"] as? [[String: Any]])?.count, 2)
        func code(_ recipe: [String: Any]) -> String? { do { _ = try AgentPolish.plan(recipe); return nil } catch { return (error as? AgentError)?.code } }
        XCTAssertEqual(code(["captions": [["text": "x", "start": 2, "end": 1]]]), "INVALID_ARGUMENTS", "end must be after start")
        XCTAssertEqual(code(["captions": [["text": "x", "start": 0, "end": 1, "size": 3]]]), "INVALID_ARGUMENTS", "unknown keys fail")
        XCTAssertEqual(code(["captions": "hello"]), "INVALID_ARGUMENTS")
        XCTAssertEqual(DemoFinish.captionPoints(420), 21); XCTAssertEqual(DemoFinish.captionBand(videoHeight: 420, padding: 38), 46)
        var options = PolishOptions(); options.backdrop = .dusk; options.captionBand = 46
        let frame = RecordingPolish.frame(for: CGSize(width: 640, height: 420), options: options)
        XCTAssertEqual(frame.output.height, 420 + frame.padding * 2 + 46); XCTAssertEqual(frame.band, 46)
        XCTAssertNotNil(DemoFinish.captionImage(.init(text: "Search for a song", start: 0, end: 1), videoSize: CGSize(width: 640, height: 420)))
    }
}
