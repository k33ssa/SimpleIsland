import Foundation

// --- misc2 ---
// Удержание раскрытого острова, пока у модуля открыто своё меню (NSMenu «Действия», NSSharingServicePicker
// «Поделиться»). Без этого курсор уходит на меню → остров сворачивается через `collapseDelay` → пропадает плитка,
// к которой привязано меню. Ядро (`IslandModel.pointer(inside: false)`) не сворачивает, пока есть удержание, и
// сворачивает после отпускания, если курсор так и не вернулся. Держится только остров, открытый на вкладке этого
// модуля (`IslandStateCenter.isExpandHeld(by:)`): остров на другом мониторе на другой вкладке сворачивается как
// обычно. Явное сворачивание (клик по острову, свайп, сон, полноэкранное приложение) удержание не останавливает.

public extension ModuleContext {
    /// Держать остров раскрытым до `releaseExpanded(token)`. Страховка: удержание снимается само через `timeout`
    /// секунд (меню забыли закрыть, делегат не ответил). Повторный вызов с тем же токеном продлевает срок.
    ///
    /// ```swift
    /// context.holdExpanded("actions")
    /// menu.popUp(positioning: nil, at: p, in: view)      // ждёт закрытия меню
    /// context.releaseExpanded("actions")
    /// ```
    func holdExpanded(_ token: String = "menu", timeout: TimeInterval = 120) {
        let key = "\(moduleId).\(token)"
        island.holdExpanded(key)
        ExpandHoldTimers.items[key]?.cancel()
        let w = DispatchWorkItem { [weak island] in
            MainActor.assumeIsolated {
                ExpandHoldTimers.items[key] = nil
                island?.releaseExpanded(key)
            }
        }
        ExpandHoldTimers.items[key] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, timeout), execute: w)
    }

    /// Отпустить удержание (меню закрыто).
    func releaseExpanded(_ token: String = "menu") {
        let key = "\(moduleId).\(token)"
        ExpandHoldTimers.items.removeValue(forKey: key)?.cancel()
        island.releaseExpanded(key)
    }

    /// Снять все удержания модуля (из `stop()`).
    func releaseAllExpandHolds() {
        let prefix = "\(moduleId)."
        for (k, w) in ExpandHoldTimers.items where k.hasPrefix(prefix) {
            w.cancel()
            ExpandHoldTimers.items[k] = nil
        }
        island.releaseExpandHolds(prefix: prefix)
    }

    /// Держит ли кто-то остров раскрытым.
    var isExpandHeld: Bool { island.isExpandHeld }
}

/// Страховочные сроки удержаний: токен → отложенное отпускание.
@MainActor
enum ExpandHoldTimers {
    static var items: [String: DispatchWorkItem] = [:]
}
// --- /misc2 ---
