import Foundation
import SwiftUI

/// С какой стороны выреза стоит вкладка в раскрытом острове (16.11: «разделение на слева / справа»).
public enum TabSide: String, LenientStringEnum, Sendable {
    case left, right
    public static let fallback = TabSide.left
    public var title: String { self == .left ? "Слева от выреза" : "Справа от выреза" }
    public var other: TabSide { self == .left ? .right : .left }
}

/// Вкладка раскрытого острова: id модуля, включена ли и с какой стороны выреза. Порядок массива = порядок вкладок
/// (внутри стороны — порядок слева направо). Старые settings.json без `side` читаются как «слева» — так вкладки
/// и шли раньше: сначала слева от выреза.
public struct TabSetting: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var enabled: Bool
    public var side: TabSide
    /// Прочитана из старого settings.json без `side` (в файл не пишется): сторону расставит
    /// `SettingsData.migrateLegacyTabSides` так, как вкладки стояли раньше.
    public var sideIsLegacy = false
    public init(id: String, enabled: Bool, side: TabSide = .left) {
        self.id = id; self.enabled = enabled; self.side = side
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(enabled, forKey: .enabled); try c.encode(side, forKey: .side)
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, side }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let raw = try? c.decodeIfPresent(TabSide.self, forKey: .side)
        side = raw ?? .left
        sideIsLegacy = !c.contains(.side)
    }
}

/// Перестановки вкладок по сторонам (общие для настроек, каталога и самотестов). Порядок вкладки внутри стороны —
/// её порядок в общем массиве.
public enum TabArrangement {
    /// Вкладки стороны по порядку.
    public static func tabs(_ tabs: [TabSetting], on side: TabSide) -> [TabSetting] {
        tabs.filter { $0.side == side }
    }

    /// Перетаскивание на строку `target`: вкладка встаёт на её место и на её сторону (внутри секции вверх — перед
    /// ней, вниз — после неё, как обычно при перетаскивании в списке; из другой секции — перед ней). Неизвестные
    /// id — ничего.
    public static func move(_ tabs: inout [TabSetting], id: String, before target: String) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        var item = tabs.remove(at: from)
        let targetSide = tabs[to > from ? to - 1 : to].side
        // Из другой секции — всегда перед строкой (иначе вкладка из левой, брошенная на первую правую, встала бы
        // второй).
        let at = item.side != targetSide ? (tabs.firstIndex(where: { $0.id == target }) ?? to) : to
        item.side = targetSide
        tabs.insert(item, at: at)
    }

    /// Перенести вкладку в конец стороны `side` (бросок на заголовок / пустую секцию, кнопка-стрелка).
    public static func moveToEnd(_ tabs: inout [TabSetting], id: String, side: TabSide) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        var item = tabs.remove(at: from)
        item.side = side
        let to = (tabs.lastIndex(where: { $0.side == side }).map { $0 + 1 }) ?? (side == .left ? 0 : tabs.count)
        tabs.insert(item, at: to)
    }

    /// Перенести на другую сторону: налево — в конец левой (ближе к вырезу), направо — в начало правой
    /// (тоже ближе к вырезу): вкладка «перешагивает» вырез и оказывается рядом.
    public static func flip(_ tabs: inout [TabSetting], id: String) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let side = tabs[from].side.other
        if side == .left { moveToEnd(&tabs, id: id, side: .left); return }
        var item = tabs.remove(at: from)
        item.side = .right
        let to = tabs.firstIndex(where: { $0.side == .right }) ?? tabs.count
        tabs.insert(item, at: to)
    }

    /// Поднять/опустить вкладку внутри её стороны (контекстное меню «Выше/Ниже»).
    public static func step(_ tabs: inout [TabSetting], id: String, by delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let side = tabs[i].side
        let same = tabs.indices.filter { tabs[$0].side == side }
        guard let k = same.firstIndex(of: i), same.indices.contains(k + delta) else { return }
        tabs.swapAt(i, same[k + delta])
    }

    /// Новая вкладка на острове (каталог «Добавить»): в конец левой стороны, если там есть место, иначе — в конец
    /// правой. `leftHasRoom(n)` — влезет ли слева ещё одна вкладка при `n` уже включённых там.
    public static func placeNew(_ tabs: inout [TabSetting], id: String, leftHasRoom: (Int) -> Bool) {
        if !tabs.contains(where: { $0.id == id }) { tabs.append(TabSetting(id: id, enabled: false)) }
        let onLeft = tabs.filter { $0.side == .left && $0.enabled && $0.id != id }.count
        moveToEnd(&tabs, id: id, side: leftHasRoom(onLeft) ? .left : .right)
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].enabled = true }
    }
}

