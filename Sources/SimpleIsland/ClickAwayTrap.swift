import AppKit
import Combine
import IslandCore

// «Клик мимо острова только закрывает его» (14.11.2026, жалоба: «вместо того чтобы закрыть остров, меня
// уносит на рабочий стол»). Пока остров раскрыт, на каждом экране лежит прозрачное окно-ловушка уровнем ниже
// строки меню и выше обычных окон и Dock: первый клик мимо острова сворачивает его и никуда больше не проходит —
// как закрытие поповера. Окна создаются при первом раскрытии и переиспользуются (orderOut/orderFront), при смене
// экранов — сверяются по displayID (пропавшие закрываются), при выходе — закрываются все (LiveObjects.traps).

/// Окно-ловушка на одном экране.
final class ClickTrapWindow: NSPanel {
    /// Ниже строки меню (24) — её значки и меню работают как обычно; выше Dock (20), плавающих (3) и обычных окон.
    /// Остров (27) и выпадающие меню (101) — выше ловушки.
    static let trapLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    /// Непрозрачность фона. Полностью прозрачные пиксели оконный сервер пропускает насквозь, а 0,001 в 8-битном
    /// альфа-канале округляется до 0 — берём 2/255: глазом не видно (затемнение < 1 %), клики ловятся.
    static let alpha: CGFloat = 2.0 / 255.0

    var onMouseDown: ((NSPoint) -> Void)?
    var onDragEntered: (() -> Void)?
    /// Движение мыши над ловушкой: зона острова должна узнать, что курсор вернулся (страховка к мониторам мыши).
    var onMouseMoved: ((NSPoint) -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = Self.trapLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = NSColor(calibratedWhite: 0, alpha: Self.alpha)
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none            // в записи экрана не нужна
        // VoiceOver её не видит (и при включённом VoiceOver ловушки нет вовсе — см. ClickAwayTrap.shouldShow).
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        let view = ClickTrapView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
        LiveObjects.traps.add(self)
    }

    // Клавиатуру не берёт и приложение не активирует.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Содержимое ловушки: нажатие любой кнопкой — свернуть и поглотить; скролл — проглотить без действия
/// (пропустить в окно под ловушкой нельзя); курсор — стрелка; перетаскивание — ловушка сама уходит.
final class ClickTrapView: NSView {
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        // Любое перетаскивание над ловушкой (файл из острова на рабочий стол и т. п.) — ловушка уходит, бросок
        // достаётся окну под ней.
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .pdf, .rtf, .html, .color, .sound,
                                 NSPasteboard.PasteboardType("public.data"),
                                 NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType")] + DragPasteboard.promiseTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("не используется") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var trap: ClickTrapWindow? { window as? ClickTrapWindow }
    private func click() { trap?.onMouseDown?(NSEvent.mouseLocation) }

    override func mouseDown(with event: NSEvent) { click() }
    override func rightMouseDown(with event: NSEvent) { click() }
    override func otherMouseDown(with event: NSEvent) { click() }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { trap?.onMouseMoved?(NSEvent.mouseLocation) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        trap?.onDragEntered?()
        return []
    }
}

/// Когда ловушка нужна. Всё — снимок состояния; решение — `ClickAwayTrap.shouldShow` (чистая, самотест).
struct TrapConditions: Equatable {
    /// Настройка «Клик мимо острова только закрывает его».
    var enabled = true
    var anyExpanded = false
    /// Сон/блокировка.
    var suspended = false
    /// Тащат файлы (бросок должен дойти до окон).
    var fileDrag = false
    /// Над ловушкой прошёл drag (из острова наружу) — до сворачивания.
    var dragSuppressed = false
    /// Модуль держит остров (`holdExpanded`): открыто его меню/«Поделиться»/AirDrop — их окна (sharingd и т. п.) могут
    /// оказаться ниже ловушки.
    var held = false
    /// Модальное окно приложения (`NSApp.modalWindow`, `runModal` у NSOpenPanel — уровень 8, ниже ловушки) или ключевым
    /// стало другое наше окно (Настройки, Каталог): клики должны доходить до него.
    var ownWindowActive = false
    /// VoiceOver: «щелчок мышью» VO (VO-Shift-Space) — настоящее событие мыши в точке элемента, попало бы в ловушку.
    var voiceOver = false
}

/// Ловушки на всех экранах: показ, пока раскрыт хоть один остров (и включена настройка), без файлового drag'а.
@MainActor
final class ClickAwayTrap {
    struct Stats { var created = 0, closed = 0, shows = 0, hides = 0, clicks = 0, ignoredInside = 0, rescues = 0 }

