import AppKit
import Combine
import SwiftUI
import IslandCore

// --- catalog --- Окно каталога виджетов: безрамочная панель «стекло острова» под вырезом. Открывается кнопкой «+»
// в раскрытом острове, кнопкой «Каталог виджетов…» в настройках → «Раскладка» и из модулей
// (`context.openWidgetCatalog()` → уведомление `.simpleIslandOpenWidgetCatalog`). Esc или × — закрыть.
// Содержимое создаётся на каждое открытие и освобождается при закрытии (как окно настроек).

/// Панель без рамки, но с клавиатурой (поиск, Esc).
private final class CatalogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class WidgetCatalogWindow: NSObject, NSWindowDelegate {
    static let shared = WidgetCatalogWindow()

    private var env: AppEnvironment?
    private var window: NSPanel?
    private var state: WidgetCatalogState?
    private var observer: NSObjectProtocol?
    private var vafaSub: AnyCancellable?
    /// Поля вокруг «листа» под тень.
    static let margin: CGFloat = 60

    /// AppDelegate зовёт при запуске: слушать просьбы модулей открыть каталог.
    func start(env: AppEnvironment) {
        self.env = env
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .simpleIslandOpenWidgetCatalog, object: nil,
                                                          queue: .main) { [weak self] note in
            let focus = note.object as? String
            MainActor.assumeIsolated { self?.show(focus: focus) }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(env: AppEnvironment? = nil, focus: String? = nil) {
        if let env { self.env = env }
        guard let env = self.env else { return }
        let st = state ?? WidgetCatalogState(env: env)
        state = st
        // Уже открыто и просят без focus («+» ещё раз) — не сбрасывать то, что человек ищет.
        if !isVisible || focus != nil { st.prepareForShow(focus: focus) }
        st.refresh()
        st.resumeWatchingIfNeeded()

        let w = window ?? makeWindow()
        window = w
        if w.contentView == nil || !(w.contentView is NSHostingView<CatalogRoot>) {
            let host = NSHostingView(rootView: CatalogRoot(themes: env.themes, settings: env.settings, state: st,
                                                           onClose: { [weak self] in self?.close() }))
            // Окно не подгоняется под содержимое на лету (иначе «Мои приложения» → «Все» растягивало бы окно
            // вверх, под остров): размер задаёт place() по «Все».
            host.sizingOptions = []
            w.contentView = host
        }
        // Карточка Vafa сменила вид (установка → «Установлена», ошибка) — пересчитать высоту, верх на месте.
        vafaSub = st.$vafa.combineLatest(st.$installNote).dropFirst().removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resize() } }
        place(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    /// Высота окна — по виду «Все» без поиска (самый длинный) при текущем состоянии карточки Vafa: отдельный
    /// NSHostingView на копии состояния, живое окно не дёргается.
    private func fullSize(env: AppEnvironment, state st: WidgetCatalogState) -> NSSize {
        let probe = WidgetCatalogState(env: env)
        probe.mockVafa(st.vafa)
        probe.installNote = st.installNote
        let host = NSHostingView(rootView: CatalogRoot(themes: env.themes, settings: env.settings, state: probe, onClose: {}))
        return host.fittingSize
    }

    /// Пересчитать высоту открытого окна, верхний край на месте.
    private func resize() {
        guard let w = window, w.isVisible, let env, let st = state else { return }
        let size = fullSize(env: env, state: st)
        let top = w.frame.maxY
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
        let height = min(size.height, vf.height)
        var y = top - height
        if y < vf.minY { y = vf.minY }
        w.setFrame(NSRect(x: w.frame.minX, y: y, width: w.frame.width, height: height), display: true)
    }

    private func makeWindow() -> NSPanel {
        let w = CatalogPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false                // тень рисует SwiftUI (у безрамочного окна системная не следит за формой)
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.level = .normal
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.title = "Каталог виджетов"
        w.delegate = self
        return w
    }

    /// Под вырезом по центру экрана под мышью, высота — по содержимому «Все» (не по текущему фильтру).
    private func place(_ w: NSWindow) {
        guard let env, let st = state else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
        guard let screen else { return }
        let size = fullSize(env: env, state: st)
        let vf = screen.visibleFrame
        let width = min(size.width, vf.width)
        let height = min(size.height, vf.height)
        // Как в макете: верх листа ~200 pt под краем экрана (остров виден над ним), но целиком на экране.
        let top = min(vf.maxY, screen.frame.maxY - 180 + Self.margin)
        var y = top - height
        if y < vf.minY { y = vf.minY }
        let x = vf.midX - width / 2
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Вернулись из Терминала — проверить, встала ли Vafa (проверка при активации окна, без опроса).
        state?.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        state?.stopWatching()
        vafaSub = nil
        // Содержимое — освободить; состояние («идёт установка») остаётся до следующего открытия,
        // поиск и категория сбрасываются при открытии (prepareForShow).
        DispatchQueue.main.async { MainActor.assumeIsolated { if self.window?.isVisible == false { self.window?.contentView = nil } } }
    }
}

/// Корень окна: палитра и тема из текущей темы острова (меняется вживую).
struct CatalogRoot: View {
    @ObservedObject var themes: ThemeStore
    @ObservedObject var settings: SimpleIslandSettings
    let state: WidgetCatalogState
    var onClose: () -> Void

