import AppKit
import SwiftUI
import IslandCore

// Вкладка «Встречи» (Sten): вход один раз, запись, список, протокол с задачами по людям. Цвета — из темы,
// красный записи — `IslandPalette.err` (на светлых темах — темнее через `readable`).

enum MeetingsStyle {
    static let gradient = [Color(hex: "#FF5470"), Color(hex: "#A879FF")]
    static let recColors = [Color(hex: "#FF5470"), Color(hex: "#FF8A5B")]

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func when(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        if cal.isDate(d, inSameDayAs: now) { f.dateFormat = "сегодня, HH:mm" }
        else if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { f.dateFormat = "вчера, HH:mm" }
        else { f.dateFormat = "d MMM, HH:mm" }
        return f.string(from: d)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    /// Цвет аватара по имени — стабильный.
    static func avatar(_ name: String) -> [Color] {
        let palettes: [[String]] = [["#4AA8FF", "#2563EB"], ["#A879FF", "#7B2CFF"], ["#39D98A", "#0F9D58"],
                                    ["#FFB020", "#FF7A45"], ["#FF5470", "#B5179E"], ["#38BDF8", "#0EA5E9"]]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palettes[h % palettes.count].map { Color(hex: $0) }
    }
}

/// Вертикальная прокрутка; в снимках — обычный стек с обрезкой (ImageRenderer не рисует содержимое ScrollView).
struct VScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        if isSnapshot {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content }
        }
    }
}

struct MeetingsTabView: View {
    @ObservedObject var model: MeetingsModel
    var keyboard: (Bool) -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if !model.auth.isLoggedIn {
                LoginView(model: model, keyboard: keyboard)
            } else if let id = model.selected {
                MeetingDetailView(model: model, id: id)
            } else {
                HStack(spacing: 10) {
                    RecordTile(model: model).frame(width: 248)
                    MeetingsListTile(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !isSnapshot else { return }
            Task {
                if model.prefs.userName == nil { await model.verifySession() }
                await model.refreshList()
            }
        }
    }
}

// MARK: - Вход

private struct LoginView: View {
    @ObservedObject var model: MeetingsModel
    var keyboard: (Bool) -> Void
    @State private var server = ""
    @State private var name = ""
    @State private var password = ""
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Tile {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        AppBadge(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sten · протокол встреч").font(theme.font(11.5, .bold)).foregroundStyle(theme.tertiary)
                            Text("Войдите один раз").font(theme.font(15, .bold)).foregroundStyle(theme.primary)
                        }
                    }
                    Text("Дальше запись, итоги и задачи по людям — прямо в острове. Пароль не сохраняется: в Связке ключей остаётся только сессия.")
                        .font(theme.font(12)).foregroundStyle(theme.secondary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 248)
            Tile {
                VStack(alignment: .leading, spacing: 7) {
                    IslandField(title: "Сервер", text: $server, placeholder: StenServer.placeholderAddress)
                    HStack(spacing: 7) {
                        IslandField(title: "Имя", text: $name, placeholder: "имя в Sten")
                        IslandField(title: "Пароль", text: $password, placeholder: "пароль", secure: true, onSubmit: submit)
                    }
                    HStack(spacing: 8) {
                        IslandButton(model.auth == .loggingIn ? "Вхожу…" : "Войти", systemImage: "person.crop.circle.badge.checkmark",
                                     style: .accent, height: 28, action: submit)
                            .disabled(model.auth == .loggingIn)
                        if let m = model.authMessage {
                            Text(m).font(theme.font(11.5, .medium)).foregroundStyle(IslandPalette.warmText(theme))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .onAppear {
            server = model.prefs.server
            if isSnapshot { name = "anna" }
            keyboard(true)
        }
        .onDisappear {
            password = ""
            keyboard(false)
        }
    }

    private func submit() {
        if !model.setServer(server) { model.authMessage = "Непонятный адрес сервера"; return }
        let pw = password
        password = ""
        Task { await model.login(name: name, password: pw) }
    }
}

/// Поле ввода в стилистике острова (подложка как у плиток, без системной рамки).
struct IslandField: View {
    var title: String
    @Binding var text: String
    var placeholder: String
    var secure = false
    var onSubmit: () -> Void = {}
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(theme.font(10.5, .semibold)).foregroundStyle(theme.tertiary)
            Group {
                // ImageRenderer рисует NSTextField жёлтой заглушкой — в снимках текст как есть.
                if isSnapshot {
                    Text(text.isEmpty ? placeholder : (secure ? String(repeating: "•", count: text.count) : text))
                        .foregroundStyle(text.isEmpty ? theme.tertiary : theme.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                } else if secure { SecureField("", text: $text, prompt: prompt).onSubmit(onSubmit) }
                else { TextField("", text: $text, prompt: prompt).onSubmit(onSubmit) }
            }
            .textFieldStyle(.plain)
            .font(theme.font(12.5, .medium))
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.primary.opacity(0.08)))
            .accessibilityLabel(title)
        }
    }

