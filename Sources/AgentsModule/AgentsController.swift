import AppKit
import Combine
import IslandCore
import SwiftUI

/// Настройки модуля (settings.json → moduleSettings.agents).
struct AgentsPrefs: Codable, Equatable {
    /// Имя системного звука на «ждёт»; пусто — без звука.
    var sound = "Tink"
    /// Раскрывать остров на вкладке, когда агент ждёт.
    var autoExpand = true
    /// Через сколько минут убирать закрытые сессии.
    var keepMinutes = 5
    /// Забирать клавиатуру сразу, как агент спросил (иначе — когда курсор над островом или по клику).
    var grabKeyboard = false

    static let sounds = ["Tink", "Pop", "Glass", "Purr", "Bottle", ""]

    /// Русские названия системных звуков (в файле настроек — системное имя).
    static func soundName(_ s: String) -> String {
        switch s {
        case "": return "без звука"
        case "Tink": return "тихий «пинг»"
        case "Pop": return "«хлоп»"
        case "Glass": return "стекло"
        case "Purr": return "мурчание"
        case "Bottle": return "бутылка"
        default: return s
        }
    }

    static func soundTitle(_ s: String) -> String { soundName(s) }

    init() {}
    init(from decoder: Decoder) throws {
        // Поля, которых нет в файле, — по умолчанию (настройки переживут новые версии).
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentsPrefs()
        sound = (try? c.decode(String.self, forKey: .sound)) ?? d.sound
        autoExpand = (try? c.decode(Bool.self, forKey: .autoExpand)) ?? d.autoExpand
        keepMinutes = (try? c.decode(Int.self, forKey: .keepMinutes)) ?? d.keepMinutes
        grabKeyboard = (try? c.decode(Bool.self, forKey: .grabKeyboard)) ?? d.grabKeyboard
    }
}

/// Мозг модуля: сервер сокета, хранилище сессий, реакция острова (точка, компакт, звук, раскрытие, клавиатура).
@MainActor
final class AgentsController: ObservableObject {
    let store = AgentsStore()
    @Published var prefs = AgentsPrefs() {
        didSet {
            guard prefs != oldValue else { return }
            if !isSnapshot { context?.saveSettings(prefs) }
            store.keepAfterEnd = TimeInterval(max(1, prefs.keepMinutes) * 60)
        }
    }
    /// Текст последнего действия установщика (подвал/настройки).
    @Published var installMessage: String?
    /// Плитка подвала спрашивает «записать хуки?» — запись в ~/.claude/settings.json только с согласия.
    @Published var confirmInstall = false
    /// Кнопка «Проверить»: тестовое событие через `--hook ping` тем же бинарём, что в хуках.
    @Published var probe: HookProbe = .idle
    /// Сколько живых разделов модуля в окне настроек (часы «N с назад» тикают и там). Считает
    /// `AgentsSettingsPresence`: снимается в его deinit, а не в `onDisappear`, которого у закрытого окна может не быть.
    var settingsViewers = 0 { didSet { updateTicking() } }
    var settingsVisible: Bool { settingsViewers > 0 }

    weak var context: ModuleContext?
    var isSnapshot = false
    private var server: AgentSocketServer?
    private var bag = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var autoOpened = false
    private var holdsKeyboard = false
    private var lastSound = Date.distantPast
    private var lastHeight: CGFloat = 0
    /// Что последний раз отдали ядру — чтобы не публиковать то же самое на каждое изменение хранилища
    /// (каждая буква в поле причины), иначе ядро перерисовывает остров.
    private var dotPublished = false
    private var lastDot: SessionStatus?
    /// Точка у выреза в полноэкранном (`setAttention`): последнее отправленное и сессии, уже бывшие «готово».
    private var lastAttention: String?
    private var doneIds: Set<String> = []
    private var freshDone: String?
    private var lastActivityKey: String?
    /// Окно острова, в котором показана вкладка (для «панель перестала быть ключевой»).
    weak var hostWindow: NSWindow? {
        didSet { if hostWindow !== oldValue { observeResignKey() } }
    }
    private var resignObserver: NSObjectProtocol?
    private var settingsWatcher: FileWatcher?
    private var codexWatcher: FileWatcher?
    private var tick: AnyCancellable?
    private var wakeCheck: DispatchWorkItem?
    private var probeProcess: ManagedProcess?
    private var probeNonce: String?
    private var probeStarted = Date.distantPast
    private var probeTimeout: DispatchWorkItem?

