import AppKit
import SwiftUI

/// Материал острова по теме: заливка (solid/gradient/glass), чёрное ядро у выреза, эффекты и кромка (rim).
/// Рисуется в рамке `metrics.outerWidth × metrics.height` и обрезается `IslandShape`.
public struct IslandBackground: View {
    public var metrics: IslandMetrics
    /// Высота чёрного ядра (обычно высота выреза). 0 — без ядра.
    public var coreHeight: CGFloat
    /// Подсветка кромки при наведении (макет 02, состояние 06).
    public var highlighted: Bool
    /// Тонкая светлая нижняя кромка (`.edge` в макетах). В покое выключена, чтобы остров не выдавал себя.
    public var showEdge: Bool
    /// Рамка темы (`rim`). В покое выключена: остров сливается с вырезом (макет 02, состояние 01).
    public var showRim: Bool
    /// Бегущая рамка (`rim.animated`) крутится, только когда true (раскрытый остров). Иначе — статичный градиент:
    /// `TimelineView` 30 к/с в покое и компакте — постоянная трата энергии.
    public var animateRim: Bool

    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion
    @Environment(\.islandArtworkColors) private var artworkColors   // --- media2 ---

    public init(metrics: IslandMetrics, coreHeight: CGFloat, highlighted: Bool = false, showEdge: Bool = true,
                showRim: Bool = true, animateRim: Bool = false) {
        self.metrics = metrics; self.coreHeight = coreHeight; self.highlighted = highlighted; self.showEdge = showEdge
        self.showRim = showRim; self.animateRim = animateRim
    }

    // --- media2 ---
    private var activeArtwork: [Color]? {
        guard theme.background.source == .artwork, let a = artworkColors, !a.isEmpty else { return nil }
        return a
    }
    // --- /media2 ---

    public var body: some View {
        let shape = IslandShape(metrics, theme: theme)
        ZStack(alignment: .top) {
            // --- media2 --- «Хамелеон»: фон из цветов обложки поверх фона темы. Смена трека и появление/уход
            // обложки — перелив 0,6 с (макет 09; `.reduced` — короткое затухание, `.off` — сразу).
            ZStack {
                fill
                if let a = activeArtwork {
                    ArtworkFill(colors: a, light: theme.isLight,
                                coreHeight: theme.background.coreBlack ? coreHeight : 0, height: metrics.height)
                        .id(a)
                        .transition(.opacity)
                }
            }
            .animation(motion.animation(.easeInOut(duration: 0.6)), value: activeArtwork)
            // --- /media2 ---
            // Эффекты — под чёрным ядром: в компакте остров остаётся неотличим от выреза.
            effects
            if theme.background.coreBlack && coreHeight > 0 {
                let h = max(metrics.height, 1)
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: min(1, coreHeight / h)),
                    .init(color: .black.opacity(0), location: min(1, (coreHeight + 28) / h)),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(shape)
        .overlay { if showRim { rim.transition(.opacity) } }
        .overlay {
            IslandShape(metrics, theme: theme, openTop: true)
                .stroke(theme.primary.opacity(theme.isPureBlack ? 0 : (highlighted ? 0.22 : (showEdge ? 0.07 : 0))), lineWidth: 1)
        }
        // Наведение: мягкая тень цвета акцента под островом (макет 02, состояние 06).
        .shadow(color: theme.accentColor.opacity(highlighted ? (theme.isPureBlack ? 0.14 : 0.22) : 0), radius: 17, y: 12)
        .accessibilityHidden(true)
    }

    // MARK: Заливка

    @ViewBuilder private var fill: some View {
        let colors = theme.backgroundColors.isEmpty ? [Color.black] : theme.backgroundColors
        switch theme.background.type {
        case .solid:
            colors[0]
        case .gradient:
            LinearGradient(colors: colors.count == 1 ? colors + colors : colors,
                           startPoint: UnitPoint.cssAngle(theme.background.angle).start,
                           endPoint: UnitPoint.cssAngle(theme.background.angle).end)
        case .glass:
            ZStack {
                if isSnapshot {
                    // ImageRenderer не рисует NSVisualEffectView — имитируем матовое стекло.
                    Color(white: 0.12).opacity(0.55)
                } else {
                    VisualEffectBlur(material: .hudWindow)
                }
                LinearGradient(colors: colors.count == 1 ? colors + colors : colors,
                               startPoint: UnitPoint.cssAngle(theme.background.angle).start,
                               endPoint: UnitPoint.cssAngle(theme.background.angle).end)
            }
        }
    }

    // MARK: Эффекты

    @ViewBuilder private var effects: some View {
        if theme.effects.highlight {
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .bottom,
                           startRadius: 0, endRadius: max(40, metrics.width * 0.45))
                .scaleEffect(x: 1.6, y: 0.5, anchor: .bottom)
                .allowsHitTesting(false)
        }
        if theme.effects.scanlines {
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
        if theme.effects.noise > 0 {
            NoiseOverlay(amount: theme.effects.noise).allowsHitTesting(false)
        }
    }

    // MARK: Кромка

    @ViewBuilder private var rim: some View {
        let open = IslandShape(metrics, theme: theme, openTop: true)
        let w = CGFloat(theme.rim.width)
        switch theme.rim.type {
        case .none:
            EmptyView()
        case .solid:
            open.stroke(theme.rimColors.first ?? .white.opacity(0.2), lineWidth: w)
        case .conic:
            let colors = theme.rimColors.isEmpty ? [theme.accentColor, theme.accent2Color] : theme.rimColors
            if theme.rim.animated && animateRim && !isSnapshot && motion.allowsContinuousAnimation {
                // Вращение — Core Animation (`RotatingConicStroke`): в процессе ни кадра (было TimelineView 30 к/с —
                // перерисовка фона всего острова на каждом кадре).
                RotatingConicStroke(shape: open, colors: colors + [colors[0]], lineWidth: w, period: 6)
            } else {
                open.stroke(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(120)),
                            lineWidth: w)
            }
        }
    }
}

