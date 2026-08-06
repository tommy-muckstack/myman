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

    /// Bare-modifier hotkey (hold Left ⌘) — registered via NSEvent monitors,
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

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
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
        ]
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
        // Hold Left ⌘ to dictate, release to paste — the Wispr gesture.
        case .voice: return HotkeyCombo(keyCode: UInt32(kVK_Command), carbonModifiers: 0)
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
    @Published var dictationTone: DictationTone {
        didSet { UserDefaults.standard.set(dictationTone.rawValue, forKey: "dictationTone") }
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
           let decoded = try? JSONDecoder().decode([String: HotkeyCombo].self, from: data) {
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }
        autoRecordMeetings = UserDefaults.standard.bool(forKey: "autoRecordMeetings")
        dictationTone = DictationTone(rawValue: UserDefaults.standard.string(forKey: "dictationTone") ?? "") ?? .neutral
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
        URL(fileURLWithPath: screenshotFolderPath, isDirectory: true)
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
    @ObservedObject var store = SettingsStore.shared
    var onDismiss: () -> Void
    @State private var recordingAction: HotkeyAction?
    @State private var vocabularyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                IconView(icon: .close, size: 16, color: MM.Colors.textTertiary)
                    .clickable()
                    .onTapGesture { onDismiss() }
            }
            .padding(.horizontal, MM.Layout.paddingLarge)
            .padding(.vertical, MM.Layout.padding)

            Divider().overlay(MM.Colors.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Dictation")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                Picker("Style", selection: $store.dictationTone) {
                    ForEach(DictationTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(store.dictationTone.detail)
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textSecondary)
                TextEditor(text: $vocabularyText)
                    .font(MM.Fonts.secondary)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(MM.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MM.Colors.border, lineWidth: 1))
                    .onChange(of: vocabularyText) { _, text in
                        DictationCleanup.setUserVocabulary(text.components(separatedBy: .newlines))
                    }
                Text("Personal vocabulary — one name, product, or term per line.")
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(MM.Colors.textTertiary)
            }
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

            VStack(alignment: .leading, spacing: 4) {
                Text("Hotkeys")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                    .padding(.bottom, 4)
                ForEach(HotkeyAction.allCases) { action in
                    hotkeyRow(action)
                }
            }
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

            VStack(alignment: .leading, spacing: 6) {
                Text("Meetings")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                Toggle(isOn: $store.autoRecordMeetings) {
                    Text("Auto record when meeting detected")
                        .font(MM.Fonts.body)
                        .foregroundStyle(MM.Colors.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MM.Colors.accent)
            }
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

            VStack(alignment: .leading, spacing: 6) {
                Text("Screenshots")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                HStack(spacing: MM.Layout.spacing) {
                    Text(store.screenshotFolderPath.replacingOccurrences(
                        of: NSHomeDirectory(), with: "~"))
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { pickFolder() }
                        .buttonStyle(.plain)
                        .clickable(minSize: 26)
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(MM.Colors.surface))
                        .overlay(Capsule().strokeBorder(MM.Colors.border, lineWidth: 1))
                }
            }
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                HStack(spacing: 6) {
                    let selected = store.theme ?? AppTheme.matchingSystem
                    ForEach(AppTheme.allCases) { option in
                        Button {
                            store.theme = option
                        } label: {
                            Text(option.label)
                                .font(MM.Fonts.secondary)
                                .foregroundStyle(selected == option
                                                 ? MM.Colors.background : MM.Colors.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(selected == option
                                                           ? MM.Colors.textPrimary : MM.Colors.surface))
                                .overlay(Capsule().strokeBorder(
                                    selected == option ? Color.clear : MM.Colors.border,
                                    lineWidth: 1))
                                .clickable(minSize: 26)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            .padding(MM.Layout.paddingLarge)

            Divider().overlay(MM.Colors.border)

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
            // Bare keys make terrible global hotkeys — require a modifier.
            guard carbonMods != 0 else { return }
            onCapture?(HotkeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods))
        }
    }
}