    init() {}

    // MARK: - Жизненный цикл

    func start(context: ModuleContext) {
        self.context = context
        isSnapshot = context.isSnapshot
        prefs = context.loadSettings(AgentsPrefs.self) ?? AgentsPrefs()
        store.keepAfterEnd = TimeInterval(max(1, prefs.keepMinutes) * 60)
        refreshIntegration()
        // Статус подключения — по событиям файла (правка руками, переустановка), без опроса.
        let home = AgentsPaths.home
        settingsWatcher = FileWatcher(url: Installer.claudeSettings(home: home)) { [weak self] in self?.refreshIntegration() }
        settingsWatcher?.start()
        codexWatcher = FileWatcher(url: Installer.codexConfig(home: home)) { [weak self] in self?.refreshIntegration() }
        codexWatcher?.start()

        startServer()
        // После сна/блокировки/смены сессии — проверить, что сокет слушает (файл могли удалить, дескриптор — закрыть),
        // иначе пересоздать. С паузой: сразу после пробуждения система ещё поднимает своё (M3).
        context.onSystemEvent { [weak self] e in
            switch e {
            case .didWake, .screensDidWake, .sessionDidBecomeActive, .screenUnlocked: self?.scheduleSocketCheck()
            default: break
            }
        }
        store.onPing = { [weak self] nonce in self?.pingArrived(nonce) }
        observeResignKey()
        store.onAttention = { [weak self] s in self?.attention(s) }
        store.onPromptsCleared = { [weak self] in self?.promptsCleared() }
        store.wrapColumns = { [weak context] in
            ToolPreview.columns(forIslandWidth: CGFloat(context?.settings.data.expandedWidth ?? 720))
        }
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &bag)
        // Ядро сняло просьбу о клавиатуре само (остров свернулся) — забыть, что держим её.
        context.island.$keyboardOwners
            .sink { [weak self] owners in if !owners.contains("agents") { self?.holdsKeyboard = false } }
            .store(in: &bag)
        context.island.$expandedTab
            .removeDuplicates()
            .sink { [weak self] tab in self?.scheduleRefresh(); self?.updateTicking(tabVisible: tab == "agents") }
            .store(in: &bag)
        scheduleRefresh()
    }

    // MARK: - Сокет

    private func startServer() {
        let server = AgentSocketServer(path: AgentsPaths.socketPath)
        server.onMessage = { [weak self] conn, line in self?.store.receive(line, connection: conn) }
        server.onClose = { [weak self] conn in self?.store.connectionClosed(conn) }
        store.reply = { [weak server] conn, data in server?.reply(data, to: conn) }
        do {
            try server.start()
            self.server = server
            store.serverProblem = nil
        } catch {
            self.server = nil
            store.serverProblem = "Сокет агентов не поднят: \(error)"
        }
    }

    func scheduleSocketCheck(after delay: TimeInterval = 1) {
        wakeCheck?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.ensureSocket() } }
        wakeCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Сокет не слушает — поднять заново. Открытые соединения (висящие запросы) не рвём: пересоздаётся только
    /// слушающий сокет. Сервера не было (занят другим экземпляром) — попробовать ещё раз.
    func ensureSocket() {
        guard context != nil, !isSnapshot else { return }
        guard let server else { startServer(); return }
        guard !server.isHealthy else { return }
        do {
            try server.restartListener()
            store.serverProblem = nil
            NSLog("SimpleIsland agents: сокет пересоздан после пробуждения")
        } catch {
            store.serverProblem = "Сокет агентов не поднят: \(error)"
        }
    }

    // MARK: - Часы «N с назад»

    /// Тикаем раз в секунду только пока видно (вкладка или раздел настроек); во сне SharedTicker сам на паузе.
    /// `tabVisible` — новое значение из подписки (@Published отдаёт его до записи в свойство).
    private func updateTicking(tabVisible: Bool? = nil) {
        let visible = tabVisible ?? context.map { $0.isTabVisible } ?? false
        if (visible || settingsVisible) && !isSnapshot && context != nil {
            if tick == nil {
                AgentsClock.shared.now = Date()
                tick = SharedTicker.shared.subscribe(every: 1) { now in AgentsClock.shared.now = now }
            }
        } else {
            tick = nil
        }
    }

    /// Для самотеста: тикают ли часы.
    var isTicking: Bool { tick != nil }
    /// Для самотеста: слушает ли сокет.
    var socketHealthy: Bool { server?.isHealthy ?? false }

    func stop() {
        context?.removeSystemEventHandlers()
        server?.stop()
        server = nil
        store.reply = nil
        store.onAttention = nil
        store.onPromptsCleared = nil
        bag.removeAll()
        settingsWatcher?.stop(); settingsWatcher = nil
        codexWatcher?.stop(); codexWatcher = nil
        tick = nil
        wakeCheck?.cancel(); wakeCheck = nil
        finishProbe(.idle)
        store.onPing = nil
        if holdsKeyboard { context?.requestKeyboard(false); holdsKeyboard = false }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        store.shutdown()
        context?.activities.removeAll(moduleId: "agents")
        dotPublished = false
        lastDot = nil
        lastAttention = nil
        doneIds = []
        freshDone = nil
        lastActivityKey = nil
        context = nil
    }

    /// Что показать точкой у выреза (чистая функция — самотест агентов).
    static func attention(sessions s: [AgentSession], freshDone: String?) -> (kind: AttentionKind, text: String)? {
        if let w = s.first(where: { $0.isWaiting }) { return (.ask, "Агент ждёт ответа · \(w.project)") }
        if let e = s.first(where: { $0.status == .error }) { return (.error, "Агент: ошибка · \(e.project)") }
        if let d = freshDone { return (.done, "Агент закончил · \(d)") }
        return nil
    }

    // MARK: - Реакция острова

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard let ctx = context else { return }
        let s = store.sessions
        // Живая точка модуля — одна: ждёт (жёлтая, 50) > ошибка (красная, 100 по контракту) > работает (зелёная, 0).
        // «Ждёт» внутри модуля важнее ошибки: на него можно ответить прямо сейчас.
        let dot: SessionStatus? = s.contains { $0.isWaiting } ? .waiting
            : s.contains { $0.status == .error } ? .error
            : s.contains { $0.status == .working } ? .working : nil
        if !dotPublished || lastDot != dot {
            switch dot {
            case .waiting: ctx.setStatusDot(IslandPalette.warn, priority: 50)
            case .error: ctx.setStatusDot(IslandPalette.err, priority: 100)
            case .working: ctx.setStatusDot(IslandPalette.ok, priority: 0)
            default: ctx.setStatusDot(nil)
            }
            dotPublished = true
            lastDot = dot
        }
        // Точка у выреза (полноэкранный): ждёт → оранжевая, ошибка → красная, только что закончил → зелёная.
        // «Закончил» — по переходу сессии в done (а не по состоянию: «готово» висит до следующего запроса).
        let nowDone = Set(s.filter { $0.status == .done }.map(\.id))
        if let fresh = s.first(where: { $0.status == .done && !doneIds.contains($0.id) }) { freshDone = fresh.project }
        if let f = freshDone, !s.contains(where: { $0.status == .done && $0.project == f }) { freshDone = nil }
        doneIds = nowDone
        let att = Self.attention(sessions: s, freshDone: freshDone)
        let attKey = att.map { "\($0.kind.rawValue)|\($0.text)" }
        if attKey != lastAttention {
            lastAttention = attKey
            ctx.setAttention(att?.kind, text: att?.text ?? "")
        }
        // Компакт: агент ждёт тебя — главная активность острова. Публикуем, только если поменялось видимое.
        // Пока висит карточка разрешения, активность остаётся: раскрытие острова вернёт её (вкладка «Агенты»).
        // Если уши назначены другому модулю, раскрытие откроет его вкладку (ядро: вкладка «хозяина» ушей), а
        // «ждёт» будет в капле — клик по ней поднимет активность или откроет «Агенты». Вкладку не перехватываем.
        let waiting = store.ordered.first { $0.isWaiting }
        let key = waiting.map { "\($0.id)|\($0.project)|\(store.waitingCount)|\(Self.compactLabel($0).text)" }
        if key != lastActivityKey {
            lastActivityKey = key
            if let w = waiting {
                ctx.post(Self.waitingActivity(w, count: store.waitingCount))
            } else {
                ctx.removeActivity(id: "agents.waiting")
            }
        }
        // Высота вкладки.
        let h = AgentsLayout.height(store: store)
        if abs(h - lastHeight) > 0.5 { lastHeight = h; ctx.invalidateLayout() }
        // Клавиатуру держим, только пока есть вопрос и вкладка открыта.
        if holdsKeyboard, !(store.hasPrompts && ctx.isTabVisible) { releaseKeyboard() }
        if !ctx.isTabVisible { autoOpened = autoOpened && store.hasPrompts }
    }

    /// Сколько знаков имени проекта показывать в ухе компакта.
    static let compactNameChars = 18

    /// Правое ухо: что именно ждёт — по типу запроса, без сырого текста: «правка файла», «команда», «вопрос»,
    /// «спрашивает», «план готов», «ждёт ответа».
    static func compactLabel(_ s: AgentSession) -> (text: String, symbol: String) {
        if let p = s.prompts.first {
            let a = p.presentation
            switch a.kind {
            case .question: return ("спрашивает", "questionmark.bubble.fill")
            case .plan: return ("план готов", "list.bullet.clipboard.fill")
            case .permission: return (ToolPreview.clip(a.category, 18), "hand.raised.fill")
            }
        }
        return ("ждёт ответа", "ellipsis.bubble.fill")
    }

    static func waitingActivity(_ s: AgentSession, count: Int) -> IslandActivity {
        let name = ProjectName.fit(s.project, max: compactNameChars)
        let label = compactLabel(s)
        let trailingText = count > 1 ? label.text + " · \(count)" : label.text
        // Ширина уха — по более длинной стороне (оценка: ~7,2 pt на знак 12,5 bold, значок 14 + отступ 6, поля 26).
        let lead = CGFloat(name.count) * 7.2 + 20 + 26
        let trail = CGFloat(trailingText.count) * 6.9 + 19 + 26
        let width = min(176, max(84, ceil(max(lead, trail))))
        let spoken = "\(s.agent.title), \(s.project): " + (s.waitingSummary ?? "ждёт ответа")
            + (count > 1 ? ", всего ждут \(count)" : "")
        return IslandActivity(id: "agents.waiting", moduleId: "agents", priority: 100, sideWidth: width,
                              glowColors: [IslandPalette.warn, IslandPalette.ok],
                              bubble: AnyView(AgentsMark(agent: s.agent))) {
            CompactLeading(project: name, agent: s.agent)
        } trailing: {
            CompactTrailing(text: trailingText, symbol: label.symbol)
        }
        .accessibility(spoken)
    }

    private func attention(_ s: AgentSession) {
        guard let ctx = context else { return }
        if !prefs.sound.isEmpty, Date().timeIntervalSince(lastSound) > 2 {
            lastSound = Date()
            if let snd = NSSound(named: NSSound.Name(prefs.sound))?.copy() as? NSSound {
                snd.volume = 0.45
                snd.play()
            }
        }
        if prefs.autoExpand, !ctx.isTabVisible {
            autoOpened = true
            ctx.openTab()
        }
        if prefs.grabKeyboard, store.hasPrompts {
            // Дать острову раскрыться, потом забрать ввод.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.wantKeyboard(true) }
            }
        }
    }

    private func promptsCleared() {
        releaseKeyboard()
        if autoOpened, let ctx = context, ctx.isTabVisible {
            autoOpened = false
            ctx.collapse()
        }
    }

    // MARK: - Действия вьюх

    func wantKeyboard(_ wants: Bool) {
        guard let ctx = context else { return }
        if wants {
            guard store.hasPrompts, ctx.isTabVisible else { return }
            if holdsKeyboard {
                // Держим, но панель уже не ключевая (щёлкнули в терминал, а уведомление не пришло) — перезапросить.
                guard let w = hostWindow, !w.isKeyWindow else { return }
                ctx.requestKeyboard(false)
            }
            holdsKeyboard = true
            ctx.requestKeyboard(true)
        } else {
            releaseKeyboard()
        }
    }

    /// Курсор ушёл с вкладки: ввод вернуть приложению пользователя — кроме набора причины отказа и режима
    /// «сразу забирать клавиатуру».
    func hoverEnded() {
        guard holdsKeyboard, !store.denyEditing, !prefs.grabKeyboard else { return }
        releaseKeyboard()
    }

    /// Панель перестала быть ключевой (пользователь щёлкнул в другое окно) — просьбу снять, иначе следующий
    /// заход курсора не вернёт ⌘↩ / ⌘⌫ / Esc: ядро не делает панель ключевой повторно, пока просьба висит.
    private func observeResignKey() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let w = hostWindow else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeyboard() }
        }
    }

    private func releaseKeyboard() {
        guard holdsKeyboard else { return }
        holdsKeyboard = false
        context?.requestKeyboard(false)
    }

    func decide(_ d: PermissionDecision) {
        store.decide(d)
    }

    /// «В терминал»: отпустить хук (Claude покажет свой диалог) и перейти во вкладку агента.
    func answerInTerminal(_ s: AgentSession) {
        store.decide(.terminal)
        jump(s)
    }

    func beginDeny() {
        store.denyEditing = true
        wantKeyboard(true)
    }

    func jump(_ s: AgentSession) {
        // Сессия из приложения Claude — открыть её саму, а не «поднять приложение» (27.11).
        if s.agent == .claude, s.term?.tty == nil, s.term?.bundleId == ClaudeDesktopLink.bundleId || s.term == nil {
            ClaudeDesktopLink.open(cliSession: s.sessionId) { [weak self] ok in
                guard let self, !ok else { return }
                if let t = s.term { self.jumpTerminal(t) }
                else { NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopLink.bundleId).first?.activate() }
            }
            return
        }
        guard let t = s.term else { return }
        jumpTerminal(t)
    }

    private func jumpTerminal(_ t: TermInfo) {
        TerminalJumper.jump(t) { [weak self] r in
            guard let self else { return }
            switch r {
            case .ok: self.store.jumpProblem = nil
            case .needsAutomation(let app):
                // Приложение-терминал уже поднято, но выбрать вкладку без права нельзя.
                self.store.jumpProblem = .init(app: app, message: "Вкладку не выбрать: нужно право «Автоматизация» для «\(app)»")
            case .failed(let msg):
                NSLog("SimpleIsland agents: прыжок в терминал не вышел: %@", msg)
            }
        }
    }

    func cycleSound() {
        let list = AgentsPrefs.sounds
        let i = list.firstIndex(of: prefs.sound) ?? -1
        prefs.sound = list[(i + 1) % list.count]
        if !prefs.sound.isEmpty, !isSnapshot { (NSSound(named: NSSound.Name(prefs.sound))?.copy() as? NSSound)?.play() }
    }

    // MARK: - Подключение агентов

    func refreshIntegration() {
        let home = AgentsPaths.home, bin = AgentsPaths.executablePath
        let claude = Installer.claudeStatus(home: home, bin: bin)
        let codex = Installer.codexStatus(home: home, bin: bin)
        if store.integration.claude != claude { store.integration.claude = claude }
        if store.integration.codex != codex { store.integration.codex = codex }
    }

    // MARK: - «Проверить» (AG2)

    /// Отправить тестовое событие тем же бинарём, что прописан в хуках (или собой, если хуков нет), и ждать его
    /// в сокете. Так видно и «не тот путь», и «сокет не слушает», и «старая версия по старому пути».
    func checkHooks() {
        guard !isSnapshot, context != nil else { return }
        finishProbe(.idle)
        ensureSocket()
        let own = AgentsPaths.executablePath
        let hooked = Installer.claudeHookBinary(home: AgentsPaths.home)
        let bin = hooked ?? own
        // Запускаем только SimpleIsland: путь берётся из файла настроек, чужой бинарь по нему не исполняем.
        guard (bin as NSString).lastPathComponent == "SimpleIsland" else {
            probe = .failed("по пути из хуков не SimpleIsland: \(HookCheckText.shortPath(bin)) — переподключи")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            probe = .failed("по пути из хуков нет SimpleIsland: \(bin) — переподключи")
            return
        }
        guard store.serverProblem == nil else { probe = .failed(store.serverProblem ?? "сокет не поднят"); return }
        let nonce = UUID().uuidString
        probeNonce = nonce
        probeStarted = Date()
        probe = .running
        // Окружение — наше: сокет тот же, что слушает остров (по умолчанию — путь, который знают хуки).
        let p = ManagedProcess(executable: bin, arguments: ["--hook", "ping", nonce], restart: .never)
        p.onExit = { [weak self] code in
            guard let self, self.probeNonce == nonce, code != 0 else { return }
            // Код 3 — некуда подключиться (сокета нет по пути по умолчанию), 4 — не записалось.
            self.finishProbe(.failed(code == 3 ? "хук не нашёл сокет \(AgentsPaths.socketDisplayPath)"
                                     : "хук завершился с кодом \(code)"))
        }
        probeProcess = p
        guard p.start() else { finishProbe(.failed("не запустить \(bin)")); return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.probeNonce == nonce else { return }
                self.finishProbe(.failed(hooked != nil && hooked != own
                    ? "по пути из хуков, видимо, старая версия SimpleIsland — переподключи"
                    : "ответа нет 3 с — сокет не принимает события"))
            }
        }
        probeTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func pingArrived(_ nonce: String) {
        guard nonce == probeNonce else { return }
        finishProbe(.ok(ms: Int(Date().timeIntervalSince(probeStarted) * 1000), at: Date()))
    }

    private func finishProbe(_ result: HookProbe) {
        probeTimeout?.cancel(); probeTimeout = nil
        probeNonce = nil
        if let p = probeProcess { p.onExit = nil; if p.isRunning { p.stop(grace: 0.5) } }
        probeProcess = nil
        if probe != result { probe = result }
    }

    func installClaude() { runInstaller { try Installer.installClaude(home: $0, bin: $1) } }
    func uninstallClaude() { runInstaller { home, _ in try Installer.uninstallClaude(home: home) } }
    func installCodex() { runInstaller { try Installer.installCodex(home: $0, bin: $1) } }
    func uninstallCodex() { runInstaller { home, _ in try Installer.uninstallCodex(home: home) } }

    private func runInstaller(_ f: (URL, String) throws -> Installer.Outcome) {
        guard !isSnapshot else { return }
        do {
            let o = try f(AgentsPaths.home, AgentsPaths.executablePath)
            installMessage = o.message + (o.backup.map { " · копия: \($0.lastPathComponent)" } ?? "")
        } catch {
            installMessage = "\(error)"
        }
        refreshIntegration()
    }

    /// Бинарь лежит в .build — хуки сломаются после очистки; предупредить в настройках.
    var binaryLooksTemporary: Bool {
        let p = AgentsPaths.executablePath
        return p.contains("/.build") || !p.contains(".app/")
    }
}

