import AppKit
import SwiftUI
import IslandCore

/// Разделы окна настроек — как сайдбар в макете 08-editor.
enum SettingsSection: Hashable {
    case layout, themes, gestures, visibility
    case module(String)
    case integrations, displays, about
}

/// Что открыто в окне настроек. Одна на процесс: онбординг и меню открывают нужный раздел.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .layout
    /// Выбранный слот редактора раскладки: модуль → инспектор показывает его настройки, превью — его вкладку.
    @Published var selectedModule: String?
    /// Превью острова: компакт (уши) вместо раскрытого.
    @Published var previewCompact = false
    init(section: SettingsSection = .layout) { self.section = section }
}

/// Окно настроек целиком: сайдбар | раздел | инспектор (только в «Раскладке»).
struct SettingsRootView: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject var themes: ThemeStore
    let permissions: PermissionCenter

    init(env: AppEnvironment, nav: SettingsNavigation, permissions: PermissionCenter? = nil) {
        self.env = env
        self.nav = nav
        self.permissions = permissions ?? .shared
        settings = env.settings
        themes = env.themes
    }

    var body: some View {
        let theme = settings.data.applying(to: themes.current)
        let p = SettingsPalette(theme: theme)
        HStack(spacing: 0) {
            SettingsSidebar(env: env, nav: nav)
                .frame(width: 230)
                .background(p.ink.opacity(0.03))
            Rectangle().fill(p.hair).frame(width: 1)
            SettingsScroll {
                VStack(alignment: .leading, spacing: 18) { detail }
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if nav.section == .layout {
                Rectangle().fill(p.hair).frame(width: 1)
                SettingsInspector(env: env, nav: nav)
                    .frame(width: 330)
                    .background(p.ink.opacity(0.015))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.window)
        .environment(\.islandTheme, theme)
        .environment(\.settingsPalette, p)
        .tint(p.accent)
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .layout: LayoutEditorSection(env: env, nav: nav)
        case .themes: ThemesSection(settings: settings, themes: themes)
        case .gestures: GesturesSection(settings: settings)
        case .visibility: VisibilitySection(settings: settings)
        case .module(let id): ModuleSection(env: env, moduleId: id)
        case .integrations: IntegrationsSection(permissions: permissions)
        case .displays: DisplaysSection(settings: settings)
        case .about: AboutSection(settings: settings)
        }
    }
}

// MARK: - Сайдбар

private struct SettingsSidebar: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isSnapshot {
                // Светофор окна (в живом окне — настоящий, системный).
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#FF5F57")); Circle().fill(Color(hex: "#FEBC2E")); Circle().fill(Color(hex: "#28C840"))
                }
                .frame(width: 52, height: 12)
                .padding(.leading, 8).padding(.top, 4).padding(.bottom, 22)
            } else {
                Color.clear.frame(height: 38)
            }
            item(.layout, "Раскладка", "square.stack.3d.up.fill", [Color(hex: "#FFB36E"), Color(hex: "#FF3D7F")])
            item(.themes, "Темы", "paintpalette.fill", [Color(hex: "#7B2CFF")])
            item(.gestures, "Жесты и клавиши", "hand.raised.fill", [Color(hex: "#2563EB")])
            item(.visibility, "Когда показывать", "eye.fill", [Color(hex: "#0F9D58")])
            sectionTitle("Модули")
            ForEach(env.modules, id: \.id) { m in
                item(.module(m.id), m.title, m.systemImage, SettingsModuleStyle.color(m.id))
            }
            sectionTitle("Ещё")
            item(.integrations, "Интеграции", "globe", [Color(hex: "#3A3A40")])
            item(.displays, "Мониторы", "display", [Color(hex: "#3A3A40")])
            item(.about, "О программе", "info.circle.fill", [Color(hex: "#3A3A40")])
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(p.font(11, .bold)).tracking(0.7)
            .foregroundStyle(p.ink4)
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
    }

    private func item(_ s: SettingsSection, _ title: String, _ icon: String, _ colors: [Color]) -> some View {
        let on = nav.section == s
        return HStack(spacing: 10) {
            SettingsIconTile(systemImage: icon, colors: colors)
            Text(title).font(p.font(13.5, .medium)).lineLimit(1)
                .foregroundStyle(on ? p.ink : p.ink2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? p.accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { nav.section = s }
    }
}

// MARK: - Раздел модуля

private struct ModuleSection: View {
    let env: AppEnvironment
    let moduleId: String
    @Environment(\.settingsPalette) private var p
    var body: some View {
        let m = env.module(id: moduleId)
        let note = SettingsModuleStyle.note(moduleId)
        SettingsHeader(title: m?.title ?? moduleId,
                       subtitle: note.isEmpty ? "Настройки модуля." : "Настройки модуля · \(note).")
        if let v = m?.settingsView() {
            SettingsCard { v }
        } else {
            SettingsCard {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: m?.systemImage ?? "square.dashed",
                                     colors: SettingsModuleStyle.color(moduleId), size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Пока нечего настраивать").font(p.font(13.5, .semibold)).foregroundStyle(p.ink)
                        Text(moduleId == "agents"
                             ? "Здесь появится установщик хуков Claude Code и Codex: подключить, проверить, отключить."
                             : "Модуль ещё в разработке — его настройки появятся здесь.")
                            .font(p.font(12)).foregroundStyle(p.ink3)
                    }
                }
            }
        }
    }
}

