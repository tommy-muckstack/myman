import AppKit
import Carbon

/// Bare-modifier hotkeys (hold Left ⌘ to dictate) — Carbon can't register
/// these, so we watch flagsChanged via NSEvent monitors (needs Accessibility,
/// which auto-paste already requires). Guards make a bare ⌘ safe:
/// - any OTHER key pressed while held → onCancel (it was ⌘C, not dictation)
/// - the caller treats short holds as taps and ignores them
@MainActor
final class ModifierHotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var watchedKeyCode: UInt32 = 0
    private var isPressed = false
    private var cancelled = false

    /// Device-dependent modifier flag bits by virtual key code.
    nonisolated static func flagBit(for keyCode: UInt32) -> UInt64? {
        switch Int(keyCode) {
        case kVK_Command: return 0x0008        // left ⌘
        case kVK_RightCommand: return 0x0010
        case kVK_Option: return 0x0020         // left ⌥
        case kVK_RightOption: return 0x0040
        case kVK_Shift: return 0x0002          // left ⇧
        case kVK_RightShift: return 0x0004
        case kVK_Control: return 0x0001
        default: return nil
        }
    }

    nonisolated static func isModifierKeyCode(_ keyCode: UInt32) -> Bool {
        flagBit(for: keyCode) != nil
    }

    func start(keyCode: UInt32) {
        stop()
        guard let bit = Self.flagBit(for: keyCode) else { return }
        watchedKeyCode = keyCode

        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == self.watchedKeyCode else { return }
            let pressed = event.modifierFlags.rawValue & UInt(bit) != 0
            if pressed, !self.isPressed {
                self.isPressed = true
                self.cancelled = false
                self.onDown?()
            } else if !pressed, self.isPressed {
                self.isPressed = false
                if !self.cancelled {
                    self.onUp?()
                }
            }
        }
        // Another key while held = a shortcut, never dictation.
        let keyDownHandler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isPressed, !self.cancelled else { return }
            self.cancelled = true
            self.onCancel?()
        }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDownHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyDownHandler(event)
            return event
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        isPressed = false
        cancelled = false
    }
}
