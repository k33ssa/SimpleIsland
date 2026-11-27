import AppKit
import Combine
import IOKit.ps
import SwiftUI

// Состояние системы для ядра и модулей: сон/пробуждение, экраны, сессия пользователя, блокировка,
// «Уменьшить движение», режим энергосбережения, питание от батареи → уровень движения `IslandMotion`.
// Грабли D2/D3/E2 (docs/PITFALLS.md): после сна у конкурентов ломался HUD и hover, анимации крутились в
// скрытом окне. Всё — события, без опроса.

/// Системное событие. Модуль подписывается через `context.onSystemEvent { … }` или `context.system.events`.
///
/// Что делать модулю:
/// * `.willSleep`, `.screensDidSleep`, `.sessionDidResignActive`, `.screenLocked` — остановить анимации и
///   таймеры, закрыть сетевые соединения, если они не нужны в фоне.
/// * `.didWake`, `.screensDidWake`, `.sessionDidBecomeActive`, `.screenUnlocked` — **перевесить слушатели**:
///   event tap (HUD) система могла выключить (`tapEnable` заново), MediaRemote/адаптер мог потерять источник
///   (переспросить «что играет»), сокеты — переподключить.
/// * `.screensChanged` — набор/параметры экранов поменялись (уже после склейки пачки уведомлений, ~0,4 с).
public enum IslandSystemEvent: String, Sendable, Equatable, CaseIterable {
    case willSleep, didWake
    case screensDidSleep, screensDidWake
    /// Быстрое переключение пользователей: наша сессия ушла в фон / вернулась.
    case sessionDidResignActive, sessionDidBecomeActive
    case screenLocked, screenUnlocked
    /// Экраны подключили/отключили/сменили разрешение, масштаб, раскладку (после склейки и сравнения подписи).
    case screensChanged
    /// Поменялись «Уменьшить движение», энергосбережение или питание (батарея/сеть) — см. `motion`.
    case motionChanged
}

/// Сколько движения можно показывать. Ядро кладёт это в Environment (`\.islandMotion`); модули берут оттуда:
/// `.full` — всё как задумано; `.reduced` — без бегущих рамок, эквалайзеров и пружинного перелёта (короткое
/// затухание); `.off` — окно не видно / сон / экран заблокирован: ни одного кадра.
public enum IslandMotion: Int, Sendable, Comparable, CaseIterable {
    case off, reduced, full
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Можно ли крутить анимации по времени (`TimelineView`, бегущая рамка, эквалайзер).
    public var allowsContinuousAnimation: Bool { self == .full }

    /// Анимация смены состояния с учётом уровня: `.full` — как есть, `.reduced` — короткое затухание без перелёта,
    /// `.off` — без анимации.
    public func animation(_ base: Animation) -> Animation? {
        switch self {
        case .full: return base
        case .reduced: return .easeOut(duration: 0.12)
        case .off: return nil
        }
    }
}

private struct IslandMotionKey: EnvironmentKey {
    static let defaultValue = IslandMotion.full
}

public extension EnvironmentValues {
    /// Уровень движения (ставит ядро для каждого острова: видимость окна + система + настройки).
    var islandMotion: IslandMotion {
        get { self[IslandMotionKey.self] }
        set { self[IslandMotionKey.self] = newValue }
    }
}

/// Состояние системы, один на процесс (`SystemStateCenter.shared`). Ядро запускает наблюдение
/// (`startMonitoring()`), модули только читают (`context.system`) и подписываются на события.
@MainActor
public final class SystemStateCenter: ObservableObject {
    public static let shared = SystemStateCenter()

    /// Мак засыпает/спит (между `willSleep` и `didWake`).
    @Published public private(set) var isAsleep = false
    /// Экраны выключены (сон дисплеев, заставка с выключением).
    @Published public private(set) var areScreensAsleep = false
    /// Наша сессия активна (false — быстрое переключение на другого пользователя).
    @Published public private(set) var isSessionActive = true
    @Published public private(set) var isScreenLocked = false
    /// Системная настройка «Уменьшить движение».
    @Published public private(set) var reduceMotion = false
    /// Режим энергосбережения (Low Power Mode).
    @Published public private(set) var isLowPowerMode = false
    /// Питание от батареи (не от сети).
    @Published public private(set) var isOnBattery = false
    /// Пользовательская настройка «на батарее — без анимаций» (ставит ядро из настроек).
    @Published public private(set) var reduceMotionOnBattery = false
    /// Итоговый уровень движения без учёта видимости конкретного окна.
    @Published public private(set) var motion: IslandMotion = .full

    /// Поток событий (на главном потоке).
    public let events = PassthroughSubject<IslandSystemEvent, Never>()

