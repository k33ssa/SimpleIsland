import AppKit
import CoreGraphics
import ApplicationServices
import IslandCore

/// Системная клавиша из NX_SYSDEFINED (подтип 8). Коды — ev_keymap.h (docs/TECH.md §2).
enum MediaKey: Int, CaseIterable {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    case illuminationUp = 21, illuminationDown = 22
    /// Управление воспроизведением (ev_keymap.h: NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18, FAST 19, REWIND 20).
    /// Клавиатуры Apple на F7/F9 шлют то NEXT/PREVIOUS, то FAST/REWIND (система сама делает «короткое — трек,
    /// удержание — перемотка»), поэтому FAST ≡ «вперёд», REWIND ≡ «назад».
    case play = 16, next = 17, previous = 18, fast = 19, rewind = 20

    var isVolume: Bool { self == .soundUp || self == .soundDown || self == .mute }
    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
    var isIllumination: Bool { self == .illuminationUp || self == .illuminationDown }
    var isUp: Bool { self == .soundUp || self == .brightnessUp || self == .illuminationUp }
    /// Клавиша управления музыкой → мост ядра (`MediaKeyRouter`).
    var transport: MediaTransportKey? {
        switch self {
        case .play: return .playPause
        case .next, .fast: return .next
        case .previous, .rewind: return .previous
        default: return nil
        }
    }
}

struct MediaKeyEvent: Equatable {
    var key: MediaKey
    var isDown: Bool
    var isRepeat: Bool
    /// ⌥⇧ — мелкий шаг 1/64.
    var fine: Bool
    /// Только ⌥ — система открывает настройки (Звук/Дисплеи): такие нажатия не трогаем.
    var optionOnly: Bool

    /// Разбор data1 события NX_SYSDEFINED: код в старших 16 битах, состояние (0xA — нажата, 0xB — отпущена)
    /// в битах 8–15, флаг автоповтора — бит 0.
    static func decode(subtype: Int16, data1: Int, flags: CGEventFlags) -> MediaKeyEvent? {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: code), state == 0xA || state == 0xB else { return nil }
        let opt = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)
        return MediaKeyEvent(key: key, isDown: state == 0xA, isRepeat: data1 & 0x1 != 0,
                             fine: opt && shift, optionOnly: opt && !shift)
    }

    /// data1 для теста/синтеза.
    static func data1(key: MediaKey, down: Bool, repeating: Bool = false) -> Int {
        (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8) | (repeating ? 1 : 0)
    }
}

/// CGEventTap на NX_SYSDEFINED. `active` — глотает клавиши, которые обработчик взял на себя (нужен
/// Универсальный доступ); `listen` — только наблюдает. Тайм-аут/отключение пользователем — включаем обратно.
@MainActor
final class MediaKeyTap {
    enum Mode { case active, listen }

    /// Вернуть true — клавиша наша (в активном режиме событие проглатывается).
    var handler: ((MediaKeyEvent) -> Bool)?
    /// Отпущена клавиша, чьё нажатие проглочено (обработчик нажатий отпусканий не видит): «Медиа» отличает
    /// короткое нажатие ⏭ от удержания.
    var releaseHandler: ((MediaKeyEvent) -> Void)?
    private(set) var mode: Mode?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Коды, чьё нажатие проглочено: отпускание тоже глотаем, иначе система увидит «висящую» клавишу.
    private var swallowedDown = Set<Int>()
    private(set) var reenableCount = 0
    /// Сколько раз tap создавался (для самотеста пересоздания после сна).
    private(set) var createCount = 0

    var isRunning: Bool { port != nil }

    /// Создать tap. false — нет прав (Универсальный доступ) или система отказала.
    @discardableResult
    func start(mode: Mode) -> Bool {
        if self.mode == mode, port != nil { return true }
        stop()
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let p = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                        options: mode == .active ? .defaultTap : .listenOnly,
                                        eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: ref) else {
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        port = p; source = src; self.mode = mode
        createCount += 1
        return true
    }

    /// Только для самотеста: режим без настоящего tap.
    func setModeForTest(_ m: Mode?) { mode = m; swallowedDown.removeAll() }

    func stop() {
        if let p = port {
            CGEvent.tapEnable(tap: p, enable: false)
            if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
            CFMachPortInvalidate(p)
        }
        port = nil; source = nil; mode = nil
        swallowedDown.removeAll()
    }

    /// Разбор одного события. Возвращает true — проглотить. Открыт для самотеста (без настоящего tap).
    func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            reenableCount += 1
            return false
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              let e = MediaKeyEvent.decode(subtype: ns.subtype.rawValue, data1: ns.data1, flags: event.flags) else {
            return false
        }
        return route(e)
    }

    func route(_ e: MediaKeyEvent) -> Bool {
        let code = e.key.rawValue
        if !e.isDown {
            let was = swallowedDown.remove(code) != nil
            if was { releaseHandler?(e) }
            return mode == .active && was
        }
        let mine = handler?(e) ?? false
        guard mode == .active, mine else { return false }
        swallowedDown.insert(code)
        return true
    }
}

/// C-колбэк tap. Источник добавлен в главный run loop — значит, мы на главном потоке.
private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { tap.process(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Универсальный доступ (Accessibility).
enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static let promptedKey = "hud.accessibilityPrompted"

    /// «Разрешить…» — через ядро (`Permissions.requestFromUser`): в первый раз — только системный запрос (в нём
    /// своя кнопка «Открыть Системные настройки») и карточка «включите в списке»; дальше — раздел Универсального
    /// доступа и карточка; запущено из оболочки — «Перезапустить». Не молчит.
    @MainActor static func request() {
        // Прежний свой флаг «уже спрашивали» — ядру (иначе второй системный запрос вместо раздела настроек).
        if UserDefaults.standard.bool(forKey: promptedKey) { Permissions.accessibilityWasRequested = true }
        Task { @MainActor in _ = await Permissions.requestFromUser(.accessibility, moduleId: "hud") }
    }
}
