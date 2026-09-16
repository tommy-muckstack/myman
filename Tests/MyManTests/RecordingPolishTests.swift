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
