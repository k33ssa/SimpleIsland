import AppKit
import Combine
import SwiftUI
import IslandCore
import VafaModule

// --- catalog --- Каталог виджетов (макет 11-catalog): карточки встроенных модулей с понятными описаниями и
// «Мои приложения» — внешние приложения автора (Vafa, SimpleScreenTab). Состояние карточки модуля = включена ли его
// вкладка в настройках (`settings.data.tabs`), «Добавить»/«Убрать» пишут туда же (то же, что тумблер в «Раскладке»).

enum CatalogCategory: String, CaseIterable, Identifiable {
    case all, builtin, system, work, mine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .builtin: return "Встроенные"
        case .system: return "Система"
        case .work: return "Работа"
        case .mine: return "Мои приложения"
        }
    }
}

/// Карточка встроенного модуля: тексты для обычного человека, без жаргона.
struct CatalogEntry: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var description: String
    var symbol: String
    var gradient: [String]
    var categories: Set<CatalogCategory>
    /// Доп. слова для поиска.
    var keywords: String = ""

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return [title, subtitle, description, keywords].contains { $0.lowercased().contains(q) }
    }
}

@MainActor
enum WidgetCatalogData {
    /// Тексты встроенных модулей. Модуль без записи получает карточку из своих title/systemImage.
    static let known: [String: CatalogEntry] = [
        "media": CatalogEntry(id: "media", title: "Музыка", subtitle: "Apple Music, Spotify, браузер",
                              description: "Обложка, перемотка, наушники и текст песни прямо под вырезом.",
                              symbol: "music.note", gradient: ["#FF7A45", "#FF3D7F"], categories: [.builtin],
                              keywords: "плеер песня трек звук"),
        "today": CatalogEntry(id: "today", title: "Сегодня", subtitle: "встреча, погода, буфер",
                              description: "Ближайшая встреча, погода, нагрузка на Мак и недавно скопированное.",
                              symbol: "calendar", gradient: ["#38BDF8", "#2563EB"], categories: [.builtin, .system, .work],
                              keywords: "календарь погода таймер буфер обмена нагрузка батарея"),
        "shelf": CatalogEntry(id: "shelf", title: "Полка", subtitle: "файлы на вырез",
                              description: "Бросьте файл на остров — он подождёт тут. Отсюда же AirDrop, архив и текст с картинки.",
                              symbol: "tray.fill", gradient: ["#A879FF", "#7B2CFF"], categories: [.builtin, .work],
                              keywords: "файл перетащить airdrop zip архив картинка"),
        "agents": CatalogEntry(id: "agents", title: "Агенты", subtitle: "Claude Code, Codex",
                               description: "Видно, чем заняты помощники-программисты. Разрешения — в один клик, с показом изменений.",
                               symbol: "terminal.fill", gradient: ["#3A3A40", "#16161A"], categories: [.builtin, .work],
                               keywords: "ии нейросеть код программист"),
        "hud": CatalogEntry(id: "hud", title: "Громкость и яркость", subtitle: "вместо системных окошек",
                            description: "Громкость, яркость, зарядка, наушники и раскладка — аккуратно вокруг выреза.",
                            symbol: "speaker.wave.2.fill", gradient: ["#39D98A", "#0F9D58"], categories: [.builtin, .system],
                            keywords: "звук экран подсветка зарядка раскладка наушники"),
        // --- lyrics --- виджет на модели «Медиа»: тот же захват звука, по умолчанию не на острове
        "equalizer": CatalogEntry(id: "equalizer", title: "Эквалайзер", subtitle: "пресеты Музыки и спектр",
                                  description: "Пресеты эквалайзера Музыки (Рок, Поп, Усилитель басов…) и вкл/выкл в один клик. Сверху — спектр того, что играет, из любого плеера; у Spotify и браузеров эквалайзера нет — только спектр.",
                                  symbol: "waveform", gradient: ["#FFD36E", "#FF3D7F"], categories: [.builtin],
                                  keywords: "эквалайзер спектр полоски визуализатор звук музыка пресет бас equalizer visualizer preset"),
        // --- menubar ---
        "menubar": CatalogEntry(id: "menubar", title: "Значки строки меню", subtitle: "уборка справа вверху",
                                description: "Лишние значки строки меню — в остров, спрятать или закрыть приложение. Видно и то, что macOS прячет под вырезом.",
                                symbol: "square.grid.2x2.fill", gradient: ["#FF7A45", "#C2187A"], categories: [.builtin, .system],
                                keywords: "строка меню значки иконки трей вырез уборка мусор bartender ice hidden bar"),
    ]

