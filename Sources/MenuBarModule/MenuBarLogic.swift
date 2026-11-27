import AppKit
import IslandCore

// Чистая логика модуля «Строка меню»: настройки, назначение разделам и восстановление, варианты карточки
// подтверждения и клавиши режима уборки, длина разделителя. Без обращения к системе — это проверяет самотест.

/// Куда пользователь определил значок.
public enum MenuBarPlacement: String, Codable, CaseIterable, Sendable {
    /// Виден в строке меню (как было).
    case bar
    /// Спрятан из строки, показывается во вкладке «Значки» острова.
    case island
    /// Спрятан совсем: в острове не показывается, вернуть — в настройках.
    case hidden

    public var title: String {
        switch self {
        case .bar: return "в строке"
        case .island: return "в острове"
        case .hidden: return "спрятан"
        }
    }
}

/// Настройки модуля (settings.json → moduleSettings["menubar"]). Отсутствующие поля — по умолчанию.
public struct MenuBarPrefs: Codable, Equatable, Sendable {
    /// Ключ значка (`MenuBarItem.key`) → назначение. Нет записи — «в строке».
    public var placements: [String: MenuBarPlacement] = [:]
    /// Ключ → имя значка (чтобы список в настройках был понятен, когда приложение не запущено).
    public var names: [String: String] = [:]
    /// Значки, которые до разделителя прятал вырез (бейдж «из-под выреза» во вкладке).
    public var fromNotch: [String] = []
    /// Не возвращать на место после перезапуска приложения (снята галочка «Помнить…»).
    public var noRestore: [String] = []
    /// Стопка спрятанных значков в правом ухе компакта.
    public var showStack = false
    public var hotKeyEnabled = true
    public var hotKey: HotKeySpec = MenuBarPrefs.defaultHotKey
    /// Настоящие картинки значков (право «Запись экрана», только по кнопке).
    public var realIcons = false
    /// При запуске и перезапуске приложений возвращать значки в назначенный раздел (нужен Универсальный доступ).
    public var restoreOnLaunch = true
    /// Значки, которые возвращать в остров молча, без уведомления «Вернуть в остров?» (16.11: «часто вылезает»):
    /// попадают сюда после первого «Вернуть».
    public var autoRestore: [String] = []

    /// ⌃⌥B.
    public static let defaultHotKey = HotKeySpec(keyCode: 11, modifiers: 0x1000 | 0x0800, keyLabel: "B")

    public init() {}

    enum CodingKeys: String, CodingKey {
        case placements, names, fromNotch, noRestore, showStack, hotKeyEnabled, hotKey, realIcons, restoreOnLaunch, autoRestore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarPrefs()
        // Неизвестное значение назначения (из будущей версии) — запись пропускается, а не ломает всё.
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .placements) {
            placements = raw.compactMapValues { MenuBarPlacement(rawValue: $0) }
        }
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? d.names
        fromNotch = (try? c.decodeIfPresent([String].self, forKey: .fromNotch)) ?? d.fromNotch
        noRestore = (try? c.decodeIfPresent([String].self, forKey: .noRestore)) ?? d.noRestore
        showStack = (try? c.decodeIfPresent(Bool.self, forKey: .showStack)) ?? d.showStack
        hotKeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled)) ?? d.hotKeyEnabled
        hotKey = (try? c.decodeIfPresent(HotKeySpec.self, forKey: .hotKey)) ?? d.hotKey
        // Сочетание без ⌘/⌃/⌥ (старая версия записывала ⇧B) занимает обычную букву — назад к ⌃⌥B.
        if hotKey.modifiers & (0x0100 | 0x1000 | 0x0800) == 0 { hotKey = d.hotKey }
        realIcons = (try? c.decodeIfPresent(Bool.self, forKey: .realIcons)) ?? d.realIcons
        restoreOnLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch)) ?? d.restoreOnLaunch
        autoRestore = (try? c.decodeIfPresent([String].self, forKey: .autoRestore)) ?? d.autoRestore
    }

    public func placement(_ key: String) -> MenuBarPlacement { placements[key] ?? .bar }

    /// Хоть что-то спрятано — нужен разделитель.
    public var needsDivider: Bool { placements.values.contains { $0 != .bar } }

    /// Записать назначение (`.bar` — запись убирается).
    public mutating func set(_ key: String, _ p: MenuBarPlacement, name: String? = nil, remember: Bool = true) {
        if p == .bar { placements[key] = nil; fromNotch.removeAll { $0 == key } } else { placements[key] = p }
        if let name { names[key] = name }
        noRestore.removeAll { $0 == key }
        if !remember && p != .bar { noRestore.append(key) }
    }

    /// «Вернуть всё как было»: назначения и пометки — прочь, остальные настройки остаются.
    public mutating func resetPlacements() {
        placements = [:]; fromNotch = []; noRestore = []
    }
}

