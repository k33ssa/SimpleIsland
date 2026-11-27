import AppKit
import QuartzCore
import SwiftUI
import IslandCore

/// Точка у выреза в полноэкранном (15.11: «но будет кружочек, если агент написал?»). Остров спрятан правилом
/// «прятать в полноэкранном», а событие, о котором стоит знать, есть — под вырезом висит минимальное чёрное «ухо»
/// (та же форма острова: вогнутые сопряжения сверху, скруглённый низ) с цветной точкой:
/// оранжевая — агент спрашивает / ждёт разрешения, красная — ошибка / Vafa сработала, синяя — важное уведомление,
/// зелёная — агент закончил. Цвета — `AttentionKind.color` = `IslandPalette`, как у живой точки покоя.
/// Появилась — 3 мягких пульса (Core Animation, в сервере отрисовки), потом статично. Клик — остров с этим
/// событием поверх полноэкранного; просмотрено — гаснет.
enum FullscreenBeacon {
    /// Ухо: ширина тела и высота под вырезом, радиус вогнутых сопряжений сверху.
    static let bodySize = CGSize(width: 26, height: 13)
    static let earRadius: CGFloat = 5
    static let dotSize: CGFloat = 7
    /// Пульс: столько раз, каждый — `pulseDuration` с.
    static let pulseCount: Float = 3
    static let pulseDuration: CFTimeInterval = 0.9

    /// Рамка панели (глобальные координаты AppKit): по центру выреза, верх — нижний край выреза (без выреза — верх
    /// экрана), с ушами по бокам.
    static func frame(centerX: CGFloat, screenTop: CGFloat, notchHeight: CGFloat, hasNotch: Bool) -> NSRect {
        let w = bodySize.width + earRadius * 2
        let top = hasNotch ? screenTop - notchHeight : screenTop
        return NSRect(x: (centerX - w / 2).rounded(), y: top - bodySize.height, width: w, height: bodySize.height)
    }

    /// Что показать на экране: остров спрятан правилом, точка включена в настройках, есть событие.
    static func kind(islandHidden: Bool, enabled: Bool, top: AttentionState?) -> AttentionKind? {
        guard islandHidden, enabled, let top else { return nil }
        return top.kind
    }

    /// Важное ли уведомление для синей точки (политика уведомлений): с кнопкой — ждёт реакции. Агенты зовут свою
    /// точку сами (ask/error/done), поэтому их карточки сюда не идут; вспышки HUD — не уведомления.
    static func isImportant(_ n: IslandNotification) -> Bool {
        n.isInformative && !n.actions.isEmpty && n.moduleId != "agents"
    }

    /// Ключ модуля «пропущенная карточка» в `ActivityCenter.attention`.
    static let notificationsKey = "core.notifications"

    /// Путь уха в координатах вида `size` (y вверх): верх по всей ширине, вогнутые сопряжения радиуса `e` у краёв,
    /// тело `size.width - 2e`, низ скруглён.
    static func earPath(size: CGSize, e: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let h = size.height, w = size.width
        let bodyR = min(h - e, (w - 2 * e) / 2, 6)
        p.move(to: CGPoint(x: 0, y: h))
        p.addQuadCurve(to: CGPoint(x: e, y: h - e), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: e, y: bodyR))
        p.addQuadCurve(to: CGPoint(x: e + bodyR, y: 0), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: w - e - bodyR, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - e, y: bodyR), control: CGPoint(x: w - e, y: 0))
        p.addLine(to: CGPoint(x: w - e, y: h - e))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - e, y: h))
        p.closeSubpath()
        return p
    }

    /// Анимация пульса точки (самотест проверяет: конечная, 2–3 раза, потом статично).
    static func pulseAnimation() -> CAAnimationGroup {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.55, 1]
        scale.keyTimes = [0, 0.4, 1]
        let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
        glow.values = [3, 7, 3]
        glow.keyTimes = [0, 0.4, 1]
        let g = CAAnimationGroup()
        g.animations = [scale, glow]
        g.duration = pulseDuration
        g.repeatCount = pulseCount
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.isRemovedOnCompletion = true
        return g
    }
}

