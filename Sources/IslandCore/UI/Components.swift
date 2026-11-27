import AppKit
import SwiftUI

// Общие UI-компоненты острова. Цвета и шрифт — из темы (`@Environment(\.islandTheme)`).
// Размеры — по design/mockups/base.css.

/// Круглая/капсульная кнопка (`.btn`): иконка и/или текст. `solid` — белая (контраст), `accent` — цвет темы.
public struct IslandButton: View {
    public enum Style: Sendable { case plain, solid, accent, ok, destructive }
    var title: String?
    var systemImage: String?
    var style: Style
    var height: CGFloat
    var accessibilityText: String?
    var accessibilityHintText: String?
    var action: () -> Void
    @Environment(\.islandTheme) private var theme

    /// `accessibilityLabel` — что скажет VoiceOver. Для кнопки-иконки без `title` задавайте всегда; по умолчанию —
    /// `title`, иначе название по значку (`IslandButton.spokenName`: «slider.horizontal.3» → «Настройки»).
    public init(_ title: String? = nil, systemImage: String? = nil, style: Style = .plain, height: CGFloat = 30,
                accessibilityLabel: String? = nil, accessibilityHint: String? = nil,
                action: @escaping () -> Void = {}) {
        self.title = title; self.systemImage = systemImage; self.style = style; self.height = height; self.action = action
        self.accessibilityText = accessibilityLabel; self.accessibilityHintText = accessibilityHint
    }

    /// Подпись для VoiceOver: явная → текст кнопки → название значка.
    public var resolvedAccessibilityLabel: String {
        accessibilityText ?? title ?? Self.spokenName(for: systemImage ?? "")
    }

    /// Русское название для частых SF Symbols кнопок; неизвестный значок — его имя словами.
    public static func spokenName(for symbol: String) -> String {
        let base = symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".circle", with: "")
        let names: [String: String] = [
            "slider.horizontal.3": "Настройки", "gearshape": "Настройки", "gear": "Настройки",
            "play": "Играть", "pause": "Пауза", "playpause": "Играть или пауза", "stop": "Стоп",
            "forward": "Следующий трек", "backward": "Предыдущий трек", "forward.end": "Следующий трек",
            "backward.end": "Предыдущий трек", "goforward.15": "Вперёд на 15 секунд", "gobackward.15": "Назад на 15 секунд",
            "shuffle": "Перемешать", "repeat": "Повтор", "repeat.1": "Повтор трека", "heart": "Нравится",
            "airplayaudio": "AirPlay", "speaker.wave.2": "Звук", "speaker.slash": "Без звука",
            "xmark": "Закрыть", "plus": "Добавить", "minus": "Убрать", "trash": "Удалить", "checkmark": "Готово",
            "doc.on.doc": "Копировать", "square.and.arrow.up": "Поделиться", "arrow.up.right.square": "Открыть",
            "magnifyingglass": "Поиск", "ellipsis": "Ещё", "chevron.left": "Назад", "chevron.right": "Вперёд",
            "chevron.down": "Развернуть", "chevron.up": "Свернуть", "pin": "Закрепить", "pin.slash": "Открепить",
            "mic": "Микрофон", "mic.slash": "Микрофон выключен", "video": "Камера", "phone": "Ответить",
            "phone.down": "Завершить звонок", "arrow.clockwise": "Обновить", "folder": "Показать в Finder",
            "eye": "Просмотр", "lock": "Заблокировать", "bell": "Уведомления", "bell.slash": "Без уведомлений",
            "timer": "Таймер", "calendar": "Календарь", "terminal": "Терминал", "apple.terminal": "Терминал",
            "arrow.down.to.line": "Раскрыть", "arrow.up.to.line": "Свернуть",
        ]
        if let n = names[symbol] ?? names[base] { return n }
        return base.replacingOccurrences(of: ".", with: " ")
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s).font(.system(size: height * 0.42, weight: .semibold)) }
                if let t = title { Text(t).font(theme.font(height * 0.42, .semibold)).lineLimit(1) }
            }
            .padding(.horizontal, title == nil ? 0 : 12)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(resolvedAccessibilityLabel)
        .accessibilityHint(accessibilityHintText ?? "")
    }

    private var fg: Color {
        switch style {
        case .plain: return theme.primary
        case .solid: return theme.isLight ? .white : .black
        case .accent: return .white
        case .ok: return Color(hex: "#03140B")
        case .destructive: return Color(hex: "#FF8AA0")
        }
    }
    private var bg: Color {
        switch style {
        case .plain: return theme.controlFillColor
        case .solid: return theme.isLight ? .black : .white
        case .accent: return theme.accentColor
        case .ok: return Color(hex: "#39D98A")
        case .destructive: return Color(hex: "#FF5470").opacity(0.16)
        }
    }
}