    /// Модули, которые показываются не в сетке, а своей карточкой в «Мои приложения».
    static let ownCardModules: Set<String> = [VafaIslandModule.moduleId]

    static func entries(for modules: [IslandModule]) -> [CatalogEntry] {
        modules.filter { !ownCardModules.contains($0.id) }.map { m in
            (known[m.id] ?? extraKnown[m.id]) ?? CatalogEntry(id: m.id, title: m.title, subtitle: "встроенный", description: "",
                                        symbol: m.systemImage, gradient: ["#6B7280", "#374151"], categories: [.builtin])
        }
    }

    // Vafa
    static let vafaDescription = "Охрана приложений без VPN. Выбранные программы замораживаются и не запускаются, пока VPN выключен, и сами оживают, когда он снова включится. В острове — значок охраны и список того, что сейчас заморожено. Особый присмотр за всеми сервисами Claude."
    static let vafaMeta = ["Бесплатно · открытый код (MIT)", "macOS 12+", "нужен пароль администратора"]
    static let vafaCask = "k33ssa/tap/vafa"
    static let vafaCommand = "brew install --cask \(vafaCask)"
    static let vafaReleases = URL(string: "https://github.com/k33ssa/vafa/releases/latest")!
    static let vafaKeywords = "vafa вафа vpn впн охрана заморозка claude блокировка мои приложения"
    static let screenTabURL = URL(string: "https://github.com/k33ssa/SimpleScreenTab")!

    static func vafaMatches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty || ("vafa " + vafaDescription + " " + vafaKeywords).lowercased().contains(q)
    }
}

// MARK: - Значки карточек (Resources/Catalog)

enum CatalogImages {
    private static var cache: [String: NSImage] = [:]

    /// Где лежат значки: .app → Contents/Resources/Catalog; отладка (.build/debug) → Resources/Catalog репозитория.
    static var directories: [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Catalog")) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var d = exe.deletingLastPathComponent()
            for _ in 0..<5 {
                dirs.append(d.appendingPathComponent("Resources/Catalog"))
                d = d.deletingLastPathComponent()
            }
        }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Catalog"))
        return dirs
    }

    /// Значок под размер показа (ImageIO-миниатюра, не весь PNG в память).
    @MainActor static func image(_ name: String, points: CGFloat) -> NSImage? {
        let key = "\(name)@\(Int(points))"
        if let c = cache[key] { return c }
        for dir in directories {
            let url = dir.appendingPathComponent("\(name).png")
            guard FileManager.default.fileExists(atPath: url.path),
                  let cg = ImageDownsampler.downsample(url: url, maxPixelSize: Int(points * 2)) else { continue }
            let img = NSImage(cgImage: cg, size: NSSize(width: points, height: points))
            cache[key] = img
            return img
        }
        return nil
    }
}

// MARK: - Внешние приложения: установлено ли, есть ли Homebrew

enum ExternalAppStatus: Equatable {
    case installed
    /// Терминал с установкой открыт, ждём появления файлов.
    case installing
    case canBrew(brew: String)
    case download
}

@MainActor
final class WidgetCatalogState: ObservableObject {
    // Сменили поиск или категорию — подсветку «куда смотреть» снять.
    @Published var query = "" { didSet { if query != oldValue { focus = nil } } }
    @Published var category: CatalogCategory = .all { didSet { if category != oldValue { focus = nil } } }
    @Published private(set) var vafa: ExternalAppStatus = .download
    /// Последняя ошибка запуска Терминала (показывается под кнопкой «Установить»).
    @Published var installNote: String?
    /// Карточка, которую подсветить (открыли «из Vafa»). Снимается при смене категории или поиска.
    @Published var focus: String?

