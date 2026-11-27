import AppKit
import ApplicationServices
import CoreGraphics
import IslandCore

/// Перенос чужого значка строки меню синтетическим ⌘-перетаскиванием и нажатие на значок через AX.
///
/// Подход изучен у Ice (GPL-3.0 — код не брали, только идею, docs/MENUBAR.md §3.4): macOS сама переставляет
/// значки при ⌘-перетаскивании; события мыши с ⌘ и номером окна значка в полях события доходят до значка, даже
/// если он не на экране (под вырезом или за разделителем). Нужен Универсальный доступ.
///
/// Два способа (15.11.2026, после жалобы «Не вышло показать eqMac в строке меню»):
/// * `.offscreen` (основной, как у Ice): нажатие с ⌘ **в точке вне всех экранов** (20000, 20000) с номером окна
///   значка в полях, отпускание без ⌘ у цели с номером окна цели; промежуточных событий нет. Где сейчас значок — не
///   важно: под вырезом, за разделителем, на другом мониторе. Прежний способ нажимал в центр рамки значка — у
///   значка под вырезом это зона острова, и нажатие получал остров, а не значок.
/// * `.direct` (запасной, вторая попытка, только для значка на экране): нажатие в центре значка, 6 шагов
///   перетаскивания, отпускание у цели — как человек.
/// На время событий все наши окна пропускают мышь (`SyntheticMouse`): оверлей уборки на весь экран и остров над
/// вырезом иначе перехватывали события (вторая причина неудач, в т. ч. «скрыть системный значок»).
@MainActor
final class MenuBarMover {
    enum Side: String { case leftOf, rightOf }
    /// `.agent` — macOS 27 (окон у значков нет): как `.direct`, но с паузами и шагами, проверенными вживую 20.11
    /// (движение → нажатие с ⌘ → 150 мс → 10 шагов по 30 мс → 150 мс → отпускание, уровень HID), без полей окна.
    enum Style: String { case offscreen, direct, agent }
    /// Почему события не ушли (для честного сообщения пользователю).
    enum Failure: String {
        /// Нет Универсального доступа (AXIsProcessTrusted = false) — macOS не примет синтетические события.
        case noAccess
        /// Уже идёт другой перенос.
        case busy
        /// Зажаты клавиши/кнопки мыши или идёт набор текста — ждали и не дождались.
        case inputBusy
        /// Сброс/выключение у вызывающего.
        case cancelled
    }

    /// Сколько событий отправлено в систему за процесс (самотест проверяет, что 0).
    static fileprivate(set) var postedEvents = 0
    /// Самотест: события не отправляются никогда (drag сразу отвечает false).
    static var dryRun = false
    private(set) var isBusy = false
    /// Почему последний `drag` ответил false (nil — события ушли).
    var lastFailure: Failure?
    /// Самотест: события не уходят в систему, а пишутся сюда; курсор не трогается, право не проверяется.
    var testSink: ((CGEvent) -> Void)?
    /// Самотест: подменить «ввод свободен».
    var testIdle: (() -> Bool)?

    /// Точка нажатия способа `.offscreen`: вне любого разумного набора экранов (как у Ice).
    nonisolated static let offscreenPoint = CGPoint(x: 20_000, y: 20_000)

    /// Точка броска. `.offscreen`: край цели (левый — встать левее неё, правый — правее), как у Ice: значок не
    /// «поднимается» из строки, сдвига нет. `.direct`: значок, поднятый правее цели, освобождает место — всё левее
    /// него (и цель) сдвигается вправо на его ширину — поправка заранее; бросок на левую часть цели ставит значок
    /// левее неё, на правую — правее.
    nonisolated static func destination(item: CGRect, target: CGRect, side: Side, style: Style = .direct) -> CGPoint {
        if style == .offscreen {
            return CGPoint(x: side == .leftOf ? target.minX : target.maxX, y: target.midY)
        }
        if style == .agent {
            // Бросок в 3 pt от края цели внутри неё: левее — левая часть, правее — правая (проверено 20.11: значок,
            // брошенный у правого края Claude, встал правее него).
            let inset = min(3, target.width / 3)
            return CGPoint(x: side == .leftOf ? target.minX + inset : target.maxX - inset, y: target.midY)
        }
        let inset = min(4, target.width / 3)
        var x = side == .leftOf ? target.minX + inset : target.maxX - inset
        if item.midX > target.midX { x += item.width }
        return CGPoint(x: x, y: target.midY)
    }

