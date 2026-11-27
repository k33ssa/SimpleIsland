import SwiftUI

/// Размеры острова в одном состоянии. Всё анимируется одной пружиной.
public struct IslandMetrics: Equatable, Sendable {
    /// Ширина тела острова (без «ушей»).
    public var width: CGFloat
    public var height: CGFloat
    /// Нижние углы.
    public var cornerRadius: CGFloat
    /// Вогнутые «уши» сверху (0 — нет).
    public var earRadius: CGFloat
    /// Выпуклые верхние углы — для плавающей капли без выреза (тогда ушей нет).
    public var topCornerRadius: CGFloat

    public init(width: CGFloat, height: CGFloat, cornerRadius: CGFloat, earRadius: CGFloat, topCornerRadius: CGFloat = 0) {
        self.width = width; self.height = height; self.cornerRadius = cornerRadius
        self.earRadius = earRadius; self.topCornerRadius = topCornerRadius
    }

    /// Полная ширина с ушами.
    public var outerWidth: CGFloat { width + 2 * earRadius }
}

/// Форма острова: низ скруглён, сверху вогнутые «уши» — сопряжение с краем экрана
/// (как `.island::before/::after` в design/mockups/base.css). Рисуется по центру `rect`, от его верха.
public struct IslandShape: Shape, Equatable {   // Equatable — RotatingConicStroke не перекладывает путь без изменений
    public var metrics: IslandMetrics
    /// true — открытый контур без верхней кромки (для обводки/rim).
    public var openTop: Bool
    /// > 0 — скругления ступеньками этого шага в pt (тема с `effects.pixelated`, 8 бит).
    public var pixelStep: CGFloat

    public init(_ metrics: IslandMetrics, openTop: Bool = false, pixelStep: CGFloat = 0) {
        self.metrics = metrics; self.openTop = openTop; self.pixelStep = pixelStep
    }

    /// Форма по теме: у темы с `effects.pixelated` углы ступеньками по 4 pt.
    public init(_ metrics: IslandMetrics, theme: Theme, openTop: Bool = false) {
        self.init(metrics, openTop: openTop, pixelStep: theme.effects.pixelated ? 4 : 0)
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                              AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(metrics.width, metrics.height),
                           AnimatablePair(metrics.cornerRadius, AnimatablePair(metrics.earRadius, metrics.topCornerRadius)))
        }
        set {
            metrics.width = newValue.first.first
            metrics.height = newValue.first.second
            metrics.cornerRadius = newValue.second.first
            metrics.earRadius = newValue.second.second.first
            metrics.topCornerRadius = newValue.second.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let smooth = smoothPath(in: rect)
        guard pixelStep > 0 else { return smooth }
        return Self.staircase(smooth, step: pixelStep, origin: CGPoint(x: rect.midX, y: rect.minY), closed: !openTop)
    }

    /// Ломаная из плавного контура, точки — на сетке `step`, соседние соединены по осям (ступеньки).
    static func staircase(_ smooth: Path, step: CGFloat, origin: CGPoint, closed: Bool) -> Path {
        var pts: [CGPoint] = []
        func snap(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + ((p.x - origin.x) / step).rounded() * step,
                    y: origin.y + ((p.y - origin.y) / step).rounded() * step)
        }
        smooth.cgPath.flattened(threshold: 0.5).applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: pts.append(snap(e.points[0]))
            default: break
            }
        }
        var out = Path()
        guard let first = pts.first else { return out }
        out.move(to: first)
        var last = first
        for p in pts.dropFirst() where p != last {
            // Сначала по горизонтали на верхней половине, по вертикали — на нижней: ступени смотрят наружу.
            let corner = p.y > last.y ? CGPoint(x: last.x, y: p.y) : CGPoint(x: p.x, y: last.y)
            if corner != last && corner != p { out.addLine(to: corner) }
            out.addLine(to: p)
            last = p
        }
        if closed { out.closeSubpath() }
        return out
    }

    private func smoothPath(in rect: CGRect) -> Path {
        let k: CGFloat = 0.5523 // кубическая аппроксимация четверти окружности
        let w = max(0, metrics.width), h = max(0, metrics.height)
        let x0 = rect.midX - w / 2, x1 = rect.midX + w / 2
        let t = rect.minY, b = rect.minY + h
        let r = max(0, min(metrics.cornerRadius, w / 2, h))
        let tr = max(0, min(metrics.topCornerRadius, w / 2, h - r))
        let e = tr > 0 ? 0 : max(0, min(metrics.earRadius, h - r))

        var p = Path()
        // Верх: от левого уха к правому
        if openTop {
            p.move(to: CGPoint(x: x1 + e, y: t))
            if tr > 0 { p.move(to: CGPoint(x: x1 - tr, y: t)) }
        } else {
            p.move(to: CGPoint(x: x0 - e + (tr > 0 ? tr : 0), y: t))
            p.addLine(to: CGPoint(x: (tr > 0 ? x1 - tr : x1 + e), y: t))
        }
        // Правый верх
        if tr > 0 {
            p.addCurve(to: CGPoint(x: x1, y: t + tr),
                       control1: CGPoint(x: x1 - tr + k * tr, y: t), control2: CGPoint(x: x1, y: t + tr - k * tr))
        } else if e > 0 {
            p.addCurve(to: CGPoint(x: x1, y: t + e),
                       control1: CGPoint(x: x1 + e - k * e, y: t), control2: CGPoint(x: x1, y: t + e - k * e))
        }
        // Правый бок и низ
        p.addLine(to: CGPoint(x: x1, y: b - r))
        p.addCurve(to: CGPoint(x: x1 - r, y: b),
                   control1: CGPoint(x: x1, y: b - r + k * r), control2: CGPoint(x: x1 - r + k * r, y: b))
        p.addLine(to: CGPoint(x: x0 + r, y: b))
        p.addCurve(to: CGPoint(x: x0, y: b - r),
                   control1: CGPoint(x: x0 + r - k * r, y: b), control2: CGPoint(x: x0, y: b - r + k * r))
        // Левый бок и левый верх
        if tr > 0 {
            p.addLine(to: CGPoint(x: x0, y: t + tr))
            p.addCurve(to: CGPoint(x: x0 + tr, y: t),
                       control1: CGPoint(x: x0, y: t + tr - k * tr), control2: CGPoint(x: x0 + tr - k * tr, y: t))
        } else {
            p.addLine(to: CGPoint(x: x0, y: t + e))
            if e > 0 {
                p.addCurve(to: CGPoint(x: x0 - e, y: t),
                           control1: CGPoint(x: x0, y: t + e - k * e), control2: CGPoint(x: x0 - e + k * e, y: t))
            }
        }
        if !openTop { p.closeSubpath() }
        return p
    }
}
