import AppKit
import Combine
import SwiftUI
import IslandCore

/// Геометрия выреза конкретного экрана.
struct IslandGeometry: Equatable {
    /// Ширина/высота физического выреза (или виртуальной капли на экране без выреза).
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    /// Отступ сверху (у плавающей капли).
    var topOffset: CGFloat
    /// Центр выреза по X в координатах экрана (глобальных).
    var centerX: CGFloat
    /// Верх экрана (глобальные координаты, maxY).
    var screenTop: CGFloat
    /// Высота экрана — предел роста вкладки.
    var screenHeight: CGFloat = 982

    /// Пустой промежуток под железом в компакте.
    var gap: CGFloat { hasNotch ? notchWidth : 22 }

    /// Как в макетах: вырез 186×38.
    static let mockNotch = IslandGeometry(notchWidth: 186, notchHeight: 38, hasNotch: true, topOffset: 0, centerX: 0, screenTop: 0)
    static let mockFloating = IslandGeometry(notchWidth: 0, notchHeight: 30, hasNotch: false, topOffset: 4, centerX: 0, screenTop: 0)

    /// Вырез по safeAreaInsets и auxiliaryTop*Area. nil — выреза нет.
    /// auxiliary*Area — области меню-бара слева/справа от выреза (в координатах экрана). Левая область начинается
    /// от левого края экрана → центр выреза = левый край + её ширина + половина выреза. Расчёт —
    /// `detect(_: ScreenDescriptor, …)` в ScreenPlanning.swift (его проверяет самотест).
    @MainActor
    static func detect(_ screen: NSScreen, floatingAllowed: Bool) -> IslandGeometry? {
        detect(ScreenDescriptor(screen, isMenuBarScreen: screen == NSScreen.screens.first), floatingAllowed: floatingAllowed)
    }

    /// Самая высокая вкладка, что поместится на экран (остальное модуль прокручивает сам).
    var maxContentHeight: CGFloat { max(160, screenHeight * 0.62) }
}

/// Состояние одного острова (на одном экране): раскрыт ли, наведение, вкладка.
@MainActor
final class IslandModel: ObservableObject {
    @Published var geometry: IslandGeometry
    @Published var expanded = false {
        // Свернули — через несколько секунд вернуть системе освобождённые страницы кучи (см. `MemoryTrim`).
        didSet { if oldValue && !expanded { MemoryTrim.schedule() } }
    }
    @Published var hovering = false
    /// Замок (16.11, «кнопка с замком, которая блочит айленд раскрытым»): уход курсора и клик мимо не сворачивают;
    /// явное сворачивание (тап, свайп, Esc, повторный замок, сон) — сворачивает и снимает замок. Пока заперт —
    /// удержание `island.lock` в центре: ловушка «клик мимо» не ставится, клики идут в другие приложения.
    @Published private(set) var locked = false
    @Published var selectedTab: String?
    /// Сколько движения можно показывать (окно видно? сон? «Уменьшить движение»?) — ставит IslandController,
    /// вьюхи берут из Environment `\.islandMotion`.
    @Published var motion: IslandMotion = .full

    let env: AppEnvironment
    var onOpenSettings: () -> Void = {}

    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    // Свайп (IslandSwipe.swift): накопленный сдвиг жеста, прежний порог, интерактивный прогресс.
    let swipe = IslandSwipeState()
    var scrollAccum: CGFloat = 0
    var lastScroll = Date.distantPast
    var legacyFired = false
    var gestureInteractive = false
    var swipeStartOpen = false
    var swipeSamples: [(TimeInterval, CGFloat)] = []
    var swipeDistance: CGFloat = 200
    var swipeSavedTab: String?
    // --- misc2 ---
    /// Курсор ушёл, пока модуль держит остров раскрытым (`holdExpanded`, открыто его меню): свернуть после
    /// отпускания, если курсор так и не вернулся.
    private var collapseAfterHold = false
    private var holdSub: AnyCancellable?
    // --- /misc2 ---
    // --- shelfbar ---
    /// Модуль держит остров в покое (`holdCollapsed`, режим уборки строки меню): только вырез, без ушей, компакта,
    /// HUD, уведомлений, раскрытия и наведения.
    @Published private(set) var calm = false
    private var calmSub: AnyCancellable?
    // --- /shelfbar ---

    /// Строка подсказки под вырезом при наведении (макет 02, состояние 06): «потяни или щёлкни».
    static let hintRowHeight: CGFloat = 22

