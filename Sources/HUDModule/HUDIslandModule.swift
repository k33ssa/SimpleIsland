import CoreAudio
import AppKit
import Combine
import SwiftUI
import IslandCore

/// Модуль «HUD»: вспышки громкости/яркости/подсветки и системных событий по бокам выреза (макет 06).
/// Вкладки нет. Всё — на событиях (CoreAudio, IOPS, TIS, CoreMediaIO, NWPathMonitor, IOBluetooth, event tap),
/// таймеров и тикеров нет ни в покое, ни во вспышке (разовые дела — `DispatchWorkItem` с отменой).
/// Права: Универсальный доступ (клавиши, Caps Lock), Bluetooth (наушники) — без них остальное работает,
/// в настройках — «Разрешить…». Сон/пробуждение, экраны, сессия — через `context.onSystemEvent`: после
/// пробуждения слушатели перевешиваются (`rewire`). VPN не показываем — его даёт отдельный модуль (Vafa).
@MainActor
public final class HUDIslandModule: IslandModule {
    public let id = "hud"
    public let title = "HUD"
    public let systemImage = "sun.max.fill"
    public var providesTab: Bool { false }
    public var expandedHeight: CGFloat { 120 }

    private weak var context: ModuleContext?
    private var prefs = HUDPrefs()
    private var settingsModel: HUDSettingsModel?
    var settingsModelForTest: HUDSettingsModel? { settingsModel }

    let audio = AudioWatcher()
    /// Громкость клавишами — без ожидания устройства (25.11: «лагает»; USB-карта отвечает ~130 мс на вызов, а на нажатие
    /// было 3–4 вызова в главном потоке ≈ 375 мс). Вспышка — сразу по расчёту, установка — на своей очереди;
    /// частые нажатия считаются от последней цели, а не от медленно обновляющегося устройства.
    private let volumeApplier = VolumeApplier()
    private var volumeTarget: (value: Double, device: AudioObjectID, at: Date)?
    private var volumeSettable: [AudioObjectID: Bool] = [:]
    let tap = MediaKeyTap()
    let power = PowerWatcher()
    let input = InputWatcher()
    let capture = CaptureWatcher()
    let network = NetworkWatcher()
    let bluetooth = BluetoothWatcher()

    private var axObserver: NSObjectProtocol?
    /// Возврат в приложение (доступ к Bluetooth могли выдать в Системных настройках).
    private var appObservers: [NSObjectProtocol] = []
    /// Подписка на системные события ядра (сон, экраны, сессия, блокировка).
    private var systemToken: Int?
    /// Пачка событий пробуждения (didWake + screensDidWake + screensChanged) → одно перевешивание.
    private var rewireWork: DispatchWorkItem?
    static let rewireDelay: TimeInterval = 0.3
    /// Сколько раз перевешивали слушатели по системным событиям (для самотеста).
    private(set) var rewireCount = 0
    private var lastBTAccess = BluetoothWatcher.access
    private var axWork: DispatchWorkItem?
    private var lastAX = false
    private var camShown = false
    private var micShown = false
    /// Яркость/подсветка в режиме наблюдения: прочитать значение чуть позже, когда система его применит.
    private var readBackWork: DispatchWorkItem?

    public init() {}

    // MARK: Жизненный цикл

