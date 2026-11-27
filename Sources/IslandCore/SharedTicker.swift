import Combine
import Foundation

/// Один общий тикер на процесс вместо `Timer.scheduledTimer` в каждом модуле (грабли E1: у Boring Notch
/// утекло 2243 NSTimer и 26–41 % CPU в покое).
///
/// * Один `DispatchSourceTimer` на главной очереди с допуском (`leeway`) 10 % интервала — система склеивает
///   пробуждения.
/// * Работает, только пока есть подписчики: последний отписался → таймер снят.
/// * Во сне, при выключенных экранах, заблокированном экране и в чужой сессии — пауза; после возврата
///   каждый подписчик получает один «догоняющий» тик.
/// * Тики выровнены по стенным часам (интервал 1 с — на границе секунды, 60 с — на границе минуты): часы и
///   обратные отсчёты меняются одновременно с системными.
///
/// ```swift
/// tick = SharedTicker.shared.subscribe(every: 1) { [weak self] now in self?.updateCountdown(now) }
/// // tick = nil или tick.cancel() — отписка (держать AnyCancellable обязательно)
/// ```
/// Интервал меньше 1 с — только пока что-то видно и реально двигается (правила модулей, ARCHITECTURE.md).
@MainActor
public final class SharedTicker {
    public static let shared = SharedTicker(system: .shared)

    private struct Sub {
        var interval: TimeInterval
        var next: Date
        var handler: @MainActor (Date) -> Void
    }

    private var subs: [Int: Sub] = [:]
    private var seq = 0
    private var timer: DispatchSourceTimer?
    private var armedFor: Date?
    private let system: SystemStateCenter
    private var systemSub: AnyCancellable?
    /// Система «интерактивна» (не сон/блокировка). Своя копия: @Published шлёт значение ДО записи в свойство.
    private var systemRunning: Bool
    /// Сколько раз срабатывал системный таймер (для самотестов).
    public private(set) var fireCount = 0

    public init(system: SystemStateCenter) {
        self.system = system
        self.systemRunning = system.isInteractive
        systemSub = system.$isAsleep.combineLatest(system.$areScreensAsleep, system.$isSessionActive, system.$isScreenLocked)
            .map { asleep, screens, active, locked in !asleep && !screens && active && !locked }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] running in
                MainActor.assumeIsolated { self?.systemRunningChanged(running) }
            }
    }

    /// Работает ли сейчас системный таймер (нет подписчиков или пауза — false).
    public var isRunning: Bool { timer != nil }
    public var subscriberCount: Int { subs.count }
    public var isPaused: Bool { !systemRunning }

    /// Подписаться: `handler` зовётся раз в `interval` секунд (не чаще 1/30 с) на главном потоке.
    /// Вернёт токен: пока он жив — подписка жива.
    public func subscribe(every interval: TimeInterval, _ handler: @escaping @MainActor (Date) -> Void) -> AnyCancellable {
        let iv = max(1.0 / 30, interval)
        seq += 1
        let id = seq
        subs[id] = Sub(interval: iv, next: Self.aligned(after: Date(), interval: iv), handler: handler)
        reschedule()
        // Токен могут отпустить и не на главном потоке (модуль освобождается в фоне) — тогда отписка уходит на
        // главную очередь, а не роняет процесс на `assumeIsolated`.
        return AnyCancellable { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.unsubscribe(id) }
            } else {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.unsubscribe(id) } }
            }
        }
    }

    private func unsubscribe(_ id: Int) {
        guard subs.removeValue(forKey: id) != nil else { return }
        reschedule()
    }

    /// Следующий момент, кратный интервалу по стенным часам.
    static func aligned(after date: Date, interval: TimeInterval) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(t / interval) + 1) * interval)
    }

    private func systemRunningChanged(_ running: Bool) {
        systemRunning = running
        if running {
            // Догоняющий тик сразу после пробуждения, дальше — по сетке.
            let now = Date()
            for (id, var s) in subs { s.next = now; subs[id] = s }
        }
        reschedule()
    }

    private func reschedule() {
        guard !subs.isEmpty, systemRunning, let next = subs.values.map(\.next).min() else {
            timer?.cancel(); timer = nil; armedFor = nil
            return
        }
        if armedFor == next, timer != nil { return }
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
            timer = t
            t.resume()
        }
        let minInterval = subs.values.map(\.interval).min() ?? 1
        let leeway = DispatchTimeInterval.milliseconds(max(5, Int(minInterval * 100)))   // 10 %
        let delay = max(0, next.timeIntervalSinceNow)
        timer?.schedule(deadline: .now() + delay, repeating: .never, leeway: leeway)
        armedFor = next
    }

    private func fire() {
        fireCount += 1
        armedFor = nil
        let now = Date()
        // Допуск: тик, пришедший чуть раньше срока (leeway), считается вовремя.
        let due = subs.filter { $0.value.next.timeIntervalSince(now) <= $0.value.interval * 0.1 }
        for (id, s) in due {
            // Следующий — по сетке; если до узла сетки меньше четверти интервала (тик пришёл рано в пределах
            // допуска или это «догоняющий» тик после сна) — через узел, чтобы не было двух тиков подряд.
            var next = Self.aligned(after: now, interval: s.interval)
            if next.timeIntervalSince(now) < s.interval * 0.25 { next.addTimeInterval(s.interval) }
            subs[id]?.next = next
        }
        for (id, s) in due where subs[id] != nil { s.handler(now) }
        reschedule()
    }
}