    var body: some View {
        let theme = settings.data.applying(to: themes.current)
        let p = SettingsPalette(theme: theme)
        WidgetCatalogView(state: state, onClose: onClose)
            .shadow(color: .black.opacity(p.light ? 0.25 : 0.6), radius: 40, y: 24)
            .padding(WidgetCatalogWindow.margin)
            .fixedSize(horizontal: false, vertical: true)
            // Окно — по высоте «Все»; при поиске лист короче и держится верхом, а не съезжает в центр.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.settingsPalette, p)
            .environment(\.islandTheme, theme)
            .environment(\.colorScheme, p.light ? .light : .dark)
    }
}

// MARK: - Снимки: `--snapshot <к> --snapshot-module catalog`

@MainActor
enum CatalogSnapshots {
    struct Shot {
        var name: String
        var prepare: @MainActor (WidgetCatalogState) -> Void
    }

    static let shots: [Shot] = [
        Shot(name: "all") { s in s.mockVafa(.canBrew(brew: "/opt/homebrew/bin/brew")) },
        Shot(name: "vafa-installed") { s in s.mockVafa(.installed) },
        Shot(name: "vafa-on-island") { s in s.mockVafa(.installed); s.addVafaWidget(); s.category = .mine },
        Shot(name: "vafa-installing") { s in s.mockVafa(.installing); s.category = .mine },
        Shot(name: "vafa-install-error") { s in
            s.mockVafa(.canBrew(brew: "/opt/homebrew/bin/brew")); s.category = .mine
            s.installNote = "Не открылся Терминал (нет доступа). Выполните команду ниже вручную."
        },
        Shot(name: "vafa-focus") { s in s.mockVafa(.installed); s.prepareForShow(focus: "vafa") },
        Shot(name: "vafa-download") { s in s.mockVafa(.download); s.category = .mine },
        Shot(name: "search") { s in s.mockVafa(.canBrew(brew: "/opt/homebrew/bin/brew")); s.query = "погода" },
        Shot(name: "work") { s in
            s.mockVafa(.canBrew(brew: "/opt/homebrew/bin/brew")); s.category = .work; s.setOnIsland("shelf", false)
        },
    ]

    /// `<тема>-catalog-<имя>.png`. Возвращает число снимков.
    static func render(store: ThemeStore, theme: Theme, o: SnapshotRunner.Options) -> Int {
        var count = 0
        for shot in shots {
            var data = SettingsData()
            data.themeId = theme.id
            let env = AppEnvironment(settings: SimpleIslandSettings(inMemory: data), themes: store,
                                     modules: ModuleRegistry.makeModules(), isSnapshot: true)
            let st = WidgetCatalogState(env: env)
            shot.prepare(st)
            let t = env.settings.data.applying(to: theme)
            let p = SettingsPalette(theme: t)
            let view = ZStack(alignment: .top) {
                // «Рабочий стол» как в макете.
                Color(hex: "#07070A")
                LinearGradient(colors: [Color(hex: "#1C2A6B"), Color(hex: "#3A1A5C"), Color(hex: "#7A2E1C")],
                               startPoint: UnitPoint(x: 0, y: 0), endPoint: UnitPoint(x: 1, y: 1)).opacity(0.75)
                WidgetCatalogView(state: st, onClose: {})
                    .shadow(color: .black.opacity(p.light ? 0.25 : 0.6), radius: 40, y: 24)
                    .padding(40)
            }
            .fixedSize()
            .environment(\.settingsPalette, p)
            .environment(\.islandTheme, t)
            .environment(\.colorScheme, p.light ? .light : .dark)
            .environment(\.isSnapshot, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            let url = o.outDir.appendingPathComponent("\(theme.id)-catalog-\(shot.name).png")
            guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                fputs("SimpleIsland: не отрисован \(url.lastPathComponent)\n", stderr); continue
            }
            do { try png.write(to: url); count += 1 } catch {
                fputs("SimpleIsland: не записан \(url.path): \(error)\n", stderr)
            }
        }
        return count
    }
}
