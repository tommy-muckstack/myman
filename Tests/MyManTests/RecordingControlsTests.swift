import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import MyMan

final class RecordingControlsTests: XCTestCase {
    func testSavedDefaultsSurviveNewRecordingSnapshots() {
        let suite = "myman.recording-settings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = RecordingPreferences(defaults: defaults)
        XCTAssertEqual(initial.source, .region)
        XCTAssertTrue(initial.microphone)
        XCTAssertTrue(initial.systemAudio)
        XCTAssertTrue(initial.webcam)
        defaults.set("camera", forKey: "recordingSource")
        defaults.set(false, forKey: "mm.screenRecordingMicrophone")
        defaults.set(false, forKey: "mm.screenRecordingSystemAudio")
        defaults.set(false, forKey: "mm.webcamBubble")
        for _ in 0..<2 {
            let next = RecordingPreferences(defaults: defaults)
            XCTAssertEqual(next.source, .camera)
            XCTAssertFalse(next.microphone)
            XCTAssertFalse(next.systemAudio)
            XCTAssertFalse(next.webcam)
        }
        defaults.set("unknown", forKey: "recordingSource")
        XCTAssertEqual(RecordingPreferences(defaults: defaults).source, .region)
    }

    func testControlsPreferBelowAndFallBackAboveOrAlongsideSelection() {
        let size = CGSize(width: 360, height: 48)
        let screen = CGRect(x: 0, y: 30, width: 1440, height: 850)
        for region in [CGRect(x: 300, y: 250, width: 600, height: 400),
                       CGRect(x: 300, y: 40, width: 600, height: 400),
                       CGRect(x: 30, y: 30, width: 600, height: 850)] {
            let frame = RecordingControlPlacement.frame(size: size, selection: region, screens: [screen])
            XCTAssertTrue(screen.contains(frame))
            XCTAssertFalse(frame.intersects(region))
            if region.minY == 250 { XCTAssertLessThan(frame.maxY, region.minY) }
            if region.minY == 40 { XCTAssertGreaterThan(frame.minY, region.maxY) }
        }
    }

