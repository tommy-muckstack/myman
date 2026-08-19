import AppKit
import Carbon
import Sparkle
import SwiftUI

// My Man — the Mac sidekick. Menu-bar only; ⌥Space summons the launcher and
// every surface is a floating panel. No Dock icon, no main window.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var statusItem: NSStatusItem?
    private let launchedAt = Date()
    private let notesPanel = NotesPanelController()
    private let notesStore = NotesStore()
    private let capture = CaptureController()
    private let voice = VoiceController()
    private let meetings = MeetingController()
    private let calendar = CalendarWatcher()
    private let meetingDetector = MeetingDetector()
    private var launcher: LauncherPanelController!
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar apps get NO working ⌘C/⌘V/⌘A unless a main menu exists to
        // route the key equivalents — invisible, but load-bearing.
        installMainMenu()
        CrashReporting.setup()
        MM.Fonts.registerFonts()
        SettingsStore.shared.theme?.apply()
        Analytics.setup()
        _ = Database.shared
        Brain.bootstrap()
        Brain.backfillScreenshots()
        // Crashed sessions can leave phantom aggregate audio devices behind.
        SystemAudioTap.cleanupStaleDevices()
        MeetingController.cleanupOldRecordings()

        // Sparkle needs a real .app bundle; skip in bare-binary dev runs.
        if Bundle.main.bundleURL.pathExtension == "app" {
            updater = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            // Check immediately at every launch — with SUAutomaticallyUpdate
            // (release builds), new versions download + install silently.
            updater?.updater.checkForUpdatesInBackground()
        }

        launcher = LauncherPanelController(
            actions: { [weak self] in self?.launcherActions() ?? [] },
            openNote: { note in NoteDocumentController.shared.open(note) },
            openScreenshot: { [weak self] url in self?.capture.openInEditor(fileURL: url) },
            saveQueryAsNote: { [weak self] text in
                _ = self?.notesStore.save(body: text, source: "search_empty_state")
            },
            openChat: { BrainChatController.shared.show() }
        )
        setUpStatusItem()
        setUpHotkeys()
        if let notice = Database.startupRecoveryNotice {
            Toast.show(notice, systemImage: "externaldrive.badge.exclamationmark")
        }

        // 45s before a linked calendar event: capture starts provisionally and
        // the Use My Man card appears (Join & Start when there's a link).
        // With auto-record on, the take commits itself at the event's start.
        calendar.onPreMeeting = { [weak self] title, joinURL, startsAt in
            guard let self,
                  !ScreenRecorder.shared.isBusy,
                  case .idle = self.meetings.phase else { return }
            self.meetings.startProvisional(title: title, joinURL: joinURL)
            if SettingsStore.shared.autoRecordMeetings {
                let delay = max(0, startsAt.timeIntervalSinceNow)
                // Commit only once the take shows an actual call (call app on
                // the mic, meeting window, remote audio) — blind commit at the
                // event's start time turned every unjoined invite into a
                // phantom recorded "meeting" named after the calendar. Checks
                // every 30s for 10 minutes to catch late joins; if the user
                // never joins, the provisional silence watchdog discards it.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    for _ in 0 ..< 20 {
                        guard let self, self.meetings.isProvisional else { return }
                        if !ScreenRecorder.shared.isBusy, self.meetings.hasCallEvidence {
                            self.meetings.keepProvisional()
                            return
                        }
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
        calendar.start()

        // App-based meeting detection: Zoom/FaceTime/Teams/browser opens the
        // mic → offer to record (or just record, per the setting).
        meetingDetector.isOwnAudioActive = { [weak self] in
            guard let self else { return true }
            if case .idle = self.voice.phase {} else { return true }
            if case .idle = self.meetings.phase {} else { return true }
            // Selection, permission prompts, capture spin-up, and a live
            // recording are one exclusive screen-recording session. A meeting
            // detector event in any of those stages must not start a second
            // recorder from My Man's own microphone.
            if ScreenRecorder.shared.isBusy { return true }
            return false
        }
        meetingDetector.onMeetingDetected = { [weak self] appName in
            guard let self,
                  !ScreenRecorder.shared.isBusy,
                  case .idle = self.meetings.phase else { return }
            Analytics.track("meeting_detected", ["app": appName])
            if SettingsStore.shared.autoRecordMeetings {
                self.meetings.toggle()
                Toast.show("Recording your \(appName) meeting", systemImage: "record.circle")
            } else {
                // Quill pattern: capture starts immediately so nothing is
                // missed, but only "Start Meeting" on the pill makes it real.
                // The pill IS the notification — no toast on top of it.
                self.meetings.startProvisional()
            }
        }
        meetingDetector.start()

        // Warm the Qwen3 accuracy engine off the critical path — dictation
        // uses Parakeet until it's genuinely ready.
        TranscriptionService.shared.warmQwen3()
        voice.warmUp()
        Task.detached(priority: .background) { await Diarization.shared.warm() }
        meetings.recoverOrphanedTranscriptions()

        WelcomeController.shared.showIfFirstLaunch()

        // Settings' update button — reachable even when the menu-bar icon
        // is hidden by a crowded menu bar.
        NotificationCenter.default.addObserver(
            forName: .mmCheckForUpdates, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updater?.checkForUpdates(nil) }
        }
    }

    /// Double-clicking the app in Finder/Launchpad while it's running lands
    /// here — the only discoverable "open" for users whose menu bar hides us.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // open(), never toggle(): a Dock click delivers didBecomeActive AND
        // reopen back-to-back — toggle turned that into open-then-close.
        launcher.open()
        return false
    }

    /// Small, local automation surface for the bundled `myman` command-line
    /// helper. URL commands intentionally invoke the exact same controllers
    /// as a launcher tile or hotkey; they never bypass permissions or capture
    /// confirmation UI.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "myman" {
            performAutomationCommand(url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())
        }
    }

    private func performAutomationCommand(_ command: String) {
        switch command {
        case "open", "launcher": launcher.open()
        case "screenshot": capture.beginRegionCapture()
        case "note": notesPanel.show()
        case "dictation": voice.toggle()
        case "meeting": meetings.toggle()
        case "cancel-meeting": meetings.discardRecording()
        case "record": ScreenRecorder.shared.toggle()
        case "settings": SettingsController.shared.show()
        default:
            NSLog("My Man: ignored unknown automation command: \(command)")
        }
    }

    /// ⌘Tab / Dock activation with nothing on screen should land somewhere.
    /// Panels are non-activating, so this only fires on deliberate switches —
    /// plus once at launch, which the grace period swallows.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(launchedAt) > 3,
              NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }) == nil
        else { return }
        launcher.open()
    }

    @objc private func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }

    /// A recorder must NEVER be restarted by its own updater. Update checks
    /// (and therefore silent installs) wait until nothing is being captured.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let busy = MainActor.assumeIsolated {
            var capturing = false
            if case .idle = self.voice.phase {} else { capturing = true }
            if case .idle = self.meetings.phase {} else { capturing = true }
            // A restart mid-transcription is recoverable at next launch, but
            // never worth it — the background queue counts as busy too.
            if self.meetings.isTranscribing { capturing = true }
            if ScreenRecorder.shared.isRecording { capturing = true }
            return capturing
        }
        if busy {
            throw NSError(domain: "com.muckstack.myman", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recording in progress — update deferred",
            ])
        }
    }

    private func launcherActions() -> [LauncherAction] {
        [
            LauncherAction(id: "screenshot", icon: .screenshot, title: "Take Screenshot",
                           hint: SettingsStore.shared.hint(for: .screenshot), enabled: true) { [weak self] in
                // Let the launcher panel fully leave the screen before freezing it.
                Analytics.track("launcher_action_used", ["action": "screenshot"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.capture.beginRegionCapture()
                }
            },
            LauncherAction(id: "note", icon: .note, title: "New Note",
                           hint: SettingsStore.shared.hint(for: .note), enabled: true) { [weak self] in
                Analytics.track("launcher_action_used", ["action": "note"])
                self?.notesPanel.show()
            },
            LauncherAction(id: "voice", icon: .voice, title: "Voice Dictation",
                           hint: SettingsStore.shared.hint(for: .voice), enabled: true) { [weak self] in
                Analytics.track("launcher_action_used", ["action": "voice"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.voice.toggle()
                }
            },
            LauncherAction(id: "meeting", icon: .calendar,
                           title: meetingActionTitle, hint: SettingsStore.shared.hint(for: .meeting), enabled: true,
                           recording: isMeetingRecording) { [weak self] in
                Analytics.track("launcher_action_used", ["action": "meeting"])
                self?.meetings.toggle()
            },
        ]
        + (ScreenRecorder.isSupported ? [
            LauncherAction(id: "record", icon: .recordScreen,
                           title: ScreenRecorder.shared.isRecording ? "Stop Recording" : "Record Screen",
                           hint: "", enabled: true,
                           recording: ScreenRecorder.shared.isRecording) {
                Analytics.track("launcher_action_used", ["action": "record"])
                // Let the launcher leave the screen before capture starts.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    ScreenRecorder.shared.toggle()
                }
            },
        ] : [])
    }

    private var meetingActionTitle: String {
        if case .recording = meetings.phase { return "Stop Meeting" }
        return "Record Meeting"
    }

    private var isMeetingRecording: Bool {
        if case .recording = meetings.phase { return true }
        return false
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu — shown in the menu bar whenever My Man is the active app.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About My Man",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        app.addItem(update)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide My Man", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit My Man", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "person.fill.checkmark",
                accessibilityDescription: "My Man"
            )
        }

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open My Man", action: #selector(showLauncher), keyEquivalent: " ")
        open.keyEquivalentModifierMask = [.option]
        open.target = self
        menu.addItem(open)
        let shot = NSMenuItem(title: "Take Screenshot", action: #selector(captureRegion), keyEquivalent: "2")
        shot.keyEquivalentModifierMask = [.option, .shift]
        shot.target = self
        menu.addItem(shot)
        let note = NSMenuItem(title: "New Note", action: #selector(showNotes), keyEquivalent: "n")
        note.keyEquivalentModifierMask = [.option, .shift]
        note.target = self
        menu.addItem(note)
        let dictate = NSMenuItem(title: "Voice Dictation", action: #selector(toggleVoice), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        let meeting = NSMenuItem(title: "Record Meeting", action: #selector(toggleMeeting), keyEquivalent: "m")
        meeting.keyEquivalentModifierMask = [.option, .shift]
        meeting.target = self
        menu.addItem(meeting)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if let updater {
            let update = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
            update.target = updater
            menu.addItem(update)
        }
        menu.addItem(withTitle: "Quit My Man", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private var hotkeyIDs: [UInt32] = []
    private let modifierMonitor = ModifierHotkeyMonitor()

    private func setUpHotkeys() {
        SettingsStore.shared.onHotkeysChanged = { [weak self] in
            self?.registerAllHotkeys()
        }
        registerAllHotkeys()
    }

    /// (Re)register every hotkey from SettingsStore — called live on remap.
    private func registerAllHotkeys() {
        hotkeyIDs.forEach { HotkeyCenter.shared.unregister($0) }
        hotkeyIDs = []
        let store = SettingsStore.shared

        register(store.combo(for: .launcher), "launcher") { $0.launcher.toggle() }
        register(store.combo(for: .screenshot), "screenshot") { $0.capture.beginRegionCapture() }
        register(store.combo(for: .note), "note") { $0.notesPanel.show() }
        register(store.combo(for: .meeting), "meeting") { $0.meetings.toggle() }
        if ScreenRecorder.isSupported {
            // Same toggle as the launcher tile: starts region selection, or
            // stops an in-flight recording.
            register(store.combo(for: .record), "record") { _ in ScreenRecorder.shared.toggle() }
        }

        // Voice: hold to talk, release to paste. Bare-modifier combos (hold
        // Right ⌥ — the default) go through the NSEvent monitor; key combos go
        // through Carbon with press/release.
        modifierMonitor.stop()
        let voiceCombo = store.combo(for: .voice)
        if voiceCombo.isModifierOnly {
            modifierMonitor.onDown = { [weak self] in self?.voice.hotkeyDown() }
            modifierMonitor.onUp = { [weak self] in self?.voice.modifierHotkeyUp() }
            modifierMonitor.onAbort = { [weak self] in self?.voice.modifierHotkeyAborted() }
            modifierMonitor.start(keyCode: voiceCombo.keyCode)
        } else {
            let voiceResult = HotkeyCenter.shared.register(
                .init(keyCode: voiceCombo.keyCode, modifiers: voiceCombo.carbonModifiers),
                handler: { [weak self] in
                    MainActor.assumeIsolated { self?.voice.hotkeyDown() }
                },
                onRelease: { [weak self] in
                    MainActor.assumeIsolated { self?.voice.hotkeyUp() }
                }
            )
            if case .success(let id) = voiceResult {
                hotkeyIDs.append(id)
            } else {
                NSLog("My Man: voice hotkey registration failed (combo likely taken)")
            }
        }
    }

    private func register(_ combo: HotkeyCombo, _ label: String,
                          _ action: @escaping (AppDelegate) -> Void) {
        let result = HotkeyCenter.shared.register(
            .init(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
        ) { [weak self] in
            // Carbon dispatches hotkey events on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        if case .success(let id) = result {
            hotkeyIDs.append(id)
        } else {
            NSLog("My Man: \(label) hotkey registration failed (combo likely taken)")
        }
    }

    @objc private func showLauncher() { launcher.toggle() }
    @objc private func captureRegion() { capture.beginRegionCapture() }
    @objc private func showNotes() { notesPanel.show() }
    @objc private func toggleVoice() { voice.toggle() }
    @objc private func toggleMeeting() { meetings.toggle() }
    @objc private func showSettings() { SettingsController.shared.show() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Regular app: Dock icon + ⌘Tab. Users expect to SEE the app (Dock click
    // opens the launcher); panels stay non-activating so it never steals focus.
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
