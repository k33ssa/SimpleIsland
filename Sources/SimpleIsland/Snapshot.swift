import AppKit
import SwiftUI
import IslandCore
import MenuBarModule   // --- menubar ---

/// Режим снимков: `SimpleIsland --snapshot <каталог> [--snapshot-theme <id>] [--snapshot-module <id>] [--themes-dir <каталог>]…`
/// Рендерит IslandRootView через ImageRenderer (×2) поверх полосы «экрана» с меню-баром и вырезом 186×38
/// (как `.stage` в макетах) для каждой темы и состояния → `<тема>-<состояние>.png`, модули → `<тема>-mod-<модуль>-<имя>.png`.
@MainActor
enum SnapshotRunner {
    struct Options {
        var outDir: URL
        var themeId: String?
        var moduleId: String?
        var themeDirs: [URL] = []
        /// Вырез контуром, а не заливкой: видно, что под железом ничего не нарисовано.
        var notchOutline = false
        /// Размер выреза (по умолчанию как в макетах, 186×38; у MacBook Air/Pro 14 в «больше места» — 185×32).
        var notch: CGSize?
    }

    nonisolated static func parse(_ args: [String]) -> Options? {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let out = value("--snapshot") else { return nil }
        var o = Options(outDir: URL(fileURLWithPath: out, isDirectory: true),
                        themeId: value("--snapshot-theme"), moduleId: value("--snapshot-module"))
        for (i, a) in args.enumerated() where a == "--themes-dir" && i + 1 < args.count {
            o.themeDirs.append(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
        o.notchOutline = args.contains("--notch-outline")
        if let n = value("--notch") {
            let parts = n.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { o.notch = CGSize(width: parts[0], height: parts[1]) }
        }
        return o
    }

    /// Состояние ядра: имя файла + как его выставить.
    struct CoreState {
        var name: String
        var floating = false
        /// Лишние вкладки-заглушки (раскладка вкладок на 10 штук).
        var extraTabs = 0
        var apply: @MainActor (AppEnvironment, IslandModel) -> Void
    }

    static let coreStates: [CoreState] = [
        CoreState(name: "idle") { env, _ in
            env.activities.setStatusDot(IslandPalette.ok, priority: 0, for: "agents")
            // Точка важнее (ждёт тебя) — в покое должна победить зелёную.
            env.activities.setStatusDot(IslandPalette.warn, priority: 50, for: "today")
        },
        CoreState(name: "hover-idle") { _, model in model.hovering = true },
        CoreState(name: "compact") { env, _ in env.activities.post(mockMedia()) },
        CoreState(name: "hover") { env, model in
            env.activities.post(mockMedia()); model.hovering = true
        },
        CoreState(name: "drop-target") { env, model in
            env.activities.post(mockMedia())
            env.island.setFileDrag(active: true)
            env.island.setDropTargeted(true)
            model.hovering = true
        },
        // Вторая активность — значком в правом ухе (кольцо загрузки), снаружи острова ничего.
        CoreState(name: "two-activities") { env, _ in
            env.activities.post(mockTimer())
            env.activities.post(mockDownload())
        },
        // Как на скрине пользователя 15.11: агент ждёт, играет музыка — музыка (фон) значком не выходит.
        CoreState(name: "waiting-plus-music") { env, _ in
            env.activities.post(mockMedia())
            env.activities.post(mockWaiting())
        },
        CoreState(name: "hud-volume") { env, _ in env.hud.show(mockVolume(style: nil)) },
        CoreState(name: "hud-segments") { env, _ in
            env.hud.show(HUDEvent(kind: "keyboard", systemImage: "light.max", value: 0.6, style: .segments, segments: 10))
        },
        CoreState(name: "hud-fill") { env, _ in
            env.hud.show(HUDEvent(kind: "battery", systemImage: "bolt.fill", label: "Заряжается", valueText: "78% · 34 мин",
                                  tint: IslandPalette.ok, style: .fill, sideWidth: 132)
                .with { $0.value = 0.78 })
        },
        // Без выреза (капля): заливка линейно по всему острову, во всю форму (16.11).
        CoreState(name: "hud-fill-floating", floating: true) { env, _ in
            env.hud.show(HUDEvent(kind: "battery", systemImage: "bolt.fill", label: "Заряжается", valueText: "63% · 41 мин",
                                  tint: IslandPalette.ok, style: .fill, sideWidth: 132)
                .with { $0.value = 0.63 })
        },
        CoreState(name: "hud-number") { env, _ in env.hud.show(mockVolume(style: .number)) },
        CoreState(name: "notification") { env, _ in
            env.notifications.show(IslandNotification(
                moduleId: "today", title: "Аня", source: "Telegram",
                body: "скинь макеты острова, хочу посмотреть 👀", avatarText: "А",
                actions: [IslandNotificationAction("Ответить")], duration: nil))
        },
        CoreState(name: "expanded") { env, model in
            env.activities.setAmbientGlow(ArtworkView.glowColors(for: .warm), for: "media")
            model.expanded = true
            model.selectedTab = env.enabledTabModules.first?.id
        },
        CoreState(name: "expanded-hud") { env, model in
            env.activities.setAmbientGlow(ArtworkView.glowColors(for: .warm), for: "media")
            model.expanded = true
            model.selectedTab = env.enabledTabModules.first?.id
            env.hud.show(mockVolume(style: nil))
        },
        // Интерактивный свайп (27.11): из компакта на 30 / 60 / 90 % хода и из раскрытого обратно на 50 %.
        CoreState(name: "swipe-30") { env, model in env.activities.post(mockMedia()); model.previewSwipe(0.3) },
        CoreState(name: "swipe-60") { env, model in env.activities.post(mockMedia()); model.previewSwipe(0.6) },
        CoreState(name: "swipe-90") { env, model in env.activities.post(mockMedia()); model.previewSwipe(0.9) },
        CoreState(name: "swipe-back-50") { env, model in
            env.activities.post(mockMedia())
            model.expand(tab: env.enabledTabModules.first?.id)
            model.previewSwipe(0.5)
        },
        CoreState(name: "floating", floating: true) { env, _ in env.activities.post(mockMedia()) },
        // Раскладка вкладок (15.11): 3 — все слева; 7 — слева и справа от выреза; 10 — лишние в «⋯»;
        // без выреза (капля) — то же на узких сторонах. Выбрана последняя — длинное имя («Эквалайзер»).
        CoreState(name: "tabs-3") { env, model in tabs(env, model, count: 3, select: "today") },
        CoreState(name: "tabs-7") { env, model in tabs(env, model, count: 7, select: "equalizer") },
        CoreState(name: "tabs-7-vafa") { env, model in tabs(env, model, count: 7, select: "vafa") },
        CoreState(name: "tabs-10", extraTabs: 3) { env, model in tabs(env, model, count: 10, select: "equalizer") },
        CoreState(name: "tabs-7-floating", floating: true) { env, model in tabs(env, model, count: 7, select: "agents") },
        // Стороны выреза (16.11): часть вкладок — справа от выреза; всё справа — лишние в «⋯»; без выреза — подряд с чертой.
        CoreState(name: "tabs-3-split") { env, model in tabs(env, model, count: 3, select: "today", right: ["shelf"]) },
        CoreState(name: "tabs-7-split") { env, model in
            tabs(env, model, count: 7, select: "equalizer", right: ["vafa", "menubar", "equalizer"])
        },
        CoreState(name: "tabs-7-right") { env, model in
            tabs(env, model, count: 7, select: "media", right: ["media", "today", "shelf", "agents", "vafa", "menubar", "equalizer"])
        },
        CoreState(name: "tabs-7-floating-split", floating: true) { env, model in
            tabs(env, model, count: 7, select: "agents", right: ["vafa", "menubar", "equalizer"])
        },
    ]

    /// Включить первые `count` вкладок (в порядке модулей), `right` — справа от выреза, выбрать `select`, раскрыть.
    static func tabs(_ env: AppEnvironment, _ model: IslandModel, count: Int, select: String, right: Set<String> = []) {
        let order = ["media", "today", "shelf", "agents", "vafa", "menubar", "equalizer"]
        var tabs = env.settings.data.tabs
        for i in tabs.indices {
            let id = tabs[i].id
            let rank = order.firstIndex(of: id) ?? (order.count + (tabs[i].id.hasPrefix("extra") ? Int(id.dropFirst(5)) ?? 0 : 99))
            tabs[i].enabled = rank < count
            tabs[i].side = right.contains(id) ? .right : .left
        }
        env.settings.data.tabs = tabs
        model.expanded = true
        model.selectedTab = select
    }

    static func run(_ o: Options) -> Int32 {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: o.outDir, withIntermediateDirectories: true)
        } catch {
            fputs("SimpleIsland: не создать \(o.outDir.path): \(error)\n", stderr); return 1
        }
        let store = ThemeStore(extraDirectories: o.themeDirs)
        for (file, err) in store.loadErrors { fputs("SimpleIsland: тема \(file) не разобрана: \(err)\n", stderr) }
        var themes = store.themes
        if let id = o.themeId {
            themes = themes.filter { $0.id == id }
            if themes.isEmpty { fputs("SimpleIsland: нет темы «\(id)»\n", stderr); return 2 }
        }

        var count = 0
        for theme in themes {
            store.select(theme.id)
            if o.moduleId == nil || o.moduleId == "core" {
                for s in coreStates {
                    let (env, model) = makeEnv(store: store, theme: theme, floating: s.floating, o: o, extraTabs: s.extraTabs)
                    s.apply(env, model)
                    count += render(model: model, to: o.outDir.appendingPathComponent("\(theme.id)-\(s.name).png"), o: o) ? 1 : 0
                }
            }
            // Точка у выреза в полноэкранном — по виду события.
            if o.moduleId == nil || o.moduleId == "core" {
                for k in AttentionKind.allCases {
                    let url = o.outDir.appendingPathComponent("\(theme.id)-beacon-\(k).png")
                    if let png = FullscreenBeacon.snapshotPNG(kind: k), (try? png.write(to: url)) != nil { count += 1 }
                }
            }
            // --- settings: окно настроек и шаги онбординга — только по `--snapshot-module settings` (окна 1360×860 тяжёлые)
            if o.moduleId == "settings" { count += SettingsSnapshots.render(store: store, theme: theme, o: o) }
            // --- catalog --- окно каталога виджетов — только по `--snapshot-module catalog`
            if o.moduleId == "catalog" { count += CatalogSnapshots.render(store: store, theme: theme, o: o) }
            // --- menubar --- оверлей уборки и карточки подтверждения — отдельные панели, рисуются своей сценой
            if o.moduleId == "menubar" { count += MenuBarSnapshots.render(outDir: o.outDir, theme: theme) }
            for probe in ModuleRegistry.makeModules() where o.moduleId == nil || o.moduleId == probe.id {
                for snap in probe.snapshotStates() {
                    let (env, model) = makeEnv(store: store, theme: theme, floating: false, o: o)
                    guard let module = env.module(id: probe.id), let ctx = env.contexts[probe.id] else { continue }
                    // Состояние готовит свежий экземпляр модуля из env (его же рисует вкладка).
                    let fresh = module.snapshotStates().first { $0.name == snap.name } ?? snap
                    fresh.apply(ctx)
                    switch fresh.presentation {
                    case .expanded: model.expanded = true; model.selectedTab = module.id
                    case .compact, .automatic: break
                    }
                    let url = o.outDir.appendingPathComponent("\(theme.id)-mod-\(module.id)-\(snap.name).png")
                    count += render(model: model, to: url, o: o) ? 1 : 0
                }
            }
        }
        print("SimpleIsland: снимков — \(count), каталог \(o.outDir.path)")
        return count > 0 ? 0 : 3
    }