/// Окно точки: неактивирующее, над полноэкранным столом (`.fullScreenAuxiliary`), принимает только клик.
@MainActor
final class FullscreenBeaconPanel: NSPanel {
    private let beacon = BeaconView()
    var onClick: () -> Void {
        get { beacon.onClick }
        set { beacon.onClick = newValue }
    }
    private(set) var kind: AttentionKind?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 36, height: 13), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = NotchPanel.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        contentView = beacon
        setAccessibilityLabel("SimpleIsland: событие")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Показать/обновить/спрятать. Новый вид события — пульс заново; тот же — ничего.
    func show(_ kind: AttentionKind?, text: String, frame: NSRect, reduceMotion: Bool) {
        guard let kind else {
            if self.kind != nil { self.kind = nil; orderOut(nil) }
            return
        }
        if self.frame != frame { setFrame(frame, display: false) }
        beacon.toolTip = text.isEmpty ? kind.spokenName.capitalized : text + " — нажми, чтобы открыть"
        beacon.setAccessibilityLabel("SimpleIsland: \(text.isEmpty ? kind.spokenName : text)")
        let changed = self.kind != kind
        self.kind = kind
        beacon.apply(color: NSColor(kind.color), pulse: changed && !reduceMotion)
        if !isVisible { orderFrontRegardless() }
    }
}

/// Слои: чёрное ухо + точка со свечением. Никакого SwiftUI и таймеров: пульс крутит Core Animation.
private final class BeaconView: NSView {
    var onClick: () -> Void = {}
    private let ear = CAShapeLayer()
    private let dot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ear)
        layer?.addSublayer(dot)
        ear.fillColor = NSColor.black.cgColor
        dot.cornerRadius = FullscreenBeacon.dotSize / 2
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("не используется") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ear.frame = bounds
        ear.path = FullscreenBeacon.earPath(size: bounds.size, e: FullscreenBeacon.earRadius)
        let d = FullscreenBeacon.dotSize
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.position = CGPoint(x: bounds.midX, y: (bounds.height - FullscreenBeacon.earRadius) / 2 + 0.5)
        CATransaction.commit()
    }

    func apply(color: NSColor, pulse: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        CATransaction.commit()
        needsLayout = true
        dot.removeAnimation(forKey: "pulse")
        if pulse { dot.add(FullscreenBeacon.pulseAnimation(), forKey: "pulse") }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

// MARK: - Снимок (`--snapshot`, ядро): полоса «полноэкранного видео» с вырезом и ухом под ним

extension FullscreenBeacon {
    /// PNG ×2: вырез 186×32 и ухо с точкой вида `kind` на сером «кадре видео».
    @MainActor static func snapshotPNG(kind: AttentionKind) -> Data? {
        let w: CGFloat = 320, h: CGFloat = 70, scale: CGFloat = 2, notch = CGSize(width: 186, height: 32)
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: w, height: h)
        root.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.42, alpha: 1).cgColor
        let band = CALayer()   // чёрная полоса строки меню полноэкранного стола
        band.frame = CGRect(x: 0, y: h - notch.height, width: w, height: notch.height)
        band.backgroundColor = NSColor.black.cgColor
        root.addSublayer(band)
        let f = frame(centerX: w / 2, screenTop: h, notchHeight: notch.height, hasNotch: true)
        let ear = CAShapeLayer()
        ear.frame = f
        ear.path = earPath(size: f.size, e: earRadius)
        ear.fillColor = NSColor.black.cgColor
        root.addSublayer(ear)
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dot.position = CGPoint(x: f.midX, y: f.minY + (f.height - earRadius) / 2 + 0.5)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = NSColor(kind.color).cgColor
        dot.shadowColor = NSColor(kind.color).cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        root.addSublayer(dot)
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
