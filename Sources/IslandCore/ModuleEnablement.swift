import Combine
import Foundation

// «Включён ли модуль» для модулей (грабли S3: права спрашивать при ВКЛЮЧЕНИИ модуля, а не при каждом старте).
// Ядро запускает все модули при старте (`start(context:)`); модуль с вкладкой считается включённым, пока его
// вкладка включена в настройках (`settings.data.tabs`), модуль без вкладки (HUD) — всегда. Свои переключатели
// модуль хранит в своих настройках и решает сам.

public extension ModuleContext {
    /// Включён ли модуль: вкладка модуля включена в настройках; у модуля без вкладки — true.
    var isEnabled: Bool { Self.enabled(moduleId, in: settings.data) }

    /// Подписаться на включение/выключение модуля (вкладку включили/выключили в настройках). Зовётся на главном
    /// потоке с новым значением, только при изменении. Держать токен: пока он жив — подписка жива.
    ///
    /// ```swift
    /// enabledSub = context.onEnabledChange { [weak self] on in
    ///     if on { Task { await self?.context.ensurePermission(.calendars, reason: "…") } }
    /// }
    /// ```
    func onEnabledChange(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        let id = moduleId
        return settings.$data
            .map { Self.enabled(id, in: $0) }
            .removeDuplicates()
            .dropFirst()
            // @Published шлёт значение до записи в свойство — обработчик зовём на следующем шаге цикла,
            // когда `settings.data` (и `isEnabled`) уже новые.
            .receive(on: DispatchQueue.main)
            .sink { on in MainActor.assumeIsolated { handler(on) } }
    }

    nonisolated private static func enabled(_ id: String, in data: SettingsData) -> Bool {
        data.tabs.first { $0.id == id }?.enabled ?? true
    }
}
