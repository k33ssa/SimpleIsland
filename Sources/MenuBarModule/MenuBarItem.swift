import AppKit
import CoreGraphics

// Инвентарь значков правой части строки меню. Здесь только данные и чистая логика разбора (её проверяет
// `--selftest-menubar` на зафиксированном снимке слоя 25); живое чтение системы — MenuBarScanner.swift.
// Откуда числа и правила — docs/MENUBAR.md §2 (измерено 14.11.2026 на macOS 15.5).

/// Где значок сейчас.
public enum MenuBarSection: String, Codable, Sendable {
    /// Виден в строке меню (правее нашего разделителя и не под вырезом).
    case visible
    /// Левее нашего разделителя: спрятан нами (в острове или «совсем» — решают настройки).
    case island
    /// macOS его не показывает: не поместился слева от выреза / за краем (справа от разделителя или без него).
    case notch
}

/// Что за значок.
public enum MenuBarItemKind: Equatable, Sendable {
    /// Стороннее приложение.
    case app
    /// Модуль Пункта управления (`WiFi`, `Battery`, `Clock`, `BentoBox`…); `module` — nil, если имя окна недоступно
    /// (нет права «Запись экрана»).
    case controlCenter(module: String?)
    /// Другие системные: Spotlight, раскладка (TextInputMenuAgent), Siri, SystemUIServer.
    case system(String)
}

/// Окно слоя строки меню как его отдаёт `CGWindowListCopyWindowInfo` (только нужные поля).
public struct MenuBarRawWindow: Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var ownerName: String
    /// `kCGWindowName`: у чужих окон — только с правом «Запись экрана» (без него nil).
    public var name: String?
    /// Глобальные координаты CG (начало — левый верхний угол основного экрана).
    public var frame: CGRect
    public var onScreen: Bool
    public var layer: Int

    public init(windowID: CGWindowID, pid: pid_t, ownerName: String, name: String?, frame: CGRect, onScreen: Bool,
                layer: Int = MenuBarRawWindow.statusLayer) {
        // У копий значков на других экранах имя окна пустое (измерено 14.11 с двумя мониторами) — как «нет имени».
        self.windowID = windowID; self.pid = pid; self.ownerName = ownerName
        self.name = (name?.isEmpty ?? true) ? nil : name
        self.frame = frame; self.onScreen = onScreen; self.layer = layer
    }

    /// kCGStatusWindowLevel (25).
    public static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))

    /// Разбор словаря `CGWindowListCopyWindowInfo`.
    public init?(_ d: [String: Any]) {
        guard let id = (d[kCGWindowNumber as String] as? Int).flatMap({ CGWindowID(exactly: $0) }),
              let pid = d[kCGWindowOwnerPID as String] as? Int,
              let layer = d[kCGWindowLayer as String] as? Int,
              let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func num(_ k: String) -> CGFloat {
            if let v = b[k] as? CGFloat { return v }
            if let v = b[k] as? Double { return CGFloat(v) }
            if let v = b[k] as? Int { return CGFloat(v) }
            return 0
        }
        self.init(windowID: id, pid: pid_t(pid), ownerName: d[kCGWindowOwnerName as String] as? String ?? "?",
                  name: d[kCGWindowName as String] as? String,
                  frame: CGRect(x: num("X"), y: num("Y"), width: num("Width"), height: num("Height")),
                  onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false, layer: layer)
    }
}

/// Что известно о процессе-владельце (NSRunningApplication).
public struct MenuBarAppInfo: Equatable, Sendable {
    public var bundleId: String?
    public var name: String?
    public init(bundleId: String?, name: String?) { self.bundleId = bundleId; self.name = name }
}

/// Значок по данным Универсального доступа (`AXExtrasMenuBar` приложения): позиция и подписи.
public struct MenuBarAXInfo: Equatable, Sendable {
    public var pid: pid_t
    public var frame: CGRect
    public var title: String?
    public var detail: String?
    public var identifier: String?
    public init(pid: pid_t, frame: CGRect, title: String?, detail: String?, identifier: String?) {
        self.pid = pid; self.frame = frame; self.title = title; self.detail = detail; self.identifier = identifier
    }
}