    let env: AppEnvironment
    /// Пути признаков Vafa и Homebrew — самотест подменяет.
    var vafaMarkers = VafaPaths.installMarkers
    var brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// Как открыть Терминал с командой; второй аргумент — «не вышло» с текстом для человека
    /// (самотест подменяет, чтобы ничего не запускать).
    var runInTerminal: (String, @escaping @MainActor (String) -> Void) -> Void = {
        WidgetCatalogInstaller.openTerminal(command: $0, onFailure: $1)
    }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var installWatchers: [FileWatcher] = []
    private var installing = false
    private var tabsWatch: AnyCancellable?
    /// Сколько раз состояние сообщило вьюхам «вкладки острова поменялись» (самотест).
    private(set) var tabsChangeCount = 0

    init(env: AppEnvironment) {
        self.env = env
        // «На острове» считается из `settings.tabs`, а не из своих @Published: без подписки карточка, нажатая
        // «Добавить», не перерисовывалась (15.11, «не обновляется, что добавилось»). Вкладки меняются и из
        // «Раскладки», и из меню острова — источник один, поэтому слушаем его, а не только свою кнопку.
        tabsWatch = env.settings.$data
            .map { $0.tabs.map { "\($0.id)=\($0.enabled)/\($0.side.rawValue)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tabsChangeCount += 1
                    self.objectWillChange.send()
                }
            }
    }

    // MARK: Встроенные

    var entries: [CatalogEntry] { WidgetCatalogData.entries(for: env.modules) }

    func isOnIsland(_ id: String) -> Bool {
        guard let m = env.module(id: id) else { return false }
        if !m.providesTab { return true }        // HUD: без вкладки, работает всегда (свои переключатели в настройках)
        return env.settings.data.tabs.first { $0.id == id }?.enabled ?? false
    }

    func canRemove(_ id: String) -> Bool { env.module(id: id)?.providesTab ?? false }

    /// «Добавить» — вкладка встаёт в конец левой стороны выреза, если там есть место, иначе в конец правой
    /// (16.11); «Убрать» — только выключает (место в списке и сторона остаются).
    func setOnIsland(_ id: String, _ on: Bool) {
        guard let m = env.module(id: id), m.providesTab else { return }
        let current = env.settings.data.tabs.first { $0.id == id }
        if on {
            guard current?.enabled != true else { return }
            let width = CGFloat(env.settings.data.expandedWidth)
            let gap = notchWidth
            TabArrangement.placeNew(&env.settings.data.tabs, id: id) {
                TabBarLayout.leftHasRoom(count: $0, width: width, gap: gap)
            }
        } else if let i = env.settings.data.tabs.firstIndex(where: { $0.id == id }) {
            if env.settings.data.tabs[i].enabled { env.settings.data.tabs[i].enabled = false }
        } else {
            env.settings.data.tabs.append(TabSetting(id: id, enabled: false))
        }
    }

    /// Ширина выреза для «есть ли место слева»: в снимках/самотестах — как в макетах, живьём — вырез этого Мака.
    private var notchWidth: CGFloat {
        env.isSnapshot ? IslandGeometry.mockNotch.notchWidth : SettingsPreviewHolder.realNotch().notchWidth
    }

    var visibleEntries: [CatalogEntry] {
        guard category != .mine else { return [] }
        return entries.filter { (category == .all || $0.categories.contains(category)) && $0.matches(query) }
    }

