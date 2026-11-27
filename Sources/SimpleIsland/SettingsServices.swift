import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Combine
import EventKit
import ServiceManagement
import SwiftUI
import IslandCore

// Системное для окна настроек: глобальная горячая клавиша, автозапуск, разрешения.
// Всё работает без выданных прав: статус «нужно разрешение» и кнопка, открывающая нужный раздел Системных настроек.

// MARK: - Горячая клавиша (Carbon, без Универсального доступа)

@MainActor
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()
    /// Код последней регистрации: noErr — работает; eventHotKeyExistsErr (-9878) — сочетание занято.
    @Published private(set) var lastStatus: OSStatus = 0
    /// Что делать по нажатию (ставит AppDelegate: раскрыть/свернуть остров).
    var action: () -> Void = {}
    private(set) var registered: HotKeySpec?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Зарегистрировать (старое снимается). nil — снять. Возвращает код Carbon (noErr = 0).
    @discardableResult
    func register(_ spec: HotKeySpec?) -> OSStatus {
        unregister()
        guard let spec else { lastStatus = 0; return 0 }
        installHandlerIfNeeded()
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers,
                                         EventHotKeyID(signature: Self.ownSignature, id: Self.ownId),
                                         GetApplicationEventTarget(), 0, &r)
        lastStatus = status
        if status == 0 { ref = r; registered = spec }
        else { NSLog("SimpleIsland: горячая клавиша %@ не зарегистрирована (%d)", spec.displayString, status) }
        refreshSystemConflict(spec)
        return status
    }

    /// Сочетание совпало с включённым системным (Клавиатура → Сочетания клавиш): Carbon при этом отвечает noErr,
    /// но нажатие забирает система (напр. ⌃⌥Space — «Следующий источник ввода»). Текст для настроек или nil.
    @Published private(set) var systemConflict: String?

    /// Перепроверить конфликт с системными сочетаниями (пользователь мог отключить их в Системных настройках).
    func refreshSystemConflict(_ spec: HotKeySpec? = nil) {
        let s = spec ?? registered
        let found = s.flatMap { Self.systemConflict(for: $0, in: Self.systemHotKeys()) }
        if found != systemConflict { systemConflict = found }
    }

    /// Системное сочетание: код клавиши, маска Carbon, включено ли, название (если известно).
    struct SystemHotKey: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var enabled: Bool
        var name: String?
    }

    /// Только ⌘⇧⌥⌃ (без caps lock, fn и т. п.).
    nonisolated static let modifierMask: UInt32 = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// Включённые системные сочетания: `CopySymbolicHotKeys` (Carbon, без прав) + названия по номерам из
    /// `com.apple.symbolichotkeys` (только чтение).
    nonisolated static func systemHotKeys() -> [SystemHotKey] {
        var list: [SystemHotKey] = []
        var arr: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&arr) == noErr, let items = arr?.takeRetainedValue() as? [[String: Any]] {
            for d in items {
                guard let code = (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                      let mods = (d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
                let enabled = (d[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
                list.append(SystemHotKey(keyCode: code, modifiers: mods & modifierMask, enabled: enabled))
            }
        }
        // Названия: в plist модификаторы — флаги NSEvent, номера сочетаний известны.
        let names: [String: String] = [
            "60": "Выбрать предыдущий источник ввода", "61": "Выбрать следующий источник ввода",
            "64": "Показать поиск Spotlight", "65": "Показать окно поиска Finder",
            "32": "Mission Control", "33": "Окна программы", "36": "Показать рабочий стол",
            "79": "Пространство слева", "81": "Пространство справа", "118": "Рабочий стол 1",
            "160": "Launchpad", "162": "Универсальный доступ", "175": "Не беспокоить", "190": "Быстрая заметка",
        ]
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")
        if let keys = domain?["AppleSymbolicHotKeys"] as? [String: Any] {
            for (num, raw) in keys {
                guard let name = names[num], let e = raw as? [String: Any],
                      (e["enabled"] as? NSNumber)?.boolValue == true,
                      let v = e["value"] as? [String: Any], let ps = v["parameters"] as? [NSNumber], ps.count >= 3
                else { continue }
                let code = ps[1].uint32Value
                let mods = carbonModifiers(NSEvent.ModifierFlags(rawValue: UInt(ps[2].uintValue)))
                if let i = list.firstIndex(where: { $0.enabled && $0.keyCode == code && $0.modifiers == mods && $0.name == nil }) {
                    list[i].name = name
                } else {
                    list.append(SystemHotKey(keyCode: code, modifiers: mods, enabled: true, name: name))
                }
            }
        }
        return list
    }

    /// Текст конфликта для `spec` или nil.
    nonisolated static func systemConflict(for spec: HotKeySpec, in list: [SystemHotKey]) -> String? {
        let mods = spec.modifiers & modifierMask
        let hits = list.filter { $0.enabled && $0.keyCode == spec.keyCode && $0.modifiers == mods }
        guard !hits.isEmpty else { return nil }
        if let name = hits.compactMap(\.name).first { return "«\(name)»" }
        return "системное сочетание"
    }

    /// Только для снимков: показать предупреждение о конфликте без обращения к системе.
    func setSnapshotConflict(_ text: String?) { systemConflict = text }

    /// Раздел «Клавиатура» Системных настроек (там «Сочетания клавиш…»).
    static func openKeyboardShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            // Только своё сочетание ('SILD', id 1); чужие горячие клавиши процесса (другие модули) — дальше по цепочке.
            guard GlobalHotKey.isOwnHotKey(event) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action() } }
            return noErr
        }, 1, &type, nil, &handler)
    }

    nonisolated static let ownSignature: OSType = 0x53494C44 // 'SILD'
    nonisolated static let ownId: UInt32 = 1

    /// Событие нажатия — нашей горячей клавиши (`EventHotKeyID` из `kEventParamDirectObject`)?
    nonisolated static func isOwnHotKey(_ event: EventRef?) -> Bool {
        guard let event else { return false }
        var hk = EventHotKeyID()
        let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        return err == noErr && hk.signature == ownSignature && hk.id == ownId
    }

    /// Флаги NSEvent → маска Carbon.
    nonisolated static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Подпись клавиши по виртуальному коду; буквы/цифры — из символа события.
    nonisolated static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
            kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        ]
        if let s = special[Int(keyCode)] { return s }
        // Подпись — по латинской раскладке (в русской символ события был бы «Й» вместо «Q»).
        if let a = asciiLabel(keyCode: keyCode) { return a }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "#\(keyCode)" : c
    }

    /// Символ клавиши в текущей ASCII-совместимой раскладке (ABC/US), заглавный. Только главный поток (TIS).
    nonisolated static func asciiLabel(keyCode: UInt16) -> String? {
        guard Thread.isMainThread,
              let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let st = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        }
        guard st == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return s.isEmpty || !s.unicodeScalars.allSatisfy({ $0.isASCII }) ? nil : s
    }

    /// Локальный монитор записи сочетания: каждое нажатие → (код клавиши, сочетание или nil); событие поглощается.
    nonisolated static func recordingMonitor(_ onKey: @escaping @Sendable (UInt16, HotKeySpec?) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            onKey(e.keyCode, spec(from: e))
            return nil
        }
    }

    /// Сочетание из события записи. nil — нет модификатора (⌘/⌃/⌥): одиночная клавиша глобально мешала бы вводу.
    nonisolated static func spec(from e: NSEvent) -> HotKeySpec? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        return HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: carbonModifiers(flags),
                          keyLabel: keyLabel(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers))
    }
}