/// Один значок строки меню.
public struct MenuBarItem: Identifiable, Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var ownerName: String
    public var bundleId: String?
    public var windowName: String?
    public var frame: CGRect
    public var onScreen: Bool
    public var kind: MenuBarItemKind
    /// Ключ для настроек: «bundle id | имя окна» → «| AXIdentifier» → «| #порядковый номер значка у приложения»
    /// (справа налево). AX-описание в ключ не идёт: оно меняется с состоянием («Connected/Disconnected»).
    public var key: String
    /// Все виды ключа этого значка (имя окна, AXIdentifier, «#N») — для миграции назначений, когда вид ключа сменился
    /// (включили/выключили «Запись экрана», старые «#N»).
    public var altKeys: [String] = []
    /// Ключ переживает перенос: есть имя окна/AX-метка или значок у приложения один. Порядковый номер у приложения с
    /// несколькими значками (OpenVPN, iStat без «Записи экрана») при переносе меняется — такие значки
    /// восстановление не трогает, только ручные действия.
    public var hasStableKey = true
    /// Как называть значок человеку: «Wi-Fi», «Ollama», «iStat Menus».
    public var displayName: String
    /// Живая подпись из AX («CPU 64%», «Battery 7%, Charging»), если есть.
    public var axTitle: String?
    public var section: MenuBarSection

    public var id: CGWindowID { windowID }
    /// macOS 27: номер «окна» синтетический (`MenuBarAgent.syntheticID`), настоящего окна у значка нет.
    public var hasRealWindow: Bool { windowID & 0x4000_0000 == 0 }
    public var isSystem: Bool { kind != .app }
    /// Скрыт вырезом / переполнением строки (`hiddenByNotch` из плана разведки).
    public var hiddenByNotch: Bool { section == .notch }

    /// macOS не даёт двигать: часы и сам Пункт управления (⌘-перетаскивание их не берёт).
    public var isMovable: Bool {
        if case .controlCenter(let m) = kind, let m,
           Self.immovableModules.contains(m) || Self.nonHideableModules.contains(m) { return false }
        return true
    }
    /// Выйти можно только из стороннего приложения.
    public var canQuit: Bool { kind == .app }

    static let immovableModules: Set<String> = ["Clock", "BentoBox"]
    /// Индикаторы, которые macOS держит в строке, пока они нужны (камера/микрофон, FaceTime, распознавание
    /// музыки): за разделитель их не спрятать — система вернёт (у Ice — `nonHideableItems`). Для уборки они
    /// «неподвижны», в карточке — только раздел Пункта управления и пояснение.
    static let nonHideableModules: Set<String> = ["AudioVideoModule", "FaceTime", "MusicRecognition"]
    /// macOS сама держит значок на виду (индикатор), а не запрещает двигать.
    public var isSystemIndicator: Bool {
        if case .controlCenter(let m) = kind, let m { return Self.nonHideableModules.contains(m) }
        return false
    }

    /// SF Symbol для системных значков (монохромные, как в строке меню). nil — брать значок приложения.
    public var systemSymbol: String? {
        switch kind {
        case .app: return nil
        case .controlCenter(let m): return MenuBarNames.ccSymbol[m ?? ""] ?? "switch.2"
        case .system(let s): return MenuBarNames.systemSymbol[s] ?? "gearshape"
        }
    }
}

// MARK: - Имена системных значков

