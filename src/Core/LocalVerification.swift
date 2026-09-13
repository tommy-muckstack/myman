import Foundation

/// Debug builds can run isolated verification without touching the real library.
/// Release builds ignore this environment variable entirely.
enum VerificationPaths {
    static var root: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MYMAN_VERIFICATION_ROOT"], path.hasPrefix("/private/tmp/man-verification-") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }
}

#if DEBUG
import AppKit
import SwiftUI
import GRDB

@MainActor final class LocalVerification: NSObject, NSApplicationDelegate {
    let root: URL
    private var bridge: AgentBridge?
    private var actions: AgentActions?
    private var window: NSWindow?
    private var agentSettingsWindow: NSWindow?
    init(root: URL) { self.root = root }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // These fixture-only grants never run in production and only
            // affect the preview app's preferences, not the installed app.
            UserDefaults.standard.set(true, forKey: "agentActionsEnabled")
            for key in AgentConsent.keys.values {
                UserDefaults.standard.set(ProcessInfo.processInfo.environment["MYMAN_VERIFICATION_AGENT_ACCESS"] == "enabled", forKey: key)
            }
            if ProcessInfo.processInfo.environment["MYMAN_VERIFICATION_MULTI_AGENT"] == "enabled" {
                var credentials: [[String: Any]] = []
                for name in ["Capture Agent fixture", "Design fixture", "Read fixture"] {
                    let (agent, token) = try AgentIdentity.shared.issue(name: name, scopes: name == "Read fixture" ? [] : AgentPrincipal.local.scopes)
                    credentials.append(["id": agent.id, "token": token, "name": name])
                }
                let file = root.appendingPathComponent("test-credentials.json")
                try JSONSerialization.data(withJSONObject: credentials).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            MM.Fonts.registerFonts()
            _ = Database.shared
            Brain.bootstrap()
            BrainAgentExportObserver.shared.start()
            CaptureEnrichment.shared.start()
            let themeA = UUID().uuidString, themeB = UUID().uuidString
            let meetingID = UUID().uuidString
            try Database.shared.write { db in
                for (id, title) in [(themeA, "Fixture capture design"), (themeB, "Fixture planning")] {
                    try db.execute(sql: "INSERT INTO captureTheme(id,title,signature,pinned) VALUES(?,?,?,1)", arguments: [id, title, "fixture:" + id])
                }
                try Meeting(id: meetingID, title: "CLI fixture meeting with Alex", startedAt: Date().addingTimeInterval(-600), endedAt: Date().addingTimeInterval(-300), transcript: "Alex: We reviewed the capture design and agreed to make screenshots easier to find. Tommy: I will review the interface tomorrow.", summary: "## Summary\nReviewed capture design and screenshot retrieval.").insert(db)
            }
            let capture = CaptureController(), meetings = MeetingController(), voice = VoiceController()
            let actions = AgentActions(capture: capture, meetings: meetings, voice: voice)
            capture.meetingIDProvider = { meetings.activeCaptureMeetingID }
            let launcher = LauncherPanelController(actions: { [] }, openNote: { NoteDocumentController.shared.open($0) }, openScreenshot: { capture.openInEditor(fileURL: $0) }, saveQueryAsNote: { _ in }, openChat: {})
            actions.openSurface = { surface in
                switch surface { case "settings": SettingsController.shared.show(); case "note": NoteDocumentController.shared.open(Note(body: "Verification draft")); case "briefs": AgentBriefWindow.shared.open(); default: launcher.open() }
            }
            self.actions = actions
            let bridge = AgentBridge { actions.receive($0) }; try bridge.start(); self.bridge = bridge
            let image = NSImage(size: NSSize(width: 900, height: 600))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 600).fill()
            ("My Man verification\nH O n o I l\nE S h m p e" as NSString).draw(at: NSPoint(x: 50, y: 260), withAttributes: [.font: NSFont(name: "Georgia", size: 48)!, .foregroundColor: NSColor.black])
            image.unlockFocus()
            let url = root.appendingPathComponent("fixture.png"); try AgentImages.png(image).write(to: url)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "My Man · isolated verification"; window.isReleasedWhenClosed = false
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)); view.image = image; window.contentView = view
            window.makeKeyAndOrderFront(nil); self.window = window
            if ProcessInfo.processInfo.environment["MYMAN_VERIFICATION_MULTI_AGENT"] == "enabled" {
                let settings = NSWindow(contentRect: NSRect(x: 1100, y: 150, width: 660, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                settings.title = "My Man · agent settings verification"; settings.isReleasedWhenClosed = false
                settings.contentView = NSHostingView(rootView: AgentSettingsView().preferredColorScheme(.dark))
                settings.makeKeyAndOrderFront(nil); agentSettingsWindow = settings
            }
            let ready: [String: Any] = ["root": root.path, "fixture": url.path, "region": [100,100,900,600], "socket": AgentBridge.path, "theme_a": themeA, "theme_b": themeB, "meeting_id": "meeting-" + meetingID]
            if ProcessInfo.processInfo.environment["MYMAN_VERIFICATION_BRIEFS"] == "enabled" {
                let movie = root.appendingPathComponent("brief-source.mov")
                if FileManager.default.fileExists(atPath: movie.path) {
                    let recording = ScreenRecording(id: "brief-fixture", path: movie.path, duration: 4, createdAt: Date(), transcript: "The checkout button should confirm the order once. Show the successful confirmation and check repeated clicks.")
                    try Database.shared.write { try recording.insert($0) }
                }
                AgentBriefWindow.shared.open()
            }
            try JSONSerialization.data(withJSONObject: ready).write(to: root.appendingPathComponent("ready.json"))
        } catch { NSLog("Verification failed: \(error)"); NSApp.terminate(nil) }
    }
}
#endif