// MARK: - Жесты и клавиши

private struct GesturesSection: View {
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @Environment(\.settingsPalette) private var p

    var body: some View {
        SettingsHeader(title: "Жесты и клавиши",
                       subtitle: "Наведение, клик, свайп двумя пальцами вниз или горячая клавиша — раскрыть; вверх или увести курсор — свернуть.")
        SettingsCard(title: "Горячая клавиша") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Раскрыть / свернуть остров").font(p.font(13, .semibold)).foregroundStyle(p.ink)
                    Text("Работает в любом приложении. Универсальный доступ не нужен.")
                        .font(p.font(11.5)).foregroundStyle(p.ink3)
                }
                Spacer()
                HotKeyRecorder(settings: settings)
                SettingsToggle(isOn: $settings.data.toggleHotKeyEnabled, scale: 0.85)
            }
            if settings.data.toggleHotKeyEnabled && hotKey.lastStatus != 0 {
                Text(hotKey.lastStatus == -9878 ? "Сочетание занято другим приложением — выбери другое."
                                                 : "Не удалось зарегистрировать (код \(hotKey.lastStatus)).")
                    .font(p.font(11.5, .medium)).foregroundStyle(SettingsColors.err(p))
            } else if settings.data.toggleHotKeyEnabled, let conflict = hotKey.systemConflict {
                // Carbon регистрирует такое сочетание без ошибки, но нажатие забирает система.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(settings.data.toggleHotKey.displayString) занято системой: \(conflict). Нажатие сработает там, а не в острове — запиши другое сочетание или отключи системное в «Клавиатура → Сочетания клавиш».")
                        .font(p.font(11.5, .medium)).foregroundStyle(SettingsColors.warn(p))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SettingsButton(title: "Сочетания клавиш…", style: .quiet, height: 24) { GlobalHotKey.openKeyboardShortcuts() }
                }
            }
            if settings.data.toggleHotKey != .defaultToggle {
                SettingsButton(title: "Вернуть ⌃⌥Space", systemImage: "arrow.uturn.backward", style: .quiet, height: 24) {
                    settings.data.toggleHotKey = .defaultToggle
                }
            }
        }
        SettingsCard(title: "Трекпад и мышь") {
            SettingsToggleRow(title: "Свайп двумя пальцами по острову", note: "вниз — раскрыть, вверх — свернуть",
                              isOn: $settings.data.swipeGestures)
            SettingsToggleRow(title: "Колесо мыши над островом", note: "щелчок вниз — раскрыть, вверх — свернуть",
                              isOn: $settings.data.wheelGestures)
            SettingsToggleRow(title: "Клик мимо острова только закрывает его",
                              note: "первый клик вне раскрытого острова сворачивает его и не уходит в окно под ним",
                              isOn: $settings.data.clickAwayOnlyCollapses)
            SettingsSlider(title: "Задержка наведения", value: $settings.data.hoverDelay, range: 0...1, step: 0.01,  // как в инспекторе
                           format: { "\(Int(($0 * 1000).rounded())) мс" })
            SettingsSlider(title: "Задержка сворачивания", value: $settings.data.collapseDelay, range: 0...2, step: 0.05,
                           format: { "\(Int(($0 * 1000).rounded())) мс" })
        }
        SettingsCard(title: "HUD") {
            SettingsSegmented(options: HUDBarStyle.allCases.map { ($0, $0.title) }, selection: $settings.data.hudStyle)
            SettingsSlider(title: "Сколько держится вспышка", value: $settings.data.hudDuration, range: 0.6...3, step: 0.1,
                           format: { String(format: "%.1f с", $0) })
        }
        SettingsLabel("Шпаргалка")
        GestureTiles(settings: settings, columns: 4)
    }
}

