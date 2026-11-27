import AppKit
import Combine
import SwiftUI
import IslandCore

/// Панель над вырезом: без рамки, не активирует приложение, поверх строки меню, на всех столах.
final class NotchPanel: NSPanel {
    /// Уровень окна: строка меню — 24 (mainMenu), значки справа — 25 (statusBar).
    /// Берём mainMenu + 3 = 27: выше строки меню и её значков, но ниже выпадающих меню (101),
    /// чтобы меню, открытые из строки меню, рисовались поверх острова; и ниже заставки/алертов.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = Self.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        // По умолчанию клики проходят насквозь; включаем приём, только когда курсор над формой острова.
        ignoresMouseEvents = true
        // VoiceOver: панель — «плавающее окно» SimpleIsland, внутри один контейнер-остров (IslandRootView).
        setAccessibilityLabel("SimpleIsland")
        setAccessibilityRole(.popover)
        LiveObjects.panels.add(self)
    }

    /// Ключевой панель становится, только пока модуль попросил клавиатуру (`ModuleContext.requestKeyboard`):
    /// иначе клик по острову забирал бы ввод у приложения, с которым работает пользователь.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    /// Не даём системе сдвинуть окно под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Хостинг SwiftUI, принимающий первый клик (без предварительной активации окна).
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        LiveObjects.hosts.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("не используется") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Слабый реестр живых окон/хостов/моделей: самотест `--selftest-core rebuild` проверяет, что после пересборок
/// их ровно столько, сколько островов (грабли M6: NSHostingView/окно не освобождались из-за циклов).
@MainActor
enum LiveObjects {
    static let hosts = NSHashTable<AnyObject>.weakObjects()
    static let panels = NSHashTable<AnyObject>.weakObjects()
    static let models = NSHashTable<AnyObject>.weakObjects()
    static let controllers = NSHashTable<AnyObject>.weakObjects()
    /// Окна-ловушки «клик мимо острова» (ClickAwayTrap).
    static let traps = NSHashTable<AnyObject>.weakObjects()
    static var trapCount: Int { autoreleasepool { traps.allObjects.count } }
    /// `allObjects` отдаёт autoreleased-массив сильных ссылок — считаем внутри своего пула, иначе сам подсчёт
    /// продлевает жизнь объектам (у CLI без внешнего пула — навсегда).
    static var counts: (hosts: Int, panels: Int, models: Int, controllers: Int) {
        autoreleasepool {
            (hosts.allObjects.count, panels.allObjects.count, models.allObjects.count, controllers.allObjects.count)
        }
    }
    /// Раскрыт ли хоть один остров (для `MemoryTrim`).
    @MainActor static var anyExpanded: Bool {
        autoreleasepool { models.allObjects.contains { ($0 as? IslandModel)?.expanded == true } }
    }
}

/// SimpleIsland на одном экране: панель, модель, зона кликов.
@MainActor
final class IslandController {
    /// Параметры экрана на момент последней сборки/обновления (подпись — см. ScreenDescriptor).
    private(set) var descriptor: ScreenDescriptor
    /// NSScreen по displayID (система пересоздаёт объекты NSScreen; ссылку не держим).
    var screen: NSScreen? { descriptor.screen }
    let panel: NotchPanel
    let model: IslandModel
    private var bag = Set<AnyCancellable>()
    private var occlusionObserver: NSObjectProtocol?
    private var hiddenByRule = false
    /// Окно реально видно на экране (`occlusionState`). Не видно → движение `.off`.
    private(set) var isPanelVisible = true
    /// Склейка `invalidateLayout` модулей: один пересчёт на шаг цикла и не больше `layoutBurstLimit` за 100 мс
    /// (грабли E4: петля SwiftUI-перерисовки у Atoll — 1900 транзакций подряд).
    private var layoutScheduled = false
    private var layoutWindowStart = Date.distantPast
    private var layoutPassesInWindow = 0
    static let layoutBurstLimit = 6
    /// Последний ключ размеров (рамка панели + метрики острова) — публикуем изменение модели, только если он другой.
    private var lastLayoutKey: LayoutKey?
    private(set) var stats = Stats()

    struct Stats {
        var layoutRequests = 0, layoutPasses = 0, layoutPublishes = 0, reports = 0, stateChanges = 0
    }

    private struct LayoutKey: Equatable {
        var frame: NSRect
        var metrics: IslandMetrics
    }
    /// Зона острова, посчитанная при последнем изменении состояния (мышь двигается чаще, чем меняется остров).
    private var cachedRect: NSRect?
    private var reportScheduled = false