// MARK: - Назначение разделам

/// Перенос, который нужно сделать, чтобы значок оказался в своём разделе.
public struct MenuBarMove: Equatable, Sendable {
    public enum Direction: String, Sendable { case intoHidden, toBar }
    public var key: String
    public var direction: Direction
}

public enum MenuBarPlanner {
    /// Сверить фактическое положение значков с настройками.
    /// * назначен «в острове»/«спрятан», а стоит в строке или под вырезом → перенести за разделитель;
    /// * назначен «в строке» явно (был переносом возвращён), а стоит за разделителем → вернуть;
    /// * за разделителем без записи (пользователь сам ⌘-перетащил) → принять как «в острове» (`adopt`).
    /// Значки с пометкой «не помнить», неподвижные (часы, Пункт управления) и без устойчивого ключа (второй значок
    /// приложения без имени окна — его номер меняется при переносе) не трогаем.
    public static func reconcile(_ inv: MenuBarInventory, _ prefs: MenuBarPrefs)
        -> (moves: [MenuBarMove], adopt: [String]) {
        var moves: [MenuBarMove] = []
        var adopt: [String] = []
        for item in inv.items where item.isMovable && item.hasStableKey {
            let p = prefs.placements[item.key]
            switch (p, item.section) {
            case (.island?, .visible), (.island?, .notch), (.hidden?, .visible), (.hidden?, .notch):
                if !prefs.noRestore.contains(item.key) { moves.append(MenuBarMove(key: item.key, direction: .intoHidden)) }
            case (nil, .island):
                adopt.append(item.key)
            default: break
            }
        }
        return (moves, adopt)
    }

    /// Что показывать во вкладке «Значки»: назначенные «в острове» (за разделителем) + то, что прячет вырез.
    public static func islandItems(_ inv: MenuBarInventory, _ prefs: MenuBarPrefs) -> [MenuBarItem] {
        let hidden = inv.inIslandSection.filter { prefs.placement($0.key) != .hidden }
        return hidden + inv.underNotch
    }

    /// Спрятано совсем (по настройкам; приложение может быть не запущено).
    public static func hiddenCount(_ prefs: MenuBarPrefs) -> Int { prefs.placements.values.filter { $0 == .hidden }.count }

    /// Куда ставить разделитель при создании: правым краем к левому краю самого левого видимого значка
    /// (`NSStatusItem Preferred Position` — расстояние от правого края экрана до правого края значка; у часов и
    /// Пункта управления совпадает с рамкой с точностью 2 pt, измерено 14.11). Всё, что прятал вырез, оказывается
    /// левее разделителя — то есть в острове, а не «нигде».
    public static func dividerPreferredPosition(_ inv: MenuBarInventory, screenMaxX: CGFloat) -> CGFloat? {
        guard let leftmost = inv.visible.min(by: { $0.frame.minX < $1.frame.minX }) else { return nil }
        return max(0, screenMaxX - leftmost.frame.minX + 1)
    }

