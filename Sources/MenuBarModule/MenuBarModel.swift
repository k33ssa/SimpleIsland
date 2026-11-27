import AppKit
import ApplicationServices
import Combine
import IslandCore
import ScreenCaptureKit
import SwiftUI

/// Состояние и действия модуля «Строка меню»: инвентарь, назначения, разделитель, режим уборки, перенос.
///
/// Энергия: ничего не опрашивает в покое. Сканирует по событиям — запуск/выход приложения (NSWorkspace), экраны и
/// пробуждение (`onSystemEvent`), открытая вкладка; раз в секунду (SharedTicker) — только пока открыт режим уборки
/// или временно показан значок. Права: Универсальный доступ — при первом переносе (`ensurePermission`), «Запись
/// экрана» — только по кнопке «Показывать настоящие значки».
@MainActor
public final class MenuBarModel: ObservableObject {
    @Published public internal(set) var inventory: MenuBarInventory = .empty
    @Published public var prefs = MenuBarPrefs() {
        didSet { if prefs != oldValue { prefsChanged(from: oldValue) } }
    }
    @Published public internal(set) var axGranted = false
    @Published public internal(set) var screenGranted = false
    @Published public internal(set) var cleanupActive = false
    @Published public var cleanup = CleanupState()
    /// Строка состояния в оверлее и вкладке: «Переношу Ollama…», «Не вышло — …».
    @Published public internal(set) var status: String?
    /// Настоящие картинки значков (захват окна) по ключу.
    @Published public internal(set) var images: [String: NSImage] = [:]
    /// Только снимки: значки мок-приложений (SF Symbols вместо значков приложений).
    var mockSymbols: [String: String] = [:]

    weak var context: ModuleContext?
    let divider = MenuBarDivider()
    let mover = MenuBarMover()
    private var overlay: CleanupOverlayController?
    private(set) var tick: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var scanWork: DispatchWorkItem?
    private var statusWork: DispatchWorkItem?
    private var running = false
    var isRunning: Bool { running }
    private var loadingPrefs = false
    private var postedStack: String?
    /// Значок, временно вынесенный в строку, чтобы открыть его меню; `baseline` — окна приложения до нажатия
    /// (новое окно = открыт поповер/окно значка, не только NSMenu).
    /// `key` — ключ, под которым значок назначен (до переноса; у «#N» после переноса ключ другой — по нему
    /// и переносится назначение при возврате), `windowID` — сам значок.
    struct TempShown { var key: String; var windowID: CGWindowID; var pid: pid_t; var sawMenu: Bool; var since: Date
                       var baseline: Set<CGWindowID>
                       /// macOS 27: значок показан раскрытием системного overflow — прятать обратно сворачиванием.
                       var viaOverflow = false }
    var tempShown: TempShown?
    private var iconCache: [pid_t: NSImage] = [:]
    /// Поколение: растёт при «Вернуть всё», выключении и запуске. Отложенные шаги переноса/показа/сканов сверяют его
    /// и молча выходят, если пользователь успел всё сбросить (иначе разделитель пересоздался бы сам).
    private(set) var epoch = 0
    /// Сколько сканов сейчас в фоне: тик уборки не ставит новый, пока старый не вернулся.
    private(set) var scansInFlight = 0
    /// Раздел каждого значка на прошлом скане (по ключу) и уже показанные сообщения о «новых за разделителем».
    private var prevSections: [String: MenuBarSection]?
    private var announcedKeys: Set<String> = []
    /// Последнее предложение «Вернуть N значков в остров?» (не повторять то же).
    private var offeredRestore: String?
    /// Самотест: уведомления не показываются, а записываются сюда.
    var testNotifications: [IslandNotification]?
    /// Самотест: журнал шагов («hide <ключ>», «show <ключ>»).
    var testLog: [String]?
    /// Временный показ запущен, но значок ещё не в строке (идёт перенос): второй показ ждать не будет — отклоняется.
    private(set) var showInFlight = false

    static let stackActivityId = "menubar.stack"

    public init() {}

    // MARK: Жизненный цикл

