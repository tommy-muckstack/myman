import AppKit
import SwiftUI
import XCTest
@testable import MyMan

final class CompetitiveWorkflowUITests: XCTestCase {
    @MainActor func testSyntheticWorkflowScreenshots() async throws {
        guard let root = VerificationPaths.root,
              ProcessInfo.processInfo.environment["MYMAN_VERIFY_COMPETITIVE_UI"] == "enabled" else {
            throw XCTSkip("Opt-in screenshots with an isolated synthetic library")
        }
        _ = NSApplication.shared
        MM.Fonts.registerFonts()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await render(BrainChatView(initialScope: .init(), onDismiss: {}), size: NSSize(width: 620, height: 720), name: "brain-chat", root: root)
        try await render(RecordingSettingsView().padding(MM.Layout.paddingLarge), size: NSSize(width: 420, height: 490), name: "recording-settings", root: root)
        try await render(DictationPersonalizationSettings().padding(MM.Layout.paddingLarge).background(MM.Colors.background), size: NSSize(width: 620, height: 480), name: "dictation-profile", root: root)
        let movie = root.appendingPathComponent("Synthetic demo.mp4")
        try Data("synthetic placeholder; no microphone or screen captured".utf8).write(to: movie)
        let captions: [RecordingTranscript.Segment] = [.init(start: 0, end: 2, text: "A synthetic product walkthrough."), .init(start: 3, end: 5, text: "A reviewable next step.")]
        try RecordingTranscript.save(captions, for: movie)
        try await render(RecordingTimelineControls(movie: movie, duration: 10,
            project: .constant(RecordingProject(captions: captions)), trimStart: 0, trimEnd: 10, seek: { _ in })
            .padding(MM.Layout.paddingLarge).background(MM.Colors.background), size: NSSize(width: 760, height: 650), name: "recording-timeline", root: root)
    }
    @MainActor private func render<V: View>(_ view: V, size: NSSize, name: String, root: URL) async throws {
        let panel = FloatingPanel(content: view.frame(width: size.width, height: size.height, alignment: .topLeading).background(MM.Colors.background), fixedSize: true)
        panel.isReleasedWhenClosed = false; panel.dismissesOnResign = false
        panel.setContentSize(size); panel.present()
        defer { panel.contentView = nil; panel.close() }
        try await Task.sleep(for: .milliseconds(400))
        let host = try XCTUnwrap(panel.contentView)
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }
}