/// Плитки жестов (`.gest`): что делает каждый жест, по текущим настройкам.
struct GestureTiles: View {
    @ObservedObject var settings: SimpleIslandSettings
    var columns = 2
    /// Сколько плиток показать (инспектор — 4 главных).
    var limit = Int.max
    @Environment(\.settingsPalette) private var p

    var body: some View {
        let d = settings.data
        var items: [(String, String)] = [("Наведение", "набухает, подсказка"), ("Клик", "раскрыть на вкладке")]
        if d.swipeGestures { items.append(("Свайп ↓ / ↑", "раскрыть / свернуть")) }
        if d.wheelGestures { items.append(("Колесо мыши", "раскрыть / свернуть")) }
        if d.toggleHotKeyEnabled { items.append((d.toggleHotKey.displayString, "раскрыть / свернуть")) }
        if d.clickAwayOnlyCollapses { items.append(("Клик мимо", "только свернуть")) }
        items.append(("Клик по значку в ухе", "поднять вторую активность"))
        if items.count > limit {
            // В инспекторе — главное: свайп/колесо и горячая клавиша важнее наведения и клика.
            items = Array(items.dropFirst(2).prefix(limit))
        }
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rows[r][i].0).font(p.font(11.5, .semibold)).foregroundStyle(p.ink)
                            Text(rows[r][i].1).font(p.font(11)).foregroundStyle(p.ink3)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)   // моноширинные темы (pixel) в 2 колонки инспектора
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.card))
                    }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

/// Запись горячей клавиши: щёлкни и нажми сочетание (с ⌘, ⌃ или ⌥). Esc — отмена.
struct HotKeyRecorder: View {
    @ObservedObject var settings: SimpleIslandSettings
    @State private var recording = false
    @State private var monitor: Any?
    @Environment(\.settingsPalette) private var p

