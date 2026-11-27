import AppKit
import SwiftUI
import IslandCore
import HUDModule

// Первый запуск: приветствие с живым островом → тема → разрешения → агенты → готово.
// Тёмное окно в стиле острова; всё необязательно, «Пропустить» на каждом шаге. Повторно — меню и «О программе».

enum OnboardingStep: Int, CaseIterable {
    case welcome, features, theme, permissions, agents, done
    var name: String {
        switch self {
        case .welcome: return "welcome"
        case .features: return "features"
        case .theme: return "theme"
        case .permissions: return "permissions"
        case .agents: return "agents"
        case .done: return "done"
        }
    }
}

struct OnboardingView: View {
    let env: AppEnvironment
    let permissions: PermissionCenter
    var onFinish: () -> Void
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject var themes: ThemeStore
    @State private var step: OnboardingStep
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @Environment(\.isSnapshot) private var isSnapshot

    /// Горячую клавишу упоминаем, только если она включена и не перехвачена системным сочетанием.
    private var hotKeyUsable: Bool { settings.data.toggleHotKeyEnabled && hotKey.systemConflict == nil }

    init(env: AppEnvironment, step: OnboardingStep = .welcome, permissions: PermissionCenter? = nil,
         onFinish: @escaping () -> Void = {}) {
        self.env = env
        self.permissions = permissions ?? .shared
        self.onFinish = onFinish
        settings = env.settings
        themes = env.themes
        _step = State(initialValue: step)
    }

    var body: some View {
        let theme = settings.data.applying(to: themes.current)
        let p = SettingsPalette(theme: theme, forceDark: true)
        ZStack {
            Color(hex: "#050507")
            RadialGradient(colors: [p.accent.opacity(0.20), .clear], center: UnitPoint(x: 0.5, y: 0),
                           startRadius: 0, endRadius: 420)
            VStack(spacing: 0) {
                if isSnapshot {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: "#FF5F57")); Circle().fill(Color(hex: "#FEBC2E")); Circle().fill(Color(hex: "#28C840"))
                    }
                    .frame(width: 52, height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, -12).padding(.top, -14)
                }
                content(p: p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                bottomBar(p: p)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .environment(\.islandTheme, theme)
        .environment(\.settingsPalette, p)
        .preferredColorScheme(.dark)
    }

    // MARK: Шаги

    @ViewBuilder private func content(p: SettingsPalette) -> some View {
        switch step {
        case .welcome: welcome(p: p)
        case .features: features(p: p)
        case .theme:
            VStack(alignment: .leading, spacing: 18) {
                title("Выбери тему", "Тема меняет материал острова, кромку, свечение и шрифт. Потом — в настройках или в меню ▸ Тема.")
                ThemeGrid(themes: themes.themes, selectedId: themes.current.id, columns: 6, cardHeight: 62,
                          showsSubtitle: false) { t in
                    withAnimation(.easeOut(duration: 0.2)) { settings.data.themeId = t.id }
                }
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 18) {
                title("Разрешения", "Всё необязательно: без разрешения модуль просто молчит. «Разрешить…» открывает нужный раздел Системных настроек.")
                PermissionsList(center: permissions, compact: true)
                replaceHUDRow(p: p)
            }
        case .agents: agents(p: p)
        case .done: done(p: p)
        }
    }

