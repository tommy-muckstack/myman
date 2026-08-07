import AppKit
import Carbon

/// Bare-modifier hotkeys (hold Left ⌘ to dictate) — Carbon can't register
/// these, so we watch flagsChanged via NSEvent monitors (needs Accessibility,
/// which auto-paste already requires). Other keys are intentionally ignored:
/// holding ⌘ while pressing Return or clicking must not end dictation.
@MainActor
final class ModifierHotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// A click arrived after we'd already started. The user is ⌘-clicking,
    /// not talking — throw the take away rather than transcribe it.
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

    func start(keyCode: UInt32) {
        stop()
        guard let bit = Self.flagBit(for: keyCode) else { return }
        watchedKeyCode = keyCode

        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == self.watchedKeyCode else { return }
            let pressed = event.modifierFlags.rawValue & UInt(bit) != 0
            if pressed, !self.isPressed {
                self.isPressed = true
                self.didFireDown = false
                self.armTask?.cancel()
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
        // Clicks additionally abort AFTER arming. ⌘-click is normally a slow
        // gesture — hold ⌘, aim, click — so the hold alone clears the arm
        // delay and dictation is already live by the time the click lands.
        // Keys don't get this treatment: ⌘-Return mid-dictation is a real
        // thing, and a keystroke can't be a ⌘-click.
        let abortHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isPressed else { return }
            guard self.didFireDown else {
                self.armTask?.cancel()
                self.armTask = nil
                return
            }
            let isClick = event.type != .keyDown
            guard isClick else { return }
            self.didFireDown = false // release must not also report an onUp
            self.onAbort?()
        }
        let abortMask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: abortMask, handler: abortHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: abortMask) { event in
            abortHandler(event)
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