    public func start(context: ModuleContext) {
        self.context = context
        prefs = context.loadSettings(HUDPrefs.self) ?? HUDPrefs()
        lastAX = AccessibilityAccess.isTrusted
        wire()
        let model = makeSettingsModel()
        settingsModel = model
        // Выдали/отозвали Универсальный доступ — система рассылает это уведомление; перепроверить и пересобрать tap.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAXRecheck() }
        }
        let nc = NotificationCenter.default
        appObservers = [
            // Доступ к Bluetooth могли выдать в Системных настройках, не нажимая «Разрешить…».
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.recheckEnvironment() }
            },
        ]
        // Сон, экраны (уже склеенные ядром), сессия, блокировка. Встроенный экран появился/пропал (крышка) —
        // это `.screensChanged`: от него зависит перехват яркости.
        systemToken = context.onSystemEvent { [weak self] e in self?.systemEvent(e) }
        // Переключатель в онбординге пишет настройки модуля снаружи (`HUDSystemIndicators`) — подхватить.
        settingsSink = context.settings.$data
            .map { $0.moduleSettings["hud"] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reloadPrefsFromSettings() } }
            }
        routerSink = router.$wantsKeys.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateTap() } }
        }
        apply()
    }

    private var settingsSink: AnyCancellable?
    /// «Медиа» захотела/расхотела медиаклавиши (мост ядра) — пересчитать режим tap.
    private var routerSink: AnyCancellable?
    /// Мост медиаклавиш (самотест подставляет свой).
    var router = MediaKeyRouter.shared

    /// Настройки модуля поменялись не через его окно (онбординг) — перечитать и применить.
    func reloadPrefsFromSettings() {
        guard let context, let p = context.loadSettings(HUDPrefs.self), p != prefs else { return }
        prefs = p
        settingsModel?.prefs = p
        apply()
    }

    public func stop() {
        tap.stop()
        audio.stop()
        power.stop()
        input.stop()
        capture.stop()
        network.stop()
        bluetooth.stop()
        if let o = axObserver { DistributedNotificationCenter.default().removeObserver(o) }
        axObserver = nil
        for o in appObservers { NotificationCenter.default.removeObserver(o) }
        appObservers.removeAll()
        settingsSink = nil
        routerSink = nil
        router.setTapActive(false)
        if let t = systemToken { context?.system.removeHandler(owner: id, token: t) }
        systemToken = nil
        rewireWork?.cancel(); rewireWork = nil
        camShown = false; micShown = false
        axWork?.cancel(); axWork = nil
        readBackWork?.cancel(); readBackWork = nil
        context?.activities.removeAll(moduleId: id)
        context = nil
    }

    public func settingsView() -> AnyView? {
        guard let context, let model = settingsModel else { return nil }
        return AnyView(HUDSettingsView(model: model, settings: context.settings))
    }

    /// Сколько системных подписок сейчас висит (для самотеста: после stop() — 0).
    var activeSubscriptions: Int {
        audio.listenerCount + capture.listenerCount + (tap.isRunning ? 1 : 0) + (power.isRunning ? 1 : 0)
            + (input.watchesLayout ? 1 : 0) + (input.watchesCaps ? 1 : 0) + (network.isRunning ? 1 : 0)
            + (bluetooth.isRunning ? 1 : 0) + (axObserver != nil ? 1 : 0) + appObservers.count
            + (systemToken != nil ? 1 : 0)
    }

    /// Отложенные дела модуля (в покое — 0: ничего не ждёт и процесс не будит).
    var pendingWork: Int {
        (axWork != nil ? 1 : 0) + (readBackWork != nil ? 1 : 0) + (rewireWork != nil ? 1 : 0)
            + network.pendingWorkCount + (bluetooth.profiler.isRunning ? 1 : 0) + bluetooth.pendingCount
    }

    // MARK: Сон, экраны, сессия

    /// Системное событие от ядра (`SystemStateCenter`): на сон — тишина сети и tap снят; на пробуждение,
    /// смену экранов и возврат сессии — перевесить слушатели (склеено в один проход).
    func systemEvent(_ e: IslandSystemEvent) {
        guard context != nil else { return }
        switch e {
        case .willSleep:
            network.willSleep()
            readBackWork?.cancel(); readBackWork = nil
            rewireWork?.cancel(); rewireWork = nil
            tap.stop() // система всё равно выключит его во сне; на пробуждении — новый
        case .didWake:
            network.didWake()
            scheduleRewire()
        case .screensDidWake, .screensChanged, .sessionDidBecomeActive:
            scheduleRewire()
        case .screenLocked, .sessionDidResignActive:
            // Экран входа / чужая сессия: клавиши — системе (наш остров там не виден, иначе громкость менялась бы
            // без индикатора).
            updateTap()
        case .screenUnlocked:
            updateTap()
        case .screensDidSleep, .motionChanged:
            break
        }
    }

    private func scheduleRewire() {
        rewireWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.rewireWork = nil
                self?.rewire()
            }
        }
        rewireWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rewireDelay, execute: w)
    }

    /// Перевесить всё, что система могла потерять во сне или при смене экранов/сессии: слушатели CoreAudio
    /// (устройство вывода могло смениться), камеру/микрофон (перечитать — камеру могли выключить во сне), event tap
    /// (новый), IOBluetooth-уведомления (отложенные карточки подключения не теряются), раскладку и Caps Lock;
    /// перепроверить права и встроенный экран (яркость). Без вспышек. Открыто для самотеста.
    func rewire() {
        guard context != nil else { return }
        rewireWork?.cancel(); rewireWork = nil
        rewireCount += 1
        audio.rewire()
        input.rewire()
        capture.rewire()
        bluetooth.rewire()
        tap.stop()
        updateTap()
        recheckEnvironment()
    }

    /// Клавиши перехватываем, только пока сессия наша, экран не заблокирован и Мак не спит.
    private var keysAllowed: Bool {
        let s = SystemStateCenter.shared
        return s.isSessionActive && !s.isScreenLocked && !s.isAsleep
    }

    private func makeSettingsModel() -> HUDSettingsModel {
        let m = HUDSettingsModel(prefs: prefs)
        m.onPrefsChange = { [weak self] p in
            guard let self else { return }
            self.prefs = p
            self.context?.saveSettings(p)
            self.apply()
        }
        m.onRequestAccessibility = { AccessibilityAccess.request() }
        m.onAppear = { [weak self] in self?.recheckEnvironment() }
        m.onRequestBluetooth = { [weak self] in self?.bluetooth.requestAccess() }
        m.onPreview = { [weak self] kind in self?.preview(kind) }
        return m
    }

    func wire() {
        audio.onChange = { [weak self] s, _ in
            guard let self, self.prefs.volume else { return }
            // Громкость сейчас меняют клавишами — вспышку ведёт расчёт по клавишам, не запоздалое значение устройства
            // (иначе полоска дёргалась назад-вперёд).
            if let t = self.volumeTarget, t.device == s.device, Date().timeIntervalSince(t.at) < 1.5 { return }
            self.flash(HUDFlashes.volume(s.volume, muted: s.muted, device: s.name, style: nil, fallback: self.barStyle,
                                         theme: self.theme))
        }
        tap.handler = { [weak self] e in self?.handleKey(e) ?? false }
        tap.releaseHandler = { [weak self] e in self?.releaseKey(e) }
        power.onEvent = { [weak self] e, s in self?.powerEvent(e, s) }
        input.onLayout = { [weak self] from, to in
            guard let self, self.prefs.layout else { return }
            self.flash(HUDFlashes.layout(from: from, to: to, capsOn: self.input.capsOn, theme: self.theme))
        }
        input.onCaps = { [weak self] on in
            guard let self, self.prefs.capsLock else { return }
            self.flash(HUDFlashes.capsLock(on: on, theme: self.theme))
        }
        capture.onChange = { [weak self] cam, mic, app, _ in self?.captureChanged(camera: cam, microphone: mic, app: app) }
        network.onNetwork = { [weak self] online, iface in
            guard let self, self.prefs.network else { return }
            self.flash(HUDFlashes.network(online: online, interface: iface, theme: self.theme), long: true)
        }
        bluetooth.onConnect = { [weak self] name, battery in
            guard let self, self.prefs.headphones else { return }
            self.context?.showNotification(HUDFlashes.headphonesConnected(name: name, battery: battery))
        }
        // Заряд пришёл позже (system_profiler) — та же карточка (`hud.bt.<имя>`) обновляется на месте; уже ушла —
        // заново не показываем.
        bluetooth.onBattery = { [weak self] name, battery in
            guard let self, self.prefs.headphones else { return }
            self.context?.notifications.replace(HUDFlashes.headphonesConnected(name: name, battery: battery))
        }
        bluetooth.onDisconnect = { [weak self] name in
            guard let self, self.prefs.headphones else { return }
            self.flash(HUDFlashes.headphonesDisconnected(name: name, theme: self.theme))
        }
        bluetooth.onAccessChange = { [weak self] a in
            guard let self else { return }
            self.lastBTAccess = a
            self.settingsModel?.bluetoothAccess = a
            self.apply()
        }
    }

    private var theme: Theme { context?.theme ?? .obsidian }
    /// Стиль полосы из настроек — по нему ширина уха у вспышек без своего стиля.
    private var barStyle: HUDBarStyle { context?.settings.data.hudStyle ?? .thread }

    /// Перепроверить то, о чём система не сообщает отдельным событием: доступ к Bluetooth (выдали в
    /// Конфиденциальности), Универсальный доступ, встроенный экран (яркость). Дёшево: без опроса, по событиям
    /// «экраны изменились», «приложение стало активным», «открыли настройки».
    func recheckEnvironment() {
        guard context != nil else { return }
        let bt = BluetoothWatcher.access
        if bt != lastBTAccess {
            lastBTAccess = bt
            apply() // запустит/остановит Bluetooth и пересчитает tap
            return
        }
        if AccessibilityAccess.isTrusted != lastAX { scheduleAXRecheck(); return }
        updateTap()
        refreshSettingsModel()
    }

    /// Запустить/остановить источники под текущие настройки и права.
    private func apply() {
        guard context != nil else { return }
        let p = prefs
        if p.volume { audio.start() } else { audio.stop() }
        if p.charging || p.lowBattery { power.start() } else { power.stop() }
        if p.layout { input.startLayout() } else { input.stopLayout() }
        if p.capsLock { input.startCaps() } else { input.stopCaps() }
        if p.camera || p.microphone {
            capture.start()
        } else {
            capture.stop(); clearCaptureActivity()
            camShown = false; micShown = false // при новом запуске первая вспышка должна прийти
        }
        if !p.captureActivity { clearCaptureActivity() }
        if p.network { network.start() } else { network.stop() }
        if p.headphones { bluetooth.start() } else { bluetooth.stop() }
        updateTap()
        refreshSettingsModel()
    }

    private func updateTap() {
        let p = prefs
        let ax = AccessibilityAccess.isTrusted
        let brightnessOK = p.brightness && DisplayBrightness.shared.isAvailable
        let keyboardOK = p.keyboard && KeyboardBacklight.shared.isAvailable
        let replace = p.replaces(axGranted: ax)
        // Медиаклавиши для музыки («Медиа» через мост) — tap активный и без замены системного HUD: громкость и яркость
        // тогда всё равно проходят системе (`handleKey` смотрит `replacing`).
        let wantsActive = (replace && (p.volume || brightnessOK || keyboardOK)) || router.wantsKeys
        let wantsListen = !replace && (brightnessOK || keyboardOK)
        if !keysAllowed {
            tap.stop()
        } else if ax && wantsActive {
            tap.start(mode: .active)
        } else if ax && wantsListen {
            tap.start(mode: .listen)
        } else {
            tap.stop()
        }
        router.setTapActive(tap.mode == .active)
    }

    private func refreshSettingsModel() {
        guard let m = settingsModel else { return }
        m.accessibilityGranted = AccessibilityAccess.isTrusted
        m.bluetoothAccess = BluetoothWatcher.access
        m.tapRunning = tap.isRunning
        m.brightnessAvailable = DisplayBrightness.shared.isAvailable
        m.keyboardAvailable = KeyboardBacklight.shared.isAvailable
        m.hasBattery = power.last?.hasBattery ?? (PowerWatcher.read()?.hasBattery ?? false)
    }

    private func scheduleAXRecheck() {
        axWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.context != nil else { return }
                let ax = AccessibilityAccess.isTrusted
                if ax != self.lastAX {
                    self.lastAX = ax
                    // Монитор клавиатуры, созданный без доступа, событий не получает — пересоздать.
                    if self.prefs.capsLock { self.input.stopCaps(); self.input.startCaps() }
                }
                self.updateTap()
                self.refreshSettingsModel()
            }
        }
        axWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: Клавиши

    /// Нажатие системной клавиши. true — обработали сами (в активном режиме событие проглатывается).
    func handleKey(_ e: MediaKeyEvent) -> Bool {
        if let t = e.key.transport {
            // ⏯ ⏭ ⏮ — «Медиа» решает, кому их отдать (последнее музыкальное приложение или система).
            guard tap.mode == .active else { return false }
            return router.handle(MediaTransportPress(key: t, phase: e.isRepeat ? .repeating : .down))
        }
        guard !e.optionOnly else { return false } // ⌥ + клавиша — система открывает настройки
        let p = prefs
        // Tap может быть активным ради медиаклавиш, а замена системного HUD выключена — тогда громкость и яркость
        // не трогаем (как в режиме наблюдения).
        let active = tap.mode == .active && p.replaces(axGranted: AccessibilityAccess.isTrusted)
        if e.key.isVolume {
            // Громкость видна через CoreAudio и без перехвата; сами меняем только в режиме замены.
            guard active, p.volume else { return false }
            guard let s = audio.state ?? audio.read() else { return false }
            let dev = s.device
            if volumeSettable[dev] == nil { volumeSettable[dev] = audio.canSetVolume() }
            guard volumeSettable[dev] == true else { return false }
            if e.key == .mute {
                guard !e.isRepeat else { return true }
                audio.setMuted(!s.muted)
                if let n = audio.read() {
                    flash(HUDFlashes.volume(n.volume, muted: n.muted, device: n.name, style: nil, fallback: barStyle, theme: theme))
                }
                return true
            }
            if s.muted { audio.setMuted(false) }
            let base: Double = {
                if let t = volumeTarget, t.device == dev, Date().timeIntervalSince(t.at) < 1.5 { return t.value }
                return s.volume
            }()
            let up = e.key.isUp
            let v = HUDStep.apply(base, up: up, fine: e.fine)
            volumeTarget = (v, dev, Date())
            flash(HUDFlashes.volume(v, muted: false, device: s.name, style: nil, fallback: barStyle, theme: theme))
            // Одна установка за раз, только последняя цель (25.11: при удержании автоповтор ~30/с ставил в очередь
            // установки по 130–260 мс, и громкость ползла секундами после отпускания).
            volumeApplier.submit(dev: dev, target: v, base: base, up: up) { [weak self] got in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let t = self.volumeTarget, t.device == dev, t.value == v else { return }
                        self.volumeTarget = (got, dev, Date())
                        if abs(got - v) > 0.004 {
                            self.flash(HUDFlashes.volume(got, muted: false, device: s.name, style: nil,
                                                         fallback: self.barStyle, theme: self.theme))
                        }
                    }
                }
            }
            return true
        }
        if e.key.isBrightness {
            let d = DisplayBrightness.shared
            guard p.brightness, d.isAvailable else { return false }
            guard active else { readBack(brightness: true); return false }
            guard let cur = d.get() else { return false }
            let v = HUDStep.apply(cur, up: e.key.isUp, fine: e.fine)
            guard d.set(v) else { return false }
            flashBrightness(v)
            return true
        }
        if e.key.isIllumination {
            let k = KeyboardBacklight.shared
            guard p.keyboard, k.isAvailable else { return false }
            guard active else { readBack(brightness: false); return false }
            guard let cur = k.get() else { return false }
            let v = HUDStep.apply(cur, up: e.key.isUp, fine: e.fine)
            guard k.set(v) else { return false }
            flashKeyboard(v)
            return true
        }
        return false
    }

    /// Отпущена проглоченная клавиша: для ⏭/⏮ — конец удержания (перемотки) или короткое нажатие.
    func releaseKey(_ e: MediaKeyEvent) {
        guard let t = e.key.transport else { return }
        _ = router.handle(MediaTransportPress(key: t, phase: .up))
    }

    /// Режим наблюдения: система сама меняет яркость, и плавно — прочитать результат через 0,12 с (вспышка сразу)
    /// и ещё раз через 0,45 с, когда переход закончился (та же вспышка обновится, если значение ушло дальше).
    private func readBack(brightness: Bool) {
        readBackWork?.cancel()
        var shown: Double?
        func read() -> Double? { brightness ? DisplayBrightness.shared.get() : KeyboardBacklight.shared.get() }
        func show(_ v: Double) { if brightness { flashBrightness(v) } else { flashKeyboard(v) } }
        let second = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self != nil, let v = read() else { return }
                if shown.map({ abs($0 - v) > 0.004 }) ?? true { show(v) }
            }
        }
        let first = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let v = read() { show(v); shown = v }
                self.readBackWork = second
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.33, execute: second)
            }
        }
        readBackWork = first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: first)
    }

    private func flashBrightness(_ v: Double) {
        guard let c = context else { return }
        flash(HUDFlashes.brightness(v, auto: DisplayBrightness.shared.isAutoBrightness == true, style: nil,
                                    fallback: barStyle, theme: c.theme))
    }

    private func flashKeyboard(_ v: Double) {
        flash(HUDFlashes.keyboard(v, style: prefs.keyboardSegments ? .segments : nil, fallback: barStyle, theme: theme))
    }

    // MARK: События

    func powerEvent(_ e: PowerEvent, _ s: PowerSnapshot) {
        let t = theme, notch = HUDMeasure.liveNotchWidth()
        switch e {
        case .pluggedIn where prefs.charging, .chargingDetails where prefs.charging:
            // chargingDetails: та же вспышка kind "battery" — если ещё видна, обновится на месте.
            flash(HUDFlashes.charging(percent: s.percent, minutesToFull: s.minutesToFull, isCharging: s.isCharging,
                                      theme: t, notch: notch), long: true)
        case .unplugged where prefs.charging:
            flash(HUDFlashes.unplugged(percent: s.percent, minutesToEmpty: s.minutesToEmpty, theme: t, notch: notch), long: true)
        case .charged where prefs.charging:
            flash(HUDFlashes.charged(percent: s.percent, theme: t, notch: notch), long: true)
        case .low(let pct) where prefs.lowBattery:
            flash(HUDFlashes.lowBattery(percent: pct, theme: t, notch: notch), long: true)
        default:
            break
        }
    }

    func captureChanged(camera: Bool, microphone: Bool, app: String?) {
        let cam = camera && prefs.camera
        let mic = microphone && prefs.microphone
        let rising = (cam && !camShown) || (mic && !micShown)
        camShown = cam; micShown = mic
        if rising { flash(HUDFlashes.capture(camera: cam, microphone: mic, app: app, theme: theme), long: true) }
        if prefs.captureActivity, cam || mic {
            context?.post(Self.captureActivity(camera: cam, microphone: mic, app: app, theme: theme))
        } else {
            clearCaptureActivity()
        }
    }

    static func captureActivity(camera: Bool, microphone: Bool, app: String?, theme: Theme) -> IslandActivity {
        let note = HUDFlashes.fitNote(app ?? (camera ? "камера" : "микрофон"), theme: theme)
        // Компакт: отступ ядра 10 + зазор у выреза.
        let side = min(HUDMeasure.maxSide, max(78, ceil(max(HUDFlashes.captureIconsWidth(camera: camera, microphone: microphone),
                                                          HUDFlashes.noteWidth(note, theme: theme)) + 10 + HUDMeasure.notchGap)))
        return IslandActivity(id: "hud.capture", moduleId: "hud", priority: 30, sideWidth: side) {
            CaptureIcons(camera: camera, microphone: microphone)
        } trailing: {
            HUDNote(text: note)
        }
    }

    private func clearCaptureActivity() { context?.removeActivity(id: "hud.capture") }

    private func flash(_ e: HUDEvent, long: Bool = false) {
        guard let c = context else { return }
        let base = c.settings.data.hudDuration
        c.flashHUD(e, duration: long ? max(2.4, base * 2) : base)
    }

    /// Кнопки «Показать пример» в настройках — на живых значениях, где они есть.
    private func preview(_ kind: String) {
        switch kind {
        case "volume":
            let s = audio.read() ?? AudioWatcher.State(device: 0, name: "Динамики", volume: 0.62, muted: false)
            flash(HUDFlashes.volume(s.volume, muted: s.muted, device: s.name, style: nil, fallback: barStyle, theme: theme))
        case "charging":
            let s = power.last ?? PowerWatcher.read()
            flash(HUDFlashes.charging(percent: s?.percent ?? 78, minutesToFull: s?.minutesToFull ?? 34, isCharging: true,
                                      theme: theme, notch: HUDMeasure.liveNotchWidth()), long: true)
        default:
            let to = InputWatcher.currentLayoutCode() ?? "RU"
            flash(HUDFlashes.layout(from: to == "RU" ? "EN" : "RU", to: to, capsOn: InputWatcher.capsLockState(), theme: theme))
        }
    }

    // MARK: Снимки

    public func snapshotStates() -> [ModuleSnapshot] {
        var out: [ModuleSnapshot] = []
        for style in HUDBarStyle.allCases {
            out.append(ModuleSnapshot("volume-\(style.rawValue)") { ctx in
                ctx.hud.show(HUDFlashes.volume(0.62, muted: false, device: "AirPods Pro", style: style, theme: ctx.theme))
            })
            out.append(ModuleSnapshot("brightness-\(style.rawValue)") { ctx in
                ctx.hud.show(HUDFlashes.brightness(0.8, style: style, theme: ctx.theme))
            })
            out.append(ModuleSnapshot("keyboard-\(style.rawValue)") { ctx in
                ctx.hud.show(HUDFlashes.keyboard(0.6, style: style, theme: ctx.theme))
            })
        }
        out += [
            ModuleSnapshot("volume-muted") { ctx in
                ctx.hud.show(HUDFlashes.volume(0.62, muted: true, device: "Динамики MacBook Pro", style: nil, theme: ctx.theme))
            },
            ModuleSnapshot("charging") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 78, minutesToFull: 34, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("charged") { ctx in ctx.hud.show(HUDFlashes.charged(percent: 100, theme: ctx.theme)) },
            ModuleSnapshot("unplugged") { ctx in
                ctx.hud.show(HUDFlashes.unplugged(percent: 64, minutesToEmpty: 312, theme: ctx.theme))
            },
            ModuleSnapshot("battery-low") { ctx in ctx.hud.show(HUDFlashes.lowBattery(percent: 10, theme: ctx.theme)) },
            ModuleSnapshot("airpods") { ctx in
                ctx.notifications.show(HUDFlashes.headphonesConnected(
                    name: "AirPods Pro", battery: HeadphonesBattery(left: 82, right: 80, caseLevel: 54)))
            },
            ModuleSnapshot("brightness-auto") { ctx in
                ctx.hud.show(HUDFlashes.brightness(0.8, auto: true, style: .thread, theme: ctx.theme))
            },
            ModuleSnapshot("headphones-single") { ctx in
                ctx.notifications.show(HUDFlashes.headphonesConnected(name: "Beats Studio Pro", battery: HeadphonesBattery(single: 64)))
            },
            ModuleSnapshot("headphones-nobattery") { ctx in
                ctx.notifications.show(HUDFlashes.headphonesConnected(name: "Sony WH-1000XM5", battery: nil))
            },
            ModuleSnapshot("headphones-off") { ctx in ctx.hud.show(HUDFlashes.headphonesDisconnected(name: "AirPods Pro", theme: ctx.theme)) },
            ModuleSnapshot("layout") { ctx in ctx.hud.show(HUDFlashes.layout(from: "EN", to: "RU", capsOn: false, theme: ctx.theme)) },
            ModuleSnapshot("layout-caps") { ctx in ctx.hud.show(HUDFlashes.layout(from: "RU", to: "EN", capsOn: true, theme: ctx.theme)) },
            ModuleSnapshot("capslock-on") { ctx in ctx.hud.show(HUDFlashes.capsLock(on: true, theme: ctx.theme)) },
            ModuleSnapshot("capslock-off") { ctx in ctx.hud.show(HUDFlashes.capsLock(on: false, theme: ctx.theme)) },
            ModuleSnapshot("camera") { ctx in
                ctx.hud.show(HUDFlashes.capture(camera: true, microphone: false, app: "Телемост", theme: ctx.theme))
            },
            ModuleSnapshot("camera-mic") { ctx in
                ctx.hud.show(HUDFlashes.capture(camera: true, microphone: true, app: "Telegram", theme: ctx.theme))
            },
            ModuleSnapshot("microphone") { ctx in
                ctx.hud.show(HUDFlashes.capture(camera: false, microphone: true, app: nil, theme: ctx.theme))
            },
            ModuleSnapshot("capture-compact", presentation: .compact) { ctx in
                ctx.post(Self.captureActivity(camera: true, microphone: true, app: "Телемост", theme: ctx.theme))
            },
            ModuleSnapshot("network-off") { ctx in ctx.hud.show(HUDFlashes.network(online: false, interface: nil, theme: ctx.theme)) },
            ModuleSnapshot("microphone-longname") { ctx in
                ctx.hud.show(HUDFlashes.capture(camera: false, microphone: true,
                                                app: "Microsoft Teams (work or school) +2", theme: ctx.theme))
            },
            ModuleSnapshot("volume-longname") { ctx in
                ctx.hud.show(HUDFlashes.volume(0.4, muted: false, device: "Внешние динамики LG UltraFine 5K Display",
                                               style: nil, theme: ctx.theme))
            },
            ModuleSnapshot("charging-90") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 90, minutesToFull: 12, isCharging: true, theme: ctx.theme))
            },
            // Шкала по крыльям вокруг выреза (16.11): до выреза, рядом с ним с обеих сторон, 63 % живого скрина, почти полная.
            ModuleSnapshot("charging-10") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 10, minutesToFull: 118, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("charging-45") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 45, minutesToFull: 64, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("charging-55") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 55, minutesToFull: 52, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("charging-63") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 63, minutesToFull: 41, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("charging-95") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 95, minutesToFull: 6, isCharging: true, theme: ctx.theme))
            },
            ModuleSnapshot("volume-fill-35") { ctx in
                ctx.hud.show(HUDFlashes.volume(0.35, muted: false, device: "AirPods Pro", style: .fill, theme: ctx.theme))
            },
            ModuleSnapshot("charging-plugged") { ctx in
                ctx.hud.show(HUDFlashes.charging(percent: 31, minutesToFull: nil, isCharging: false, theme: ctx.theme))
            },
            ModuleSnapshot("network-on") { ctx in ctx.hud.show(HUDFlashes.network(online: true, interface: "Wi-Fi", theme: ctx.theme)) },
        ]
        return out
    }
}