    private var prompt: Text { Text(placeholder).foregroundColor(theme.tertiary) }
}

struct AppBadge: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: MeetingsStyle.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "person.2.wave.2.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Запись

private struct RecordTile: View {
    @ObservedObject var model: MeetingsModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                switch model.record {
                case .idle: idle
                case .starting: busy("Включаю микрофон…")
                case .recording: recording
                case .stopping: busy("Дописываю запись…")
                case .uploading: busy("Отправляю файлом…")
                }
                if let m = model.recordMessage {
                    Spacer(minLength: 4)
                    Text(m).font(theme.font(11, .medium)).foregroundStyle(IslandPalette.warmText(theme))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppBadge(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(signedIn).font(theme.font(11, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
                    Text("Новая встреча").font(theme.font(15, .bold)).foregroundStyle(theme.primary)
                }
            }
            Spacer(minLength: 6)
            Text("Sten разберёт разговор: итог, решения и задачи по людям.")
                .font(theme.font(11.5)).foregroundStyle(theme.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            RecordButton(recording: false) { Task { await model.startRecording() } }
        }
    }

    private var signedIn: String {
        if case .loggedIn(let n) = model.auth, !n.isEmpty { return "Sten · \(n)" }
        return "Sten"
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                StatusDot(IslandPalette.err, size: 8)
                Text("Идёт запись").font(theme.font(12, .bold)).foregroundStyle(IslandPalette.readable(IslandPalette.err, on: theme))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 10) {
                RecordClock(start: model.recordStart, size: 30)
                Spacer(minLength: 0)
                Visualizer(bars: 14, animated: true, height: 30, colors: MeetingsStyle.recColors,
                           feed: model.levels, barWidth: 3, gap: 2)
            }
            Spacer(minLength: 6)
            RecordButton(recording: true) { Task { await model.stopRecording() } }
        }
    }

    private func busy(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isSnapshot { Ring(value: 0.3, lineWidth: 3, tint: theme.primary).frame(width: 18, height: 18) }
                else { SpinningRing(track: theme.primary.opacity(0.15), arc: theme.primary, lineWidth: 2.5).frame(width: 18, height: 18) }
                Text(text).font(theme.font(13, .semibold)).foregroundStyle(theme.primary)
            }
            if let p = model.uploadProgress, model.record == .uploading { ProgressTrack(value: p) }
            Spacer(minLength: 0)
        }
    }
}

/// Таймер записи: раз в секунду (TimelineView по секундам — не чаще правила ядра), в снимках — статичный.
struct RecordClock: View {
    var start: Date?
    var size: CGFloat
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if isSnapshot || start == nil {
                text(start.map { Date().timeIntervalSince($0) } ?? 0)
            } else {
                TimelineView(.periodic(from: start!, by: 1)) { tl in text(tl.date.timeIntervalSince(start!)) }
            }
        }
        .accessibilityLabel("Время записи")
    }

    private func text(_ t: TimeInterval) -> some View {
        Text(MeetingsStyle.clock(t)).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(theme.primary)
    }
}