    private static func makeEnv(store: ThemeStore, theme: Theme, floating: Bool, o: Options,
                                extraTabs: Int = 0) -> (AppEnvironment, IslandModel) {
        var data = SettingsData()
        data.themeId = theme.id
        let extras: [IslandModule] = (0..<extraTabs).map { SnapshotExtraTab(index: $0) }
        let env = AppEnvironment(settings: SimpleIslandSettings(inMemory: data), themes: store,
                                 modules: ModuleRegistry.makeModules() + extras, isSnapshot: true)
        var g: IslandGeometry = floating ? .mockFloating : .mockNotch
        if !floating, let n = o.notch { g.notchWidth = n.width; g.notchHeight = n.height }
        let model = IslandModel(env: env, geometry: g)
        return (env, model)
    }

    private static func render(model: IslandModel, to url: URL, o: Options) -> Bool {
        let m = model.currentMetrics
        let height = max(150, model.geometry.topOffset + m.height + 120)
        let view = SnapshotStage(model: model, notchOutline: o.notchOutline)
            .frame(width: 1000, height: height)
            .environment(\.isSnapshot, true)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fputs("SimpleIsland: не отрисован \(url.lastPathComponent)\n", stderr); return false
        }
        do { try png.write(to: url); return true } catch {
            fputs("SimpleIsland: не записан \(url.path): \(error)\n", stderr); return false
        }
    }

    // MARK: Мок-данные ядра

    static func mockMedia() -> IslandActivity {
        IslandActivity(id: "media.now", moduleId: "media", priority: 0, sideWidth: 56,
                       glowColors: ArtworkView.glowColors(for: .warm)) {
            ArtworkView(cornerRadius: 6).frame(width: 22, height: 22)
        } trailing: {
            Visualizer(bars: 5)
        }
    }

    static func mockTimer() -> IslandActivity {
        IslandActivity(id: "today.timer", moduleId: "today", priority: 50, sideWidth: 77) {
            ThemedLabel(text: "24:12", systemImage: "timer", size: 12.5, tone: .warm)
        } trailing: {
            ThemedLabel(text: "3", systemImage: "apple.terminal", size: 12, tone: .ok)
        }
    }

    static func mockWaiting() -> IslandActivity {
        IslandActivity(id: "agents.waiting", moduleId: "agents", priority: 100, sideWidth: 176) {
            ThemedLabel(text: "apple-music…player", systemImage: "sparkle", size: 12.5, tone: .warm)
        } trailing: {
            ThemedLabel(text: "спрашивает", systemImage: "questionmark.bubble.fill", size: 12.5, tone: .warm)
        }
    }

    static func mockDownload() -> IslandActivity {
        IslandActivity(id: "shelf.download", moduleId: "shelf", priority: 40,
                       bubble: AnyView(Ring(value: 0.68, lineWidth: 3.5, tint: IslandPalette.warn))) {
            Image(systemName: "arrow.down.circle.fill")
        } trailing: {
            Text("68%")
        }
    }

    static func mockVolume(style: HUDBarStyle?) -> HUDEvent {
        HUDEvent(kind: "volume", systemImage: "speaker.wave.2.fill", label: "AirPods Pro", value: 0.62, style: style)
    }
}

