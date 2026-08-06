import AppKit
import Carbon

// Global hotkeys via Carbon RegisterEventHotKey — needs no Accessibility
// permission and coexists with the sandbox. N hotkeys dispatched by ID.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    struct Hotkey {
        let keyCode: UInt32
        let modifiers: UInt32 // Carbon flags: cmdKey, optionKey, controlKey, shiftKey
    }

    enum RegistrationError: Error {
        case combinationTaken
        case systemError(OSStatus)
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false
    private let signature: OSType = 0x4D_59_4D_4E // 'MYMN'

    private init() {}

    @discardableResult
    func register(_ hotkey: Hotkey, handler: @escaping () -> Void,
                  onRelease: (() -> Void)? = nil) -> Result<UInt32, RegistrationError> {
        installEventHandlerIfNeeded()

        let id = nextID
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            return .failure(status == eventHotKeyExistsErr
                ? .combinationTaken
                : .systemError(status))
        }
        handlers[id] = handler
        releaseHandlers[id] = onRelease
        refs[id] = ref
        nextID += 1
        return .success(id)
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
        releaseHandlers.removeValue(forKey: id)
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if hotKeyID.signature == center.signature {
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    center.releaseHandlers[hotKeyID.id]?()
                } else {
                    center.handlers[hotKeyID.id]?()
                }
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), callback, 2, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), nil
        )
        precondition(status == noErr, "HotkeyCenter: failed to install Carbon event handler (\(status))")
        eventHandlerInstalled = true
    }
}
