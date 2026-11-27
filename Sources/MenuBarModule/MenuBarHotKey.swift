import AppKit
import Carbon.HIToolbox
import IslandCore

/// Своя горячая клавиша режима уборки (по умолчанию ⌃⌥B), Carbon `RegisterEventHotKey` — права не нужны.
/// Подпись 'SIMB': обработчик ядра (⌃⌥Space, 'SILD') чужие нажатия пропускает дальше по цепочке, этот — тоже.
@MainActor
final class MenuBarHotKey {
    static let shared = MenuBarHotKey()
    nonisolated static let signature: OSType = 0x53494D42 // 'SIMB'
    nonisolated static let hotKeyId: UInt32 = 1

    var action: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered: HotKeySpec?
    /// Код последней регистрации (−9878 — сочетание занято).
    private(set) var lastStatus: OSStatus = 0

    @discardableResult
    func register(_ spec: HotKeySpec?) -> OSStatus {
        unregister()
        guard let spec else { lastStatus = 0; return 0 }
        installHandler()
        var r: EventHotKeyRef?
        let st = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: Self.hotKeyId),
                                     GetApplicationEventTarget(), 0, &r)
        lastStatus = st
        if st == noErr { ref = r; registered = spec }
        else { NSLog("SimpleIsland: горячая клавиша уборки %@ не зарегистрирована (%d)", spec.displayString, st) }
        return st
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard MenuBarHotKey.isOwn(event) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarHotKey.shared.action() } }
            return noErr
        }, 1, &type, nil, &handler)
    }

    nonisolated static func isOwn(_ event: EventRef?) -> Bool {
        guard let event else { return false }
        var hk = EventHotKeyID()
        let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        return err == noErr && hk.signature == signature && hk.id == hotKeyId
    }

    /// Флаги NSEvent → маска Carbon (только ⌘⇧⌥⌃).
    nonisolated static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Подпись клавиши по виртуальному коду латинской раскладки (в русской символ был бы «И» вместо «B»).
    nonisolated static func label(keyCode: UInt16) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[Int(keyCode)] ?? "#\(keyCode)"
    }

    /// Нажатие при записи сочетания → спецификация (без ⌘/⌃/⌥ — nil: так легко занять обычную букву).
    nonisolated static func spec(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> HotKeySpec? {
        let mods = carbonModifiers(flags)
        // Нужен ⌘, ⌃ или ⌥: «⇧B» отнял бы у пользователя заглавную «B».
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        return HotKeySpec(keyCode: UInt32(keyCode), modifiers: mods, keyLabel: label(keyCode: keyCode))
    }
}
