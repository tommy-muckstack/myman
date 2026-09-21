import AppKit
import ImageIO
import GRDB
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

    @MainActor func testManualCaptureTimestampDeletionAndRecordingPersistence() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = Meeting(id: "timestamped", title: "Screen share", startedAt: start, transcript: "Existing words")
        try await db.write { try record.insert($0) }
        let capture = MeetingSlideCapture(removeFile: { try FileManager.default.removeItem(at: $0) })
        let controller = MeetingController(recording: record, titleDatabase: db, slideCapture: capture)
        capture.start(meetingID: record.id, folder: folder, startedAt: start)
        let firstImage = try image(), secondImage = try image(white: 1)
        await capture.capture(meetingID: record.id, now: { start.addingTimeInterval(65) }, image: { firstImage }, inspect: { _ in })
        await capture.capture(meetingID: record.id, force: true, now: { start.addingTimeInterval(75) }, image: { firstImage }, inspect: { _ in })
        XCTAssertEqual(capture.slides.map(\.offset), [65, 75])
        XCTAssertEqual(capture.slides.map(\.automatic), [true, false])
        XCTAssertEqual(capture.slides.first?.timestamp, "1:05")
        let old = capture.paths
        let keptData = try Data(contentsOf: URL(fileURLWithPath: old[1]))
        controller.removeRecordingScreenshot(old[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old[0]))
        await capture.capture(meetingID: record.id, now: { start.addingTimeInterval(125) }, image: { secondImage }, inspect: { _ in })
        XCTAssertEqual(capture.paths.count, 2)
        XCTAssertEqual(capture.paths.first, old[1])
        XCTAssertFalse(capture.paths.last == old[0] || capture.paths.last == old[1])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: old[1])), keptData)
        let fetched = try await db.read { try Meeting.fetchOne($0, key: record.id) }
        let saved = try XCTUnwrap(fetched)
        XCTAssertEqual(saved.slidePaths, capture.paths)
        XCTAssertEqual(saved.capturedSlides.map(\.offset), [75, 125])
        XCTAssertEqual(saved.capturedSlides.first?.capturedAt, start.addingTimeInterval(75))
        XCTAssertEqual(saved.transcript, "Existing words")
        XCTAssertNil(saved.endedAt)
        XCTAssertEqual(capture.finish(), saved.slidePaths)
    }

    @MainActor func testDeletedAutomaticImageIsNotImmediatelyRecapturedAndManualCanOverride() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = MeetingSlideCapture(removeFile: { try FileManager.default.removeItem(at: $0) })
        capture.start(meetingID: "call", folder: folder)
        let image = try image()
        await capture.capture(meetingID: "call", image: { image }, inspect: { _ in })
        try capture.remove(path: XCTUnwrap(capture.paths.first), meetingID: "call")
        await capture.capture(meetingID: "call", image: { image }, inspect: { _ in })
        XCTAssertTrue(capture.paths.isEmpty)
        await capture.capture(meetingID: "call", force: true, image: { image }, inspect: { _ in })
        XCTAssertEqual(capture.paths.count, 1)
        XCTAssertFalse(try XCTUnwrap(capture.slides.first).automatic)
    }

    @MainActor func testPersistenceAndDeleteFailuresDoNotLoseScreenshots() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = MeetingSlideCapture(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        capture.start(meetingID: "call", folder: folder)
        let image = try image()
        capture.onChange = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let failed = await capture.capture(meetingID: "call", force: true, image: { image }, inspect: { _ in })
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(capture.paths.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        var persisted: [MeetingSlide] = []
        capture.onChange = { _, slides in persisted = slides }
        await capture.capture(meetingID: "call", image: { image }, inspect: { _ in })
        let original = capture.slides
        XCTAssertThrowsError(try capture.remove(path: XCTUnwrap(capture.paths.first), meetingID: "call"))
        XCTAssertEqual(capture.slides, original)
        XCTAssertEqual(persisted, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original[0].path))
    }

    func testTimestampMigrationPreservesLegacyScreenshotsWithoutInventingTimes() throws {
        let db = try DatabaseQueue()
        try Database.migrator.migrate(db, upTo: "v18-recording-notes")
        try db.write {
            try $0.execute(sql: "INSERT INTO meeting(id,title,startedAt,transcript,slides) VALUES(?,?,?,?,?)",
                           arguments: ["legacy", "Call", Date(), "", "[\"/tmp/legacy-slide.png\"]"])
        }
        try Database.migrator.migrate(db)
        let record = try XCTUnwrap(db.read { try Meeting.fetchOne($0, key: "legacy") })
        XCTAssertEqual(record.capturedSlides.map(\.path), ["/tmp/legacy-slide.png"])
        XCTAssertNil(record.capturedSlides.first?.offset)
        XCTAssertEqual(record.capturedSlides.first?.timestamp, "Time unavailable")
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
        let second = try XCTUnwrap(capture.paths.first)
        XCTAssertTrue(URL(fileURLWithPath: second).lastPathComponent.hasPrefix("second-slide-"))
        XCTAssertEqual(capture.paths, [second])
        gate.signal()
        await pending.value
        XCTAssertEqual(capture.paths, [second])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("first-slide-") })
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
        let capture = MeetingSlideCapture(automaticLimit: 24)
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