/// «Заменить системные индикаторы» для онбординга (и других мест вне окна модуля): читает и пишет настройки модуля
/// HUD в `settings.json`; модуль подхватывает изменение сам (`reloadPrefsFromSettings`).
@MainActor
public enum HUDSystemIndicators {
    /// Заменяет ли остров системные индикаторы сейчас (выбор пользователя или «да, если есть доступ»).
    public static func isOn(_ settings: SimpleIslandSettings) -> Bool {
        let p = settings.moduleValue(HUDPrefs.self, for: "hud") ?? HUDPrefs()
        return p.replaces(axGranted: AccessibilityAccess.isTrusted)
    }

    /// Включить/выключить; включили без Универсального доступа — запросить его (системное окно или карточка ядра).
    public static func set(_ on: Bool, settings: SimpleIslandSettings) {
        var p = settings.moduleValue(HUDPrefs.self, for: "hud") ?? HUDPrefs()
        p.setReplaces(on)
        settings.setModuleValue(p, for: "hud")
        if on && !AccessibilityAccess.isTrusted { AccessibilityAccess.request() }
    }
}


/// Установка громкости вне главного потока с объединением: пока идёт установка, новые цели только заменяют ожидающую;
/// после неё применяется последняя. Дожим до ступени устройства — только для последней цели.
final class VolumeApplier: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (dev: AudioObjectID, target: Double, base: Double, up: Bool, done: @Sendable (Double) -> Void)?
    private var busy = false
    private let queue = DispatchQueue(label: "local.simpleisland.hud.volume", qos: .userInteractive)

    func submit(dev: AudioObjectID, target: Double, base: Double, up: Bool, done: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        pending = (dev, target, base, up, done)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else { busy = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            if let got = AudioWatcher.applyVolume(job.dev, target: job.target, from: job.base, up: job.up) {
                lock.lock(); let newer = pending != nil; lock.unlock()
                if !newer { job.done(got) }
            }
        }
    }
}
