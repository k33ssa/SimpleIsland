import Foundation
import SwiftUI

/// Модуль острова. Каждый модуль — отдельный SwiftPM-таргет, зависит только от IslandCore,
/// регистрируется одной строкой в `Sources/SimpleIsland/ModuleRegistry.swift`. Подробно — docs/ARCHITECTURE.md.
@MainActor
public protocol IslandModule: AnyObject {
    /// Латиница, стабильный: ключ вкладки и настроек ("media", "hud", "shelf", "agents", "today").
    var id: String { get }
    /// Русское имя вкладки/раздела настроек.
    var title: String { get }
    /// SF Symbol для вкладки.
    var systemImage: String { get }
    /// Есть ли у модуля вкладка в раскрытом острове (HUD — нет).
    var providesTab: Bool { get }
    var tabEnabledByDefault: Bool { get }
    /// Высота области контента раскрытого острова под верхней строкой, pt. Может меняться на ходу
    /// (напр. под diff) — тогда позвать `context.invalidateLayout()`.
    var expandedHeight: CGFloat { get }
    /// Принимает ли модуль файлы, брошенные на остров (Полка). Тащат файлы над островом → остров раскрывается
    /// на вкладке такого модуля; бросок в любом месте острова (и в компакте) уходит в `handleDrop`.
    var acceptsFileDrops: Bool { get }

    /// Запуск: подписаться на события, начать слушать. Не опрашивать таймерами чаще раза в секунду.
    func start(context: ModuleContext)
    /// Остановка: снять подписки, убрать свои активности.
    func stop()
    /// Содержимое вкладки (под верхней строкой). nil — плейсхолдер.
    func expandedView() -> AnyView?
    /// Раздел модуля в окне настроек. nil — «пока нечего настраивать».
    func settingsView() -> AnyView?
    /// Мок-состояния для `SimpleIsland --snapshot`. Каждое — PNG `<тема>-<id>-<name>.png`.
    func snapshotStates() -> [ModuleSnapshot]
    /// Файлы брошены на остров. true — приняты. Зовётся, только если `acceptsFileDrops`
    /// и вьюха вкладки сама не перехватила бросок своим `.onDrop`.
    func handleDrop(_ urls: [URL]) -> Bool
    // --- shelfbar ---
    /// Папка приёма для броска без готового файла (обещание файла — миниатюра снимка экрана, вложение Почты;
    /// сырая картинка из браузера): ядро кладёт туда файлы (`DragPasteboard.receive`) и отдаёт их в `handleDrop`.
    /// Модуль сам решает, когда их убрать. По умолчанию — `Application Support/SimpleIsland/Incoming`.
    var dropIncomingDirectory: URL { get }
    // --- /shelfbar ---
    // --- agents2 ---
    /// Правый верх верхней строки раскрытого острова, пока открыта вкладка модуля (сводка «2 работают · 1 ждёт»,
    /// макет 05). Ядро ставит её с приоритетом раскладки 1: она получает то, что осталось в правом ухе после кнопок,
    /// и должна уметь сжиматься (короткий вариант через `ViewThatFits`, обрезка). Во время HUD-вспышки не
    /// показывается. nil — ничего.
    func headerTrailingView() -> AnyView?
}

public extension IslandModule {
    var providesTab: Bool { true }
    var tabEnabledByDefault: Bool { true }
    var expandedHeight: CGFloat { 180 }
    var acceptsFileDrops: Bool { false }
    func handleDrop(_ urls: [URL]) -> Bool { false }
    var dropIncomingDirectory: URL { SimpleIslandPaths.appSupport.appendingPathComponent("Incoming", isDirectory: true) }   // --- shelfbar ---
    func stop() {}
    func expandedView() -> AnyView? { nil }
    func settingsView() -> AnyView? { nil }
    func snapshotStates() -> [ModuleSnapshot] { [] }
    // --- agents2 ---
    func headerTrailingView() -> AnyView? { nil }
}

/// Мок-состояние модуля для снимков.
public struct ModuleSnapshot {
    public enum Presentation: Sendable {
        /// Компакт (активности, что модуль запостил в `apply`).
        case compact
        /// Раскрытый остров на вкладке модуля.
        case expanded
        /// Как получится из центров (HUD / уведомление / компакт / покой).
        case automatic
    }
    public var name: String
    public var presentation: Presentation
    /// Подготовить состояние: запостить активности/HUD/уведомление, выставить мок-данные модуля.
    /// Модуль при этом НЕ запущен (`start` не вызывался) — не трогать систему.
    public var apply: @MainActor (ModuleContext) -> Void

    public init(_ name: String, presentation: Presentation = .automatic,
                apply: @escaping @MainActor (ModuleContext) -> Void = { _ in }) {
        self.name = name; self.presentation = presentation; self.apply = apply
    }
}

