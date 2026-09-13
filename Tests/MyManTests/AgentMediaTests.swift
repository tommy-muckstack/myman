import AppKit
import AVFoundation
import XCTest
@testable import MyMan

final class AgentMediaTests: XCTestCase {
    func testOCRTargetsAreStableAndAmbiguityNeverPicksAnArbitraryMatch() throws {
        let size = CGSize(width: 1000, height: 600)
        let lines = [ImageAnalysis.TextObservation(text: "Save", box: CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.1)),
                     ImageAnalysis.TextObservation(text: "Save", box: CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.1))]
        let regions = AgentMarkup.regions(lines, size: size)
        XCTAssertEqual(regions[0].rect.minY, 60, accuracy: 0.001)
        XCTAssertEqual(regions.map(\.id), AgentMarkup.regions(lines, size: size).map(\.id))
        XCTAssertNotEqual(regions[0].id, regions[1].id)
        XCTAssertThrowsError(try AgentMarkup.resolve(["type":"circle", "target_text":"save"], regions: regions, size: size)) {
            let error = $0 as? AgentError
            XCTAssertEqual(error?.code, "AMBIGUOUS_TARGET")
            XCTAssertEqual((error?.json["candidates"] as? [[String: Any]])?.count, 2)
        }
        let selected = try AgentMarkup.resolve(["type":"circle", "target_region":regions[1].id], regions: regions, size: size)
        let rect = try AgentImages.rect(XCTUnwrap(selected["rect"] as? [Double]))
        XCTAssertTrue(rect.contains(regions[1].rect)); XCTAssertFalse(rect.intersects(regions[0].rect))
        XCTAssertThrowsError(try AgentMarkup.resolve(["type":"box", "target_region":"stale-id"], regions: regions, size: size))
    }
    func testCalloutsStayInBoundsAndAvoidEarlierLabels() throws {
        let target = CGRect(x: 170, y: 5, width: 25, height: 20), canvas = CGSize(width: 200, height: 160), label = CGSize(width: 100, height: 30)
        let first = try AgentMarkup.labelRect(size: label, target: target, canvas: canvas, occupied: [])
        let second = try AgentMarkup.labelRect(size: label, target: target, canvas: canvas, occupied: [first])
        XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(first))
        XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(second))
        XCTAssertFalse(first.intersects(second))
        XCTAssertThrowsError(try AgentMarkup.labelRect(size: CGSize(width: 201, height: 40), target: target, canvas: canvas, occupied: []))
    }
    @MainActor func testRenderedMarkupUsesExistingRendererAndPreservesSource() async throws {
        let source = try AgentMediaStore.canvas(size: CGSize(width: 640, height: 400)) { context in
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        let before = try AgentImages.png(source)
        let model = try await AgentActions.annotationModel(image: source, path: "/private/tmp/media-fixture.png", args: ["preview":true, "annotations":[
            ["type":"circle", "rect":[50.0,100.0,120.0,60.0], "color":"#FF0000"],
            ["type":"callout", "rect":[300.0,120.0,120.0,70.0], "text":"Review", "number":2.0, "color":"#007AFF"]
        ]])
        let rendered = try AgentImages.png(model.renderFinal())
        XCTAssertNotEqual(before, rendered); XCTAssertEqual(before, try AgentImages.png(source))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: rendered))
        XCTAssertEqual(bitmap.pixelsWide, 640); XCTAssertEqual(bitmap.pixelsHigh, 400)
        let red = try XCTUnwrap(bitmap.colorAt(x: 110, y: 102)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, 0.8); XCTAssertLessThan(red.greenComponent, 0.3)
    }
    @MainActor func testPreviewDoesNotChangeSavedBackdropAndExpiresOnSourceExclusion() throws {
        let suite = "man-media-test-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try AgentMediaStore.canvas(size: CGSize(width: 40, height: 30)) { _ in }
        let model = EditorModel(image: source, fileURL: folder, preferences: defaults, persistPreferences: false)
        model.customBackdropColor = .red
        XCTAssertNil(defaults.object(forKey: "screenshotCustomBackdropRGB"))
        let store = AgentMediaStore(root: folder)
        let result = try store.image(model.renderFinal())
        let path = try XCTUnwrap(result["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        NotificationCenter.default.post(name: .captureExcluded, object: "shot-fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let older = try store.image(source)
        let oldPath = try XCTUnwrap(older["path"] as? String)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3601)], ofItemAtPath: oldPath)
        store.expire(); XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
    }
    @MainActor func testVideoBoundsRejectEmptyInvalidAndEndOfFileFrames() throws {
        XCTAssertThrowsError(try AgentVideo.range(start: 5, end: 3, duration: 10))
        XCTAssertThrowsError(try AgentVideo.range(start: 0, end: 11, duration: 10))
        XCTAssertThrowsError(try AgentVideo.sampleTimes([10], count: 1, duration: 10))
        XCTAssertThrowsError(try AgentVideo.sampleTimes([Double.nan], count: 1, duration: 10))
        XCTAssertEqual(try AgentVideo.sampleTimes(nil, count: 2, duration: 4), [1,3])
    }
    @MainActor func testVideoFramesTrimAndJoinedSegmentsArePlayable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-media-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await fixtureVideo(source)
        let metadata = try await AgentVideo.attachment(source, preview: false)
        XCTAssertEqual(metadata["width"] as? Double, 320); XCTAssertEqual(metadata["height"] as? Double, 200)
        let store = AgentMediaStore(root: folder.appendingPathComponent("previews"))
        let frames = try await AgentVideo.frames(source, args: ["times":[0.1,1.2], "width":200.0], store: store)
        let results = try XCTUnwrap(frames["frames"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        for frame in results { XCTAssertTrue(FileManager.default.fileExists(atPath: frame["path"] as! String)) }
        XCTAssertNotNil(frames["contact_sheet"])
        let first = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: results[0]["path"] as! String))))
        let last = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: results[1]["path"] as! String))))
        XCTAssertGreaterThan(first.colorAt(x:20,y:20)!.redComponent, first.colorAt(x:20,y:20)!.blueComponent)
        XCTAssertGreaterThan(last.colorAt(x:20,y:20)!.blueComponent, last.colorAt(x:20,y:20)!.redComponent)
        let trimmed = folder.appendingPathComponent("trimmed.mp4")
        try await AgentVideo.export(source, to: trimmed, start: 0.3, end: 1.1)
        let trimMetadata = try await AgentVideo.attachment(trimmed, preview: false)
        XCTAssertEqual(trimMetadata["duration"] as! Double, 0.8, accuracy: 0.15)
        XCTAssertEqual(trimMetadata["mime_type"] as? String, "video/mp4")
        let joined = folder.appendingPathComponent("joined.mov")
        try await AgentVideo.join([trimmed, trimmed], to: joined)
        let joinedMetadata = try await AgentVideo.attachment(joined, preview: false)
        XCTAssertEqual(joinedMetadata["duration"] as! Double, (trimMetadata["duration"] as! Double) * 2, accuracy: 0.15)
        let tooSmall = folder.appendingPathComponent("small.mp4")
        do { try await AgentVideo.export(source, to: tooSmall, maxBytes: 1024); XCTFail("Should reject a cap smaller than the complete clip") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "SIZE_LIMIT_EXCEEDED") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tooSmall.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @MainActor func testFinishedVideoExportKeepsSourceAndUsesOriginalTimeline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("man-finished-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov"), target = folder.appendingPathComponent("finished.mp4")
        try await fixtureVideo(source)
        let original = try Data(contentsOf: source)
        let edits: [[String: Any]] = [
            ["type":"redact","start":0.3,"end":0.8,"rect":[0.0,0.0,100.0,100.0]],
            ["type":"caption","start":0.3,"end":0.7,"text":"A clear explanation"],
            ["type":"step","start":0.8,"end":1.1,"number":1.0,"text":"Save changes"],
            ["type":"title","start":1.4,"end":1.7,"text":"Finished"]]
        try await AgentVideo.export(source, to: target, start: 0.3, end: 1.7, edits: edits)
        let attachment = try await AgentVideo.attachment(target, preview: false)
        XCTAssertEqual(attachment["duration"] as! Double, 1.4, accuracy: 0.12)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(pixel.redComponent, 0.08, "Redaction covers the original .4-second frame even after trim")
        let (title, _) = try await generator.image(at: CMTime(seconds: 1.2, preferredTimescale: 600))
        let titlePixel = try XCTUnwrap(NSBitmapImageRep(cgImage: title).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(titlePixel.blueComponent, 0.08, "Title card covers the original blue frame")
        XCTAssertEqual(try Data(contentsOf: source), original)
        try original.write(to: URL(fileURLWithPath: "/private/tmp/man-v07-video-source.mov"))
        try Data(contentsOf: target).write(to: URL(fileURLWithPath: "/private/tmp/man-v07-video-finished.mp4"))
    }
    @MainActor private func fixtureVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String:320, kCVPixelBufferHeightKey as String:200, kCVPixelBufferCGImageCompatibilityKey as String:true, kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<20 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData { guard Date() < deadline else { throw AgentError("TEST_TIMEOUT", "Video writer stalled") }; try await Task.sleep(for: .milliseconds(10)) }
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &value), kCVReturnSuccess)
            let buffer = try XCTUnwrap(value); CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor((index < 10 ? NSColor.red : NSColor.blue).cgColor); context.fill(CGRect(x: 0,y: 0,width:320,height:200))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
}