/// Стиль полосы HUD (макет 06-hud, нижний ряд).
public enum HUDBarStyle: String, LenientStringEnum, Sendable {
    case thread, segments, fill, number
    public static let fallback = HUDBarStyle.thread
    public var title: String {
        switch self {
        case .thread: return "Нить"
        case .segments: return "Сегменты"
        case .fill: return "Заливка"
        case .number: return "Цифра"
        }
    }
}

/// Глобальная горячая клавиша. `keyCode` — виртуальный код клавиши (kVK_*), `modifiers` — маска Carbon
/// (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000), `keyLabel` — подпись клавиши («Space», «K»).
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyLabel: String
    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    /// ⌃⌥Space.
    public static let defaultToggle = HotKeySpec(keyCode: 49, modifiers: 0x1000 | 0x0800, keyLabel: "Space")
    /// «⌃⌥⇧⌘Space» — порядок символов как в меню macOS.
    public var displayString: String {
        var s = ""
        if modifiers & 0x1000 != 0 { s += "⌃" }
        if modifiers & 0x0800 != 0 { s += "⌥" }
        if modifiers & 0x0200 != 0 { s += "⇧" }
        if modifiers & 0x0100 != 0 { s += "⌘" }
        return s + keyLabel
    }
}

/// Все настройки приложения — простая структура, хранится JSON-ом.
/// Отсутствующие в файле поля берутся из значений по умолчанию ниже.
public struct SettingsData: Codable, Equatable, Sendable {
    public var themeId = "obsidian"
    /// Порядок, включённость и сторона выреза вкладок. Сверяется со списком модулей при старте (`reconcileTabs`).
    public var tabs: [TabSetting] = []

    // Форма и физика. nil — брать из темы.
    public var expandedWidth: Double = 720
    public var cornerRadius: Double?
    public var earRadius: Double?
    public var compactCornerRadius: Double?
    public var springResponse: Double?
    public var springDamping: Double?

    // Поведение
    /// Через сколько секунд после наведения остров «набухает».
    public var hoverDelay: Double = 0.12
    /// Через сколько секунд после ухода курсора остров сворачивается.
    public var collapseDelay: Double = 0.4
    /// Множитель свечения под островом (0 — выключено).
    public var glowIntensity: Double = 1
    public var hudStyle: HUDBarStyle = .thread
    public var hudDuration: Double = 1.2

    // Правила
    public var hideInFullscreen = true
    /// В полноэкранном (остров спрятан) карточка «нужен ответ» (без срока, с кнопками — напр. разрешение агента)
    /// всё же показывает остров на время карточки. Вспышки HUD и обычные уведомления там не видны.
    public var showCriticalInFullscreen = true
    /// В полноэкранном (остров спрятан) — цветная точка у нижнего края выреза, когда есть событие: оранжевая — агент
    /// спрашивает, красная — ошибка / Vafa, синяя — важное уведомление, зелёная — агент закончил. Клик — остров.
    public var fullscreenDot = true
    /// Прятать остров из записи/демонстрации экрана (окно исключается из захвата).
    public var hideWhileScreenSharing = false
    /// На экранах без выреза — плавающая капля по центру сверху.
    public var floatingOnNotchlessScreens = true
    /// Показывать на всех мониторах, а не только на основном (с вырезом).
    public var allScreens = false
    /// Автозапуск включался сам при первом запуске (27.11): дальше решает переключатель «Запускать при входе».
    public var launchAtLoginAsked = false
    /// SimpleIsland на паузе (скрыт).
    public var paused = false
    /// На батарее — без анимаций по времени (бегущая рамка, эквалайзер), как при «Уменьшить движение».
    public var reduceMotionOnBattery = false

    /// Настройки модулей: moduleId → произвольный JSON. Модули пишут сюда через ModuleContext.
    public var moduleSettings: [String: JSONValue] = [:]