/// Лёгкое «вдавливание» по нажатию.
public struct PressScaleStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Пилюля-вкладка верхней строки (`.tabs span`): выбранная — с подписью и подложкой.
public struct Pill: View {
    var title: String
    var shortTitle: String
    var systemImage: String?
    var selected: Bool
    var showsTitle: Bool
    @Environment(\.islandTheme) private var theme

    /// Отступ слева от значка = отступ справа после текста (или после значка, если текста нет).
    public static let inset: CGFloat = 9
    public static let height: CGFloat = 24

    public init(_ title: String, systemImage: String? = nil, selected: Bool = false, showsTitle: Bool? = nil,
                shortTitle: String? = nil) {
        self.title = title; self.systemImage = systemImage; self.selected = selected
        self.showsTitle = showsTitle ?? selected
        self.shortTitle = shortTitle ?? Self.abbreviation(title)
    }

    /// Сокращение для тесной строки вкладок: до 7 букв — как есть, длиннее — первые 3 буквы и точка
    /// («Эквалайзер» → «Экв.»). Самотест — `--selftest-core utils`.
    public static func abbreviation(_ title: String) -> String {
        title.count <= 7 ? title : String(title.prefix(3)) + "."
    }

    /// Варианты подписи по убыванию: полное имя → сокращение → только значок. Пусто — только значок.
    public static func titleVariants(_ title: String, short: String) -> [String] {
        short == title ? [title] : [title, short]
    }

    public var body: some View {
        Group {
            if (showsTitle || systemImage == nil), let s = systemImage {
                // 15.11: выбранной вкладке не хватало места — текст сжимался до «…» или до нуля, а ширина под него
                // оставалась («справа пусто шире, чем слева»). Теперь вариант берётся целиком: полное имя,
                // сокращение или один значок в круге, и отступы всегда симметричны.
                ViewThatFits(in: .horizontal) {
                    ForEach(Self.titleVariants(title, short: shortTitle), id: \.self) { t in
                        labeled(s, t).fixedSize()
                    }
                    iconOnly(s)
                }
            } else if let s = systemImage {
                iconOnly(s)
            } else {
                Text(title).font(theme.font(11.5, .semibold)).lineLimit(1)
                    .padding(.horizontal, Self.inset).frame(height: Self.height)
            }
        }
        .foregroundStyle(selected ? theme.primary : theme.tertiary)
        .background(Capsule().fill(selected ? theme.primary.opacity(0.12) : .clear))
        .contentShape(Capsule())
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Вкладка \(title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    private func labeled(_ s: String, _ t: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: s).font(.system(size: 12, weight: .semibold))
            Text(t).font(theme.font(11.5, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
    }

    /// Только значок — круг 24×24, значок по центру (одинаково слева и справа).
    private func iconOnly(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 12, weight: .semibold))
            .frame(width: Self.height, height: Self.height)
    }
}

/// Маленький чип (`.chip`): «Lossless», «AirPods Pro · 82%».
public struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color?
    @Environment(\.islandTheme) private var theme

    public init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text; self.systemImage = systemImage; self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let s = systemImage { Image(systemName: s).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(theme.font(11, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .foregroundStyle(tint ?? theme.secondary)
        .background(Capsule().fill(tint.map { $0.opacity(0.14) } ?? theme.controlFillColor))
        .accessibilityElement(children: .combine)
    }
}

/// Плитка (`.tile`) для вкладок «Сегодня», «Полка» и т. п.
public struct Tile<Content: View>: View {
    var padding: CGFloat
    var content: Content
    @Environment(\.islandTheme) private var theme

    public init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.controlFillColor))
    }
}

/// Тонкая полоса прогресса (`.bar-track`).
public struct ProgressTrack: View {
    var value: Double
    var height: CGFloat
    var tint: AnyShapeStyle?
    @Environment(\.islandTheme) private var theme

    public init(value: Double, height: CGFloat = 5, tint: AnyShapeStyle? = nil) {
        self.value = value; self.height = height; self.tint = tint
    }

    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primary.opacity(0.14))
                Capsule().fill(tint ?? AnyShapeStyle(theme.primary))
                    .frame(width: max(height, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) %")
    }
}

/// Сегментная полоса (подсветка клавиатуры, стиль HUD «Сегменты»).
public struct SegmentTrack: View {
    var value: Double
    var segments: Int
    var tint: Color?
    @Environment(\.islandTheme) private var theme

