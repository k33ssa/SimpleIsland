import AppKit
import SwiftUI

/// Раскладка компакта: левое ухо | вырез (пусто) | правое ухо. Контент никогда не попадает под железо.
public struct EarsLayout<L: View, T: View>: View {
    var notchGap: CGFloat
    var sideWidth: CGFloat
    var inset: CGFloat
    var leading: L
    var trailing: T

    public init(notchGap: CGFloat, sideWidth: CGFloat, inset: CGFloat = 10,
                @ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) {
        self.notchGap = notchGap; self.sideWidth = sideWidth; self.inset = inset
        self.leading = leading(); self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: max(0, sideWidth - inset), alignment: .leading)
                .padding(.leading, inset)
            Color.clear.frame(width: notchGap)
            trailing
                .frame(width: max(0, sideWidth - inset), alignment: .trailing)
                .padding(.trailing, inset)
        }
    }
}

/// Части HUD-вспышки: левое ухо (иконка + подпись) и правое (полоса + число) по стилю.
public struct HUDLeading: View {
    var event: HUDEvent
    /// Стиль «Заливка»: подпись лежит на цветной заливке — делаем её ярче (макет 06, зарядка).
    var onFill: Bool
    @Environment(\.islandTheme) private var theme
    public init(event: HUDEvent, onFill: Bool = false) { self.event = event; self.onFill = onFill }