    /// Временный показ спрятанного значка (за разделителем или под вырезом): левее какого видимого значка его
    /// поставить, **не сворачивая разделитель**. Вставка левее цели T занимает [T.minX − ширина, T.minX] и сдвигает
    /// всё левее T влево; значок виден, если этот отрезок правее выреза (`leftLimit` — правый край выреза или левый
    /// край свободной части строки). Берём самый левый подходящий подвижный значок (меньше всего сдвигаем строку);
    /// не подошёл ни один (строка забита) — самый правый подвижный: значок встанет у часов, под вырез уйдёт крайний
    /// левый. Прежний способ (15.11, «Не вышло показать eqMac») сворачивал разделитель — спрятанные вставали в строку,
    /// не влезали и уходили под вырез, а значок под вырезом уже нельзя было перетащить из-под острова.
    public static func showTarget(for item: MenuBarItem, in inv: MenuBarInventory, leftLimit: CGFloat?) -> MenuBarItem? {
        let candidates = inv.items
            .filter { $0.section == .visible && $0.isMovable && $0.windowID != item.windowID }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let rightmost = candidates.last else { return nil }
        guard let limit = leftLimit else { return candidates.first }
        let w = item.frame.width
        return candidates.first { $0.frame.minX - w >= limit + 2 } ?? rightmost
    }
}

// MARK: - Разделитель (по Hidden Bar, MIT — см. THIRD_PARTY.md)

public enum MenuBarDividerMath {
    /// Длина развёрнутого разделителя: вдвое шире самого широкого экрана, но не меньше 500 и не больше 10000 pt
    /// (больше система не принимает). Значки левее уходят за край строки.
    public static func expandedLength(screenWidths: [CGFloat]) -> CGFloat {
        let widest = screenWidths.max() ?? 0
        return max(500, min(widest * 2, 10000))
    }
    /// macOS 27: длина развёрнутого разделителя — от его правого края (`rightEdge`, CG) до правого края выреза
    /// (`leftLimit`) с запасом 50 pt на кнопку overflow системы, не больше «половина экрана − 20» (длиннее система
    /// отбрасывает элемент: 849 pt на экране 1728 — не рисуется, измерено 20.11) и не меньше 60.
    /// Без выреза — левый край неизвестен (меню приложения): берём предел.
    public static func agentLength(rightEdge: CGFloat?, leftLimit: CGFloat?, screenWidth: CGFloat) -> CGFloat {
        let cap = max(60, screenWidth / 2 - 20)
        guard let r = rightEdge, let l = leftLimit else { return cap }
        return min(cap, max(60, r - 8 - (l + 50)))
    }
    /// macOS 27, несколько экранов: «половина самого узкого экрана − 20» — элемент шире половины экрана система не рисует
    /// (на 1728 — 844, окно 860; на LG 1920 при этом разделитель виден и прячет левее себя — измерено 27.11).
    public static func agentMultiScreenLength(screenWidths: [CGFloat]) -> CGFloat {
        max(60, (screenWidths.min() ?? 1440) / 2 - 20)
    }
    /// Свёрнутый: тонкая черта, видна только пока идёт перенос или временный показ.
    public static let collapsedLength: CGFloat = 12
}

// MARK: - Карточка подтверждения

/// Вариант в карточке «<Значок> — что сделать?».
public enum CleanupOption: Equatable, Sendable {
    case toIsland
    case hide
    case quit
    /// Открыть раздел Системных настроек, где значок выключается (Пункт управления, клавиатура).
    case systemSettings(MenuBarSettingsPane)

    public var title: String {
        switch self {
        case .toIsland: return "Убрать в остров"
        case .hide: return "Спрятать совсем"
        case .quit: return "Выйти из приложения"
        case .systemSettings(let p): return p.actionTitle
        }
    }
    public var symbol: String {
        switch self {
        case .toIsland: return "tray.and.arrow.down"
        case .hide: return "eye.slash"
        case .quit: return "power"
        case .systemSettings: return "switch.2"
        }
    }
    public var isDestructive: Bool { self == .quit }
    /// Нужен перенос значка (синтетическое ⌘-перетаскивание → Универсальный доступ).
    public var needsMove: Bool { self == .toIsland || self == .hide }
}

