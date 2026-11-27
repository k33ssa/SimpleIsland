import AppKit
import Combine
import SwiftUI
import IslandCore

/// Общие объекты приложения: настройки, темы, центры, модули и их контексты.
/// Один на процесс (в режиме снимков — свежий на каждый снимок).
@MainActor
final class AppEnvironment {
    let settings: SimpleIslandSettings
    let themes: ThemeStore
    let activities = ActivityCenter()
    let hud = HUDCenter()
    let notifications = IslandNotifications()
    let island = IslandStateCenter()
    /// Модуль сказал «моя высота поменялась» (`invalidateLayout`) — острова пересчитывают размеры и панель.
    let layoutChanged = PassthroughSubject<Void, Never>()
    let modules: [IslandModule]
    let isSnapshot: Bool
    private(set) var contexts: [String: ModuleContext] = [:]

    /// Кто раскрывает остров по просьбе модуля (nil — свернуть). Ставит AppDelegate.
    var openTabHandler: (String?) -> Void = { _ in }

    private var bag = Set<AnyCancellable>()

    init(settings: SimpleIslandSettings, themes: ThemeStore, modules: [IslandModule], isSnapshot: Bool = false) {
        self.settings = settings
        self.themes = themes
        self.modules = modules
        self.isSnapshot = isSnapshot
        settings.data.reconcileTabs(modules.filter(\.providesTab).map { ($0.id, $0.tabEnabledByDefault) })
        // Старый settings.json без сторон вкладок — что раньше уезжало направо от выреза, встаёт справа (16.11).
        let gap = isSnapshot ? IslandGeometry.mockNotch.notchWidth : SettingsPreviewHolder.realNotch().notchWidth
        let width = CGFloat(settings.data.expandedWidth)
        settings.data.migrateLegacyTabSides { ids in
            let caps = TabBarLayout.capacities(width: width, gap: gap)
            let title = ids.first.flatMap { id in modules.first { $0.id == id }?.title } ?? ""
            return TabBarLayout.legacyLeftCount(ids: ids, selectedWidths: TabBarLayout.selectedWidths(title: title),
                                                left: caps.left, right: caps.right)
        }
        themes.select(settings.data.themeId)
        hud.defaultDuration = settings.data.hudDuration
        settings.$data
            .map(\.themeId)
            .removeDuplicates()
            .sink { [weak themes] id in themes?.select(id) }
            .store(in: &bag)
        settings.$data
            .map(\.hudDuration)
            .removeDuplicates()
            .sink { [weak hud] d in hud?.defaultDuration = d }
            .store(in: &bag)
        // Раскрытый остров: карточки уведомлений ждут сворачивания, их таймер стоит.
        island.$expandedTab
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak notifications] expanded in notifications?.setSuspended(expanded) }
            .store(in: &bag)
        for m in modules { contexts[m.id] = makeContext(for: m.id) }
    }

    func makeContext(for moduleId: String) -> ModuleContext {
        ModuleContext(moduleId: moduleId, settings: settings, themes: themes, activities: activities,
                      hud: hud, notifications: notifications, island: island, isSnapshot: isSnapshot,
                      openTab: { [weak self] id in self?.openTabHandler(id) },
                      invalidateLayout: { [weak self] in self?.layoutChanged.send() })
    }

    /// Кому отдать брошенные файлы: открытой вкладке, если она их принимает, иначе первому принимающему модулю.
    func dropModule(preferring tab: String?) -> IslandModule? {
        if let tab, let m = module(id: tab), m.acceptsFileDrops { return m }
        let enabled = Set(settings.data.tabs.filter(\.enabled).map(\.id))
        return modules.first { $0.acceptsFileDrops && (!$0.providesTab || enabled.contains($0.id)) }
    }

    /// Самая высокая вкладка (для размера панели).
    var maxExpandedHeight: CGFloat {
        modules.filter(\.providesTab).map(\.expandedHeight).max() ?? 200
    }

    /// Тема с поправками формы/физики из настроек.
    var theme: Theme { settings.data.applying(to: themes.current) }

    func module(id: String) -> IslandModule? { modules.first { $0.id == id } }

    /// Модули вкладок в порядке настроек (только включённые).
    var enabledTabModules: [IslandModule] {
        settings.data.tabs.filter(\.enabled).compactMap { t in
            modules.first { $0.id == t.id && $0.providesTab }
        }
    }

    func startModules() {
        for m in modules { if let c = contexts[m.id] { m.start(context: c) } }
    }

    func stopModules() {
        for m in modules {
            m.stop()
            // Подписки модуля на системные события (`context.onSystemEvent`) снимаем за него.
            SystemStateCenter.shared.removeHandlers(owner: m.id)
        }
    }
}
