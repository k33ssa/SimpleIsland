import AppKit
import SwiftUI
import IslandCore

// Внешний вид окна настроек и онбординга: палитра из темы острова и свои контролы (как в макете 08-editor).
// Контролы нарисованы на SwiftUI, без NSView-обёрток: так они одинаковы во всех темах и видны в снимках
// (ImageRenderer не рисует Toggle/Slider/ScrollView macOS).

/// Цвета окна, выведенные из темы: светлая тема (paper, sakura) → светлое окно, остальные — тёмное с оттенком фона.
struct SettingsPalette {
    var theme: Theme
    var light: Bool
    var window: Color
    var ink: Color
    var ink2: Color
    var ink3: Color
    var ink4: Color
    var accent: Color
    /// Вторая точка градиента полос (светлее акцента).
    var accentLight: Color
    /// Цвет поверх акцента (ручка тумблера, текст на акцентной кнопке).
    var onAccent: Color
    var hair: Color
    var card: Color
    var cardStrong: Color

    init(theme: Theme, forceDark: Bool = false) {
        self.theme = theme
        let light = theme.isLight && !forceDark
        self.light = light
        let base = NSColor(hex: "#17161D")!
        if light {
            window = Color(hex: theme.background.colors.first ?? "#F6F5F2", fallback: Color(hex: "#F6F5F2"))
        } else if theme.isLight || theme.background.type == .glass {
            window = Color(nsColor: base)
        } else {
            let last = NSColor(hex: theme.background.colors.last ?? "#000000") ?? .black
            let tint = last.luminance > 0.025 ? 0.45 : 0
            window = Color(nsColor: base.blended(withFraction: tint, of: last) ?? base)
        }
        if theme.isLight && forceDark {
            let o = Theme.obsidian
            ink = o.primary; ink2 = o.secondary; ink3 = o.tertiary
        } else {
            ink = theme.primary; ink2 = theme.secondary; ink3 = theme.tertiary
            // Третичный цвет темы бывает слишком бледным для мелких подписей окна (sakura: 2,7 : 1) — тогда вторичный.
            if Self.contrast(NSColor(ink3), NSColor(window)) < 3.5 { ink3 = ink2 }
        }
        ink4 = ink3.opacity(0.75)
        let accentHex = (theme.isLight && forceDark) ? Theme.obsidian.accent : theme.accent
        let accentNS = NSColor(hex: accentHex) ?? .orange
        accent = Color(nsColor: accentNS)
        accentLight = Color(nsColor: accentNS.blended(withFraction: 0.35, of: .white) ?? accentNS)
        onAccent = accentNS.luminance > 0.62 ? Color(hex: "#111111") : .white
        let inkBase = light ? Color.black : Color.white
        hair = inkBase.opacity(light ? 0.09 : 0.08)
        card = inkBase.opacity(light ? 0.045 : 0.05)
        cardStrong = inkBase.opacity(light ? 0.07 : 0.08)
    }

    /// Контраст WCAG двух цветов (полупрозрачный передний — поверх заднего), 1…21.
    static func contrast(_ fg: NSColor, _ bg: NSColor) -> Double {
        func rgb(_ c: NSColor) -> (Double, Double, Double, Double) {
            let c = c.usingColorSpace(.sRGB) ?? .black
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
        let b = rgb(bg), f = rgb(fg)
        let mix = (f.0 * f.3 + b.0 * (1 - f.3), f.1 * f.3 + b.1 * (1 - f.3), f.2 * f.3 + b.2 * (1 - f.3))
        func lum(_ c: (Double, Double, Double)) -> Double {
            func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
        }
        let l1 = lum(mix), l2 = lum((b.0, b.1, b.2))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { theme.font(size, weight) }
    var mono: Font { .system(size: 12, weight: .semibold, design: .monospaced) }
}

private struct SettingsPaletteKey: EnvironmentKey {
    static let defaultValue = SettingsPalette(theme: .obsidian)
}

extension EnvironmentValues {
    var settingsPalette: SettingsPalette {
        get { self[SettingsPaletteKey.self] }
        set { self[SettingsPaletteKey.self] = newValue }
    }
}

// MARK: - Текст

/// Заголовок раздела (`.main h2` + `.s2`).
struct SettingsHeader: View {
    var title: String
    var subtitle: String
    @Environment(\.settingsPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(p.font(22, .bold)).foregroundStyle(p.ink)
            Text(subtitle).font(p.font(13)).foregroundStyle(p.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Подпись группы капсом (`.lbl`).
struct SettingsLabel: View {
    var text: String
    @Environment(\.settingsPalette) private var p
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(p.font(11, .bold)).tracking(0.7)
            .foregroundStyle(p.ink4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Контролы

/// Тумблер 38×22 (`.tog`).
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var scale: CGFloat = 1
    @Environment(\.settingsPalette) private var p
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? p.accent : p.ink.opacity(p.light ? 0.16 : 0.14))
            Circle().fill(isOn ? p.onAccent : Color.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .frame(width: 18, height: 18)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .scaleEffect(scale)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "вкл" : "выкл")
    }
}

/// Строка «подпись … тумблер» (`.trow`).
struct SettingsToggleRow: View {
    var title: String
    var note: String? = nil
    @Binding var isOn: Bool
    @Environment(\.settingsPalette) private var p
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(p.font(12.5, .medium)).foregroundStyle(p.ink2)
                if let note { Text(note).font(p.font(11)).foregroundStyle(p.ink4).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            SettingsToggle(isOn: $isOn, scale: 0.85)
        }
        .frame(minHeight: 26)
    }
}

/// Слайдер с подписью и значением (`.sl`): полоса 4 pt с градиентом акцента и белая ручка.
struct SettingsSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    @Environment(\.settingsPalette) private var p

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(p.font(12.5, .medium)).foregroundStyle(p.ink2)
                Spacer()
                Text(format(value)).font(p.mono).foregroundStyle(p.ink)
            }
            GeometryReader { g in
                let w = max(1, g.size.width)
                let f = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                                / max(0.0001, range.upperBound - range.lowerBound))
                ZStack(alignment: .leading) {
                    Capsule().fill(p.ink.opacity(0.12)).frame(height: 4)
                    Capsule().fill(LinearGradient(colors: [p.accentLight, p.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * f), height: 4)
                    Circle().fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(p.light ? 0.12 : 0), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                        .frame(width: 18, height: 18)
                        .offset(x: w * f - 9)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let t = Double(min(max(v.location.x / w, 0), 1))
                    var nv = range.lowerBound + t * (range.upperBound - range.lowerBound)
                    if step > 0 { nv = (nv / step).rounded() * step }
                    value = min(max(nv, range.lowerBound), range.upperBound)
                })
            }
            .frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let d = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (dir == .increment ? d : -d), range.lowerBound), range.upperBound)
        }
    }
}

