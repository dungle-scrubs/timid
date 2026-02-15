import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey (Ctrl+Option+N) using the Carbon Event API.
/// Calls the provided callback when the hotkey is pressed.
class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void

    /// @param callback Closure invoked on the main thread when the hotkey is pressed.
    init(callback: @escaping () -> Void) {
        self.callback = callback
        registerHotkey()
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    private func registerHotkey() {
        // Control + Option + N
        let modifiers: UInt32 = UInt32(controlKey | optionKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_N)

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x54494D44) // "TIMD"
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("Failed to register hotkey: \(status)")
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    manager.callback()
                }
            }

            return noErr
        }

        let status2 = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status2 != noErr {
            print("Failed to install event handler: \(status2)")
        }
    }
}
