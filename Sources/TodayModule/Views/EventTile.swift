import AppKit
import SwiftUI
import IslandCore

/// «Следующее»: событие, отсчёт, участники, «Подключиться», полоса дня с отметкой «сейчас».
struct EventTile: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    var body: some View {
        tile
            // Нажатие на плитку — Календарь на сегодня (есть событие — само событие); «Подключиться» перехватывает своё.
            .contentShape(Rectangle())
            .onTapGesture {
                guard model.calendarAccess == .granted else { return }
                model.openCalendar(EventLogic.featured(model.events, now: Date(), lead: TodayModel.reminderLead)?.main)
            }
            .help("Открыть Календарь на сегодня")
    }

    private var tile: some View {
        Tile {
            if model.calendarAccess != .granted {
                noAccess
            } else if isSnapshot || model.nowOverride != nil {
                content(now: model.now)
            } else if motion == .off {
                // Окно не видно, сон, блокировка — ни одного кадра; при показе уровень сменится и тикнет заново.
                content(now: Date())
            } else {
                // Перерисовка раз в минуту и только пока плитка на экране. Это смена текста, не анимация, —
                // поэтому и при «Уменьшить движение» (`.reduced`) отсчёт идёт.
                TimelineView(.everyMinute) { tl in content(now: tl.date) }
            }
        }
    }

    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileLabel("Календарь", systemImage: "calendar")
            Spacer(minLength: 6)
            PermissionNotice(title: "Нужен доступ к календарю",
                             note: "Покажу ближайшую встречу, отсчёт и кнопку «Подключиться».",
                             button: "Разрешить календарь…") { model.requestCalendar() }
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let featured = EventLogic.featured(model.events, now: now, lead: TodayModel.reminderLead)
        let next = featured?.main
        let today = EventLogic.today(model.events, now: now)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                TileLabel(next.map { $0.isOngoing(at: now) ? "Сейчас" : "Следующее" } ?? "Сегодня",
                          systemImage: next?.link != nil ? "video" : "calendar")
                    .padding(.trailing, 70)
                if let e = next {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(theme.font(17, .bold)).foregroundStyle(theme.primary)
                                .lineLimit(1).tracking(-0.2)
                            // Как в макете: одна строка «15:00 – 15:40 · Телемост · Дима, Лёша, Настя».
                            // Не влезли участники (узкая вкладка, кнопка рядом) — строка без них, а не «Ди…».
                            ViewThatFits(in: .horizontal) {
                                Text(whenLine(e, now: now, place: true, people: true)).fixedSize()
                                Text(whenLine(e, now: now, place: false, people: true)).fixedSize()
                                Text(whenLine(e, now: now, place: true, people: false)).lineLimit(1).truncationMode(.tail)
                            }
                            .font(theme.font(12, .medium)).foregroundStyle(theme.tertiary)
                            if let o = featured?.ongoing {
                                HStack(spacing: 5) {
                                    Circle().fill(color(o)).frame(width: 6, height: 6)
                                    Text("Сейчас: \(o.title) · до \(EventLogic.hm(o.end))").lineLimit(1)
                                }
                                .font(theme.font(11.5, .medium)).foregroundStyle(theme.secondary)
                                .padding(.top, 2)
                            }
                        }
                        Spacer(minLength: 0)
                        if e.link != nil {
                            IslandButton("Подключиться", style: .solid, height: 28) { model.join(e) }
                                .padding(.top, 10)
                        }
                    }
                    .padding(.top, 7)
                } else {
                    Text(model.events.isEmpty ? "Встреч нет" : "На сегодня всё")
                        .font(theme.font(17, .bold)).foregroundStyle(theme.primary).padding(.top, 7)
                    Text("Свободный вечер").font(theme.font(12, .medium)).foregroundStyle(theme.tertiary)
                }
                Spacer(minLength: 0)
                DayStrip(events: today, now: now)
            }
            if let e = next {
                countdown(e, now: now)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: -4)
            }
        }
    }

    /// Узко — сначала жертвуем сервисом/местом (рядом есть «Подключиться»), потом участниками.
    private func whenLine(_ e: TodayEvent, now: Date, place: Bool, people: Bool) -> String {
        var parts = [EventLogic.timeRange(e, now: now)]
        if place, let l = e.link { parts.append(l.service) }
        else if place, let loc = e.location, !loc.isEmpty, !loc.contains("://") { parts.append(loc) }
        if people, !e.attendees.isEmpty { parts.append(EventLogic.people(e.attendees)) }
        return parts.joined(separator: " · ")
    }

    private func color(_ e: TodayEvent) -> Color {
        e.colorHex.map { Color(hex: $0, fallback: IslandPalette.blue) } ?? IslandPalette.blue
    }

    @ViewBuilder private func countdown(_ e: TodayEvent, now: Date) -> some View {
        let c = EventLogic.countdown(to: e.start, end: e.end, now: now)
        let big = Text(c.value).font(theme.font(c.unit.isEmpty ? 17 : 24, .heavy))
        let small = Text(c.unit).font(theme.font(11.5, .bold))
        let txt = (big + small).monospacedDigit()
        if theme.isLight {
            txt.foregroundStyle(IslandPalette.warmText(theme))
        } else {
            // Акцент темы со светлым началом (в obsidian ≈ макетный #FFD36E → #FF7A45).
            let a = NSColor(theme.accentColor)
            let light = Color(nsColor: a.blended(withFraction: 0.4, of: .white) ?? a)
            txt.foregroundStyle(LinearGradient(colors: [light, theme.accentColor], startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// Полоса дня (`.day`): события цветом календаря, прошедшие бледнее, вертикальная отметка «сейчас».
struct DayStrip: View {
    var events: [TodayEvent]
    var now: Date
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let w = EventLogic.dayWindow(events, now: now)
        let span = max(1, w.end.timeIntervalSince(w.start))
        GeometryReader { g in
            let x = { (d: Date) -> CGFloat in g.size.width * CGFloat(min(1, max(0, d.timeIntervalSince(w.start) / span))) }
            ZStack(alignment: .leading) {
                // Высоты заданы явно: ZStack растягивает гибкие фигуры до самого высокого ребёнка (отметки).
                Capsule().fill(theme.primary.opacity(0.08)).frame(height: Self.track)
                ForEach(events) { e in
                    let x0 = x(e.start), x1 = x(e.end)
                    // Прошедшие бледнее; на светлом острове бледно-голубое терялось — там прозрачность меньше.
                    Capsule()
                        .fill(color(e))
                        .opacity(e.end <= now ? (theme.isLight ? 0.6 : 0.4) : 1)
                        .frame(width: max(8, x1 - x0), height: Self.track)
                        .offset(x: x0)
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.primary)
                    .frame(width: 2, height: Self.marker)
                    .shadow(color: theme.isLight ? .clear : theme.primary.opacity(0.9), radius: 4)
                    .offset(x: x(now) - 1)
            }
        }
        .frame(height: Self.marker)
    }

    /// Макет 03: тонкая дорожка, события той же толщины, отметка «сейчас» чуть выше.
    static let track: CGFloat = 5
    static let marker: CGFloat = 12

    private func color(_ e: TodayEvent) -> Color {
        guard let hex = e.colorHex else { return IslandPalette.blue }
        return Color(hex: hex, fallback: IslandPalette.blue)
    }
}

// MARK: - Компакт «встреча скоро»

struct MeetingCompactLeading: View {
    var title: String
    @Environment(\.islandTheme) private var theme

    /// Ширина уха под название: значок 11 + отступ 5 + текст + поля ядра; 96…150 pt (остров не шире ~486 pt).
    static func sideWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let w = (title as NSString).size(withAttributes: [.font: font]).width
        return min(150, max(96, ceil(w) + 11 + 5 + 32))
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "video.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(IslandPalette.warmText(theme))
            Text(title).font(theme.font(11.5, .semibold)).foregroundStyle(theme.primary).lineLimit(1)
        }
    }
}

struct MeetingCompactTrailing: View {
    var start: Date
    var staticText: String?
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        Group {
            if let s = staticText ?? (isSnapshot ? "5:00" : nil) {
                Text(s)
            } else {
                // Одна перерисовка в момент начала (не опрос): дальше вместо «0:00» — «сейчас».
                TimelineView(.explicit([start])) { _ in
                    let n = Date()
                    if start > n {
                        Text(timerInterval: n...start, countsDown: true, showsHours: false)
                    } else {
                        Text("сейчас")
                    }
                }
            }
        }
        .font(theme.font(12.5, .bold))
        .monospacedDigit()
        .foregroundStyle(IslandPalette.warmText(theme))
        .lineLimit(1)
    }
}
