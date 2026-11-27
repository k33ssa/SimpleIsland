import AppKit
import Combine
import CoreAudio
import SwiftUI
import IslandCore

/// Состояние вкладки «Сегодня» и координация служб. Всё на главном потоке.
@MainActor
final class TodayModel: ObservableObject {
    static let moduleId = "today"

    // Настройки
    @Published var prefs = TodayPrefs() { didSet { prefsChanged(from: oldValue) } }

    // Календарь
    @Published var calendarAccess: CalendarAccess = CalendarService.access
    @Published var events: [TodayEvent] = []
    /// Мок «сейчас» для снимков; nil — реальное время.
    @Published var nowOverride: Date?

    // Погода
    @Published var weather: WeatherSnapshot?
    /// Последний запрос не удался: нет сети или сервис ответил ошибкой (показано последнее значение).
    @Published var weatherProblem: WeatherProblem?
    @Published var weatherLoading = false

    // Система, батареи, буфер
    @Published var system: SystemSample?
    @Published var batteries: [BatteryItem] = []
    @Published var clips: [ClipItem] = []
    @Published var copiedId: UUID?

    // Тумблеры
    @Published var awake = false
    @Published var dark = DarkMode.isOn
    @Published var micOff = false
    @Published var desktopHidden = false
    @Published var focusOn = false
    @Published var focusShortcutName: String?
    @Published var mirrorOn = false
    @Published var busy: Set<ToggleKind> = []
    /// Вместо сетки тумблеров: подтверждение «чистого стола» или просьба выдать право.
    @Published var confirmCleanDesk = false
    @Published var permissionPrompt: TodayPermission?
    @Published var toggleError: String?

    let calendar = CalendarService()
    let mirror = CameraMirror()
    private let systemMonitor = SystemMonitor()
    private let powerWatcher = PowerSourceWatcher()
    private let clipboard = ClipboardHistory()
    private let awakeAssertion = AwakeAssertion()
    /// Устройство, на котором тумблер выключил микрофон — его и вернуть в stop() (выход приложения, SIGTERM/
    /// SIGINT/SIGHUP — ядро зовёт stop() из `applicationWillTerminate`).
    private(set) var micDevice: AudioDeviceID?
    /// Системный выключатель; самотест подменяет поддельным.
    var mic: MicSwitch = SystemMic()
    private var weatherTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private var lastFocusLookup: Date?

    private weak var context: ModuleContext?
    private var cancellables: Set<AnyCancellable> = []
    /// Один отложенный пересчёт на ближайший момент (по стенным часам — догоняет после сна).
    private var eventWork: DispatchWorkItem?
    private var enabledSub: AnyCancellable?
    private var darkObserver: NSObjectProtocol?
    private var lastBluetoothRead: Date?
    private var tabVisible = false

    var now: Date { nowOverride ?? Date() }

    // MARK: Жизненный цикл