/// Раздел Системных настроек, где выключается системный значок.
public enum MenuBarSettingsPane: String, Equatable, Sendable {
    case controlCenter, keyboard

    public var url: URL {
        switch self {
        case .controlCenter: return URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
        case .keyboard: return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        }
    }
    public var actionTitle: String {
        switch self {
        case .controlCenter: return "Выключить в Пункте управления"
        case .keyboard: return "Выключить в настройках клавиатуры"
        }
    }
}

/// Что показать в карточке.
public struct CleanupCard: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var options: [CleanupOption]
    public var details: [String]
    /// Галочка «Помнить после перезапуска <App>» (только для стороннего приложения).
    public var showsRemember: Bool
    /// Пояснение, почему вариантов мало (часы, Пункт управления).
    public var note: String?

    /// Построить карточку для значка. `axGranted` — есть ли Универсальный доступ (без него перенос не работает —
    /// варианты остаются, но с пометкой; выбор запросит право).
    public static func make(for item: MenuBarItem, axGranted: Bool) -> CleanupCard {
        let name = item.displayName
        var options: [CleanupOption] = []
        var details: [String] = []
        let needAX = axGranted ? nil : "нужен Универсальный доступ"
        if item.isMovable {
            options.append(.toIsland)
            details.append(needAX ?? (item.isSystem ? "\(name) будет виден в «Значках»" : "значок будет во вкладке «Значки»"))
        }
        let pane = settingsPane(item)
        if let pane, item.isMovable {
            options.append(.systemSettings(pane))
            details.append(pane == .keyboard ? "значок раскладки уйдёт, раскладки работают" : "значок уйдёт, \(name) работает")
        }
        if item.isMovable {
            options.append(.hide)
            details.append(needAX ?? (item.isSystem ? "вернуть — в настройках" : "не видно нигде, вернуть — в настройках"))
        }
        if item.canQuit {
            options.append(.quit)
            details.append("\(name) закроется, значок пропадёт")
        }
        var note: String?
        if item.isSystemIndicator {
            options = [.systemSettings(.controlCenter)]
            details = ["там видно, что он показывает"]
            note = "macOS сама показывает этот индикатор, пока он нужен, — спрятать его нельзя"
        } else if !item.isMovable {
            options = [.systemSettings(.controlCenter)]
            details = ["часы и Пункт управления настраиваются там"]
            note = "macOS не даёт двигать этот значок"
        }
        let subtitle: String
        switch item.kind {
        case .app: subtitle = item.section == .notch ? "значок прятался под вырезом" : "приложение работает"
        case .controlCenter, .system: subtitle = "системный значок macOS"
        }
        return CleanupCard(title: "\(name) — что сделать?", subtitle: subtitle, options: options, details: details,
                           showsRemember: item.canQuit && item.isMovable, note: note)
    }

    static func settingsPane(_ item: MenuBarItem) -> MenuBarSettingsPane? {
        switch item.kind {
        case .app: return nil
        case .controlCenter: return .controlCenter
        case .system(let s): return s == "TextInput" ? .keyboard : .controlCenter
        }
    }
}

// MARK: - Клавиши режима уборки

/// Состояние режима уборки: что под курсором/выбрано, открыта ли карточка, какой вариант выделен.
public struct CleanupState: Equatable, Sendable {
    public var hoveredKey: String?
    /// Карточка открыта для этого значка.
    public var selectedKey: String?
    public var optionIndex = 0
    /// Второй шаг «Выйти из <App>?».
    public var confirmingQuit = false
    public var remember = true

    public init() {}
    public var cardOpen: Bool { selectedKey != nil }
}

public enum CleanupKey: Equatable, Sendable { case escape, enter, up, down, left, right, tab, space }