    func testControlsStayOnSelectedDisplayAndHandleFullScreen() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let size = CGSize(width: 360, height: 48)
        let region = CGRect(x: -1800, y: 300, width: 600, height: 400)
        let frame = RecordingControlPlacement.frame(size: size, selection: region, screens: [right, left])
        XCTAssertTrue(left.contains(frame))
        XCTAssertLessThan(frame.maxY, region.minY)
        let full = RecordingControlPlacement.frame(size: size, selection: left, screens: [right, left])
        XCTAssertTrue(left.contains(full))
        XCTAssertEqual(full.minY, left.minY)
    }

    @MainActor func testStopRespondsInNonKeyPanelAndShowsSaving() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MYMAN_VERIFY_RECORDING_CONTROLS"] else {
            throw XCTSkip("Opt-in native mouse verification with synthetic controls")
        }
        _ = NSApplication.shared; MM.Fonts.registerFonts()
        let root = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = RecordingControlFixture()
        let panel = FloatingPanel(content: RecordingControlFixtureView(fixture: fixture).preferredColorScheme(.dark),
                                  becomesKey: false, fixedSize: true, acceptsFirstClick: true)
        panel.isReleasedWhenClosed = false; panel.dismissesOnResign = false
        panel.isMovableByWindowBackground = false
        panel.setFrame(CGRect(origin: CGPoint(x: 200, y: 200), size: RecordingControlPlacement.size), display: false)
        panel.orderFrontRegardless()
        defer { panel.contentView = nil; panel.close() }
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(panel.contentView)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertFalse(host.needsPanelToBecomeKey)
        try save(host, to: root.appendingPathComponent("recording-controls.png"))
        // Click the visible Stop pill in the rendered fixture, through the
        // non-key window's event path rather than invoking its callback.
        let point = NSPoint(x: host.bounds.width * 0.72, y: host.bounds.midY)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertTrue(fixture.stopping)
        try save(host, to: root.appendingPathComponent("recording-saving.png"))

        let suite = "myman.recording-render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NSHostingView(rootView: SettingsPanelView(onDismiss: {}).defaultAppStorage(defaults)
            .preferredColorScheme(.dark))
        settings.sizingOptions = []
        let settingsWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 643), styleMask: [.borderless], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = settings
        defer { settingsWindow.contentView = nil; settingsWindow.close() }
        try await Task.sleep(for: .milliseconds(200))
        settings.layoutSubtreeIfNeeded()
        try save(settings, to: root.appendingPathComponent("recording-settings.png"))

        let screen = CGRect(x: 0, y: 0, width: 720, height: 480)
        let region = CGRect(x: 40, y: 100, width: 640, height: 320)
        let controls = RecordingControlPlacement.frame(size: RecordingControlPlacement.size, selection: region, screens: [screen])
        let preview = NSHostingView(rootView: ZStack {
            MM.Colors.background
            RoundedRectangle(cornerRadius: MM.Layout.radius).fill(MM.Colors.surface)
                .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).stroke(MM.Colors.danger, lineWidth: 2))
                .overlay(Text("Selected recording area").font(MM.Fonts.title).foregroundStyle(MM.Colors.textPrimary))
                .frame(width: region.width, height: region.height)
                .position(x: region.midX, y: screen.height - region.midY)
            RecordingControlBar(elapsed: "0:08", webcamOn: true, onCamera: {}, onMicrophone: {}, onStop: {}, onRestart: {})
                .position(x: controls.midX, y: screen.height - controls.midY)
        }.preferredColorScheme(.dark))
        preview.sizingOptions = []
        let previewWindow = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false; previewWindow.contentView = preview
        defer { previewWindow.contentView = nil; previewWindow.close() }
        preview.layoutSubtreeIfNeeded()
        try save(preview, to: root.appendingPathComponent("recording-placement.png"))
    }

    @MainActor func testStopFinalizesOnlySyntheticWindowCapture() async throws {
        guard #available(macOS 15.0, *), VerificationPaths.root != nil,
              ProcessInfo.processInfo.environment["MYMAN_VERIFY_RECORDING_CONTROLS"] != nil,
              CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Opt-in real capture requires existing screen permission and an isolated library")
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 480, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "My Man synthetic recording check"
        window.contentView = NSHostingView(rootView: Text("Synthetic recording fixture")
            .font(MM.Fonts.title).frame(maxWidth: .infinity, maxHeight: .infinity).background(MM.Colors.background))
        window.orderFrontRegardless()
        let recorder = ScreenRecorder.shared
        defer { if recorder.isRecording { recorder.stop() }; window.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        try await recorder.startForAgent(region: nil, windowID: String(target.windowID), maximumDuration: 30,
                                         microphone: false, systemAudio: false)
        let startupDeadline = Date().addingTimeInterval(20)
        while !recorder.isRecording, recorder.isBusy, Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(recorder.isRecording, "Synthetic window capture must start")
        guard recorder.isRecording else { return }
        try await Task.sleep(for: .seconds(1))
        recorder.stop()
        XCTAssertTrue(recorder.isStopping)
        XCTAssertFalse(recorder.isRecording)
        let saveDeadline = Date().addingTimeInterval(30)
        while recorder.isBusy, Date() < saveDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(recorder.isBusy, "Stop must finish saving and release capture")
        XCTAssertFalse(recorder.isStopping)
        let saved = try XCTUnwrap(recorder.lastSavedRecord)
        let asset = AVURLAsset(url: URL(fileURLWithPath: saved.path))
        let videos = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videos.isEmpty)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThan(duration, 10, "Capture must end after Stop, not run until its deadline")
    }

    @MainActor private func save(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor private final class RecordingControlFixture: ObservableObject {
    @Published var stopping = false
    var stops = 0
}

private struct RecordingControlFixtureView: View {
    @ObservedObject var fixture: RecordingControlFixture
    var body: some View {
        RecordingControlBar(elapsed: "0:08", isStopping: fixture.stopping, webcamOn: true,
                            onCamera: {}, onMicrophone: {}, onStop: {
            fixture.stops += 1; fixture.stopping = true
        }, onRestart: {})
    }
}