    func start(context: ModuleContext) {
        // Настройки — до `self.context`: иначе didSet сочтёт это правкой (сохранение, внеочередной запрос погоды).
        if let p = context.loadSettings(TodayPrefs.self) { prefs = p }
        self.context = context
        context.invalidateLayout()

        calendar.onChange = { [weak self] in self?.reloadEvents() }
        calendar.start()          // только если право уже есть; запрос — при включении плитки/модуля
        reloadEvents()
        // Вернулись из Системных настроек (выдали календарь) — подхватить без перезапуска. Событие, не опрос.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.calendarAccess != CalendarService.access else { return }
                self.reloadEvents()
            }
        }

        weather = WeatherAPI.loadCached().flatMap { $0.matches(prefs) ? $0 : nil }

        systemMonitor.onSample = { [weak self] s in self?.system = s }
        powerWatcher.start { [weak self] in self?.refreshMacBattery() }
        refreshBatteries(bluetooth: false)

        clipboard.onChange = { [weak self] items in self?.clips = items }
        if prefs.isEnabled(.clipboard) { clipboard.start(persist: prefs.rememberClipboard) }

        darkObserver = DistributedNotificationCenter.default().addObserver(forName: DarkMode.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dark = DarkMode.isOn }
        }
        refreshToggleStates()
        // Микрофон выключили тумблером, а приложение упало (SIGKILL, сбой). Его уже включили в обход тумблера —
        // пометку снять. Ещё выключен — сразу не включаем (приватность: тумблер показывает «выключен»), но
        // запоминаем устройство: сохранённую громкость вернёт нажатие тумблера или штатный выход (stop()).
        if prefs.micMutedByUs && !micOff { prefs.micMutedByUs = false }
        if prefs.micMutedByUs && micOff { micDevice = mic.defaultInput() }
        if prefs.isEnabled(.toggles) { lookUpFocusShortcut() }

        // Права — при включении модуля (вкладку включили в настройках), не при каждом старте.
        enabledSub = context.onEnabledChange { [weak self] on in
            guard on, let self else { return }
            if self.prefs.isEnabled(.event) { self.ensureCalendarAccess() }
        }
        context.onSystemEvent { [weak self] e in self?.systemEvent(e) }

        context.island.$expandedTab
            .map { $0 == Self.moduleId }
            .removeDuplicates()
            .sink { [weak self] visible in self?.setTabVisible(visible) }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        enabledSub = nil
        setTabVisible(false)
        restoreMicIfNeeded()
        weatherTask?.cancel(); weatherTask = nil; weatherLoading = false
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
        calendar.stop()
        powerWatcher.stop()
        clipboard.stop()
        awakeAssertion.set(false); awake = false
        mirror.stop(); mirrorOn = false
        eventWork?.cancel(); eventWork = nil
        if let o = darkObserver { DistributedNotificationCenter.default().removeObserver(o) }
        darkObserver = nil
        context?.activities.removeAll(moduleId: Self.moduleId)
        context = nil
    }

    private func setTabVisible(_ visible: Bool) {
        guard visible != tabVisible else { return }
        tabVisible = visible
        systemMonitor.setActive(visible && prefs.isEnabled(.system))
        if visible {
            if prefs.isEnabled(.event) { reloadEvents() }
            if prefs.isEnabled(.weather) { refreshWeather(force: false) }
            if prefs.isEnabled(.batteries) { refreshBatteries(bluetooth: true) }
            if prefs.isEnabled(.toggles) {
                refreshToggleStates()
                // Ярлык «Тишины» могли создать после запуска; `shortcuts list` — процесс, не чаще раза в 2 мин.
                if lastFocusLookup.map({ Date().timeIntervalSince($0) > 120 }) ?? true { lookUpFocusShortcut() }
            }
        } else {
            if mirrorOn { mirror.stop(); mirrorOn = false }
            confirmCleanDesk = false
            permissionPrompt = nil
        }
    }

    /// Сон/блокировка: камеру погасить, опрос нагрузки снять (тикер и сам на паузе). Пробуждение/возврат: события
    /// и отложенный пересчёт заново (день мог смениться), батарея и тумблеры — перечитать.
    private func systemEvent(_ e: IslandSystemEvent) {
        switch e {
        case .willSleep, .screensDidSleep, .screenLocked, .sessionDidResignActive:
            if mirrorOn || mirror.state != .off { mirror.stop(); mirrorOn = false }
            systemMonitor.setActive(false)
        case .didWake, .screensDidWake, .screenUnlocked, .sessionDidBecomeActive:
            guard let ctx = context, ctx.system.isInteractive else { return }
            reloadEvents()
            refreshMacBattery()
            refreshToggleStates()
            systemMonitor.setActive(tabVisible && prefs.isEnabled(.system))
        default:
            // Экраны, уровень движения и значения, которые ядро добавит позже: модулю «Сегодня» не нужны.
            break
        }
    }

    private func prefsChanged(from old: TodayPrefs) {
        guard prefs != old, let ctx = context else { return }
        ctx.saveSettings(prefs)
        if prefs.enabledTiles != old.enabledTiles { ctx.invalidateLayout() }
        // Плитку встречи включили — тогда и спросить календарь.
        if prefs.isEnabled(.event) && !old.isEnabled(.event) { ensureCalendarAccess() }
        if prefs.latitude != old.latitude || prefs.longitude != old.longitude {
            weather = nil; weatherProblem = nil
            refreshWeather(force: true)
        }
        if prefs.isEnabled(.clipboard) != old.isEnabled(.clipboard) {
            if prefs.isEnabled(.clipboard) { clipboard.start(persist: prefs.rememberClipboard) } else { clipboard.stop() }
        }
        if prefs.rememberClipboard != old.rememberClipboard { clipboard.persist = prefs.rememberClipboard }
        if prefs.focusShortcut != old.focusShortcut || (prefs.isEnabled(.toggles) && !old.isEnabled(.toggles)) { lookUpFocusShortcut() }
        if prefs.isEnabled(.system) != old.isEnabled(.system) { systemMonitor.setActive(tabVisible && prefs.isEnabled(.system)) }
    }

    // MARK: Календарь

    func reloadEvents() {
        calendarAccess = CalendarService.access
        // Доступ выдали позже в Системных настройках — хранилища ещё нет (start() вышел без права).
        if calendarAccess == .granted { calendar.start() }
        events = calendar.events(now: now)
        scheduleEventTimer()
    }

    /// Кнопка «Разрешить календарь…» — через ядро (`Permissions.requestFromUser`): не спрашивали — окно macOS;
    /// права так и нет (запрещено раньше, окно не показалось, нет строки Info.plist) — раздел «Календари» и карточка
    /// «что включить и где»; запущено из оболочки — карточка «Перезапустить». Никогда не молчит.
    func requestCalendar() {
        guard let ctx = context, !ctx.isSnapshot else { return }
        ctx.dismissPermissionCard(.calendars)
        Task { [weak self] in
            _ = await Permissions.requestFromUser(.calendars, moduleId: ctx.moduleId)
            self?.reloadEvents()
        }
    }

    /// Включили модуль/плитку встречи: право через `ensurePermission` (окно — если не спрашивали; запрещено —
    /// карточка «Нужен доступ», не чаще раза за запуск). Модуль выключен — только статус.
    private func ensureCalendarAccess() {
        guard let ctx = context, !ctx.isSnapshot, CalendarService.access != .granted else { return }
        Task { [weak self] in
            _ = await ctx.ensurePermission(.calendars, reason: "Плитка «Следующее»: ближайшая встреча, отсчёт и «Подключиться»")
            self?.reloadEvents()
        }
    }


    /// Плитка «Следующее» (27.11: «календарь не открывается — должен быть сегодняшний сразу с событиями»): Календарь
    /// на сегодняшнем дне в виде «День»; есть событие — сразу оно.
    func openCalendar(_ e: TodayEvent?) {
        guard context?.isSnapshot != true else { return }
        if let e, let ek = e.id.split(separator: "@").first, !ek.isEmpty,
           let enc = String(ek).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let u = URL(string: "ical://ekevent/\(enc)?method=show&options=more") {
            NSWorkspace.shared.open(u)
            return
        }
        let script = """
            tell application "Calendar"
                activate
                switch view to day view
                view calendar at (current date)
            end tell
            """
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if err != nil {
                DispatchQueue.main.async {
                    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                        NSWorkspace.shared.openApplication(at: u, configuration: .init())
                    }
                }
            }
        }
    }

    /// Плитка погоды → приложение «Погода».
    func openWeather() {
        guard context?.isSnapshot != true else { return }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
        } else if let u = URL(string: "https://open-meteo.com") { NSWorkspace.shared.open(u) }
    }

    func join(_ e: TodayEvent) {
        guard let link = e.link else { return }
        let zoomInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil
        NSWorkspace.shared.open(MeetingLinks.preferredOpenURL(link, zoomAppInstalled: zoomInstalled))
        context?.removeActivity(id: Self.activityId)
    }

    static let activityId = "today.meeting"
    static let reminderLead: TimeInterval = 5 * 60
    static let reminderTail: TimeInterval = 3 * 60

    /// Один таймер на ближайший момент (за 5 мин до встречи / конец напоминания / полночь) — не опрос.
    /// Напоминание — по ближайшему *началу*: идущее длинное событие его не заслоняет. Плитка сама
    /// перерисовывается раз в минуту (TimelineView), отсчёт в компакте переключается в момент начала сам.
    private func scheduleEventTimer() {
        eventWork?.cancel(); eventWork = nil
        guard let ctx = context, nowOverride == nil else { return }
        let now = Date()
        var wake: [Date] = []
        if prefs.isEnabled(.event), let e = EventLogic.upcoming(events, now: now, grace: Self.reminderTail) {
            let showFrom = e.start.addingTimeInterval(-Self.reminderLead)
            let showTo = e.start.addingTimeInterval(Self.reminderTail)
            if now >= showFrom && now < showTo {
                ctx.post(Self.meetingActivity(e, staticCountdown: nil))
                wake.append(showTo)
            } else {
                ctx.removeActivity(id: Self.activityId)
                if showFrom > now { wake.append(showFrom) }
            }
        } else {
            ctx.removeActivity(id: Self.activityId)
        }
        // Смена дня — пересчитать полосу.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) {
            wake.append(midnight)
        }
        guard let at = wake.filter({ $0 > now }).min() else { return }
        // Разовый DispatchWorkItem по стенным часам (`wallDeadline` идёт и во сне), а не Timer.
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadEvents() } }
        eventWork = w
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSinceNow) + 0.5, execute: w)
    }

    /// Компакт-активность «встреча скоро»: слева значок и название, справа отсчёт.
    static func meetingActivity(_ e: TodayEvent, staticCountdown: String?) -> IslandActivity {
        IslandActivity(id: activityId, moduleId: moduleId, priority: 60, sideWidth: MeetingCompactLeading.sideWidth(for: e.title),
                       expiresAt: e.start.addingTimeInterval(reminderTail)) {
            MeetingCompactLeading(title: e.title)
        } trailing: {
            MeetingCompactTrailing(start: e.start, staticText: staticCountdown)
        }
    }

    // MARK: Погода

    /// Один запрос за раз. `force` (сменили город) отменяет идущий: ответ по старым координатам не нужен.
    func refreshWeather(force: Bool) {
        guard nowOverride == nil else { return }
        if !force, let w = weather, w.matches(prefs), Date().timeIntervalSince(w.fetchedAt) < WeatherAPI.cacheTTL { return }
        if weatherTask != nil {
            guard force else { return }
            weatherTask?.cancel()
        }
        weatherLoading = true
        let lat = prefs.latitude, lon = prefs.longitude
        weatherTask = Task { [weak self] in
            let result: Result<WeatherSnapshot, Error>
            do { result = .success(try await WeatherAPI.fetch(lat: lat, lon: lon)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.weatherTask = nil
            self.weatherLoading = false
            switch result {
            case .success(let w):
                // Город сменили в обход force (не должно быть) — просто спросить заново.
                guard w.matches(self.prefs) else { self.refreshWeather(force: true); return }
                self.weather = w
                self.weatherProblem = nil
                WeatherAPI.saveCached(w)
            case .failure(let e):
                self.weatherProblem = WeatherAPI.isNetworkError(e) ? .offline : .service
            }
        }
    }

    // MARK: Батареи

    private func refreshMacBattery() {
        var list = batteries.filter { $0.kind != .mac }
        if let m = Batteries.mac() { list.insert(m, at: 0) }
        if list != batteries { batteries = list }
    }

    private func refreshBatteries(bluetooth: Bool) {
        var list: [BatteryItem] = []
        if let m = Batteries.mac() { list.append(m) }
        // IORegistry не дёргаем чаще раза в минуту.
        if bluetooth, lastBluetoothRead.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            lastBluetoothRead = Date()
            list += Batteries.bluetooth()
        } else {
            list += batteries.filter { $0.kind != .mac }
        }
        batteries = list
    }

    // MARK: Буфер

    func copy(_ item: ClipItem) {
        clipboard.copyBack(item)
        copiedId = clips.first?.id
        let id = copiedId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { if self?.copiedId == id { self?.copiedId = nil } }
        }
    }

    func clearClipboard() { clipboard.clear() }

    // MARK: Тумблеры

    var availableToggles: [ToggleKind] {
        ToggleKind.allCases.filter { ($0 != .focus || focusShortcutName != nil) && !prefs.hiddenToggles.contains($0.rawValue) }
    }

    func isOn(_ k: ToggleKind) -> Bool {
        switch k {
        case .focus: return focusOn
        case .awake: return awake
        case .cleanDesk: return desktopHidden
        case .mirror: return mirrorOn
        case .mic: return micOff
        case .dark: return dark
        }
    }

    func refreshToggleStates() {
        dark = DarkMode.isOn
        micOff = mic.isOff()
        desktopHidden = CleanDesk.iconsHidden
        awake = awakeAssertion.isOn
    }

    private func lookUpFocusShortcut() {
        lastFocusLookup = Date()
        let preferred = prefs.focusShortcut
        Task { [weak self] in
            let names = await FocusShortcut.list()
            self?.focusShortcutName = FocusShortcut.pick(from: names, preferred: preferred)
        }
    }

    func toggle(_ k: ToggleKind) {
        guard !busy.contains(k), nowOverride == nil else { return }
        toggleError = nil
        switch k {
        case .awake:
            if awakeAssertion.set(!awake) { awake = awakeAssertion.isOn } else { toggleError = "Не удалось запретить сон" }
        case .dark:
            let target = !dark
            busy.insert(k)
            Task { [weak self] in
                guard let self else { return }
                // Право «Автоматизация → System Events» — через ядро. `.unknown` — System Events не запущен (ядро
                // спросить не может): osascript запустит его, и macOS спросит сама — запасной путь.
                let access = await self.ensureAutomationAccess()
                guard access == .granted || access == .unknown else {
                    self.busy.remove(k)
                    self.promptInTile(.automation, Self.systemEvents)
                    return
                }
                let r = await DarkMode.set(target)
                self.busy.remove(k)
                switch r {
                case .ok: self.dark = DarkMode.isOn == target ? target : DarkMode.isOn
                case .needsPermission: self.promptInTile(.automation, Self.systemEvents)
                case .failed: self.toggleError = "System Events не ответили"
                }
            }
        case .mic:
            toggleMic()
        case .mirror:
            if mirrorOn { mirror.stop(); mirrorOn = false; return }
            startMirror()
        case .cleanDesk:
            confirmCleanDesk = true
        case .focus:
            guard let name = focusShortcutName else { return }
            busy.insert(k)
            Task { [weak self] in
                let ok = await FocusShortcut.run(name)
                guard let self else { return }
                self.busy.remove(k)
                if ok { self.focusOn.toggle() } else { self.toggleError = "Ярлык «\(name)» не сработал" }
            }
        }
    }

    /// Зеркало включили: право на камеру — через ядро (`ensurePermission`: окно, если не спрашивали; запрещено —
    /// просьба в плитке). Ответ пришёл, когда вкладку уже закрыли, — камеру не включать.
    private func startMirror() {
        guard let ctx = context else { return }
        let run: @MainActor () -> Void = { [weak self] in
            guard let self, self.tabVisible, !self.mirrorOn else { return }
            self.mirror.start()
            if self.mirror.state == .needsPermission { self.promptInTile(.camera, .camera); return }
            if self.mirror.state == .noCamera { self.toggleError = "Камера не найдена"; return }
            self.mirrorOn = true
        }
        if ctx.permissionStatus(.camera) == .granted { run(); return }
        busy.insert(.mirror)
        Task { [weak self] in
            let s = await ctx.ensurePermission(.camera, reason: "Зеркало: камера в плитке «Быстрое», только пока она открыта")
            guard let self else { return }
            self.busy.remove(.mirror)
            if s == .granted { run() } else { self.promptInTile(.camera, .camera) }
        }
    }

    /// Права нет. Вкладка открыта — просьба в плитке, а карточку ядра «Нужен доступ» убрать (иначе та же просьба
    /// всплыла бы второй раз после сворачивания). Вкладку уже закрыли — плитку не трогать (устаревшая просьба
    /// всплыла бы при следующем открытии), остаётся карточка ядра.
    private func promptInTile(_ prompt: TodayPermission, _ p: IslandPermission) {
        guard tabVisible else { return }
        context?.dismissPermissionCard(p)
        permissionPrompt = prompt
    }

    /// Тёмная тема меняется через System Events.
    static let systemEvents = IslandPermission.automation(bundleId: "com.apple.systemevents")

    private func ensureAutomationAccess() async -> PermissionStatus {
        guard let ctx = context else { return .unknown }
        return await ctx.ensurePermission(Self.systemEvents, reason: "Тумблер «Тёмная»: переключает оформление macOS через System Events")
    }

    /// Кнопка «Автоматизация (тёмная тема)» в настройках модуля: запрещено — Системные настройки; не спрашивали —
    /// системное окно через ядро; System Events не запущен (`.unknown`) — безвредное чтение через osascript (оно
    /// запустит System Events, и macOS спросит сама). Ничего не меняет.
    func requestAutomation() async -> PermissionStatus {
        guard let ctx = context else { return .unknown }
        let p = Self.systemEvents
        // Кнопка не молчит: запущено из оболочки — «Перезапустить», запрещено раньше — раздел и карточка.
        if !LaunchKind.current.isApp {
            Permissions.showGuide(.relaunch(canRelaunch: LaunchKind.current.canRelaunch), for: p, moduleId: ctx.moduleId)
            return ctx.permissionStatus(p)
        }
        if ctx.permissionStatus(p) == .denied {
            Permissions.showGuide(.deniedBefore, for: p, moduleId: ctx.moduleId)
            return .denied
        }
        var s = await ensureAutomationAccess()
        if s == .unknown {
            switch await DarkMode.probeAccess() {
            case .ok: s = .granted
            case .needsPermission: s = .denied
            case .failed: s = .unknown
            }
        }
        if s != .granted && s != .unknown {
            // Вместо общей карточки «Нужен доступ» — раздел настроек и подсказка «что включить и где».
            ctx.dismissPermissionCard(p)
            Permissions.showGuide(.declined, for: p, moduleId: ctx.moduleId)
        }
        return s
    }

    /// Выключение — громкость входа 0 (или mute), прежняя громкость сохраняется в настройках модуля:
    /// после перезапуска «включить» вернёт её, а не 0,75. При выгрузке модуля/выходе микрофон возвращается.
    private func toggleMic() {
        guard let dev = mic.defaultInput() else { toggleError = "Нет микрофона"; return }
        if !micOff {
            if let cur = mic.volume(dev), cur > 0.001 { prefs.micSavedVolume = cur }
            let ok = mic.setVolume(dev, 0) || mic.setMuted(dev, true)
            if ok { micDevice = dev; prefs.micMutedByUs = true } else { toggleError = "Громкость входа не меняется" }
        } else {
            // Вернуть на то устройство, что выключали (вход могли сменить), и на текущее.
            let target = micDevice ?? dev
            var ok = mic.restore(target, volume: prefs.micSavedVolume ?? 0.75)
            if target != dev { ok = mic.restore(dev, volume: prefs.micSavedVolume ?? 0.75) || ok }
            if !ok { toggleError = "Громкость входа не меняется" }
            micDevice = nil; prefs.micMutedByUs = false
        }
        micOff = mic.isOff()
    }

    /// stop() — выход приложения (меню «Выход», SIGTERM/SIGINT/SIGHUP через обработчик выхода ядра → stop()):
    /// вернуть микрофон, если его выключил тумблер. Настройки ядро сохраняет после stop().
    func restoreMicIfNeeded() {
        guard prefs.micMutedByUs, let dev = micDevice else { return }
        mic.restore(dev, volume: prefs.micSavedVolume ?? 0.75)
        micDevice = nil
        prefs.micMutedByUs = false
        micOff = mic.isOff()
    }

    func confirmCleanDesk(_ yes: Bool) {
        confirmCleanDesk = false
        guard yes else { return }
        let target = !desktopHidden
        busy.insert(.cleanDesk)
        Task { [weak self] in
            let ok = await CleanDesk.setIconsHidden(target)
            guard let self else { return }
            self.busy.remove(.cleanDesk)
            self.desktopHidden = CleanDesk.iconsHidden
            if !ok { self.toggleError = "Не удалось изменить настройку Finder" }
        }
    }
}

enum WeatherProblem: Equatable, Sendable {
    /// Нет сети (URLError подключения) — «нет сети».
    case offline
    /// Сеть есть, но сервис ответил ошибкой или ответ не разобрался.
    case service
}

extension WeatherSnapshot {
    func matches(_ p: TodayPrefs) -> Bool {
        abs(latitude - p.latitude) < 0.0001 && abs(longitude - p.longitude) < 0.0001
    }
}
