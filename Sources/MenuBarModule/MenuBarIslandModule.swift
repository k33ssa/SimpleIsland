import AppKit
import Combine
import IslandCore
import SwiftUI

/// Модуль «Строка меню» (вкладка «Значки», макет 12): уборка правой части строки меню.
///
/// * Инвентарь: окна слоя строки меню + подписи из Универсального доступа; кто спрятан вырезом.
/// * Режим уборки: пункт в меню значка SimpleIsland, кнопка во вкладке, горячая клавиша (⌃⌥B). Оверлей над строкой,
///   щелчок по значку → карточка: в остров / спрятать совсем / выйти из приложения / выключить в настройках.
/// * Скрытие: свой разделитель-NSStatusItem (ничего чужого не правим), перенос значков ⌘-перетаскиванием (нужен
///   Универсальный доступ). «Вернуть всё как было» — убрать разделитель: всё снова видно.
/// * Выход/падение приложения: разделитель исчезает вместе с процессом — значки не теряются.
/// Подробно — docs/MENUBAR.md.
@MainActor
public final class MenuBarIslandModule: IslandModule {
    nonisolated public static let moduleId = "menubar"
    public let id = MenuBarIslandModule.moduleId
    public let title = "Значки"
    public let systemImage = "square.grid.2x2"
    public var tabEnabledByDefault: Bool { true }
    public var expandedHeight: CGFloat {
        MenuBarTabView.height(items: MenuBarPlanner.islandItems(model.inventory, model.prefs).count, axGranted: model.axGranted)
            + (MenuBarModel.leakText(model.inventory, model.prefs) != nil ? 40 : 0)
    }

    public let model = MenuBarModel()
    private weak var context: ModuleContext?
    private var enabledSub: AnyCancellable?
    private var layoutSub: AnyCancellable?
    private var lastHeight: CGFloat = 0
    private var started = false

    public init() {}

    public func start(context: ModuleContext) {
        self.context = context
        enabledSub = context.onEnabledChange { [weak self] on in on ? self?.enable() : self?.disable() }
        context.onSystemEvent { [weak self] e in self?.model.handleSystemEvent(e) }
        lastHeight = expandedHeight
        layoutSub = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let h = self.expandedHeight
                    if h != self.lastHeight { self.lastHeight = h; self.context?.invalidateLayout() }
                }
            }
        }
        if context.isEnabled { enable() }
    }

    private func enable() {
        guard !started, let ctx = context else { return }
        started = true
        // Пункт «Уборка строки меню…» в меню значка SimpleIsland — только пока модуль включён.
        ctx.setStatusMenuItem(title: "Уборка строки меню…") { [weak self] in self?.model.startCleanup() }
        model.start(context: ctx)
    }

    private func disable(appExiting: Bool = false) {
        guard started else { return }
        started = false
        context?.setStatusMenuItem(title: nil)
        model.stopAll(appExiting: appExiting)
        context?.releaseAllCollapseHolds()   // остров не должен остаться «в покое» после выключения
    }

    /// Ядро зовёт `stop()` только при выходе приложения (`applicationWillTerminate` → `stopModules`).
    public func stop() {
        disable(appExiting: true)
        context?.setStatusMenuItem(title: nil)
        enabledSub = nil
        layoutSub = nil
        context = nil
    }

    public func expandedView() -> AnyView? { AnyView(MenuBarTabView(model: model)) }
    public func headerTrailingView() -> AnyView? { AnyView(MenuBarHeaderView(model: model)) }
    public func settingsView() -> AnyView? { AnyView(MenuBarSettingsView(model: model)) }

    // MARK: Снимки (мок-данные; систему не трогают)

    public func snapshotStates() -> [ModuleSnapshot] {
        [
            ModuleSnapshot("tab", presentation: .expanded) { [model] ctx in
                MenuBarMocks.apply(to: model, ctx: ctx, axGranted: true)
            },
            ModuleSnapshot("tab-noaccess", presentation: .expanded) { [model] ctx in
                MenuBarMocks.apply(to: model, ctx: ctx, axGranted: false)
            },
            ModuleSnapshot("tab-empty", presentation: .expanded) { [model] ctx in
                MenuBarMocks.apply(to: model, ctx: ctx, axGranted: true, empty: true)
            },
            ModuleSnapshot("compact-stack", presentation: .compact) { [model] ctx in
                MenuBarMocks.apply(to: model, ctx: ctx, axGranted: true)
                let items = MenuBarPlanner.islandItems(model.inventory, model.prefs)
                MenuBarModel.postStack(items: Array(items.prefix(3)), count: items.count, model: model, ctx: ctx)
            },
        ]
    }
}
