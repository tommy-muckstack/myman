import AppKit
import Carbon

/// Bare-modifier hotkeys (hold Right ⌥ to dictate) — Carbon can't register
/// these, so we watch flagsChanged via NSEvent monitors (needs Accessibility,
/// which auto-paste already requires). Other keys and clicks are intentionally
/// ignored once dictation is live: holding ⌘ while pressing Return or clicking
/// around (Wispr Flow style) must not end dictation. Only a second MODIFIER
/// joining the chord (⌘⇧4 screenshots, ⌘⌥ shortcuts…) disarms or aborts —
/// those chords never mean "talk", and the system swallows the final
/// keystroke of shortcuts like screenshots before our monitors ever see it.
@MainActor
final class ModifierHotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// A second modifier joined after we'd already started. The user is in a
    /// ⌘⇧/⌘⌥ chord, not talking — throw the take away rather than transcribe.
    var onAbort: (() -> Void)?

    /// How long the modifier must be held ALONE before this counts as a
    /// hotkey. ⌘ is half of every keyboard shortcut on the machine, so
    /// firing on key-down meant ⌘Space, ⌘C and ⌘Tab each started a dictation
    /// — and starting one spins up a voice-processing unit, which ducks
    /// every other app's audio. Nothing may happen until we KNOW the user is
    /// holding the key on its own.
    var holdDelay: TimeInterval = 0.35

    private var monitors: [Any] = []
    private var watchedKeyCode: UInt32 = 0
    private var isPressed = false
    private var armTask: Task<Void, Never>?
    /// onUp must only follow an onDown we actually delivered.
    private var didFireDown = false

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

    /// Device-INDEPENDENT flag for the watched key, so we can subtract it and
    /// see whether any OTHER real modifier (⇧⌃⌥⌘) is part of the chord.
    /// Caps Lock and Fn are deliberately excluded — they don't form shortcuts.
    nonisolated static func genericFlag(for keyCode: UInt32) -> NSEvent.ModifierFlags {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return .command
        case kVK_Option, kVK_RightOption: return .option
        case kVK_Shift, kVK_RightShift: return .shift
        case kVK_Control: return .control
        default: return []
        }
    }

    func start(keyCode: UInt32) {
        stop()
        guard let bit = Self.flagBit(for: keyCode) else { return }
        watchedKeyCode = keyCode

        let watchedGeneric = Self.genericFlag(for: keyCode)
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            // Any OTHER modifier in the chord means this is a keyboard
            // shortcut (⌘⇧4 screenshot, ⌘⌥…), never a dictation hold. This is
            // the ONLY reliable signal for shortcuts the system consumes —
            // their final keystroke never reaches our monitors.
            let otherModifierHeld = !event.modifierFlags
                .intersection([.shift, .control, .option, .command])
                .subtracting(watchedGeneric)
                .isEmpty

            guard event.keyCode == self.watchedKeyCode else {
                // A different modifier key changed while ours is held.
                guard self.isPressed, otherModifierHeld else { return }
                if self.didFireDown {
                    self.didFireDown = false // release must not also report onUp
                    self.onAbort?()
                } else {
                    self.armTask?.cancel()
                    self.armTask = nil
                }
                return
            }

            let pressed = event.modifierFlags.rawValue & UInt(bit) != 0
            if pressed, !self.isPressed {
                self.isPressed = true
                self.didFireDown = false
                self.armTask?.cancel()
                // ⇧ was already down when ⌘ arrived — a chord from the start.
                guard !otherModifierHeld else { return }
                self.armTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(self?.holdDelay ?? 0.35))
                    guard let self, !Task.isCancelled, self.isPressed else { return }
                    self.didFireDown = true
                    self.onDown?()
                }
            } else if !pressed, self.isPressed {
                self.isPressed = false
                self.armTask?.cancel()
                self.armTask = nil
                // A tap that never armed did nothing — nothing to undo.
                if self.didFireDown {
                    self.didFireDown = false
                    self.onUp?()
                }
            }
        }

        // Any other key or click during the arming window means this is a
        // shortcut, not a hold. Disarm before we ever touch the mic.
        //
        // Once dictation is LIVE, keys and clicks are both left alone:
        // Wispr-Flow style, you keep talking while you click around or hit
        // ⌘-Return. Only a second modifier joining the chord aborts (handled
        // in flagsHandler above).
        let disarmHandler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isPressed, !self.didFireDown else { return }
            self.armTask?.cancel()
            self.armTask = nil
        }
        let disarmMask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: disarmMask, handler: disarmHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: disarmMask) { event in
            disarmHandler(event)
            return event
        } as Any)

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        isPressed = false
        armTask?.cancel()
        armTask = nil
        didFireDown = false
    }
}