    /// «Заменить системные индикаторы» (модуль HUD): квадрат громкости/яркости посреди экрана — в остров. Включение
    /// без Универсального доступа сразу его запрашивает (`HUDSystemIndicators.set`).
    private func replaceHUDRow(p: SettingsPalette) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemImage: "speaker.wave.2.fill", colors: [Color(hex: "#FF9F0A")], size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Заменить системные индикаторы").font(p.font(13, .semibold)).foregroundStyle(p.ink)
                Text("Громкость, яркость и подсветка — в острове, без квадрата посреди экрана. Нужен Универсальный доступ.")
                    .font(p.font(11.5)).foregroundStyle(p.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { HUDSystemIndicators.isOn(settings) },
                                     set: { HUDSystemIndicators.set($0, settings: settings) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private func title(_ t: String, _ s: String) -> some View {
        SettingsHeader(title: t, subtitle: s)
    }

    /// «Что умеет остров» (27.11): свои функции с коротким описанием. Vafa, эквалайзер и встречи Sten — не здесь
    /// (виджеты из каталога, не основа острова).
    static let featureList: [(icon: String, color: String, title: String, text: String)] = [
        ("music.note", "#FF5A5F", "Медиа",
         "Что играет в любом плеере и браузере: обложка, перемотка, вывод звука и текст песни с подсветкой по словам."),
        ("calendar", "#3B82F6", "Сегодня",
         "Следующая встреча, погода, нагрузка Мака, заряд AirPods и других устройств, буфер обмена, быстрые тумблеры."),
        ("tray.full.fill", "#F59E0B", "Полка",
         "Брось файл на вырез — полежит сутки. Отсюда AirDrop, zip, конвертер, распознавание текста, вырезка фона."),
        ("terminal.fill", "#22C55E", "Агенты",
         "Сессии Claude Code и Codex: кто работает, кто ждёт тебя. Разрешить или ответить — прямо из выреза."),
        ("speaker.wave.2.fill", "#A855F7", "Индикаторы",
         "Громкость, яркость, подсветка, зарядка, наушники, раскладка и Caps Lock — в острове, а не квадратом посреди экрана."),
        ("menubar.rectangle", "#14B8A6", "Значки",
         "Уборка строки меню: лишние значки уходят в остров, и вырез больше не прячет нужные."),
    ]

    private func features(p: SettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Что умеет остров", "Всё живёт в вырезе: наведи — раскроется, уведи — свернётся. Вкладки можно переставлять и выключать в настройках.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Self.featureList, id: \.title) { f in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: f.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: f.color)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(p.font(14, .semibold)).foregroundStyle(p.ink)
                            Text(f.text).font(p.font(12)).foregroundStyle(p.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card.opacity(1.4)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.hair))
                }
            }
        }
    }

    private func welcome(p: SettingsPalette) -> some View {
        VStack(spacing: 22) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#2A1550"), Color(hex: "#5B1A4A"), Color(hex: "#8A3A1C")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.75))
                WelcomeIsland()
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black)
                    .frame(width: 186, height: 38)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.hair))
            VStack(spacing: 8) {
                Text("Привет! Это SimpleIsland").font(p.font(30, .bold)).foregroundStyle(p.ink)
                Text("Вырез твоего Мака теперь живой: музыка, встречи, файлы и агенты — прямо в нём.\nНаведи на него\(hotKeyUsable ? " или нажми \(settings.data.toggleHotKey.displayString)" : "").")
                    .font(p.font(14)).foregroundStyle(p.ink3).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                ForEach([("Медиа", "music.note"), ("Сегодня", "calendar"), ("Полка", "tray.full.fill"),
                         ("Агенты", "terminal.fill"), ("HUD", "speaker.wave.2.fill")], id: \.0) { f in
                    HStack(spacing: 6) {
                        Image(systemName: f.1).font(.system(size: 11, weight: .semibold))
                        Text(f.0).font(p.font(12.5, .semibold))
                    }
                    .foregroundStyle(p.ink2)
                    .padding(.horizontal, 11).frame(height: 30)
                    .background(Capsule().fill(p.card.opacity(1.4)))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func agents(p: SettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Подключить агентов",
                  "Остров покажет сессии Claude Code и Codex: кто работает, кто ждёт разрешения — и даст ответить прямо из выреза.")
            AgentsTeaser()
            // Только короткая карточка: весь раздел настроек агентов (`settingsView()`) в окно 820×600 не влезает
            // и выталкивает заголовок и нижнюю панель (ревью слияния 14.11). Подключение — в разделе «Агенты».
            SettingsCard {
                HStack(spacing: 14) {
                    SettingsIconTile(systemImage: "terminal.fill", colors: [Color(hex: "#1F2937"), Color(hex: "#374151")], size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Хуки ставятся одной кнопкой").font(p.font(14, .semibold)).foregroundStyle(p.ink)
                        Text("Установщик живёт в настройках модуля «Агенты»: он покажет, что добавит в настройки Claude Code и Codex, и так же уберёт.")
                            .font(p.font(12.5)).foregroundStyle(p.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                SettingsButton(title: "Открыть раздел «Агенты»", systemImage: "arrow.up.forward.app", style: .accent, height: 32) {
                    SettingsWindows.shared.showSettings(section: .module("agents"))
                }
                Text("можно позже").font(p.font(12)).foregroundStyle(p.ink4)
            }
        }
    }

    private func done(p: SettingsPalette) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(p.accent.opacity(0.16)).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 40, weight: .bold)).foregroundStyle(p.accent)
            }
            .padding(.top, 10)
            VStack(spacing: 8) {
                Text("Готово").font(p.font(30, .bold)).foregroundStyle(p.ink)
                Text("Тема «\(themes.current.name)». Раскрыть остров — наведение, клик, свайп вниз\(hotKeyUsable ? " или \(settings.data.toggleHotKey.displayString)" : "").\nНастройки — в строке меню ▸ Настройки… или кнопкой в раскрытом острове.\(hotKey.systemConflict != nil && settings.data.toggleHotKeyEnabled ? "\n\(settings.data.toggleHotKey.displayString) занято системой — другое сочетание: Настройки ▸ Жесты и клавиши." : "")")
                    .font(p.font(14)).foregroundStyle(p.ink3).multilineTextAlignment(.center)
            }
            LaunchAtLoginCard().frame(maxWidth: 460)
            SettingsButton(title: "Открыть настройки", systemImage: "slider.horizontal.3", height: 32) {
                SettingsWindows.shared.showSettings(section: .layout)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Низ

    private func bottomBar(p: SettingsPalette) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule().fill(s == step ? p.accent : p.ink.opacity(0.18))
                        .frame(width: s == step ? 20 : 7, height: 7)
                }
            }
            Spacer()
            if step != .done {
                SettingsButton(title: "Пропустить", style: .quiet, height: 32) { onFinish() }
            }
            if step != .welcome {
                SettingsButton(title: "Назад", height: 32) { go(-1) }
            }
            SettingsButton(title: step == .done ? "Начать" : (step == .welcome ? "Поехали" : "Далее"),
                           systemImage: step == .done ? nil : "arrow.right", style: .accent, height: 32) {
                if step == .done { onFinish() } else { go(1) }
            }
        }
        .padding(.top, 14)
    }

    private func go(_ d: Int) {
        guard let s = OnboardingStep(rawValue: step.rawValue + d) else { return }
        withAnimation(.easeOut(duration: 0.25)) { step = s }
        if s == .permissions { permissions.refresh() }
    }
}