    private var labelColor: Color {
        guard onFill else { return theme.tertiary }
        guard let t = event.tint else { return theme.primary }
        return theme.isLight ? IslandPalette.readable(t, on: theme)
            : Color(NSColor(t).blended(withFraction: 0.45, of: .white) ?? NSColor(t))
    }
    public var body: some View {
        if let custom = event.customLeading {
            custom
        } else {
            HStack(spacing: 7) {
                if let s = event.systemImage {
                    Image(systemName: s).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(onFill ? labelColor : (event.tint ?? theme.primary))
                        .contentTransition(.symbolEffect(.replace))
                }
                if let l = event.label {
                    Text(l).font(theme.font(12.5, onFill ? .bold : .semibold)).foregroundStyle(labelColor)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
    }
}

public struct HUDTrailing: View {
    var event: HUDEvent
    var style: HUDBarStyle
    @Environment(\.islandTheme) private var theme
    public init(event: HUDEvent, style: HUDBarStyle) { self.event = event; self.style = style }

    public var body: some View {
        if let custom = event.customTrailing {
            custom
        } else {
            HStack(spacing: 8) {
                if let v = event.value {
                    switch style {
                    case .thread:
                        ProgressTrack(value: v, height: 4, tint: event.tint.map { AnyShapeStyle($0) })
                            .frame(width: 70)
                        if event.valueText == nil { number(v) }
                    case .segments:
                        // --- hud2 --- громкость сегментами — 16, как на железе (макет 06); подсветка задаёт своё число (10).
                        // Не больше, чем влезает в ухо `event.sideWidth` (событие с шириной по умолчанию — 12).
                        SegmentTrack(value: v, segments: Self.fittingSegments(event.segments, sideWidth: event.sideWidth),
                                     tint: event.tint)
                    case .fill:
                        if event.valueText == nil { number(v) }
                    case .number:
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int((v * 100).rounded()))").font(theme.font(17, .heavy)).monospacedDigit()
                            Text("%").font(theme.font(11, .semibold)).foregroundStyle(theme.tertiary)
                        }
                        .foregroundStyle(theme.primary)
                    }
                }
                if let t = event.valueText {
                    Text(t).font(theme.font(12.5, .bold)).monospacedDigit().foregroundStyle(theme.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }

    // --- hud2 --- сколько сегментов (5 pt + шаг 3 pt) показать: просили `requested` (потолок 16), но не больше,
    // чем влезает в ухо шириной `sideWidth` за вычетом отступа от края (12, как `inset` у HUD) и зазора у выреза
    // (8). Ухо 120 pt (по умолчанию у `HUDEvent`) — 12 сегментов, 145 pt — все 16. Минимум 1.
    public static func fittingSegments(_ requested: Int, sideWidth: CGFloat, inset: CGFloat = 12,
                                       notchGap: CGFloat = 8) -> Int {
        let fit = Int(floor((sideWidth - inset - notchGap + 3) / 8))
        return max(1, min(requested, 16, fit))
    }

    private func number(_ v: Double) -> some View {
        Text("\(Int((v * 100).rounded()))")
            .font(theme.font(12, .bold)).monospacedDigit()
            .foregroundStyle(theme.primary)
            // «100» не влезало в 24 pt и переносилось «10 / 0» (18.11): одна строка, ширина под три цифры.
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 26, alignment: .trailing)
            .contentTransition(.numericText())
    }
}

/// Заливка всего острова до уровня (HUD «Заливка», зарядка).
///
/// С вырезом (16.11, живой скрин «Заряжается 63 %»): середину острова закрывает железо, и при линейной заливке
/// край уровня 40–60 % уходил под вырез — полоска не читалась. Теперь шкала идёт только по видимым крыльям:
/// 0–50 % — левое крыло, 50–100 % — правое, вырез пропускается (`edgeX`). Край уровня и его кромка никогда не
/// лежат под вырезом; 50 % — ровно полное левое крыло. Без выреза (`notch` = 0) — линейно по всему острову.
public struct HUDFillBackground: View {
    var value: Double
    var tint: Color?
    /// Ширина выреза по центру острова (pt); 0 — выреза нет.
    var notch: CGFloat
    /// Вогнутые «уши» формы острова по бокам (`IslandMetrics.earRadius`): слой рисуется во всю форму
    /// (`outerWidth`), шкала — по телу острова между ушами. Левое ухо залито с первого процента, правое — на 100 %.
    var ear: CGFloat
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandMotion) private var motion
    @Environment(\.isSnapshot) private var isSnapshot
    public init(value: Double, tint: Color? = nil, notch: CGFloat = 0, ear: CGFloat = 0) {
        self.value = value; self.tint = tint; self.notch = notch; self.ear = max(0, ear)
    }

    /// Ширина светлой кромки на краю уровня.
    public static let edgeWidth: CGFloat = 1.5

    /// Где край уровня `value` в острове шириной `width` с вырезом `notch` по центру (0 — без выреза).
    /// Справа от выреза край стоит не ближе `edgeWidth` к нему: кромка целиком на виду.
    public nonisolated static func edgeX(value: Double, width: CGFloat, notch: CGFloat) -> CGFloat {
        let v = CGFloat(min(1, max(0, value.isFinite ? value : 0)))
        guard notch > 0, notch < width else { return width * v }
        let wing = (width - notch) / 2
        let d = v * 2 * wing
        if d <= wing { return d }
        return min(width, max(wing + notch + edgeWidth, d + notch))
    }

    /// Край уровня в слое во всю форму острова (`outerWidth` = тело + 2 уха): 0 % — пусто, 100 % — до внешнего
    /// края правого уха, между — `ear + edgeX` по телу.
    public nonisolated static func outerEdgeX(value: Double, outerWidth: CGFloat, notch: CGFloat, ear: CGFloat) -> CGFloat {
        let v = value.isFinite ? value : 0
        if v <= 0 { return 0 }
        if v >= 1 { return outerWidth }
        let body = max(0, outerWidth - 2 * ear)
        return ear + edgeX(value: v, width: body, notch: notch)
    }

    public var body: some View {
        let c = tint ?? theme.primary
        let base = tint == nil ? 0.2 : 0.32
        GeometryReader { g in
            let edge = Self.outerEdgeX(value: value, outerWidth: g.size.width, notch: notch, ear: ear)
            ZStack(alignment: .leading) {
                // Едва заметная «ёмкость» крыльев: пустая часть читается как шкала, а не как чёрный остров.
                Rectangle().fill(c.opacity(0.06))
                // Заливка чуть ярче к краю уровня и светлая кромка на краю — уровень читается, а не обрывается.
                Rectangle()
                    .fill(LinearGradient(colors: [c.opacity(base * 0.8), c.opacity(base * 1.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(c.opacity(0.75)).frame(width: Self.edgeWidth).blur(radius: 0.6)
                    }
                    .frame(width: edge)
            }
            // Уровень меняется (громкость клавишами, заряд) — край едет пружиной острова; «Уменьшить движение» —
            // короткое затухание, окно не видно — без анимации (`islandMotion`).
            .animation(isSnapshot ? nil : motion.animation(theme.springAnimation), value: value)
        }
    }
}

/// Строка уведомления под вырезом (макет 02-states, состояние 05).
public struct NotificationRow: View {
    var notification: IslandNotification
    var onAction: (IslandNotificationAction) -> Void
    @Environment(\.islandTheme) private var theme

    public init(notification: IslandNotification, onAction: @escaping (IslandNotificationAction) -> Void) {
        self.notification = notification; self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(notification.title).font(theme.font(13, .bold)).foregroundStyle(theme.primary)
                    if let s = notification.source {
                        Text(" · \(s)").font(theme.font(13, .semibold)).foregroundStyle(theme.tertiary.opacity(0.7))
                    }
                }
                .lineLimit(1)
                Text(notification.body).font(theme.font(12.5)).foregroundStyle(theme.secondary)
                    .lineLimit(max(1, min(3, notification.bodyLines))).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: notification.bodyLines > 1)
            }
            Spacer(minLength: 4)
            // --- hud2 --- необязательная правая часть (заряд AirPods «L/R %» и «кейс %» в две строки, макет 06).
            if let t = notification.trailing { t.accessibilityHidden(true) }
            ForEach(notification.actions) { a in
                IslandButton(a.title, style: style(a.role), height: 28) { onAction(a) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notification.spokenDescription)
    }

    @ViewBuilder private var avatar: some View {
        ZStack {
            if let icon = notification.icon {
                icon
            } else {
                Circle().fill(LinearGradient(colors: notification.avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                if let s = notification.systemImage {
                    Image(systemName: s).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text(notification.avatarText ?? String(notification.title.prefix(1)))
                        .font(theme.font(13, .heavy)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func style(_ r: IslandNotificationAction.Role) -> IslandButton.Style {
        switch r {
        case .normal: return .plain
        case .primary: return .solid
        case .destructive: return .destructive
        }
    }
}
