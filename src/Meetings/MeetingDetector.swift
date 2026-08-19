import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit

// Meeting auto-detection, the Muesli pattern: a CoreAudio listener on the
// default input device's "is running somewhere" flag fires the moment ANY app
// opens the mic. If a known meeting app is running (Zoom, FaceTime, Teams,
// Webex) — or a browser likely hosting a call — we offer to record, or start
// automatically when the setting says so. Event-driven; no polling.

@MainActor
final class MeetingDetector {
    /// Called with the detected app's name when a meeting seems to start.
    var onMeetingDetected: ((String) -> Void)?
    /// The detector must stay quiet while My Man itself uses the mic.
    var isOwnAudioActive: () -> Bool = { false }

    /// Every CoreAudio property read is a blocking IPC round-trip to
    /// coreaudiod, and the daemon is at its slowest during exactly the device
    /// switches that wake our listeners — a 3s main-thread freeze in
    /// `GetDefaultDeviceIDFromServer` is what MYMAN-4 caught. So no HAL call
    /// ever runs on the main actor: listeners are delivered here, the reads
    /// happen here, and only the ANSWERS hop back to the main actor.
    private nonisolated static let halQueue =
        DispatchQueue(label: "com.muckstack.myman.meetingdetector.hal")

    /// Confined to `halQueue`. Never touch it from the main actor.
    private nonisolated(unsafe) var listeningDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastNudge = Date.distantPast
    private var wasRunning = false
    private var suppressedUntil = Date.distantPast
    private var browserRecheckPending = false

    /// Post this when My Man itself sends the user somewhere (opening a
    /// calendar event in the browser, a meeting link, …) — the detector must
    /// never mistake its own navigation for a meeting starting.
    static let suppressNotification = Notification.Name("mm.suppressMeetingDetection")