enum MenuBarNames {
    /// Модули Пункта управления: имя окна (= ключ `NSStatusItem Visible <имя>` в com.apple.controlcenter) → по-русски.
    static let ccNames: [String: String] = [
        "WiFi": "Wi-Fi", "Battery": "Батарея", "Clock": "Часы", "BentoBox": "Пункт управления",
        "Sound": "Звук", "AudioVideoModule": "Камера и микрофон", "FocusModes": "Фокусирование",
        "NowPlaying": "Исполняется", "ScreenMirroring": "Повтор экрана", "StageManager": "Stage Manager",
        "Display": "Дисплей", "Bluetooth": "Bluetooth", "KeyboardBrightness": "Подсветка клавиатуры",
        "AirDrop": "AirDrop", "UserSwitcher": "Быстрое переключение", "Accessibility": "Универсальный доступ",
        "Hearing": "Слух", "Timer": "Таймер", "Weather": "Погода", "MusicRecognition": "Распознавание музыки",
        "Shortcuts": "Быстрые команды", "Siri": "Siri", "Spotlight": "Spotlight", "Battery-Percent": "Батарея",
    ]
    static let ccSymbol: [String: String] = [
        "WiFi": "wifi", "Battery": "battery.75percent", "Clock": "clock", "BentoBox": "switch.2",
        "Sound": "speaker.wave.2.fill", "AudioVideoModule": "video.fill", "FocusModes": "moon.fill",
        "NowPlaying": "play.circle", "ScreenMirroring": "rectangle.on.rectangle", "StageManager": "square.stack.3d.forward.dottedline",
        "Display": "sun.max", "Bluetooth": "dot.radiowaves.left.and.right", "KeyboardBrightness": "light.max",
        "AirDrop": "dot.radiowaves.up.forward", "UserSwitcher": "person.crop.circle", "Accessibility": "accessibility",
        "Hearing": "ear", "Timer": "timer", "Weather": "cloud.sun", "MusicRecognition": "shazam.logo",
        "Shortcuts": "square.2.layers.3d", "Siri": "mic", "Spotlight": "magnifyingglass",
    ]
    static let systemNames: [String: String] = [
        "Spotlight": "Spotlight", "TextInput": "Раскладка", "Siri": "Siri", "SystemUIServer": "Системный значок",
    ]
    static let systemSymbol: [String: String] = [
        "Spotlight": "magnifyingglass", "TextInput": "keyboard", "Siri": "mic", "SystemUIServer": "gearshape",
    ]
    /// Bundle id → системный значок.
    static let systemBundles: [String: String] = [
        "com.apple.Spotlight": "Spotlight", "com.apple.TextInputMenuAgent": "TextInput",
        "com.apple.Siri": "Siri", "com.apple.systemuiserver": "SystemUIServer",
    ]
    /// Имена владельцев (когда bundle id неизвестен — снимок для самотеста, процесс уже вышел).
    static let systemOwners: [String: String] = [
        "Spotlight": "Spotlight", "TextInputMenuAgent": "TextInput", "Siri": "Siri", "SystemUIServer": "SystemUIServer",
    ]
    static let controlCenterBundle = "com.apple.controlcenter"
    static let controlCenterOwners: Set<String> = ["Пункт управления", "Control Center", "ControlCenter"]
}

// MARK: - Разбор

/// Входные данные инвентаря: всё, что прочитано у системы (или снимок для самотеста).
public struct MenuBarScanInput: Sendable {
    public var windows: [MenuBarRawWindow]
    /// pid → приложение.
    public var apps: [pid_t: MenuBarAppInfo]
    /// Наш процесс: его окна (значок острова, разделитель) в список не идут.
    public var ownPID: pid_t
    /// Окно нашего разделителя (если создан): что левее — спрятано нами.
    public var dividerWindowID: CGWindowID?
    /// `NSStatusItem Visible <имя>` из com.apple.controlcenter (только чтение): выключенные модули Пункта
    /// управления остаются окнами со старой рамкой и `onscreen=false`.
    public var ccVisibility: [String: Bool]
    /// Подписи из Универсального доступа (пусто без права).
    public var ax: [MenuBarAXInfo]
    /// Вырез основного экрана в координатах CG (nil — экрана с вырезом нет).
    public var notch: CGRect?
    /// Экраны в координатах CG, первый — основной (со строкой меню, на нём оверлей уборки). У каждого экрана своя
    /// строка меню и **свои копии окон всех значков** (у копий на других экранах нет имени; измерено 14.11 с внешним
    /// монитором): в инвентарь идут только копии основного экрана. Пусто — все окна считаются основным экраном.
    public var screens: [CGRect]
    /// Текущая длина нашего разделителя: его копии на других экранах ищем по ширине (номер окна знаем только один).
    public var dividerLength: CGFloat?

