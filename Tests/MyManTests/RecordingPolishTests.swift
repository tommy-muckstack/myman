import XCTest
import AVFoundation
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