// MARK: - Автозапуск (SMAppService.mainApp)

@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    init() { refresh() }

    func refresh() { status = SMAppService.mainApp.status }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// Запущено не из .app (swift run, .build/debug) — системе нечего регистрировать.
    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func set(_ on: Bool) {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = isBundled ? error.localizedDescription : "Работает только у собранного SimpleIsland.app"
        }
        refresh()
    }

    var statusText: String {
        switch status {
        case .enabled: return "включено"
        case .requiresApproval: return "ждёт подтверждения в «Объектах входа»"
        case .notFound: return isBundled ? "не найдено системой" : "только у собранного .app"
        case .notRegistered: return "выключено"
        @unknown default: return "неизвестно"
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Разрешения

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, automation, calendar, camera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Универсальный доступ"
        case .automation: return "Автоматизация"
        case .calendar: return "Календарь"
        case .camera: return "Камера"
        }
    }
    var purpose: String {
        switch self {
        case .accessibility: return "замена системного HUD громкости и яркости"
        case .automation: return "музыка: Music и Spotify, кнопки плеера"
        case .calendar: return "«Сегодня»: следующая встреча и «Подключиться»"
        case .camera: return "зеркало перед созвоном"
        }
    }
    var systemImage: String {
        switch self {
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2.fill"
        case .calendar: return "calendar"
        case .camera: return "camera.fill"
        }
    }
    var tileColor: Color {
        switch self {
        case .accessibility: return Color(hex: "#2563EB")
        case .automation: return Color(hex: "#6B7280")
        case .calendar: return Color(hex: "#FF3B30")
        case .camera: return Color(hex: "#0F9D58")
        }
    }
    /// Раздел «Конфиденциальность и безопасность».
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        case .calendar: anchor = "Privacy_Calendars"
        case .camera: anchor = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