    public init(windows: [MenuBarRawWindow], apps: [pid_t: MenuBarAppInfo], ownPID: pid_t,
                dividerWindowID: CGWindowID? = nil, ccVisibility: [String: Bool] = [:], ax: [MenuBarAXInfo] = [],
                notch: CGRect? = nil, screens: [CGRect] = [], dividerLength: CGFloat? = nil) {
        self.windows = windows; self.apps = apps; self.ownPID = ownPID; self.dividerWindowID = dividerWindowID
        self.ccVisibility = ccVisibility; self.ax = ax; self.notch = notch; self.screens = screens
        self.dividerLength = dividerLength
    }
}

public struct MenuBarInventory: Equatable, Sendable {
    /// Значки справа налево (как читает глаз от часов): сначала видимые, затем спрятанные.
    public var items: [MenuBarItem]
    /// Рамка нашего разделителя (CG), если он есть в списке окон.
    public var dividerFrame: CGRect?
    /// Сколько окон отброшено как «призраки» (выключенные модули Пункта управления).
    public var ghosts: Int
    /// Сколько окон-копий на других экранах пропущено (для печати в самотесте).
    public var otherScreenCopies = 0
    /// Откуда прочитано (macOS 27 — MenuBarAgent через AX; без права там пусто — `.agentNoAccess`).
    public var source: MenuBarSource = .windows
    /// macOS 27: кнопка системного overflow (nil — скрытых нет) и раскрыт ли он.
    public var overflowIndicator: CGRect?
    public var overflowExpanded = false
    /// macOS 27: наш разделитель есть, но сам в overflow (новые значки система ставит левее всех) — ничего не прячет,
    /// пока его не перенести в строку.
    public var dividerInOverflow = false
    /// macOS 27, несколько экранов: ключ значка → номера экранов (1… — не основной), где он сейчас виден в строке.
    public var visibleElsewhere: [String: Set<Int>] = [:]
    /// Сколько экранов со своей строкой меню (по окнам MenuBarAgent).
    public var screenCount = 1

    public static let empty = MenuBarInventory(items: [], dividerFrame: nil, ghosts: 0)

    public var visible: [MenuBarItem] { items.filter { $0.section == .visible } }
    public var inIslandSection: [MenuBarItem] { items.filter { $0.section == .island } }
    public var underNotch: [MenuBarItem] { items.filter { $0.section == .notch } }

    public func item(key: String) -> MenuBarItem? { items.first { $0.key == key } }