    var showsVafa: Bool { (category == .all || category == .mine) && WidgetCatalogData.vafaMatches(query) }
    var showsMore: Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (category == .all || category == .mine)
            && (q.isEmpty || "simplescreentab cmd tab монитор ещё от автора".contains(q))
    }

    /// «N из M на острове» — по тем карточкам, что сейчас видны (категория и поиск).
    var onIslandCount: Int { visibleEntries.filter { isOnIsland($0.id) }.count }

    // MARK: Vafa

    var vafaWidgetOn: Bool { isOnIsland(VafaIslandModule.moduleId) }

    /// Перепроверить: установлена ли Vafa, есть ли Homebrew. Зовётся при показе окна и при его активации.
    func refresh() {
        let fm = FileManager.default
        let new: ExternalAppStatus
        if vafaMarkers.contains(where: { fm.fileExists(atPath: $0) }) {
            new = .installed
            if installing { finishInstall() }
        } else if installing {
            new = .installing
        } else if let brew = brewPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            new = .canBrew(brew: brew)
        } else {
            new = .download
        }
        if new != vafa { vafa = new }
    }

    /// «Установить»: Терминал с командой Homebrew (пароль администратора человек вводит там сам),
    /// дальше — ждать появления файлов Vafa (FileWatcher на каталогах, без опроса).
    func installVafa() {
        guard case .canBrew(let brew) = vafa else { return }
        installNote = nil
        installing = true
        runInTerminal("\(brew) install --cask \(WidgetCatalogData.vafaCask)") { [weak self] note in
            // Ни osascript, ни запасной `.command` не открыли Терминал — вернуть «Установить» и сказать почему.
            guard let self, self.installing else { return }
            self.cancelInstall()
            self.installNote = note
        }
        if installing {
            watchForInstall()
            refresh()
        }
    }

    /// «Отмена» в «Устанавливается…»: Терминал закрыли, пароль не подошёл, brew упал — вернуть «Установить».
    /// Сама установка в Терминале (если идёт) не прерывается: появятся файлы — карточка увидит при следующей проверке.
    func cancelInstall() {
        installing = false
        installNote = nil
        stopWatching()
        refresh()
    }

    /// «Повторить»: снова открыть Терминал с той же командой.
    func retryInstall() {
        cancelInstall()
        installVafa()
    }

    func downloadVafa() { openURL(WidgetCatalogData.vafaReleases) }

    /// Следить за каталогами, где появятся файлы Vafa (`/usr/local/bin`, `/Applications`).
    private func watchForInstall() {
        installWatchers.forEach { $0.stop() }
        let dirs = Set(vafaMarkers.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        installWatchers = dirs.sorted().map { dir in
            let w = FileWatcher(url: URL(fileURLWithPath: dir, isDirectory: true)) { [weak self] in self?.refresh() }
            w.start()
            return w
        }
    }

    private func finishInstall() {
        installing = false
        installWatchers.forEach { $0.stop() }
        installWatchers = []
    }

    /// Окно закрыто — слушатели снять (установка дождётся следующего открытия: проверка при показе).
    func stopWatching() {
        installWatchers.forEach { $0.stop() }
        installWatchers = []
    }

    /// Окно снова показали, а установка шла — слушать дальше.
    func resumeWatchingIfNeeded() {
        if installing && installWatchers.isEmpty { watchForInstall() }
    }

    var isWatchingInstall: Bool { !installWatchers.isEmpty }

    /// Снимки: состояние карточки Vafa без проверки диска.
    func mockVafa(_ v: ExternalAppStatus) { vafa = v; installing = v == .installing }

    /// Открытие окна: без `focus` — с чистого листа («Все», без поиска); с `focus` — категория карточки и подсветка.
    func prepareForShow(focus: String?) {
        query = ""
        category = focus == VafaIslandModule.moduleId ? .mine : .all
        self.focus = focus
    }

    func addVafaWidget() {
        setOnIsland(VafaIslandModule.moduleId, true)
    }
}

// MARK: - Терминал

enum WidgetCatalogInstaller {
    static let terminalBundleId = "com.apple.Terminal"