/// Тексты с числами.
public enum MenuBarText {
    /// 1 значок, 2 значка, 5 значков, 11 значков, 21 значок.
    public static func icons(_ n: Int) -> String { "\(n) " + plural(n, "значок", "значка", "значков") }
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }
}

/// Что сделать по клавише.
public enum CleanupCommand: Equatable, Sendable {
    case none
    /// Выйти из режима уборки без изменений.
    case exit
    /// Выполнить вариант для значка.
    case perform(key: String, option: CleanupOption, remember: Bool)
}

public enum CleanupKeys {
    /// Автоповтор зажатой клавиши разрешён только для навигации; ⏎/Space/Esc — только новое нажатие.
    public static func repeatable(_ k: CleanupKey) -> Bool { [.up, .down, .left, .right, .tab].contains(k) }

    /// Код клавиши (kVK_*) → клавиша режима.
    public static func key(forKeyCode code: UInt16) -> CleanupKey? {
        switch code {
        case 53: return .escape
        case 36, 76: return .enter
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 48: return .tab
        case 49: return .space
        default: return nil
        }
    }

    /// Обработать клавишу. `order` — ключи значков слева направо (для ←/→ и Tab без открытой карточки),
    /// `card` — карточка выбранного значка.
    public static func handle(_ key: CleanupKey, state: inout CleanupState, order: [String],
                              card: (String) -> CleanupCard?) -> CleanupCommand {
        if let sel = state.selectedKey, let c = card(sel) {
            let n = c.options.count
            if state.confirmingQuit {
                switch key {
                case .enter: state.confirmingQuit = false; state.selectedKey = nil; state.optionIndex = 0
                    return .perform(key: sel, option: .quit, remember: state.remember)
                case .escape: state.confirmingQuit = false
                default: break
                }
                return .none
            }
            switch key {
            case .escape:
                state.selectedKey = nil; state.optionIndex = 0
            case .up: state.optionIndex = max(0, state.optionIndex - 1)
            case .down: state.optionIndex = min(n - 1, state.optionIndex + 1)
            case .tab: state.optionIndex = n > 0 ? (state.optionIndex + 1) % n : 0
            case .space: if c.showsRemember { state.remember.toggle() }
            case .left, .right:
                // Соседний значок — карточка переезжает к нему.
                if let next = neighbour(of: sel, in: order, forward: key == .right) {
                    state.selectedKey = next; state.optionIndex = 0; state.hoveredKey = next
                }
            case .enter:
                guard n > 0 else { return .none }
                let opt = c.options[min(state.optionIndex, n - 1)]
                if opt == .quit { state.confirmingQuit = true; return .none }
                state.selectedKey = nil; state.optionIndex = 0
                return .perform(key: sel, option: opt, remember: state.remember)
            }
            return .none
        }
        switch key {
        case .escape: return .exit
        case .left, .right, .tab:
            let start = state.hoveredKey
            let next = start.flatMap { neighbour(of: $0, in: order, forward: key != .left) }
                ?? (key == .left ? order.last : order.first)
            state.hoveredKey = next
        case .enter, .space, .down:
            if let h = state.hoveredKey ?? order.last {
                state.selectedKey = h; state.optionIndex = 0; state.confirmingQuit = false; state.remember = true
            }
        case .up: break
        }
        return .none
    }

    static func neighbour(of key: String, in order: [String], forward: Bool) -> String? {
        guard let i = order.firstIndex(of: key) else { return nil }
        let j = forward ? i + 1 : i - 1
        return order.indices.contains(j) ? order[j] : nil
    }

    /// Щелчок по значку: открыть карточку (по второму щелчку того же — закрыть).
    public static func click(_ key: String, state: inout CleanupState) {
        if state.selectedKey == key { state.selectedKey = nil; state.optionIndex = 0; return }
        state.selectedKey = key; state.hoveredKey = key; state.optionIndex = 0
        state.confirmingQuit = false; state.remember = true
    }
}