    /// Разбор снимка слоя строки меню.
    public static func parse(_ input: MenuBarScanInput) -> MenuBarInventory {
        let status = input.windows.filter {
            $0.layer == MenuBarRawWindow.statusLayer && $0.frame.width > 1 && $0.frame.height > 0 && $0.frame.height <= 60
        }
        // Копии разделителя на всех экранах: по номеру окна или по ширине (наш второй значок — 38 pt, разделитель —
        // 12 pt свёрнутый или ≥ 500 развёрнутый).
        let dividerCopies = status.filter { w in
            w.pid == input.ownPID && (w.windowID == input.dividerWindowID
                || (input.dividerLength.map { abs(w.frame.width - $0) <= 1 } ?? false))
        }
        let screens = input.screens
        let dividerHomes: [(CGRect, Int)] = dividerCopies.compactMap { d in
            home(d.frame, onScreen: true, refX: d.frame.maxX - 1, screens: screens, dividers: []).map { (d.frame, $0) }
        }
        // Окна только основного экрана (без экранов — все).
        var copies = 0
        let mainOnly = status.filter { w in
            guard !screens.isEmpty else { return true }
            let isDivider = dividerCopies.contains { $0.windowID == w.windowID }
            let h = home(w.frame, onScreen: w.onScreen, refX: isDivider ? w.frame.maxX - 1 : w.frame.midX,
                         screens: screens, dividers: isDivider ? [] : dividerHomes)
            if h != 0 { copies += 1 }
            return h == 0
        }
        let divider = mainOnly.first { $0.windowID == input.dividerWindowID }
            ?? mainOnly.first { w in dividerCopies.contains { $0.windowID == w.windowID } }
        let foreign = mainOnly.filter {
            $0.pid != input.ownPID && $0.ownerName != "SimpleIsland"
                && !(input.apps[$0.pid]?.bundleId.map(ownBundles.contains) ?? false)
        }
        let onscreen = foreign.filter(\.onScreen)

        var ghosts = 0
        var kept: [MenuBarRawWindow] = []
        for w in foreign {
            let app = input.apps[w.pid]
            let isCC = app?.bundleId == MenuBarNames.controlCenterBundle || MenuBarNames.controlCenterOwners.contains(w.ownerName)
            // Выключенный модуль Пункта управления: по defaults (если имя окна известно)…
            if isCC, let n = w.name, input.ccVisibility[n] == false, !w.onScreen { ghosts += 1; continue }
            // …и без имени: невидимое окно, налезающее на видимое (у выключенных старая рамка поверх чужих; значки
            // под вырезом идут встык и ни на кого не налезают — измерено 14.11).
            // Левее разделителя — спрятанные нами: их рамки не сверяем.
            let leftOfDivider = divider.map { w.frame.midX < $0.frame.midX } ?? false
            if !w.onScreen, !leftOfDivider,
               onscreen.contains(where: { overlapShare(w.frame, $0.frame) >= 0.3 }) { ghosts += 1; continue }
            // Модуль Пункта управления без имени, ни разу не размещённый (рамка в нуле, измерено 14.11 со вторым
            // монитором), — тоже призрак.
            if isCC, w.name == nil, !w.onScreen, !leftOfDivider, w.frame.minX <= 1 { ghosts += 1; continue }
            kept.append(w)
        }

        // Порядковые номера значков одного процесса (для ключа без имени окна): справа налево.
        var ordinals: [CGWindowID: Int] = [:]
        var perPid: [pid_t: Int] = [:]
        for (pid, group) in Dictionary(grouping: kept, by: \.pid) {
            perPid[pid] = group.count
            for (i, w) in group.sorted(by: { $0.frame.midX > $1.frame.midX }).enumerated() { ordinals[w.windowID] = i }
        }

        var items: [MenuBarItem] = kept.map { w in
            let app = input.apps[w.pid]
            let kind = kindOf(w, app: app)
            let ax = matchAX(w, in: input.ax)
            let section: MenuBarSection
            if let d = divider, w.frame.midX < d.frame.midX { section = .island }
            else if !w.onScreen { section = .notch }
            else { section = .visible }
            let owner = app?.bundleId ?? w.ownerName
            let axID = stableAXLabel(ax, kind: kind)
            let label = w.name ?? axID
            let ordinal = "#\(ordinals[w.windowID] ?? 0)"
            let suffix = label ?? ordinal
            var it = MenuBarItem(windowID: w.windowID, pid: w.pid, ownerName: w.ownerName, bundleId: app?.bundleId,
                                 windowName: w.name, frame: w.frame, onScreen: w.onScreen, kind: kind,
                                 key: "\(owner)|\(suffix)",
                                 displayName: displayName(w, kind: kind, app: app, ax: ax),
                                 axTitle: cleanTitle(ax?.title ?? ax?.detail), section: section)
            it.hasStableKey = label != nil || (perPid[w.pid] ?? 0) <= 1
            it.altKeys = [w.name, axID, ordinal].compactMap { $0 }.map { "\(owner)|\($0)" }
            return it
        }
        let rank: [MenuBarSection: Int] = [.visible: 0, .notch: 1, .island: 2]
        items.sort { a, b in
            if a.section != b.section { return rank[a.section]! < rank[b.section]! }
            return a.frame.midX > b.frame.midX
        }
        var inv = MenuBarInventory(items: items, dividerFrame: divider?.frame, ghosts: ghosts)
        inv.otherScreenCopies = copies
        return inv
    }