    private let env: AppEnvironment
    private let controllers: () -> [IslandController]
    private(set) var windows: [CGDirectDisplayID: ClickTrapWindow] = [:]
    private var screens: [ScreenDescriptor] = []
    private(set) var isShown = false
    private(set) var stats = Stats()
    /// Сон/блокировка: ловушек нет.
    var suspended = false { didSet { if suspended != oldValue { scheduleRefresh() } } }
    /// Над ловушкой началось перетаскивание (из острова наружу) — до сворачивания ловушка не нужна.
    private(set) var dragSuppressed = false
    private var refreshScheduled = false
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var voiceOverObservation: NSKeyValueObservation?
    /// Сторож: главный поток не отвечает дольше `stallLimit` — ловушки снимаются с экрана в обход AppKit.
    let watchdog: TrapWatchdog
    /// Для самотеста: подправить снимок условий (VoiceOver, «наше окно ключевое» — без активации приложения).
    var conditionsOverride: ((inout TrapConditions) -> Void)?

    init(env: AppEnvironment, controllers: @escaping () -> [IslandController], stallLimit: TimeInterval = 3) {
        self.env = env
        self.controllers = controllers
        self.watchdog = TrapWatchdog(stallLimit: stallLimit)
        // @Published шлёт до записи — решаем на следующем шаге цикла (и склеиваем пачку изменений в одно).
        let changes: [AnyPublisher<Void, Never>] = [
            env.island.$presentation.map { _ in () }.eraseToAnyPublisher(),
            env.island.$isFileDragActive.map { _ in () }.eraseToAnyPublisher(),
            env.settings.$data.map(\.clickAwayOnlyCollapses).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            env.island.$expandHolds.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &bag)
        // Ключевое окно сменилось (Настройки, Каталог, NSOpenPanel в runModal): решить сразу — в модальном цикле
        // клик по ловушке не дойдёт до её mouseDown, и экран был бы «мёртвым» до Esc.
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if n.object is ClickTrapWindow { return }
                    self?.refresh()
                }
            })
        }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        watchdog.onRecovered = { [weak self] in self?.recoverAfterStall() }
    }

    /// Наше окно, кроме острова и ловушки, ключевое или модальное.
    static func isOwnWindowActive(key: NSWindow?, modal: NSWindow?) -> Bool {
        if modal != nil { return true }
        guard let key else { return false }
        return !(key is NotchPanel) && !(key is ClickTrapWindow)
    }

    var conditions: TrapConditions {
        var c = TrapConditions(enabled: env.settings.data.clickAwayOnlyCollapses, anyExpanded: anyExpanded,
                               suspended: suspended, fileDrag: env.island.isFileDragActive, dragSuppressed: dragSuppressed,
                               held: env.island.isExpandHeld,
                               ownWindowActive: Self.isOwnWindowActive(key: NSApp.keyWindow, modal: NSApp.modalWindow),
                               voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
        conditionsOverride?(&c)
        return c
    }

    /// Решение без побочных эффектов (самотест).
    nonisolated static func shouldShow(_ c: TrapConditions) -> Bool {
        c.enabled && c.anyExpanded && !c.suspended && !c.fileDrag && !c.dragSuppressed && !c.held
            && !c.ownWindowActive && !c.voiceOver
    }

    var anyExpanded: Bool { controllers().contains { $0.model.expanded } }

    var wanted: Bool { Self.shouldShow(conditions) }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Привести окна к нужному состоянию сейчас.
    func refresh() {
        if !anyExpanded { dragSuppressed = false }   // свернулись — следующее раскрытие снова с ловушкой
        let want = wanted
        if want {
            for s in screens where windows[s.displayID] == nil { makeWindow(for: s) }
            for w in windows.values where !w.isVisible { w.orderFrontRegardless() }
            if !isShown { stats.shows += 1 }
            watchdog.arm(windowNumbers: windows.values.map(\.windowNumber).filter { $0 > 0 })
        } else {
            watchdog.disarm()
            for w in windows.values where w.isVisible { w.orderOut(nil) }
            if isShown { stats.hides += 1 }
        }
        isShown = want
    }

    /// Экраны поменялись: пропавшие — закрыть, изменившиеся — новая рамка, новые — окно создастся при показе.
    func setScreens(_ s: [ScreenDescriptor]) {
        screens = s
        let ids = Set(s.map(\.displayID))
        for (id, w) in windows where !ids.contains(id) { close(w); windows[id] = nil }
        for d in s { if let w = windows[d.displayID], w.frame != d.frame { w.setFrame(d.frame, display: false) } }
        refresh()
    }

    /// Убрать все окна (выход, самотест).
    func closeAll() {
        watchdog.disarm()
        for w in windows.values { close(w) }
        windows.removeAll()
        isShown = false
    }

    private func makeWindow(for d: ScreenDescriptor) {
        let w = ClickTrapWindow(frame: d.frame)
        w.onMouseDown = { [weak self] p in self?.handleClick(at: p) }
        w.onDragEntered = { [weak self] in self?.dragEntered() }
        w.onMouseMoved = { [weak self] p in self?.controllers().forEach { $0.mouseMoved(to: p) } }
        windows[d.displayID] = w
        stats.created += 1
    }

    private func close(_ w: ClickTrapWindow) {
        w.onMouseDown = nil
        w.onDragEntered = nil
        w.onMouseMoved = nil
        w.orderOut(nil)
        w.contentView = nil
        w.close()
        stats.closed += 1
    }

    /// Нажатие на ловушку: мимо острова — свернуть раскрытые острова (клик поглощён). Попали в зону острова
    /// (панель не успела включить приём по движению мыши) — не сворачивать, включить приём: следующий клик дойдёт.
    func handleClick(at p: NSPoint) {
        for c in controllers() where c.islandRect().contains(p) {
            stats.ignoredInside += 1
            c.mouseMoved(to: p)
            return
        }
        stats.clicks += 1
        for c in controllers() where c.model.expanded && !c.model.locked { c.model.collapse() }
        // Не сразу: состояние острова публикуется на следующем шаге цикла — решаем после него (иначе быстрое
        // «свернуть → раскрыть» в одном шаге оставило бы раскрытый остров без ловушки).
        scheduleRefresh()
    }

    /// Главный поток ожил после зависания, во время которого сторож убрал ловушки в обход AppKit: привести AppKit
    /// в согласие (orderOut), свернуть острова (клики во время зависания пропали) и решить заново.
    private func recoverAfterStall() {
        stats.rescues += 1
        NSLog("SimpleIsland: главный поток не отвечал > %.1f с — ловушки кликов сняты сторожем", watchdog.stallLimit)
        for w in windows.values { w.orderOut(nil) }
        if isShown { stats.hides += 1 }
        isShown = false
        for c in controllers() where c.model.expanded { c.model.collapse() }
        scheduleRefresh()
    }

    private func dragEntered() {
        dragSuppressed = true
        refresh()
    }
}

