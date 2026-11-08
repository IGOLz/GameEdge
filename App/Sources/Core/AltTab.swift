import AppKit
import Carbon.HIToolbox

/// ⌥Tab while a game runs, like Alt+Tab on Windows: from the game to the app
/// you used last, and back. A Carbon hot key needs no permission; it's only
/// registered while a game runs, so ⌥Tab works as usual otherwise.
final class AltTab {
    static let shared = AltTab()

    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled, hotKey == nil {
            if handler == nil {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), altTabPressed, 1, &spec, nil, &handler)
            }
            let id = EventHotKeyID(signature: OSType(0x4745_6467), id: 1) // "GEdg"
            let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
            if status != noErr {
                hotKey = nil
                Log.write("⌥Tab unavailable (\(status))")
            }
        } else if !enabled, let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }
}

private nonisolated func altTabPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in AltTab.shared.onPress?() }
    return noErr
}