/// Сегменты (`.seg2`).
struct SettingsSegmented<ID: Hashable>: View {
    var options: [(id: ID, title: String)]
    @Binding var selection: ID
    @Environment(\.settingsPalette) private var p
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.id == selection
                Text(o.title)
                    .font(p.font(12, .semibold))
                    .foregroundStyle(on ? p.ink : p.ink3)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? p.ink.opacity(p.light ? 0.10 : 0.14) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = o.id }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.card.opacity(1.2)))
    }
}

/// Кнопка окна настроек: обычная (подложка), акцентная, пунктирная («новое»).
struct SettingsButton: View {
    enum Style { case plain, accent, dashed, quiet }
    var title: String
    var systemImage: String? = nil
    var style: Style = .plain
    var height: CGFloat = 30
    var action: () -> Void
    @Environment(\.settingsPalette) private var p
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let s = systemImage { Image(systemName: s).font(.system(size: height * 0.4, weight: .semibold)) }
                Text(title).font(p.font(12.5, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style == .accent || style == .quiet ? .clear : p.hair,
                              style: StrokeStyle(lineWidth: 1, dash: style == .dashed ? [4, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }
    private var fg: Color {
        switch style {
        case .accent: return p.onAccent
        case .dashed, .quiet: return p.ink3
        case .plain: return p.ink2
        }
    }
    private var bg: Color {
        switch style {
        case .accent: return p.accent
        case .plain: return p.card.opacity(1.2)
        case .dashed, .quiet: return .clear
        }
    }
}

/// Карточка группы настроек.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.settingsPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { SettingsLabel(title) }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.hair))
    }
}

/// Цветной квадратик-иконка раздела (`.nav .o`).
struct SettingsIconTile: View {
    var systemImage: String
    var colors: [Color]
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: systemImage).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Маленький статус-чип («разрешено», «нужно разрешение»).
struct SettingsStatusChip: View {
    var text: String
    var color: Color
    @Environment(\.settingsPalette) private var p
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(p.font(11, .semibold)).lineLimit(1)
        }
        .foregroundStyle(p.light ? color.opacity(0.95) : color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Прокрутка, которая в режиме снимков становится обычным стеком (ImageRenderer не рисует NSScrollView).
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
    }
}

extension View {
    /// Модификаторы на NSView (drag&drop, контекстное меню, поповер) — только в живом окне: ImageRenderer
    /// рисует вместо них заглушку.
    @ViewBuilder func liveOnly<V: View>(_ isSnapshot: Bool, _ apply: (Self) -> V) -> some View {
        if isSnapshot { self } else { apply(self) }
    }
}

/// Цвета статусов, читаемые на светлом и тёмном окне.
enum SettingsColors {
    static func ok(_ p: SettingsPalette) -> Color { p.light ? Color(hex: "#13804F") : Color(hex: "#39D98A") }
    static func warn(_ p: SettingsPalette) -> Color { p.light ? Color(hex: "#B4560A") : Color(hex: "#FFB020") }
    static func err(_ p: SettingsPalette) -> Color { p.light ? Color(hex: "#C0263F") : Color(hex: "#FF5470") }
    static func neutral(_ p: SettingsPalette) -> Color { p.ink3 }
}

/// Иконки модулей в сайдбаре и списках (цвета — как в макете 08).
enum SettingsModuleStyle {
    static func color(_ id: String) -> [Color] {
        switch id {
        case "media": return [Color(hex: "#FF3D7F")]
        case "today": return [Color(hex: "#FF7A45")]
        case "shelf": return [Color(hex: "#38BDF8")]
        case "agents": return [Color(hex: "#1F2937")]
        default: return [Color(hex: "#3A3A40")]
        }
    }

    /// Подпись строки вкладки (`.tl small`).
    static func note(_ id: String) -> String {
        switch id {
        case "media": return "открывается, когда играет музыка"
        case "today": return "по умолчанию"
        case "shelf": return "выскакивает при перетаскивании файла"
        case "agents": return "перебивает всё, когда агент ждёт"
        case "hud": return "громкость, яркость, подсветка — без вкладки"
        default: return ""
        }
    }

    /// Что модуль показывает в ухе компакта (для подписей слотов).
    static func earPart(_ id: String, leading: Bool) -> String {
        switch (id, leading) {
        case ("media", true): return "обложка"
        case ("media", false): return "эквалайзер"
        case ("agents", true): return "сессии"
        case ("agents", false): return "статус"
        case ("today", true): return "таймер"
        case ("today", false): return "встреча"
        case ("shelf", true): return "загрузка"
        case ("shelf", false): return "прогресс"
        default: return id
        }
    }
}