    var body: some View {
        Text(recording ? "Нажми сочетание…" : settings.data.toggleHotKey.displayString)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(recording ? p.accent : p.ink)
            .padding(.horizontal, 12)
            .frame(minWidth: 120, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.card.opacity(1.4)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(recording ? p.accent : p.hair, lineWidth: recording ? 1.5 : 1))
            .opacity(settings.data.toggleHotKeyEnabled || recording ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { recording ? stop() : start() }
            .help("Щёлкни и нажми новое сочетание; Esc — отмена")
            .onDisappear { stop() }
    }

    private func start() {
        recording = true
        GlobalHotKey.shared.unregister() // чтобы текущее сочетание не сработало во время записи
        // Пока идёт запись, все нажатия — наши (не уходят в окно).
        monitor = GlobalHotKey.recordingMonitor { code, recorded in
            MainActor.assumeIsolated {
                if code == 53 { stop(); return } // Esc
                guard let recorded else { NSSound.beep(); return }
                settings.data.toggleHotKey = recorded
                settings.data.toggleHotKeyEnabled = true
                stop()
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            SettingsWindows.shared.applyHotKey()
        }
    }
}

// MARK: - Когда показывать

private struct VisibilitySection: View {
    @ObservedObject var settings: SimpleIslandSettings
    var body: some View {
        SettingsHeader(title: "Когда показывать", subtitle: "Правила, когда остров уходит с глаз, и запуск вместе с Маком.")
        SettingsCard(title: "Правила") {
            SettingsToggleRow(title: "Прятать в полноэкранных приложениях, видео и играх",
                              note: "вместе с островом не видны вспышки громкости и уведомления; проверяется при смене стола, приложения или экрана, без опроса",
                              isOn: $settings.data.hideInFullscreen)
            SettingsToggleRow(title: "В полноэкранном показывать вопросы, требующие ответа",
                              note: "например, разрешение для агента — остров появится на время карточки",
                              isOn: $settings.data.showCriticalInFullscreen)
                .disabled(!settings.data.hideInFullscreen)
            SettingsToggleRow(title: "В полноэкранном показывать точку у выреза",
                              note: "когда есть событие: оранжевая — агент спрашивает, красная — ошибка или Vafa, синяя — важное уведомление, зелёная — агент закончил; клик — показать остров",
                              isOn: $settings.data.fullscreenDot)
                .disabled(!settings.data.hideInFullscreen)
            SettingsToggleRow(title: "Прятать при показе экрана",
                              note: "окно исключается из записи; на macOS 15 часть программ это не учитывает",
                              isOn: $settings.data.hideWhileScreenSharing)
            SettingsToggleRow(title: "Упрощать анимации на батарее",
                              note: "без бегущей рамки и эквалайзера, как при «Уменьшить движение»",
                              isOn: $settings.data.reduceMotionOnBattery)
            SettingsToggleRow(title: "Пауза острова", note: "остров скрыт, модули не мешают",
                              isOn: $settings.data.paused)
        }
        LaunchAtLoginCard()
    }
}

/// «Запускать при входе» — SMAppService.mainApp.
struct LaunchAtLoginCard: View {
    @ObservedObject private var login = LoginItem.shared
    @Environment(\.settingsPalette) private var p
    var body: some View {
        SettingsCard(title: "Запуск") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запускать при входе").font(p.font(12.5, .medium)).foregroundStyle(p.ink2)
                    Text(login.lastError ?? login.statusText).font(p.font(11))
                        .foregroundStyle(login.lastError == nil ? p.ink4 : SettingsColors.err(p))
                }
                Spacer()
                SettingsToggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) }), scale: 0.85)
            }
            if login.status == .requiresApproval {
                SettingsButton(title: "Открыть «Объекты входа»…", systemImage: "arrow.up.forward.app", height: 26) {
                    login.openLoginItemsSettings()
                }
            }
        }
    }
}

// MARK: - Интеграции и разрешения