/// Остров приветствия: покой → компакт с музыкой → раскрытый. В снимке — статичный раскрытый.
/// Не PhaseAnimator: его задержки между фазами держат CVDisplayLink включённым всё время, и окно онбординга
/// грело процессор на 15–17 % (ревью слияния 14.11). Здесь между фазами — сон задачи (кадров нет), круги —
/// только пока окно ключевое и не больше `maxCycles`, потом остров стоит раскрытым.
private struct WelcomeIsland: View {
    enum Phase: CaseIterable { case idle, compact, expanded }
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandTheme) private var theme
    @Environment(\.controlActiveState) private var activeState
    @State private var phase: Phase = .expanded
    @State private var cycles = 0
    private static let maxCycles = 2

    var body: some View {
        if isSnapshot {
            island(.expanded)
        } else {
            island(phase)
                .task(id: activeState == .key) {
                    guard activeState == .key else { return }
                    while cycles < Self.maxCycles, !Task.isCancelled {
                        for (next, hold) in [(Phase.idle, 1.4), (.compact, 0.6), (.expanded, 1.4)] {
                            try? await Task.sleep(for: .seconds(hold))
                            if Task.isCancelled { return }
                            withAnimation(theme.springAnimation) { phase = next }
                        }
                        cycles += 1
                    }
                }
        }
    }

    private func metrics(_ p: Phase) -> IslandMetrics {
        switch p {
        case .idle: return IslandMetrics(width: 186, height: 38, cornerRadius: 10, earRadius: 0)
        case .compact: return IslandMetrics(width: 186 + 112, height: 38, cornerRadius: CGFloat(theme.shape.compactCornerRadius),
                                            earRadius: min(CGFloat(theme.shape.earRadius), 9))
        case .expanded: return IslandMetrics(width: 470, height: 168, cornerRadius: CGFloat(theme.shape.cornerRadius) * 0.85,
                                             earRadius: CGFloat(theme.shape.earRadius) * 0.85)
        }
    }

    private func island(_ p: Phase) -> some View {
        let m = metrics(p)
        return ZStack(alignment: .top) {
            if p != .idle, theme.glow.source != .none {
                IslandGlow(colors: theme.glow.source == .fixed ? theme.glowColors : ArtworkView.glowColors(for: .warm),
                           metrics: m, opacity: theme.glow.opacity * (p == .expanded ? 1 : 0.4), radius: theme.glow.radius)
            }
            IslandBackground(metrics: m, coreHeight: 38, showEdge: p != .idle, showRim: p != .idle)
                .frame(width: m.outerWidth, height: m.height)
            ZStack(alignment: .top) {
                if p == .compact {
                    EarsLayout(notchGap: 186, sideWidth: 56, inset: 10) {
                        ArtworkView(cornerRadius: 6).frame(width: 22, height: 22)
                    } trailing: {
                        Visualizer(bars: 5)
                    }
                    .frame(height: 38)
                    .transition(.opacity)
                }
                if p == .expanded {
                    HStack(spacing: 14) {
                        ArtworkView(cornerRadius: 14).frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Полуночный трамвай").font(theme.font(17, .bold)).foregroundStyle(theme.primary)
                            Text("Северный ветер").font(theme.font(13, .medium)).foregroundStyle(theme.secondary)
                            ProgressTrack(value: 0.46, height: 4, tint: AnyShapeStyle(theme.accentColor))
                                .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 54)
                    .transition(.opacity)
                }
            }
            .frame(width: m.width, height: m.height, alignment: .top)
            .clipShape(IslandShape(m, theme: theme))
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Как выглядит агент в острове: компакт «claude ждёт» (заглушка, как в превью настроек).
private struct AgentsTeaser: View {
    @Environment(\.islandTheme) private var theme
    var body: some View {
        let m = IslandMetrics(width: 186 + 148, height: 38, cornerRadius: CGFloat(theme.shape.compactCornerRadius),
                              earRadius: min(CGFloat(theme.shape.earRadius), 9))
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1B2A4A"), Color(hex: "#3A1D4F")], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.8)
            IslandGlow(colors: [IslandPalette.warn], metrics: m, opacity: 0.35, radius: 40)
            IslandBackground(metrics: m, coreHeight: 38).frame(width: m.outerWidth, height: m.height)
            EarsLayout(notchGap: 186, sideWidth: 74, inset: 12) {
                PreviewEar(id: "agents", systemImage: "terminal.fill", leading: true)
            } trailing: {
                PreviewEar(id: "agents", systemImage: "terminal.fill", leading: false)
            }
            .frame(width: m.width, height: 38)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 186, height: 38)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