    /// Сколько событий опубликовано (для самотестов и диагностики).
    public private(set) var eventCount = 0
    private var handlers: [String: [(Int, @MainActor (IslandSystemEvent) -> Void)]] = [:]
    private var handlerSeq = 0
    // nonisolated(unsafe): трогаются только с главного потока; доступны из deinit, чтобы снять наблюдение.
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?
    /// Контекст обратного вызова IOKit: коробка со слабой ссылкой (удержана, отпускается в `stopMonitoring`),
    /// а не сам центр — освобождённый центр не превратится в висячий указатель.
    nonisolated(unsafe) private var powerBox: Unmanaged<WeakCenterBox>?
    private var refreshingSession = false
    private(set) public var isMonitoring = false

    public init() {}

    deinit {
        for (c, o) in observers { c.removeObserver(o) }
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        powerBox?.release()
    }

    /// «Активна ли система для показа»: не спит, экраны включены, сессия наша, не заблокировано.
    public var isInteractive: Bool { !isAsleep && !areScreensAsleep && isSessionActive && !isScreenLocked }

    // MARK: Наблюдение

    /// Подписаться на уведомления системы. Зовёт ядро один раз при запуске (не в режиме снимков).
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        let ws = NSWorkspace.shared.notificationCenter
        let map: [(Notification.Name, IslandSystemEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        for (name, event) in map {
            let o = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            observers.append((ws, o))
        }
        // Блокировка экрана — распределённые уведомления loginwindow (публичных имён в AppKit нет).
        let dnc = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", IslandSystemEvent.screenLocked),
                              ("com.apple.screenIsUnlocked", IslandSystemEvent.screenUnlocked)] {
            let o = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            observers.append((dnc, o))
        }
        // «Уменьшить движение».
        let rm = ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotionInputs() }
        }
        observers.append((ws, rm))
        // Энергосбережение (уведомление приходит на произвольном потоке).
        let lp = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotionInputs() }
        }
        observers.append((NotificationCenter.default, lp))
        // Батарея/сеть: IOKit шлёт уведомление при смене источника питания (run loop source, не опрос).
        let box = Unmanaged.passRetained(WeakCenterBox(self))
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let center = Unmanaged<WeakCenterBox>.fromOpaque(ctx).takeUnretainedValue().center
            MainActor.assumeIsolated { center?.refreshMotionInputs() }
        }, box.toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
            powerBox = box
        } else {
            box.release()
        }
        // Блокировка и сессия известны по уведомлениям — а на старте их не было: прочитать как есть
        // (запуск при заблокированном экране / в фоновой сессии), без рассылки событий.
        if let s = Self.readSessionState() {
            set(\.isScreenLocked, s.locked)
            set(\.isSessionActive, s.onConsole)
        }
        refreshMotionInputs(publish: false)
    }

    public func stopMonitoring() {
        for (c, o) in observers { c.removeObserver(o) }
        observers.removeAll()
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        powerSource = nil
        powerBox?.release(); powerBox = nil
        isMonitoring = false
    }

    // MARK: Блокировка и сессия — сверка с системой

    /// Заблокирован ли экран и наша ли сессия на консоли — по `CGSessionCopyCurrentDictionary`
    /// (`CGSSessionScreenIsLocked`, `kCGSessionOnConsoleKey`). nil — словаря нет (не GUI-сессия).
    public nonisolated static func readSessionState() -> (locked: Bool, onConsole: Bool)? {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        let locked = (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
        let onConsole = (d["kCGSSessionOnConsoleKey"] as? Bool) ?? ((d["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? true)
        return (locked, onConsole)
    }

    /// Перечитать блокировку и сессию у системы и, если флаги разошлись (уведомление `screenIsUnlocked` не
    /// пришло: быстрое переключение пользователей, запуск при заблокированном экране), разослать недостающее
    /// событие. Ядро зовёт это само на пробуждении и возврате сессии, пока идёт наблюдение.
    public func refreshSessionState() {
        guard let s = Self.readSessionState() else { return }
        applySessionState(locked: s.locked, onConsole: s.onConsole)
    }

    /// Привести флаги к фактическому состоянию (для `refreshSessionState` и самотестов): расхождение → событие
    /// `.screenLocked/.screenUnlocked`, `.sessionDidResignActive/.sessionDidBecomeActive`.
    public func applySessionState(locked: Bool, onConsole: Bool) {
        guard !refreshingSession else { return }
        refreshingSession = true
        defer { refreshingSession = false }
        if onConsole != isSessionActive { handle(onConsole ? .sessionDidBecomeActive : .sessionDidResignActive) }
        if locked != isScreenLocked { handle(locked ? .screenLocked : .screenUnlocked) }
    }

    /// Настройка «на батарее — без анимаций».
    public func setReduceMotionOnBattery(_ on: Bool) {
        guard on != reduceMotionOnBattery else { return }
        reduceMotionOnBattery = on
        recomputeMotion(publish: true)
    }

    /// Перечитать «Уменьшить движение», энергосбережение и питание.
    public func refreshMotionInputs(publish: Bool = true) {
        let rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let lp = ProcessInfo.processInfo.isLowPowerModeEnabled
        let bat = Self.readOnBattery()
        if rm != reduceMotion { reduceMotion = rm }
        if lp != isLowPowerMode { isLowPowerMode = lp }
        if bat != isOnBattery { isOnBattery = bat }
        recomputeMotion(publish: publish)
    }

    /// Питание от батареи сейчас (IOKit, без опроса — для разового чтения).
    public nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    // MARK: События

    /// Обработать событие: обновить флаги, пересчитать `motion`, разослать подписчикам.
    /// Ядро зовёт это и для `.screensChanged` (после склейки); самотесты — чтобы сымитировать систему.
    public func handle(_ event: IslandSystemEvent) {
        switch event {
        case .willSleep: set(\.isAsleep, true)
        case .didWake: set(\.isAsleep, false); set(\.areScreensAsleep, false)
        case .screensDidSleep: set(\.areScreensAsleep, true)
        case .screensDidWake: set(\.areScreensAsleep, false)
        case .sessionDidResignActive: set(\.isSessionActive, false)
        case .sessionDidBecomeActive: set(\.isSessionActive, true)
        case .screenLocked: set(\.isScreenLocked, true)
        case .screenUnlocked: set(\.isScreenLocked, false)
        case .screensChanged, .motionChanged: break
        }
        recomputeMotion(publish: false)
        emit(event)
        // Пробуждение / возврат сессии: блокировку сверить с системой (её уведомление могло потеряться).
        if isMonitoring, [.didWake, .screensDidWake, .sessionDidBecomeActive].contains(event) {
            refreshSessionState()
        }
    }

    /// Для самотестов: подменить входы уровня движения.
    public func simulateMotionInputs(reduceMotion: Bool? = nil, lowPower: Bool? = nil, onBattery: Bool? = nil) {
        if let v = reduceMotion { self.reduceMotion = v }
        if let v = lowPower { isLowPowerMode = v }
        if let v = onBattery { isOnBattery = v }
        recomputeMotion(publish: true)
    }

    private func set(_ kp: ReferenceWritableKeyPath<SystemStateCenter, Bool>, _ v: Bool) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func recomputeMotion(publish: Bool) {
        let m: IslandMotion
        if !isInteractive { m = .off }
        // Энергосбережение анимации острова больше не глушит (просьба пользователя 16.11: «сделай, чтобы и в энергорежиме
        // работала анимация») — анимации дешёвые (Core Animation, ≤15–30 к/с). Упрощает только «Уменьшить движение» и
        // опция «на батарее».
        else if reduceMotion || (isOnBattery && reduceMotionOnBattery) { m = .reduced }
        else { m = .full }
        guard m != motion else { return }
        motion = m
        if publish { emit(.motionChanged) }
    }

    private func emit(_ e: IslandSystemEvent) {
        eventCount += 1
        events.send(e)
        for list in handlers.values { for (_, h) in list { h(e) } }
    }

    // MARK: Подписки модулей

    /// Подписка модуля (снимается `removeHandlers(owner:)`, ядро зовёт это при остановке модуля).
    @discardableResult
    public func addHandler(owner: String, _ h: @escaping @MainActor (IslandSystemEvent) -> Void) -> Int {
        handlerSeq += 1
        handlers[owner, default: []].append((handlerSeq, h))
        return handlerSeq
    }

    public func removeHandler(owner: String, token: Int) {
        handlers[owner]?.removeAll { $0.0 == token }
    }

    public func removeHandlers(owner: String) { handlers[owner] = nil }
}

/// Слабая ссылка на центр для контекста C-обратного вызова IOKit.
private final class WeakCenterBox {
    weak var center: SystemStateCenter?
    init(_ c: SystemStateCenter) { center = c }
}

public extension ModuleContext {
    /// Состояние системы (сон, блокировка, «Уменьшить движение», энергосбережение, батарея) и поток событий.
    var system: SystemStateCenter { .shared }

    /// Подписаться на системные события (сон/пробуждение, экраны, сессия, блокировка, смена уровня движения).
    /// Подписка живёт до `removeSystemEventHandlers()` — ядро снимает её само при остановке модулей.
    /// После `.didWake`/`.screensDidWake`/`.sessionDidBecomeActive` модулю нужно перевесить слушатели
    /// (event tap, источник «что играет», сокеты): система их могла выключить во сне.
    @discardableResult
    func onSystemEvent(_ handler: @escaping @MainActor (IslandSystemEvent) -> Void) -> Int {
        SystemStateCenter.shared.addHandler(owner: moduleId, handler)
    }

    /// Снять все подписки модуля на системные события.
    func removeSystemEventHandlers() { SystemStateCenter.shared.removeHandlers(owner: moduleId) }

    /// Уровень движения сейчас (для не-SwiftUI кода; во вьюхах — `@Environment(\.islandMotion)`).
    var motion: IslandMotion { SystemStateCenter.shared.motion }
}
