import Foundation

// --- catalog --- мост «открыть каталог виджетов» для модулей: каталог живёт в приложении (Sources/SimpleIsland),
// модуль о нём не знает — шлёт уведомление, окно каталога его ловит (WidgetCatalogWindow.swift).

public extension Notification.Name {
    /// Открыть каталог виджетов. `object` — id карточки (напр. "vafa"), или nil: каталог откроется на её
    /// категории и подсветит её рамкой акцента (до смены категории или поиска).
    static let simpleIslandOpenWidgetCatalog = Notification.Name("SimpleIsland.openWidgetCatalog")
}

public extension ModuleContext {
    /// Открыть каталог виджетов. Остров не сворачивается — перед вызовом `collapse()`, если нужно.
    /// `focus` — id карточки: каталог откроется на её категории и подсветит её.
    func openWidgetCatalog(focus: String? = nil) {
        NotificationCenter.default.post(name: .simpleIslandOpenWidgetCatalog, object: focus)
    }
}
