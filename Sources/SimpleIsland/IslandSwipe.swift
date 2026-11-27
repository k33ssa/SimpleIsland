import AppKit
import SwiftUI
import IslandCore

/// Фаза события прокрутки (из `NSEvent.phase` / `momentumPhase`). Инерция после отпускания пальцев — `.momentum`.
enum ScrollPhase: Equatable {
    case mayBegin, began, changed, ended, cancelled, momentum
    /// Событие без фаз (колесо, старые устройства).
    case none

    init(phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        if !momentum.isEmpty { self = .momentum; return }
        if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) || phase.contains(.stationary) { self = .changed }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else if phase.contains(.mayBegin) { self = .mayBegin }
        else { self = .none }
    }
}

/// Раскрытость острова во время интерактивного свайпа (27.11, «следил за движением пальцев»). Отдельный объект, а
/// не поле `IslandModel`: на каждое событие прокрутки меняется только он, и пересчитывается одна корневая вьюха —
/// `ExpandedContent` (подписан на модель) на каждый кадр не пересобирается.
@MainActor
final class IslandSwipeState: ObservableObject {
    /// nil — жеста нет; иначе 0…1: 0 — покой/компакт/HUD/уведомление, 1 — раскрыт.
    @Published fileprivate(set) var progress: CGFloat?
}

extension IslandMetrics {
    /// Промежуточная форма между `a` и `b` (t = 0…1).
    static func lerp(_ a: IslandMetrics, _ b: IslandMetrics, _ t: CGFloat) -> IslandMetrics {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return IslandMetrics(width: mix(a.width, b.width), height: mix(a.height, b.height),
                             cornerRadius: mix(a.cornerRadius, b.cornerRadius), earRadius: mix(a.earRadius, b.earRadius),
                             topCornerRadius: mix(a.topCornerRadius, b.topCornerRadius))
    }
}

/// Проявление раскрытой вкладки по ходу свайпа: прозрачность и масштаб под текущую ширину формы (вкладка свёрстана
/// в конечном размере — масштаб только рисуется, без перерасчёта раскладки). Без жеста — как есть.
struct SwipeReveal: ViewModifier {
    var progress: CGFloat?
    /// Ширина формы сейчас / ширина раскрытого.
    var fit: CGFloat = 1
    func body(content: Content) -> some View {
        let p = progress ?? 1
        let t = min(1, max(0, (p - 0.2) / 0.6))
        content
            .opacity(Double(t * t * (3 - 2 * t)))
            .scaleEffect(progress == nil ? 1 : min(1, max(0.3, fit)), anchor: .top)
    }
}

/// Интерактивный свайп: трекпад двумя пальцами (фазы began/changed/ended) и «потянуть» мышью. Прогресс =
/// старт (0 или 1) + сдвиг / расстояние (разница высот покоя и раскрытого, 120…320 pt); на отпускании — пружиной
/// к ближнему краю или по скорости. Колесо, «Уменьшить движение», окно не видно и события без фаз — прежний порог.
extension IslandModel {
    /// Скорость (pt/с) в сторону открытия/закрытия, после которой решает она, а не середина.
    nonisolated static let swipeFlickVelocity: CGFloat = 450
    /// Сдвиг, после которого жест начинает менять форму (мелкая дрожь пальцев не трогает остров).
    nonisolated static let swipeDeadZone: CGFloat = 3
    /// Окно оценки скорости перед отпусканием.
    nonisolated static let swipeVelocityWindow: TimeInterval = 0.1
    /// Порог прежнего (не интерактивного) срабатывания трекпада.
    nonisolated static let swipeLegacyThreshold: CGFloat = 10

    /// Интерактивно — только при полном движении: `.reduced`/`.off` и покой (уборка строки меню) — по порогу.
    var interactiveSwipeAllowed: Bool { motion == .full && !calm && !env.enabledTabModules.isEmpty }

    /// Сколько ушло в интерактивный прогресс (для самотеста и отладки).
    var swipeProgress: CGFloat? { swipe.progress }

    /// Вкладка, на которой откроется остров из текущего состояния (как `expandFromCurrent`).
    func swipeTargetTab() -> String? {
        if presentation == .notification, let n = env.notifications.current { return n.opensTab ?? n.moduleId }
        if presentation == .compact, let a = env.settings.data.compactOwner(in: env.activities) { return a.opensTab ?? a.moduleId }
        return selectedTab ?? env.enabledTabModules.first?.id
    }

    /// Свайп двумя пальцами (вниз — раскрыть, вверх — свернуть) или щелчок колеса мыши. Трекпад с фазами —
    /// интерактивно (`track`); колесо (`precise == false`): каждый щелчок переключает; без фаз — дельты копятся за
    /// жест (пауза 0,35 с — новый), срабатывает один раз.
    func scroll(physicalDeltaY dy: CGFloat, precise: Bool, phase: ScrollPhase,
                time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard precise ? env.settings.data.swipeGestures : env.settings.data.wheelGestures else { return }  // settings
        guard precise else {
            if dy > 0.1, !expanded { expand() } else if dy < -0.1, expanded { collapse() }
            return
        }
        switch phase {
        case .began:
            scrollAccum = dy
            track(total: scrollAccum, phase: .began, time: time, legacyOpen: { $0.expand() })
        case .changed, .ended, .cancelled:
            scrollAccum += dy
            track(total: scrollAccum, phase: phase, time: time, legacyOpen: { $0.expand() })
        case .momentum:
            // Инерция после отпускания: в интерактивном жесте не используется; прежний путь копил её в тот же жест.
            guard !gestureInteractive else { return }
            scrollAccum += dy
            legacyStep(total: scrollAccum, threshold: Self.swipeLegacyThreshold, open: { $0.expand() })
        case .mayBegin, .none:
            let now = Date()
            if phase == .mayBegin || now.timeIntervalSince(lastScroll) > 0.35 { scrollAccum = 0; legacyFired = false }
            lastScroll = now
            gestureInteractive = false
            scrollAccum += dy
            legacyStep(total: scrollAccum, threshold: Self.swipeLegacyThreshold, open: { $0.expand() })
        }
        lastScroll = Date()
    }

