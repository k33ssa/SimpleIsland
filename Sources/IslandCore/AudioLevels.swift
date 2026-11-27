import Foundation

/// Уровни настоящего звука для эквалайзера (`Visualizer(feed:)`): модуль-источник (Медиа) считает полосы из захвата
/// звука и публикует их сюда ≤ 20 раз в секунду; полоски (`AnimatedBars`) подписываются напрямую, мимо SwiftUI —
/// обновление уровней не гоняет `body` и раскладку острова, только свойства слоёв Core Animation.
///
/// Спрос: полоска, которая сейчас в окне и анимирована (играет, `islandMotion == .full`, не снимок), регистрирует
/// себя (`addSink`). Нет ни одной — `hasDemand == false`, источник освобождает захват (`onDemandChange`).
/// Нет данных (нет права, захват не создался, тишина-нули) — `isLive == false`, полоски крутят прежнюю псевдоанимацию.
@MainActor
public final class AudioLevelsFeed {
    /// Число «широких» полос (раскрытый остров) и «узких» (компакт).
    public static let wideCount = 24
    public static let compactCount = 5

    /// Идут настоящие уровни.
    public private(set) var isLive = false
    /// Уровни 0…1: 24 полосы (низ → верх по частоте) и 5 для компакта.
    public private(set) var wide: [Float] = Array(repeating: 0, count: AudioLevelsFeed.wideCount)
    public private(set) var compact: [Float] = Array(repeating: 0, count: AudioLevelsFeed.compactCount)
    /// Сколько секунд до следующего обновления (длительность анимации слоя между уровнями).
    public private(set) var interval: Double = 0.085
    /// Сколько раз опубликовано (самотест).
    public private(set) var publishCount = 0

    /// Спрос появился/пропал (вызывается при смене `hasDemand`).
    public var onDemandChange: ((Bool) -> Void)?

    private var sinks: [ObjectIdentifier: (AudioLevelsFeed) -> Void] = [:]

    public init() {}

    public var hasDemand: Bool { !sinks.isEmpty }
    public var sinkCount: Int { sinks.count }

    /// Подписать полоску (владелец — ключ; повторная подписка заменяет обработчик).
    public func addSink(_ owner: AnyObject, _ fn: @escaping (AudioLevelsFeed) -> Void) {
        let had = hasDemand
        sinks[ObjectIdentifier(owner)] = fn
        if !had { onDemandChange?(true) }
    }

    public func removeSink(_ owner: AnyObject) {
        guard sinks.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        if sinks.isEmpty { onDemandChange?(false) }
    }

    /// Новые уровни (с главного потока).
    public func publish(wide w: [Float], compact c: [Float], interval: Double) {
        wide = w
        compact = c
        self.interval = max(0.03, min(0.3, interval))
        publishCount += 1
        isLive = true
        notify()
    }

    /// Настоящих уровней больше нет (пауза, захват остановлен/не удался) — полоски вернутся к псевдоанимации.
    public func setIdle() {
        guard isLive else { return }
        isLive = false
        wide = Array(repeating: 0, count: Self.wideCount)
        compact = Array(repeating: 0, count: Self.compactCount)
        notify()
    }

    /// Уровни для `count` полосок: 5 — компактные, остальное — широкие (пересчёт по ближайшей).
    public func levels(count: Int) -> [Float] {
        if count == Self.compactCount { return compact }
        if count == Self.wideCount { return wide }
        guard count > 0 else { return [] }
        return (0..<count).map { i in wide[min(Self.wideCount - 1, i * Self.wideCount / count)] }
    }

    private func notify() {
        for fn in sinks.values { fn(self) }
    }
}
