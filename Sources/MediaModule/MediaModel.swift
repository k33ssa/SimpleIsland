import AppKit
import Combine
import IslandCore
import os
import SwiftUI

/// Журнал обложек: откуда пришла, какой id, показана / выброшена и почему, дозапросы.
/// `/usr/bin/log show --last 30m --predicate 'subsystem == "local.simpleisland" AND category == "artwork"'`.
enum ArtworkLog {
    static let log = Logger(subsystem: "local.simpleisland", category: "artwork")
    /// Самотест / `--selftest-media watch`: ещё и в stdout.
    nonisolated(unsafe) static var echo = false
    static func note(_ s: String) {
        log.notice("\(s, privacy: .public)")
        if echo {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            print("artwork \(f.string(from: Date())) \(s)")
        }
    }
    static func source(_ id: String) -> String { id.hasPrefix("script-") ? "applescript" : "mediaremote" }
}

/// Настройки модуля (settings.json → moduleSettings.media).
struct MediaPrefs: Codable, Equatable {
    var source: MediaSourcePreference = .auto
    /// Компакт + строка текста песни (макет 01, «свёрнутый + строка текста»).
    var compactLyrics = false
    /// Раскрывать вкладку, когда начинается воспроизведение.
    var openOnPlay = false
    /// Искать текст песни (сеть: каскад LyricsCore). Только для Музыки, Spotify и того, что источник назвал музыкой.
    var lyricsEnabled = true
    /// Выключенные источники текстов (`LyricsSourceKind.rawValue`); по умолчанию включены все.
    var lyricsSourcesOff: [String] = []
    /// Порядок опроса источников (`LyricsSourceKind.rawValue`; пусто — по умолчанию). Новые источники встают на место
    /// по умолчанию (`LyricsSourceKind.ordered`).
    var lyricsSourceOrder: [String] = []
    /// Искать текст и для браузеров/других плееров (их названия — часто видео, не песни — уходят в LRCLIB).
    var lyricsAnyApp = false
    /// Эквалайзер по настоящему звуку (захват системного звука, право «Запись системного звука»). Выкл. — псевдополоски.
    var liveVisualizer = true   // по умолчанию включено (решение пользователя 15.11)
    /// Вид эквалайзера в компакте (лист eq-v2: №1/№3/№8; классика — прежние градиентные). По умолчанию №8 — выбор
    /// пользователя 16.11 («все 3 норм, оставь в настройках, мне поставь 8»).
    var eqStyle: VisualizerStyle = .reflection
    /// Короткая вспышка «обложка + название» на смену трека. По умолчанию выкл.: компакт обновляется сам (UX 15.11).
    var flashOnTrackChange = false
    /// Медиаклавиши ⏯ ⏭ ⏮ управляют музыкой (15.11: «клавиши чисто для музыки в приоритете всегда»). Нужен
    /// Универсальный доступ (tap HUD); без него — как в системе.
    var mediaKeys = true
    var mediaKeysTarget: MediaKeysTarget = .lastMusicApp
    /// Последнее приложение, где реально играла музыка (`MusicApps.qualifies`), — цель медиаклавиш между запусками.
    var lastMusicBundle: String?
    var lastMusicName: String?
    /// Свои пресеты эквалайзера «Музыки» (16.11): копия здесь — чтобы пережили перезапуск/сброс «Музыки».
    var customEQ: [CustomEQPreset] = []

    /// Клавиши нужны модулю (мост ядра → HUD держит tap активным).
    var wantsMediaKeys: Bool { mediaKeys && mediaKeysTarget == .lastMusicApp }

    /// Включённые источники текстов.
    var lyricsSources: Set<LyricsSourceKind> {
        Set(LyricsSourceKind.allCases.filter { !lyricsSourcesOff.contains($0.rawValue) })
    }
    /// Все источники в порядке опроса (вкл. и выкл.).
    var lyricsOrder: [LyricsSourceKind] { LyricsSourceKind.ordered(lyricsSourceOrder) }

    init() {}
    init(from decoder: Decoder) throws {
        // Новые поля в будущем не должны сбрасывать старые настройки.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(MediaSourcePreference.self, forKey: .source)) ?? .auto
        compactLyrics = (try? c.decode(Bool.self, forKey: .compactLyrics)) ?? false
        openOnPlay = (try? c.decode(Bool.self, forKey: .openOnPlay)) ?? false
        lyricsEnabled = (try? c.decode(Bool.self, forKey: .lyricsEnabled)) ?? true
        lyricsAnyApp = (try? c.decode(Bool.self, forKey: .lyricsAnyApp)) ?? false
        lyricsSourcesOff = (try? c.decode([String].self, forKey: .lyricsSourcesOff)) ?? []
        lyricsSourceOrder = (try? c.decode([String].self, forKey: .lyricsSourceOrder)) ?? []
        liveVisualizer = (try? c.decode(Bool.self, forKey: .liveVisualizer)) ?? true
        eqStyle = (try? c.decode(VisualizerStyle.self, forKey: .eqStyle)) ?? .reflection
        flashOnTrackChange = (try? c.decode(Bool.self, forKey: .flashOnTrackChange)) ?? false
        mediaKeys = (try? c.decode(Bool.self, forKey: .mediaKeys)) ?? true
        mediaKeysTarget = (try? c.decode(MediaKeysTarget.self, forKey: .mediaKeysTarget)) ?? .lastMusicApp
        lastMusicBundle = try? c.decode(String.self, forKey: .lastMusicBundle)
        lastMusicName = try? c.decode(String.self, forKey: .lastMusicName)
        customEQ = (try? c.decode([CustomEQPreset].self, forKey: .customEQ)) ?? []
    }
}

/// Состояние плеера: источник (MediaRemote / AppleScript), обложка и её цвета, текст песни, устройство вывода.
/// Всё на главном потоке; тяжёлое (цвета, сеть, AppleScript) — в фоне.
@MainActor
final class MediaModel: ObservableObject {
    @Published private(set) var now: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// Мок обложки для снимков (градиент из IslandCore), когда картинки нет.
    @Published var placeholderArtwork: ArtworkView.Placeholder?
    @Published private(set) var palette: [ArtworkPalette.RGB] = []
    /// Текст для показа: найденный (`rawLyrics`), сдвинутый на задержку вывода звука (`lyricsDelay`).
    @Published private(set) var lyrics: Lyrics?
    /// Поиск текста закончен, ничего не нашлось (26.11: вместо «Играет в …» сказать прямо, что текста нет).
    @Published private(set) var lyricsNotFound = false
    /// Текст как в LRCLIB (без поправки на задержку).
    private(set) var rawLyrics: Lyrics?
    /// Сдвиг строк, с (`LyricsSync.offset`: задержка вывода звука минус упреждение 0,1 с).
    private(set) var lyricsDelay: Double = 0
    /// Задержка вывода текущего устройства, с (nil — неизвестна; читается при смене устройства).
    private(set) var outputLatency: Double?
    /// Текущая строка текста — для компакта (меняется одним таймером на смену строки, без опроса).
    @Published private(set) var lyricIndex: Int?
    @Published private(set) var availability: MediaAvailability = .ok
    @Published private(set) var device: OutputDevice?
    @Published private(set) var liked: Bool?
    @Published private(set) var speed: Double = 1
    /// «Далее: …» — следующий трек, если источник его надёжно знает (Музыка через AppleScript, без перемешивания).
    /// nil — не знаем, строку не показываем.
    @Published private(set) var nextTitle: String?
    /// Позиция, пока пользователь тащит по волне (nil — не тащит).
    @Published var scrubPosition: Double?
    @Published var prefs = MediaPrefs() {
        didSet {
            guard prefs != oldValue else { return }
            if !isSnapshot { context?.saveSettings(prefs) }
            if prefs.source != oldValue.source, started { configureSources() }
            if prefs.lyricsEnabled != oldValue.lyricsEnabled || prefs.lyricsAnyApp != oldValue.lyricsAnyApp
                || prefs.lyricsSourcesOff != oldValue.lyricsSourcesOff
                || prefs.lyricsOrder != oldValue.lyricsOrder { reloadLyrics() }
            if prefs.liveVisualizer != oldValue.liveVisualizer { updateLiveAudio() }
            if prefs.wantsMediaKeys != oldValue.wantsMediaKeys { router.setWants(prefs.wantsMediaKeys, owner: "media") }
            if prefs.lastMusicBundle != oldValue.lastMusicBundle {
                if lastMusicTrack?.bundleId != prefs.lastMusicBundle { lastMusicTrack = nil; lastMusicCover = nil }
                refreshKeysAutomation()
            }
            // Сменилось только «последнее музыкальное» / настройки клавиш — плеер пересчитывать незачем.
            if Self.onlyKeysChanged(prefs, oldValue) { return }
            scheduleLyricTimer()
            updateActivity(force: true)
        }
    }

    weak var context: ModuleContext?
    var isSnapshot = false
    /// Тексты песен (самотест подставляет свой каталог кеша).
    var lyricsService = LyricsService.shared
    /// Вьюха вкладки (для «курсор над островом» перед автосворачиванием).
    weak var tabView: NSView?

    /// Уровни настоящего звука для полосок (компакт — 5, вкладка — 24). Спрос дают сами полоски на экране.
    let audioFeed = AudioLevelsFeed()
    /// Захват звука (process tap). Создаётся в `start` (самотест подставляет заглушку через `audioBackend`).
    private(set) var liveAudio: LiveAudioController?
    var audioBackend: AudioCaptureBackend?
    /// Статус права «Запись системного звука» (для настроек; обновляется при включении и показе настроек).
    @Published private(set) var audioPermission: PermissionStatus = .unknown
    /// Превью ролика YouTube (видео без обложки от MediaRemote) и id ролика, для которого оно.
    @Published private(set) var videoThumbnail: NSImage?
    private var videoThumbnailId: String?
    /// Браузер не дал вкладки: нет права «Автоматизация» (кнопка «Показать превью…» во вкладке).
    @Published private(set) var browserAccessNeeded: String?
    /// Ролики, за превью которых уже ходили (одно скачивание на ролик за запуск).
    private var thumbnailRequested: Set<String> = []
    private var thumbnailWork: DispatchWorkItem?
    private var thumbnailLookupKey: String?
    /// Самотест: вместо сети и AppleScript.
    var thumbnailFetcher: ((URL) async -> Data?)?
    var browserTabsReader: ((String) async -> String?)?
    private(set) var thumbnailDownloads = 0

