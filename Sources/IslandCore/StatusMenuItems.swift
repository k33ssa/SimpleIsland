import Foundation

/// Пункты модулей в меню значка SimpleIsland в строке меню (напр. «Уборка строки меню…» модуля «Значки»).
/// Ядро (AppDelegate) строит меню при открытии и вставляет эти пункты после «Настройки…». Один пункт на модуль.
@MainActor
public final class StatusMenuItems {
    public static let shared = StatusMenuItems()

    public struct Entry {
        public var moduleId: String
        public var title: String
        public var action: @MainActor () -> Void
    }

    /// По порядку добавления.
    public private(set) var entries: [Entry] = []

    public init() {}

    public func set(moduleId: String, title: String?, action: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.moduleId == moduleId }
        if let title { entries.append(Entry(moduleId: moduleId, title: title, action: action)) }
    }
}

public extension ModuleContext {
    /// Свой пункт в меню значка SimpleIsland (nil — убрать). Зовётся из `start`; в `stop` — `setStatusMenuItem(title: nil)`.
    func setStatusMenuItem(title: String?, action: @escaping @MainActor () -> Void = {}) {
        guard !isSnapshot else { return }
        StatusMenuItems.shared.set(moduleId: moduleId, title: title, action: action)
    }
}