    public init(value: Double, segments: Int = 16, tint: Color? = nil) {
        self.value = value; self.segments = segments; self.tint = tint
    }

    public var body: some View {
        let on = Int((value * Double(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < on ? (tint ?? theme.primary) : theme.primary.opacity(0.18))
                    .frame(width: 5, height: 12)
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) %")
    }
}

/// Стиль эквалайзера в компакте (лист design/figcraft/eq-v2: №1 капсулы с инерцией, №3 ореол по громкости,
/// №8 отражение в ухе). `classic` — прежние градиентные полоски.
public enum VisualizerStyle: String, CaseIterable, Codable, Sendable {
    case classic, capsules, halo, reflection
    public var title: String {
        switch self {
        case .classic: return "Классика"
        case .capsules: return "Вариант 1 · Капсулы с инерцией"
        case .halo: return "Вариант 3 · Ореол по громкости"
        case .reflection: return "Вариант 8 · Отражение в ухе"
        }
    }
}

/// Эквалайзер-полоски (`.viz`). `animated` — двигаются (только пока играет музыка).
public struct Visualizer: View {
    var bars: Int
    var levels: [Double]?
    var animated: Bool
    var height: CGFloat
    var colors: [Color]?
    /// Уровни настоящего звука (Медиа, захват системного звука). Пока они идут (`feed.isLive`), полоски показывают
    /// их; нет — прежняя псевдоанимация. Подписка — только пока полоски анимированы (`animated`, `.full`, не снимок).
    var feed: AudioLevelsFeed?
    /// Ширина полоски и зазор, pt (компакт — 3 и 2; большой эквалайзер-виджет — шире).
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2
    var style: VisualizerStyle = .classic
    /// Без музыки (пауза/нет трека) — все полоски на минимуме, ровно (18.11: «без музыки — просто на минимум»).
    var flat = false
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    public init(bars: Int = 5, levels: [Double]? = nil, animated: Bool = false, height: CGFloat = 16, colors: [Color]? = nil,
                feed: AudioLevelsFeed? = nil, barWidth: CGFloat = 3, gap: CGFloat = 2, style: VisualizerStyle = .classic,
                flat: Bool = false) {
        self.bars = bars; self.levels = levels; self.animated = animated; self.height = height; self.colors = colors
        self.feed = feed; self.barWidth = barWidth; self.gap = gap; self.style = style; self.flat = flat
    }