    /// Другие экземпляры SimpleIsland (собранный .app рядом с отладочным; отладочный — по имени владельца) — их значки
    /// не «мусор».
    static let ownBundles: Set<String> = ["local.simpleisland"]

    /// На каком экране окно строки меню (индекс в `screens`, 0 — основной; nil — не понять).
    /// 1. По высоте: строка меню — у верхнего края своего экрана (экраны друг над другом различаются сразу).
    /// 2. Видимое окно — экран, в ширину которого попадает `refX`.
    /// 3. Невидимое — ближайшая справа копия разделителя (спрятанные нами стоят левее разделителя своего экрана,
    ///    за краем, где по x может оказаться соседний экран), не дальше 2500 pt.
    /// 4. Невидимое в ширине экрана (под вырезом, переполнение) — этот экран.
    static func home(_ f: CGRect, onScreen: Bool, refX: CGFloat, screens: [CGRect], dividers: [(CGRect, Int)]) -> Int? {
        guard !screens.isEmpty else { return 0 }
        var cands = screens.indices.filter { abs(f.minY - screens[$0].minY) <= 2 }
        if cands.isEmpty { cands = Array(screens.indices) }
        if cands.count == 1 { return cands[0] }
        let inRange = cands.first { screens[$0].minX - 1 <= refX && refX < screens[$0].maxX + 2 }
        if onScreen, let i = inRange { return i }
        if let d = dividers.filter({ cands.contains($0.1) && $0.0.minX >= f.maxX - 2 && $0.0.minX - f.maxX < 2500 })
            .min(by: { $0.0.minX < $1.0.minX }) { return d.1 }
        return inRange ?? cands.first
    }

    /// Доля ширины `a`, перекрытая `b` (значки — полосы одной высоты, сравниваем только по x).
    static func overlapShare(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return a.width > 0 ? max(0, w) / a.width : 0
    }

    static func kindOf(_ w: MenuBarRawWindow, app: MenuBarAppInfo?) -> MenuBarItemKind {
        if app?.bundleId == MenuBarNames.controlCenterBundle || MenuBarNames.controlCenterOwners.contains(w.ownerName) {
            return .controlCenter(module: w.name.flatMap { $0.hasPrefix("Item-") ? nil : $0 })
        }
        if let b = app?.bundleId, let s = MenuBarNames.systemBundles[b] { return .system(s) }
        if app?.bundleId == nil, let s = MenuBarNames.systemOwners[w.ownerName] { return .system(s) }
        return .app
    }

    static func matchAX(_ w: MenuBarRawWindow, in ax: [MenuBarAXInfo]) -> MenuBarAXInfo? {
        ax.filter { $0.pid == w.pid && abs($0.frame.midX - w.frame.midX) <= max(6, w.frame.width / 2) }
            .min { abs($0.frame.midX - w.frame.midX) < abs($1.frame.midX - w.frame.midX) }
    }

    static func displayName(_ w: MenuBarRawWindow, kind: MenuBarItemKind, app: MenuBarAppInfo?, ax: MenuBarAXInfo?) -> String {
        switch kind {
        case .controlCenter(let m):
            if let m, let n = MenuBarNames.ccNames[m] { return n }
            if let d = cleanTitle(ax?.detail ?? ax?.title) { return d }
            return m ?? "Пункт управления"
        case .system(let s):
            return MenuBarNames.systemNames[s] ?? w.ownerName
        case .app:
            let base = app?.name ?? w.ownerName
            // «iStat Menus Status» → «iStat Menus»: служебный процесс-помощник.
            return base.hasSuffix(" Status") ? String(base.dropLast(7)) : base
        }
    }

    /// Устойчивая AX-метка значка — только `AXIdentifier`. Описание (`AXDescription`) меняется с состоянием
    /// («Connected/Disconnected», «Muted/Unmuted», «Wi‑Fi, 3 полосы») — оно только для показа. nil — метки нет.
    static func stableAXLabel(_ ax: MenuBarAXInfo?, kind: MenuBarItemKind) -> String? {
        cleanTitle(ax?.identifier)
    }

    static func cleanTitle(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 60 else { return nil }
        return t
    }
}
