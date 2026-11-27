import AppKit
import IslandCore

/// Самотест медиаклавиш (часть `--selftest-media`): выбор цели, нажатия → команды через заглушку (ничего не уходит
/// ни в систему, ни в AppleScript, ни помощнику), запоминание последнего музыкального приложения, вспышка.
enum MediaKeysSelfTest {
    @MainActor
    static func run(_ check: LyricsSelfTest.Check) {
        decide(check)
        qualifies(check)
        controller(check)
        model(check)
    }

    private static func track(_ bundle: String, playing: Bool, album: String = "Альбом", mediaType: String = "") -> NowPlaying {
        var n = NowPlaying(title: "Трек"); n.artist = "Исполнитель"; n.album = album
        n.bundleId = bundle; n.isPlaying = playing; n.mediaType = mediaType; n.duration = 200
        return n
    }

    private static func inputs(last: String? = MediaApps.music, running: Bool = true, current: NowPlaying? = nil,
                               known: Bool = true, automation: PermissionStatus? = .granted, sendTo: Bool = false,
                               enabled: Bool = true) -> MediaKeyRouting.Inputs {
        .init(enabled: enabled, lastMusic: last, lastMusicRunning: running, current: current, systemKnown: known,
              automation: automation, canSendToApp: sendTo)
    }

    @MainActor
    private static func decide(_ check: LyricsSelfTest.Check) {
        let chromeVideoPaused = track("com.google.Chrome", playing: false, album: "")
        let chromeVideoPlaying = track("com.google.Chrome", playing: true, album: "")
        func d(_ i: MediaKeyRouting.Inputs) -> MediaKeyRoute { MediaKeyRouting.decide(i) }
        var r = d(inputs(current: chromeVideoPaused))
        check(r == .script(MediaApps.music), "клавиши: музыка играла последней + видео на паузе → Музыка (AppleScript)", "\(r)")
        r = d(inputs(current: chromeVideoPlaying))
        check(r == .system("играет видео"), "клавиши: видео реально играет → система", "\(r)")
        var paused = inputs(current: chromeVideoPaused); paused.pausedOther = "com.google.Chrome"
        r = d(paused)
        check(!r.swallows && r.bundle == nil, "клавиши: видео поставили на паузу клавишей → следующее ⏯ продолжает видео, не музыку", "\(r)")
        r = d(inputs(running: false, current: chromeVideoPaused))
        check(r == .system("музыкальное приложение закрыто"), "клавиши: музыкальное приложение закрыто → система", "\(r)")
        r = d(inputs(current: chromeVideoPaused, enabled: false))
        check(!r.swallows && r.bundle == nil, "клавиши: настройка выключена → система", "\(r)")
        r = d(inputs(last: nil, current: chromeVideoPaused))
        check(r == .system("музыка ещё не играла"), "клавиши: музыка ещё не играла → система", "\(r)")
        r = d(inputs(current: chromeVideoPaused, known: false))
        check(!r.swallows, "клавиши: MediaRemote недоступен (не знаем, играет ли видео) → система", "\(r)")
        r = d(inputs(current: track(MediaApps.music, playing: false)))
        check(r == .passThrough(MediaApps.music), "клавиши: Музыка и есть текущий Now Playing → не глотаем, система отдаст ей", "\(r)")
        r = d(inputs(current: track("com.google.Chrome", playing: true, album: "Альбом")))
        check(r == .system("играет другое приложение"), "клавиши: в браузере играет музыка/звук → система (пауза — ему)", "\(r)")
        r = d(inputs(last: MediaApps.spotify, current: chromeVideoPaused, automation: nil))
        check(r == .needsPermission(MediaApps.spotify), "клавиши: Spotify без проверенного права → глотаем и просим «Автоматизацию»", "\(r)")
        r = d(inputs(last: MediaApps.spotify, current: chromeVideoPaused, automation: .denied))
        check(r == .system("нет права «Автоматизация»"), "клавиши: «Автоматизация» запрещена → система", "\(r)")
        r = d(inputs(last: "com.swinsian.Swinsian", current: chromeVideoPaused, sendTo: true))
        check(r == .remote("com.swinsian.Swinsian"), "клавиши: прочий плеер + помощник умеет sendto → MediaRemote приложению", "\(r)")
        r = d(inputs(last: "com.swinsian.Swinsian", current: chromeVideoPaused, sendTo: false))
        check(!r.swallows, "клавиши: прочий плеер, sendto нет → не глотаем", "\(r)")
        r = d(inputs(current: nil))
        check(r == .script(MediaApps.music), "клавиши: Now Playing пуст, Музыка запущена → Музыке (а не запуск Музыки системой)", "\(r)")
    }