/// Всё, что модуль получает от приложения. Тема для вьюх — `@Environment(\.islandTheme)`.
@MainActor
public final class ModuleContext {
    public let moduleId: String
    public let settings: SimpleIslandSettings
    public let themes: ThemeStore
    public let activities: ActivityCenter
    public let hud: HUDCenter
    public let notifications: IslandNotifications
    /// Что показывает остров, открыта ли вкладка модуля, тащат ли файлы. Только чтение.
    public let island: IslandStateCenter
    /// true — рендер снимков: ничего не запускать, данные мок.
    public let isSnapshot: Bool
    private let openTabHandler: @MainActor (String?) -> Void
    private let layoutHandler: @MainActor () -> Void

    public init(moduleId: String, settings: SimpleIslandSettings, themes: ThemeStore, activities: ActivityCenter,
                hud: HUDCenter, notifications: IslandNotifications, island: IslandStateCenter,
                isSnapshot: Bool = false,
                openTab: @escaping @MainActor (String?) -> Void,
                invalidateLayout: @escaping @MainActor () -> Void = {}) {
        self.moduleId = moduleId; self.settings = settings; self.themes = themes; self.activities = activities
        self.hud = hud; self.notifications = notifications; self.island = island; self.isSnapshot = isSnapshot
        self.openTabHandler = openTab; self.layoutHandler = invalidateLayout
    }

    /// Видна ли сейчас вкладка этого модуля (остров раскрыт на ней). Для «анимировать только при показе».
    public var isTabVisible: Bool { island.isTabVisible(moduleId) }

    /// `expandedHeight` поменялась — пересчитать размер острова и панели.
    public func invalidateLayout() { layoutHandler() }

    /// Поле ввода в острове: true — панель может стать ключевой и получать клавиатуру; false — отдать обратно.
    /// Без запроса клик по острову клавиатуру у приложения пользователя не забирает.
    public func requestKeyboard(_ wants: Bool = true) { island.setKeyboard(wants, owner: moduleId) }

    /// Текущая тема с поправками из настроек (для не-SwiftUI кода; во вьюхах — Environment).
    public var theme: Theme { settings.data.applying(to: themes.current) }

    /// Раскрыть остров на вкладке (по умолчанию — своей). nil в аргументе обработчика = свернуть.
    public func openTab(_ id: String? = nil) { openTabHandler(id ?? moduleId) }
    public func collapse() { openTabHandler(nil) }

    public func showNotification(_ n: IslandNotification) { notifications.post(n) }

    public func flashHUD(_ e: HUDEvent, duration: TimeInterval? = nil) {
        hud.flash(e, duration: duration ?? settings.data.hudDuration)
    }

    public func post(_ activity: IslandActivity) { activities.post(activity) }
    public func removeActivity(id: String) { activities.remove(id: id) }
    /// «Живая точка» в покое. В покое видна одна — с наибольшим `priority`
    /// (0 — работает, 50 — ждёт тебя, 100 — ошибка). nil — снять.
    public func setStatusDot(_ color: Color?, priority: Int = 0) {
        activities.setStatusDot(color, priority: priority, for: moduleId)
    }
    /// Событие для точки у выреза в полноэкранном (остров спрятан): ask — ждёт ответа, error — ошибка, done —
    /// закончил, info — важное уведомление. nil — снять. Ядро гасит его само, когда пользователь его увидел (клик по
    /// точке, открыл вкладку модуля). Ставить на смену состояния, а не на каждое обновление.
    public func setAttention(_ kind: AttentionKind?, text: String = "", opensTab: String? = nil) {
        activities.setAttention(kind, text: text, opensTab: opensTab, for: moduleId)
    }
    /// Свечение под островом без активности (напр. цвет обложки), своё у каждого модуля. nil — снять.
    /// Видно в раскрытом острове на вкладке модуля и в компакте, если главная активность — этого модуля.
    public func setGlow(_ colors: [Color]?) { activities.setAmbientGlow(colors, for: moduleId) }
    // --- media2 ---
    /// Цвета обложки играющего — для фона темы с `background.source = artwork` («Хамелеон»). Не свечение: фон
    /// красится только этим каналом. nil — обложки нет (фон темы обычный). Снимается и при остановке модуля.
    public func setArtworkColors(_ colors: [Color]?) { activities.setArtworkColors(colors, for: moduleId) }
    // --- /media2 ---

    // MARK: Настройки модуля (лежат в settings.json → moduleSettings[moduleId])

    public func loadSettings<T: Decodable>(_ type: T.Type) -> T? {
        settings.moduleValue(T.self, for: moduleId)
    }

    public func saveSettings<T: Encodable>(_ value: T) {
        settings.setModuleValue(value, for: moduleId)
    }
}