    /// Открыть Терминал и выполнить команду (osascript `do script`). Право «Автоматизация → Терминал» — через ядро
    /// прав: уже запрещено — сразу запасной путь, без Apple Events: файл `.command` во временном каталоге, его
    /// открывает Терминал. Разрешено/не спрашивали — osascript (первый раз система сама спросит, это нажатие
    /// пользователя), не вышло — тот же запасной путь. Не открылся и он — `onFailure` с текстом.
    @MainActor static func openTerminal(command: String, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        if Permissions.status(.automation(bundleId: terminalBundleId)) == .denied {
            openCommandFile(command, onFailure: onFailure)
            return
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = ManagedProcess(executable: "/usr/bin/osascript",
                               arguments: ["-e", "tell application \"Terminal\"", "-e", "activate",
                                           "-e", "do script \"\(escaped)\"", "-e", "end tell"])
        p.onExit = { code in
            running.removeAll { $0 === p }
            if code != 0 { openCommandFile(command, onFailure: onFailure) }
        }
        running.append(p)
        if !p.start() { running.removeAll { $0 === p }; openCommandFile(command, onFailure: onFailure) }
    }

    /// Живые запуски osascript (ManagedProcess гасит их при выходе приложения).
    @MainActor private static var running: [ManagedProcess] = []

    @MainActor static func openCommandFile(_ command: String, onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("install-vafa.command")
        let script = "#!/bin/zsh\necho \"SimpleIsland: \(command.replacingOccurrences(of: "\"", with: "\\\""))\"\n\(command)\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            onFailure("Не открылся Терминал: не записан файл установки (\(error.localizedDescription)). Выполните команду ниже вручную.")
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let text = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onFailure("Не открылся Терминал (\(text)). Выполните команду ниже вручную.")
                }
            }
        }
    }
}

// MARK: - Самотест