    init(env: AppEnvironment, geometry: IslandGeometry) {
        self.env = env
        self.geometry = geometry
        LiveObjects.models.add(self)
        // --- misc2 --- удержание сняли — отложенное сворачивание (курсор ушёл на меню и не вернулся).
        holdSub = env.island.$expandHolds
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // @Published шлёт до записи — смотреть состояние на следующем шаге цикла. Отпущено ли удержание
                // именно этого острова (модуль его вкладки), решает `holdReleased`.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.holdReleased() } }
            }
        // --- /misc2 ---
        // --- shelfbar ---
        calm = env.island.isCollapseHeld
        calmSub = env.island.$collapseHolds
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] on in self?.setCalm(on) }
        // --- /shelfbar ---
    }

    // --- shelfbar ---
    private func setCalm(_ on: Bool) {
        guard calm != on else { return }
        if on {
            cancelPendingWork()
            collapse()
        }
        calm = on
    }
    // --- /shelfbar ---

    // --- misc2 ---
    /// Держит ли этот остров модуль его открытой вкладки (меню модуля открыто). Удержание общее на все экраны,
    /// поэтому сверяем с вкладкой: остров на другом мониторе на другой вкладке сворачивается как обычно.
    private var isHeldHere: Bool {
        guard expanded, let tab = currentTab?.id else { return false }
        return env.island.isExpandHeld(by: tab)
    }

    private func holdReleased() {
        guard collapseAfterHold, !isHeldHere else { return }
        collapseAfterHold = false
        guard expanded, !pointerInside else { return }
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapseUnlessHeld() } }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + env.settings.data.collapseDelay, execute: w)
    }

    /// Сворачивание по уходу курсора: модуль держит остров (меню открыто) — отложить до отпускания.
    private func collapseUnlessHeld() {
        if locked { return }
        if isHeldHere { collapseAfterHold = true } else { collapse() }
    }
    // --- /misc2 ---

    /// Отменить отложенные наведение/сворачивание (закрытие острова, сон).
    func cancelPendingWork() {
        hoverWork?.cancel(); hoverWork = nil
        collapseWork?.cancel(); collapseWork = nil
        pointerInside = false
        collapseAfterHold = false   // --- misc2 ---
        cancelSwipe()
    }

    // MARK: Состояние

    var presentation: IslandPresentation {
        if calm { return .idle }   // --- shelfbar ---
        if expanded { return .expanded }
        return restingPresentation
    }

    /// Что остров показывает свёрнутым (без учёта `expanded`) — нижняя точка интерактивного свайпа.
    var restingPresentation: IslandPresentation {
        if calm { return .idle }   // --- shelfbar ---
        if env.notifications.current != nil && !env.notifications.isSuspended { return .notification }
        if env.hud.current != nil { return .hud }
        if env.activities.primary != nil { return .compact }
        return .idle
    }

    var currentTab: IslandModule? {
        let tabs = env.enabledTabModules
        return tabs.first { $0.id == selectedTab } ?? tabs.first
    }

    /// Размеры для состояния — общая формула для вьюхи и для зоны кликов.
    func metrics(for p: IslandPresentation) -> IslandMetrics {
        let theme = env.theme
        let g = geometry
        let shape = theme.shape
        let compactR = CGFloat(shape.compactCornerRadius)
        let compactE = min(CGFloat(shape.earRadius), compactR * 0.65)
        var m: IslandMetrics
        switch p {
        case .idle:
            let dot = env.activities.idleDot != nil && !calm   // --- shelfbar --- в покое — ровно вырез
            if g.hasNotch {
                m = IslandMetrics(width: g.gap + (dot ? 28 : 0), height: g.notchHeight,
                                  cornerRadius: dot ? compactR : min(compactR, 10), earRadius: dot ? compactE : 0)
            } else {
                m = IslandMetrics(width: dot ? 96 : 80, height: g.notchHeight, cornerRadius: compactR, earRadius: 0)
            }
        case .compact:
            let d = env.settings.data   // уши с учётом назначений (settings)
            let side = env.activities.compactSideWidth(left: d.leftEarModule, right: d.rightEarModule) ?? 56
            m = IslandMetrics(width: g.gap + 2 * side, height: g.notchHeight, cornerRadius: compactR, earRadius: compactE)
        case .hud:
            let side = env.hud.current?.sideWidth ?? 120
            m = IslandMetrics(width: g.gap + 2 * side, height: g.notchHeight, cornerRadius: compactR, earRadius: compactE)
        case .notification:
            // Многострочная карточка (подсказка «где включить право») — шире и выше на строку.
            let extra = CGFloat(max(0, min(3, env.notifications.current?.bodyLines ?? 1) - 1))
            m = IslandMetrics(width: max(extra > 0 ? 580 : 480, g.gap + 240), height: g.notchHeight + 56 + 16 * extra,
                              cornerRadius: min(CGFloat(shape.cornerRadius), 26), earRadius: min(CGFloat(shape.earRadius), 12))
        case .expanded:
            let content = min(currentTab?.expandedHeight ?? 160, g.maxContentHeight)
            m = IslandMetrics(width: CGFloat(env.settings.data.expandedWidth), height: g.notchHeight + 14 + content + 22,
                              cornerRadius: CGFloat(shape.cornerRadius), earRadius: CGFloat(shape.earRadius))
        }
        if hovering && (p == .idle || p == .compact) {
            // Набухание вниз на строку подсказки; без вкладок раскрывать нечего — только лёгкий отклик.
            if showsHoverHint {
                m.width = max(m.width + 22, 150)
                m.height += Self.hintRowHeight
                m.cornerRadius = max(m.cornerRadius + 6, 20)
                m.earRadius = min(max(m.earRadius, 10), 12)
            } else {
                m.width += 12; m.height += 6; m.cornerRadius += 4
            }
        }
        if !g.hasNotch {
            m.earRadius = 0
            m.topCornerRadius = min(m.cornerRadius, m.height / 2)
        }
        return m
    }

    /// То, что сейчас нарисовано: во время интерактивного свайпа — промежуточная форма покой ↔ раскрыт.
    var currentMetrics: IslandMetrics {
        if let t = swipe.progress { return .lerp(metrics(for: restingPresentation), metrics(for: .expanded), t) }
        return metrics(for: presentation)
    }

    /// Строка подсказки при наведении — только когда над островом тащат файл («отпусти — положу на полку»).
    /// Обычную подсказку «потяни или щёлкни» пользователь попросил убрать (14.11): при наведении остров лишь
    /// слегка набухает.
    var showsHoverHint: Bool { env.island.isFileDragActive && env.dropModule(preferring: nil) != nil }

    /// Вторая активность для значка в правом ухе (только в компакте). Снаружи острова ничего не рисуется.
    var secondaryActivity: IslandActivity? {
        guard presentation == .compact else { return nil }
        return env.activities.secondaryActivity(left: env.settings.data.leftEarModule, right: env.settings.data.rightEarModule)
    }

    // MARK: Действия

    func expand(tab: String? = nil) {
        guard !calm else { return }   // --- shelfbar ---
        cancelSwipe()
        if let tab { selectedTab = tab }
        else if let a = env.settings.data.compactOwner(in: env.activities), presentation == .compact {   // по ушам (settings)
            selectedTab = a.opensTab ?? a.moduleId
        }
        if env.enabledTabModules.isEmpty { return }
        if currentTab?.id != selectedTab, let first = env.enabledTabModules.first, selectedTab == nil { selectedTab = first.id }
        expanded = true
    }

    /// Раскрыть «как по тапу»: уведомление — убрать и открыть его вкладку, иначе `expand()` (вкладка по ушам).
    func expandFromCurrent() {
        if presentation == .notification, let n = env.notifications.current {
            env.notifications.dismiss(id: n.id)
            expand(tab: n.opensTab ?? n.moduleId)
        } else if !expanded {
            expand()
        }
    }

    func collapse() {
        cancelSwipe()
        setLocked(false)
        expanded = false
        hovering = false
    }

    /// Запереть/отпереть раскрытый остров (кнопка-замок). Запереть можно только раскрытый.
    func setLocked(_ on: Bool) {
        let v = on && expanded
        guard locked != v else { return }
        locked = v
        let token = "island.lock.\(ObjectIdentifier(self).hashValue)"
        if v {
            collapseWork?.cancel(); collapseWork = nil
            collapseAfterHold = false
            env.island.holdExpanded(token)
        } else {
            env.island.releaseExpanded(token)
        }
    }

    func toggleLock() { setLocked(!locked) }

    func toggle() { expanded ? collapse() : expand() }

    /// Курсор вошёл/вышел из зоны острова (зовёт IslandController по глобальному монитору мыши).
    func pointer(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if calm { hovering = false; return }   // --- shelfbar --- в покое наведение не действует
        if inside {
            collapseWork?.cancel()
            collapseAfterHold = false   // --- misc2 ---
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hovering = true
                    // Тащат файлы над островом → раскрыть на вкладке модуля, что их примет (Полка).
                    if self.env.island.isFileDragActive, !self.expanded,
                       let m = self.env.dropModule(preferring: nil) {
                        self.expand(tab: m.providesTab ? m.id : nil)
                    }
                }
            }
            hoverWork = w
            let delay = env.island.isFileDragActive ? min(0.15, env.settings.data.hoverDelay) : env.settings.data.hoverDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        } else {
            hoverWork?.cancel()
            // --- misc2 --- было `self?.collapse()`: модуль может держать остров раскрытым (его меню открыто).
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapseUnlessHeld() } }
            collapseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + env.settings.data.collapseDelay, execute: w)
        }
    }
}

/// Возврат памяти после сворачивания. Раскрытый остров строит много вью SwiftUI, картинок и слоёв; после
/// сворачивания они освобождаются, но malloc держит освободившиеся «грязные» страницы у себя — их считает
/// phys_footprint (бюджет покоя 40 МБ, замер до правки — 50 МБ в покое после раскрытий). Через 3 с покоя —
/// `malloc_zone_pressure_relief`: зоны отдают свободные страницы системе (то же делает система при нехватке памяти).
/// Один отложенный вызов, повторное сворачивание откладывает его; раскрытие отменяет.
@MainActor
enum MemoryTrim {
    private static var work: DispatchWorkItem?

    static func schedule(after delay: TimeInterval = 3) {
        work?.cancel()
        let w = DispatchWorkItem {
            MainActor.assumeIsolated {
                work = nil
                guard !LiveObjects.anyExpanded else { return }
                DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
            }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