    @MainActor
    private static func qualifies(_ check: LyricsSelfTest.Check) {
        check(MusicApps.qualifies(track(MediaApps.music, playing: true))
              && MusicApps.qualifies(track("com.spotify.client", playing: true))
              && MusicApps.qualifies(track("ru.yandex.desktop.music", playing: true)),
              "музыкальные: Музыка, Spotify, Яндекс Музыка", "")
        check(MusicApps.qualifies(track("com.google.Chrome", playing: true, album: "Альбом")),
              "музыкальные: песня в браузере (исполнитель + альбом — Яндекс Музыка в Chrome, 23.11)", "")
        check(!MusicApps.qualifies(track("com.google.Chrome", playing: true, album: ""))
              && !MusicApps.qualifies(track("com.colliderli.iina", playing: true))
              && !MusicApps.qualifies(track("com.example.player", playing: true, mediaType: "MRMediaRemoteMediaTypeVideo")),
              "не музыкальные: видео в браузере (без альбома), видеоплеер, источник сказал «видео»", "")
        check(MusicApps.qualifies(track("com.example.player", playing: true, mediaType: "MRMediaRemoteMediaTypeMusic"))
              && !MusicApps.qualifies(track("com.example.player", playing: true)),
              "незнакомый плеер: музыка — только если источник сам назвал MediaType музыкой", "")
    }

    @MainActor
    private static func controller(_ check: LyricsSelfTest.Check) {
        let c = MediaKeyController()
        var route = MediaKeyRoute.script(MediaApps.music)
        var sent: [MediaKeyCommand] = []
        var flashes: [MediaKeyCommand] = []
        c.inputs = {
            switch route {
            case .script(let b): return inputs(last: b, current: track("com.google.Chrome", playing: false, album: ""))
            case .passThrough(let b): return inputs(last: b, current: track(b, playing: true))
            default: return inputs(current: track("com.google.Chrome", playing: true, album: ""))
            }
        }
        c.perform = { cmd, _ in sent.append(cmd) }
        c.feedback = { cmd, _ in flashes.append(cmd) }
        func press(_ k: MediaTransportKey, _ ph: MediaTransportPress.Phase) -> Bool { c.handle(.init(key: k, phase: ph)) }
        func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

        check(press(.playPause, .down) && sent == [.toggle] && flashes == [.toggle], "клавиши: ⏯ → toggle Музыке сразу + вспышка", "\(sent)")
        check(press(.playPause, .repeating), "клавиши: автоповтор проглоченной ⏯ тоже глотается", "")
        _ = press(.playPause, .up)
        check(sent == [.toggle] && c.pendingWork == 0, "клавиши: отпускание ⏯ ничего не шлёт, отложенного нет", "\(sent)")

        sent = []; flashes = []
        check(press(.next, .down) && sent.isEmpty, "клавиши: ⏭ нажата — ждём, удержание это или нет", "\(sent)")
        spin(0.1)
        _ = press(.next, .up)
        check(sent == [.next] && flashes == [.next] && c.pendingWork == 0, "клавиши: короткое ⏭ → следующий трек", "\(sent)")

        sent = []; flashes = []
        _ = press(.previous, .down)
        spin(MediaKeyController.holdDelay + 0.25)
        check(sent == [.seekBegin(forward: false)], "клавиши: удержание ⏮ → перемотка назад (Музыка: rewind)", "\(sent)")
        _ = press(.previous, .up)
        check(sent == [.seekBegin(forward: false), .seekEnd(forward: false)] && c.pendingWork == 0,
              "клавиши: отпускание после удержания → конец перемотки, без «предыдущего трека»", "\(sent)")

        route = .script(MediaApps.spotify)
        sent = []
        _ = press(.next, .down)
        spin(MediaKeyController.holdDelay + MediaKeyController.spotifyStepPeriod + 0.25)
        _ = press(.next, .up)
        let steps = sent.filter { if case .step(let s) = $0 { return s > 0 } else { return false } }.count
        check(steps >= 2 && !sent.contains(.next) && c.pendingWork == 0, "клавиши: удержание ⏭ в Spotify → шаги +10 с", "\(sent)")

        route = .system("")
        sent = []; flashes = []
        check(!press(.playPause, .down) && !press(.playPause, .repeating) && sent.isEmpty && flashes.isEmpty,
              "клавиши: цель — система → не глотаем, команд и вспышек нет", "")
        _ = press(.playPause, .up)

        route = .passThrough(MediaApps.music)
        check(!press(.next, .down) && sent.isEmpty && flashes == [.next], "клавиши: Музыка — текущий Now Playing → система, вспышка есть", "")
        _ = press(.next, .up)
        c.reset()
    }