/// Сторож зависания главного потока, пока ловушка на экране. Фоновый таймер раз в секунду шлёт главному потоку
/// «пинг»; ответа нет дольше `stallLimit` — окна-ловушки снимаются с экрана напрямую через оконный сервер
/// (`SLSOrderWindow`/`CGSOrderWindow` по номерам окон, взятым при показе; без NSWindow вне главного потока). Нет функций —
/// только запись в журнал (риск описан в PITFALLS X3). Таймер работает, только пока ловушка показана.
final class TrapWatchdog: @unchecked Sendable {
    let stallLimit: TimeInterval
    /// Главный поток ожил после снятия ловушек (зовётся на главном).
    var onRecovered: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var windowNumbers: [Int] = []
    private var lastPong = DispatchTime.now()
    private var pingOutstanding = false
    private var rescued = false
    private var rescueCount = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "SimpleIsland.trap.watchdog", qos: .utility)

    init(stallLimit: TimeInterval) { self.stallLimit = stallLimit }

    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }
    var rescues: Int { lock.lock(); defer { lock.unlock() }; return rescueCount }

    /// Ловушка показана (главный поток). Номера окон — для снятия в обход AppKit.
    func arm(windowNumbers wids: [Int]) {
        lock.lock(); defer { lock.unlock() }
        windowNumbers = wids
        guard timer == nil else { return }
        lastPong = .now()
        pingOutstanding = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        let step = min(1.0, max(0.1, stallLimit / 3))
        t.schedule(deadline: .now() + step, repeating: step, leeway: .milliseconds(Int(step * 200)))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        windowNumbers = []
    }

    private func tick() {
        lock.lock()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastPong.uptimeNanoseconds) / 1e9
        var toRemove: [Int] = []
        if elapsed > stallLimit, !rescued, !windowNumbers.isEmpty {
            rescued = true
            rescueCount += 1
            toRemove = windowNumbers
        }
        let sendPing = !pingOutstanding
        if sendPing { pingOutstanding = true }
        lock.unlock()
        if !toRemove.isEmpty { _ = Self.orderOut(toRemove) }
        guard sendPing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastPong = .now()
            self.pingOutstanding = false
            let wasRescued = self.rescued
            self.rescued = false
            self.lock.unlock()
            if wasRescued { MainActor.assumeIsolated { self.onRecovered?() } }
        }
    }

    /// Снять окна с экрана через оконный сервер (можно с любого потока). false — функций нет.
    @discardableResult
    static func orderOut(_ wids: [Int]) -> Bool {
        guard let conn = connection, let order = orderWindow else { return false }
        let cid = conn()
        for w in wids { _ = order(cid, Int32(w), 0, 0) }   // 0 = kCGSOrderOut
        return true
    }

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias OrderFn = @convention(c) (Int32, Int32, Int32, Int32) -> Int32
    private static func sym(_ names: [String]) -> UnsafeMutableRawPointer? {
        for n in names { if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), n) { return p } }
        return nil
    }
    private static let connection: ConnFn? = sym(["SLSMainConnectionID", "CGSMainConnectionID"])
        .map { unsafeBitCast($0, to: ConnFn.self) }
    private static let orderWindow: OrderFn? = sym(["SLSOrderWindow", "CGSOrderWindow"])
        .map { unsafeBitCast($0, to: OrderFn.self) }
    static var isAvailable: Bool { connection != nil && orderWindow != nil }

    private typealias OrderedInFn = @convention(c) (Int32, Int32, UnsafeMutablePointer<UInt8>) -> Int32
    private static let orderedIn: OrderedInFn? = sym(["SLSWindowIsOrderedIn", "CGSWindowIsOrderedIn"])
        .map { unsafeBitCast($0, to: OrderedInFn.self) }
    /// На экране ли окно по данным оконного сервера (самотест; nil — функции нет).
    static func isOrderedIn(_ wid: Int) -> Bool? {
        guard let conn = connection, let f = orderedIn else { return nil }
        var v: UInt8 = 0
        guard f(conn(), Int32(wid), &v) == 0 else { return nil }
        return v != 0
    }
}
