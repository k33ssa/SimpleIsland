import AppKit
import IslandCore

/// Снимок параметров одного экрана — «подпись»: displayID + рамка + видимая рамка + безопасные поля (вырез) +
/// масштаб. Острова пересобираются только при изменении подписи (грабли D1/D2: пачка
/// `didChangeScreenParameters` при пробуждении и подключении монитора пересоздавала окна 2–3 раза).
struct ScreenDescriptor: Equatable {
    var displayID: CGDirectDisplayID
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var safeArea: NSEdgeInsets
    /// Ширина областей меню-бара слева/справа от выреза (`auxiliaryTopLeftArea/RightArea`). nil — выреза нет.
    var auxLeftWidth: CGFloat?
    var auxRightWidth: CGFloat?
    var scale: CGFloat
    /// Экран со строкой меню (`NSScreen.screens.first`).
    var isMenuBarScreen: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.displayID == b.displayID && a.frame == b.frame && a.visibleFrame == b.visibleFrame
            && a.safeArea.top == b.safeArea.top && a.safeArea.left == b.safeArea.left
            && a.safeArea.bottom == b.safeArea.bottom && a.safeArea.right == b.safeArea.right
            && a.auxLeftWidth == b.auxLeftWidth && a.auxRightWidth == b.auxRightWidth
            && a.scale == b.scale && a.isMenuBarScreen == b.isMenuBarScreen
    }

    init(displayID: CGDirectDisplayID, name: String, frame: CGRect, visibleFrame: CGRect,
         safeArea: NSEdgeInsets = NSEdgeInsets(), auxLeftWidth: CGFloat? = nil, auxRightWidth: CGFloat? = nil,
         scale: CGFloat = 2, isMenuBarScreen: Bool = false) {
        self.displayID = displayID; self.name = name; self.frame = frame; self.visibleFrame = visibleFrame
        self.safeArea = safeArea; self.auxLeftWidth = auxLeftWidth; self.auxRightWidth = auxRightWidth
        self.scale = scale; self.isMenuBarScreen = isMenuBarScreen
    }

    @MainActor init(_ s: NSScreen, isMenuBarScreen: Bool) {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        self.init(displayID: id, name: s.localizedName, frame: s.frame, visibleFrame: s.visibleFrame,
                  safeArea: s.safeAreaInsets, auxLeftWidth: s.auxiliaryTopLeftArea?.width,
                  auxRightWidth: s.auxiliaryTopRightArea?.width, scale: s.backingScaleFactor,
                  isMenuBarScreen: isMenuBarScreen)
    }

    /// Текущие экраны системы.
    @MainActor static func current() -> [ScreenDescriptor] {
        NSScreen.screens.enumerated().map { ScreenDescriptor($0.element, isMenuBarScreen: $0.offset == 0) }
    }

    /// NSScreen по displayID (объекты NSScreen система пересоздаёт — держим id, а не ссылку).
    @MainActor var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

extension IslandGeometry {
    /// Вырез по безопасной области и `auxiliaryTop*Area`. nil — выреза нет и капля не разрешена.
    static func detect(_ d: ScreenDescriptor, floatingAllowed: Bool) -> IslandGeometry? {
        let f = d.frame
        let top = d.safeArea.top
        if top > 0, let l = d.auxLeftWidth, let r = d.auxRightWidth {
            var width = f.width - l - r
            if width <= 0 || width > f.width / 2 { width = 186 }
            let center = f.minX + l + width / 2
            return IslandGeometry(notchWidth: width, notchHeight: top, hasNotch: true, topOffset: 0,
                                  centerX: center, screenTop: f.maxY, screenHeight: f.height)
        }
        guard floatingAllowed else { return nil }
        let menuBar = max(24, f.maxY - d.visibleFrame.maxY)
        // Высота — ровно строка меню, от самого верха (27.11: «сделай под строку меню» — капля торчала ниже неё).
        return IslandGeometry(notchWidth: 0, notchHeight: menuBar, hasNotch: false, topOffset: 0,
                              centerX: f.midX, screenTop: f.maxY, screenHeight: f.height)
    }
}

/// На каких экранах должны быть острова. Чистая функция — проверяется самотестом без экранов.
enum IslandPlanner {
    struct Options: Equatable {
        var paused = false
        var allScreens = false
        var floatingOnNotchlessScreens = true
    }

    struct Target: Equatable {
        var screen: ScreenDescriptor
        var geometry: IslandGeometry
    }

