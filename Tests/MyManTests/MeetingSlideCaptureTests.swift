import AppKit
import ImageIO
import XCTest
@testable import MyMan

private actor SlideCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

final class MeetingSlideCaptureTests: XCTestCase {
    private func image(white: CGFloat = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor func testSlowWriterLeavesMainActorResponsiveAndSkipsOverlappingCaptures() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try image()
        let entered = expectation(description: "Background writer started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let capture = MeetingSlideCapture { image, previous, url in
            XCTAssertFalse(Thread.isMainThread, "PNG processing must never run on the UI thread")
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return try MeetingSlideWriter.saveIfChanged(image, previous: previous, url: url)
        }
        capture.start(meetingID: "first", folder: folder)
        let pending = Task { await capture.capture(meetingID: "first", image: { image }, inspect: { _ in }) }
        await fulfillment(of: [entered], timeout: 2)
        // This main-actor continuation must run while encoding is blocked.
        await capture.capture(meetingID: "first", image: {
            XCTFail("A timer tick must not queue another image while the writer is busy")
            return image
        }, inspect: { _ in XCTFail("Overlapping OCR") })
        XCTAssertTrue(capture.paths.isEmpty)
        gate.signal()
        await pending.value
        XCTAssertEqual(capture.paths.count, 1)
    }

    @MainActor func testStopDuringWriteCleansUpWithoutChangingNextMeeting() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try image()
        let entered = expectation(description: "Old write started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let capture = MeetingSlideCapture { image, previous, url in
            if url.lastPathComponent.hasPrefix("first-") {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
                // Model an encoder already inside a non-cancellable write.
                try Data("late slide".utf8).write(to: url)
                return [0]
            }
            return try MeetingSlideWriter.saveIfChanged(image, previous: previous, url: url)
        }
        capture.start(meetingID: "first", folder: folder)
        let pending = Task { await capture.capture(meetingID: "first", image: { image }, inspect: { _ in }) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(capture.finish(), [])
        capture.start(meetingID: "second", folder: folder)
        await capture.capture(meetingID: "second", image: { image }, inspect: { _ in })
        let second = folder.appendingPathComponent("second-slide-0.png").path
        XCTAssertEqual(capture.paths, [second])
        gate.signal()
        await pending.value
        XCTAssertEqual(capture.paths, [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("first-slide-0.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))
        XCTAssertEqual(capture.finish(), [second])
    }

    @MainActor func testStopDuringCaptureOrInspectionPreventsLateWrites() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try image()
        for pauseInInspection in [false, true] {
            let entered = expectation(description: "Suspended capture")
            let gate = SlideCaptureGate()
            let capture = MeetingSlideCapture { _, _, _ in
                XCTFail("A stopped capture must not start writing")
                return nil
            }
            capture.start(meetingID: "first", folder: folder)
            let pending = Task {
                await capture.capture(meetingID: "first", image: {
                    if !pauseInInspection { entered.fulfill(); await gate.wait() }
                    return image
                }, inspect: { _ in
                    XCTAssertTrue(pauseInInspection, "A stale screenshot must not enter OCR")
                    entered.fulfill()
                    await gate.wait()
                })
            }
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(capture.finish(), [])
            capture.start(meetingID: "second", folder: folder)
            await gate.open()
            await pending.value
            XCTAssertTrue(capture.paths.isEmpty)
            await capture.capture(meetingID: "first", image: {
                XCTFail("A stale timer must not capture the next meeting")
                return image
            }, inspect: { _ in })
        }
    }

    @MainActor func testFailedWriteCanRetrySameSlideAndProducesValidPNG() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("missing")
        let image = try image(white: 0.5)
        let capture = MeetingSlideCapture()
        capture.start(meetingID: "first", folder: destination)
        await capture.capture(meetingID: "first", image: { image }, inspect: { _ in })
        XCTAssertTrue(capture.paths.isEmpty, "An unsuccessful write must not commit its path or fingerprint")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await capture.capture(meetingID: "first", image: { image }, inspect: { _ in })
        let path = try XCTUnwrap(capture.paths.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    @MainActor func testDeduplicationAndSlideLimitStillAllowParticipantInspection() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let black = try image(), white = try image(white: 1)
        let capture = MeetingSlideCapture()
        capture.start(meetingID: "first", folder: folder)
        var inspections = 0
        for _ in 0..<2 {
            await capture.capture(meetingID: "first", image: { black }, inspect: { _ in inspections += 1 })
        }
        XCTAssertEqual(capture.paths.count, 1)
        for index in 0..<26 {
            await capture.capture(meetingID: "first", image: { index.isMultiple(of: 2) ? white : black },
                                  inspect: { _ in inspections += 1 })
        }
        XCTAssertEqual(inspections, 28)
        XCTAssertEqual(capture.paths.count, 24)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 24)
        XCTAssertEqual(capture.finish().count, 24)
        XCTAssertTrue(capture.paths.isEmpty)
    }
}
