import AppKit
import Combine
import SwiftUI
import IslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var env: AppEnvironment!
    private var islands: IslandSet!
    /// Ловушка кликов мимо раскрытого острова (окна на всех экранах).
    private var clickTrap: ClickAwayTrap?
    private var screenCoalescer: ScreenChangeCoalescer!
    /// Острова по экранам (порядок — как в плане: с вырезом / со строкой меню первым).
    private var controllers: [IslandController] { islands?.controllers ?? [] }
    /// Сон, выключенные экраны, блокировка, чужая сессия: мониторы мыши сняты, острова свёрнуты.
    private var suspended = false
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private var mouseMonitors: [Any] = []
    /// `NSPasteboard(name: .drag).changeCount` на момент нажатия кнопки мыши: изменился во время
    /// перетаскивания → начался drag-сеанс (файлы из Finder и т. п.).
    private var dragPasteboardCount = 0
    /// Содержимое drag-буфера с этим счётчиком уже разобрано (не «файл») — не разбирать на каждом событии.
    private var dragInspectedCount = -1   // --- shelfbar ---
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Один остров на пользователя (27.11): автозапуск из двух мест (Объекты входа + SMAppService) или повторный
        // `open` не должен давать второй остров поверх первого.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            NSLog("SimpleIsland: уже запущен — второй экземпляр закрывается")
            NSApp.terminate(nil)
            return
        }
        let settings = SimpleIslandSettings()
        // Первый запуск собранного .app — включить автозапуск системным способом (SMAppService), один раз: после
        // перезагрузки остров должен быть на месте (27.11), а выключенный пользователем — не включаться снова.
        if !settings.data.launchAtLoginAsked, LoginItem.shared.isBundled {
            settings.data.launchAtLoginAsked = true
            if !LoginItem.shared.isOn { LoginItem.shared.set(true) }
        }
        let themes = ThemeStore()
        env = AppEnvironment(settings: settings, themes: themes, modules: ModuleRegistry.makeModules())
        env.openTabHandler = { [weak self] id in
            guard let self, let c = self.primaryController else { return }
            if let id { c.model.expand(tab: id) } else { c.model.collapse() }
        }

        // Дети прошлого запуска, пережившие жёсткое падение (`kill -9`), — добить (грабли E3).
        let orphans = ManagedProcess.reapOrphans()
        if orphans > 0 { NSLog("SimpleIsland: добито сирот прошлого запуска: %d", orphans) }
        installTerminationSignals()

        let system = SystemStateCenter.shared
        system.startMonitoring()
        system.setReduceMotionOnBattery(settings.data.reduceMotionOnBattery)

        islands = IslandSet(env: env)
        islands.onCreate = { [weak self] c in c.model.onOpenSettings = { [weak self] in self?.openSettings() } }
        // Экраны: пачка уведомлений склеивается (0,4 с), пересборка — только если подпись экранов изменилась,
        // и только изменившиеся экраны (грабли D1/D2/D4).
        screenCoalescer = ScreenChangeCoalescer(delay: 0.4, read: { ScreenDescriptor.current() },
                                                apply: { [weak self] screens in self?.applyScreens(screens) })

        clickTrap = ClickAwayTrap(env: env) { [weak self] in self?.controllers ?? [] }
        // Подсказки прав («где включить», «перезапустите»). Ответ на нажатие — свернуть остров (раскрытый карточки
        // откладывает) и показать сразу, вне очереди; сама по себе (старт модуля) — обычная очередь, остров не трогать.
        PermissionGuideCenter.presenter = { [weak self] card in
            guard let self else { return }
            Self.present(card, env: self.env, controllers: self.controllers)
        }

        setupStatusItem()
        screenCoalescer.applyNow()
        installMouseMonitors()
        env.startModules()
        WidgetCatalogWindow.shared.start(env: env)   // --- catalog --- модули открывают каталог уведомлением
        // Отладочное управление (замеры, живые снимки) — только при SIMPLEISLAND_DEBUG=1.
        DebugControl.shared.start(env: env) { [weak self] in self?.primaryController }
        // --- settings: горячая клавиша раскрыть/свернуть, вид окон, онбординг первого запуска
        // Остров спрятан правилом (полноэкранное приложение) — клавишу не обрабатываем: раскрытие было бы невидимым.
        SettingsWindows.shared.start(env: env) { [weak self] in
            guard let c = self?.primaryController, c.panel.isVisible else { return }
            c.model.toggle()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenCoalescer.note() }
        }
        // Сон/пробуждение/блокировка/быстрое переключение пользователей (грабли D3).
        system.events
            .sink { [weak self] e in MainActor.assumeIsolated { self?.handleSystemEvent(e) } }
            .store(in: &bag)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Окно полноэкранного приложения встаёт на место не сразу (анимация ~0,7–1 с) — серия проверок.
                MainActor.assumeIsolated { self?.scheduleFullscreenChecks(name.rawValue) }
            }
        }
        observeAttention()
        // Карточка «нужен ответ» в полноэкранном — по настройке показать остров на время карточки.
        env.notifications.$current
            .map { n in n.map { FullscreenDetector.isCritical(duration: $0.duration, actionCount: $0.actions.count) } ?? false }
            .removeDuplicates()
            .sink { [weak self] critical in
                MainActor.assumeIsolated {
                    self?.criticalShown = critical
                    self?.applyHiddenByRule()
                }
            }
            .store(in: &bag)

        // Пауза, «все мониторы», «капля без выреза» → привести набор островов к плану (без задержки).
        settings.$data
            .map { [$0.paused, $0.allScreens, $0.floatingOnNotchlessScreens, $0.hideInFullscreen, $0.showCriticalInFullscreen] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuildIslands() } }
            }
            .store(in: &bag)
        settings.$data
            .map(\.reduceMotionOnBattery)
            .removeDuplicates()
            .sink { SystemStateCenter.shared.setReduceMotionOnBattery($0) }
            .store(in: &bag)
        // Запуск при заблокированном экране / в фоновой сессии (флаги прочитаны у системы в startMonitoring).
        if !system.isInteractive { suspend() }
    }

    /// Показ подсказки прав (самотест `guide`): на нажатие — свернуть острова и вне очереди; сама по себе — в очередь.
    static func present(_ card: PermissionGuideCard, env: AppEnvironment, controllers: [IslandController]) {
        if card.interactive {
            controllers.forEach { $0.model.collapse() }
            env.notifications.postFront(card.notification())
        } else {
            env.notifications.post(card.notification())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugControl.shared.stop()   // токен отладки — убрать
        env?.stopModules()
        // Дочерние процессы модулей (адаптер MediaRemote и т. п.) — не оставлять сиротами (грабли E3, AG3).
        ManagedProcess.terminateAll()
        removeMouseMonitors()
        clickTrap?.closeAll()
        env?.settings.saveNow()
    }

    /// SIGTERM/SIGINT/SIGHUP (`kill`, `launchctl stop`, Ctrl-C, закрытый терминал) → штатный выход: модули
    /// остановлены, дети убиты, настройки сохранены. Без этого `kill` обрывал бы процесс и оставлял детей.
    /// Ставится до первого `ManagedProcess`: его обработчики игнорируемые сигналы не перехватывают.
    private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Сон, пробуждение, блокировка

    private func handleSystemEvent(_ e: IslandSystemEvent) {
        let system = SystemStateCenter.shared
        switch e {
        case .willSleep, .screensDidSleep, .sessionDidResignActive, .screenLocked:
            suspend()
        case .didWake, .screensDidWake, .sessionDidBecomeActive, .screenUnlocked:
            if system.isInteractive { resume() }
        case .screensChanged, .motionChanged:
            break
        }
    }

    /// Сон: снять мониторы мыши, свернуть острова, не пересобирать экраны до пробуждения.
    private func suspend() {
        screenCoalescer.isHeld = true
        guard !suspended else { return }
        suspended = true
        removeMouseMonitors()
        controllers.forEach { $0.suspend() }
        clickTrap?.suspended = true
        env.island.setFileDrag(active: false)
        NSLog("SimpleIsland: сон/блокировка — мониторы сняты")
    }

    /// Пробуждение: вернуть мониторы; острова показать сразу, только если набор экранов тот же, что до сна,
    /// иначе — после склейки (0,4 с после последнего уведомления), уже по новой геометрии: остров пропавшего
    /// экрана или со старыми координатами не мелькает. Принудительная перепроверка — в любом случае.
    private func resume() {
        guard suspended else { return }
        suspended = false
        clickTrap?.suspended = false
        installMouseMonitors()
        let same = ScreenDescriptor.current() == screenCoalescer.lastApplied
        if same { controllers.forEach { $0.resume() } }
        screenCoalescer.isHeld = false
        screenCoalescer.note(force: true)
        NSLog("SimpleIsland: пробуждение — мониторы на месте, экраны %@", same ? "те же" : "изменились, ждём склейку")
    }

    // MARK: Острова на экранах

    private var primaryController: IslandController? {
        controllers.first { $0.model.geometry.hasNotch } ?? controllers.first
    }

    /// Настройки поменялись (пауза, все мониторы, капля) — привести острова к плану сразу.
    private func rebuildIslands() {
        // Во сне не создаём и не показываем острова (мониторы мыши сняты) — применится после пробуждения.
        if suspended { screenCoalescer.note(force: true); return }
        screenCoalescer.applyNow()
    }

    /// Привести острова к экранам: новые — создать, изменившиеся — обновить на месте, пропавшие — закрыть,
    /// остальные не трогать. Сюда приходят уже склеенные и сравненные по подписи изменения.
    private func applyScreens(_ screens: [ScreenDescriptor]) {
        let data = env.settings.data
        let plan = IslandPlanner.plan(screens, .init(paused: data.paused, allScreens: data.allScreens,
                                                     floatingOnNotchlessScreens: data.floatingOnNotchlessScreens))
        let before = (islands.created, islands.updated, islands.removed)
        let changed = islands.reconcile(plan)
        // Ловушки — на всех экранах (клик на другом мониторе тоже только сворачивает), окна пропавших — закрыть.
        clickTrap?.setScreens(screens)
        // Острова, убранные на время сна, — на место (новые IslandSet показывает сам; `show` идемпотентен).
        if !suspended { controllers.forEach { $0.resume() } }
        for c in controllers {
            let g = c.model.geometry
            NSLog("SimpleIsland: экран %@ (id %u) — вырез %.0f×%.0f (есть: %@), панель %@, уровень %d",
                  c.descriptor.name, c.descriptor.displayID, g.notchWidth, g.notchHeight,
                  g.hasNotch ? "да" : "нет", NSStringFromRect(c.panel.frame), c.panel.level.rawValue)
        }
        NSLog("SimpleIsland: экранов %d, островов %d (создано %d, обновлено %d, закрыто %d)",
              screens.count, controllers.count, islands.created - before.0, islands.updated - before.1,
              islands.removed - before.2)
        if changed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.logMenuBarLayers() } }
            SystemStateCenter.shared.handle(.screensChanged)
        }
        applyFullscreenRule()
        scheduleFullscreenChecks()
    }

    /// Диагностика при старте: уровень (layer) окон строки меню против нашего — остров должен быть выше.
    private func logMenuBarLayers() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let menu = list.filter { ($0[kCGWindowName as String] as? String) == "Menubar" }
            .compactMap { $0[kCGWindowLayer as String] as? Int }
        let ours = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
            .compactMap { $0[kCGWindowLayer as String] as? Int }
        NSLog("SimpleIsland: слои строки меню %@, наши окна %@", "\(menu)", "\(ours)")
    }

    private func removeMouseMonitors() {
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                self?.controllers.forEach { $0.mouseMoved(to: p) }
            }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) {
            mouseMonitors.append(l)
        }
        // Перетаскивание файлов (для Полки): нажатие запоминает счётчик drag-буфера, перетаскивание с новым
        // содержимым-файлами включает `isFileDragActive`, отпускание — выключает. Без опроса.
        let dragHandler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.trackFileDrag(e) }
        }
        let dragMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: dragMask, handler: dragHandler) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: dragMask, handler: { dragHandler($0); return $0 }) {
            mouseMonitors.append(l)
        }
        // Свайп двумя пальцами / колесо над островом: вниз — раскрыть, вверх — свернуть (трекпад — интерактивно, IslandSwipe).
        if let s = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let c = self.controllers.first(where: { $0.panel === e.window }) else { return }
                let physical = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
                c.model.scroll(physicalDeltaY: physical, precise: e.hasPreciseScrollingDeltas,
                               phase: ScrollPhase(phase: e.phase, momentum: e.momentumPhase), time: e.timestamp)
            }
            return e
        }) { mouseMonitors.append(s) }
    }

    private func trackFileDrag(_ e: NSEvent) {
        let island = env.island
        switch e.type {
        case .leftMouseDown:
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            dragInspectedCount = -1   // --- shelfbar ---
        case .leftMouseDragged:
            guard !island.isFileDragActive else { return }
            let pb = NSPasteboard(name: .drag)
            // --- shelfbar --- «файл» — не только public.file-url: обещание файла (миниатюра снимка экрана ⌘⇧4,
            // вложения Почты/Telegram, картинка из Chrome), сырая картинка (Safari), file://-ссылка
            // (`DragPasteboard`). Разбор один раз на новое содержимое буфера, а не на каждое событие мыши.
            let count = pb.changeCount
            guard count != dragPasteboardCount, count != dragInspectedCount else { return }
            dragInspectedCount = count
            if DragPasteboard.isFileLike(pb) {
                island.setFileDrag(active: true)
            }
            // --- /shelfbar ---
        case .leftMouseUp:
            if island.isFileDragActive {
                // Бросок мог прийти в панель после отпускания — снимаем флаг на следующем шаге.
                DispatchQueue.main.async { MainActor.assumeIsolated { island.setFileDrag(active: false) } }
            }
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        default: break
        }
    }

    /// Правило «прятать в полноэкранном» (`FullscreenDetector`): на экране острова полноэкранное окно любого
    /// приложения (видео, игра) — остров спрятан, вместе с ним не видны вспышки HUD и уведомления; карточка «нужен
    /// ответ» по настройке `showCriticalInFullscreen` остров на время показывает. Проверка — только по событиям (смена
    /// стола, приложения, экранов) сериями `FullscreenDetector.recheckDelays`, без постоянного опроса.
    private var fullscreenWork: [DispatchWorkItem] = []
    /// Экраны (displayID), занятые полноэкранным окном, и номер этого окна.
    private var fullscreenWindows: [CGDirectDisplayID: CGWindowID] = [:]
    private var criticalShown = false

    /// --- shelfbar --- после события ещё `pollWindow` секунд — проверка раз в секунду (SharedTicker); потом тишина.
    private var fullscreenPoll: AnyCancellable?
    private var fullscreenPollUntil = Date.distantPast
    private var fullscreenReasons: [CGDirectDisplayID: FullscreenDetector.Reason] = [:]

    private func scheduleFullscreenChecks(_ why: String = "событие") {
        FullscreenDetector.log.info("проверка: \(why, privacy: .public)")
        fullscreenWork.forEach { $0.cancel() }
        fullscreenWork = FullscreenDetector.recheckDelays.map { delay in
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.applyFullscreenRule() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
        // --- shelfbar --- анимация пространства бывает дольше серии: досматриваем раз в секунду, пока у переднего
        // приложения есть окно на ширину экрана (кандидат) и не вышел срок.
        guard env.settings.data.hideInFullscreen else { return }
        fullscreenPollUntil = Date().addingTimeInterval(FullscreenDetector.pollWindow)
        if fullscreenPoll == nil {
            fullscreenPoll = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in self?.fullscreenPollTick() }
        }
    }

    private func fullscreenPollTick() {
        guard Date() < fullscreenPollUntil, env.settings.data.hideInFullscreen,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            fullscreenPoll = nil
            return
        }
        let screens = controllers.map { FullscreenDetector.cgFrame(of: $0.descriptor.frame) }
        if FullscreenDetector.hasScreenWideWindow(pid: pid, screens: screens, windows: FullscreenDetector.liveWindows()) {
            applyFullscreenRule()
        } else if fullscreenWindows.isEmpty {
            fullscreenPoll = nil   // кандидата нет и ничего не спрятано — досматривать нечего
        } else {
            applyFullscreenRule()  // было спрятано — проверить выход
        }
    }

    private func applyFullscreenRule() {
        guard env.settings.data.hideInFullscreen else {
            fullscreenWindows = [:]
            applyHiddenByRule()
            return
        }
        let windows = FullscreenDetector.liveWindows()
        // --- shelfbar --- тип текущего стола каждого экрана: полноэкранный (4) — прячем, что бы ни было с рамками.
        let spaces = SpaceProbe.currentSpaceTypes()
        var found: [CGDirectDisplayID: CGWindowID] = [:]
        var reasons: [CGDirectDisplayID: FullscreenDetector.Reason] = [:]
        for c in controllers {
            let cg = FullscreenDetector.cgFrame(of: c.descriptor.frame)
            let space = spaces.flatMap { SpaceProbe.spaceType(for: SpaceProbe.uuid(of: c.descriptor.displayID), in: $0) }
            let d = FullscreenDetector.decide(screen: cg, safeTop: c.descriptor.safeArea.top, windows: windows,
                                              ownPID: getpid(), spaceType: space)
            if let id = d.window {
                found[c.descriptor.displayID] = id
                reasons[c.descriptor.displayID] = d.reason
            }
            let isNew = (found[c.descriptor.displayID] != nil) != (fullscreenWindows[c.descriptor.displayID] != nil)
            if isNew {
                let disp = c.descriptor.displayID
                let spaceText = space.map { "\($0)" } ?? "?"
                FullscreenDetector.log.notice("""
                    экран \(disp, privacy: .public): \(d.window != nil ? "ПРЯЧУ" : "показываю", privacy: .public) — \
                    \(d.reason.rawValue, privacy: .public), стол тип \(spaceText, privacy: .public), \
                    \(FullscreenDetector.describeCandidates(screen: cg, windows: windows, ownPID: getpid()), privacy: .public)
                    """)
            }
        }
        if found != fullscreenWindows {
            NSLog("SimpleIsland: полноэкранный — экраны %@", found.isEmpty ? "нет" : found.keys.map { "\($0)" }.joined(separator: ", "))
        }
        // Вошли в полноэкранный — «новости» до него (готово, карточка) точкой не показывать.
        if fullscreenWindows.isEmpty && !found.isEmpty {
            env.activities.dropAttentionNews()
            missedNotification = nil
        }
        if found.isEmpty { peekDisplay = nil }
        fullscreenWindows = found
        fullscreenReasons = reasons
        applyHiddenByRule()
    }

    private func applyHiddenByRule() {
        let showCritical = criticalShown && env.settings.data.showCriticalInFullscreen
        let top = env.activities.topAttention
        var alive = Set<CGDirectDisplayID>()
        for c in controllers {
            let disp = c.descriptor.displayID
            let full = env.settings.data.hideInFullscreen && fullscreenWindows[disp] != nil
            let hidden = full && !showCritical && peekDisplay != disp
            c.setHiddenByRule(hidden)
            // Точка у выреза — только пока остров этого экрана спрятан правилом.
            alive.insert(disp)
            let kind = FullscreenBeacon.kind(islandHidden: hidden, enabled: env.settings.data.fullscreenDot, top: top?.state)
            if kind == nil, beacons[disp] == nil { continue }
            let panel = beacons[disp] ?? makeBeacon(for: disp)
            let g = c.model.geometry
            panel.show(kind, text: top?.state.text ?? "",
                       frame: FullscreenBeacon.frame(centerX: g.centerX, screenTop: g.screenTop, notchHeight: g.notchHeight,
                                                     hasNotch: g.hasNotch),
                       reduceMotion: SystemStateCenter.shared.reduceMotion)
        }
        for (disp, panel) in beacons where !alive.contains(disp) { panel.orderOut(nil); panel.close(); beacons[disp] = nil }
    }

    // MARK: Точка у выреза в полноэкранном (15.11)

    /// Окна точки по экранам (создаются по первой надобности, живут до пропажи экрана).
    private var beacons: [CGDirectDisplayID: FullscreenBeaconPanel] = [:]
    /// Экран, где по клику по точке остров показан поверх полноэкранного, пока его не свернут.
    private var peekDisplay: CGDirectDisplayID?
    private var peekSawOpen = false
    private var peekStarted = Date.distantPast
    /// Карточка, пришедшая, пока остров был спрятан (синяя точка) — покажется по клику.
    private var missedNotification: IslandNotification?

    private func makeBeacon(for disp: CGDirectDisplayID) -> FullscreenBeaconPanel {
        let p = FullscreenBeaconPanel()
        p.onClick = { [weak self] in MainActor.assumeIsolated { self?.openBeacon(on: disp) } }
        beacons[disp] = p
        return p
    }

    /// Клик по точке: остров этого экрана поверх полноэкранного — с вкладкой модуля события или пропущенной карточкой.
    private func openBeacon(on disp: CGDirectDisplayID) {
        guard let c = controllers.first(where: { $0.descriptor.displayID == disp }),
              let top = env.activities.topAttention else { return }
        peekDisplay = disp
        peekSawOpen = false
        peekStarted = Date()
        env.activities.acknowledgeAttention(moduleId: top.moduleId)
        applyHiddenByRule()
        if top.moduleId == FullscreenBeacon.notificationsKey, let n = missedNotification {
            missedNotification = nil
            var again = n
            if again.duration != nil { again.duration = max(again.duration ?? 6, 8) }
            env.notifications.postFront(again)
        } else {
            c.model.expand(tab: top.state.opensTab ?? top.moduleId)
        }
        FullscreenDetector.log.notice("точка: открыт остров — \(top.moduleId, privacy: .public)")
        // Не раскрылся (вкладка выключена и т. п.) — через 4 с вернуть как было.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peekDisplay == disp, !self.peekSawOpen else { return }
                self.endPeek()
            }
        }
    }

    private func endPeek() {
        guard peekDisplay != nil else { return }
        peekDisplay = nil
        peekSawOpen = false
        applyHiddenByRule()
    }

    /// Подписки точки: события модулей, пропущенные карточки, просмотр вкладки, конец «подсмотра».
    private func observeAttention() {
        env.activities.$attention
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyHiddenByRule() } } }
            .store(in: &bag)
        env.notifications.$current
            .sink { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let n, FullscreenBeacon.isImportant(n), self.islandHiddenSomewhere else { return }
                    // Карточку «нужен ответ» по настройке и так покажет сам остров.
                    if FullscreenDetector.isCritical(duration: n.duration, actionCount: n.actions.count),
                       self.env.settings.data.showCriticalInFullscreen { return }
                    self.missedNotification = n
                    let text = [n.title, n.body].filter { !$0.isEmpty }.joined(separator: " · ")
                    self.env.activities.setAttention(.info, text: text, opensTab: n.opensTab, for: FullscreenBeacon.notificationsKey)
                }
            }
            .store(in: &bag)
        // Открыли вкладку модуля — его событие просмотрено.
        env.island.$expandedTab
            .compactMap { $0 }
            .sink { [weak self] tab in MainActor.assumeIsolated { self?.env.activities.acknowledgeAttention(moduleId: tab) } }
            .store(in: &bag)
        env.island.$presentation
            .sink { [weak self] p in
                MainActor.assumeIsolated {
                    guard let self, self.peekDisplay != nil else { return }
                    if p >= .notification { self.peekSawOpen = true; return }
                    guard self.peekSawOpen, Date().timeIntervalSince(self.peekStarted) > 0.5 else { return }
                    // Свернули — спрятать снова (на следующем шаге: presentation шлётся до записи).
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.endPeek() } }
                }
            }
            .store(in: &bag)
        env.settings.$data
            .map(\.fullscreenDot)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyHiddenByRule() } } }
            .store(in: &bag)
    }

    /// Остров хоть одного экрана спрятан правилом (полноэкранный) — карточку там не видно.
    private var islandHiddenSomewhere: Bool {
        guard env.settings.data.hideInFullscreen, !fullscreenWindows.isEmpty else { return false }
        let showCritical = criticalShown && env.settings.data.showCriticalInFullscreen
        return !showCritical && controllers.contains { fullscreenWindows[$0.descriptor.displayID] != nil && peekDisplay != $0.descriptor.displayID }
    }

    // MARK: Меню в строке меню

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = Self.menuBarIcon()
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Значок строки меню: свой шаблонный `MenuBarIcon.pdf` из `Contents/Resources` (кладёт scripts/build-app.sh),
    /// 18×18 pt, цвет — от системы (`isTemplate`). Нет файла (отладочный бинарник) — SF Symbol.
    private static func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "SimpleIsland"
            return image
        }
        return NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "SimpleIsland")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Открыть онбординг…", action: #selector(openOnboardingAction), keyEquivalent: "").target = self
        // --- menubar --- пункты модулей (напр. «Уборка строки меню…»), IslandCore/StatusMenuItems.swift
        for e in StatusMenuItems.shared.entries {
            let i = NSMenuItem(title: e.title, action: #selector(moduleMenuItem(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = e.moduleId
            menu.addItem(i)
        }

        let themeItem = NSMenuItem(title: "Тема", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in env.themes.themes {
            let i = NSMenuItem(title: t.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.id
            i.state = t.id == env.themes.current.id ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: "Перечитать темы", action: #selector(reloadThemes), keyEquivalent: "").target = self
        themeItem.submenu = sub
        menu.addItem(themeItem)

        let pause = NSMenuItem(title: "Пауза острова", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = env.settings.data.paused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func openOnboardingAction() { SettingsWindows.shared.showOnboarding() }
    @objc private func moduleMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        StatusMenuItems.shared.entries.first { $0.moduleId == id }?.action()
    }
    @objc private func selectTheme(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { env.settings.data.themeId = id }
    }
    @objc private func reloadThemes() { env.themes.reload() }
    @objc private func togglePause() { env.settings.data.paused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Окно настроек

    func openSettings() {
        primaryController?.model.collapse()
        SettingsWindows.shared.showSettings()   // окно настроек — SettingsWindows.swift
    }
}