extension PermissionKind {
    /// То же право в ядре (`Permissions`): автоматизация — запущенного плеера (или Music).
    func islandPermission(player: String?) -> IslandPermission {
        switch self {
        case .accessibility: return .accessibility
        case .calendar: return .calendars
        case .camera: return .camera
        case .automation: return .automation(bundleId: player ?? "com.apple.Music")
        }
    }
}

enum PermissionState: Equatable {
    case granted, denied, notDetermined, unknown
    var text: String {
        switch self {
        case .granted: return "разрешено"
        case .denied: return "запрещено"
        case .notDetermined: return "нужно разрешение"
        case .unknown: return "не проверено"
        }
    }
}

/// Статусы разрешений. Обновляются при открытии окна и когда приложение снова активно (вернулись из
/// Системных настроек) — без опроса.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private var observer: Any?
    private var isMock = false

    /// `mock` — готовые статусы (снимки, самотесты): систему не спрашиваем, на события не подписываемся.
    init(mock: [PermissionKind: PermissionState]? = nil) {
        if let mock { states = mock; isMock = true; return }
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                GlobalHotKey.shared.refreshSystemConflict()   // вернулись из Системных настроек — могли отключить сочетание
            }
        }
    }

    func state(_ k: PermissionKind) -> PermissionState { states[k] ?? .unknown }

    func refresh() {
        guard !isMock else { return }
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        states[.calendar] = {
            let s = EKEventStore.authorizationStatus(for: .event)
            if s == .fullAccess { return .granted }
            if s == .notDetermined { return .notDetermined }
            if s == .denied || s == .restricted || s == .writeOnly { return .denied }
            return .unknown
        }()
        states[.camera] = {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        }()
        if states[.automation] == nil { states[.automation] = .unknown }
        refreshAutomation()
    }

    /// Автоматизация плеера: `AEDeterminePermissionToAutomateTarget` без запроса. Если плеер не запущен — ответа
    /// нет (procNotFound), тогда статус «не проверено». Синхронный вызов — в фоне.
    private func refreshAutomation() {
        // Спрашиваем запущенный плеер (Music или Spotify); не запущен ни один — Music (ответ «не проверено»).
        let target = Self.automationTargets.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
            ?? "com.apple.Music"
        DispatchQueue.global(qos: .utility).async {
            let status = Self.automationStatus(bundleId: target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.states[.automation] = status }
            }
        }
    }

    nonisolated static func automationStatus(bundleId: String, ask: Bool = false) -> PermissionState {
        var addr = AEAddressDesc()
        let data = Array(bundleId.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), data, data.count, &addr) == 0 else { return .unknown }
        defer { AEDisposeDesc(&addr) }
        let r = AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch r {
        case 0: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown // procNotFound (-600): Music не запущен
        }
    }

    /// Что сделать по «Разрешить…».
    enum RequestPlan: Equatable {
        /// Системный запрос: появится окно macOS, приложение попадёт в список раздела.
        case systemPrompt
        /// Запрос Автоматизации к запущенному плееру (`AEDeterminePermissionToAutomateTarget`, askUserIfNeeded).
        case automationPrompt(bundleId: String)
        /// Открыть раздел Системных настроек (уже запрещено, нет строки Info.plist, плеер не запущен).
        case openSettings
    }

    /// Строки Info.plist, без которых системный запрос роняет процесс (есть у собранного .app, см. build-app.sh).
    static let usageKeys: [PermissionKind: String] = [
        .calendar: "NSCalendarsFullAccessUsageDescription",
        .camera: "NSCameraUsageDescription",
        .automation: "NSAppleEventsUsageDescription",
    ]

    /// Плееры для Автоматизации (кого спрашивать, если запущен).
    static let automationTargets = ["com.apple.Music", "com.spotify.client"]

    /// Решение без побочных эффектов (его проверяет самотест).
    /// Камера/Календарь/Автоматизация: в списке раздела приложение появляется только после системного запроса,
    /// кнопки «+» там нет — поэтому сначала запрос; раздел — когда запрашивать нельзя или бесполезно.
    nonisolated static func plan(_ k: PermissionKind, state: PermissionState, hasUsage: Bool,
                                 runningPlayer: String?, accessibilityPrompted: Bool) -> RequestPlan {
        switch k {
        case .accessibility:
            // Первый раз — только системный запрос (в нём своя кнопка «Открыть Системные настройки»), без второго окна.
            return accessibilityPrompted || state == .granted ? .openSettings : .systemPrompt
        case .calendar, .camera:
            return hasUsage && state == .notDetermined ? .systemPrompt : .openSettings
        case .automation:
            guard hasUsage, state != .denied, state != .granted, let p = runningPlayer else { return .openSettings }
            return .automationPrompt(bundleId: p)
        }
    }

    private var accessibilityPrompted = false
    private var eventStore: EKEventStore?
    /// Подсказка под списком прав (напр. «запусти Music или Spotify»). nil — нет.
    @Published private(set) var hint: String?

    func request(_ k: PermissionKind) {
        let hasUsage = Self.usageKeys[k].map { Bundle.main.object(forInfoDictionaryKey: $0) != nil } ?? true
        let player = Self.automationTargets.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        let ip = k.islandPermission(player: player)
        hint = nil
        // Запущено не как приложение (из оболочки): окно macOS ушло бы от имени родителя — карточка «Перезапустить».
        if !LaunchKind.current.isApp {
            guide(.relaunch(canRelaunch: LaunchKind.current.canRelaunch), ip)
            return
        }
        let plan = Self.plan(k, state: state(k), hasUsage: hasUsage, runningPlayer: player,
                             accessibilityPrompted: accessibilityPrompted)
        let t0 = Date()
        switch plan {
        case .openSettings:
            // Кнопка не молчит: раздел настроек и карточка в острове «что включить и где».
            if k == .automation, hasUsage, player == nil, state(k) != .denied {
                NSWorkspace.shared.open(k.settingsURL)
                guide(.targetNotRunning, ip)
                hint = "Автоматизация: запусти Music или Spotify и нажми «Разрешить…» ещё раз — macOS спросит разрешение."
            } else {
                guide(k == .accessibility ? .deniedBefore : (hasUsage ? .deniedBefore : .cannotAsk), ip)
            }
        case .systemPrompt:
            switch k {
            case .accessibility:
                accessibilityPrompted = true
                Permissions.accessibilityWasRequested = true
                let key = "AXTrustedCheckOptionPrompt" as CFString
                let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                if !trusted { guide(.accessibilityPrompted, ip) }
            case .calendar:
                let store = EKEventStore()
                eventStore = store
                store.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.afterPrompt(ip, granted, t0) } }
                }
            case .camera:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.afterPrompt(ip, granted, t0) } }
                }
            case .automation:
                break
            }
        case .automationPrompt(let bundleId):
            // Синхронный и может ждать ответа пользователя — в фоне.
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = Self.automationStatus(bundleId: bundleId, ask: true) == .granted
                DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.afterPrompt(ip, granted, t0) } }
            }
        }
    }

    /// Ответ на системный запрос: статус перечитать заново; права нет (окно не показалось, ответ сразу, отказ) —
    /// раздел настроек и карточка (`Permissions.followUp`).
    private func afterPrompt(_ ip: IslandPermission, _ granted: Bool, _ t0: Date) {
        refresh()
        let after: PermissionStatus = granted ? .granted : Permissions.status(ip)
        if case .guide(let g) = Permissions.followUp(ip, after: after, elapsed: Date().timeIntervalSince(t0),
                                                     launch: LaunchKind.current) {
            guide(g, ip)
        }
    }

    /// Подсказка: в острове (карточка) и под списком прав.
    private func guide(_ g: PermissionGuide, _ ip: IslandPermission) {
        hint = g.text(for: ip).body
        Permissions.showGuide(g, for: ip)
    }
}