/// Подпись статуса с цветом под тему (на светлом острове — тёмные варианты).
private struct ThemedLabel: View {
    enum Tone { case warm, ok }
    var text: String
    var systemImage: String
    var size: CGFloat
    var tone: Tone
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Label { Text(text).monospacedDigit() } icon: { Image(systemName: systemImage) }
            .labelStyle(TightLabel())
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(tone == .warm ? IslandPalette.warmText(theme) : IslandPalette.okText(theme))
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

extension HUDEvent {
    func with(_ f: (inout HUDEvent) -> Void) -> HUDEvent { var c = self; f(&c); return c }
}

/// «Экран» как `.stage` в макетах: градиент, меню-бар, физический вырез поверх острова.
private struct SnapshotStage: View {
    @ObservedObject var model: IslandModel
    var notchOutline = false

    var body: some View {
        let g = model.geometry
        let menuH: CGFloat = g.hasNotch ? g.notchHeight : 24
        ZStack(alignment: .top) {
            Color(hex: "#07070A")
            LinearGradient(colors: [Color(hex: "#2A1550"), Color(hex: "#5B1A4A"), Color(hex: "#8A3A1C")],
                           startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
                .opacity(0.55)
            HStack {
                Text("Finder   Файл   Правка")
                Spacer()
                Text("02:41").monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 16)
            .frame(height: menuH)
            .background(g.hasNotch ? Color.clear : Color.black.opacity(0.18))

            IslandRootView(model: model)

            if g.hasNotch {
                // Физический вырез: поверх всего, как железо.
                let notch = UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                if notchOutline {
                    notch.stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: g.notchWidth, height: g.notchHeight)
                } else {
                    notch.fill(Color.black).frame(width: g.notchWidth, height: g.notchHeight)
                }
            }
        }
    }
}

/// Вкладка-заглушка для снимка «10 вкладок».
@MainActor
private final class SnapshotExtraTab: IslandModule {
    let id: String
    let title: String
    let systemImage: String
    init(index: Int) {
        id = "extra\(index)"
        title = ["Погода", "Заметки", "Таймеры"][index % 3]
        systemImage = ["cloud.sun.fill", "note.text", "timer"][index % 3]
    }
    func start(context: ModuleContext) {}
}
