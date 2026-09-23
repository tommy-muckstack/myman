import AppKit
import Carbon
import SwiftUI

// Settings: hotkeys and folders, reachable from the ⌥Space HUD. Deliberately
// tiny — a hotkey row per action, a folder row, nothing else. Changes apply
// immediately: hotkeys re-register live and the launcher's hint labels read
// from here, so a remap shows up in the 2s hint flash instantly.

struct HotkeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Bare-modifier hotkey (hold Right ⌥) — registered via NSEvent monitors,
    /// not Carbon.
    var isModifierOnly: Bool {
        carbonModifiers == 0 && ModifierHotkeyMonitor.isModifierKeyCode(keyCode)
    }

    var displayString: String {
        if isModifierOnly { return "hold " + Self.keyName(keyCode) }
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(keyCode)
    }

    /// Keys allowed as a hotkey with NO modifier. A bare hotkey is taken from
    /// every app on the machine, so the keys you type prose with — letters,
    /// digits, Space, Return, Delete, Escape, the arrows — are deliberately
    /// absent: binding one would swallow it system-wide. ` and ⇥ are in
    /// because a launcher key is the one thing people reach for bare.
    static let bareCapableKeyCodes: Set<UInt32> = {
        var codes: Set<UInt32> = [
            UInt32(kVK_Tab), UInt32(kVK_ANSI_Grave),
            UInt32(kVK_ANSI_Minus), UInt32(kVK_ANSI_Equal),
            UInt32(kVK_ANSI_LeftBracket), UInt32(kVK_ANSI_RightBracket),
            UInt32(kVK_ANSI_Backslash), UInt32(kVK_ANSI_Semicolon),
            UInt32(kVK_ANSI_Quote), UInt32(kVK_ANSI_Comma),
            UInt32(kVK_ANSI_Period), UInt32(kVK_ANSI_Slash),
            UInt32(kVK_Home), UInt32(kVK_End),
            UInt32(kVK_PageUp), UInt32(kVK_PageDown),
        ]
        codes.formUnion(functionKeyCodes.keys)
        return codes
    }()

    static func allowsBareKey(_ code: UInt32) -> Bool {
        bareCapableKeyCodes.contains(code) || ModifierHotkeyMonitor.isModifierKeyCode(code)
    }

    private static let functionKeyCodes: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    static func keyName(_ code: UInt32) -> String {
        var names: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "⏎",
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Command): "L⌘", UInt32(kVK_RightCommand): "R⌘",
            UInt32(kVK_Option): "L⌥", UInt32(kVK_RightOption): "R⌥",
            UInt32(kVK_Shift): "L⇧", UInt32(kVK_RightShift): "R⇧",
            UInt32(kVK_Control): "⌃",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Minus): "-",
            UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/",
        ]
        names.merge(functionKeyCodes) { current, _ in current }
        return names[code] ?? "key\(code)"
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case launcher, screenshot, note, voice, meeting, record
    var id: String { rawValue }

    var label: String {
        switch self {
        case .launcher: return "Open My Man"
        case .screenshot: return "Take Screenshot"
        case .note: return "New Note"
        case .voice: return "Voice Dictation"
        case .meeting: return "Record Meeting"
        case .record: return "Record Screen"
        }
    }

    var defaultCombo: HotkeyCombo {
        switch self {
        case .launcher: return HotkeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
        // ⌘⇧S — S for screenshot. Trade-off (accepted): globally shadows
        // in-app "Save As" shortcuts while My Man runs.
        case .screenshot: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .note: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(optionKey | shiftKey))
        // Hold Right ⌥ to dictate, release to paste — the Wispr gesture.
        // Right ⌥ on purpose, not ⌘: ⌘ is half of every shortcut on the
        // machine, and chords like ⌘⇧S kept arming dictation before the
        // second modifier arrived. Right ⌥ is on no common shortcut.
        case .voice: return HotkeyCombo(keyCode: UInt32(kVK_RightOption), carbonModifiers: 0)
        case .meeting: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(optionKey | shiftKey))
        case .record: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | shiftKey))
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Forcing NSApp.appearance flips every window at once — all MM color
    /// tokens are appearance-dynamic NSColors.
    @MainActor func apply() {
        NSApp.appearance = NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }

    /// What the system looks like right now — the implicit default before
    /// the user ever picks a side.
    @MainActor static var matchingSystem: AppTheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark : .light
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Fired after any hotkey change — AppDelegate re-registers everything.
    var onHotkeysChanged: (() -> Void)?

    @Published private(set) var hotkeys: [String: HotkeyCombo]
    @Published var screenshotFolderPath: String {
        didSet { UserDefaults.standard.set(screenshotFolderPath, forKey: "screenshotFolder") }
    }
    @Published var autoRecordMeetings: Bool {
        didSet { UserDefaults.standard.set(autoRecordMeetings, forKey: "autoRecordMeetings") }
    }
    /// Cursor trail + click ripple drawn into screen recordings.
    @Published var cursorEffects: Bool {
        didSet { UserDefaults.standard.set(cursorEffects, forKey: "cursorEffects") }
    }
    /// Record without the system cursor and log its path instead, so
    /// Polish can draw a smoothed, resized one. Off by default: a raw
    /// recording that is never polished should still show the cursor.
    @Published var recordCursorSeparately: Bool {
        didSet { UserDefaults.standard.set(recordCursorSeparately, forKey: "recordCursorSeparately") }
    }
    @Published var dictationTone: DictationTone {
        didSet { UserDefaults.standard.set(dictationTone.rawValue, forKey: "dictationTone") }
    }
    /// The noise a screenshot makes when it lands.
    @Published var captureSound: CaptureSound {
        didSet { UserDefaults.standard.set(captureSound.rawValue, forKey: "captureSound") }
    }
    /// Noise suppression + AGC on the dictation mic. OFF by default: the only
    /// way macOS offers it is a voice-processing unit, and an active one puts
    /// the whole machine in voice-chat mode — every other app's audio ducks
    /// while you dictate. Takes are peak-normalized at stop either way, which
    /// is what carries a whisper; this only adds suppression on top.
    @Published var enhanceMicrophone: Bool {
        didSet { UserDefaults.standard.set(enhanceMicrophone, forKey: "enhanceMicrophone") }
    }
    /// nil = never chosen: follow the system live. Set once, it sticks.
    @Published var theme: AppTheme? {
        didSet {
            guard let theme else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            let picked = theme
            Task { @MainActor in picked.apply() }
            Analytics.track("theme_changed", ["theme": theme.rawValue])
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "hotkeys"),
           var decoded = try? JSONDecoder().decode([String: HotkeyCombo].self, from: data) {
            // One-time migration: dictation's default moved from hold Left ⌘
            // to hold Right ⌥ (⌘ chords like ⌘⇧S kept firing dictation). A
            // stored combo equal to the OLD default was the default, not a
            // choice — drop it so the new default applies. A genuinely custom
            // combo is untouched.
            if decoded[HotkeyAction.voice.rawValue]
                == HotkeyCombo(keyCode: UInt32(kVK_Command), carbonModifiers: 0) {
                decoded[HotkeyAction.voice.rawValue] = nil
                if let updated = try? JSONEncoder().encode(decoded) {
                    UserDefaults.standard.set(updated, forKey: "hotkeys")
                }
            }
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }
        autoRecordMeetings = UserDefaults.standard.bool(forKey: "autoRecordMeetings")
        cursorEffects = UserDefaults.standard.object(forKey: "cursorEffects") as? Bool ?? true
        recordCursorSeparately = UserDefaults.standard.bool(forKey: "recordCursorSeparately")
        dictationTone = DictationTone(rawValue: UserDefaults.standard.string(forKey: "dictationTone") ?? "") ?? .neutral
        captureSound = CaptureSound(rawValue: UserDefaults.standard.string(forKey: "captureSound") ?? "") ?? .bloop
        enhanceMicrophone = UserDefaults.standard.bool(forKey: "enhanceMicrophone")
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "")
        screenshotFolderPath = UserDefaults.standard.string(forKey: "screenshotFolder")
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("My Man").path
    }

    func combo(for action: HotkeyAction) -> HotkeyCombo {
        hotkeys[action.rawValue] ?? action.defaultCombo
    }

    func setCombo(_ combo: HotkeyCombo, for action: HotkeyAction) {
        hotkeys[action.rawValue] = combo
        if let data = try? JSONEncoder().encode(hotkeys) {
            UserDefaults.standard.set(data, forKey: "hotkeys")
        }
        Analytics.track("hotkey_changed", ["action": action.rawValue])
        onHotkeysChanged?()
    }

    func hint(for action: HotkeyAction) -> String {
        combo(for: action).displayString
    }

    var screenshotFolderURL: URL {
        if let root = VerificationPaths.root { return root.appendingPathComponent("Captures") }
        return URL(fileURLWithPath: screenshotFolderPath, isDirectory: true)
    }
}