    /// Поля вокруг острова внутри панели: место под свечение.
    private static let sidePad: CGFloat = 150
    private static let bottomPad: CGFloat = 150
    /// При перетаскивании файлов зона острова шире — чтобы «поймать» подлёт.
    private static let dragSlop: CGFloat = 40

    convenience init(screen: NSScreen, geometry: IslandGeometry, env: AppEnvironment) {
        self.init(descriptor: ScreenDescriptor(screen, isMenuBarScreen: screen == NSScreen.screens.first),
                  geometry: geometry, env: env)
    }

    init(descriptor: ScreenDescriptor, geometry: IslandGeometry, env: AppEnvironment) {
        self.descriptor = descriptor
        self.model = IslandModel(env: env, geometry: geometry)
        self.panel = NotchPanel(contentRect: .zero)
        let host = IslandHostingView(rootView: IslandRootView(model: model))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        layoutPanel()
        applySharing()

        env.settings.$data
            .map { ($0.expandedWidth, $0.hideWhileScreenSharing) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layoutPanel(); self?.applySharing() } }
            }
            .store(in: &bag)

        // Модуль сменил высоту вкладки → панель и форма пересчитываются (склеено, с защитой от петли).
        env.layoutChanged
            .sink { [weak self] in self?.requestLayout() }
            .store(in: &bag)

        // Видимость окна → уровень движения острова (вместе с системным: сон, «Уменьшить движение»…).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
        SystemStateCenter.shared.$motion
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateMotion() } }
            }
            .store(in: &bag)

        // Любое изменение, от которого зависят размеры острова: сбросить кэш зоны и сообщить состояние модулям.
        let changes: [AnyPublisher<Void, Never>] = [
            model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.activities.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.hud.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.notifications.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.themes.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            env.island.$isFileDragActive.map { _ in () }.eraseToAnyPublisher(),
            // Начало/конец интерактивного свайпа: зона кликов на время жеста — объединение покоя и раскрытого.
            model.swipe.$progress.map { $0 != nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.stateChanged() }
            .store(in: &bag)

        // Клавиатура: только по просьбе модуля, отдаём сразу, как просьб не осталось.
        env.island.$keyboardOwners
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] wants in self?.setKeyboard(wants) }
            .store(in: &bag)

        LiveObjects.controllers.add(self)
        stateChanged()
    }

    /// Изменение придёт в `objectWillChange` до записи значения — считаем на следующем шаге цикла.
    private func stateChanged() {
        cachedRect = nil
        stats.stateChanges += 1
        guard !reportScheduled else { return }
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reportScheduled = false
                self.cachedRect = nil
                self.stats.reports += 1
                let p = self.model.presentation
                self.model.env.island.report(self.model, presentation: p, tab: self.model.currentTab?.id)
                // Свернулись в покой/компакт — просьбы о клавиатуре больше не к чему.
                if p != .expanded && p != .notification { self.model.env.island.releaseAllKeyboard() }
            }
        }
    }

    private func setKeyboard(_ wants: Bool) {
        panel.allowsKey = wants
        if wants {
            // Ввод берёт тот остров, что раскрыт или показывает уведомление.
            let p = model.presentation
            if p == .expanded || p == .notification { panel.makeKey() }
        } else if panel.isKeyWindow {
            // Вернуть ввод приложению пользователя: неактивирующая панель отдаёт ключ, если её переподнять.
            panel.orderOut(nil)
            if !hiddenByRule { panel.orderFrontRegardless() }
        }
    }

    /// `invalidateLayout()` модуля: пересчёт на следующем шаге цикла (пачка просьб → один проход), не больше
    /// `layoutBurstLimit` проходов за 100 мс; модель публикуется, только если размеры реально поменялись —
    /// иначе цепочка layoutChanged → objectWillChange → перерисовка → invalidateLayout замкнулась бы.
    func requestLayout() {
        stats.layoutRequests += 1
        guard !layoutScheduled else { return }
        layoutScheduled = true
        let now = Date()
        if now.timeIntervalSince(layoutWindowStart) > 0.1 { layoutWindowStart = now; layoutPassesInWindow = 0 }
        let delay: TimeInterval = layoutPassesInWindow >= Self.layoutBurstLimit
            ? max(0, 0.1 - now.timeIntervalSince(layoutWindowStart)) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.performLayout() }
        }
    }

    private func performLayout() {
        layoutScheduled = false
        let now = Date()
        if now.timeIntervalSince(layoutWindowStart) > 0.1 { layoutWindowStart = now; layoutPassesInWindow = 0 }
        layoutPassesInWindow += 1
        stats.layoutPasses += 1
        layoutPanel()
        let key = LayoutKey(frame: panel.frame, metrics: model.currentMetrics)
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key
        stats.layoutPublishes += 1
        model.objectWillChange.send()
        stateChanged()
    }

    /// Панель фиксированного размера (максимальный остров + поля), прибита к верху экрана по центру выреза.
    /// Пересчитывается при смене ширины в настройках и по `invalidateLayout()` модуля.
    func layoutPanel() {
        let env = model.env
        let g = model.geometry
        let maxContent = min(env.maxExpandedHeight, g.maxContentHeight)
        let width = max(CGFloat(env.settings.data.expandedWidth), 480) + 2 * Self.sidePad
        let height = g.topOffset + g.notchHeight + 14 + maxContent + 30 + Self.bottomPad
        let frame = NSRect(x: g.centerX - width / 2, y: g.screenTop - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        cachedRect = nil
    }

    private func applySharing() {
        // «Прятать при демонстрации экрана»: окно исключается из захвата экрана (запись, Zoom, Телемост).
        panel.sharingType = model.env.settings.data.hideWhileScreenSharing ? .none : .readOnly
    }

    func show() {
        if !hiddenByRule { panel.orderFrontRegardless() }
        updateMotion()
    }
    func hide() { panel.orderOut(nil) }

    /// Экран поменял параметры (разрешение, масштаб, раскладка, Dock): обновить на месте, окно не пересоздавать.
    func update(descriptor d: ScreenDescriptor, geometry g: IslandGeometry) {
        descriptor = d
        if model.geometry != g { model.geometry = g }
        layoutPanel()
        lastLayoutKey = nil
        cachedRect = nil
    }

    /// Убрать насовсем (экран пропал, пауза): закрыть панель, снять подписки и наблюдателей, освободить
    /// SwiftUI-хост (`contentView = nil` рвёт цепочку окно → хост → модель → env).
    func close() {
        model.env.island.forget(model)
        bag.removeAll()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        model.cancelPendingWork()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    // MARK: Видимость и движение

    private func occlusionChanged() {
        let visible = panel.occlusionState.contains(.visible)
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        updateMotion()
    }

    /// Уровень движения острова: системный, но `.off`, пока окно не видно (перекрыто, спрятано правилом, экран
    /// выключен).
    func updateMotion() {
        let m: IslandMotion = isPanelVisible && panel.isVisible ? SystemStateCenter.shared.motion : .off
        if model.motion != m { model.motion = m }
    }

    /// Сон/блокировка: свернуть, забыть наведение (мониторы мыши сняты — выхода курсора не будет) и убрать окно:
    /// после пробуждения его покажут только по проверенному набору экранов, без мелькания по старой геометрии.
    func suspend() {
        model.pointer(inside: false)
        model.cancelPendingWork()
        model.collapse()
        panel.ignoresMouseEvents = true
        cachedRect = nil
        hide()
        updateMotion()
    }

    /// После пробуждения (и после сверки экранов): окно на место, размеры заново.
    func resume() {
        layoutPanel()
        lastLayoutKey = nil
        cachedRect = nil
        show()
        updateMotion()
    }

    /// Скрыть/показать по правилу (полноэкранное приложение).
    func setHiddenByRule(_ hidden: Bool) {
        guard hidden != hiddenByRule else { return }
        hiddenByRule = hidden
        if hidden { model.collapse(); hide(); updateMotion() } else { show() }
    }

    /// Зона острова в глобальных координатах (для решения «пропускать клики или нет»).
    func islandRect() -> NSRect {
        let g = model.geometry
        let m = model.hitMetrics
        let w = max(m.outerWidth, g.hasNotch ? g.notchWidth : 0)
        // Вторая активность — значком внутри уха: зона кликов = форма острова, снаружи ничего.
        var rect = NSRect(x: g.centerX - w / 2, y: g.screenTop - g.topOffset - m.height, width: w, height: m.height + g.topOffset)
        if model.env.island.isFileDragActive { rect = rect.insetBy(dx: -Self.dragSlop, dy: -Self.dragSlop) }
        return rect.insetBy(dx: -2, dy: -2)
    }

    /// Вызывается на каждое движение мыши (глобальный + локальный монитор). Зона кэшируется до следующего
    /// изменения состояния, так что на событие — одно сравнение прямоугольников.
    func mouseMoved(to point: NSPoint) {
        // Модуль шлёт синтетические события (перенос значка строки меню): панель пропускает мышь до конца.
        guard panel.isVisible, !SyntheticMouse.isActive else { return }
        let rect = cachedRect ?? islandRect()
        cachedRect = rect
        let inside = rect.contains(point)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        model.pointer(inside: inside)
    }
}
