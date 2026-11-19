import Carbon.HIToolbox

/// Raccourci global ⌃⌥⌘N via l'API Carbon (pas besoin d'autorisation d'accessibilité).
final class HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Vrai si le raccourci est actif (faux s’il est déjà pris par une autre app).
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4E42_4C4B), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey | controlKey),
            id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Renvoie vrai si l’état demandé est obtenu.
    @discardableResult
    func set(_ enabled: Bool) -> Bool {
        if enabled { return register() }
        unregister()
        return true
    }
}
