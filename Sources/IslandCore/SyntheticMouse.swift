import AppKit

/// Свои окна «прозрачны» для мыши, пока модуль шлёт синтетические события (перенос значков строки меню).
///
/// Причина (15.11.2026, жалоба «Не вышло показать eqMac в строке меню», «скрыть системные не работает»): точка
/// события попадала в наши же окна — оверлей уборки (уровень 26, на весь экран) и остров над вырезом (уровень 27,
/// панель сама перестаёт пропускать мышь, когда курсор в её зоне). WindowServer отдавал нажатие нам, а не значку,
/// и ⌘-перенос не случался. На время событий все видимые окна процесса пропускают мышь, остров не переключает
/// `ignoresMouseEvents` по движению курсора (`isActive`), после — всё как было.
@MainActor
public enum SyntheticMouse {
    /// Идут синтетические события: окна острова не должны «ловить» мышь по положению курсора.
    public private(set) static var isActive = false
    private static var saved: [(NSWindow, Bool)] = []

    /// Начать: все видимые окна процесса пропускают мышь. Повторный вызов без `end()` ничего не меняет.
    public static func begin() {
        guard !isActive else { return }
        isActive = true
        saved = NSApp.windows.filter(\.isVisible).map { ($0, $0.ignoresMouseEvents) }
        for (w, _) in saved { w.ignoresMouseEvents = true }
    }

    /// Закончить: вернуть окнам прежнее `ignoresMouseEvents`.
    public static func end() {
        guard isActive else { return }
        for (w, v) in saved { w.ignoresMouseEvents = v }
        saved = []
        isActive = false
    }

    /// Сколько окон сейчас переведено в «пропускать мышь» (самотест).
    public static var guardedCount: Int { saved.count }
}