// --- media2 ---
/// Цвета обложки играющего для темы с `background.source = artwork` («Хамелеон»). Кладёт ядро (IslandRootView) из
/// канала обложки (`ModuleContext.setArtworkColors`, не свечение); nil — обложки нет, фон темы обычный.
private struct IslandArtworkColorsKey: EnvironmentKey {
    static let defaultValue: [Color]? = nil
}

public extension EnvironmentValues {
    var islandArtworkColors: [Color]? {
        get { self[IslandArtworkColorsKey.self] }
        set { self[IslandArtworkColorsKey.self] = newValue }
    }
}

/// Фон «Хамелеона» (макет 09, `.cham`): сверху чёрное ядро выреза (`coreHeight`; 0 — тема без `coreBlack`), ниже — оттенки главного цвета обложки, снизу —
/// мягкая подсветка вторым и третьим цветом. Тёмная тема — тёмные оттенки (яркость ≤ 0,35: белый текст читается на
/// любой обложке); светлая (`theme.isLight`) — светлые пастельные (яркость ≥ 0,88, насыщенность ≤ 0,22: тёмный текст
/// темы читается).
struct ArtworkFill: View {
    var colors: [Color]
    var light = false
    var coreHeight: CGFloat
    var height: CGFloat

    var body: some View {
        let main = colors[0]
        let second = colors.count > 1 ? colors[1] : main
        let third = colors.count > 2 ? colors[2] : second
        let h = max(height, 1)
        let start = coreHeight > 0 ? min(0.9, (coreHeight + 38) / h) : 0
        // Яркость полосы градиента сверху вниз и подсветки снизу: тёмная тема / светлая.
        let band: [CGFloat] = light ? [0.97, 0.94, 0.9] : [0.16, 0.27, 0.35]
        let maxSat: CGFloat = light ? 0.22 : 1
        ZStack {
            LinearGradient(stops: (coreHeight > 0 ? [
                .init(color: .black, location: 0),
                .init(color: .black, location: min(1, coreHeight / h)),
            ] : []) + [
                .init(color: Self.shade(main, band[0], maxSat: maxSat), location: start),
                .init(color: Self.shade(main, band[1], maxSat: maxSat), location: max(start, 0.72)),
                .init(color: Self.shade(main, band[2], maxSat: maxSat), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Self.shade(second, light ? 0.95 : 0.9, sat: light ? 0.3 : 0.9,
                                               maxSat: light ? 0.45 : 1).opacity(light ? 0.35 : 0.22), .clear],
                           center: UnitPoint(x: 0.15, y: 1.1), startRadius: 0, endRadius: h * 0.9)
            RadialGradient(colors: [Self.shade(third, light ? 0.95 : 0.75, sat: light ? 0.3 : 0.9,
                                               maxSat: light ? 0.45 : 1).opacity(light ? 0.35 : 0.3), .clear],
                           center: UnitPoint(x: 0.9, y: 1.1), startRadius: 0, endRadius: h * 0.8)
        }
    }

    /// Тот же оттенок с заданной яркостью (HSB) и насыщенностью в пределах `sat…maxSat`.
    static func shade(_ c: Color, _ brightness: CGFloat, sat: CGFloat = 0.55, maxSat: CGFloat = 1) -> Color {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return c }
        var hue: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&hue, saturation: &s, brightness: &b, alpha: &a)
        // Серую обложку не раскрашиваем: низкая насыщенность остаётся низкой.
        let sat2 = s < 0.12 ? s : max(s, min(sat, maxSat))
        return Color(nsColor: NSColor(hue: hue, saturation: min(maxSat, sat2), brightness: brightness, alpha: 1))
    }
}
// --- /media2 ---

