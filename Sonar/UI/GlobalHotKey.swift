import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey. Unlike
/// global event monitors it needs no Accessibility permission, and it fails
/// (rather than stealing the keys) if another app already registered the combo.
final class GlobalHotKey {
    /// ⌃⌥⌘ — a combination macOS and common apps almost never use.
    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = 0x534F_4E52 // 'SONR'

    /// The key as typed, for showing in menus (e.g. "b").
    let key: String
    let modifiers: NSEvent.ModifierFlags
    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Returns nil if the combination is already taken.
    init?(keyCode: Int, key: String, modifiers: NSEvent.ModifierFlags = GlobalHotKey.defaultModifiers, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        self.key = key
        self.modifiers = modifiers
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            NSLog("Sonar: couldn't register hot key \(key) (\(status)); it may be in use by another app")
            return nil
        }
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers this on the main thread.
            GlobalHotKey.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension NSMenuItem {
    /// Shows a global hot key next to the item (display only; the hot key itself does the work).
    func show(_ hotKey: GlobalHotKey?) {
        keyEquivalent = hotKey?.key ?? ""
        keyEquivalentModifierMask = hotKey?.modifiers ?? []
    }
}