    // --- settings: окно настроек и первый запуск ---
    /// Какой модуль рисует левое/правое ухо компакта (его активность, если она есть). nil — как у главной активности.
    public var leftEarModule: String?
    public var rightEarModule: String?
    /// Глобальная горячая клавиша «раскрыть/свернуть» (Carbon RegisterEventHotKey — без Универсального доступа).
    public var toggleHotKey: HotKeySpec = .defaultToggle
    public var toggleHotKeyEnabled = true
    /// Свайп двумя пальцами по острову (трекпад) и щелчок колеса мыши раскрывают/сворачивают.
    public var swipeGestures = true
    public var wheelGestures = true
    /// Пока остров раскрыт, первый клик мимо него только сворачивает остров и никуда не проходит (ловушка кликов).
    public var clickAwayOnlyCollapses = true
    /// Онбординг первого запуска пройден (или пропущен).
    public var onboardingCompleted = false

    public init() {}

    /// Тема с поправками формы и физики из настроек.
    public func applying(to theme: Theme) -> Theme {
        var t = theme
        if let v = cornerRadius { t.shape.cornerRadius = v }
        if let v = earRadius { t.shape.earRadius = v }
        if let v = compactCornerRadius { t.shape.compactCornerRadius = v }
        if let v = springResponse { t.spring.response = v }
        if let v = springDamping { t.spring.damping = v }
        return t
    }

    /// Миграция старого settings.json (вкладки без `side`): как раньше — вкладки по порядку слева, пока влезают
    /// (`leftCount` из прежней раскладки: столько включённых стояло слева от выреза), остальные справа. Выключенные
    /// получают сторону по месту в списке (после первой «правой» — справа), так порядок и стороны не расходятся.
    /// Ничего не делает, если старых вкладок нет. Возвращает, была ли миграция.
    @discardableResult
    public mutating func migrateLegacyTabSides(leftCount: ([String]) -> Int) -> Bool {
        guard tabs.contains(where: \.sideIsLegacy) else { return false }
        let enabled = tabs.filter(\.enabled).map(\.id)
        let n = leftCount(enabled)
        var seen = 0
        var right = false
        for i in tabs.indices {
            if tabs[i].enabled { if seen >= n { right = true }; seen += 1 }
            if tabs[i].sideIsLegacy { tabs[i].side = right ? .right : .left }
            tabs[i].sideIsLegacy = false
        }
        return true
    }

    /// Сверить вкладки со списком модулей: сохранить порядок, добавить новые, убрать исчезнувшие.
    public mutating func reconcileTabs(_ available: [(id: String, enabledByDefault: Bool)]) {
        let ids = Set(available.map(\.id))
        var result = tabs.filter { ids.contains($0.id) }
        for m in available where !result.contains(where: { $0.id == m.id }) {
            result.append(TabSetting(id: m.id, enabled: m.enabledByDefault))
        }
        tabs = result
    }
}

/// Наблюдаемая обёртка над `SettingsData` с автосохранением (через 0,5 с после последней правки).
/// Доступ: `settings.data.hoverDelay`, привязки в SwiftUI: `$settings.data.hoverDelay`.
@MainActor
public final class SimpleIslandSettings: ObservableObject {
    @Published public var data: SettingsData {
        didSet { if data != oldValue { scheduleSave() } }
    }

    public let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    /// `fileURL == nil` — только в памяти (режим снимков, тесты).
    public init(fileURL: URL? = SimpleIslandPaths.settingsFile) {
        self.fileURL = fileURL
        if let url = fileURL, let raw = try? Data(contentsOf: url),
           let d = try? MergedJSON.decode(SettingsData.self, from: raw, base: SettingsData()) {
            data = d
        } else {
            data = SettingsData()
        }
    }

    public init(inMemory data: SettingsData) {
        self.fileURL = nil
        self.data = data
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    public func saveNow() {
        guard let url = fileURL else { return }
        saveWork?.cancel()
        saveWork = nil
        do {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try e.encode(data)
            // Те же байты — файл не трогать (выход без правок не меняет время settings.json).
            if let old = try? Data(contentsOf: url), old == encoded { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: url, options: .atomic)
        } catch {
            NSLog("SimpleIsland: не удалось сохранить настройки: \(error)")
        }
    }

    // MARK: Настройки модулей

    public func moduleValue<T: Decodable>(_ type: T.Type, for moduleId: String) -> T? {
        guard let v = data.moduleSettings[moduleId] else { return nil }
        return try? v.decode(T.self)
    }

    public func setModuleValue<T: Encodable>(_ value: T, for moduleId: String) {
        guard let v = try? JSONValue.from(value) else { return }
        data.moduleSettings[moduleId] = v
    }
}