private struct RecordButton: View {
    var recording: Bool
    var action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(.white.opacity(recording ? 0 : 0.25)).frame(width: 16, height: 16)
                    if recording { RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10, height: 10) }
                    else { Circle().fill(.white).frame(width: 9, height: 9) }
                }
                Text(recording ? "Стоп" : "Начать запись").font(theme.font(13, .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .background(Capsule().fill(recording ? AnyShapeStyle(Color.white.opacity(0.16))
                                       : AnyShapeStyle(LinearGradient(colors: MeetingsStyle.recColors, startPoint: .leading, endPoint: .trailing))))
            .overlay(Capsule().strokeBorder(recording ? IslandPalette.err.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(recording ? "Остановить запись" : "Начать запись встречи")
    }
}

// MARK: - Список

private struct MeetingsListTile: View {
    @ObservedObject var model: MeetingsModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Tile(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Последние встречи").font(theme.font(11.5, .bold)).foregroundStyle(theme.tertiary)
                    Spacer()
                    IslandButton(systemImage: "arrow.clockwise", height: 22, accessibilityLabel: "Обновить список") {
                        Task { await model.refreshList(force: true) }
                    }
                }
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        if case .failed(let m) = model.listState, model.meetings.isEmpty {
            empty(symbol: "wifi.exclamationmark", title: "Список не загрузился", note: m)
        } else if model.listState == .loading && model.meetings.isEmpty {
            empty(symbol: "hourglass", title: "Загружаю…", note: "")
        } else if model.meetings.isEmpty {
            empty(symbol: "waveform", title: "Пока нет встреч",
                  note: "Нажмите «Начать запись» — протокол появится здесь.")
        } else {
            VScroll {
                VStack(spacing: 4) {
                    ForEach(model.meetings.prefix(30)) { m in
                        MeetingRow(meeting: m, status: model.processing[m.id],
                                   live: model.recordingId == m.id) { model.open(m.id) }
                    }
                }
            }
        }
    }

    private func empty(symbol: String, title: String, note: String) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.tertiary)
                .accessibilityHidden(true)
            Text(title).font(theme.font(13.5, .bold)).foregroundStyle(theme.primary)
            if !note.isEmpty {
                Text(note).font(theme.font(11.5)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MeetingRow: View {
    var meeting: StenMeeting
    var status: StenStatus?
    var live: Bool
    var action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(theme.font(12.5, .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                    Text(MeetingsStyle.when(meeting.createdAt)).font(theme.font(10.5)).foregroundStyle(theme.tertiary)
                }
                Spacer(minLength: 6)
                badge
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть протокол")
    }

    @ViewBuilder private var badge: some View {
        if live {
            Chip("Запись", systemImage: "record.circle", tint: IslandPalette.readable(IslandPalette.err, on: theme))
        } else if let s = status {
            HStack(spacing: 6) {
                if let p = s.percent { ProgressTrack(value: p / 100, height: 4).frame(width: 46) }
                Chip(s.percent.map { "Обработка \(Int($0))%" } ?? "Обработка", tint: IslandPalette.readable(IslandPalette.warn, on: theme))
            }
        } else {
            switch meeting.status {
            case "ready", "consensus": Chip("Готово", systemImage: "checkmark", tint: IslandPalette.okText(theme))
            case "processing": Chip("Обработка", tint: IslandPalette.readable(IslandPalette.warn, on: theme))
            case "error": Chip("Ошибка", tint: IslandPalette.readable(IslandPalette.err, on: theme))
            case "recording": Chip("Не дописана", tint: theme.secondary)
            default: EmptyView()
            }
        }
    }
}

// MARK: - Протокол

struct MeetingDetailView: View {
    @ObservedObject var model: MeetingsModel
    var id: Int
    @State private var copied = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandButton(systemImage: "chevron.left", height: 26, accessibilityLabel: "К списку встреч") { model.closeDetail() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(theme.font(14, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                    Text(MeetingsStyle.when(model.meeting(id)?.createdAt)).font(theme.font(10.5)).foregroundStyle(theme.tertiary)
                }
                Spacer(minLength: 6)
                IslandButton(copied ? "Скопировано" : "Копировать итог", systemImage: copied ? "checkmark" : "doc.on.doc",
                             height: 26) {
                    model.copySummary(id)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .disabled(model.reports[id]?.available != true)
                IslandButton("На сайте", systemImage: "arrow.up.right.square", height: 26,
                             accessibilityLabel: "Открыть протокол на сайте") { model.openOnSite(id) }
            }
            content
        }
    }

    private var title: String {
        let r = model.reports[id]?.title ?? ""
        return r.isEmpty ? (model.meeting(id)?.title ?? "Встреча") : r
    }

    @ViewBuilder private var content: some View {
        if let s = model.processing[id] {
            note(symbol: "waveform", title: s.label ?? "Идёт обработка…",
                 text: "Протокол появится сам — остров скажет «Протокол готов».", progress: s.percent.map { $0 / 100 } ?? 0.05)
        } else if case .failed(let m) = model.detailState {
            note(symbol: "exclamationmark.triangle", title: m, text: "Попробуйте открыть на сайте.", progress: nil)
        } else if let r = model.reports[id] {
            if r.available { ReportView(report: r) }
            else { note(symbol: "doc.text.magnifyingglass", title: "Обзора пока нет",
                        text: "Краткий обзор появится после обработки записи.", progress: nil) }
        } else {
            note(symbol: "hourglass", title: "Загружаю протокол…", text: "", progress: nil)
        }
    }

    private func note(symbol: String, title: String, text: String, progress: Double?) -> some View {
        Tile {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(theme.font(13.5, .bold)).foregroundStyle(theme.primary).lineLimit(2)
                    if !text.isEmpty { Text(text).font(theme.font(11.5)).foregroundStyle(theme.secondary).lineLimit(2) }
                    if let progress { ProgressTrack(value: progress).frame(maxWidth: 260) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Итог слева, люди с задачами справа.
struct ReportView: View {
    var report: StenReport
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Tile(padding: 12) {
                VScroll {
                    VStack(alignment: .leading, spacing: 8) {
                        if !report.outcome.isEmpty { section("Итог", report.outcome) }
                        if !report.summary.isEmpty { section("Кратко", report.summary) }
                        if !report.decisions.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                header("Решения")
                                ForEach(Array(report.decisions.enumerated()), id: \.offset) { _, d in
                                    bullet(d.text, extra: d.initiator, symbol: "checkmark.seal.fill",
                                           tint: IslandPalette.okText(theme))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 270)
            PeopleView(groups: StenGrouping.group(report))
        }
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(theme.font(10, .bold)).tracking(0.6).foregroundStyle(theme.tertiary)
    }

    private func section(_ t: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(t)
            Text(body).font(theme.font(12)).foregroundStyle(theme.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String, extra: String?, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint).accessibilityHidden(true)
            (Text(text).foregroundColor(theme.primary) + Text(extra.map { " · \($0)" } ?? "").foregroundColor(theme.tertiary))
                .font(theme.font(11.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Задачи, сгруппированные по людям: карточка на человека.
struct PeopleView: View {
    var groups: [StenPersonGroup]
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if groups.isEmpty {
            Tile {
                Text("Участники и задачи не выделены").font(theme.font(12.5, .medium)).foregroundStyle(theme.secondary)
            }
        } else {
            VScroll {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top),
                                    GridItem(.flexible(), spacing: 8, alignment: .top)], spacing: 8) {
                    ForEach(groups) { g in PersonCard(group: g) }
                }
            }
        }
    }
}

private struct PersonCard: View {
    var group: StenPersonGroup
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(group.isUnassigned ? AnyShapeStyle(theme.primary.opacity(0.14))
                                  : AnyShapeStyle(LinearGradient(colors: MeetingsStyle.avatar(group.name),
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
                    if group.isUnassigned {
                        Image(systemName: "questionmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.secondary)
                    } else {
                        Text(MeetingsStyle.initials(group.name)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(theme.font(12.5, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                    if let n = group.note { Text(n).font(theme.font(10.5)).foregroundStyle(theme.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if !group.tasks.isEmpty {
                    Text("\(group.tasks.count)").font(theme.font(10.5, .bold)).foregroundStyle(theme.secondary)
                        .padding(.horizontal, 6).frame(height: 17)
                        .background(Capsule().fill(theme.primary.opacity(0.1)))
                        .accessibilityLabel("задач: \(group.tasks.count)")
                }
            }
            if group.tasks.isEmpty && group.decisions.isEmpty {
                Text("задач нет").font(theme.font(11)).foregroundStyle(theme.tertiary)
            }
            ForEach(Array(group.tasks.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).strokeBorder(theme.secondary, lineWidth: 1.2)
                        .frame(width: 9, height: 9).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.text).font(theme.font(11.5)).foregroundStyle(theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let due = t.due {
                            Text("срок: \(due)").font(theme.font(10, .semibold)).foregroundStyle(IslandPalette.warmText(theme))
                        }
                    }
                }
            }
            ForEach(Array(group.decisions.enumerated()), id: \.offset) { _, d in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(IslandPalette.okText(theme)).accessibilityHidden(true)
                    Text(d.text).font(theme.font(11)).foregroundStyle(theme.secondary).lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.controlFillColor))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Компакт

struct MeetingsCompactLeading: View {
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(IslandPalette.err, size: 8)
            Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandPalette.err)
        }
        .accessibilityHidden(true)
    }
}

struct MeetingsCompactTrailing: View {
    var start: Date?
    var body: some View { RecordClock(start: start, size: 13) }
}

struct MeetingsProcessingLeading: View {
    var body: some View {
        Image(systemName: "waveform").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: MeetingsStyle.gradient, startPoint: .leading, endPoint: .trailing))
            .accessibilityHidden(true)
    }
}

struct MeetingsProcessingTrailing: View {
    var percent: Double?
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            Ring(value: (percent ?? 5) / 100, lineWidth: 2.5, tint: theme.primary).frame(width: 14, height: 14)
            if let p = percent { Text("\(Int(p))%").font(theme.font(11.5, .semibold)).monospacedDigit().foregroundStyle(theme.primary) }
        }
    }
}

// MARK: - Настройки

struct MeetingsSettingsView: View {
    @ObservedObject var model: MeetingsModel
    @State private var server = ""
    @State private var name = ""
    @State private var password = ""
    @State private var serverNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Сервер Sten") {
                Text("Адрес сайта протоколов. Туннель может смениться — тогда вставьте новый адрес (можно ссылкой на любую встречу).")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField(StenServer.placeholderAddress, text: $server).onSubmit(saveServer)
                    Button("Сохранить", action: saveServer)
                }
                if let serverNote { Text(serverNote).font(.caption).foregroundStyle(.secondary) }
            }
            card("Вход") {
                switch model.auth {
                case .loggedIn(let n):
                    HStack {
                        Label(n.isEmpty ? "Вы вошли" : "Вы вошли как \(n)", systemImage: "checkmark.seal.fill")
                        Spacer()
                        Button("Выйти") { Task { await model.logout() } }
                    }
                default:
                    Text("Имя и пароль от Sten. Пароль уходит одним запросом и не сохраняется — в Связке ключей остаётся только сессия (служба local.simpleisland.sten).")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Имя", text: $name).frame(maxWidth: 180)
                        SecureField("Пароль", text: $password).frame(maxWidth: 180).onSubmit(login)
                        Button(model.auth == .loggingIn ? "Вхожу…" : "Войти", action: login).disabled(model.auth == .loggingIn)
                    }
                    if let m = model.authMessage { Text(m).font(.caption).foregroundStyle(.orange) }
                }
            }
            card("Доступ") {
                PermissionRow(.microphone, reason: "Записать встречу и отправить звук в Sten")
            }
        }
        .onAppear { server = model.prefs.server }
        .onDisappear { password = "" }
    }

    private func saveServer() {
        serverNote = model.setServer(server) ? "Сервер: \(model.server.display)" : "Непонятный адрес"
        server = model.prefs.server
    }

    private func login() {
        let pw = password
        password = ""
        Task { await model.login(name: name, password: pw) }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