    func start(context: ModuleContext) {
        self.context = context
        running = true
        epoch += 1
        prevSections = nil
        loadingPrefs = true
        prefs = context.loadSettings(MenuBarPrefs.self) ?? MenuBarPrefs()
        loadingPrefs = false
        refreshPermissions()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let launched = n.name == NSWorkspace.didLaunchApplicationNotification
                let bundle = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.appsChanged(launched: launched, bundleId: bundle) }
            })
        }
        // Назначения «до выхода приложения» (снята галочка «Помнить…»), чьи приложения уже не запущены, — забыть.
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        forgetUntilQuit { !runningBundles.contains($0) }
        MenuBarHotKey.shared.action = { [weak self] in self?.toggleCleanup() }
        applyHotKey()
        divider.onClick = { [weak self] in self?.context?.openTab() }
        if prefs.needsDivider {
            divider.ensure(preferredPosition: nil)
            divider.expand()
        }
        scheduleScan(after: 0.5)
        // Порядок после перезапуска мог сбиться (Ice #723) — предложить вернуть назначенное, когда строка устоится.
        let g = epoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { if self?.live(g) == true { self?.restore(reason: "запуск") } }
        }
    }

    /// Отложенный шаг ещё актуален: модуль работает и «Вернуть всё»/выключения не было.
    func live(_ g: Int) -> Bool { running && g == epoch }

    /// Сбросить всё отложенное: временный показ, окно ручного переноса, тикер, запланированный скан.
    private func cancelPending() {
        epoch += 1
        tempShown = nil
        manualUntil = nil
        showInFlight = false
        tempCheckInFlight = false
        scanWork?.cancel()
        if !cleanupActive { tick = nil }
        // Липкое «Переношу X…» после обрыва переноса не должно висеть.
        if statusSticky { statusSticky = false; status = nil; statusWork?.cancel() }
    }

    /// Снятая галочка «Помнить после перезапуска»: назначение живёт до выхода приложения.
    private func forgetUntilQuit(_ match: (String) -> Bool) {
        var p = prefs
        for key in p.noRestore {
            let bundle = String(key.split(separator: "|", maxSplits: 1).first ?? "")
            if match(bundle) { p.set(key, .bar) }
        }
        if p != prefs { prefs = p }
    }

    /// Выключение модуля / выход приложения: подписки снять, разделитель свернуть или убрать (всё снова видно). Быстро.
    /// `appExiting` — выход приложения: разделитель только сворачивается (12 pt, значки сразу видны), его окно
    /// исчезнет вместе с процессом, а запомненное системой место (autosaveName) остаётся — после запуска значки
    /// снова за ним. Выключили модуль — разделитель убирается совсем.
    func stopAll(appExiting: Bool = false) {
        exitCleanup()
        cancelPending()
        tick = nil
        MenuBarHotKey.shared.unregister()
        if appExiting { divider.collapse() } else { divider.remove(forgetPosition: false) }
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        context?.removeActivity(id: Self.stackActivityId)
        postedStack = nil
        running = false
    }

    func handleSystemEvent(_ e: IslandSystemEvent) {
        switch e {
        case .willSleep, .screensDidSleep, .screenLocked, .sessionDidResignActive:
            exitCleanup()
        case .screensChanged:
            divider.screensChanged()
            scheduleScan(after: 1)
        case .didWake, .screensDidWake, .screenUnlocked, .sessionDidBecomeActive:
            refreshPermissions()
            scheduleScan(after: 2)
        case .motionChanged: break
        }
    }

    func appsChanged(launched: Bool, bundleId: String?) {
        guard running else { return }
        if !launched, let b = bundleId { forgetUntilQuit { $0 == b } }
        scheduleScan(after: 1.5)
        // Приложение запустилось — его значок мог встать на старое место в строке: предложить вернуть в остров.
        if launched {
            let g = epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { if self?.live(g) == true { self?.restore(reason: "запуск приложения") } }
            }
        }
    }

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        if ax != axGranted { axGranted = ax }
        let sc = CGPreflightScreenCaptureAccess()
        if sc != screenGranted { screenGranted = sc }
    }

    // MARK: Настройки

    private func prefsChanged(from old: MenuBarPrefs) {
        guard !loadingPrefs else { return }
        context?.saveSettings(prefs)
        if old.hotKey != prefs.hotKey || old.hotKeyEnabled != prefs.hotKeyEnabled { applyHotKey() }
        if old.showStack != prefs.showStack || old.placements != prefs.placements { updateStack() }
        if !old.realIcons && prefs.realIcons { captureImages() }
        if !prefs.realIcons && !images.isEmpty { images = [:] }
    }

    func applyHotKey() {
        guard running else { return }
        MenuBarHotKey.shared.register(prefs.hotKeyEnabled ? prefs.hotKey : nil)
    }

    // MARK: Сканирование

    /// Сканировать только когда нужно: идёт уборка, открыта вкладка, показывается стопка или что-то спрятано.
    var wantsScans: Bool {
        running && (cleanupActive || context?.isTabVisible == true || prefs.showStack || prefs.needsDivider || tempShown != nil)
    }

    func scheduleScan(after delay: TimeInterval) {
        guard wantsScans else { return }
        scanWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scanNow() } }
        scanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Снимок строки меню: CGWindowList и AX — в фоне (AX зависшего приложения отвечает до 0,25 с на элемент), итог
    /// — на главном. Устаревший (был «Вернуть всё»/выключение) не применяется и `done` не зовётся.
    func scanNow(_ done: (@MainActor (MenuBarInventory) -> Void)? = nil) {
        guard running else { return }
        let g = epoch
        scanSeq += 1
        let n = scanSeq
        refreshPermissions()
        scansInFlight += 1
        MenuBarScanner.scan(dividerWindowID: divider.windowID, dividerLength: divider.length, dividerFrame: divider.cgFrame,
                            dividerExpanded: divider.isExpanded) { [weak self] inv in
            guard let self else { return }
            self.scansInFlight -= 1
            self.receiveScan(inv, seq: n, epoch: g, done: done)
        }
    }

    /// Номер последнего запущенного и последнего применённого скана: результат старше применённого не перезаписывает
    /// новый (сканер последовательный, но страховка — на случай гонки), его ждущий получает свежий инвентарь.
    private var scanSeq = 0
    private(set) var appliedSeq = 0

    func receiveScan(_ inv: MenuBarInventory, seq: Int, epoch g: Int, done: (@MainActor (MenuBarInventory) -> Void)?) {
        guard live(g) else { return }
        if seq < appliedSeq { done?(inventory); return }
        appliedSeq = seq
        apply(inv)
        done?(inv)
    }

    func apply(_ inv: MenuBarInventory) {
        let before = prevSections
        if inv != inventory { inventory = inv }
        var p = prefs
        Self.migrateKeys(&p, inv)   // до проверки «новых»: иначе значок со старым видом ключа сочли бы новым
        var fresh: [MenuBarItem] = []
        if let before, divider.exists {
            for it in inv.inIslandSection where p.placements[it.key] == nil && it.hasStableKey && before[it.key] != .island {
                if manualUntil != nil && !divider.isExpanded && before[it.key] != nil {
                    // Окно ручного переноса (черта видна): значок перетащил за неё пользователь — «в остров».
                    p.placements[it.key] = .island
                } else if !announcedKeys.contains(it.key) && !mover.isBusy && tempShown == nil
                            && !p.fromNotch.contains(it.key) && before[it.key] != .notch {
                    // (Из-под выреза за новый разделитель — ожидаемо: их и так не было видно; помечены «из-под выреза».)
                    // Сам оказался за разделителем (новый значок macOS ставит левее всех, приложение перезапустилось
                    // со старым местом) — не прячем молча, сообщаем.
                    fresh.append(it)
                }
            }
        }
        prevSections = Dictionary(inv.items.map { ($0.key, $0.section) }, uniquingKeysWith: { a, _ in a })
        for it in inv.items where p.placements[it.key] != nil && p.names[it.key] != it.displayName {
            p.names[it.key] = it.displayName
        }
        if p != prefs { prefs = p }
        updateStack()
        if !fresh.isEmpty { announceFresh(fresh) }
        // Назначенное «в остров»/«спрятать» снова видно в строке (25.11: «часто спрятанные выскакивают» — на macOS 27
        // строка перестраивается сама: перезапуск приложения, освободилось место) — вернуть молча, после паузы.
        let escaped = inv.items.contains { p.placement($0.key) != .bar && $0.section == .visible && !p.noRestore.contains($0.key) }
        if escaped { scheduleRestore() }
        // Пока что-то назначено — изредка смотреть строку: macOS 27 выпускает значки без событий, которые мы слышим.
        if p.needsDivider { scheduleScan(after: 20) }
    }

    private var restoreWork: DispatchWorkItem?
    private func scheduleRestore() {
        guard restoreWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restoreWork = nil; self?.restore(reason: "выскочил в строку") }
        }
        restoreWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// Миграция ключей (один раз — старая запись уходит): назначение под ключом, которого в строке нет, переезжает на
    /// значок того же приложения, у которого это один из видов ключа (имя окна ↔ «#N» при включении/выключении
    /// «Записи экрана», старые «#N»), а у приложения с одним значком — на него. Занятые ключи не трогаем.
    static func migrateKeys(_ p: inout MenuBarPrefs, _ inv: MenuBarInventory) {
        var known = Set(inv.items.map(\.key))
        for (old, placement) in p.placements.sorted(by: { $0.key < $1.key }) where !known.contains(old) {
            guard let bar = old.firstIndex(of: "|") else { continue }
            let owner = String(old[..<bar])
            let same = inv.items.filter { $0.key.hasPrefix(owner + "|") }
            guard let target = same.first(where: { $0.altKeys.contains(old) }) ?? (same.count == 1 ? same.first : nil),
                  p.placements[target.key] == nil else { continue }
            p.placements[old] = nil
            p.placements[target.key] = placement
            p.names[target.key] = p.names[old] ?? target.displayName
            p.names[old] = nil
            if p.noRestore.contains(old) { p.noRestore.removeAll { $0 == old }; p.noRestore.append(target.key) }
            if p.fromNotch.contains(old) { p.fromNotch.removeAll { $0 == old }; p.fromNotch.append(target.key) }
            known.insert(target.key)
        }
    }

    /// «Telegram оказался за разделителем» — с кнопкой «Вернуть в строку». Один раз на значок за запуск.
    private func announceFresh(_ items: [MenuBarItem]) {
        for it in items { announcedKeys.insert(it.key) }
        let names = items.prefix(3).map(\.displayName).joined(separator: ", ")
        let body = items.count == 1
            ? "\(names) оказался за разделителем — сейчас он во вкладке «Значки»."
            : "\(names)\(items.count > 3 ? " и ещё \(items.count - 3)" : "") — за разделителем, сейчас во вкладке «Значки»."
        let keys = items.map(\.key)
        let g = epoch
        // Кнопки — только для того же «поколения» и для значков, которые всё ещё без назначения и за разделителем
        // (после «Вернуть всё» или ручных правок кнопка ничего не делает).
        let stillFresh: @MainActor (MenuBarModel) -> [String] = { m in
            keys.filter { m.prefs.placements[$0] == nil && m.inventory.item(key: $0)?.section == .island }
        }
        notify(IslandNotification(moduleId: MenuBarIslandModule.moduleId, title: "Строка меню", body: body,
                                  systemImage: "menubar.rectangle",
                                  actions: [IslandNotificationAction("Вернуть в строку", role: .primary) { [weak self] in
                                      guard let self, self.live(g) else { return }
                                      self.returnAll(stillFresh(self))
                                  }, IslandNotificationAction("Оставить") { [weak self] in
                                      guard let self, self.live(g) else { return }
                                      for k in stillFresh(self) {
                                          self.prefs.set(k, .island, name: self.inventory.item(key: k)?.displayName)
                                      }
                                  }], duration: 15, opensTab: MenuBarIslandModule.moduleId))
    }

    private func returnAll(_ keys: [String]) {
        guard let first = keys.first else { return }
        returnToBar(first) { [weak self] in self?.returnAll(Array(keys.dropFirst())) }
    }

    func notify(_ n: IslandNotification) {
        if testNotifications != nil { testNotifications?.append(n); return }
        context?.showNotification(n)
    }

    // MARK: Режим уборки

    /// Токен удержания острова в покое на время режима уборки (`ModuleContext.holdCollapsed`).
    static let cleanupHoldToken = "cleanup"

    func toggleCleanup() { cleanupActive ? exitCleanup() : startCleanup() }

    func startCleanup() {
        guard running, !cleanupActive, let ctx = context else { return }
        // macOS 27: без Универсального доступа значков не видно вовсе — уборке нечего показать, сразу спросить право.
        if MenuBarAgent.isActive && !axGranted { askAccessibility(); return }
        cleanupActive = true
        cleanup = CleanupState()
        ctx.collapse()
        // Остров на время уборки — ровно вырез: уши, компакт и раскрытие закрывали значки справа от выреза (15.11).
        ctx.holdCollapsed(Self.cleanupHoldToken)
        scanNow { [weak self] _ in
            guard let self, self.cleanupActive else { return }
            if self.overlay == nil { self.overlay = CleanupOverlayController(model: self) }
            self.overlay?.show()
        }
        tick = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in self?.onTick() }
    }

    func exitCleanup() {
        guard cleanupActive else { return }
        cleanupActive = false
        cleanup = CleanupState()
        context?.releaseCollapsed(Self.cleanupHoldToken)
        overlay?.close()
        overlay = nil
        if tempShown == nil && manualUntil == nil { tick = nil }
    }

    func onTick() {
        if (cleanupActive || manualUntil != nil) && !mover.isBusy && scansInFlight == 0 { scanNow() }
        watchTempShown()
        if let until = manualUntil, Date() >= until {
            manualUntil = nil
            if !mover.isBusy && divider.exists { divider.expand(); scanNow() }
            if !cleanupActive && tempShown == nil { tick = nil }
        }
    }

    /// Перенос не удался: разделитель остаётся свёрнутым (тонкая черта видна) 30 с —
    /// значок можно ⌘-перетащить за черту руками, скан раз в секунду это подхватит.
    var manualUntil: Date?

    private func startManualWindow() {
        guard divider.exists else { return }
        divider.collapse()
        manualUntil = Date().addingTimeInterval(30)
        if tick == nil { tick = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in self?.onTick() } }
    }

    /// Порядок значков для ←/→ в режиме уборки: видимые слева направо, затем под вырезом.
    var cleanupOrder: [String] {
        inventory.visible.sorted { $0.frame.minX < $1.frame.minX }.map(\.key) + inventory.underNotch.map(\.key)
    }

    func card(for key: String) -> CleanupCard? {
        inventory.item(key: key).map { CleanupCard.make(for: $0, axGranted: axGranted) }
    }

    /// Клавиша в режиме уборки (код kVK). true — обработана. Автоповтор (`isRepeat`) — только у стрелок и Tab:
    /// зажатый ⏎ не должен проскочить второе подтверждение «Выйти».
    func handleKey(_ code: UInt16, isRepeat: Bool = false) -> Bool {
        guard let key = CleanupKeys.key(forKeyCode: code) else { return false }
        if isRepeat && !CleanupKeys.repeatable(key) { return true }
        var st = cleanup
        let cmd = CleanupKeys.handle(key, state: &st, order: cleanupOrder) { [weak self] k in self?.card(for: k) }
        if st != cleanup { cleanup = st }
        run(cmd)
        return true
    }

    func click(_ key: String) {
        var st = cleanup
        CleanupKeys.click(key, state: &st)
        cleanup = st
    }

    func hover(_ key: String?) {
        guard cleanup.hoveredKey != key, !cleanup.cardOpen else { return }
        cleanup.hoveredKey = key
    }

    /// Щелчок мимо значков: открыта карточка — закрыть, нет — выйти из режима.
    func backgroundClick() {
        if cleanup.cardOpen { cleanup.selectedKey = nil; cleanup.confirmingQuit = false } else { exitCleanup() }
    }

    func choose(_ index: Int) {
        guard let sel = cleanup.selectedKey, let c = card(for: sel), c.options.indices.contains(index) else { return }
        cleanup.optionIndex = index
        _ = handleKey(36)
    }

    func run(_ cmd: CleanupCommand) {
        switch cmd {
        case .none: break
        case .exit: exitCleanup()
        case .perform(let key, let option, let remember):
            guard let item = inventory.item(key: key) else { return }
            perform(option, on: item, remember: remember)
        }
    }

    // MARK: Действия

    func perform(_ option: CleanupOption, on item: MenuBarItem, remember: Bool) {
        cleanup.selectedKey = nil
        cleanup.confirmingQuit = false
        switch option {
        case .quit:
            exitCleanup()
            let ok = NSRunningApplication(processIdentifier: item.pid)?.terminate() ?? false
            flash(ok ? "\(item.displayName): выхожу из приложения" : "\(item.displayName) не закрылось — закрой его сам")
            scheduleScan(after: 1.5)
        case .systemSettings(let pane):
            exitCleanup()
            NSWorkspace.shared.open(pane.url)
            notify(IslandNotification(
                moduleId: MenuBarIslandModule.moduleId, title: pane == .keyboard ? "Клавиатура" : "Пункт управления",
                body: Self.settingsHint(item, pane: pane), systemImage: pane == .keyboard ? "keyboard" : "switch.2",
                duration: 12))
        case .toIsland, .hide:
            let placement: MenuBarPlacement = option == .hide ? .hidden : .island
            guard axGranted else { askAccessibility(); return }
            prefs.set(item.key, placement, name: item.displayName, remember: remember)
            if item.section == .island { flash(Self.doneText(item, placement)); return }
            flash("Переношу \(item.displayName)…", sticky: true)
            moveIntoHidden(key: item.key, allowCreate: true) { [weak self] ok in
                guard let self, self.running else { return }
                if ok { self.flash(Self.doneText(item, placement)) }
                else {
                    self.prefs.set(item.key, .bar)
                    switch self.mover.lastFailure {
                    case .noAccess?, .inputBusy?, .busy?:
                        // Причина известна и не в macOS: сказать её (нет доступа — спросить его), без окна переноса.
                        self.reportMoveFailure(name: item.displayName, verb: "перенести", item: item, sent: false)
                    default:
                        self.startManualWindow()
                        if item.isSystem && CleanupCard.settingsPane(item) != nil {
                            self.reportMoveFailure(name: item.displayName, verb: "перенести", item: item, sent: true)
                        } else if self.agentMode {
                            self.flash(Self.agentMoveFailedText(item.displayName), seconds: 10)
                        } else {
                            self.flash("Не вышло перенести \(item.displayName). Перетащи значок с ⌘ левее тонкой черты-разделителя (30 с) — я подхвачу сам.", seconds: 8)
                        }
                    }
                }
            }
        }
    }

    static func doneText(_ item: MenuBarItem, _ p: MenuBarPlacement) -> String {
        p == .hidden ? "\(item.displayName) спрятан — вернуть можно в настройках" : "\(item.displayName) теперь в острове"
    }

    static func settingsHint(_ item: MenuBarItem, pane: MenuBarSettingsPane) -> String {
        switch pane {
        case .keyboard:
            return "Источники ввода → выключи «Показывать меню ввода в строке меню»."
        case .controlCenter:
            if !item.isMovable { return "\(item.displayName): здесь меняется вид. Убрать сам значок macOS не даёт." }
            return "Найди «\(item.displayName)» и выбери «Не показывать в строке меню»."
        }
    }

    /// Нет Универсального доступа: выйти из уборки и спросить через ядро (системное окно или карточка «Нужен доступ»).
    func askAccessibility() {
        exitCleanup()
        guard let ctx = context else { return }
        Task { @MainActor [weak self] in
            let st = await ctx.ensurePermission(.accessibility, reason: "Переносить значки строки меню в остров")
            self?.refreshPermissions()
            if st != .granted {
                self?.flash("Нужен Универсальный доступ: без него значки строки меню не переносятся", seconds: 6)
            }
        }
    }

    /// Перенести значок за разделитель. Две попытки, итог — по рамкам; значок отслеживается по номеру окна (ключ
    /// «#N» у второго значка приложения при переносе меняется — после удачи назначение переезжает на новый ключ).
    /// Разделитель создаётся только по явному действию (`allowCreate`, первая попытка), не из повтора/фона.
    /// Каждый отложенный шаг сверяет поколение: «Вернуть всё» или выключение посреди переноса его обрывают.
    func moveIntoHidden(key: String, windowID: CGWindowID? = nil, attempt: Int = 1, allowCreate: Bool = false,
                        typingPause: TimeInterval = 0, completion: @escaping @MainActor (Bool) -> Void) {
        testLog?.append("hide \(key)")
        guard running else { completion(false); return }
        if agentMode {
            agentMoveIntoHidden(key: key, windowID: windowID, allowCreate: allowCreate, typingPause: typingPause,
                                completion: completion)
            return
        }
        if !divider.exists {
            guard allowCreate && attempt == 1 else { completion(false); return }
            let pos = MenuBarPlanner.dividerPreferredPosition(inventory, screenMaxX: MenuBarScanner.mainScreenMaxX)
            // Что прячет вырез, окажется левее нового разделителя — помечаем «из-под выреза».
            prefs.fromNotch = Array(Set(prefs.fromNotch + inventory.underNotch.map(\.key)))
            divider.ensure(preferredPosition: pos)
        }
        let g = epoch
        let wid = windowID ?? inventory.item(key: key)?.windowID
        if attempt == 1 && !mover.isBusy { mover.lastFailure = nil }
        divider.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live(g) else { return }
                self.scanNow { inv in
                    let find = { (i: MenuBarInventory) in wid.flatMap { w in i.items.first { $0.windowID == w } } ?? i.item(key: key) }
                    guard let item = find(inv), let dWin = self.divider.windowID, let dFrame = inv.dividerFrame else {
                        self.divider.expand(); completion(false); return
                    }
                    if item.section == .island { self.finishMove(key: key, newKey: item.key, ok: true, completion); return }
                    // Первая попытка — нажатие вне экрана (где значок — не важно), вторая — «как человек» из центра
                    // значка, если он на экране и не под вырезом.
                    let style: MenuBarMover.Style = attempt > 1 && item.section == .visible ? .direct : .offscreen
                    self.mover.drag(itemWindow: item.windowID, pid: item.pid, item: item.frame, targetWindow: dWin,
                                    target: dFrame, side: .leftOf, style: style, typingPause: typingPause,
                                    isCancelled: { [weak self] in self?.live(g) != true }) { sent in
                        guard self.live(g) else { return }
                        self.scanNow { after in
                            let moved = find(after)
                            let ok = moved?.section == .island
                            if !ok && sent && attempt < 2 {
                                self.moveIntoHidden(key: key, windowID: wid, attempt: attempt + 1,
                                                    typingPause: typingPause, completion: completion)
                                return
                            }
                            self.finishMove(key: key, newKey: moved?.key ?? key, ok: ok, completion)
                        }
                    }
                }
            }
        }
    }

    func finishMove(key: String, newKey: String, ok: Bool, _ completion: @MainActor (Bool) -> Void) {
        if ok, newKey != key, let p = prefs.placements[key] {
            var q = prefs
            q.placements[key] = nil
            q.placements[newKey] = p
            q.names[newKey] = q.names[key]
            q.names[key] = nil
            prefs = q
        }
        divider.expand()
        scanNow()
        completion(ok)
    }

    /// Вернуть значок в строку меню (правее разделителя).
    func returnToBar(_ key: String, then next: (@MainActor () -> Void)? = nil) {
        let name = inventory.item(key: key)?.displayName ?? prefs.names[key] ?? "Значок"
        guard let item = inventory.item(key: key), item.section == .island else {
            prefs.set(key, .bar)
            finishIfEmpty()
            if inventory.item(key: key)?.section == .notch {
                flash("\(name) и так в строке меню, но macOS прячет его под вырезом — убери другие значки, чтобы он поместился",
                      seconds: 6)
            } else {
                flash("\(name) — снова в строке меню")
            }
            next?()
            return
        }
        guard axGranted else { askAccessibility(); return }
        prefs.set(key, .bar)
        if agentMode { agentReturnToBar(item, name: name, then: next); return }
        let g = epoch
        let wid = item.windowID
        divider.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live(g) else { return }
                self.scanNow { inv in
                    guard let it = inv.items.first(where: { $0.windowID == wid }), let dWin = self.divider.windowID,
                          let dFrame = inv.dividerFrame else {
                        self.divider.expand(); next?(); return
                    }
                    self.mover.drag(itemWindow: it.windowID, pid: it.pid, item: it.frame, targetWindow: dWin,
                                    target: dFrame, side: .rightOf,
                                    isCancelled: { [weak self] in self?.live(g) != true }) { sent in
                        guard self.live(g) else { return }
                        self.scanNow { after in
                            let ok = after.items.first { $0.windowID == wid }?.section != .island
                            self.divider.expand()
                            self.finishIfEmpty()
                            self.scanNow()
                            if ok { self.flash("\(name) — снова в строке меню") }
                            else if !sent { self.reportMoveFailure(name: name, verb: "вернуть", item: it, sent: false) }
                            else { self.flash("Не вышло вернуть \(name). Перетащи его с ⌘ правее черты-разделителя.", seconds: 8) }
                            next?()
                        }
                    }
                }
            }
        }
    }

    /// Назначение из настроек: «в строке» — вернуть, «в острове»/«спрятан» — перенести (или только пометить, если
    /// значок уже за разделителем либо приложение не запущено).
    func setPlacement(_ key: String, _ p: MenuBarPlacement) {
        guard prefs.placement(key) != p else { return }
        let item = inventory.item(key: key)
        switch p {
        case .bar:
            returnToBar(key)
        case .island, .hidden:
            if let item, item.section != .island { perform(p == .hidden ? .hide : .toIsland, on: item, remember: true) }
            else { prefs.set(key, p, name: item?.displayName) }
        }
    }

    /// Ничего не спрятано — разделитель не нужен.
    private func finishIfEmpty() {
        if !prefs.needsDivider && inventory.inIslandSection.isEmpty { divider.remove(forgetPosition: false) }
    }

    /// «Вернуть всё как было»: разделитель убрать — все значки снова в строке (без событий и без прав, надёжно);
    /// назначения и запомненное место разделителя — стереть. Всё отложенное (перенос, временный показ, окно
    /// ручного переноса) обрывается — разделитель сам не вернётся.
    func resetAll() {
        exitCleanup()
        cancelPending()
        prefs.resetPlacements()
        divider.remove(forgetPosition: true)
        images = [:]
        offeredRestore = nil
        announcedKeys = []
        prevSections = nil
        scheduleScan(after: 0.5)
        flash("Всё вернули: разделителя нет, значки снова в строке меню")
    }

    /// Назначенное «в остров» снова в строке (после запуска приложения или своего): **сами не переносим** —
    /// предлагаем уведомлением «Вернуть N значков в остров?», перенос — по кнопке. Только с Универсальным доступом,
    /// не во время уборки, переноса и временного показа; одно и то же не предлагается дважды за запуск.
    func restore(reason: String) {
        guard running, prefs.restoreOnLaunch, prefs.needsDivider, axGranted, !cleanupActive, !mover.isBusy,
              tempShown == nil, manualUntil == nil else {
            NSLog("SimpleIsland: строка меню — возврат (%@) пропущен: running=%d remember=%d divider=%d ax=%d cleanup=%d busy=%d temp=%d manual=%d",
                  reason, running, prefs.restoreOnLaunch, prefs.needsDivider, axGranted, cleanupActive, mover.isBusy,
                  tempShown != nil, manualUntil != nil)
            return
        }
        scanNow { [weak self] inv in
            guard let self else { return }
            let n = MenuBarPlanner.reconcile(inv, self.prefs).moves.filter { $0.direction == .intoHidden }.count
            NSLog("SimpleIsland: строка меню — проверка возврата (%@): к переносу %d", reason, n)
            if ProcessInfo.processInfo.environment["SIMPLEISLAND_MB_DEBUG"] == "1" {
                for it in inv.items {
                    NSLog("SimpleIsland: mbdbg %@ key=%@ stable=%d movable=%d section=%@ place=%@", it.displayName, it.key,
                          it.hasStableKey, it.isMovable, "\(it.section)", "\(self.prefs.placements[it.key].map { "\($0)" } ?? "-")")
                }
                NSLog("SimpleIsland: mbdbg placements %@", "\(self.prefs.placements)")
            }
            self.offerRestore(inv, reason: reason)
        }
    }

    /// Уведомление «Вернуть N значков в остров?» по снимку `inv`. true — показано.
    @discardableResult
    func offerRestore(_ inv: MenuBarInventory, reason: String) -> Bool {
        let all = MenuBarPlanner.reconcile(inv, prefs).moves.filter { $0.direction == .intoHidden }.map(\.key)
        // Уже раз подтверждённые — молча, без уведомления (перенос всё равно ждёт паузы в наборе текста).
        // Всё назначенное «в остров» возвращается молча (25.11): спрашивать при каждом выскакивании — шум; не трогаем
        // только то, где снята галочка «Помнить место» (`noRestore`).
        let auto = all.filter { !prefs.noRestore.contains($0) }
        if !auto.isEmpty {
            NSLog("SimpleIsland: строка меню — молча возвращаю в остров %d (%@)", auto.count, reason)
            runMoves(Array(auto.prefix(6)))
        }
        let keys = all.filter { !auto.contains($0) && !prefs.noRestore.contains($0) }
        let sig = keys.sorted().joined(separator: ",")
        guard !keys.isEmpty, sig != offeredRestore else { return !auto.isEmpty }
        offeredRestore = sig
        let g = epoch
        let names = keys.prefix(3).compactMap { inv.item(key: $0)?.displayName }.joined(separator: ", ")
        NSLog("SimpleIsland: строка меню — предлагаю вернуть в остров %d (%@)", keys.count, reason)
        notify(IslandNotification(
            moduleId: MenuBarIslandModule.moduleId, title: "Вернуть \(MenuBarText.icons(keys.count)) в остров?",
            body: names + (keys.count > 3 ? " и ещё \(keys.count - 3)" : "") + " снова в строке меню. Дальше — без вопроса.",
            systemImage: "menubar.rectangle",
            actions: [IslandNotificationAction("Вернуть", role: .primary) { [weak self] in
                guard let self, self.live(g) else { return }
                // Только то, что всё ещё назначено «в остров»/«спрятан» (могли вернуть в строку или сбросить).
                let still = keys.filter { self.prefs.placement($0) != .bar }
                // Больше не спрашивать про эти значки — возвращать молча.
                self.prefs.autoRestore = Array(Set(self.prefs.autoRestore + still)).sorted()
                self.runMoves(Array(still.prefix(6)))
            },
            IslandNotificationAction("Оставить в строке") { [weak self] in
                guard let self, self.live(g) else { return }
                for k in keys { self.setPlacement(k, .bar) }
            }], duration: 15))
        return true
    }

    /// Перенос по кнопке «Вернуть»: ждём паузы в наборе текста ≥ 2 с, чтобы ⌘ не попал в чужой ввод.
    func runMoves(_ keys: [String], epoch g: Int? = nil) {
        let g = g ?? epoch
        guard live(g), let first = keys.first, prefs.placement(first) != .bar else {
            if live(g), keys.count > 1 { runMoves(Array(keys.dropFirst()), epoch: g) }
            return
        }
        moveIntoHidden(key: first, allowCreate: true, typingPause: 2) { [weak self] _ in
            guard let self, self.live(g) else { return }   // «Вернуть всё» посреди — дальше не переносить
            self.runMoves(Array(keys.dropFirst()), epoch: g)
        }
    }

    // MARK: Значок из острова

    /// Щелчок по значку во вкладке: открыть его меню. Виден или под вырезом — AXPress на месте (под вырезом не
    /// открылось — временный показ); за разделителем — временно вынести в строку, нажать, после закрытия меню
    /// (или окна-поповера) — спрятать обратно. Без Универсального доступа — открыть приложение.
    func open(_ item: MenuBarItem) {
        context?.collapse()
        guard axGranted else {
            NSRunningApplication(processIdentifier: item.pid)?.activate()
            flash("Без Универсального доступа меню значка не открыть — открыл \(item.displayName)", seconds: 5)
            return
        }
        // Один временный показ за раз: идёт перенос — отклонить; показан другой — сначала спрятать его.
        if showInFlight { flash("Подожди секунду — ещё показываю прошлый значок"); return }
        if let prev = tempShown, prev.windowID != item.windowID {
            tempShown = nil
            showInFlight = true
            let g = epoch
            moveIntoHidden(key: prev.key, windowID: prev.windowID) { [weak self] _ in
                guard let self, self.live(g) else { return }
                self.showInFlight = false
                self.open(item)
            }
            return
        }
        if tempShown?.windowID == item.windowID { return }
        let pid = item.pid, frame = item.frame, key = item.key, section = item.section
        // За развёрнутым разделителем значок в тысячах pt за краем экрана: AXPress открыл бы меню там же (или
        // невидимым и с захватом мыши) — сразу временный показ в строке. Под вырезом и видимый — AXPress на месте.
        if agentMode && item.section != .visible { agentShowFromOverflow(item); return }
        if section == .island { temporarilyShow(key: key); return }
        let g = epoch
        DispatchQueue.global(qos: .userInitiated).async {
            let pressed = MenuBarMover.press(pid: pid, frame: frame)
            Thread.sleep(forTimeInterval: 0.5)
            let menu = pressed && MenuBarScanner.hasOpenMenu(pid: pid)   // CGWindowList — тоже в фоне
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.live(g) else { return }
                    if pressed && (section == .visible || menu) { return }
                    if section == .visible { NSRunningApplication(processIdentifier: pid)?.activate(); return }
                    self.temporarilyShow(key: key)
                }
            }
        }
    }

    /// Временный показ: значок (за разделителем или под вырезом) переносится **без сворачивания разделителя** левее
    /// подходящего видимого значка (`MenuBarPlanner.showTarget`: справа от выреза, чтобы точно был виден), потом
    /// AXPress (окна до нажатия и AX — в фоне). Перенос — нажатием вне экрана (`MenuBarMover.Style.offscreen`): где
    /// значок сейчас, не важно. Прежде (до 15.11) разделитель сворачивался — спрятанные вставали в строку, крайние
    /// уходили под вырез, и перетаскивание из-под выреза попадало в остров: «Не вышло показать eqMac в строке меню».
    func temporarilyShow(key: String) {
        guard let item = inventory.item(key: key), item.isMovable, !showInFlight, tempShown == nil else { return }
        testLog?.append("show \(key)")
        let g = epoch, wid = item.windowID, name = item.displayName, pid0 = item.pid
        showInFlight = true
        let fail: @MainActor () -> Void = { [weak self] in self?.showInFlight = false }
        // Свежий скан: остров только что свернулся, рамки могли сдвинуться.
        scanNow { [weak self] inv in
            guard let self, self.live(g) else { fail(); return }
            guard let cur = inv.items.first(where: { $0.windowID == wid }) else {
                fail()
                self.flash("\(name) пропал из строки меню — приложение закрылось?", seconds: 5)
                return
            }
            guard let target = MenuBarPlanner.showTarget(for: cur, in: inv, leftLimit: MenuBarScanner.notchRect()?.maxX) else {
                fail()
                NSRunningApplication(processIdentifier: pid0)?.activate()
                self.flash("Не вышло показать \(name): в строке меню нет значка, рядом с которым его можно поставить — открыл приложение",
                           seconds: 6)
                return
            }
            self.showMove(cur: cur, target: target, key: key, name: name, attempt: 1, g: g, fail: fail)
        }
    }

    /// Шаг временного показа: перенести, проверить по рамкам, при неудаче — вторая попытка, потом честное сообщение.
    private func showMove(cur: MenuBarItem, target: MenuBarItem, key: String, name: String, attempt: Int, g: Int,
                          fail: @escaping @MainActor () -> Void) {
        let wid = cur.windowID
        let style: MenuBarMover.Style = attempt > 1 && cur.section == .visible ? .direct : .offscreen
        mover.drag(itemWindow: cur.windowID, pid: cur.pid, item: cur.frame, targetWindow: target.windowID,
                   target: target.frame, side: .leftOf, style: style,
                   isCancelled: { [weak self] in self?.live(g) != true }) { [weak self] sent in
            guard let self, self.live(g) else { fail(); return }
            guard sent else {
                fail()
                self.reportMoveFailure(name: name, verb: "показать", item: cur, sent: false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard self.live(g) else { fail(); return }
                    self.scanNow { inv2 in
                        guard let shown = inv2.items.first(where: { $0.windowID == wid }), shown.section == .visible else {
                            if attempt < 2, let again = inv2.items.first(where: { $0.windowID == wid }),
                               let t2 = MenuBarPlanner.showTarget(for: again, in: inv2,
                                                                  leftLimit: MenuBarScanner.notchRect()?.maxX) {
                                self.showMove(cur: again, target: t2, key: key, name: name, attempt: attempt + 1, g: g,
                                              fail: fail)
                                return
                            }
                            fail()
                            self.reportMoveFailure(name: name, verb: "показать", item: cur, sent: true)
                            return
                        }
                        fail()
                        let pid = shown.pid, frame = shown.frame
                        // Назначение висит на исходном ключе `key` — его и храним (п. 2 ревью).
                        self.tempShown = TempShown(key: key, windowID: wid, pid: pid, sawMenu: false,
                                                   since: Date(), baseline: [])
                        if self.tick == nil {
                            self.tick = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in self?.onTick() }
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let baseline = MenuBarScanner.openWindows(pid: pid)   // до нажатия
                            _ = MenuBarMover.press(pid: pid, frame: frame)
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if self.tempShown?.windowID == wid { self.tempShown?.baseline = baseline }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Текст неудачи переноса — с причиной и тем, что делать. `sent` — события ушли, но значок не сдвинулся.
    static func moveFailureText(name: String, verb: String, failure: MenuBarMover.Failure?, sent: Bool,
                                isSystem: Bool, canSettings: Bool) -> String? {
        if !sent {
            switch failure {
            case .noAccess?:
                return "Не вышло \(verb) \(name): у SimpleIsland нет Универсального доступа. Включи его: Системные настройки → Конфиденциальность и безопасность → Универсальный доступ"
            case .inputBusy?:
                return "Не вышло \(verb) \(name): были зажаты клавиши или кнопка мыши. Отпусти их и попробуй ещё раз"
            case .busy?:
                return "Не вышло \(verb) \(name): ещё идёт прошлый перенос — попробуй через секунду"
            case .cancelled?, nil:
                return nil
            }
        }
        if isSystem && canSettings {
            return "Не вышло \(verb) \(name): macOS не дала переставить системный значок. Его можно выключить в Пункте управления"
        }
        return "Не вышло \(verb) \(name): macOS не переставила значок. Попробуй ещё раз или перетащи его с ⌘ сам"
    }

    /// Сообщить о неудаче переноса. Нет Универсального доступа — спросить его (карточка ядра ведёт в настройки);
    /// системный значок — кнопка «Открыть Пункт управления» (сами в чужих настройках ничего не меняем).
    func reportMoveFailure(name: String, verb: String, item: MenuBarItem, sent: Bool) {
        let pane = CleanupCard.settingsPane(item)
        guard let text = Self.moveFailureText(name: name, verb: verb, failure: sent ? nil : mover.lastFailure, sent: sent,
                                              isSystem: item.isSystem, canSettings: pane != nil) else { return }
        if !sent && mover.lastFailure == .noAccess {
            refreshPermissions()
            flash(text, seconds: 6)
            askAccessibility()
            return
        }
        if sent, item.isSystem, let pane {
            status = text
            notify(IslandNotification(
                moduleId: MenuBarIslandModule.moduleId, title: "Строка меню", body: text, systemImage: "menubar.rectangle",
                actions: [IslandNotificationAction(pane == .keyboard ? "Открыть Клавиатуру" : "Открыть Пункт управления",
                                                   role: .primary) { [weak self] in
                    NSWorkspace.shared.open(pane.url)
                    self?.notify(IslandNotification(
                        moduleId: MenuBarIslandModule.moduleId,
                        title: pane == .keyboard ? "Клавиатура" : "Пункт управления",
                        body: Self.settingsHint(item, pane: pane), systemImage: pane == .keyboard ? "keyboard" : "switch.2",
                        duration: 12))
                }], duration: 12))
            return
        }
        flash(text, seconds: 6)
    }

    /// Раз в секунду, пока значок временно в строке: открыто ли его меню **или** новое окно (поповер
    /// MenuBarExtra(.window), панель) — то, чего не было до нажатия (CGWindowList — в фоне). Закрылось (или так и не
    /// открылось за 4 с, или прошло 10 минут) — спрятать обратно по исходному ключу и номеру окна. Разделитель
    /// здесь не создаётся.
    private var tempCheckInFlight = false
    private func watchTempShown() {
        guard let t0 = tempShown, !mover.isBusy, !tempCheckInFlight else { return }
        tempCheckInFlight = true
        let pid = t0.pid, baseline = t0.baseline, wid = t0.windowID
        let check: @Sendable () -> Bool = {
            MenuBarScanner.hasOpenMenu(pid: pid) || !MenuBarScanner.openWindows(pid: pid).subtracting(baseline).isEmpty
        }
        if testLog != nil { finishTempCheck(open: false, wid: wid); return }   // самотест: без чтения окон
        DispatchQueue.global(qos: .utility).async {
            let open = check()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finishTempCheck(open: open, wid: wid) } }
        }
    }

    private func finishTempCheck(open: Bool, wid: CGWindowID) {
        tempCheckInFlight = false
        guard var t = tempShown, t.windowID == wid, !mover.isBusy else { return }
        let age = Date().timeIntervalSince(t.since)
        if open && age < 600 { t.sawMenu = true; tempShown = t; return }
        guard t.sawMenu || age > 4 else { return }
        tempShown = nil
        if !cleanupActive && manualUntil == nil { tick = nil }
        if t.viaOverflow {
            DispatchQueue.global(qos: .userInitiated).async { MenuBarAgent.setOverflow(expanded: false) }
            scheduleScan(after: 1)
            return
        }
        moveIntoHidden(key: t.key, windowID: t.windowID) { _ in }
    }

    // MARK: Картинки

    /// Значок приложения (без права «Запись экрана») — из NSRunningApplication, с кэшем по pid.
    func appIcon(_ item: MenuBarItem) -> NSImage? {
        if let c = iconCache[item.pid] { return c }
        guard let img = NSRunningApplication(processIdentifier: item.pid)?.icon else { return nil }
        iconCache[item.pid] = img
        return img
    }

    /// «Показывать настоящие значки»: право «Запись экрана» — только по этой кнопке.
    func enableRealIcons() {
        prefs.realIcons = true
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            flash("Разреши SimpleIsland в «Запись экрана» — картинки появятся после перезапуска", seconds: 8)
        }
        refreshPermissions()
        captureImages()
    }

    /// Захват окон спрятанных значков (ScreenCaptureKit). Только если право уже есть и вкладка открыта.
    func captureImages() {
        guard running, prefs.realIcons, CGPreflightScreenCaptureAccess() else { return }
        let targets = MenuBarPlanner.islandItems(inventory, prefs).map { ($0.key, $0.windowID, $0.frame.size) }
        guard !targets.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            var out: [String: NSImage] = [:]
            for (key, id, size) in targets {
                guard let w = content.windows.first(where: { $0.windowID == id }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(size.width * 2); cfg.height = Int(size.height * 2)
                cfg.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                        configuration: cfg) {
                    out[key] = NSImage(cgImage: cg, size: size)
                }
            }
            self?.images = out
        }
    }

    // MARK: Компакт

    func updateStack() {
        guard let ctx = context, !ctx.isSnapshot else { return }
        let items = MenuBarPlanner.islandItems(inventory, prefs)
        guard running, prefs.showStack, !items.isEmpty else {
            if postedStack != nil { ctx.removeActivity(id: Self.stackActivityId); postedStack = nil }
            return
        }
        let sig = items.prefix(3).map(\.key).joined(separator: ",") + "#\(items.count)"
        guard sig != postedStack else { return }
        postedStack = sig
        Self.postStack(items: Array(items.prefix(3)), count: items.count, model: self, ctx: ctx)
    }


    static func postStack(items: [MenuBarItem], count: Int, model: MenuBarModel, ctx: ModuleContext) {
        ctx.post(IslandActivity(id: stackActivityId, moduleId: MenuBarIslandModule.moduleId, priority: -10, sideWidth: 96) {
            Image(systemName: "square.grid.2x2").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ctx.theme.secondary).accessibilityHidden(true)
        } trailing: {
            MenuBarStackView(items: items, count: count, model: model)
        }.accessibility("В острове \(MenuBarText.icons(count)) строки меню"))
    }

    // MARK: Строка состояния

    private var statusSticky = false

    func flash(_ text: String, seconds: TimeInterval = 3, sticky: Bool = false) {
        status = text
        statusSticky = sticky
        // Важное (неудача, нужно действие) при свёрнутом острове и без оверлея — карточкой в острове.
        if seconds >= 5, !cleanupActive, let ctx = context, !ctx.isTabVisible {
            notify(IslandNotification(moduleId: MenuBarIslandModule.moduleId, title: "Строка меню",
                                      body: text, systemImage: "menubar.rectangle", duration: seconds + 2))
        }
        statusWork?.cancel()
        guard !sticky else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.status == text { self?.status = nil } } }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