private struct IntegrationsSection: View {
    let permissions: PermissionCenter
    @Environment(\.settingsPalette) private var p
    var body: some View {
        SettingsHeader(title: "Интеграции",
                       subtitle: "Разрешения macOS для модулей. Всё необязательно: без разрешения модуль просто молчит.")
        SettingsCard(title: "Разрешения") { PermissionsList(center: permissions) }
        SettingsCard(title: "Скоро") {
            HStack(spacing: 8) {
                ForEach([("Telegram", "paperplane"), ("CI / GitHub", "arrow.triangle.branch"),
                         ("Свой скрипт…", "terminal"), ("Shortcuts…", "plus")], id: \.0) { t in
                    HStack(spacing: 7) {
                        Image(systemName: t.1).font(.system(size: 11, weight: .semibold))
                        Text(t.0).font(p.font(12.5, .semibold))
                    }
                    .foregroundStyle(p.ink3)
                    .padding(.horizontal, 11).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(p.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
        }
    }
}

/// Список разрешений: иконка, зачем, статус, «Разрешить…» (системный запрос, если он возможен, иначе раздел
/// Системных настроек — см. `PermissionCenter.plan`).
struct PermissionsList: View {
    @ObservedObject var center: PermissionCenter
    var compact = false
    @Environment(\.settingsPalette) private var p

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            ForEach(PermissionKind.allCases, id: \.self) { k in
                row(k)
                if !compact && k != .camera { Rectangle().fill(p.hair).frame(height: 1) }
            }
            if let hint = center.hint {
                Text(hint).font(p.font(11.5, .medium)).foregroundStyle(SettingsColors.warn(p))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ k: PermissionKind) -> some View {
        let s = center.state(k)
        return HStack(spacing: 12) {
                    SettingsIconTile(systemImage: k.systemImage, colors: [k.tileColor], size: compact ? 30 : 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.title).font(p.font(13, .semibold)).foregroundStyle(p.ink)
                        Text(k.purpose).font(p.font(11.5)).foregroundStyle(p.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    SettingsStatusChip(text: s.text, color: color(s))
                    if s != .granted {
                        SettingsButton(title: "Разрешить…", height: 26) { center.request(k) }
                    } else {
                        Color.clear.frame(width: 104, height: 26)
                    }
                }
                .padding(compact ? 10 : 0)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(compact ? p.card : .clear))
    }

    private func color(_ s: PermissionState) -> Color {
        switch s {
        case .granted: return SettingsColors.ok(p)
        case .denied: return SettingsColors.err(p)
        case .notDetermined: return SettingsColors.warn(p)
        case .unknown: return p.ink3
        }
    }
}

// MARK: - Мониторы

private struct DisplaysSection: View {
    @ObservedObject var settings: SimpleIslandSettings
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        SettingsHeader(title: "Мониторы", subtitle: "Без выреза остров становится плавающей каплей по центру сверху.")
        SettingsCard(title: "Где показывать") {
            SettingsToggleRow(title: "Каплей на экранах без выреза", isOn: $settings.data.floatingOnNotchlessScreens)
            SettingsToggleRow(title: "Показывать на всех мониторах", note: "иначе — только на экране с вырезом",
                              isOn: $settings.data.allScreens)
        }
        SettingsCard(title: "Подключены") {
            ForEach(screens, id: \.0) { s in
                HStack(spacing: 10) {
                    Image(systemName: s.2 ? "macbook" : "display").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(p.ink2).frame(width: 24)
                    Text(s.0).font(p.font(13, .medium)).foregroundStyle(p.ink)
                    Spacer()
                    Text(s.1).font(p.font(11.5)).foregroundStyle(p.ink3)
                }
            }
        }
    }

    private var screens: [(String, String, Bool)] {
        if isSnapshot { return [("Встроенный дисплей Retina", "вырез 185 × 32 pt · остров", true),
                                ("Внешний 27″", "без выреза · капля", false)] }
        return NSScreen.screens.map { s in
            let notch = s.safeAreaInsets.top > 0
            let role = notch ? "вырез · остров" : (settings.data.floatingOnNotchlessScreens ? "без выреза · капля" : "без выреза · скрыт")
            return (s.localizedName, "\(Int(s.frame.width))×\(Int(s.frame.height)) · \(role)", notch)
        }
    }
}

// MARK: - О программе

private struct AboutSection: View {
    @ObservedObject var settings: SimpleIslandSettings
    @Environment(\.settingsPalette) private var p
    @Environment(\.islandTheme) private var theme

    var body: some View {
        SettingsHeader(title: "О программе", subtitle: "Свой Dynamic Island для Mac.")
        SettingsCard {
            HStack(spacing: 16) {
                let m = IslandMetrics(width: 96, height: 34, cornerRadius: 14, earRadius: 9)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: "#2A1550"), Color(hex: "#8A3A1C")],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    IslandBackground(metrics: m, coreHeight: 22).frame(width: m.outerWidth, height: m.height)
                }
                .frame(width: 140, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("SimpleIsland").font(p.font(18, .bold)).foregroundStyle(p.ink)
                    Text("Версия \(version) · тема «\(theme.name)»").font(p.font(12)).foregroundStyle(p.ink3)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                SettingsButton(title: "Открыть онбординг", systemImage: "sparkles", style: .accent) {
                    SettingsWindows.shared.showOnboarding()
                }
                SettingsButton(title: "Папка настроек", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: SimpleIslandPaths.appSupport, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SimpleIslandPaths.appSupport)
                }
            }
        }
        LaunchAtLoginCard()
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}
