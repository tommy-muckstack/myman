import AppKit
import AVFoundation
import GRDB
import SwiftUI
import XCTest
@testable import MyMan

final class CapturePreviewTests: XCTestCase {
    private func item(_ kind: String, path: String = "", title: String = "Design review", body: String = "Review the mockups and agree on next steps.") -> CaptureItem {
        CaptureItem(id: kind + "-preview", kind: kind, sourceID: "preview", rawTitle: title,
                    generatedTitle: "", userTitle: "", body: body, summary: "", metadata: "", sourcePath: path,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000), modifiedAt: Date(),
                    pinned: false, excluded: false, revision: 1)
    }

    @MainActor func testMeetingSkipsMissingSlidesAndVideoLoadsARealFrame() async throws {
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = try DatabaseQueue()
        try Database.migrator.migrate(queue)
        let slide = folder.appendingPathComponent("slide.png")
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill()
            ("Design review" as NSString).draw(at: NSPoint(x: 20, y: 100),
                withAttributes: [.font: MM.Fonts.native(28, .medium), .foregroundColor: NSColor.white])
            return true
        }
        try AgentImages.png(image).write(to: slide)
        var meeting = Meeting(id: "preview", title: "Design review", startedAt: Date(), transcript: "")
        meeting.slides = String(decoding: try JSONEncoder().encode([folder.appendingPathComponent("missing.png").path, slide.path]), as: UTF8.self)
        let savedMeeting = meeting
        try await queue.write { try savedMeeting.insert($0) }
        let meetingImage = await CapturePreviewLoader.load(item("meeting"), database: queue)
        XCTAssertNotNil(meetingImage, "Use the next readable slide if the first file is missing")
        XCTAssertLessThanOrEqual(try XCTUnwrap(meetingImage).size.width, 160)

        let movie = folder.appendingPathComponent("recording.mov")
        try await writeMovie(movie)
        let recording = item("recording", path: movie.path)
        let loaded = await CapturePreviewLoader.load(recording, database: queue)
        let preview = try XCTUnwrap(loaded)
        XCTAssertLessThanOrEqual(preview.size.width, 160)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(preview.tiffRepresentation)))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8, "Thumbnail contains the recording's red frame")
        let cached = await CapturePreviewLoader.load(recording, database: queue)
        XCTAssertTrue(cached === preview)
        let missing = await CapturePreviewLoader.load(item("recording", path: folder.appendingPathComponent("missing.mov").path), database: queue)
        XCTAssertNil(missing)

        if let reviewFolder = ProcessInfo.processInfo.environment["MAN_SCREENSHOT_UI_REVIEW"] {
            try await render([
                item("note", title: "Design notes", body: "## Decisions\nUse a quieter toolbar.\n\n- Keep the search field visible\n- Review **keyboard shortcuts**\n\nNext review on Friday."),
                item("meeting"), recording
            ], database: queue, folder: reviewFolder)
        }
        try await queue.write { try $0.execute(sql: "UPDATE meeting SET slides = '[]' WHERE id = 'preview'") }
        let empty = await CapturePreviewLoader.load(item("meeting"), database: queue)
        XCTAssertNil(empty, "A meeting without slides uses the calendar fallback")
    }

    @MainActor private func writeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw AgentError("TEST_TIMEOUT", "Video writer stalled") }
                try await Task.sleep(for: .milliseconds(10))
            }
            var value: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &value), kCVReturnSuccess)
            let buffer = try XCTUnwrap(value)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    @MainActor private func render(_ items: [CaptureItem], database: DatabaseQueue, folder: String) async throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let content = VStack(spacing: 3) {
                ForEach(items) { item in
                    CaptureResultRow(match: .init(item: item, tier: 0, score: 0,
                        excerpt: CaptureText.excerpt(item.body, query: ""), reason: item.kind.capitalized, matchedTerms: []), database: database)
                }
            }.padding(8).background(MM.Colors.background).preferredColorScheme(scheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 620, height: 360)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("capture-previews-\(scheme == .dark ? "dark" : "light").png"))
            window.contentView = nil
            window.close()
        }
    }
}