    @MainActor
    private static func model(_ check: LyricsSelfTest.Check) {
        let settings = SimpleIslandSettings(inMemory: SettingsData())
        let ctx = ModuleContext(moduleId: "media", settings: settings, themes: ThemeStore(load: false),
                                activities: ActivityCenter(), hud: HUDCenter(), notifications: IslandNotifications(),
                                island: IslandStateCenter(), openTab: { _ in })
        let m = MediaModel()
        m.context = ctx
        var p = MediaPrefs(); p.lyricsEnabled = false; p.liveVisualizer = false
        m.prefs = p
        let router = MediaKeyRouter()
        m.router = router
        m.isAppRunningForTest = { _ in true }
        var sent: [(MediaKeyCommand, MediaKeyRoute)] = []
        m.keyCommandSinkForTest = { sent.append(($0, $1)) }
        m.startKeysForTest()
        check(router.wantsKeys, "клавиши: модуль просит клавиши у моста (по умолчанию вкл.)", "")
        check(MediaPrefs().mediaKeys && MediaPrefs().mediaKeysTarget == .lastMusicApp, "клавиши: настройка по умолчанию — музыке", "")

        m.simulateMediaRemote(track(MediaApps.music, playing: true))
        check(m.prefs.lastMusicBundle == MediaApps.music && ctx.loadSettings(MediaPrefs.self)?.lastMusicBundle == MediaApps.music,
              "клавиши: играла Музыка → запомнена и сохранена в настройках модуля", "\(m.prefs.lastMusicBundle ?? "нет")")
        m.simulateMediaRemote(track("com.google.Chrome", playing: true, album: ""))
        check(m.prefs.lastMusicBundle == MediaApps.music, "клавиши: видео в Chrome не перебивает «последнее музыкальное»", "")
        check(!router.handle(.init(key: .playPause, phase: .down)) && sent.isEmpty, "клавиши: видео играет → система", "")
        _ = router.handle(.init(key: .playPause, phase: .up))
        m.simulateMediaRemote(track("com.google.Chrome", playing: false, album: ""))
        m.setKeysAutomationForTest(.granted)
        check(!router.handle(.init(key: .playPause, phase: .down)) && sent.isEmpty,
              "клавиши: видео поставили на паузу клавишей → повторное ⏯ — системе (продолжит видео), не музыке", "\(sent.map { "\($0.1)" })")
        _ = router.handle(.init(key: .playPause, phase: .up))
        m.keys.forgetPausedOtherForTest()   // дальше: видео на паузе не нашей клавишей
        check(router.handle(.init(key: .playPause, phase: .down)) && sent.first?.0 == .toggle
              && sent.first?.1 == .script(MediaApps.music),
              "клавиши: видео на паузе → ⏯ проглочена, toggle — Музыке (заглушка, в систему ничего)", "\(sent.map { "\($0.1)" })")
        check(m.lastKeyFlash?.kind == "media.key" && m.lastKeyFlash?.accessibilityLabel?.hasPrefix("Пауза") == true,
              "клавиши: вспышка «Пауза» (Музыка играла до нажатия)", m.lastKeyFlash?.accessibilityLabel ?? "нет")
        _ = router.handle(.init(key: .playPause, phase: .up))
        _ = router.handle(.init(key: .playPause, phase: .down))
        check(m.lastKeyFlash?.accessibilityLabel?.hasPrefix("Играет") == true, "клавиши: второе нажатие — «Играет»",
              m.lastKeyFlash?.accessibilityLabel ?? "нет")
        _ = router.handle(.init(key: .playPause, phase: .up))

        var off = m.prefs; off.mediaKeysTarget = .system
        m.prefs = off
        check(!router.wantsKeys, "клавиши: «Как в системе» → мост клавиши не просит (HUD tap не держит ради них)", "")
        m.stop()
        check(m.keys.pendingWork == 0, "клавиши: stop() — отложенного нет", "")
    }
}
