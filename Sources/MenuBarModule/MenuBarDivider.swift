import AppKit

/// Наш разделитель в строке меню — свой `NSStatusItem` (чужие значки не трогаем). Развёрнут (длина ≈ 2× экрана)
/// — всё левее него уходит за край строки; свёрнут (12 pt, тонкая черта) — видно, только пока идёт перенос или
/// временный показ значка. Идея и числа длины — Hidden Bar (dwarvesf/hidden, MIT; THIRD_PARTY.md), код свой.
///
/// Безопасность: разделитель живёт, только пока работает приложение. Выход, выключение модуля или падение —
/// окно разделителя исчезает вместе с процессом, и все значки снова видны (под вырезом — как без нас).
@MainActor
final class MenuBarDivider {
    static let autosaveName = "SimpleIslandMenuBarDivider"
    static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }
    static var visibleKey: String { "NSStatusItem Visible \(autosaveName)" }

    private(set) var item: NSStatusItem?
    private(set) var isExpanded = false
    /// macOS 27: правый край разделителя до разворота (значки справа не двигаются — край тот же).
    private var lastRightEdge: CGFloat?
    /// Самотест: настоящий NSStatusItem не создаётся (в строке меню ничего не появляется), состояние — как у живого.
    static var dryRun = false
    private var dryCreated = false
    /// Нажали на свёрнутый разделитель (во время временного показа) — открыть вкладку.
    var onClick: (() -> Void)?

    var exists: Bool { item != nil || dryCreated }
    /// Текущая длина (для поиска копий окна разделителя на других экранах); nil — разделителя нет.
    var length: CGFloat? { item?.length }

    /// Номер окна разделителя (для сравнения с окнами слоя 25).
    var windowID: CGWindowID? {
        // macOS 27: значки строки меню рисует система, у окна кнопки номер-заглушка 2^32 — не CGWindowID
        // (было падение «Not enough bits» на старте, 20.11). Не влезает — окна нет.
        guard let n = item?.button?.window?.windowNumber, n > 0 else { return nil }
        return CGWindowID(exactly: n)
    }

    /// Рамка значка-разделителя в координатах CG (из окна его кнопки). На macOS 27 окно кнопки — место значка в
    /// строке (в раскрытом overflow — там, в свёрнутом — в общей точке под вырезом; измерено 20.11).
    var cgFrame: CGRect? {
        guard let f = item?.button?.window?.frame, f.width > 0, let main = NSScreen.screens.first else { return nil }
        return CGRect(x: f.minX, y: main.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// Создать, если нет. `preferredPosition` — куда поставить при первом создании (расстояние от правого края
    /// экрана); дальше место помнит сама система по `autosaveName`.
    func ensure(preferredPosition: CGFloat?) {
        guard !exists else { return }
        if Self.dryRun { dryCreated = true; isExpanded = false; return }
        let d = UserDefaults.standard
        if d.object(forKey: Self.positionKey) == nil, let p = preferredPosition { d.set(Double(p), forKey: Self.positionKey) }
        // ⌘-утащенный за строку разделитель система помечает невидимым навсегда — возвращаем (как Hidden Bar).
        d.set(true, forKey: Self.visibleKey)
        let it = NSStatusBar.system.statusItem(withLength: MenuBarDividerMath.collapsedLength)
        it.autosaveName = Self.autosaveName
        it.isVisible = true
        it.behavior = []          // не даём убрать ⌘-перетаскиванием
        if let b = it.button {
            b.image = Self.lineImage()
            b.image?.isTemplate = true
            b.setAccessibilityLabel("Разделитель SimpleIsland: левее — значки в острове")
            b.target = self
            b.action = #selector(clicked)
        }
        item = it
        isExpanded = false
    }

    func expand() {
        if Self.dryRun { isExpanded = dryCreated; return }
        guard let item else { return }
        let len: CGFloat
        if MenuBarAgent.isActive {
            // macOS 27: элемент шире половины экрана система отбрасывает (не рисует и ничего не прячет; 848 pt
            // работает, 849 — нет на экране 1728, измерено 20.11). Прячет она «префикс» строки — всё левее
            // разделителя; длины «от правого края разделителя до выреза» хватает, и он сам остаётся в строке.
            let right = (isExpanded ? lastRightEdge : cgFrame?.maxX) ?? cgFrame?.maxX
            let main = NSScreen.screens.first
            let notchMax = MenuBarScanner.notchRect()?.maxX
            // Сам в overflow (у выреза) — длина ничего не даст, а в раскрытом ряду была бы пустая дыра: черта.
            let inOverflow = right.map { r in notchMax.map { r - 8 - ($0 + 50) < 60 } ?? false } ?? true
            len = inOverflow ? MenuBarDividerMath.collapsedLength
                : MenuBarDividerMath.agentLength(rightEdge: right, leftLimit: notchMax, screenWidth: main?.frame.width ?? 1440)
            if !isExpanded { lastRightEdge = cgFrame?.maxX }
            if !inOverflow { item.button?.image = nil }   // пустое место, а не черта посреди него
        } else {
            len = MenuBarDividerMath.expandedLength(screenWidths: NSScreen.screens.map(\.frame.width))
        }
        if item.length != len { item.length = len }
        isExpanded = true
    }

    func collapse() {
        if Self.dryRun { isExpanded = false; return }
        guard let item else { return }
        if item.length != MenuBarDividerMath.collapsedLength { item.length = MenuBarDividerMath.collapsedLength }
        if item.button?.image == nil { item.button?.image = Self.lineImage(); item.button?.image?.isTemplate = true }
        isExpanded = false
    }

    /// Экраны поменялись — пересчитать длину развёрнутого.
    func screensChanged() { if isExpanded { expand() } }

    /// Убрать разделитель: всё, что было левее, снова видно. `forgetPosition` — «Вернуть всё как было»: следующий
    /// разделитель встанет заново.
    func remove(forgetPosition: Bool) {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        isExpanded = false
        dryCreated = false
        if forgetPosition && !Self.dryRun {
            UserDefaults.standard.removeObject(forKey: Self.positionKey)
            UserDefaults.standard.removeObject(forKey: Self.visibleKey)
        }
    }

    @objc private func clicked() { onClick?() }

    /// Тонкая вертикальная черта 2×14 pt.
    private static func lineImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 2, height: r.height - 2), xRadius: 1, yRadius: 1).fill()
            return true
        }
        return img
    }
}