// MARK: - macOS 27 (MenuBarAgent)

/// macOS 27: значки рисует MenuBarAgent, окон у значков нет (docs/MENUBAR.md §10, измерено 20.11.2026).
/// * Перенос — только «как человек» (`MenuBarMover.Style.agent`): курсор на миг уходит к значку и возвращается.
///   Источник должен быть на экране: значок из системного overflow сначала показываем раскрытием overflow (AXPress
///   индикатора), потом тащим из раскрытого ряда.
/// * Новый разделитель система ставит левее всех — при полной строке он сам в overflow и ничего не прячет; перед
///   первым переносом ставим его левее самого левого видимого значка.
/// * Развёрнутый разделитель (≤ половины экрана) — система прячет всё левее него в overflow («в острове»).
/// * Показать спрятанный: раскрыть overflow + AXPress значка (без переноса); меню закрылось — свернуть.
extension MenuBarModel {
    static func agentMoveFailedText(_ name: String) -> String {
        "Не вышло перенести \(name): macOS 27 не переставила значок. Перетащи его с ⌘ левее черты-разделителя (30 с) — я подхвачу; или выключи его совсем: Системные настройки → Строка меню → «Разрешить в строке меню»."
    }

    var agentMode: Bool { inventory.source != .windows || (MenuBarAgent.isActive && !MenuBarDivider.dryRun) }