// MARK: - Settings panel

@MainActor
final class SettingsController {
    static let shared = SettingsController()
    private var panel: FloatingPanel?

    func show() {
        panel?.dismiss()
        let settingsPanel = FloatingPanel(content: SettingsPanelView(
            onDismiss: { [weak self] in self?.panel?.dismiss() }
        ))
        settingsPanel.onDismiss = { [weak self] in self?.panel = nil }
        panel = settingsPanel
        settingsPanel.present()
        Analytics.track("settings_opened")
    }
}

extension Notification.Name {
    static let mmCheckForUpdates = Notification.Name("mm.checkForUpdates")
}

struct SettingsPanelView: View {
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case general = "General", dictation = "Dictation", shortcuts = "Shortcuts", library = "Library", agents = "Agents"
        var id: String { rawValue }
    }

    @ObservedObject var store = SettingsStore.shared
    var onDismiss: () -> Void
    @State private var settingsPage: SettingsPage = .general
    @State private var recordingAction: HotkeyAction?
    @State private var vocabularyText = ""
    @State private var automationCopied = false
    @State private var vocabularySuggestions: [String] = []
    @State private var knownPeople: [Person] = []
    @AppStorage("interfaceTextScale") private var interfaceTextScale = 1.0
    @AppStorage("adaptiveLauncher") private var adaptiveLauncher = false
    @AppStorage(AdaptiveListeningPreference.key) private var listeningPausedUntil = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    IconView(icon: .close, size: 16, color: MM.Colors.textTertiary)
                        .clickable(minSize: 32)
                }
                .buttonStyle(.plain).accessibilityLabel("Close settings")
            }
            .padding(.horizontal, MM.Layout.paddingLarge)
            .padding(.vertical, MM.Layout.padding)

            Picker("Settings page", selection: $settingsPage) {
                ForEach(SettingsPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

            ScrollView {
                Group {
                    switch settingsPage {
                    case .general: generalPage
                    case .dictation: dictationPage
                    case .shortcuts: shortcutsPage
                    case .library: CapturePrivacySettings()
                    case .agents: AgentSettingsView()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: MM.Layout.settingsContentHeight)


            // Update path that never depends on the menu-bar icon — crowded
            // menu bars (notch, corporate agents) silently hide status items.
            HStack(spacing: MM.Layout.spacing) {
                Text("My Man \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                Button("Permissions…") {
                    WelcomeController.shared.show()
                }
                    .buttonStyle(.plain)
                    .clickable(minSize: 26)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MM.Colors.surface))
                    .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .mmCheckForUpdates, object: nil)
                }
                    .buttonStyle(.plain)
                    .clickable(minSize: 26)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MM.Colors.surface))
                    .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
            }
            .padding(MM.Layout.paddingLarge)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
        )
        .background(HotkeyCaptureView(active: recordingAction != nil) { combo in
            if let action = recordingAction {
                store.setCombo(combo, for: action)
                recordingAction = nil
            }
        })
        .onAppear { vocabularyText = DictationCleanup.userVocabulary().joined(separator: "\n") }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingSection("Automation & CLI") {
                HStack(spacing: 6) {
                    IconView(icon: .agent, size: 16, color: MM.Colors.accent)
                    Text("For agents and scripts")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textPrimary)
                }
                Text("Agents and scripts can open My Man’s normal capture UI — they never bypass permissions or confirmation.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                HStack(spacing: 8) {
                    Text("myman screenshot · note · dictation · meeting")
                        .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(automationCopied ? "Copied" : "Copy setup") { copyAutomationSetup() }
                        .buttonStyle(.plain).clickable(minSize: 26).font(MM.Fonts.metadata)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                }
                Text("Copy setup installs the helper in ~/.local/bin. Direct URL commands also work: myman://screenshot")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
            Divider().overlay(MM.Colors.border)
            settingSection("Meetings") {
                Toggle("Auto record when meeting detected", isOn: $store.autoRecordMeetings)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
            }
            Divider().overlay(MM.Colors.border)
            settingSection("Screenshot sound") {
                Picker("Screenshot sound", selection: $store.captureSound) {
                    ForEach(CaptureSound.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .onChange(of: store.captureSound) { _, sound in CaptureSoundPlayer.shared.play(sound) }
                Text("Plays when a screenshot is captured. Pick one to hear it.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
            Divider().overlay(MM.Colors.border)
            settingSection("Screen Recording") {
                Toggle("Cursor trail and click ripple", isOn: $store.cursorEffects)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
                Toggle("Record the cursor separately so Polish can smooth and resize it", isOn: $store.recordCursorSeparately)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
                Text("Off: the cursor is baked into the recording. On: the raw recording has no cursor; Polish draws one.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            }
            Divider().overlay(MM.Colors.border)
            settingSection("Screenshots") {
                HStack(spacing: MM.Layout.spacing) {
                    Text(store.screenshotFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(MM.Fonts.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { pickFolder() }
                        .buttonStyle(.plain).clickable(minSize: 26).font(MM.Fonts.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                }
            }
            Divider().overlay(MM.Colors.border)
            settingSection("Appearance") {
                Toggle("Adaptive launcher (experimental)", isOn: $adaptiveLauncher)
                    .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent).clickable()
                Text("One input for search and tools. Typing stops the microphone. Turn the mic off to pause automatic listening for one hour.")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                if adaptiveLauncher {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let paused = listeningPausedUntil > context.date.timeIntervalSince1970
                        HStack {
                            Text(paused ? "Listening paused until \(Date(timeIntervalSince1970: listeningPausedUntil).formatted(date: .omitted, time: .shortened))"
                                 : "Listen automatically when opened")
                                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                            Spacer()
                            Button {
                                if paused { AdaptiveListeningPreference.reset() }
                                else { AdaptiveListeningPreference.pause() }
                            } label: {
                                Text(paused ? "Reset" : "Pause for 1 hour").font(MM.Fonts.secondary).clickable()
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Picker("Interface text size", selection: $interfaceTextScale) {
                    Text("Standard").tag(1.0); Text("Larger").tag(1.25); Text("Largest").tag(1.5)
                }.clickable()
                Text("Reopen other windows to apply the new text size.").font(MM.Fonts.metadata)
                HStack(spacing: 6) {
                    let selected = store.theme ?? AppTheme.matchingSystem
                    ForEach(AppTheme.allCases) { option in
                        Button { store.theme = option } label: {
                            Text(option.label).font(MM.Fonts.secondary)
                                .foregroundStyle(selected == option ? MM.Colors.background : MM.Colors.textPrimary)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(selected == option ? MM.Colors.textPrimary : MM.Colors.surface))
                                .overlay(Capsule().strokeBorder(selected == option ? Color.clear : MM.Colors.border, lineWidth: 1))
                                .clickable(minSize: 26)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
    }

    private var dictationPage: some View {
        settingSection("Dictation") {
            Picker("Style", selection: $store.dictationTone) {
                ForEach(DictationTone.allCases) { tone in Text(tone.label).tag(tone) }
            }.labelsHidden().pickerStyle(.segmented)
            Text(store.dictationTone.detail).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            DictationAppStyleSettings()
            Button("Review dictation delivery and corrections…") { WorkflowCenter.shared.open(tab: "dictation") }.clickable()
            Toggle("Noise suppression on the mic", isOn: $store.enhanceMicrophone)
                .font(MM.Fonts.body).toggleStyle(.switch).controlSize(.small).tint(MM.Colors.accent)
            Text("Turns down other apps' audio while you dictate — macOS only offers this by putting the whole machine in call mode.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            TextEditor(text: $vocabularyText).font(MM.Fonts.secondary).frame(height: 130).accessibilityLabel("Personal vocabulary, one term per line")
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(MM.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MM.Colors.border, lineWidth: 1))
                .onChange(of: vocabularyText) { _, text in
                    DictationCleanup.setUserVocabulary(text.components(separatedBy: .newlines))
                }
            Text("Personal vocabulary — one name, product, or term per line.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
            MeetingVocabularyControls(suggestions: vocabularySuggestions, people: knownPeople,
                accept: { term in
                    MeetingVocabulary.decide(term, accept: true)
                    vocabularyText = DictationCleanup.userVocabulary().joined(separator: "\n")
                    vocabularySuggestions.removeAll { $0 == term }
                }, dismiss: { term in
                    MeetingVocabulary.decide(term, accept: false)
                    vocabularySuggestions.removeAll { $0 == term }
                }, togglePerson: { person in
                    People.setHidden(!person.hidden, id: person.id)
                    knownPeople = People.all(includingHidden: true)
                })
            .task {
                knownPeople = People.all(includingHidden: true)
                vocabularySuggestions = await MeetingVocabulary.refreshSuggestions()
            }
        }
    }

    private var shortcutsPage: some View {
        settingSection("Hotkeys") {
            ForEach(HotkeyAction.allCases) { action in hotkeyRow(action) }
        }
    }

    private func settingSection<Content: View>(_ title: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
            content()
        }
        .padding(MM.Layout.paddingLarge)
    }

    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        HStack {
            Text(action.label)
                .font(MM.Fonts.body)
                .foregroundStyle(MM.Colors.textPrimary)
            Spacer()
            Button {
                recordingAction = recordingAction == action ? nil : action
            } label: {
                Text(recordingAction == action ? "Press a key…" : store.hint(for: action))
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(recordingAction == action
                                     ? MM.Colors.accent : MM.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 84)
                    .background(RoundedRectangle(cornerRadius: 6).fill(MM.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(recordingAction == action
                                      ? MM.Colors.accent : MM.Colors.border, lineWidth: 1))
                    .clickable(minSize: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    private func pickFolder() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.canCreateDirectories = true
        dialog.directoryURL = store.screenshotFolderURL
        if dialog.runModal() == .OK, let url = dialog.url {
            store.screenshotFolderPath = url.path
        }
    }

    private func copyAutomationSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "mkdir -p ~/.local/bin && ln -sf /Applications/My\\ Man.app/Contents/Resources/myman ~/.local/bin/myman",
            forType: .string
        )
        automationCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            automationCopied = false
        }
    }
}

/// Invisible key-capture layer: while a hotkey row is armed, the next
/// modifier+key press becomes the new combo.
private struct HotkeyCaptureView: NSViewRepresentable {
    var active: Bool
    var onCapture: (HotkeyCombo) -> Void

    func makeNSView(context: Context) -> CaptureNSView { CaptureNSView() }

    func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onCapture = onCapture
        if active {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        view.active = active
    }

    final class CaptureNSView: NSView {
        var active = false
        var onCapture: ((HotkeyCombo) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        private var pendingModifier: UInt32?
        private var holdTimer: DispatchWorkItem?

        override func flagsChanged(with event: NSEvent) {
            guard active else {
                super.flagsChanged(with: event)
                return
            }
            let code = UInt32(event.keyCode)
            guard ModifierHotkeyMonitor.isModifierKeyCode(code),
                  let bit = ModifierHotkeyMonitor.flagBit(for: code) else { return }
            let pressed = event.modifierFlags.rawValue & UInt(bit) != 0
            if pressed {
                // A lone modifier registers after a short beat — no need to
                // release first. Pressing a regular key first makes it a
                // combo instead (keyDown cancels this timer).
                pendingModifier = code
                holdTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.pendingModifier == code else { return }
                    self.pendingModifier = nil
                    self.onCapture?(HotkeyCombo(keyCode: code, carbonModifiers: 0))
                }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            } else if pendingModifier == code {
                // Quick tap-and-release also counts.
                holdTimer?.cancel()
                pendingModifier = nil
                onCapture?(HotkeyCombo(keyCode: code, carbonModifiers: 0))
            }
        }

        override func keyDown(with event: NSEvent) {
            holdTimer?.cancel()
            pendingModifier = nil
            guard active else {
                super.keyDown(with: event)
                return
            }
            var carbonMods: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.control) { carbonMods |= UInt32(controlKey) }
            // A modifier-less key is fine as long as it isn't one you type
            // with — a bare hotkey is grabbed from every app on the machine.
            // Rejected keys fall through to the responder chain so ⎋ still
            // closes the panel and a stray letter still beeps.
            let code = UInt32(event.keyCode)
            guard carbonMods != 0 || HotkeyCombo.allowsBareKey(code) else {
                super.keyDown(with: event)
                return
            }
            onCapture?(HotkeyCombo(keyCode: code, carbonModifiers: carbonMods))
        }
    }
}