/// Свечение под островом (размытый эллипс).
public struct IslandGlow: View {
    public var colors: [Color]
    public var metrics: IslandMetrics
    public var opacity: Double
    public var radius: Double

    public init(colors: [Color], metrics: IslandMetrics, opacity: Double, radius: Double) {
        self.colors = colors; self.metrics = metrics; self.opacity = opacity; self.radius = radius
    }

    public var body: some View {
        let cs = colors.isEmpty ? [Color.clear] : (colors.count == 1 ? colors + colors : colors)
        Ellipse()
            .fill(LinearGradient(colors: cs, startPoint: .leading, endPoint: .trailing))
            .frame(width: metrics.width * 0.92, height: max(30, metrics.height * 0.62))
            .blur(radius: radius * 0.55)
            .opacity(opacity)
            .offset(y: metrics.height * 0.42)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Зерно: детерминированная текстура 128×128, нарисованная один раз на значение `amount` и замощённая.
/// (Раньше Canvas рисовал w·h/18 точек — ~12 тыс. прямоугольников на каждом кадре пружины.)
struct NoiseOverlay: View {
    var amount: Double
    var body: some View {
        Image(nsImage: Self.tile(amount))
            .resizable(resizingMode: .tile)
    }

    @MainActor private static var cache: [Int: NSImage] = [:]

    @MainActor static func tile(_ amount: Double) -> NSImage {
        let key = Int((amount * 1000).rounded())
        if let img = cache[key] { return img }
        let side = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        let data = rep.bitmapData!
        memset(data, 0, side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        // Та же плотность, что раньше: одна точка на 18 pt².
        for _ in 0..<(side * side / 18) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Int(seed >> 40 & 0xFFFF) * side / 65536
            let y = Int(seed >> 20 & 0xFFFF) * side / 65536
            let a = UInt8(min(255, Double(seed & 0xFF) * amount))
            let i = (y * side + x) * 4
            // Предумноженный белый с прозрачностью a.
            data[i] = a; data[i + 1] = a; data[i + 2] = a; data[i + 3] = a
        }
        let img = NSImage(size: NSSize(width: side, height: side))
        img.addRepresentation(rep)
        cache[key] = img
        return img
    }
}

/// NSVisualEffectView для стеклянных тем (только живое окно).
public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public init(material: NSVisualEffectView.Material = .hudWindow) { self.material = material }
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    public func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

public extension UnitPoint {
    /// CSS-угол градиента → точки начала/конца (180° — сверху вниз, 90° — слева направо).
    static func cssAngle(_ degrees: Double) -> (start: UnitPoint, end: UnitPoint) {
        let rad = degrees * .pi / 180
        let dx = sin(rad) / 2, dy = -cos(rad) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}