    /// Ничего не зажато (кнопки мыши, модификаторы) и клавиатура молчит `typingPause` секунд — можно начинать.
    nonisolated static func inputIsIdle(typingPause: TimeInterval = 0) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let typed = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return flags.intersection(mods).isEmpty
            && !CGEventSource.buttonState(.combinedSessionState, button: .left)
            && !CGEventSource.buttonState(.combinedSessionState, button: .right)
            && typed >= typingPause
    }

    /// Перетащить значок (`item`, окно `itemWindow` процесса `pid`) к цели (`target`, окно `targetWindow`).
    /// `completion(true)` — события отправлены (итог проверяет вызывающий по рамкам); false — не отправлены.
    /// `isCancelled` — сброс/выключение у вызывающего («поколение» модели): проверяется после ожидания тишины ввода
    /// (до 8 с) и между событиями. Отменили после нажатия — сразу отпускание (кнопка мыши не «залипает»).
    func drag(itemWindow: CGWindowID, pid: pid_t, item: CGRect, targetWindow: CGWindowID, target: CGRect, side: Side,
              style: Style = .offscreen, typingPause: TimeInterval = 0,
              isCancelled: @escaping @MainActor () -> Bool = { false },
              completion: @escaping @MainActor (Bool) -> Void) {
        let testing = testSink != nil
        let fail = { [weak self] (f: Failure) in self?.lastFailure = f; completion(false) }
        guard !isBusy else { fail(.busy); return }
        guard !isCancelled() else { fail(.cancelled); return }
        guard testing || (!Self.dryRun && AXIsProcessTrusted()) else { fail(.noAccess); return }
        lastFailure = nil
        isBusy = true
        waitForIdle(tries: typingPause > 0 ? 40 : 15, typingPause: typingPause) { [weak self] idle in
            guard let self else { return }
            guard idle, !isCancelled() else { self.isBusy = false; fail(idle ? .cancelled : .inputBusy); return }
            self.performDrag(itemWindow: itemWindow, pid: pid, item: item, targetWindow: targetWindow,
                             target: target, side: side, style: style, isCancelled: isCancelled, completion: completion)
        }
    }

    private func waitForIdle(tries: Int, typingPause: TimeInterval, _ done: @escaping @MainActor (Bool) -> Void) {
        if testIdle?() ?? Self.inputIsIdle(typingPause: typingPause) { done(true); return }
        if tries <= 0 { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.waitForIdle(tries: tries - 1, typingPause: typingPause, done) }
        }
    }

    private func performDrag(itemWindow: CGWindowID, pid: pid_t, item: CGRect, targetWindow: CGWindowID,
                             target: CGRect, side: Side, style: Style, isCancelled: @escaping @MainActor () -> Bool,
                             completion: @escaping @MainActor (Bool) -> Void) {
        let testing = testSink != nil
        let end = Self.destination(item: item, target: target, side: side, style: style)
        if style == .agent && !testing {
            performAgentDrag(from: CGPoint(x: item.midX, y: item.midY), to: end, isCancelled: isCancelled,
                             completion: completion)
            return
        }
        let saved = CGEvent(source: nil)?.location ?? CGPoint(x: item.midX, y: item.midY)
        // `.offscreen` — как у Ice: состояние HID-системы, ⌘ только у нажатия (отпускание без флагов — ⌘ не
        // «залипает»). `.direct` — своё состояние источника, ⌘ у всех событий.
        let source = CGEventSource(stateID: style == .offscreen ? .hidSystemState : .privateState)
        let start = style == .offscreen ? Self.offscreenPoint : CGPoint(x: item.midX, y: item.midY)
        // Пока идут наши события, локальные события пользователя не глушатся, а наши — не глушатся системой.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents,
                                                            .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateRemoteMouseDrag)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents,
                                                            .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        source?.localEventsSuppressionInterval = 0
        // Наши окна (оверлей уборки, остров над вырезом) пропускают мышь — иначе событие достанется им.
        SyntheticMouse.begin()
        // Пока идёт перенос, движение мыши пользователя курсор не двигает (иначе бросок уедет).
        if !testing {
            CGAssociateMouseAndMouseCursorPosition(0)
            CGDisplayHideCursor(CGMainDisplayID())
        }

        var events: [CGEvent] = []
        func make(_ type: CGEventType, _ p: CGPoint, window: CGWindowID, command: Bool) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return nil }
            e.flags = command ? .maskCommand : []
            let w = Int64(window)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: w)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: w)
            guard style != .agent else { return e }   // 27: окон у значков нет — поля не ставим
            if let f = CGEventField(rawValue: 0x33) { e.setIntegerValueField(f, value: w) }   // номер окна (недокументировано)
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            return e
        }
        let expected: Int
        switch style {
        case .offscreen:
            expected = 2
            if let d = make(.leftMouseDown, start, window: itemWindow, command: true) { events.append(d) }
            if let u = make(.leftMouseUp, end, window: targetWindow, command: false) { events.append(u) }
        case .direct:
            expected = 8
            if let d = make(.leftMouseDown, start, window: itemWindow, command: true) { events.append(d) }
            for i in 1...6 {
                let t = CGFloat(i) / 6
                let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let e = make(.leftMouseDragged, p, window: i == 6 ? targetWindow : itemWindow, command: true) {
                    events.append(e)
                }
            }
            if let u = make(.leftMouseUp, end, window: targetWindow, command: true) { events.append(u) }
        case .agent:
            expected = 13
            if let m = make(.mouseMoved, start, window: 0, command: true) { events.append(m) }
            if let d = make(.leftMouseDown, start, window: 0, command: true) { events.append(d) }
            for i in 1...10 {
                let t = CGFloat(i) / 10
                let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let e = make(.leftMouseDragged, p, window: 0, command: true) { events.append(e) }
            }
            if let u = make(.leftMouseUp, end, window: 0, command: true) { events.append(u) }
        }

        func finish() {
            SyntheticMouse.end()
            guard !testing else { return }
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        guard events.count == expected else {
            finish(); isBusy = false; lastFailure = .cancelled; completion(false); return
        }
        // `.offscreen`: между нажатием и отпусканием — пауза побольше, строке меню нужно «поднять» значок.
        let step: TimeInterval = style == .offscreen ? 0.05 : style == .agent ? 0.03 : 0.025
        // 27: после нажатия и перед отпусканием строке нужно 150 мс — «поднять» и «положить» значок.
        let pauses: [Int: TimeInterval] = style == .agent ? [1: 0.06, 2: 0.15, 12: 0.15] : [:]
        post(events, index: 0, step: step, pauses: pauses, hid: style == .agent,
             isCancelled: isCancelled) { [weak self] cancelled in
            finish()
            if cancelled { self?.lastFailure = .cancelled }
            // Строке меню нужно время переставить окна.
            DispatchQueue.main.asyncAfter(deadline: .now() + (cancelled ? 0 : 0.35)) {
                MainActor.assumeIsolated { self?.isBusy = false; completion(!cancelled) }
            }
        }
    }

    /// По одному событию с шагом `step`. Отменили посреди (после нажатия) — сразу последнее событие (отпускание).
    /// macOS 27: ровно как живая проба 20.11 (единственный проверенный вариант): события в отдельном потоке с
    /// `usleep`, источник privateState, уровень HID, курсор отвязан от мыши на время и возвращается; без глушения
    /// локальных событий и без прятания курсора (с ними и с отправкой через главную очередь значок не двигался — та же
    /// строка, 20.11).
    private func performAgentDrag(from start: CGPoint, to end: CGPoint, isCancelled: @escaping @MainActor () -> Bool,
                                  completion: @escaping @MainActor (Bool) -> Void) {
        SyntheticMouse.begin()
        DispatchQueue.global(qos: .userInteractive).async {
            let saved = CGEvent(source: nil)?.location ?? start
            let src = CGEventSource(stateID: .privateState)
            CGAssociateMouseAndMouseCursorPosition(0)
            func post(_ t: CGEventType, _ p: CGPoint) {
                guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left) else { return }
                e.flags = .maskCommand
                e.post(tap: .cghidEventTap)
                usleep(30_000)
            }
            post(.mouseMoved, start); usleep(60_000)
            post(.leftMouseDown, start); usleep(150_000)
            for i in 1...10 {
                let t = CGFloat(i) / 10
                post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            usleep(150_000)
            post(.leftMouseUp, end)
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MenuBarMover.postedEvents += 13
                    SyntheticMouse.end()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { self.isBusy = false; completion(!isCancelled()) }
                    }
                }
            }
        }
    }

    /// `pauses[i]` — задержка перед событием i вместо `step`; `hid` — слать на уровень HID (27).
    private func post(_ events: [CGEvent], index: Int, step: TimeInterval, pauses: [Int: TimeInterval] = [:],
                      hid: Bool = false, isCancelled: @escaping @MainActor () -> Bool,
                      done: @escaping @MainActor (Bool) -> Void) {
        guard index < events.count else { done(false); return }
        if isCancelled() {
            if index > 0 { send(events[events.count - 1], hid: hid) }   // нажатие уже ушло — отпустить
            done(true); return
        }
        send(events[index], hid: hid)
        let delay = pauses[index + 1] ?? step
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.post(events, index: index + 1, step: step, pauses: pauses, hid: hid, isCancelled: isCancelled, done: done)
            }
        }
    }

    private func send(_ e: CGEvent, hid: Bool = false) {
        if let testSink { testSink(e); return }
        e.post(tap: hid ? .cghidEventTap : .cgSessionEventTap)
        Self.postedEvents += 1
    }

    /// Нажать на значок через AX (`AXPress`): без курсора и без событий мыши. true — действие принято.
    nonisolated(unsafe) static var pressDisabled = false
    nonisolated static func press(pid: pid_t, frame: CGRect) -> Bool {
        guard !pressDisabled, AXIsProcessTrusted(), let el = MenuBarScanner.axElement(pid: pid, near: frame) else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
}