    /// «Потянуть» (нажал и тянешь): `translation` — сдвиг от начала жеста, вниз +. Прежний порог — 12 pt.
    func pull(translation dy: CGFloat, phase: ScrollPhase, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard env.settings.data.swipeGestures else { return }
        track(total: dy, phase: phase, time: time, threshold: 12, legacyOpen: { $0.expandFromCurrent() })
    }

    /// Общий путь трекпада и «потянуть».
    private func track(total: CGFloat, phase: ScrollPhase, time: TimeInterval, threshold: CGFloat = swipeLegacyThreshold,
                       legacyOpen: (IslandModel) -> Void) {
        if phase == .began {
            legacyFired = false
            gestureInteractive = interactiveSwipeAllowed
            if gestureInteractive { swipeBegin(time: time) }
        }
        guard gestureInteractive else {
            legacyStep(total: total, threshold: threshold, open: legacyOpen)
            return
        }
        swipeUpdate(total: total, time: time)
        if phase == .ended || phase == .cancelled {
            gestureInteractive = false
            legacyFired = true   // хвост жеста (инерция) прежним порогом не срабатывает
            swipeEnd(time: time, cancelled: phase == .cancelled)
        }
    }

    private func legacyStep(total: CGFloat, threshold: CGFloat, open: (IslandModel) -> Void) {
        guard !legacyFired else { return }
        if total > threshold, !expanded { open(self); legacyFired = true }
        else if total < -threshold, expanded { collapse(); legacyFired = true }
    }

    // MARK: Интерактивный прогресс

    private func swipeBegin(time: TimeInterval) {
        swipeStartOpen = expanded
        swipeSamples = [(time, 0)]
    }

    private func swipeUpdate(total: CGFloat, time: TimeInterval) {
        swipeSamples.append((time, total))
        if swipeSamples.count > 24 { swipeSamples.removeFirst(swipeSamples.count - 24) }
        let start: CGFloat = swipeStartOpen ? 1 : 0
        if swipe.progress == nil {
            // Форма начинает следовать, только когда тянут в свою сторону: вверх по свёрнутому — ничего.
            guard swipeStartOpen ? total < -Self.swipeDeadZone : total > Self.swipeDeadZone else { return }
            guard swipeStartOpen == expanded else { return }   // кто-то успел раскрыть/свернуть
            swipePrepare()
        }
        guard swipeDistance > 0 else { return }
        swipe.progress = min(1, max(0, start + total / swipeDistance))
    }

    /// Начало формы: вкладка-цель (из свёрнутого) и расстояние полного хода.
    private func swipePrepare() {
        swipeSavedTab = selectedTab
        if !swipeStartOpen, let t = swipeTargetTab() { selectedTab = t }
        let full = metrics(for: .expanded).height - metrics(for: restingPresentation).height
        swipeDistance = min(320, max(120, full))
    }

    private func swipeVelocity(at time: TimeInterval) -> CGFloat {
        let recent = swipeSamples.filter { time - $0.0 <= Self.swipeVelocityWindow }
        guard let a = recent.first, let b = recent.last, b.0 - a.0 > 0.004 else { return 0 }
        return (b.1 - a.1) / CGFloat(b.0 - a.0)
    }

    private func swipeEnd(time: TimeInterval, cancelled: Bool) {
        guard let p = swipe.progress else { swipeSamples = []; return }
        let v = swipeVelocity(at: time)
        swipeSamples = []
        let open: Bool
        if cancelled { open = swipeStartOpen }
        else if v > Self.swipeFlickVelocity { open = true }
        else if v < -Self.swipeFlickVelocity { open = false }
        else { open = p > 0.5 }
        finishSwipe(open: open)
    }

    /// Досвести: прогресс снимается в той же транзакции, где меняется `expanded`, — корневая вьюха ведёт форму
    /// от промежуточной к конечной пружиной темы.
    private func finishSwipe(open: Bool) {
        let wasOpen = swipeStartOpen
        swipe.progress = nil
        if open {
            if !expanded { expandFromCurrent() }
        } else {
            if expanded { collapse() }
            else if !wasOpen { selectedTab = swipeSavedTab }   // открытие отменили — вкладку не подменяем
        }
    }

    /// Прервать жест без досведения (явное раскрытие/сворачивание, сон, покой).
    func cancelSwipe() {
        if gestureInteractive { legacyFired = true }   // остаток прерванного жеста ничего не делает
        gestureInteractive = false
        swipeSamples = []
        if swipe.progress != nil { swipe.progress = nil }
    }

    /// Отладка и снимки: показать форму на прогрессе `p` (из текущего состояния), nil — снять.
    func previewSwipe(_ p: CGFloat?) {
        guard let p else { cancelSwipe(); return }
        if swipe.progress == nil {
            swipeStartOpen = expanded
            swipePrepare()
        }
        swipe.progress = min(1, max(0, p))
    }

    /// Зона кликов во время жеста — объединение покоя и раскрытого (курсор не «выпадает» из сжимающегося острова).
    var hitMetrics: IslandMetrics {
        guard swipe.progress != nil else { return currentMetrics }
        let a = metrics(for: restingPresentation), b = metrics(for: .expanded)
        var m = b
        m.width = max(a.width, b.width); m.earRadius = max(a.earRadius, b.earRadius)
        m.height = max(a.height, b.height)
        return m
    }
}