/// Значок агента: Claude — «искра», Codex — «</>».
struct AgentGlyph: View {
    var agent: AgentKind
    var size: CGFloat = 11.5
    var body: some View {
        Image(systemName: agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size, weight: .bold))
    }
}

/// Значок «агент ждёт» для отметки второй активности внутри уха (`IslandActivity.bubble`).
struct AgentsMark: View {
    var agent: AgentKind
    var body: some View {
        AgentGlyph(agent: agent, size: 10).foregroundStyle(IslandPalette.warn)
    }
}

/// Левое ухо компакта: значок агента (жёлтый — ждёт) + понятное имя проекта.
struct CompactLeading: View {
    var project: String
    var agent: AgentKind = .claude
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            AgentGlyph(agent: agent).foregroundStyle(IslandPalette.warmText(theme))
            Text(project).font(theme.font(12.5, .bold)).foregroundStyle(theme.primary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Правое ухо компакта: что ждёт — «правка файла», «вопрос», «ждёт ответа».
struct CompactTrailing: View {
    var text: String
    var symbol: String = "ellipsis.bubble.fill"
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(text).font(theme.font(12.5, .bold)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(IslandPalette.warmText(theme))
    }
}


/// Результат кнопки «Проверить».
enum HookProbe: Equatable {
    case idle
    case running
    case ok(ms: Int, at: Date)
    case failed(String)
}

/// Общие часы «N с назад» для вьюх модуля: одно обновление в секунду на все строки, и только пока видно
/// (тикает `SharedTicker`, подписку держит контроллер).
@MainActor
final class AgentsClock: ObservableObject {
    static let shared = AgentsClock()
    @Published var now = Date()
}

/// Держит раздел «Агенты» в настройках «открытым», пока жива вьюха (`@StateObject`). Окно настроек при закрытии
/// освобождает содержимое, но `onDisappear` у закрытого/скрытого окна SwiftUI не гарантирует — счётчик снимается в
/// deinit, и `SharedTicker` не будит приложение раз в секунду до перезапуска.
final class AgentsSettingsPresence: ObservableObject {
    private let release: @MainActor @Sendable () -> Void

    @MainActor init(_ controller: AgentsController) {
        // Не во время построения вьюхи (часы публикуют `now`) — следующим шагом главной очереди; снятие в deinit
        // идёт той же очередью, порядок «+1, −1» сохраняется.
        DispatchQueue.main.async { [weak controller] in MainActor.assumeIsolated { controller?.settingsViewers += 1 } }
        release = { [weak controller] in if let c = controller { c.settingsViewers = max(0, c.settingsViewers - 1) } }
    }

    deinit {
        let r = release
        DispatchQueue.main.async { MainActor.assumeIsolated { r() } }
    }
}