    static func plan(_ screens: [ScreenDescriptor], _ o: Options) -> [Target] {
        guard !o.paused else { return [] }
        var targets = screens.compactMap { s in
            IslandGeometry.detect(s, floatingAllowed: o.floatingOnNotchlessScreens).map { Target(screen: s, geometry: $0) }
        }
        if !o.allScreens {
            // Один остров: экран с вырезом, иначе экран со строкой меню (не `NSScreen.main` — у фонового
            // приложения он бывает не тем или nil). Clamshell: встроенного нет → капля на внешнем.
            if let notched = targets.first(where: { $0.geometry.hasNotch }) { targets = [notched] }
            else { targets = Array((targets.filter { $0.screen.isMenuBarScreen } + targets).prefix(1)) }
        }
        return targets
    }
}

/// Склейка пачки уведомлений об экранах: ждём `delay` после последнего, читаем подпись и применяем, только
/// если она изменилась (или `force` — после пробуждения). Пока система спит (`isHeld`), не применяем:
/// экраны во сне отдают неполный набор, пересборка по нему дала бы «мигание» после пробуждения.
@MainActor
final class ScreenChangeCoalescer {
    var delay: TimeInterval
    /// Предел ожидания от первого уведомления пачки: поток уведомлений чаще `delay` (BetterDisplay, Lunar, KVM,
    /// автоскрытие Dock) не откладывает применение бесконечно.
    var maxWait: TimeInterval = 1.5
    private var burstStart: Date?
    private let read: @MainActor () -> [ScreenDescriptor]
    private let apply: @MainActor ([ScreenDescriptor]) -> Void
    private var work: DispatchWorkItem?
    private var forcePending = false
    private(set) var lastApplied: [ScreenDescriptor]?
    var isHeld = false {
        didSet {
            // Во сне пачка не считается: после пробуждения отсчёт предела — заново.
            if isHeld != oldValue { burstStart = nil }
            if !isHeld && oldValue && (work != nil || forcePending) { schedule() }
        }
    }
    /// Счётчики для самотеста: уведомлений, применений, пропусков (подпись та же).
    private(set) var notes = 0, applies = 0, skips = 0

    init(delay: TimeInterval = 0.4, read: @escaping @MainActor () -> [ScreenDescriptor],
         apply: @escaping @MainActor ([ScreenDescriptor]) -> Void) {
        self.delay = delay; self.read = read; self.apply = apply
    }

    /// Пришло уведомление (или настройки поменялись). `force` — применить даже при той же подписи.
    func note(force: Bool = false) {
        notes += 1
        if force { forcePending = true }
        schedule()
    }

    /// Применить сразу (старт, смена настроек).
    func applyNow() {
        work?.cancel(); work = nil
        burstStart = nil
        forcePending = false
        let sig = read()
        lastApplied = sig
        applies += 1
        apply(sig)
    }

    private func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        work = w
        guard !isHeld else { return }   // отложено до пробуждения; work != nil — помним, что надо
        let now = Date()
        let start = burstStart ?? now
        burstStart = start
        let wait = max(0, min(delay, start.addingTimeInterval(maxWait).timeIntervalSince(now)))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func fire() {
        work = nil
        burstStart = nil
        guard !isHeld else { return }
        let sig = read()
        if sig == lastApplied && !forcePending { skips += 1; return }
        forcePending = false
        lastApplied = sig
        applies += 1
        apply(sig)
    }
}

/// Набор островов по экранам: добавляет новые, обновляет изменившиеся на месте (без пересоздания окна),
/// закрывает пропавшие, остальных не трогает.
@MainActor
final class IslandSet {
    private(set) var controllers: [IslandController] = []
    private let env: AppEnvironment
    /// Новый контроллер создан (AppDelegate вешает «открыть настройки» и показывает).
    var onCreate: (IslandController) -> Void = { _ in }
    /// Показывать ли панели (самотест — нет).
    var showsPanels = true
    private(set) var created = 0, updated = 0, removed = 0, kept = 0

    init(env: AppEnvironment) { self.env = env }

    /// Привести набор к плану. true — что-то поменялось.
    @discardableResult
    func reconcile(_ targets: [IslandPlanner.Target]) -> Bool {
        var changed = false
        let wanted = Set(targets.map(\.screen.displayID))
        for c in controllers where !wanted.contains(c.descriptor.displayID) {
            c.close(); removed += 1; changed = true
        }
        let existing = Dictionary(controllers.filter { wanted.contains($0.descriptor.displayID) }
            .map { ($0.descriptor.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [IslandController] = []
        for t in targets {
            if let c = existing[t.screen.displayID] {
                if c.descriptor != t.screen || c.model.geometry != t.geometry {
                    c.update(descriptor: t.screen, geometry: t.geometry)
                    updated += 1; changed = true
                } else {
                    kept += 1
                }
                next.append(c)
            } else {
                let c = IslandController(descriptor: t.screen, geometry: t.geometry, env: env)
                next.append(c)
                created += 1; changed = true
                onCreate(c)
                if showsPanels { c.show() }
            }
        }
        controllers = next
        return changed
    }

    func closeAll() {
        for c in controllers { c.close(); removed += 1 }
        controllers.removeAll()
    }
}