    // --- keys --- медиаклавиши «последнему музыкальному приложению» (MediaKeys.swift).
    let keys = MediaKeyController()
    /// Мост ядра (самотест подставляет свой).
    var router = MediaKeyRouter.shared
    /// Последний трек последнего музыкального приложения и его обложка (только память) — для вспышки клавиш, когда
    /// текущий Now Playing — другое приложение (видео на паузе).
    private(set) var lastMusicTrack: NowPlaying?
    private(set) var lastMusicCover: NSImage?
    /// Право «Автоматизация» для последнего музыкального (Музыка/Spotify); nil — не проверяли.
    @Published private(set) var keysAutomation: PermissionStatus?
    /// Самотест: вместо NSRunningApplication.
    var isAppRunningForTest: ((String) -> Bool)?
    /// Самотест: команды клавиш не уходят ни в AppleScript, ни помощнику — только сюда.
    var keyCommandSinkForTest: ((MediaKeyCommand, MediaKeyRoute) -> Void)?

    private let mr = MediaRemoteSource()
    private let script = ScriptSource()
    private let devices = OutputDeviceWatcher()
    private var mrNow: NowPlaying?
    private var scriptNow: NowPlaying?
    /// Сверка позиции Музыки по `player position` (см. `mergeScript`): тикер, пока Музыка играет через MediaRemote.
    private var positionSync: AnyCancellable?
    private var lastMRAnchor: Date?
    private(set) var positionAnchor: PositionAnchor?
    private(set) var positionSamples = 0, positionSamplesRejected = 0
    static let positionSyncInterval: TimeInterval = 10
    private var useMediaRemote = false
    private var permissionNeeded: [String: Bool] = [:]
    /// Обложки: ImageIO-миниатюра под размер показа (148 pt × 2), свой кэш с лимитом (≈ 8 обложек), без
    /// полноразмерного битмапа и TIFF-копий (PITFALLS M1/M4). Цвета — с той же миниатюры, в фоне.
    static let coverPointSize: CGFloat = 148
    /// Обложки — только в памяти: текущая и предыдущая (без диска; сон — чистится).
    let downsampler = ImageDownsampler(costLimit: 3 << 20, countLimit: 2)
    /// Цвета обложек по id (несколько байт на обложку; картинки — в кэше `downsampler`).
    private var paletteCache: [String: [ArtworkPalette.RGB]] = [:]
    private var paletteOrder: [String] = []
    /// Текущая показанная обложка (id) и та, что сейчас декодируется.
    private var shownArtworkId: String?
    private var decodingArtwork: Set<String> = []
    /// Данные обложек, которые пришли раньше строки трека (помощник шлёт обложку до "now"): одна последняя.
    private var lastArtworkData: (id: String, data: Data)?
    /// Сколько обложек декодировано (для самотеста: повтор того же id не декодируется заново).
    private(set) var artworkDecodes = 0
    /// Последние декодированные обложки по id (не больше `recentCoversLimit`, ≈ 350 КБ каждая) — независимо от того,
    /// показаны ли они. Помощник шлёт данные обложки один раз на id, а у треков одного альбома id один и тот же
    /// (те же байты): без этого списка обложка, снятая между строками помощника, больше не возвращалась (16.11).
    private var recentCovers: [(id: String, image: NSImage, colors: [ArtworkPalette.RGB])] = []
    static let recentCoversLimit = 4
    /// Чей трек на показанной обложке (`trackTag`): тот же трек при смене источника/id — обложку не снимаем.
    private var shownTrack: String?
    private var shownAlbum: String?
    /// Дозапросы обложки (`requestArtwork`): трек, когда последний, сколько.
    private var artworkAsk: (key: String, at: Date, count: Int)?
    private(set) var artworkRequests = 0
    private var lyricsKey: String?
    /// Длительность, с которой спросили текст: пришла другая (больше ±2 с) — спросить заново.
    private var lyricsQueryDuration: Double = 0
    private var lyricsTask: Task<Void, Never>?
    private var lyricTimer: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var activitySignature = ""
    private var started = false
    private var startedAt = Date()
    private var wasPlaying = false
    /// Когда последний раз играло (для «показать вкладку при старте»: короткая пауза — не старт).
    private var lastPlayingAt: Date?
    private var lastPlayingKey: String?
    private var systemEventToken: Int?
    private var mrRetryWork: DispatchWorkItem?
    /// Снять обложку прошлого трека, если новая не пришла за `artworkHoldSeconds`.
    private var artworkClearWork: DispatchWorkItem?
    /// Скорость, отправленная плееру и ещё не подтверждённая его `PlaybackRate`.
    private var pendingSpeed: Double?
    private var speedWork: DispatchWorkItem?
    /// Приложения, которые не меняют скорость по команде MediaRemote (за этот запуск).
    private var speedUnsupported: Set<String> = []

    // MARK: Жизненный цикл

    func start(context: ModuleContext) {
        self.context = context
        prefs = context.loadSettings(MediaPrefs.self) ?? MediaPrefs()
        started = true
        startedAt = Date()
        mr.onState = { [weak self] st in self?.handleMR(st) }
        mr.onArtwork = { [weak self] id, data in self?.ingestArtwork(id: id, data: data) }
        mr.onFailure = { [weak self] _ in self?.configureSources(); self?.scheduleMRRetry() }
        script.onUpdate = { [weak self] n in self?.scriptNow = n; self?.resolve() }
        script.onArtwork = { [weak self] id, data in self?.ingestArtwork(id: id, data: data) }
        script.onPermission = { [weak self] bundle, needs in
            guard let self else { return }
            if self.permissionNeeded[bundle] != needs { self.permissionNeeded[bundle] = needs; self.resolve() }
        }
        script.onLiked = { [weak self] l in self?.liked = l }
        script.onNext = { [weak self] bundle, key, title in self?.handleNext(bundle: bundle, trackKey: key, title: title) }
        devices.onChange = { [weak self] d in
            guard let self else { return }
            let changed = self.device != nil && self.device != d
            self.device = d
            if changed { self.liveAudio?.outputDeviceChanged() }
            // Задержку вывода читаем только при смене устройства (CoreAudio может подвиснуть, пока создаются агрегаты
            // захвата звука) — не на каждом обновлении трека.
            self.outputLatency = OutputDeviceWatcher.outputLatency()
            self.updateLyricsDelay()
        }
        devices.start()
        let live = LiveAudioController(feed: audioFeed, backend: audioBackend ?? ProcessTapBackend())
        liveAudio = live
        updateLiveAudio()
        // Сон/пробуждение — через ядро (ARCHITECTURE «Правила модулей»): подписки снимаются им же при остановке.
        systemEventToken = context.onSystemEvent { [weak self] e in self?.handleSystemEvent(e) }
        mr.resetFailure()
        configureSources()
        startKeys()
        // Тексты: просроченное из кеша вон, индексы AMLL заранее (только если источник включён) — в фоне, с низким
        // приоритетом, раз за запуск; сеть — не чаще раза в сутки (свежесть файла индекса сверяет LyricsCore).
        if prefs.lyricsEnabled {
            let service = lyricsService, amll = prefs.lyricsSources.contains(.amll)
            Task.detached(priority: .background) { await service.startup(amll: amll) }
        }
    }

    func stop() {
        started = false
        positionSync = nil
        keys.reset()
        router.unregister(owner: "media")
        // Захват звука — освободить сразу (tap, агрегат), полоски — к псевдоанимации.
        liveAudio?.enabled = false
        liveAudio?.stopNow()
        mr.stop()
        script.stop()
        devices.stop()
        lyricsTask?.cancel(); lyricsTask = nil
        lyricTimer?.cancel(); lyricTimer = nil
        collapseWork?.cancel(); collapseWork = nil
        thumbnailWork?.cancel(); thumbnailWork = nil
        videoThumbnail = nil; videoThumbnailId = nil; browserAccessNeeded = nil; thumbnailLookupKey = nil
        mrRetryWork?.cancel(); mrRetryWork = nil
        speedWork?.cancel(); speedWork = nil; pendingSpeed = nil
        // Подписка на системные события — снимаем свою явно (ядро при остановке модулей снимет и само).
        if let t = systemEventToken, let ctx = context {
            SystemStateCenter.shared.removeHandler(owner: ctx.moduleId, token: t)
        }
        systemEventToken = nil
        artworkClearWork?.cancel(); artworkClearWork = nil
        artworkRetryWork?.cancel(); artworkRetryWork = nil
        asleep = false
        mrNow = nil; scriptNow = nil
        // Выключили модуль — во вкладке не должен остаться последний трек.
        let hadNow = now != nil
        now = nil; artwork = nil; palette = []; lyrics = nil; rawLyrics = nil; lyricIndex = nil; lyricsKey = nil; liked = nil
        nextTitle = nil; shownArtworkId = nil; lastArtworkData = nil; decodingArtwork = []
        recentCovers = []; shownTrack = nil; shownAlbum = nil; artworkAsk = nil
        downsampler.removeAll()
        speed = 1; scrubPosition = nil; availability = .ok; permissionNeeded = [:]
        wasPlaying = false; lastPlayingAt = nil; lastPlayingKey = nil
        context?.removeActivity(id: Self.activityId)
        setColors(nil)
        activitySignature = ""
        if hadNow { context?.invalidateLayout() }
    }

