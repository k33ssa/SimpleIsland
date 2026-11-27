import Foundation

// --- shelfbar ---
// Удержание острова «в покое» на время, когда он мешает модулю. Пример — режим уборки строки меню: значки справа от
// выреза начинаются вплотную к нему, и любые уши (компакт, HUD, точка активности, наведение) их закрывают. Пока есть
// удержание, ядро (`IslandModel`) показывает на всех экранах только сам вырез: не раскрывает (клик, свайп, колесо,
// подлетающий файл), не набухает при наведении, не показывает компакт/HUD/уведомления (они не теряются — после
// отпускания остров снова показывает то, что актуально). Раскрытый остров при взятии удержания сворачивается.

public extension ModuleContext {
    /// Держать остров в покое до `releaseCollapsed(token)`. Повторный вызов с тем же токеном ничего не меняет.
    ///
    /// ```swift
    /// context.holdCollapsed("cleanup")     // вход в режим
    /// context.releaseCollapsed("cleanup")  // выход
    /// ```
    func holdCollapsed(_ token: String = "calm") {
        island.holdCollapsed("\(moduleId).\(token)")
    }

    /// Отпустить удержание покоя.
    func releaseCollapsed(_ token: String = "calm") {
        island.releaseCollapsed("\(moduleId).\(token)")
    }

    /// Снять все удержания покоя модуля (из `stop()`).
    func releaseAllCollapseHolds() {
        island.releaseCollapseHolds(prefix: "\(moduleId).")
    }

    /// Держит ли кто-то остров в покое.
    var isCollapseHeld: Bool { island.isCollapseHeld }
}
// --- /shelfbar ---