    /// Выполнить в фоне и вернуться на главный через `delay`.
    private func agentAsync(_ work: @escaping @Sendable () -> Void, delay: TimeInterval,
                            then: @escaping @MainActor () -> Void) {
        if testLog != nil { then(); return }   // самотест: в систему ничего
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { then() } }
        }
    }

    private func agentFind(_ inv: MenuBarInventory, key: String, wid: CGWindowID?) -> MenuBarItem? {
        wid.flatMap { w in inv.items.first { $0.windowID == w } } ?? inv.item(key: key)
    }

    /// Значок на экране для перетаскивания: скрытый — раскрыть overflow и пересканировать. `opened` — раскрывали
    /// (надо свернуть после).
    private func agentReveal(key: String, wid: CGWindowID?, g: Int,
                             _ done: @escaping @MainActor (_ item: MenuBarItem?, _ inv: MenuBarInventory, _ opened: Bool) -> Void) {
        scanNow { [weak self] inv in
            guard let self, self.live(g) else { return }
            let it = self.agentFind(inv, key: key, wid: wid)
            guard let it, it.section != .visible, !inv.overflowExpanded else { done(it, inv, false); return }
            self.agentAsync({ MenuBarAgent.setOverflow(expanded: true) }, delay: 1.3) {
                guard self.live(g) else { return }
                self.scanNow { inv2 in
                    guard self.live(g) else { return }
                    done(self.agentFind(inv2, key: key, wid: wid), inv2, true)
                }
            }
        }
    }

    private func agentCollapseOverflow(_ opened: Bool, then: @escaping @MainActor () -> Void) {
        guard opened else { then(); return }
        agentAsync({ MenuBarAgent.setOverflow(expanded: false) }, delay: 1.0, then: then)
    }

    /// Куда бросить значок, чтобы система его спрятала (macOS 27 прячет «префикс» строки — всё левее):
    /// * строка полна (есть кнопка overflow) — в раскрытый ряд скрытых, левее самого правого из них (`overflowRow`);
    /// * не полна — левее нашего разделителя (он тогда в строке), потом разворот разделителя съедает свободное место.
    /// nil — некуда (нет ни ряда, ни разделителя в строке).
    static func agentHideTarget(_ inv: MenuBarInventory, dividerFrame: CGRect?, excluding wid: CGWindowID)
        -> (frame: CGRect, overflowRow: Bool)? {
        if inv.overflowIndicator != nil, inv.overflowExpanded,
           let last = inv.items.filter({ $0.section != .visible && $0.windowID != wid }).max(by: { $0.frame.midX < $1.frame.midX }) {
            return (last.frame, true)
        }
        if let d = dividerFrame { return (d, false) }
        return nil
    }

    /// Куда бросить, чтобы значок встал в строку: правее разделителя в строке, иначе правее самого левого видимого
    /// (при полной строке система спрячет крайний левый — сообщаем).
    static func agentShowTarget(_ inv: MenuBarInventory, excluding wid: CGWindowID) -> CGRect? {
        if let d = inv.dividerFrame { return d }
        return inv.visible.filter { $0.windowID != wid && $0.isMovable }.min { $0.frame.minX < $1.frame.minX }?.frame
    }

    func agentMoveIntoHidden(key: String, windowID: CGWindowID?, allowCreate: Bool, typingPause: TimeInterval,
                             completion: @escaping @MainActor (Bool) -> Void) {
        guard axGranted || testLog != nil else { mover.lastFailure = .noAccess; completion(false); return }
        if !divider.exists {
            guard allowCreate else { completion(false); return }
            // Разделитель на 27 — метка «что-то спрятано нами» (скрытое системой при нём — «в острове») и, если в
            // строке есть место, — то, что это место съедает. Новый встаёт левее всех.
            prefs.fromNotch = Array(Set(prefs.fromNotch + inventory.underNotch.map(\.key)))
            divider.ensure(preferredPosition: nil)
        }
        if !mover.isBusy { mover.lastFailure = nil }
        let g = epoch
        let wid = windowID ?? inventory.item(key: key)?.windowID
        divider.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live(g) else { return }
                let finish: @MainActor (Bool) -> Void = { sent in
                    self.divider.expand()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        MainActor.assumeIsolated {
                            guard self.live(g) else { return }
                            self.scanNow { after in
                                let moved = self.agentFind(after, key: key, wid: wid)
                                self.finishMove(key: key, newKey: moved?.key ?? key,
                                                ok: sent && moved != nil && moved?.section != .visible, completion)
                            }
                        }
                    }
                }
                self.scanNow { inv in
                    guard self.live(g) else { return }
                    guard let item = self.agentFind(inv, key: key, wid: wid) else { finish(false); return }
                    // Уже скрыт системой — уже в overflow, переносить нечего.
                    if item.section != .visible { finish(true); return }
                    let full = inv.overflowIndicator != nil
                    self.agentAsync({ if full { MenuBarAgent.setOverflow(expanded: true) } }, delay: full ? 1.3 : 0) {
                        guard self.live(g) else { return }
                        self.scanNow { inv2 in
                            guard self.live(g) else { return }
                            guard let cur = self.agentFind(inv2, key: key, wid: wid),
                                  let target = Self.agentHideTarget(inv2, dividerFrame: inv2.dividerFrame,
                                                                    excluding: cur.windowID) else {
                                self.agentCollapseOverflow(full) { finish(false) }
                                return
                            }
                            self.mover.drag(itemWindow: 0, pid: cur.pid, item: cur.frame, targetWindow: 0,
                                            target: target.frame, side: .leftOf, style: .agent, typingPause: typingPause,
                                            isCancelled: { [weak self] in self?.live(g) != true }) { sent in
                                guard self.live(g) else { return }
                                self.agentCollapseOverflow(full) { finish(sent) }
                            }
                        }
                    }
                }
            }
        }
    }

    func agentReturnToBar(_ item: MenuBarItem, name: String, then next: (@MainActor () -> Void)?) {
        let g = epoch, key = item.key, wid = item.windowID
        divider.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live(g) else { return }
                self.agentReveal(key: key, wid: wid, g: g) { it, inv, opened in
                    let done: @MainActor (Bool, MenuBarItem?) -> Void = { sent, src in
                        self.agentCollapseOverflow(opened) {
                            self.divider.expand()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                MainActor.assumeIsolated {
                                    guard self.live(g) else { return }
                                    self.scanNow { after in
                                        let ok = self.agentFind(after, key: key, wid: wid)?.section == .visible
                                        self.finishIfEmptyAgent()
                                        if ok { self.flash("\(name) — снова в строке меню") }
                                        else if !sent, let src { self.reportMoveFailure(name: name, verb: "вернуть", item: src, sent: false) }
                                        else { self.flash("Не вышло вернуть \(name): в строке меню нет места — macOS прячет его за стрелкой справа от выреза. Убери другие значки или перетащи его с ⌘ сам.", seconds: 8) }
                                        next?()
                                    }
                                }
                            }
                        }
                    }
                    guard let it else { done(false, nil); return }
                    if it.section == .visible { done(true, it); return }
                    guard let target = Self.agentShowTarget(inv, excluding: it.windowID) else { done(false, it); return }
                    self.mover.drag(itemWindow: 0, pid: it.pid, item: it.frame, targetWindow: 0, target: target,
                                    side: .rightOf, style: .agent,
                                    isCancelled: { [weak self] in self?.live(g) != true }) { sent in
                        guard self.live(g) else { return }
                        done(sent, it)
                    }
                }
            }
        }
    }

    private func finishIfEmptyAgent() {
        if !prefs.needsDivider && inventory.inIslandSection.isEmpty { divider.remove(forgetPosition: false) }
    }

    /// Открыть меню спрятанного значка без переноса: раскрыть системный overflow, нажать значок (AXPress), следить за
    /// меню/окном; закрылось — свернуть overflow (`TempShown.viaOverflow`).
    func agentShowFromOverflow(_ item: MenuBarItem) {
        testLog?.append("show \(item.key)")
        guard !showInFlight, tempShown == nil else { flash("Подожди секунду — ещё показываю прошлый значок"); return }
        let g = epoch, key = item.key, wid = item.windowID, name = item.displayName
        showInFlight = true
        agentReveal(key: key, wid: wid, g: g) { [weak self] it, _, opened in
            guard let self else { return }
            self.showInFlight = false
            guard let it else {
                self.agentCollapseOverflow(opened) {}
                self.flash("\(name) пропал из строки меню — приложение закрылось?", seconds: 5)
                return
            }
            self.tempShown = TempShown(key: key, windowID: wid, pid: it.pid, sawMenu: false, since: Date(), baseline: [],
                                       viaOverflow: opened)
            if self.tick == nil { self.tick = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in self?.onTick() } }
            guard self.testLog == nil else { return }
            let pid = it.pid, frame = it.frame
            DispatchQueue.global(qos: .userInitiated).async {
                let baseline = MenuBarScanner.openWindows(pid: pid)
                let pressed = MenuBarMover.press(pid: pid, frame: frame)
                NSLog("SimpleIsland: строка меню (27) — показ %@ из overflow: AXPress %@", name, pressed ? "принят" : "нет")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.tempShown?.windowID == wid { self.tempShown?.baseline = baseline }
                    }
                }
            }
        }
    }
}