    private func scheduleMRRetry() {
        mrRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.retryMediaRemote() } }
        mrRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
    }

    private func retryMediaRemote() {
        guard started, mr.failed else { return }
        mr.resetFailure()
        configureSources()
    }

    // MARK: Сон и пробуждение

    /// Мак спит (между `.willSleep` и пробуждением): помощник остановлен, таймер строки текста снят.
    private(set) var asleep = false
    /// Сколько раз переподписывались на поток Now Playing после пробуждения (самотест).
    private(set) var resubscribes = 0

    func handleSystemEvent(_ e: IslandSystemEvent) {
        guard started else { return }
        switch e {
        case .willSleep:
            // Во сне MediaRemote шлёт пачки уведомлений и помощник просыпался бы зря: гасим, на пробуждении — заново.
            asleep = true
            liveAudio?.asleep = true
            mr.stop()
            lyricTimer?.cancel(); lyricTimer = nil
            downsampler.removeAll()
            // Во сне — только показанная обложка (после пробуждения помощник новым процессом пришлёт данные заново).
            recentCovers.removeAll { $0.id != shownArtworkId }
        case .didWake, .sessionDidBecomeActive:
            asleep = false
            screensOff = false
            resubscribe(restartHelper: true)
            scheduleArtworkCheck("пробуждение")
        case .screensDidWake, .screenUnlocked:
            screensOff = false
            if asleep {
                // `.didWake` потерялся (экран проснулся/разблокирован — значит, Мак не спит): считать пробуждением,
                // иначе `configureSources()` молчал бы до следующего цикла сна.
                asleep = false
                resubscribe(restartHelper: true)
            } else {
                // Музыка могла играть, пока экран был выключен/заблокирован: перепроверить состояние, не перезапуская.
                resubscribe(restartHelper: false)
            }
        case .motionChanged:
            // Остров стал невидим (экран погас/заблокирован) или снова виден — строка текста: таймер снять/поставить.
            scheduleLyricTimer()
        case .screensDidSleep, .screenLocked, .sessionDidResignActive:
            // Экран погас/заблокирован/сессия ушла — захват звука освободить сразу (не ждать, пока уйдут полоски).
            screensOff = true
        case .screensChanged:
            break
        }
        updateLiveAudio()
    }

    /// Экран погас / заблокирован / сессия неактивна (захват звука не нужен).
    private var screensOff = false
    private var askedAudioOnce = false
    private var lastLoggedAudioPerm: PermissionStatus?

    // MARK: Захват звука

    /// Включён ли захват и что слушать — по настройке, праву, сну и текущему треку.
    func updateLiveAudio() {
        guard let live = liveAudio else { return }
        if prefs.liveVisualizer && started { audioPermission = Permissions.status(.audioCapture) }
        // Запрещено явно — не создаём tap зря (он отдавал бы нули). Не спрашивали/неизвестно — пробуем: без права
        // нули → `.silent` → псевдополоски.
        // Включено по умолчанию: при первой игре, если право ещё не спрашивали, — один раз спросить (иначе tap молча
        // отдаёт нули). Только по факту воспроизведения, не на старте приложения.
        if started, prefs.liveVisualizer, !isSnapshot, !askedAudioOnce, audioPermission == .notDetermined,
           now?.isPlaying == true {
            askedAudioOnce = true
            setLiveVisualizer(true)
        }
        let wantEnabled = started && prefs.liveVisualizer && audioPermission != .denied
        if wantEnabled != live.enabled || lastLoggedAudioPerm != audioPermission {
            lastLoggedAudioPerm = audioPermission
            NSLog("SimpleIsland media: захват звука enabled=%@ право=%@ настройка=%@ играет=%@", "\(wantEnabled)",
                  audioPermission.rawValue, "\(prefs.liveVisualizer)", "\(now?.isPlaying ?? false)")
        }
        live.enabled = wantEnabled
        live.asleep = asleep || screensOff
        live.playing = now?.isPlaying ?? false
        live.target = now.map { AudioTapTarget(pid: $0.pid, bundleId: $0.bundleId) }
    }

    /// Переключатель в настройках: включение — запрос права (окно macOS / настройки + карточка), потом захват.
    func setLiveVisualizer(_ on: Bool) {
        guard on else { prefs.liveVisualizer = false; return }
        prefs.liveVisualizer = true
        guard !isSnapshot else { return }
        Task { @MainActor [weak self] in
            let s = await Permissions.requestFromUser(.audioCapture, moduleId: "media")
            guard let self else { return }
            self.audioPermission = s
            self.liveAudio?.resetFailure()
            self.updateLiveAudio()
        }
    }

    func refreshAudioPermission() {
        audioPermission = Permissions.status(.audioCapture)
        updateLiveAudio()
    }

    /// Что сейчас с захватом — строка для настроек.
    var liveAudioStatusText: String {
        guard prefs.liveVisualizer else { return "Выключено — полоски двигаются сами, без звука." }
        if audioPermission == .denied { return "Нет доступа к записи системного звука — полоски двигаются сами." }
        switch liveAudio?.state ?? .idle {
        case .running: return "Работает: полоски — по звуку, который сейчас играет."
        case .starting: return "Подключаюсь к звуку…"
        case .failed(let why): return "Захват звука не запустился (\(why)) — полоски двигаются сами."
        case .silent: return "Звук не приходит (нет доступа?) — полоски двигаются сами до следующего трека."
        case .idle: return "Включится, когда играет музыка и остров виден."
        }
    }

    /// Переподписаться на «что играет» и перепроверить источник: сбой MediaRemote не навсегда (после сна,
    /// обновления системы, перезапуска mediaremoted) — снять отметку и попробовать снова; помощник — новый процесс
    /// (регистрация уведомлений MediaRemote могла потеряться) или просьба прислать состояние; AppleScript — дочитать.
    private func resubscribe(restartHelper: Bool) {
        resubscribes += 1
        if mr.failed { mr.resetFailure() }
        if restartHelper && mr.isRunning { mr.restart() }
        configureSources()
        if !restartHelper { mr.send("refresh") }
        for b in script.apps where ScriptSource.isRunning(b) { script.refresh(b) }
        scheduleLyricTimer()
    }

    /// Какие источники включить по настройке и по тому, жив ли MediaRemote.
    private func configureSources() {
        guard started, !asleep else { return }
        let wantMR = !mr.failed && MediaRemoteSource.isAvailable
        if wantMR && !mr.isRunning { mr.start() }
        if !wantMR && mr.isRunning { mr.stop() }
        // `mr.start()` мог сразу не удаться (perl не запустился → `onFailure` уже перенастроил источники).
        useMediaRemote = wantMR && !mr.failed
        let apps: [String]
        switch prefs.source {
        case .auto: apps = [MediaApps.music, MediaApps.spotify]
        case .music: apps = [MediaApps.music]
        case .spotify: apps = [MediaApps.spotify]
        case .any: apps = []
        }
        if apps.isEmpty { script.stop(); scriptNow = nil } else if script.apps != apps || scriptNow == nil { script.start(apps: apps) }
        resolve()
    }

    // MARK: Источники → состояние

    private func handleMR(_ st: MediaRemoteSource.State) {
        let name = appDisplayName(bundleId: st.parentBundle ?? st.bundle, pid: st.pid)
        mrNow = MediaRemoteSource.nowPlaying(from: st, appName: name)
        if let p = pendingSpeed, let r = (st.info["PlaybackRate"] as? NSNumber)?.doubleValue, abs(r - p) < 0.01 {
            // Плеер подтвердил новую скорость своей строкой.
            pendingSpeed = nil; speedWork?.cancel(); speedWork = nil
        }
        resolve()
    }

    private func resolve() {
        let filter = prefs.source.bundleFilter
        var fromMR = useMediaRemote ? mrNow : nil
        if let f = filter, fromMR?.bundleId != f { fromMR = nil }
        // MediaRemote молчит, а Музыка/Spotify по своим уведомлениям играют — значит, MediaRemote нам не отвечает.
        var chosen = fromMR
        if chosen == nil || (chosen?.isPlaying == false && scriptNow?.isPlaying == true) { chosen = scriptNow ?? chosen }
        if let c = chosen, var keep = now, keep.trackKey == c.trackKey, c.artworkId == nil, keep.artworkId != nil,
           c.viaScript == keep.viaScript {
            // Обложка приходит позже текста: не мигать плейсхолдером между строками помощника.
            keep = c; keep.artworkId = now?.artworkId; chosen = keep
        }
        if let c = chosen, c.isMusicApp, !c.viaScript, c.badge == nil, let s = scriptNow, s.trackKey == c.trackKey {
            chosen?.badge = s.badge
        }
        // Обложка: MediaRemote её не прислал (Музыка отдаёт ArtworkData не всегда и не сразу) — взять из AppleScript
        // того же трека (`artwork 1 of current track` / `artwork url` Spotify). Заглушка — только если нет нигде.
        // Так же — если MediaRemote назвал обложку, а её данных у нас нет (пропали; помощник шлёт их раз на id), а у
        // AppleScript того же трека картинка есть: показать её, пока дозапрашиваем свою.
        if let c = chosen, !c.viaScript, let s = scriptNow, s.bundleId == c.bundleId, Self.sameTrack(s, c),
           let id = s.artworkId, id != c.artworkId,
           c.artworkId == nil || (!artworkAvailable(c.artworkId!) && artworkAvailable(id)) {
            if c.artworkId != nil, now?.artworkId != id {
                ArtworkLog.note("резолв: \(c.artworkId!) (mediaremote) без данных → \(id) (applescript) того же трека")
            }
            chosen?.artworkId = id
        }
        // Длительность: MediaRemote её не прислал (бывает у Музыки — «Прямой эфир» на обычной песне, 16.11) — взять
        // из AppleScript того же трека; AppleScript сказал «missing value» — это поток.
        if let c = chosen, !c.viaScript { chosen = Self.anchored(Self.mergeScript(c, script: scriptNow), positionAnchor) }
        updatePositionSync(mr: useMediaRemote ? mrNow : nil, shown: chosen)
        noteMusic()
        apply(chosen)
        availability = computeAvailability()
    }

    private func computeAvailability() -> MediaAvailability {
        let shown = now
        let candidates: [String]
        switch prefs.source {
        case .auto: candidates = [MediaApps.music, MediaApps.spotify]
        case .music: candidates = [MediaApps.music]
        case .spotify: candidates = [MediaApps.spotify]
        case .any: candidates = []
        }
        // Показываем данные AppleScript без позиции/обложки — подсказать про разрешение.
        if let s = shown, s.viaScript, let b = s.bundleId, permissionNeeded[b] == true {
            return .needsAutomation(bundleId: b, appName: s.appName ?? b)
        }
        if shown == nil, !useMediaRemote {
            if let b = candidates.first(where: { permissionNeeded[$0] == true && ScriptSource.isRunning($0) }) {
                return .needsAutomation(bundleId: b, appName: appDisplayName(bundleId: b, pid: nil) ?? b)
            }
            if candidates.isEmpty { return .unavailable("MediaRemote недоступен — выберите источник «Авто»") }
        }
        return .ok
    }

    private func apply(_ n: NowPlaying?) {
        let old = now
        guard n != old else { return }
        now = n
        // Пустой экран ниже плеера — ядро пересчитает высоту острова.
        if (old == nil) != (n == nil) { context?.invalidateLayout() }
        let keyChanged = n?.trackKey != old?.trackKey
        if n?.artworkId != old?.artworkId || keyChanged { applyArtwork(n?.artworkId) }
        if keyChanged || n?.youTubeId != old?.youTubeId || (n?.isVideo ?? false) != (old?.isVideo ?? false) {
            scheduleVideoThumbnail()
        }
        if keyChanged { liveAudio?.resetFailure(); refreshTrackKeyFlash() }
        updateLiveAudio()
        if keyChanged {
            liked = nil
            if nextTitle != nil { nextTitle = nil }
            script.forgetNext()   // «Далее» — спросить заново для нового трека
            reloadLyrics()
            if let n, n.isMusicApp || n.isSpotify, !n.viaScript, let b = n.bundleId, script.apps.contains(b) { script.refresh(b) }
            scheduleArtworkRetry()
        }
        if !keyChanged, let n, lyricsKey != nil, n.duration >= 1,
           abs(n.duration - lyricsQueryDuration) > LyricsMatch.durationTolerance {
            // Длительность пришла позже названия (или от прошлого трека): спросить текст с настоящей.
            reloadLyrics()
        } else if keyChanged || n?.bundleId != old?.bundleId {
            updateLyricsDelay()
        }
        if let n, n.rate > 0, n.isPlaying, !n.viaScript, pendingSpeed == nil { speed = n.rate }
        scheduleLyricTimer()
        updateActivity(force: keyChanged)
        maybeOpenTab(playing: n?.isPlaying ?? false)
        maybeFlashTrack(old: old, new: n)
    }

    /// Вспышка «новый трек» — только по настройке (`flashOnTrackChange`), см. `MediaTrackFlash`.
    private func maybeFlashTrack(old: NowPlaying?, new: NowPlaying?) {
        guard !isSnapshot, let ctx = context, let n = new,
              MediaTrackFlash.shouldFlash(enabled: prefs.flashOnTrackChange, old: old, new: n,
                                          uptime: Date().timeIntervalSince(startedAt), tabVisible: ctx.isTabVisible) else { return }
        ctx.flashHUD(MediaTrackFlash.event(model: self, track: n), duration: 2.4)
    }

    // MARK: Обложка и цвета

    /// Картинка в обложке: обложка MediaRemote → превью YouTube (только для видео) → nil (значок видео / нота).
    var coverImage: NSImage? {
        if let a = artwork { return a }
        if now?.isVideo == true { return videoThumbnail }
        return nil
    }

    /// Что показывать для видео (самотест и вьюхи).
    var videoCover: VideoCover {
        VideoCover.choose(hasArtwork: artwork != nil || placeholderArtwork != nil, hasThumbnail: videoThumbnail != nil)
    }

    // MARK: Превью видео (YouTube)

    /// Видео в браузере без обложки: через 1,5 с (обложка от MediaRemote часто приходит позже текста) найти id ролика
    /// — из метаданных или из вкладки по заголовку — и скачать превью. Без права «Автоматизация» вкладки не читаем.
    private func scheduleVideoThumbnail() {
        thumbnailWork?.cancel(); thumbnailWork = nil
        guard let n = now, n.isVideo else {
            videoThumbnail = nil; videoThumbnailId = nil; browserAccessNeeded = nil; thumbnailLookupKey = nil
            return
        }
        if thumbnailLookupKey != n.trackKey {
            // Другой ролик — превью и просьба о доступе прошлого не годятся.
            videoThumbnail = nil; videoThumbnailId = nil; browserAccessNeeded = nil
        }
        guard !isSnapshot else { return }
        let key = n.trackKey
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.lookupVideoThumbnail(trackKey: key) }
            }
        }
        thumbnailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (thumbnailFetcher == nil ? 1.5 : 0), execute: work)
    }

    /// Найти и скачать превью для текущего ролика (повторный вызов — после выдачи права).
    func lookupVideoThumbnail(trackKey key: String) async {
        guard let n = now, n.trackKey == key, n.isVideo, artwork == nil else { return }
        thumbnailLookupKey = key
        var id = n.youTubeId
        if id == nil, let b = n.bundleId, MediaKind.isBrowser(b), let script = YouTube.tabsScript(bundleId: b) {
            let out: String?
            if let reader = browserTabsReader {
                out = await reader(b)
            } else {
                out = await Self.readBrowserTabs(bundleId: b, script: script)
            }
            guard now?.trackKey == key else { return }
            if let out {
                browserAccessNeeded = nil
                id = YouTube.pickTab(YouTube.parseTabs(out), nowTitle: n.title)
            } else {
                browserAccessNeeded = b
            }
        }
        guard let id else { return }
        if videoThumbnailId == id, videoThumbnail != nil { return }
        let cacheKey = "yt-" + id
        if let img = downsampler.cached(key: cacheKey, maxPointSize: Self.coverPointSize) {
            videoThumbnail = img; videoThumbnailId = id; updateActivity(force: true); return
        }
        // Одно скачивание на ролик за запуск (не удалось — значок видео, без повторов).
        guard thumbnailRequested.insert(id).inserted else { return }
        thumbnailDownloads += 1
        let url = YouTube.thumbnailURL(id)
        let data: Data?
        if let f = thumbnailFetcher { data = await f(url) } else { data = await Self.download(url) }
        guard let data, let img = await downsampler.image(data: data, maxPointSize: Self.coverPointSize, key: cacheKey) else { return }
        guard now?.trackKey == key else { return }
        videoThumbnail = img
        videoThumbnailId = id
        updateActivity(force: true)
    }

    /// Вкладки браузера (на потоке AppleScript). nil — нет права «Автоматизация» / браузер не запущен / ошибка.
    nonisolated static func readBrowserTabs(bundleId b: String, script: String) async -> String? {
        await withCheckedContinuation { cont in
            ScriptSource.perform {
                // Не запущен — не трогать (скрипт запустил бы браузер). Права нет — не спрашивать (только по кнопке).
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty,
                      ScriptSource.automationStatus(b, ask: false) == noErr else { cont.resume(returning: nil); return }
                let r = ScriptSource.run(script)
                cont.resume(returning: r.errorNumber == nil ? (r.descriptor?.stringValue ?? "") : nil)
            }
        }
    }

    /// Картинка с i.ytimg.com: без cookies и дискового кэша, до 2 МБ, таймаут 10 с.
    nonisolated static func download(_ url: URL) async -> Data? {
        guard url.host == "i.ytimg.com" else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count < 2 << 20 else { return nil }
        return data
    }

    /// Кнопка «Показать превью…»: право «Автоматизация» браузера (окно macOS / настройки + карточка), потом поиск.
    func requestBrowserAccess() {
        guard let b = browserAccessNeeded ?? now?.bundleId else { return }
        Task { @MainActor [weak self] in
            let s = await Permissions.requestFromUser(.automation(bundleId: b), moduleId: "media")
            guard let self, s == .granted, let key = self.now?.trackKey else { return }
            self.browserAccessNeeded = nil
            await self.lookupVideoThumbnail(trackKey: key)
        }
    }

    func ingestArtwork(id: String, data: Data) {
        let src = ArtworkLog.source(id)
        // Та же обложка уже показана или в работе — не декодировать заново.
        if id == shownArtworkId, artwork != nil {
            ArtworkLog.note("данные \(id) (\(src), \(data.count) Б): уже показана")
            return
        }
        if let c = cachedCover(id) {
            ArtworkLog.note("данные \(id) (\(src), \(data.count) Б): уже декодирована")
            if now?.artworkId == id { show(artwork: c.image, id: id, colors: c.colors, how: "из кэша") }
            return
        }
        ArtworkLog.note("данные \(id) (\(src), \(data.count) Б) → декодирую; у трека сейчас \(now?.artworkId ?? "нет id")")
        lastArtworkData = (id, data)
        // Помощник шлёт обложку раньше строки трека — начинаем сразу; покажется, когда трек её назовёт.
        decodeArtwork(id: id, data: data)
    }

    /// ImageIO-миниатюра (в фоне, кэш `downsampler`) → цвета с неё же (в фоне) → в `recentCovers` → показать, если
    /// это всё ещё обложка текущего трека.
    private func decodeArtwork(id: String, data: Data) {
        guard !decodingArtwork.contains(id) else { return }
        decodingArtwork.insert(id)
        let sampler = downsampler
        let knownPalette = paletteCache[id]
        Task { [weak self] in
            let img = await sampler.image(data: data, maxPointSize: Self.coverPointSize, key: "media-" + id)
            var colors = knownPalette ?? []
            // cgImage(forProposedRect:) отдаёт autorelease-объекты: без своего пула на главном потоке (вне цикла
            // событий NSApplication, напр. в самотесте) они копились бы до выхода.
            let cgImage = autoreleasepool { img?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            if knownPalette == nil, let cg = cgImage {
                let box = UncheckedBox(cg)
                // Пул — свой: потоки Swift concurrency не осушают autorelease-пул после каждой задачи.
                colors = await Task.detached(priority: .utility) {
                    autoreleasepool { ArtworkPalette.dominantColors(of: box.value) }
                }.value
            }
            guard let self else { return }
            self.decodingArtwork.remove(id)
            guard let img else {
                ArtworkLog.note("декодирование \(id) не удалось — дозапрос")
                if self.lastArtworkData?.id == id { self.lastArtworkData = nil }
                if self.now?.artworkId == id { self.requestArtwork("не декодировалась") }
                return
            }
            self.artworkDecodes += 1
            self.rememberPalette(colors, for: id)
            self.rememberCover(id: id, image: img, colors: colors)
            if self.lastArtworkData?.id == id { self.lastArtworkData = nil }
            if self.now?.artworkId == id {
                self.show(artwork: img, id: id, colors: colors, how: "декодирована")
            } else {
                ArtworkLog.note("декодирована \(id), но у трека \(self.now?.artworkId ?? "нет id") — в кэш, не показана")
            }
        }
    }

    private func rememberPalette(_ colors: [ArtworkPalette.RGB], for id: String) {
        if paletteCache[id] == nil { paletteOrder.append(id) }
        paletteCache[id] = colors
        while paletteOrder.count > 8 { paletteCache[paletteOrder.removeFirst()] = nil }
    }

    private func rememberCover(id: String, image: NSImage, colors: [ArtworkPalette.RGB]) {
        recentCovers.removeAll { $0.id == id }
        recentCovers.append((id, image, colors))
        if recentCovers.count > Self.recentCoversLimit { recentCovers.removeFirst(recentCovers.count - Self.recentCoversLimit) }
    }

    private func cachedCover(_ id: String) -> (image: NSImage, colors: [ArtworkPalette.RGB])? {
        recentCovers.last { $0.id == id }.map { ($0.image, $0.colors) }
    }

    /// Обложку с этим id можно показать без нового запроса: показана, в кэше, декодируется или данные на руках.
    func artworkAvailable(_ id: String) -> Bool {
        (id == shownArtworkId && artwork != nil) || cachedCover(id) != nil || decodingArtwork.contains(id)
            || lastArtworkData?.id == id
    }

    /// Чей трек: приложение + название + исполнитель (альбом источники пишут по-разному, см. `sameTrack`).
    static func trackTag(_ n: NowPlaying) -> String {
        "\(n.bundleId ?? "")\u{1F}\(LyricsMatch.fold(n.title))\u{1F}\(LyricsMatch.fold(n.artist))"
    }

    private func show(artwork img: NSImage, id: String, colors: [ArtworkPalette.RGB], how: String) {
        artwork = img
        if let b = now?.bundleId, b == prefs.lastMusicBundle { lastMusicCover = img }
        palette = colors
        shownArtworkId = id
        shownTrack = now.map(Self.trackTag)
        shownAlbum = now.map { LyricsMatch.fold($0.album) }
        // Данные больше не нужны: картинка уже в `recentCovers`.
        if lastArtworkData?.id == id { lastArtworkData = nil }
        artworkClearWork?.cancel(); artworkClearWork = nil
        setColors(palette.isEmpty ? nil : ArtworkPalette.glow(palette))
        updateActivity(force: true)
        ArtworkLog.note("показана \(id) (\(ArtworkLog.source(id)), \(how)) — «\(now?.title ?? "?")»")
        refreshTrackKeyFlash()
    }

    private func applyArtwork(_ id: String?) {
        artworkClearWork?.cancel(); artworkClearWork = nil
        let title = now?.title ?? "?"
        if let id, id == shownArtworkId, artwork != nil {
            // Та же картинка (у треков одного альбома — одни и те же байты): теперь она и этого трека.
            shownTrack = now.map(Self.trackTag); shownAlbum = now.map { LyricsMatch.fold($0.album) }
            ArtworkLog.note("трек «\(title)»: \(id) уже показана")
            return
        }
        if let id, let c = cachedCover(id) {
            show(artwork: c.image, id: id, colors: c.colors, how: "из кэша")
            return
        }
        if let id, let d = lastArtworkData, d.id == id { decodeArtwork(id: id, data: d.data) }
        let pending = id.map { decodingArtwork.contains($0) } ?? false
        // Тот же трек сменил источник/id (MediaRemote ↔ AppleScript, пауза/игра, строка без ArtworkData): картинка
        // этого трека уже показана — держим, пока не придёт новая; заглушки не будет.
        if artwork != nil, let n = now, shownTrack == Self.trackTag(n) {
            ArtworkLog.note("трек «\(title)»: id \(id ?? "нет") (\(pending ? "декодируется" : "данных нет")) — держу картинку того же трека")
            if let id, !pending { requestArtwork("нет данных \(id)") }
            return
        }
        if let id, !pending { requestArtwork("нет данных \(id)") }
        // Новой обложки ещё нет (придёт/декодируется): прежнюю держим недолго — без мигания плейсхолдером на обычной
        // смене трека, но и без обложки, палитры и фона «Хамелеона» прошлого трека, если новая не пришла. Тот же
        // альбом — чуть дольше: MediaRemote называет обложку через ~1 с после строки трека (16.11), а она та же.
        guard artwork != nil else {
            if id == nil, shownArtworkId != nil { clearArtwork() }
            ArtworkLog.note("трек «\(title)»: id \(id ?? "нет") — \(pending ? "декодируется" : "ждём") (нечего держать)")
            return
        }
        let sameAlbum = now.map { !$0.album.isEmpty && LyricsMatch.fold($0.album) == shownAlbum } ?? false
        let hold = sameAlbum ? Self.artworkAlbumHoldSeconds : Self.artworkHoldSeconds
        ArtworkLog.note("трек «\(title)»: id \(id ?? "нет") — прежнюю держу ≤ \(hold) с\(sameAlbum ? " (тот же альбом)" : "")")
        let key = now?.trackKey
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let n = self.now, n.trackKey == key, self.shownTrack != Self.trackTag(n) else { return }
                ArtworkLog.note("трек «\(n.title)»: новая обложка не пришла за \(hold) с — прежняя снята")
                self.clearArtwork()
                self.requestArtwork("не пришла за \(hold) с")
            }
        }
        artworkClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// Сколько держать обложку прошлого трека, пока новая не пришла.
    static let artworkHoldSeconds: TimeInterval = 1
    /// То же, если новый трек — из того же альбома (обложка почти наверняка та же).
    static let artworkAlbumHoldSeconds: TimeInterval = 2

    /// Дозапрос обложки текущего трека: помощнику MediaRemote — `artwork` (переслать данные, даже если id тот же),
    /// Музыке/Spotify — заново `artwork 1 of current track` / `artwork url`. Не чаще раза в `artworkAskGap` с, не
    /// больше `artworkAskMax` на трек подряд; дальше — раз в `artworkAskSlowGap` с (вкладка, пробуждение).
    @discardableResult
    func requestArtwork(_ reason: String) -> Bool {
        guard !isSnapshot, let n = now, !n.isVideo else { return false }
        let key = "\(n.bundleId ?? "")|\(n.trackKey)"
        let t = Date()
        if let a = artworkAsk, a.key == key {
            let gap = t.timeIntervalSince(a.at)
            if gap < Self.artworkAskGap || (a.count >= Self.artworkAskMax && gap < Self.artworkAskSlowGap) {
                ArtworkLog.note("дозапрос (\(reason)) пропущен: был \(String(format: "%.1f", gap)) с назад, всего \(a.count)")
                return false
            }
            artworkAsk = (key, t, a.count + 1)
        } else {
            artworkAsk = (key, t, 1)
        }
        artworkRequests += 1
        var to: [String] = []
        if useMediaRemote, mr.isRunning { mr.send("artwork"); to.append("mediaremote") }
        if n.isMusicApp || n.isSpotify, let b = n.bundleId, script.apps.contains(b) { script.reloadArtwork(b); to.append("applescript") }
        ArtworkLog.note("дозапрос (\(reason)) «\(n.title)» → \(to.isEmpty ? "некому" : to.joined(separator: " + "))")
        return true
    }

    static let artworkAskGap: TimeInterval = 1.5
    static let artworkAskMax = 4
    static let artworkAskSlowGap: TimeInterval = 10

    /// Через `delay` проверить, есть ли обложка у текущего трека, и дозапросить (вкладка открылась, пробуждение).
    private func scheduleArtworkCheck(_ reason: String, delay: TimeInterval = 1.5) {
        guard !isSnapshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started, let n = self.now, !n.isVideo,
                      self.artwork == nil || self.shownTrack != Self.trackTag(n) else { return }
                self.requestArtwork(reason)
            }
        }
    }

    /// Тот же трек у MediaRemote и AppleScript: название и исполнитель (альбом у источников бывает записан по-разному).
    /// Дополнить строку MediaRemote данными AppleScript того же трека того же приложения: длительность (если
    /// MediaRemote её не дал) и признак потока. Чужой трек / другое приложение — без изменений.
    static func mergeScript(_ c: NowPlaying, script s: NowPlaying?) -> NowPlaying {
        guard let s, s.bundleId == c.bundleId, sameTrack(s, c) else { return c }
        var r = c
        if r.duration <= 0 && s.duration > 0 { r.duration = s.duration }
        if r.duration <= 0 && s.liveFlag { r.liveFlag = true }
        return r
    }

    /// Опора позиции Музыки по её `player position` (замер `ScriptSource.samplePosition`).
    struct PositionAnchor: Equatable { var elapsed: Double; var at: Date; var title: String }

    /// Позиция Музыки: MediaRemote присылает ElapsedTime+Timestamp только на событиях, и у Музыки эта пара отстаёт от её
    /// `player position` (замер 16.11, SODA LUV «МОРОСЬ»: −1,17 с с начала трека, после события −0,24 с и дальше
    /// −8…−17 мс на каждую секунду — к концу трека текст опаздывал на 2–3 с). Более свежая опора того же трека,
    /// расходящаяся больше чем на 40 мс, заменяет пару MediaRemote; MediaRemote прислал более свежую (перемотка, пауза) —
    /// его, пока не придёт новый замер.
    static func anchored(_ c: NowPlaying, _ a: PositionAnchor?) -> NowPlaying {
        guard let a, c.isMusicApp, c.isPlaying, a.at > c.timestamp,
              LyricsMatch.fold(a.title) == LyricsMatch.fold(c.title),
              abs(c.position(at: a.at) - a.elapsed) > positionTolerance else { return c }
        var r = c
        r.elapsed = a.elapsed
        r.timestamp = a.at
        return r
    }

    /// Расхождение с `player position`, ниже которого опору не меняем (иначе каждая сверка перезапускала бы анимации).
    static let positionTolerance: TimeInterval = 0.04

    /// Пока Музыка играет через MediaRemote — раз в 10 с ловить ступеньку её `player position` (≈ 1 с чтений по 60 мс), и
    /// сразу — когда MediaRemote прислал новую опору (перемотка, пауза, новый трек): его пара отстаёт.
    private func updatePositionSync(mr: NowPlaying?, shown: NowPlaying?) {
        let want = started && !asleep && !isSnapshot && shown?.isMusicApp == true && shown?.isPlaying == true
            && shown?.viaScript == false && script.apps.contains(MediaApps.music)
        if want, let m = mr, m.isMusicApp, m.timestamp != lastMRAnchor {
            lastMRAnchor = m.timestamp
            samplePosition()
        }
        if want && positionSync == nil {
            positionSync = SharedTicker.shared.subscribe(every: Self.positionSyncInterval) { [weak self] _ in
                guard let self, self.started, !self.asleep else { return }
                self.samplePosition()
            }
        } else if !want && positionSync != nil {
            positionSync = nil
            positionAnchor = nil
        }
    }

    private var sampling = false
    private func samplePosition() {
        guard !sampling else { return }
        sampling = true
        script.samplePosition(MediaApps.music, completion: { [weak self] pos, at, title in
            guard let self else { return }
            self.sampling = false
            guard self.started else { return }
            self.positionSamples += 1
            let a = PositionAnchor(elapsed: pos, at: at, title: title)
            guard a != self.positionAnchor else { return }
            self.positionAnchor = a
            self.resolve()
        }, failed: { [weak self] in
            self?.sampling = false
            self?.positionSamplesRejected += 1
        })
    }

    static func sameTrack(_ a: NowPlaying, _ b: NowPlaying) -> Bool {
        LyricsMatch.fold(a.title) == LyricsMatch.fold(b.title) && LyricsMatch.fold(a.artist) == LyricsMatch.fold(b.artist)
    }

    /// Обложки нет через 1 и 3 с после смены трека — переспросить помощника MediaRemote (данные часто приходят
    /// следующим уведомлением) и прочитать AppleScript-ом Музыку/Spotify.
    private var artworkRetryWork: DispatchWorkItem?
    private(set) var artworkRetries = 0

    private func scheduleArtworkRetry(attempt: Int = 0) {
        artworkRetryWork?.cancel(); artworkRetryWork = nil
        guard !isSnapshot, attempt < 2, let n = now, !n.isVideo else { return }
        let key = n.trackKey
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let n = self.now, n.trackKey == key,
                      self.artwork == nil || self.shownTrack != Self.trackTag(n) else { return }
                self.artworkRetries += 1
                self.requestArtwork("нет обложки через \(attempt == 0 ? 1 : 3) с")
                self.scheduleArtworkRetry(attempt: attempt + 1)
            }
        }
        artworkRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 1 : 2), execute: work)
    }

    private func clearArtwork() {
        artwork = nil; palette = []; shownArtworkId = nil; shownTrack = nil; shownAlbum = nil
        setColors(nil)
        updateActivity(force: true)
    }

    /// Цвета обложки → свечение (`setGlow`) и фон темы «из обложки» (`setArtworkColors`, «Хамелеон»).
    private func setColors(_ colors: [Color]?) {
        context?.setGlow(colors)
        context?.setArtworkColors(colors)
    }

    /// Вкладка открылась: перечитать «Далее» (перемешивание/повтор в Музыке могли переключить без смены трека).
    /// И проверить обложку: нет её у текущего трека — дозапросить (с ограничением частоты).
    func expandedDidAppear() {
        guard !isSnapshot, started else { return }
        if let n = now, !n.isVideo, artwork == nil || shownTrack != Self.trackTag(n) { requestArtwork("вкладка открыта") }
        guard now?.bundleId == MediaApps.music else { return }
        script.refreshNext()
    }

    /// Свечение (для активности и `setGlow`): цвета обложки; без обложки — нет своего свечения.
    var glowColors: [Color]? {
        if let p = placeholderArtwork, palette.isEmpty { return ArtworkView.glowColors(for: p) }
        return palette.isEmpty ? nil : ArtworkPalette.glow(palette)
    }

    // MARK: Следующий трек

    /// Источник сообщил следующий трек для `trackKey` (nil — не знает). Показываем только для текущего трека.
    private func handleNext(bundle: String, trackKey: String, title: String?) {
        guard let n = now, n.bundleId == bundle, n.trackKey == trackKey else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = (t?.isEmpty ?? true) ? nil : t
        if v != nextTitle { nextTitle = v }
    }

    // MARK: Текст песни

    private func reloadLyrics() {
        lyricsTask?.cancel(); lyricsTask = nil
        guard !isSnapshot else { return }
        lyrics = nil
        rawLyrics = nil
        lyricIndex = nil
        lyricsKey = nil
        lyricsQueryDuration = 0
        if lyricsNotFound { lyricsNotFound = false }
        // В LRCLIB уходят только песни: Музыка, Spotify, MediaType «музыка»; браузеры — по отдельной настройке.
        guard prefs.lyricsEnabled, let n = now, !n.artist.isEmpty, !n.isVideo, n.isMusicContent || prefs.lyricsAnyApp else { return }
        let key = n.trackKey
        lyricsKey = key
        lyricsQueryDuration = n.duration
        let q = LyricsService.Query(artist: n.artist, title: n.title, album: n.album, duration: n.duration)
        let service = lyricsService
        let sources = prefs.lyricsSources
        let order = prefs.lyricsOrder
        // Длительности ещё нет (MediaRemote шлёт её следом за названием): подождать — придёт, `apply` перезапросит,
        // эта задача отменится. Без длительности подбор строже, версию не проверить.
        let wait: UInt64 = n.duration >= 1 ? 0 : 1_500_000_000
        lyricsTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            guard !Task.isCancelled else { return }
            // Поток: первый подходящий текст — сразу, затем только лучше по синхронизации (построчный → пословный).
            // Смена трека отменяет эту задачу — чтение потока прекращается, LyricsCore отменяет поиск. «Нет сети» —
            // просто пустой поток, без ошибок в интерфейсе.
            for await found in service.updates(q, sources: sources, order: order) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.lyricsKey == key, self.lyricsQueryDuration == q.duration else { return }
                    self.rawLyrics = found.lyrics
                    self.updateLyricsDelay(force: true)
                    self.scheduleLyricTimer()
                    self.updateActivity(force: true)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.lyricsKey == key, self.rawLyrics == nil else { return }
                self.lyricsNotFound = true
            }
        }
    }

    /// Поправка на задержку вывода (устройство сменилось, другой плеер, пришёл текст) → `lyrics` = сдвинутый текст.
    private func updateLyricsDelay(force: Bool = false) {
        guard !isSnapshot else { return }
        let d = LyricsSync.offset(bundleId: now?.bundleId, outputLatency: outputLatency)
        guard force || abs(d - lyricsDelay) > 0.005 else { return }
        lyricsDelay = d
        let shown = rawLyrics?.shifted(by: d)
        if shown != lyrics { lyrics = shown }
        scheduleLyricTimer()
    }

    /// Кеш медиа на диске (тексты песен), байт — для кнопки «Очистить кеш».
    func cacheSize() async -> Int { await lyricsService.diskUsage() }

    /// «Очистить кеш»: тексты (диск и память), HTTP-кеш, обложки в памяти (кроме показанной), цвета.
    func clearCaches() async {
        await lyricsService.clearAll()
        downsampler.removeAll()
        paletteCache = [:]; paletteOrder = []
    }

    /// Один таймер на ближайшую смену строки — только пока играет и строка видна в компакте.
    private func scheduleLyricTimer() {
        lyricTimer?.cancel(); lyricTimer = nil
        guard let n = now, let l = lyrics else { if lyricIndex != nil { lyricIndex = nil }; return }
        let t = n.position()
        let idx = l.index(at: t)
        if idx != lyricIndex { lyricIndex = idx }
        // Остров невидим (экран погас/заблокирован — `motion == .off`): строку не двигаем, на `.motionChanged` — заново.
        guard n.isPlaying, prefs.compactLyrics, !isSnapshot, context?.motion != .off,
              let next = l.nextChange(after: t) else { return }
        let delay = max(0.05, (next - t) / max(0.25, n.rate) + 0.02)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scheduleLyricTimer() } }
        lyricTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var currentLyricText: String? { currentLyricLine?.text }

    /// Текущая строка (со словами, если текст пословный) — для компакта.
    var currentLyricLine: LyricLine? {
        guard let l = lyrics, l.synced, let i = lyricIndex, l.lines.indices.contains(i) else { return nil }
        return l.lines[i].text.isEmpty ? nil : l.lines[i]
    }

    // MARK: Токен Apple Music (Keychain)

    func hasAppleToken() async -> Bool { await lyricsService.hasAppleToken() }

    /// Сохранить/удалить токен; после — искать заново (Apple — первый в каскаде).
    func setAppleToken(_ token: String?) async -> Bool {
        let ok = await lyricsService.setAppleToken(token)
        if ok { reloadLyrics() }
        return ok
    }

    /// Вошли/вышли в источник с учёткой (Яндекс Музыка): забыть «без синхронизации» и искать текущий трек заново.
    func lyricsAccountChanged() async {
        _ = await lyricsService.accountChanged()
        reloadLyrics()
    }

    // MARK: Компакт

    static let activityId = "media.now"

    func compactSideWidth(lyricsShown: Bool) -> CGFloat { lyricsShown ? 170 : 62 }

    /// Повесить/обновить/снять компакт-активность. Вьюхи сами следят за моделью, пересылаем только при смене
    /// ширины, свечения или «играет/пауза».
    func updateActivity(force: Bool = false) {
        guard let ctx = context else { return }
        guard let n = now else {
            if !activitySignature.isEmpty { ctx.removeActivity(id: Self.activityId); activitySignature = "" }
            return
        }
        let showLyrics = prefs.compactLyrics && lyrics?.synced == true
        let sig = "\(n.isPlaying)|\(showLyrics)|\(palette.count)|\(n.artworkId ?? "")|\(videoThumbnailId ?? "")|\(placeholderArtwork.map { "\($0)" } ?? "")"
        guard force || sig != activitySignature else { return }
        activitySignature = sig
        let side = compactSideWidth(lyricsShown: showLyrics)
        // На паузе компакт исчезнет сам через 90 с (один таймер ядра), при возобновлении — вернётся.
        ctx.post(IslandActivity(id: Self.activityId, moduleId: "media", priority: 0, sideWidth: side,
                                glowColors: glowColors,
                                expiresAt: n.isPlaying || isSnapshot ? nil : Date().addingTimeInterval(90),
                                bubble: AnyView(MediaBubbleView(model: self))) {
            MediaCompactLeading(model: self)
        } trailing: {
            MediaCompactTrailing(model: self)
        })
    }

    /// «Показывать вкладку, когда начинается воспроизведение»: новый трек или после паузы дольше минуты —
    /// не каждое возобновление. Через 4 с свернуть, если курсор не над островом (тогда свернёт ядро, когда уйдёт).
    private func maybeOpenTab(playing: Bool) {
        let key = now?.trackKey
        let resumedSoon = key == lastPlayingKey && lastPlayingAt.map { Date().timeIntervalSince($0) < 60 } == true
        defer {
            // Момент паузы (или очередная строка, пока играет) — от него считаем «короткую паузу».
            if playing || wasPlaying { lastPlayingAt = Date(); lastPlayingKey = key }
            wasPlaying = playing
        }
        guard playing, !wasPlaying, !resumedSoon, prefs.openOnPlay, !isSnapshot, let ctx = context,
              Date().timeIntervalSince(startedAt) > 3,
              ctx.island.presentation != .expanded else { return }
        ctx.openTab()
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let ctx = self.context, ctx.isTabVisible, !self.pointerOverTab else { return }
                ctx.collapse()
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Курсор над вкладкой (с полями острова вокруг неё).
    private var pointerOverTab: Bool {
        guard let v = tabView, let w = v.window else { return false }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil)).insetBy(dx: -30, dy: -40)
        return r.contains(NSEvent.mouseLocation)
    }

    // MARK: Команды

    var canControl: Bool { now != nil }
    // MARK: Устройство вывода (чип)

    /// Невидимый системный `AVRoutePickerView` под чипом устройства — его кнопку жмёт пункт «AirPlay…».
    weak var airPlayPicker: NSView?
    static let holdOutput = "output-menu"

    /// Меню устройств вывода под чипом: CoreAudio-устройства с выходом (текущее — галочкой) и «AirPlay…».
    /// Пока меню открыто, остров держится раскрытым.
    func showOutputMenu(from anchor: NSView) {
        let items = OutputDeviceWatcher.menuItems(OutputDeviceWatcher.allDevices(),
                                                  defaultID: OutputDeviceWatcher.defaultOutputID())
        let menu = NSMenu(title: "Вывод звука")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Вывод звука", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for it in items {
            let mi = MenuAction.item(it.title) { _ = OutputDeviceWatcher.setDefaultOutput(it.id) }
            mi.state = it.isCurrent ? .on : .off
            mi.image = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let air = MenuAction.item("AirPlay…") { [weak self] in self?.openAirPlay() }
        air.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: nil)
        menu.addItem(air)
        context?.holdExpanded(Self.holdOutput, timeout: 120)
        // Вид SwiftUI перевёрнут не всегда — берём низ якоря в его системе координат.
        let y: CGFloat = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchor)   // ждёт закрытия меню
        context?.releaseExpanded(Self.holdOutput)
    }

    /// «AirPlay…»: AirPlay-колонки обычно не видны в CoreAudio, пока не выбраны, — открываем системный выбор
    /// (кнопка `AVRoutePickerView` под чипом); его нет — настройки «Звук». [в живом приложении не проверено]
    private func openAirPlay() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let b = self.airPlayPicker.flatMap(Self.firstButton) {
                    self.context?.holdExpanded(Self.holdOutput, timeout: 20)
                    b.performClick(nil)
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private static func firstButton(_ v: NSView) -> NSButton? {
        if let b = v as? NSButton { return b }
        for s in v.subviews { if let b = firstButton(s) { return b } }
        return nil
    }

    /// Кнопка скорости — одно правило на всё (`speedSupported`).
    var canChangeSpeed: Bool { now.map { Self.speedSupported($0, rejected: speedUnsupported) } ?? false }

    /// Правило скорости (16.11, «почему где-то доступно скорость менять, где-то нет?»): кнопка есть, только если
    /// источник реально умеет менять скорость —
    /// * команда скорости идёт только через MediaRemote: трек из AppleScript (Музыка/Spotify без помощника) — нет;
    /// * у прямого эфира и трека без длительности скорости нет;
    /// * песни Музыки и Spotify — нет (их плееры команду скорости не принимают; Spotify её и не объявляет);
    ///   источник сам назвал контент музыкой (`MediaType…Music`) — тоже нет;
    /// * приложение уже раз не подтвердило скорость (`PlaybackRate` не сменился за 2 с) — нет до перезапуска;
    /// * остальное (подкасты, аудиокниги, видео в браузере, IINA/VLC/QuickTime) — есть.
    static let yandexMusic: Set<String> = ["ru.yandex.desktop.music", "ru.yandex.music"]
    static func speedSupported(_ n: NowPlaying, rejected: Set<String>) -> Bool {
        guard !n.viaScript, n.timeline == .timed else { return false }
        // Яндекс Музыка — скорость есть (просьба пользователя 16.11); не примет команду — правило «не подтвердило» скроет.
        if let b = n.bundleId, yandexMusic.contains(b) { return !rejected.contains(b) }
        if n.isMusicApp || n.isSpotify { return false }
        if !n.isVideo && n.mediaType.localizedCaseInsensitiveContains("music") { return false }
        return !rejected.contains(n.bundleId ?? "")
    }
    var canLike: Bool { now?.isMusicApp ?? false }

    func togglePlay() {
        guard var n = now else { return }
        send(.toggle, mr: "toggle")
        // Сразу отражаем нажатие; источник подтвердит своей строкой.
        n.elapsed = n.position(); n.timestamp = Date(); n.isPlaying.toggle()
        now = n
        updateLiveAudio()
        scheduleLyricTimer()
        updateActivity()
    }

    /// Клик по обложке: открыть играющий трек в его приложении (Музыка — «показать трек», Spotify — окно; прочие —
    /// вывести приложение-источник вперёд).
    func revealSource() {
        guard let n = now, let b = n.bundleId else { return }
        if n.isMusicApp || n.isSpotify, script.apps.contains(b) {
            script.send(.reveal, to: b)
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func next() { send(.next, mr: "next") }
    func previous() { send(.prev, mr: "prev") }

    func seek(to seconds: Double) {
        guard var n = now else { return }
        let t = max(0, n.duration > 0 ? min(seconds, n.duration) : seconds)
        send(.seek(t), mr: String(format: "seek %.3f", locale: Locale(identifier: "en_US_POSIX"), t))
        n.elapsed = t; n.timestamp = Date()
        now = n
        scheduleLyricTimer()
    }

    static let speeds: [Double] = [1, 1.25, 1.5, 2, 0.75]

    func cycleSpeed() {
        guard canChangeSpeed else { return }
        let i = Self.speeds.firstIndex { abs($0 - speed) < 0.01 } ?? 0
        let s = Self.speeds[(i + 1) % Self.speeds.count]
        let before = speed
        let bundle = now?.bundleId ?? ""
        speed = s
        pendingSpeed = s
        mr.send(String(format: "speed %.2f", locale: Locale(identifier: "en_US_POSIX"), s))
        // Команда скорости MediaRemote не проверена на всех плеерах: нет подтверждения `PlaybackRate` за 2 с —
        // вернуть прежнее значение и спрятать кнопку для этого приложения.
        speedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingSpeed == s else { return }
                self.pendingSpeed = nil
                self.speed = before
                self.speedUnsupported.insert(bundle)
                NSLog("SimpleIsland media: скорость %.2f не подтверждена (%@) — кнопка скрыта", s, bundle)
            }
        }
        speedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func toggleLike() {
        guard canLike else { return }
        if permissionNeeded[MediaApps.music] == true { requestPermission(MediaApps.music); return }
        liked = !(liked ?? false)
        script.send(.like, to: MediaApps.music)
    }

    func requestPermission(_ bundleId: String) {
        ScriptSource.requestAutomation(bundleId) { [weak self] ok in
            guard let self else { return }
            self.permissionNeeded[bundleId] = !ok
            if ok { self.script.refresh(bundleId) }
            self.resolve()
        }
    }

    private func send(_ c: ScriptSource.Command, mr command: String) {
        guard let n = now else { return }
        if n.viaScript, let b = n.bundleId {
            if permissionNeeded[b] == true { requestPermission(b); return }
            script.send(c, to: b)
        } else {
            mr.send(command)
        }
    }

    // MARK: Медиаклавиши

    static func onlyKeysChanged(_ a: MediaPrefs, _ b: MediaPrefs) -> Bool {
        var x = a, y = b
        for p in [\MediaPrefs.mediaKeys] { x[keyPath: p] = false; y[keyPath: p] = false }
        x.mediaKeysTarget = .system; y.mediaKeysTarget = .system
        x.lastMusicBundle = nil; y.lastMusicBundle = nil
        x.lastMusicName = nil; y.lastMusicName = nil
        x.customEQ = []; y.customEQ = []   // свои пресеты эквалайзера плеер не касаются
        return x == y
    }

    func startKeysForTest() { startKeys() }
    func setKeysAutomationForTest(_ s: PermissionStatus?) { keysAutomation = s }

    private func startKeys() {
        keys.inputs = { [weak self] in self?.keyInputs() ?? MediaKeyRouting.Inputs(
            enabled: false, lastMusic: nil, lastMusicRunning: false, current: nil, systemKnown: false,
            automation: nil, canSendToApp: false) }
        keys.perform = { [weak self] c, r in self?.performKey(c, r) }
        keys.feedback = { [weak self] c, b in self?.flashKey(c, bundle: b) }
        keys.requestPermission = { [weak self] b, done in
            Task { @MainActor in
                let st = await Permissions.requestFromUser(.automation(bundleId: b), moduleId: "media")
                self?.keysAutomation = st
                done(st == .granted)
            }
        }
        router.register(owner: "media", wants: prefs.wantsMediaKeys) { [weak self] p in self?.keys.handle(p) ?? false }
        refreshKeysAutomation()
    }

    func keyInputs() -> MediaKeyRouting.Inputs {
        let last = prefs.lastMusicBundle
        let running = last.map { b in isAppRunningForTest?(b) ?? ScriptSource.isRunning(b) } ?? false
        return MediaKeyRouting.Inputs(enabled: prefs.wantsMediaKeys, lastMusic: last, lastMusicRunning: running,
                                      current: useMediaRemote ? mrNow : nil, systemKnown: useMediaRemote,
                                      automation: keysAutomation, canSendToApp: mr.canSendToApp)
    }

    /// Запомнить, где реально играет музыка: MediaRemote (любое приложение) или AppleScript (Музыка/Spotify).
    private func noteMusic() {
        let candidates = [useMediaRemote ? mrNow : nil, scriptNow].compactMap { $0 }
        if let n = candidates.first(where: { $0.isPlaying && MusicApps.qualifies($0) }), let b = n.bundleId {
            lastMusicTrack = n
            if b == now?.bundleId, let a = artwork { lastMusicCover = a }
            if prefs.lastMusicBundle != b {
                prefs.lastMusicBundle = b
                prefs.lastMusicName = MusicApps.known[b] ?? n.appName ?? appDisplayName(bundleId: b, pid: n.pid)
            }
        } else if let b = prefs.lastMusicBundle, let n = candidates.first(where: { $0.bundleId == b }) {
            lastMusicTrack = n   // то же приложение на паузе — состояние для подписи «Пауза / Играет»
        }
    }

    /// Проверить «Автоматизацию» для цели клавиш (без окна, на потоке AppleScript).
    func refreshKeysAutomation() {
        guard let b = prefs.lastMusicBundle, MusicApps.scriptable(b), !isSnapshot else { keysAutomation = nil; return }
        ScriptSource.perform { [weak self] in
            let st = ScriptSource.automationStatus(b, ask: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.prefs.lastMusicBundle == b else { return }
                    // -600 (приложение не запущено) — не знаем; спросим при нажатии.
                    switch st {
                    case noErr: self.keysAutomation = .granted
                    case OSStatus(errAEEventNotPermitted): self.keysAutomation = .denied
                    case -1744: self.keysAutomation = .notDetermined
                    default: self.keysAutomation = nil
                    }
                }
            }
        }
    }

    private func performKey(_ c: MediaKeyCommand, _ r: MediaKeyRoute) {
        if c == .toggle, var t = lastMusicTrack, t.bundleId == r.bundle { t.isPlaying.toggle(); lastMusicTrack = t }
        if let sink = keyCommandSinkForTest { sink(c, r); return }
        switch r {
        case .script(let b):
            let sc: ScriptSource.Command
            switch c {
            case .toggle: sc = .toggle
            case .next: sc = .next
            case .previous: sc = .prev
            case .seekBegin(let f): sc = f ? .fastForward : .rewind
            case .seekEnd: sc = .resume
            case .step(let d): sc = .step(d)
            }
            script.send(sc, to: b)
        case .remote(let b):
            let code: Int
            switch c {
            case .toggle: code = 2
            case .next: code = 4
            case .previous: code = 5
            case .seekBegin(let f): code = f ? 8 : 10
            case .seekEnd(let f): code = f ? 9 : 11
            case .step: return
            }
            mr.sendTo(bundle: b, code: code)
        case .system, .passThrough, .needsPermission:
            break
        }
    }

    /// Играла ли цель до нажатия (для «Пауза / Играет»).
    func targetWasPlaying(_ b: String) -> Bool? {
        if useMediaRemote, let m = mrNow, m.bundleId == b { return m.isPlaying }
        if let s = scriptNow, s.bundleId == b { return s.isPlaying }
        if let t = lastMusicTrack, t.bundleId == b { return t.isPlaying }
        return nil
    }

    /// Последняя вспышка клавиш (самотест).
    private(set) var lastKeyFlash: HUDEvent?

    /// ⏭/⏮ клавишей: вспышка ждёт новый трек — обложка и название СЛЕДУЮЩЕГО, а не того, что играл (18.11).
    private var pendingTrackFlash: (command: MediaKeyCommand, bundle: String, oldKey: String?, until: Date)?

    /// Новый трек пришёл / показал обложку — обновить вспышку ⏭/⏮ (если она ещё ждёт): название сразу, обложка —
    /// как только показана обложка именно нового трека.
    private func refreshTrackKeyFlash() {
        guard let p = pendingTrackFlash else { return }
        guard Date() < p.until else { pendingTrackFlash = nil; return }
        guard let n = now, n.bundleId == p.bundle, n.trackKey != p.oldKey else { return }
        let coverIsNew = artwork != nil && shownTrack == Self.trackTag(n)
        if coverIsNew { pendingTrackFlash = nil }
        let e = MediaKeyFlash.event(label: MediaKeyFlash.label(p.command, wasPlaying: true),
                                    symbol: MediaKeyFlash.systemImage(p.command, wasPlaying: true),
                                    trailing: n.title, cover: coverIsNew ? artwork : nil)
        lastKeyFlash = e
        guard !isSnapshot else { return }
        context?.flashHUD(e, duration: 1.6)
    }

    private func flashKey(_ c: MediaKeyCommand, bundle b: String) {
        let was = targetWasPlaying(b)
        let track = (now?.bundleId == b ? now : nil) ?? (lastMusicTrack?.bundleId == b ? lastMusicTrack : nil)
        let isTrackChange = c == .next || c == .previous
        if isTrackChange { pendingTrackFlash = (c, b, track?.trackKey, Date().addingTimeInterval(3)) }
        // Смена трека: обложку прежнего не показывать — до прихода новой значок без картинки.
        let cover = isTrackChange ? nil : ((now?.bundleId == b ? coverImage : nil) ?? lastMusicCover)
        let app = MusicApps.known[b] ?? prefs.lastMusicName ?? appDisplayName(bundleId: b, pid: nil) ?? ""
        var trailing = app
        if c == .toggle, let t = track, !t.title.isEmpty { trailing = t.title }
        // ⏭/⏮: не «Музыка», а сразу трек (18.11) — следующий, если знаем, иначе пусто до прихода нового трека.
        if isTrackChange { trailing = (c == .next ? nextTitle : nil) ?? "" }
        let e = MediaKeyFlash.event(label: MediaKeyFlash.label(c, wasPlaying: was),
                                    symbol: MediaKeyFlash.systemImage(c, wasPlaying: was), trailing: trailing, cover: cover)
        lastKeyFlash = e
        guard !isSnapshot else { return }
        context?.flashHUD(e, duration: 1.6)
    }

    // MARK: Самотест

    /// pid процесса помощника MediaRemote (nil — не работает).
    var helperPID: pid_t? {
        guard let p = mr.process, p.isRunning, p.pid > 0 else { return nil }
        return p.pid
    }
    var shownArtworkIdForTest: String? { shownArtworkId }

    /// Как строка помощника MediaRemote (без процесса): самотест памяти/«Далее».
    func simulateMediaRemote(_ n: NowPlaying?) {
        mrNow = n
        useMediaRemote = true
        resolve()
    }

    /// Снимки виджета «Эквалайзер»: состояние права без системы.
    func mockAudioPermission(_ p: PermissionStatus) { audioPermission = p }

    /// Как ответ AppleScript (без потока скриптов): самотест цепочки обложек.
    func simulateScript(_ n: NowPlaying?) {
        scriptNow = n
        resolve()
    }

    func simulateNext(bundle: String, trackKey: String, title: String?) {
        handleNext(bundle: bundle, trackKey: trackKey, title: title)
    }

    // MARK: Снимки

    /// Мок-состояние без системы: трек, обложка-градиент (через настоящий расчёт цветов), текст песни.
    func applyMock(_ n: NowPlaying?, placeholder: ArtworkView.Placeholder?, lyrics: Lyrics?, liked: Bool? = nil,
                   availability: MediaAvailability = .ok, device: OutputDevice? = OutputDevice(name: "AirPods Pro", kind: .bluetooth),
                   next: String? = nil) {
        isSnapshot = true
        placeholderArtwork = placeholder
        if let p = placeholder, let img = Self.renderPlaceholder(p), let cg = img.cgImageForPalette {
            artwork = img
            palette = ArtworkPalette.dominantColors(of: cg)
        } else {
            artwork = nil
            palette = []
        }
        now = n
        self.lyrics = lyrics
        self.rawLyrics = lyrics
        self.liked = liked
        self.availability = availability
        self.device = device
        self.nextTitle = next
        if let n, let l = lyrics { lyricIndex = l.index(at: n.position()) } else { lyricIndex = nil }
        setColors(glowColors)
        updateActivity(force: true)
    }

    static func renderPlaceholder(_ p: ArtworkView.Placeholder) -> NSImage? {
        let r = ImageRenderer(content: ArtworkView(cornerRadius: 0, placeholder: p).frame(width: 200, height: 200))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))
    }
}

/// Пункт NSMenu с замыканием (цель держит сам пункт).
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }

    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        let mi = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        mi.target = a
        mi.representedObject = a
        return mi
    }
}