@MainActor
enum WidgetCatalogSelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("ok    \(name)") } else { failures += 1; print("ПРОВАЛ \(name) \(detail())") }
    }

    private static func spin(_ timeout: TimeInterval = 3, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        failures = 0; passes = 0
        let env = AppEnvironment(settings: SimpleIslandSettings(inMemory: SettingsData()), themes: ThemeStore(load: false),
                                 modules: ModuleRegistry.makeModules(), isSnapshot: true)
        let s = WidgetCatalogState(env: env)

        // Карточки
        let ids = s.entries.map(\.id)
        check(!ids.contains("vafa") && ids.contains("media") && ids.contains("hud"), "сетка: встроенные без Vafa", "\(ids)")
        check(s.entries.allSatisfy { !$0.description.isEmpty && !$0.subtitle.isEmpty }, "у каждой карточки есть описание")
        check(env.settings.data.tabs.first { $0.id == "vafa" }?.enabled == false, "Vafa по умолчанию выключена")
        // --- lyrics ---
        check(ids.contains("equalizer") && s.entries.first { $0.id == "equalizer" }?.title == "Эквалайзер"
              && env.settings.data.tabs.first { $0.id == "equalizer" }?.enabled == false && !s.isOnIsland("equalizer"),
              "Эквалайзер: карточка в каталоге, по умолчанию не на острове")
        s.setOnIsland("equalizer", true)
        check(s.isOnIsland("equalizer") && env.enabledTabModules.contains { $0.id == "equalizer" }, "Эквалайзер: «Добавить» — вкладка на острове")
        s.setOnIsland("equalizer", false)

        // Реактивность (15.11: «нажимаю "Добавить" — не обновляется»): карточки и счётчик берут «на острове» из
        // `settings.tabs`, состояние обязано сообщить вьюхам о каждой смене — и своей кнопкой, и снаружи.
        var willChange = 0
        let sub = s.objectWillChange.sink { willChange += 1 }
        let c0 = s.tabsChangeCount, count0 = s.onIslandCount
        s.setOnIsland("equalizer", true)
        check(s.tabsChangeCount == c0 + 1 && willChange >= 1 && s.onIslandCount == count0 + 1,
              "«Добавить» — вьюхи узнают сразу (кнопка → «На острове ✓», счётчик +1)", "\(s.tabsChangeCount - c0) \(willChange)")
        if let i = env.settings.data.tabs.firstIndex(where: { $0.id == "equalizer" }) { env.settings.data.tabs[i].enabled = false }
        check(s.tabsChangeCount == c0 + 2 && !s.isOnIsland("equalizer") && s.onIslandCount == count0,
              "вкладку выключили снаружи («Раскладка») — каталог тоже обновится")
        let c1 = s.tabsChangeCount
        env.settings.data.hoverDelay += 0.01
        check(s.tabsChangeCount == c1, "другие настройки каталог не дёргают")
        sub.cancel()

        // Добавить / убрать = вкладки в настройках
        s.setOnIsland("shelf", false)
        check(!s.isOnIsland("shelf") && env.settings.data.tabs.first { $0.id == "shelf" }?.enabled == false, "«Убрать» выключает вкладку")
        let order = env.settings.data.tabs.map(\.id)
        let sides = env.settings.data.tabs.map(\.side)
        s.setOnIsland("shelf", false)
        check(env.settings.data.tabs.map(\.id) == order && env.settings.data.tabs.map(\.side) == sides,
              "повторное «Убрать» — место и сторона прежние")
        s.setOnIsland("shelf", true)
        let left = TabArrangement.tabs(env.settings.data.tabs, on: .left).filter(\.enabled).map(\.id)
        check(s.isOnIsland("shelf") && left.last == "shelf", "«Добавить» — в конец левой стороны (место есть)", "\(left)")
        let order2 = env.settings.data.tabs.map(\.id)
        s.setOnIsland("shelf", true)
        check(env.settings.data.tabs.map(\.id) == order2, "«Добавить» уже добавленной — ничего не двигает")
        // Слева тесно — новая встаёт справа.
        let saved = env.settings.data.tabs
        for i in env.settings.data.tabs.indices where env.module(id: env.settings.data.tabs[i].id)?.providesTab == true {
            env.settings.data.tabs[i].enabled = true; env.settings.data.tabs[i].side = .left
        }
        for k in 0..<8 { env.settings.data.tabs.append(TabSetting(id: "fake\(k)", enabled: true)) }
        if let i = env.settings.data.tabs.firstIndex(where: { $0.id == "vafa" }) { env.settings.data.tabs[i].enabled = false }
        s.setOnIsland("vafa", true)
        check(env.settings.data.tabs.first { $0.id == "vafa" }?.side == .right && s.isOnIsland("vafa"),
              "слева нет места — «Добавить» ставит вкладку справа от выреза")
        env.settings.data.tabs = saved
        check(s.isOnIsland("hud") && !s.canRemove("hud"), "HUD без вкладки — всегда на острове, убрать нельзя")
        s.setOnIsland("hud", false)
        check(s.isOnIsland("hud"), "HUD «убрать» ничего не ломает")
        let before = s.onIslandCount
        s.setOnIsland("media", false)
        check(s.onIslandCount == before - 1, "счётчик «N из M на острове»")
        s.setOnIsland("media", true)

        // Категории и поиск
        s.category = .work
        check(s.visibleEntries.map(\.id).contains("agents") && !s.visibleEntries.map(\.id).contains("media") && !s.showsVafa,
              "категория «Работа»")
        check(s.onIslandCount <= s.visibleEntries.count, "«N из M на острове» — по видимым карточкам",
              "\(s.onIslandCount) из \(s.visibleEntries.count)")
        s.category = .mine
        check(s.visibleEntries.isEmpty && s.showsVafa && s.showsMore, "«Мои приложения»: только Vafa и SimpleScreenTab")
        s.category = .all; s.query = "погода"
        check(s.visibleEntries.map(\.id) == ["today"] && !s.showsVafa, "поиск «погода» → Сегодня")
        s.query = "VPN"
        check(s.visibleEntries.isEmpty && s.showsVafa, "поиск «VPN» → Vafa")
        s.query = " монитор "
        check(s.showsMore, "поиск с пробелами по краям находит SimpleScreenTab")
        s.query = ""

        // Открытие окна: из Vafa — «Мои приложения» и подсветка; потом «+» — снова «Все», без поиска.
        s.prepareForShow(focus: "vafa")
        check(s.category == .mine && s.focus == "vafa", "открыли из Vafa → «Мои приложения», подсветка Vafa")
        s.category = .all
        check(s.focus == nil, "сменили категорию → подсветка снята")
        s.query = "погода"; s.category = .work
        s.prepareForShow(focus: nil)
        check(s.category == .all && s.query.isEmpty && s.focus == nil, "открыли «+» → «Все», поиск пуст")

        // Установка: временные пути, Терминал не открывается
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("simpleisland-catalog-\(getpid())")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("bin"), apps = tmp.appendingPathComponent("Applications")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let fakeBrew = tmp.appendingPathComponent("brew")
        s.vafaMarkers = [bin.appendingPathComponent("vpn-guard").path, apps.appendingPathComponent("Vafa.app").path]
        s.brewPaths = [fakeBrew.path]
        var commands: [String] = [], urls: [URL] = []
        var failNext: String?
        s.runInTerminal = { cmd, fail in
            commands.append(cmd)
            if let f = failNext { failNext = nil; fail(f) }
        }
        s.openURL = { urls.append($0) }

        s.refresh()
        check(s.vafa == .download, "нет Vafa и нет Homebrew → «Скачать»")
        s.downloadVafa()
        check(urls.last == WidgetCatalogData.vafaReleases, "«Скачать» → страница релизов")
        FileManager.default.createFile(atPath: fakeBrew.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        s.refresh()
        check(s.vafa == .canBrew(brew: fakeBrew.path), "есть Homebrew → «Установить»")
        s.installVafa()
        check(commands == ["\(fakeBrew.path) install --cask k33ssa/tap/vafa"], "команда в Терминал — brew install --cask", "\(commands)")
        check(s.vafa == .installing && s.isWatchingInstall, "после «Установить» — ждём, слушая каталоги")
        s.cancelInstall()
        check(s.vafa == .canBrew(brew: fakeBrew.path) && !s.isWatchingInstall, "«Отмена» → снова «Установить», слушатели сняты")
        failNext = "Не открылся Терминал"
        s.installVafa()
        check(s.vafa == .canBrew(brew: fakeBrew.path) && s.installNote == "Не открылся Терминал" && !s.isWatchingInstall,
              "Терминал не открылся → «Установить» и текст ошибки", "\(s.vafa) \(s.installNote ?? "-")")
        s.installVafa()
        check(s.installNote == nil && s.vafa == .installing, "новая попытка — ошибка стёрта")
        s.retryInstall()
        check(commands.count == 4 && s.vafa == .installing && s.isWatchingInstall, "«Повторить» — Терминал ещё раз, ждём", "\(commands.count)")
        try? FileManager.default.createDirectory(at: apps.appendingPathComponent("Vafa.app"), withIntermediateDirectories: true)
        check(spin { s.vafa == .installed }, "Vafa.app появилась → «Установлена» (FileWatcher, без опроса)")
        check(!s.isWatchingInstall, "после установки слушатели сняты")
        check(!s.vafaWidgetOn, "виджет Vafa ещё не на острове")
        s.addVafaWidget()
        check(s.vafaWidgetOn, "«Добавить виджет» включает вкладку Vafa")

        // Значки
        check(CatalogImages.image("vafa", points: 96) != nil, "значок Vafa найден (Resources/Catalog)")
        check(CatalogImages.image("simplescreentab", points: 28) != nil, "значок SimpleScreenTab найден")

        print("\nCatalog selftest: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

// Публичная версия: карточка «Встреч» — только в сборке с SIMPLEISLAND_MEETINGS.
extension WidgetCatalogData {
    static var extraKnown: [String: CatalogEntry] {
        #if SIMPLEISLAND_MEETINGS
        return ["meetings": CatalogEntry(id: "meetings", title: "Встречи", subtitle: "Sten · протокол встреч",
                                 description: "Запись встречи прямо из острова. Sten разберёт разговор: итог, решения и задачи — по людям. Вход один раз.",
                                 symbol: "person.2.wave.2.fill", gradient: ["#FF5470", "#A879FF"], categories: [.builtin, .work],
                                 keywords: "sten стен встреча созвон протокол запись диктофон микрофон задачи итог решения участники meeting")]
        #else
        return [:]
        #endif
    }
}