    static let strongApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        // Mic use in these means a call/huddle in practice; provisional
        // capture makes an occasional voice-clip false positive harmless.
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
    ]
    static let browserBundles = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac",
    ]
    /// Apps that live in the Dock/menu bar all day (Slack, Discord). "It's
    /// running" means nothing for these — they may only fire a nudge when mic
    /// ATTRIBUTION names them, never from the merely-running fallback. That
    /// fallback is how Wispr Flow's dictation kept surfacing a "Slack meeting":
    /// Wispr grabs the mic, attribution comes back empty, Slack happens to be
    /// running.
    static let residentApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
    ]
    /// Whether a mic-owning bundle means a call is live. Strong apps match
    /// exactly; browsers also match their out-of-bundle helpers — Safari's
    /// pages hold the mic from WebKit framework processes that resolve to
    /// `com.apple.WebKit.*`, not `com.apple.Safari`, so an exact-match check
    /// concluded "no browser on the mic" mid-Meet and never saw the hang-up.
    nonisolated static func isCallBundle(_ id: String) -> Bool {
        strongApps.keys.contains(id) || browserBundles.contains(id)
            || id.hasPrefix("com.apple.WebKit")
            || browserBundles.contains { id.hasPrefix($0 + ".") }
    }

    /// Window titles that only exist while a call is on screen. Their
    /// disappearance is the end signal mic attribution can't always give:
    /// Zoom's in-meeting window closes at "End meeting" even though the app
    /// stays running, and a Google Meet tab's title vanishes when it closes.
    nonisolated static func isMeetingWindowTitle(_ title: String) -> Bool {
        if title.contains("Zoom Meeting") { return true }
        // A Meet tab is "Meet – abc-defg-hij" (the code, behind an en dash or
        // hyphen) — never bare "Meet", which would match ordinary pages.
        if title.range(of: #"^Meet\s+[–-]\s"#, options: .regularExpression) != nil { return true }
        if title.contains("Microsoft Teams meeting") { return true }
        return false
    }

    /// Any on-screen (or other-Space) window whose title marks a live call.
    /// Shared by start detection (evidence a merely-running app is really in
    /// a call) and end detection (its disappearance is the hang-up).
    nonisolated static func meetingWindowPresent() async -> Bool {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return false }
        return content.windows.contains { window in
            guard let title = window.title, !title.isEmpty else { return false }
            return isMeetingWindowTitle(title)
        }
    }

    /// Known dictation utilities — them holding the mic is NEVER a meeting,
    /// even if attribution also lists other apps.
    static let dictationApps: Set<String> = [
        "com.electron.wispr-flow",        // Wispr Flow
        "com.superduper.superwhisper",    // superwhisper
        "com.goodsnooze.macwhisper",      // MacWhisper
        "com.muckstack.mumbls",           // Mumbls
    ]

    func start() {
        installDefaultDeviceListener()
        refreshRunningListener()
        NotificationCenter.default.addObserver(
            forName: Self.suppressNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suppressedUntil = Date().addingTimeInterval(15)
            }
        }
    }

    // MARK: CoreAudio listeners

    private nonisolated func installDefaultDeviceListener() {
        Self.halQueue.async {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, Self.halQueue
            ) { [weak self] _, _ in
                self?.adoptDefaultInputDevice()
            }
        }
    }

    /// Point the "is running somewhere" listener at whatever input device is
    /// current. Safe to call from anywhere — the work lands on `halQueue`.
    private nonisolated func refreshRunningListener() {
        Self.halQueue.async { [weak self] in self?.adoptDefaultInputDevice() }
    }

    /// Runs on `halQueue`.
    private nonisolated func adoptDefaultInputDevice() {
        dispatchPrecondition(condition: .onQueue(Self.halQueue))
        let deviceID = Self.defaultInputDevice()
        guard deviceID != kAudioObjectUnknown, deviceID != listeningDeviceID else { return }
        listeningDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &address, Self.halQueue) { [weak self] _, _ in
            guard let self else { return }
            // Read the flag here, on the HAL queue — the main actor gets a Bool.
            let running = self.micIsRunning()
            Task { @MainActor in self.micStateChanged(running: running) }
        }
    }

    private nonisolated static func defaultInputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// Runs on `halQueue`.
    private nonisolated func micIsRunning() -> Bool {
        dispatchPrecondition(condition: .onQueue(Self.halQueue))
        guard listeningDeviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(listeningDeviceID, &address, 0, nil, &size, &running)
        return running != 0
    }

    // MARK: Decision

    private func micStateChanged(running: Bool) {
        defer { wasRunning = running }
        // Only rising edges: mic just turned ON.
        guard running, !wasRunning else { return }
        guard !isOwnAudioActive() else { return }
        guard Date() > suppressedUntil else { return }
        guard Date().timeIntervalSince(lastNudge) > 300 else { return }

        // Attribute the mic to its owner when the OS can tell us. Walking the
        // process objects is another pile of blocking HAL reads, so it happens
        // on the HAL queue and comes back as a plain list of bundle IDs.
        Self.halQueue.async { [weak self] in
            let allOwners = AudioCapture.processesUsingMic()
            Task { @MainActor in self?.evaluate(allOwners: allOwners) }
        }
    }

    /// The nudge decision, given who the OS says is holding the mic. A
    /// dictation utility (Wispr, etc.) is NOT a meeting — bail unless the
    /// owner is a meeting app or a browser.
    private func evaluate(allOwners: [String]) {
        let owners = allOwners.filter { $0 != Bundle.main.bundleIdentifier }
        // A dictation tool on the mic is dictation, full stop.
        guard !owners.contains(where: { Self.dictationApps.contains($0) }) else { return }
        if !owners.isEmpty {
            if let strong = owners.first(where: { Self.strongApps.keys.contains($0) }) {
                lastNudge = Date()
                onMeetingDetected?(Self.strongApps[strong] ?? "a meeting app")
            } else if owners.contains(where: { Self.browserBundles.contains($0) }) {
                scheduleBrowserRecheck()
            }
            return
        }
        // Attribution worked and the ONLY mic user is us (dictation, screen
        // recording spin-up) — that is never a meeting. Without this, the
        // fallback heuristic sees a merely-RUNNING Zoom and fires.
        if !allOwners.isEmpty { return }

        // No attribution available — old heuristics. Resident apps (Slack,
        // Discord) are excluded here — always-running is not evidence of a
        // call. And "Zoom is running" alone is not evidence either: Zoom and
        // Teams idle in the dock all day, so ANY app touching the mic kept
        // firing a "Zoom meeting" nudge. Merely-running only counts when the
        // app is frontmost or an on-screen window says a call is live.
        let apps = NSWorkspace.shared.runningApplications
        if let meeting = apps.first(where: {
            let id = $0.bundleIdentifier ?? ""
            return Self.strongApps.keys.contains(id) && !Self.residentApps.contains(id)
        }) {
            let bundle = meeting.bundleIdentifier ?? ""
            let name = Self.strongApps[bundle] ?? "a meeting app"
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                lastNudge = Date()
                onMeetingDetected?(name)
                return
            }
            Task { @MainActor [weak self] in
                guard await Self.meetingWindowPresent() else { return }
                guard let self, !self.isOwnAudioActive(),
                      Date() > self.suppressedUntil else { return }
                self.lastNudge = Date()
                self.onMeetingDetected?(name)
            }
            return
        }
        // Weaker: the FRONTMOST app is a browser using the mic.
        if let front = NSWorkspace.shared.frontmostApplication,
           Self.browserBundles.contains(front.bundleIdentifier ?? "") {
            scheduleBrowserRecheck()
        }
    }

    /// A blip isn't a meeting — believe the browser only if the mic is STILL
    /// live 4s later (and, when attribution works, still owned by a browser).
    private func scheduleBrowserRecheck() {
        guard !browserRecheckPending else { return }
        browserRecheckPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            self.browserRecheckPending = false
            guard !self.isOwnAudioActive(), Date() > self.suppressedUntil else { return }
            let snapshot = await self.micSnapshot()
            guard snapshot.running else { return }
            let owners = snapshot.owners.filter { $0 != Bundle.main.bundleIdentifier }
            if !owners.isEmpty {
                guard owners.contains(where: { Self.browserBundles.contains($0) }) else { return }
            } else {
                guard let front = NSWorkspace.shared.frontmostApplication,
                      Self.browserBundles.contains(front.bundleIdentifier ?? "") else { return }
            }
            self.lastNudge = Date()
            self.onMeetingDetected?("your browser")
        }
    }

    /// Both blocking HAL reads the recheck needs, taken together off the main
    /// actor. Owners are only worth walking when the mic is actually live.
    private nonisolated func micSnapshot() async -> (running: Bool, owners: [String]) {
        await withCheckedContinuation { continuation in
            Self.halQueue.async {
                let running = self.micIsRunning()
                continuation.resume(
                    returning: (running, running ? AudioCapture.processesUsingMic() : []))
            }
        }
    }
}