    public var body: some View {
        // Окно не видно, сон, «Уменьшить движение», энергосбережение → статичные полоски (`islandMotion`).
        Group {
            // Полоски по настоящему звуку (feed) — и при `.reduced` (энергосбережение/батарея): обновления по звуку
            // дешёвые (≤20 Гц, кадры считает сервер отрисовки), а без них захват звука даже не стартует (нет спроса).
            if animated && !isSnapshot && (motion.allowsContinuousAnimation || (feed != nil && motion != .off)) {
                // Полоски крутит Core Animation в сервере отрисовки: приложение не просыпается на кадры и SwiftUI не
                // пересчитывает остров (было TimelineView 12 к/с: дисплейная ссылка на 120 Гц будила процесс ~127 раз
                // в секунду, каждый кадр — проход раскладки всего острова, 15–17 % CPU в компакте с музыкой; замер 14.11).
                AnimatedBars(bars: bars, levels: (0..<bars).map { baseLevel($0) }, height: height,
                             colors: (colors ?? [Color(hex: "#FFD36E"), theme.accent2Color]).map { NSColor($0).cgColor },
                             feed: feed, barWidth: barWidth, gap: gap, style: style)
                    .frame(width: CGFloat(bars) * (barWidth + gap) - gap, height: height)
            } else {
                barsView(phase: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private static let defaultLevels: [Double] = [0.45, 0.8, 1.0, 0.6, 0.85, 0.5, 0.7]

    private func baseLevel(_ i: Int) -> Double {
        if let l = levels, !l.isEmpty { return l[i % l.count] }
        return Self.defaultLevels[i % 7]
    }

    private func level(_ i: Int, phase: Double) -> CGFloat {
        height * CGFloat(Self.level(base: baseLevel(i), bar: i, phase: phase))
    }

    /// Высота полоски (доля от 0,2 до 1) в момент `phase` (секунды): база + колебание своей частоты.
    static func level(base: Double, bar i: Int, phase: Double) -> Double {
        var wobble: Double = 0
        if phase != 0 { wobble = 0.35 * sin(phase * speed(bar: i) + Double(i)) }
        return min(1, max(0.2, base + wobble))
    }

    static func speed(bar i: Int) -> Double { 5 + Double(i) * 1.7 }

    private func barsView(phase: Double) -> some View {
        let gradientColors: [Color] = colors ?? [Color(hex: "#FFD36E"), theme.accent2Color]
        let accent = gradientColors.first ?? .white
        let fill: LinearGradient = {
            switch style {
            case .classic: return LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
            case .capsules, .reflection: return LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
            case .halo: return LinearGradient(colors: [.white, .white.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            }
        }()
        let mid = Double(bars - 1) / 2
        func h(_ i: Int) -> CGFloat {
            if flat { return max(barWidth, height * 0.2) }
            guard style != .classic, bars > 1 else { return level(i, phase: phase) }
            let d = abs(Double(i) - mid) / max(1, mid)
            return height * CGFloat(0.95 - 0.4 * d) * (style == .reflection ? 0.6 : 1)
        }
        return ZStack {
            if style == .halo {
                Capsule().fill(accent.opacity(0.22)).shadow(color: accent, radius: 7)
                    .frame(width: CGFloat(bars) * (barWidth + gap), height: height)
            }
            HStack(alignment: style == .reflection ? .bottom : .center, spacing: gap) {
                ForEach(0..<bars, id: \.self) { i in
                    VStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: barWidth / 2).fill(fill).frame(width: barWidth, height: h(i))
                        if style == .reflection {
                            RoundedRectangle(cornerRadius: barWidth / 2)
                                .fill(LinearGradient(colors: [accent.opacity(0.38), accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .frame(width: barWidth, height: h(i) * 0.45)
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Полоски эквалайзера на слоях Core Animation: та же форма движения, что у `Visualizer` (база + синус своей
/// частоты), но кадры считает сервер отрисовки — в процессе ни таймера, ни дисплейной ссылки, ни пересчёта SwiftUI.
/// Анимация живёт, пока вью на экране (Visualizer убирает её при `islandMotion` ниже `.full` и в снимках).
private struct AnimatedBars: NSViewRepresentable {
    var bars: Int
    var levels: [Double]
    var height: CGFloat
    var colors: [CGColor]
    var feed: AudioLevelsFeed?
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2
    var style: VisualizerStyle = .classic

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ v: BarsView, context: Context) {
        v.configure(.init(bars: bars, levels: levels, height: height, colors: colors, barWidth: barWidth, gap: gap,
                          style: style), feed: feed)
    }
    static func dismantleNSView(_ v: BarsView, coordinator: ()) { v.detachFeed() }

    final class BarsView: NSView {
        struct Config: Equatable {
            var bars: Int; var levels: [Double]; var height: CGFloat; var colors: [CGColor]
            var barWidth: CGFloat = 3; var gap: CGFloat = 2
            var style: VisualizerStyle = .classic
        }
        private var config: Config?
        private var barLayers: [CAGradientLayer] = []
        private var mirrorLayers: [CAGradientLayer] = []
        private var haloLayer: CALayer?
        private weak var feed: AudioLevelsFeed?
        /// Сейчас показываем настоящие уровни (иначе — ключевые кадры псевдоанимации).
        private(set) var showsLive = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }
        // Вью НЕ перевёрнута: слой с осью y вверх, у градиента y = 1 — верх (первый цвет сверху, как у статичных
        // полосок SwiftUI). С `isFlipped = true` AppKit переворачивал геометрию слоя и цвета вставали вверх ногами
        // (ревью 14.11). Полоски симметричны по высоте — переворот на них больше нигде не влияет.
        // Клик по эквалайзеру — острову (раскрыть), а не этой вью.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // Спрос на настоящий звук — только пока полоски в окне: свернули/убрали из иерархии — подписка снята.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { updateSubscription() }
        }

        func configure(_ c: Config, feed newFeed: AudioLevelsFeed?) {
            if newFeed !== feed {
                feed?.removeSink(self)
                feed = newFeed
                updateSubscription()
            }
            guard c != config, let root = layer else { return }
            config = c
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            barLayers = []; mirrorLayers = []; haloLayer = nil
            let accent = c.colors.first ?? NSColor.white.cgColor
            if c.style == .halo {
                // №3: мягкий ореол цвета обложки за белыми капсулами; яркость следует за общей громкостью.
                let h = CALayer()
                h.backgroundColor = accent
                h.cornerRadius = c.height / 2
                h.bounds = CGRect(x: 0, y: 0, width: CGFloat(c.bars) * (c.barWidth + c.gap), height: c.height)
                h.position = CGPoint(x: (CGFloat(c.bars) * (c.barWidth + c.gap) - c.gap) / 2, y: c.height / 2)
                h.opacity = 0.0
                h.shadowColor = accent; h.shadowOpacity = 1; h.shadowRadius = 7; h.shadowOffset = .zero
                h.masksToBounds = false
                h.backgroundColor = accent.copy(alpha: 0.22)
                root.addSublayer(h); haloLayer = h
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.25, 0.45, 0.3, 0.42, 0.25]; pulse.duration = 2.4; pulse.repeatCount = .infinity
                pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
                h.add(pulse, forKey: "halo")
            }
            for i in 0..<c.bars {
                let bar = CAGradientLayer()
                switch c.style {
                case .classic: bar.colors = c.colors
                case .capsules, .reflection: bar.colors = [accent, accent]
                case .halo: bar.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.92).cgColor]
                }
                // Слой без переворота (вью не flipped): y = 1 — верх, первый цвет — сверху (как LinearGradient .top → .bottom).
                bar.startPoint = CGPoint(x: 0.5, y: 1)
                bar.endPoint = CGPoint(x: 0.5, y: 0)
                bar.cornerRadius = c.barWidth / 2
                let base = Visualizer.level(base: c.levels[i % max(1, c.levels.count)], bar: i, phase: 0)
                bar.bounds = CGRect(x: 0, y: 0, width: c.barWidth, height: c.height * base)
                bar.position = CGPoint(x: CGFloat(i) * (c.barWidth + c.gap) + c.barWidth / 2, y: c.height / 2)
                if c.style == .reflection {
                    // №8: капсула стоит на невидимой линии (60 % высоты), под ней — отражение 35 %.
                    bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                    bar.position.y = c.height * 0.38
                    let m = CAGradientLayer()
                    m.colors = [accent.copy(alpha: 0.38) ?? accent, accent.copy(alpha: 0.0) ?? accent]
                    m.startPoint = CGPoint(x: 0.5, y: 1); m.endPoint = CGPoint(x: 0.5, y: 0)
                    m.cornerRadius = c.barWidth / 2
                    m.anchorPoint = CGPoint(x: 0.5, y: 1)
                    m.bounds = CGRect(x: 0, y: 0, width: c.barWidth, height: c.height * base * 0.45)
                    m.position = CGPoint(x: bar.position.x, y: c.height * 0.38 - 1)
                    root.addSublayer(m); mirrorLayers.append(m)
                }
                root.addSublayer(bar)
                barLayers.append(bar)
            }
            showsLive = false
            if let f = feed, f.isLive, window != nil { apply(f) } else { installPseudo() }
        }

        func detachFeed() {
            feed?.removeSink(self)
            feed = nil
        }

        private func updateSubscription() {
            guard let f = feed else { return }
            if window != nil {
                f.addSink(self) { [weak self] f in self?.apply(f) }
                if f.isLive { apply(f) }
            } else {
                f.removeSink(self)
            }
        }

        /// Псевдоанимация: один период синуса каждой полоски — ключевые кадры, повтор бесконечно.
        private func installPseudo() {
            guard let c = config else { return }
            showsLive = false
            let hScale: CGFloat = c.style == .reflection ? 0.6 : 1
            for (i, bar) in barLayers.enumerated() {
                // №1: у каждой капсулы своя инерция ±15 % (разная частота).
                let inertia = c.style == .capsules ? (0.85 + 0.3 * Double((i * 37) % 10) / 10) : 1
                let speed = Visualizer.speed(bar: i) * (c.style == .classic ? 1 : 0.7) * inertia
                let period = 2 * Double.pi / speed
                let steps = 24
                let anim = CAKeyframeAnimation(keyPath: "bounds.size.height")
                anim.values = (0...steps).map { k -> CGFloat in
                    let t = period * Double(k) / Double(steps)
                    // фаза t > 0 — то же колебание, что Visualizer.level(… phase:) в момент t
                    return hScale * c.height * CGFloat(Visualizer.level(base: Self.styledBase(c, i), bar: i,
                                                               phase: t == 0 ? 1e-9 : t))
                }
                anim.duration = period
                anim.repeatCount = .infinity
                anim.calculationMode = .linear
                anim.isRemovedOnCompletion = false
                // Сервер отрисовки — не чаще 15 к/с для этих слоёв (полоски 3 pt: глазу хватает, экран не гонят на 120 Гц).
                anim.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
                bar.removeAnimation(forKey: "live")
                bar.add(anim, forKey: "level")
                if i < mirrorLayers.count {
                    let m = anim.copy() as! CAKeyframeAnimation
                    m.values = (anim.values as? [CGFloat])?.map { $0 * 0.45 }
                    mirrorLayers[i].add(m, forKey: "level")
                }
            }
        }

        /// Силуэт группы: у капсул (№1/№3/№8) центр выше краёв, как у Apple.
        static func styledBase(_ c: Config, _ i: Int) -> Double {
            guard c.style != .classic, c.bars > 1 else { return c.levels[i % max(1, c.levels.count)] }
            let mid = Double(c.bars - 1) / 2
            let d = abs(Double(i) - mid) / max(1, mid)
            return 0.95 - 0.4 * d
        }

        /// Настоящие уровни: высота каждой полоски плавно (Core Animation, за `feed.interval`) идёт к новому значению.
        /// Кадры между обновлениями считает сервер отрисовки; процесс просыпается только на само обновление.
        private func apply(_ f: AudioLevelsFeed) {
            guard let c = config, !barLayers.isEmpty else { return }
            guard f.isLive else {
                if showsLive { installPseudo() }
                return
            }
            let lv = f.levels(count: barLayers.count)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let hScale: CGFloat = c.style == .reflection ? 0.6 : 1
            if let h = haloLayer {
                let avg = lv.isEmpty ? 0 : Double(lv.reduce(Float(0), +)) / Double(lv.count)
                h.removeAnimation(forKey: "halo"); h.opacity = Float(min(0.45, 0.12 + avg * 0.5))
            }
            for (i, bar) in barLayers.enumerated() {
                let target = hScale * c.height * CGFloat(0.12 + 0.88 * Double(min(1, max(0, i < lv.count ? lv[i] : 0))))
                if i < mirrorLayers.count { mirrorLayers[i].removeAnimation(forKey: "level"); mirrorLayers[i].bounds.size.height = target * 0.45 }
                let from = bar.presentation()?.bounds.height ?? bar.bounds.height
                if !showsLive { bar.removeAnimation(forKey: "level") }
                bar.bounds.size.height = target
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                a.fromValue = from
                a.toValue = target
                // Чуть дольше интервала: следующая точка придёт раньше конца — без остановок между обновлениями.
                a.duration = f.interval * 1.15
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
                bar.add(a, forKey: "live")
            }
            CATransaction.commit()
            showsLive = true
        }
    }
}

/// Крутящееся кольцо «идёт работа» (агенты, полка) на слоях Core Animation: вращение считает сервер отрисовки — в
/// процессе ни таймера, ни кадров SwiftUI (было TimelineView 20–30 к/с: каждый кадр — проход по всему острову).
/// Ставить только при `islandMotion.allowsContinuousAnimation` и не в снимках (там — статичное кольцо).
public struct SpinningRing: NSViewRepresentable {
    var track: Color?
    var arc: Color
    var lineWidth: CGFloat
    var fraction: CGFloat
    var period: Double

    public init(track: Color?, arc: Color, lineWidth: CGFloat, fraction: CGFloat = 0.25, period: Double = 1) {
        self.track = track; self.arc = arc; self.lineWidth = lineWidth; self.fraction = fraction; self.period = period
    }

    public func makeNSView(context: Context) -> RingView { RingView() }
    public func updateNSView(_ v: RingView, context: Context) {
        v.apply(.init(track: track.map { NSColor($0).cgColor }, arc: NSColor(arc).cgColor, lineWidth: lineWidth,
                      fraction: fraction, period: period))
    }

    public final class RingView: NSView {
        struct Config: Equatable { var track: CGColor?; var arc: CGColor; var lineWidth: CGFloat; var fraction: CGFloat; var period: Double }
        private let spin = CALayer()
        private let trackLayer = CAShapeLayer()
        private let arcLayer = CAShapeLayer()
        private var config: Config?

        public override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for l in [trackLayer, arcLayer] { l.fillColor = nil; l.lineCap = .round; spin.addSublayer(l) }
            layer?.addSublayer(spin)
        }
        required init?(coder: NSCoder) { nil }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(_ c: Config) {
            guard c != config else { return }
            let periodChanged = c.period != config?.period
            config = c
            CATransaction.begin(); CATransaction.setDisableActions(true)
            trackLayer.strokeColor = c.track
            trackLayer.isHidden = c.track == nil
            arcLayer.strokeColor = c.arc
            trackLayer.lineWidth = c.lineWidth; arcLayer.lineWidth = c.lineWidth
            arcLayer.strokeEnd = c.fraction
            CATransaction.commit()
            needsLayout = true
            if periodChanged || spin.animation(forKey: "spin") == nil {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * Double.pi          // по часовой (слой без переворота: ось y вверх)
                a.duration = max(0.2, c.period)
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                spin.add(a, forKey: "spin")
            }
        }

        public override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            spin.frame = bounds
            let inset = (config?.lineWidth ?? 2) / 2
            let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            for l in [trackLayer, arcLayer] { l.frame = spin.bounds; l.path = path }
            CATransaction.commit()
        }
    }
}

/// Кромка «переливается» (темы с `rim.animated`): конический градиент крутится под маской-обводкой формы острова на
/// слоях Core Animation — в процессе ни кадра (было TimelineView 30 к/с: перерисовка фона всего острова).
/// Форма — `IslandShape` (анимируемая): при морфе острова обводка идёт за пружиной кадр в кадр, как у SwiftUI-обводки.
public struct RotatingConicStroke: NSViewRepresentable, Animatable {
    var shape: IslandShape
    var colors: [Color]
    var lineWidth: CGFloat
    var period: Double

    public init(shape: IslandShape, colors: [Color], lineWidth: CGFloat, period: Double = 6) {
        self.shape = shape; self.colors = colors; self.lineWidth = lineWidth; self.period = period
    }

    public var animatableData: IslandShape.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    public func makeNSView(context: Context) -> StrokeView { StrokeView() }
    public func updateNSView(_ v: StrokeView, context: Context) {
        v.apply(.init(shape: shape, colors: colors.map { NSColor($0).cgColor }, lineWidth: lineWidth, period: period))
    }

    public final class StrokeView: NSView {
        struct Config: Equatable { var shape: IslandShape; var colors: [CGColor]; var lineWidth: CGFloat; var period: Double }
        private let gradient = CAGradientLayer()
        private let mask = CAShapeLayer()
        private var config: Config?

        public override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            layer?.addSublayer(gradient)
            layer?.mask = mask
        }
        required init?(coder: NSCoder) { nil }
        public override var isFlipped: Bool { true }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(_ c: Config) {
            guard c != config else { return }
            let periodChanged = c.period != config?.period
            config = c
            CATransaction.begin(); CATransaction.setDisableActions(true)
            gradient.colors = c.colors
            mask.lineWidth = c.lineWidth
            CATransaction.commit()
            needsLayout = true
            layoutSubtreeIfNeeded()   // форма меняется на каждом кадре морфа — путь сразу, а не на следующем проходе
            if periodChanged || gradient.animation(forKey: "spin") == nil { addSpin() }
        }

        /// Геометрия подслоёв — как у вью: flipped-вью AppKit даёт слой с осью y вниз (как у SwiftUI-пути формы).
        private var layerFlipped: Bool { isFlipped }

        /// Вращение по часовой, как в макете (themes.css): при оси y вниз положительный угол — по часовой,
        /// при оси y вверх — против (ревью 14.11: было −2π при перевёрнутой геометрии — крутилось против часовой).
        private func addSpin() {
            guard let c = config else { return }
            let flipped = layerFlipped
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = (flipped ? 2 : -2) * Double.pi
            a.duration = max(1, c.period)
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            // Полный оборот за 6 с: 20 к/с глазу хватает.
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
            gradient.add(a, forKey: "spin")
        }

        public override func layout() {
            super.layout()
            guard let root = layer else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // Квадрат по диагонали вью: при вращении градиент закрывает всю обводку.
            let side = hypot(bounds.width, bounds.height)
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            mask.frame = root.bounds
            // Путь задан сверху вниз (SwiftUI); если слой не перевёрнут (y вверх) — отразить.
            if let p = config?.shape.path(in: bounds).cgPath {
                if layerFlipped {
                    mask.path = p
                } else {
                    var t = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
                    mask.path = p.copy(using: &t)
                }
            }
            CATransaction.commit()
        }
    }
}

/// Кольцо прогресса (загрузка в «капле»).
public struct Ring: View {
    var value: Double
    var lineWidth: CGFloat
    var tint: Color?
    @Environment(\.islandTheme) private var theme

    public init(value: Double, lineWidth: CGFloat = 3.5, tint: Color? = nil) {
        self.value = value; self.lineWidth = lineWidth; self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle().stroke(theme.primary.opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint ?? theme.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) %")
    }
}

/// Обложка: картинка или плейсхолдер-градиент (`.art` в макетах, без чужих картинок).
public struct ArtworkView: View {
    public enum Placeholder: Sendable { case warm, sea, violet }
    var image: NSImage?
    var cornerRadius: CGFloat
    var placeholder: Placeholder

    public init(image: NSImage? = nil, cornerRadius: CGFloat = 10, placeholder: Placeholder = .warm) {
        self.image = image; self.cornerRadius = cornerRadius; self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Обложка")
        .accessibilityAddTraits(.isImage)
    }

    private var placeholderView: some View {
        GeometryReader { g in
            let d = max(1, min(g.size.width, g.size.height))
            placeholderLayers(d)
        }
    }

    /// Радиусы — доли размера, как у CSS radial-gradient в макетах (иначе на 22 pt всё сливается в бурое).
    @ViewBuilder private func placeholderLayers(_ d: CGFloat) -> some View {
        switch placeholder {
        case .warm:
            ZStack {
                LinearGradient(colors: [Color(hex: "#FF7A45"), Color(hex: "#7B2CFF")], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: "#FF3D7F"), Color(hex: "#FF3D7F").opacity(0)],
                               center: UnitPoint(x: 0.75, y: 0.7), startRadius: 0, endRadius: d * 0.57)
                RadialGradient(colors: [Color(hex: "#FFD36E"), Color(hex: "#FFD36E").opacity(0)],
                               center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: d * 0.45)
                RadialGradient(colors: [Color.black.opacity(0.45), Color.black.opacity(0)],
                               center: UnitPoint(x: 0.5, y: 1.2), startRadius: 0, endRadius: d * 0.6)
            }
        case .sea:
            ZStack {
                LinearGradient(colors: [Color(hex: "#00B3A4"), Color(hex: "#0B1F5E")], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: "#1D4FD8"), Color(hex: "#1D4FD8").opacity(0)],
                               center: UnitPoint(x: 0.25, y: 0.8), startRadius: 0, endRadius: d * 0.6)
                RadialGradient(colors: [Color(hex: "#B8FFF2"), Color(hex: "#B8FFF2").opacity(0)],
                               center: UnitPoint(x: 0.7, y: 0.25), startRadius: 0, endRadius: d * 0.4)
            }
        case .violet:
            AngularGradient(colors: [Color(hex: "#7B2CFF"), Color(hex: "#FF3DCB"), Color(hex: "#2AD1FF"), Color(hex: "#7B2CFF")],
                            center: UnitPoint(x: 0.4, y: 0.6), angle: .degrees(200))
        }
    }

    /// Цвета для свечения под островом, соответствующие плейсхолдеру.
    public static func glowColors(for p: Placeholder) -> [Color] {
        switch p {
        case .warm: return [Color(hex: "#FF7A45"), Color(hex: "#FF3D7F"), Color(hex: "#7B2CFF")]
        case .sea: return [Color(hex: "#00B3A4"), Color(hex: "#1D4FD8")]
        case .violet: return [Color(hex: "#7B2CFF"), Color(hex: "#FF3DCB"), Color(hex: "#2AD1FF")]
        }
    }
}

/// «Живая точка» со свечением.
public struct StatusDot: View {
    var color: Color
    var size: CGFloat
    public init(_ color: Color, size: CGFloat = 6) { self.color = color; self.size = size }
    public var body: some View {
        Circle().fill(color).frame(width: size, height: size).shadow(color: color, radius: size * 0.9)
            .accessibilityHidden(true)
    }
}

/// Стандартные цвета статусов (из base.css).
public enum IslandPalette {
    public static let ok = Color(hex: "#39D98A")
    public static let warn = Color(hex: "#FFB020")
    public static let err = Color(hex: "#FF5470")
    public static let blue = Color(hex: "#4AA8FF")
    public static let violet = Color(hex: "#A879FF")
    public static let okText = Color(hex: "#7CF0B4")
    public static let warmText = Color(hex: "#FFB36E")

    /// Текст «всё хорошо» под тему: на светлом острове светло-зелёный не читается — берём тёмный.
    public static func okText(_ theme: Theme) -> Color { theme.isLight ? Color(hex: "#13804F") : okText }
    /// Тёплый текст (таймер, предупреждение) под тему.
    public static func warmText(_ theme: Theme) -> Color { theme.isLight ? Color(hex: "#B4560A") : warmText }
    /// Цвет статуса для текста/значков под тему: ok / warn / err темнее на светлом острове.
    public static func readable(_ color: Color, on theme: Theme) -> Color {
        guard theme.isLight else { return color }
        return Color(NSColor(color).blended(withFraction: 0.35, of: .black) ?? NSColor(color))
    }
}

/// Аккуратный плейсхолдер вкладки для модулей, которые ещё не написаны.
public struct ModulePlaceholderView: View {
    var title: String
    var systemImage: String
    var note: String
    @Environment(\.islandTheme) private var theme

    public init(title: String, systemImage: String, note: String = "Модуль в разработке") {
        self.title = title; self.systemImage = systemImage; self.note = note
    }

    public var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [theme.accentColor, theme.accent2Color], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: systemImage).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(theme.font(20, .bold)).foregroundStyle(theme.primary)
                Text(note).font(theme.font(13, .medium)).foregroundStyle(theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
