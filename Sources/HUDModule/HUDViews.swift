import SwiftUI
import IslandCore

/// Значок + подпись одним цветом (Нет сети, Caps Lock…). Цвет — под тему.
struct HUDTag: View {
    enum Tone { case plain, ok, bad, caps }
    var text: String
    var systemImage: String
    var tone: Tone
    @Environment(\.islandTheme) private var theme

    private var color: Color {
        switch tone {
        case .plain: return theme.primary
        case .ok: return IslandPalette.okText(theme)
        case .bad: return IslandPalette.readable(HUDFlashes.badTint, on: theme)
        case .caps: return IslandPalette.warmText(theme)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 13.5, weight: .semibold))
            Text(text).font(theme.font(12.5, .bold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(color)
    }
}

/// Приглушённый текст справа (интерфейс сети, приложение, «отключены»).
struct HUDNote: View {
    var text: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Text(text).font(theme.font(12.5, .semibold)).foregroundStyle(theme.tertiary)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}

/// Раскладка: прежняя слева.
struct LayoutFrom: View {
    var code: String?
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").font(.system(size: 12.5, weight: .semibold))
            if let code { Text(code).font(theme.font(12.5, .bold)) }
        }
        .foregroundStyle(theme.tertiary)
    }
}

/// Раскладка: новая справа — стрелка и «таблетка» RU; Caps Lock — оранжевая точка.
struct LayoutTo: View {
    var code: String
    var capsOn: Bool
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            if capsOn { StatusDot(IslandPalette.readable(HUDFlashes.capsTint, on: theme), size: 6) }
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.secondary)
            Text(code)
                .font(theme.font(12.5, .heavy))
                .lineLimit(1).fixedSize()
                .foregroundStyle(theme.isLight ? Color.white : Color.black)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.primary))
        }
    }
}

/// Caps Lock: оранжевая точка «вкл» / «выкл».
struct CapsState: View {
    var on: Bool
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            if on { StatusDot(IslandPalette.readable(HUDFlashes.capsTint, on: theme), size: 7) }
            Text(on ? "вкл" : "выкл").font(theme.font(12.5, .bold))
                .foregroundStyle(on ? theme.primary : theme.tertiary)
        }
    }
}

/// Камера/микрофон: зелёная точка и значки (макет 06, событие 07).
struct CaptureIcons: View {
    var camera: Bool
    var microphone: Bool
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 7) {
            StatusDot(IslandPalette.ok, size: 7)
            if camera { Image(systemName: "camera").font(.system(size: 12.5, weight: .semibold)) }
            if microphone { Image(systemName: "mic.fill").font(.system(size: 12.5, weight: .semibold)) }
        }
        .foregroundStyle(theme.primary)
    }
}

/// Значок наушников для карточки подключения: светлый кружок, как в макете. На светлых темах (paper, sakura)
/// у него тонкая обводка цветом текста темы — иначе она сливается со светлым островом.
struct HeadphonesBadge: View {
    var symbol: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#F5F5F7"), Color(hex: "#CFD2D8")], startPoint: .top, endPoint: .bottom)
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: "#222222"))
        }
        .overlay {
            if theme.isLight {
                Circle().strokeBorder(theme.primary.opacity(0.28), lineWidth: 1.5)
            }
        }
    }
}

/// Заряд наушников справа в карточке подключения: «L 82% · R 80%» и приглушённое «кейс 54%» (макет 06, событие 04).
struct HeadphonesBatteryView: View {
    var top: String
    var bottom: String?
    @Environment(\.islandTheme) private var theme
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(top).foregroundStyle(theme.primary)
            if let bottom { Text(bottom).foregroundStyle(theme.tertiary) }
        }
        .font(theme.font(12, .bold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}
