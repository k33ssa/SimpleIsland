import SwiftUI
import IslandCore

/// Вкладка «Сегодня» (макет 03): плитки рядами, ширина плитки — по её весу в ряду.
struct TodayView: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let rows = TodayLayout.rows(model.prefs.enabledTiles)
        if rows.isEmpty {
            ModulePlaceholderView(title: "Сегодня", systemImage: "calendar", note: "Все плитки выключены — включи в настройках")
        } else {
            GeometryReader { g in
                VStack(spacing: TodayLayout.gap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let sum = row.reduce(0) { $0 + $1.weight }
                        let free = g.size.width - TodayLayout.gap * CGFloat(row.count - 1)
                        HStack(spacing: TodayLayout.gap) {
                            ForEach(row) { tile in
                                tileView(tile)
                                    .frame(width: max(0, free * tile.weight / sum), height: TodayLayout.rowHeight)
                            }
                        }
                    }
                }
                .frame(width: g.size.width, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private func tileView(_ t: TodayTile) -> some View {
        switch t {
        case .event: EventTile(model: model)
        case .weather: WeatherTile(model: model)
        case .system: SystemTile(model: model)
        case .batteries: BatteriesTile(model: model)
        case .clipboard: ClipboardTile(model: model)
        case .toggles: TogglesTile(model: model, mirror: model.mirror)
        }
    }
}

// MARK: - Общее

/// Подпись плитки (`.tile .lbl`): значок + КАПС, справа — необязательное.
struct TileLabel<Trailing: View>: View {
    var title: String
    var systemImage: String
    var trailing: Trailing
    @Environment(\.islandTheme) private var theme

    init(_ title: String, systemImage: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.systemImage = systemImage; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
            Text(title.uppercased()).font(theme.font(10.5, .semibold)).tracking(0.5).lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            trailing
        }
        .foregroundStyle(theme.tertiary)
        .frame(height: 14)
    }
}

extension Theme {
    /// Ещё бледнее tertiary (`--ink4`).
    var quaternary: Color { tertiary.opacity(0.65) }
    /// Подложка внутри плитки (карточки буфера, ячейки тумблеров).
    var innerFill: Color { primary.opacity(isLight ? 0.06 : 0.07) }
}

/// Сообщение «нужно разрешение» с кнопкой «Разрешить…». `compact` — для узкой плитки.
struct PermissionNotice: View {
    var title: String
    var note: String
    var button: String = "Разрешить…"
    var compact = false
    var action: () -> Void
    var dismiss: (() -> Void)?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: compact ? 10 : 11, weight: .bold))
                    .foregroundStyle(IslandPalette.warmText(theme))
                Text(title).font(theme.font(compact ? 12.5 : 13.5, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(note).font(theme.font(compact ? 10.5 : 11.5, .medium)).foregroundStyle(theme.tertiary)
                .lineLimit(compact ? 2 : 3).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                IslandButton(button, style: .solid, height: compact ? 24 : 26, action: action)
                if let dismiss { IslandButton(systemImage: "xmark", height: compact ? 24 : 26, action: dismiss).help("Не сейчас") }
            }
            .padding(.top, compact ? 0 : 2)
        }
    }
}
