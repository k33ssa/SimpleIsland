import Foundation
import IslandCore

// Самотест эквалайзера по настоящему звуку и «видео/музыка» (часть `--selftest-media`, без захвата звука и прав):
// полосы из синтетического сигнала, AGC, затухание, частота расчётов; выбор процессов для tap; жизненный цикл
// захвата на заглушке; решение «видео или музыка»; микробенч обработки 1 с звука 48 кГц стерео.
extension MediaSelfTest {
    @MainActor
    static func liveAudioTests(check: Checker) {
        spectrumTests(check: check)
        planTests(check: check)
        feedTests(check: check)
        controllerTests(check: check)
        videoTests(check: check)
        videoThumbnailFlow(check: check)
        bench(check: check)
    }

    // MARK: Сигналы

    /// Чередующееся стерео: синус `hz` амплитуды `amp` (amp 0 — точные нули), `seconds` секунд.
    static func sine(_ hz: Double, amp: Float, seconds: Double, rate: Double = 48_000, phase0: Int = 0) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n * 2)
        guard amp != 0 else { return out }
        for i in 0..<n {
            let v = amp * Float(sin(2 * Double.pi * hz * Double(i + phase0) / rate))
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }

    /// Подать стерео кусками по `chunk` кадров. Возвращает число новых расчётов.
    @discardableResult
    static func feed(_ sp: AudioSpectrum, _ x: [Float], chunk: Int = 4096) -> Int {
        var fresh = 0
        x.withUnsafeBufferPointer { b in
            let frames = b.count / 2
            var i = 0
            while i < frames {
                let n = min(chunk, frames - i)
                if sp.process(interleaved: b.baseAddress! + 2 * i, frames: n, channels: 2) { fresh += 1 }
                i += n
            }
        }
        return fresh
    }

    static func argmax(_ a: [Float]) -> Int { a.indices.max { a[$0] < a[$1] } ?? -1 }

    // MARK: Полосы

    private static func spectrumTests(check: Checker) {
        let probe = AudioSpectrum(sampleRate: 48_000)
        let e = probe.edges
        check(e.count == AudioSpectrum.wideCount + 1 && zip(e, e.dropFirst()).allSatisfy { $0 < $1 },
              "Полосы: 24 полосы, края по бинам растут", "\(e)")
        func bandOf(_ hz: Double) -> Int {
            let bin = Int((hz / (48_000.0 / Double(AudioSpectrum.fftSize))).rounded())
            return (0..<AudioSpectrum.wideCount).first { e[$0] <= bin && bin < e[$0 + 1] } ?? -1
        }

        let low = AudioSpectrum(sampleRate: 48_000)
        let analyses = feed(low, sine(100, amp: 0.5, seconds: 1))
        check(argmax(low.wide) == bandOf(100) && argmax(low.compact) == 0,
              "Синус 100 Гц → широкая полоса \(bandOf(100)) (~\(Int(low.centerHz(ofWideBand: max(0, bandOf(100))))) Гц) и компактная 0",
              "wide max \(argmax(low.wide)), compact \(low.compact.map { String(format: "%.2f", $0) })")
        check(low.compact[0] > 0.8 && low.compact[3] < 0.3 && low.compact[4] < 0.3,
              "Синус 100 Гц: низ — высоко, верх — низко", "\(low.compact)")
        check(analyses >= 10 && analyses <= 20, "Расчётов ≤ 20 в секунду (буферы по 4096: ~12)", "\(analyses)")

        let high = AudioSpectrum(sampleRate: 48_000)
        feed(high, sine(5000, amp: 0.5, seconds: 1))
        check(argmax(high.wide) == bandOf(5000) && argmax(high.compact) == 3,
              "Синус 5 кГц → широкая полоса \(bandOf(5000)) и компактная 3",
              "wide max \(argmax(high.wide)), compact \(high.compact.map { String(format: "%.2f", $0) })")
        check(high.compact[0] < 0.3, "Синус 5 кГц: низ — низко", "\(high.compact[0])")

        let small = AudioSpectrum(sampleRate: 48_000)
        let n512 = feed(small, sine(440, amp: 0.3, seconds: 1), chunk: 512)
        check(n512 <= 20 && n512 >= 18, "Маленькие буферы (512): всё равно ≤ 20 расчётов в секунду", "\(n512)")

        let silent = AudioSpectrum(sampleRate: 48_000)
        feed(silent, sine(0, amp: 0, seconds: 1))
        check(silent.wide.allSatisfy { $0 == 0 } && silent.compact.allSatisfy { $0 == 0 } && silent.lastWasSilent
              && silent.silentSeconds > 0.8,
              "Тишина (точные нули) → все полосы 0, отмечена тишина", "\(silent.silentSeconds) с")

        // AGC: тихий и громкий сигнал после привыкания — оба на высоте (не «лежат» и не упираются).
        let quiet = AudioSpectrum(sampleRate: 48_000)
        feed(quiet, sine(1000, amp: 0.003, seconds: 3))
        let loud = AudioSpectrum(sampleRate: 48_000)
        feed(loud, sine(1000, amp: 0.8, seconds: 3))
        check(quiet.wide.max()! > 0.8 && loud.wide.max()! > 0.8,
              "AGC: тихий (−50 дБ) и громкий синус — пик полос > 0,8",
              String(format: "%.2f / %.2f", quiet.wide.max()!, loud.wide.max()!))
        // Громкость упала на 30 дБ — сразу ниже, через несколько секунд опора опустилась и полосы снова выше.
        feed(loud, sine(1000, amp: 0.025, seconds: 0.3, phase0: 144_000))
        let dropped = loud.wide.max()!
        feed(loud, sine(1000, amp: 0.025, seconds: 5, phase0: 158_400))
        let adapted = loud.wide.max()!
        check(dropped < 0.75 && adapted > dropped + 0.15, "AGC: тише на 30 дБ — сразу ниже, через 5 с подтянулось",
              String(format: "%.2f → %.2f", dropped, adapted))

        // Затухание: звук оборвался — полосы спадают плавно (~0,25 с), а не мгновенно.
        let decay = AudioSpectrum(sampleRate: 48_000)
        feed(decay, sine(100, amp: 0.5, seconds: 1))
        let before = decay.compact[0]
        feed(decay, sine(0, amp: 0, seconds: 0.1), chunk: 512)
        let after100 = decay.compact[0]
        feed(decay, sine(0, amp: 0, seconds: 1.4), chunk: 512)
        let after1500 = decay.compact[0]
        check(before > 0.8 && after100 > 0.3 && after100 < before && after1500 < 0.05,
              "Затухание: через 0,1 с ещё видно, через 1,5 с — ноль",
              String(format: "%.2f → %.2f → %.3f", before, after100, after1500))

        // Неперемежённый формат даёт то же, что перемежённый.
        let a = AudioSpectrum(sampleRate: 48_000), b = AudioSpectrum(sampleRate: 48_000)
        let x = sine(700, amp: 0.4, seconds: 0.5)
        feed(a, x, chunk: 4800)
        let l = stride(from: 0, to: x.count, by: 2).map { x[$0] }
        l.withUnsafeBufferPointer { lp in
            var i = 0
            while i < l.count { let n = min(4800, l.count - i); b.process(planar: [lp.baseAddress! + i, lp.baseAddress! + i], frames: n); i += n }
        }
        check(zip(a.wide, b.wide).allSatisfy { abs($0 - $1) < 1e-4 }, "Неперемежённые каналы = перемежённые")

        // Другая частота дискретизации (44,1 кГц) — полосы те же по герцам.
        let r44 = AudioSpectrum(sampleRate: 44_100)
        feed(r44, sine(100, amp: 0.5, seconds: 1, rate: 44_100))
        check(argmax(r44.compact) == 0, "44,1 кГц: 100 Гц → компактная 0")
    }

    // MARK: Выбор процессов для tap

    private static func planTests(check: Checker) {
        let own: Int32 = 999
        let list = [
            AudioProcessEntry(object: 11, pid: 100, bundleId: "com.google.Chrome"),
            AudioProcessEntry(object: 12, pid: 101, bundleId: "com.google.Chrome.helper"),
            AudioProcessEntry(object: 13, pid: 200, bundleId: "com.apple.Music"),
            AudioProcessEntry(object: 14, pid: 300, bundleId: "com.apple.WebKit.GPU"),
            AudioProcessEntry(object: 15, pid: own, bundleId: "app.simpleisland"),
        ]
        check(AudioTapPlan.choose(target: .init(pid: 100, bundleId: "com.google.Chrome"), processes: list, ownPid: own)
              == .processes([11, 12]), "tap: Chrome и его помощник (звук идёт из Chrome Helper)")
        check(AudioTapPlan.choose(target: .init(pid: 200, bundleId: "com.apple.Music"), processes: list, ownPid: own)
              == .processes([13]), "tap: только Музыка")
        check(AudioTapPlan.choose(target: .init(pid: 400, bundleId: "com.apple.Safari"), processes: list, ownPid: own)
              == .processes([14]), "tap: Safari → WebKit.GPU")
        check(AudioTapPlan.choose(target: .init(pid: nil, bundleId: "org.videolan.vlc"), processes: list, ownPid: own)
              == .global(excluding: [15]), "tap: плеера нет среди аудио-процессов → весь вывод, кроме себя")
        let lookalike = list + [AudioProcessEntry(object: 16, pid: 500, bundleId: "com.google.ChromeRemoteDesktop")]
        check(AudioTapPlan.choose(target: .init(pid: 100, bundleId: "com.google.Chrome"), processes: lookalike, ownPid: own)
              == .processes([11, 12]), "tap: похожий bundle id без точки (com.google.ChromeRemoteDesktop) — не помощник")
    }

    // MARK: Канал уровней

    @MainActor
    private static func feedTests(check: Checker) {
        let f = AudioLevelsFeed()
        var demand: [Bool] = []
        f.onDemandChange = { demand.append($0) }
        let o1 = NSObject(), o2 = NSObject()
        var got = 0
        f.addSink(o1) { _ in got += 1 }
        f.addSink(o2) { _ in got += 1 }
        f.publish(wide: (0..<24).map { Float($0) / 23 }, compact: [0.1, 0.2, 0.3, 0.4, 0.5], interval: 0.08)
        check(f.isLive && got == 2 && f.levels(count: 5) == [0.1, 0.2, 0.3, 0.4, 0.5] && f.levels(count: 12).count == 12
              && f.levels(count: 12)[11] > 0.9, "Канал уровней: две полоски получили, 5/24/12 полос")
        f.removeSink(o1); f.removeSink(o2)
        check(demand == [true, false], "Канал уровней: спрос — с первой полоской, пропал — с последней", "\(demand)")
        f.setIdle()
        check(!f.isLive && f.compact.allSatisfy { $0 == 0 }, "Канал уровней: setIdle — псевдополоски")
    }

    // MARK: Жизненный цикл захвата (заглушка вместо Core Audio)

    final class StubBackend: AudioCaptureBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _running = false, _starts = 0, _stops = 0
        var failNext = false
        var lastTarget: AudioTapTarget?
        var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }
        var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
        func start(target: AudioTapTarget, sink: AudioSampleSink) throws -> AudioCaptureInfo {
            lock.lock(); defer { lock.unlock() }
            _starts += 1
            lastTarget = target
            if failNext { failNext = false; throw AudioCaptureError("заглушка: tap не создан") }
            sink.prepare(sampleRate: 48_000, channels: 2, interleaved: true)
            _running = true
            return AudioCaptureInfo(sampleRate: 48_000, displayDelay: 0, bufferFrames: 4096, plan: .global(excluding: []))
        }
        func stop() { lock.lock(); if _running { _stops += 1 }; _running = false; lock.unlock() }
    }

    @MainActor
    private static func controllerTests(check: Checker) {
        let feed = AudioLevelsFeed()
        let be = StubBackend()
        let c = LiveAudioController(feed: feed, backend: be)
        c.synchronous = true
        let view = NSObject()
        c.enabled = true
        c.playing = true
        c.target = AudioTapTarget(pid: 100, bundleId: "com.google.Chrome")
        check(c.state == .idle && !be.running, "Захват: без видимых полосок не создаётся (нет спроса)")
        feed.addSink(view) { _ in }
        check(c.state == .running && be.running && be.starts == 1, "Захват: играет + полоски видны → tap создан", "\(c.state)")

        let lv5: [Float] = [0.9, 0.5, 0.3, 0.2, 0.1]
        let w24 = [Float](repeating: 0.4, count: 24)
        c.deliver(c.currentGeneration, wide: w24, compact: [0, 0, 0, 0, 0], interval: 0.085, silentSeconds: 0.1, silent: true)
        check(!feed.isLive, "Захват: первые нули до звука не кладут полоски (остаётся псевдоанимация)")
        c.deliver(c.currentGeneration, wide: w24, compact: lv5, interval: 0.085, silentSeconds: 0, silent: false)
        check(feed.isLive && feed.compact == lv5, "Захват: уровни дошли до полосок")
        c.deliver(c.currentGeneration - 1, wide: w24, compact: [1, 1, 1, 1, 1], interval: 0.085, silentSeconds: 0, silent: false)
        check(feed.compact == lv5, "Захват: уровни старого поколения (после остановки) отброшены")

        c.playing = false
        check(c.state == .idle && !be.running && be.stops == 1 && !feed.isLive, "Захват: пауза → tap освобождён, псевдополоски")
        c.playing = true
        check(be.running && be.starts == 2, "Захват: снова играет → создан заново")
        c.asleep = true
        check(!be.running && c.state == .idle, "Захват: сон → освобождён")
        c.asleep = false
        check(be.running && be.starts == 3, "Захват: пробуждение → снова")
        c.target = AudioTapTarget(pid: 200, bundleId: "com.apple.Music")
        check(be.running && be.starts == 4 && be.stops == 3 && be.lastTarget?.bundleId == "com.apple.Music",
              "Захват: сменился плеер → tap пересоздан на него")
        c.outputDeviceChanged()
        check(be.running && be.starts == 5, "Захват: сменилось устройство вывода → агрегат пересоздан")
        feed.removeSink(view)
        check(!be.running && c.state == .idle, "Захват: полоски ушли с экрана (свернули/вкладка/движение ниже .full) → освобождён")
        feed.addSink(view) { _ in }
        check(be.running, "Захват: полоски вернулись → снова")

        // Нули дольше 4 с (нет права): освободить и не пересоздавать до нового трека.
        c.deliver(c.currentGeneration, wide: w24, compact: [0, 0, 0, 0, 0], interval: 0.085, silentSeconds: 4.2, silent: true)
        check(c.state == .silent && !be.running && !feed.isLive, "Захват: только нули 4 с → освобождён, псевдополоски")
        c.update()
        check(!be.running, "Захват: после «нулей» сам не пересоздаётся")
        c.resetFailure(); c.update()
        check(be.running, "Захват: новый трек → пробует снова")

        // Сбой создания: освободить остатки, псевдополоски, без повторов до следующего «играет».
        c.playing = false
        be.failNext = true
        let stopsBefore = be.stops
        c.playing = true
        if case .failed = c.state { check(true, "Захват: tap не создался → состояние «сбой»") } else {
            check(false, "Захват: tap не создался → состояние «сбой»", "\(c.state)")
        }
        check(!be.running && !feed.isLive && be.stops == stopsBefore, "Захват: после сбоя ничего не держим")
        let startsAfterFail = be.starts
        c.update(); c.update()
        check(!be.running && be.starts == startsAfterFail, "Захват: после сбоя не долбит повторами", "\(be.starts)")
        c.playing = false; c.playing = true
        check(be.running, "Захват: следующее «играет» — новая попытка")

        c.enabled = false
        check(!be.running && c.state == .idle, "Захват: выключили в настройках → освобождён")
        c.enabled = true
        c.target = nil
        check(!be.running, "Захват: ничего не играет (нет цели) → не создаётся")
        c.target = AudioTapTarget(pid: 1, bundleId: "x")
        check(be.running, "Захват: цель снова есть")
        c.stopNow()
        feed.removeSink(view)

        // Пауза в спросе (компакт → вкладка): не рвать сразу, а через stopGrace; вернулся — не пересоздавать.
        let feed2 = AudioLevelsFeed()
        let be2 = StubBackend()
        let c2 = LiveAudioController(feed: feed2, backend: be2)
        c2.stopGrace = 0.3
        c2.enabled = true; c2.playing = true; c2.target = AudioTapTarget(pid: 1, bundleId: "x")
        feed2.addSink(view) { _ in }
        _ = spinUntil(timeout: 2) { be2.running && c2.state == .running }
        feed2.removeSink(view)
        let stillRunning = be2.running
        feed2.addSink(view) { _ in }
        _ = spinUntil(timeout: 0.6) { false }
        check(stillRunning && be2.running && be2.starts == 1, "Захват: короткая потеря спроса (переход) — tap не пересоздаётся")
        feed2.removeSink(view)
        let released = spinUntil(timeout: 2) { !be2.running }
        check(released && c2.state == .idle, "Захват: спрос не вернулся за stopGrace → освобождён (с очереди захвата)")
        c2.playing = false
    }

    @MainActor
    static func spinUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    // MARK: Видео или музыка

    private static func videoTests(check: Checker) {
        typealias K = MediaKind
        check(K.isVideo(mediaType: "MRMediaRemoteMediaTypeVideo", bundleId: "com.example.app", album: "А"),
              "Видео: MediaRemote сказал Video")
        check(!K.isVideo(mediaType: "MRMediaRemoteMediaTypeMusic", bundleId: "com.google.Chrome", album: ""),
              "Музыка: MediaRemote сказал Music (даже в браузере без альбома)")
        check(!K.isVideo(mediaType: "", bundleId: MediaApps.music, album: "") && !K.isVideo(mediaType: "", bundleId: MediaApps.spotify, album: ""),
              "Музыка: Музыка и Spotify")
        check(K.isVideo(mediaType: "", bundleId: "com.colliderli.iina", album: "")
              && K.isVideo(mediaType: "", bundleId: "com.apple.QuickTimePlayerX", album: "")
              && K.isVideo(mediaType: "", bundleId: "com.apple.TV", album: ""),
              "Видео: IINA, QuickTime, TV")
        check(K.isVideo(mediaType: "", bundleId: "com.google.Chrome", album: "")
              && K.isVideo(mediaType: "", bundleId: "com.apple.Safari", album: " ")
              && K.isVideo(mediaType: "", bundleId: "company.thebrowser.Browser", album: ""),
              "Видео: браузер без альбома (YouTube)")
        check(!K.isVideo(mediaType: "", bundleId: "com.google.Chrome", album: "Тёплый асфальт"),
              "Музыка: браузер с альбомом (YouTube Music, Яндекс Музыка)")
        check(!K.isVideo(mediaType: "", bundleId: "com.example.podcasts", album: "") && !K.isVideo(mediaType: "", bundleId: nil, album: ""),
              "Музыка: незнакомое приложение / без bundle id")
        var n = NowPlaying(title: "Как устроен остров"); n.bundleId = "com.google.Chrome"; n.artist = "Канал"
        check(n.isVideo && !n.isMusicContent, "NowPlaying.isVideo: ролик в Chrome")

        // Ссылки YouTube.
        let id = "dQw4w9WgXcQ"
        let urls = ["https://www.youtube.com/watch?v=\(id)&t=42s", "https://youtu.be/\(id)?si=abc",
                    "https://www.youtube.com/shorts/\(id)", "https://music.youtube.com/watch?v=\(id)&list=RD",
                    "https://m.youtube.com/watch?feature=share&v=\(id)", "https://www.youtube.com/embed/\(id)",
                    "https://www.youtube.com/live/\(id)"]
        let parsed = urls.map { YouTube.videoId(from: $0) }
        check(parsed.allSatisfy { $0 == id }, "YouTube: id из watch?v=, youtu.be/, shorts/, music.youtube.com, m., embed/, live/",
              "\(parsed)")
        let bad = ["https://www.youtube.com/", "https://www.youtube.com/watch?v=short", "https://vimeo.com/watch?v=\(id)",
                   "https://notyoutube.com/watch?v=\(id)", "https://www.youtube.com/@channel", "не ссылка", ""]
        check(bad.allSatisfy { YouTube.videoId(from: $0) == nil }, "YouTube: чужие сайты, каналы, битые id — нет",
              "\(bad.map { YouTube.videoId(from: $0) ?? "-" })")
        check(YouTube.thumbnailURL(id).absoluteString == "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "YouTube: адрес превью")
        check(YouTube.videoId(inInfo: ["ContentItemIdentifier": "https://www.youtube.com/watch?v=\(id)", "Title": "x"]) == id
              && YouTube.videoId(inInfo: ["ContentItemIdentifier": "6F1A-UUID"]) == nil, "YouTube: id из метаданных MediaRemote")
        // Вкладка — по заголовку; без совпадения — не угадываем.
        let tabs = YouTube.parseTabs("https://www.youtube.com/watch?v=AAAAAAAAAAA\tДругое видео - YouTube\n"
                                     + "https://www.youtube.com/watch?v=\(id)\t(3) Как устроен остров - YouTube\n")
        check(tabs.count == 2 && YouTube.pickTab(tabs, nowTitle: "Как устроен остров") == id,
              "YouTube: вкладка найдена по заголовку («(3) … - YouTube»)")
        check(YouTube.pickTab(tabs, nowTitle: "Совсем другое") == nil, "YouTube: заголовок не совпал — превью не выдумываем")
        check(YouTube.tabsScript(bundleId: "com.apple.Safari")?.contains("name of t") == true
              && YouTube.tabsScript(bundleId: "com.google.Chrome")?.contains("title of t") == true
              && YouTube.tabsScript(bundleId: "org.mozilla.firefox") == nil, "YouTube: скрипт вкладок Safari/Chromium, Firefox — нет")
        // Выбор картинки.
        check(VideoCover.choose(hasArtwork: true, hasThumbnail: true) == .artwork
              && VideoCover.choose(hasArtwork: false, hasThumbnail: true) == .youTubeThumbnail
              && VideoCover.choose(hasArtwork: false, hasThumbnail: false) == .videoIcon,
              "Видео: обложка → превью YouTube → значок видео")
    }

    /// Модель: видео в Chrome без обложки → вкладка (заглушка) → одно скачивание превью (заглушка) → картинка.
    @MainActor
    static func videoThumbnailFlow(check: Checker) {
        let model = MediaModel()
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        let id = "dQw4w9WgXcQ"
        var fetched: [URL] = []
        var tabsAnswer: String? = nil
        model.browserTabsReader = { _ in tabsAnswer }
        let jpeg = coverJPEG(3, side: 480)
        model.thumbnailFetcher = { url in fetched.append(url); return jpeg }
        var n = NowPlaying(title: "Как устроен остров"); n.artist = "Канал"; n.bundleId = "com.google.Chrome"
        n.isPlaying = true; n.duration = 600
        // Права «Автоматизация» нет — вкладки не прочитаны: значок видео и просьба о доступе.
        model.simulateMediaRemote(n)
        _ = spinUntil(timeout: 2) { model.browserAccessNeeded != nil }
        check(model.browserAccessNeeded == "com.google.Chrome" && model.videoCover == .videoIcon && fetched.isEmpty,
              "Превью: без права на вкладки — значок видео, кнопка доступа, в сеть не ходим")
        // Право есть — вкладка найдена, превью скачано один раз.
        tabsAnswer = "https://www.youtube.com/watch?v=\(id)\tКак устроен остров - YouTube\n"
        Task { await model.lookupVideoThumbnail(trackKey: n.trackKey) }
        _ = spinUntil(timeout: 3) { model.videoThumbnail != nil }
        check(model.videoThumbnail != nil && model.videoCover == .youTubeThumbnail && model.coverImage != nil
              && fetched.map(\.absoluteString) == ["https://i.ytimg.com/vi/\(id)/hqdefault.jpg"],
              "Превью: вкладка по заголовку → i.ytimg.com, картинка в обложке", "\(fetched)")
        // Тот же ролик снова (пауза/игра) — без второго скачивания.
        var paused = n; paused.isPlaying = false
        model.simulateMediaRemote(paused)
        model.simulateMediaRemote(n)
        Task { await model.lookupVideoThumbnail(trackKey: n.trackKey) }
        _ = spinUntil(timeout: 0.5) { false }
        check(fetched.count == 1 && model.videoThumbnail != nil, "Превью: одно скачивание на ролик", "\(fetched.count)")
        // Музыка — превью не показываем (обложка или нота).
        var song = n; song.title = "Песня"; song.album = "Альбом"
        model.simulateMediaRemote(song)
        check(!song.isVideo && model.coverImage == nil && model.videoThumbnail == nil, "Превью: сменилось на музыку — сброшено")
        model.stop()
    }

    // MARK: Микробенч

    /// Время CPU потока на обработку звука (моно-сумма + БПФ + полосы), в пересчёте на 1 с звука 48 кГц стерео.
    private static func bench(check: Checker) {
        // «Музыка»: три синуса + шум, 10 с.
        let rate = 48_000.0, seconds = 10.0
        let n = Int(rate * seconds)
        var x = [Float](repeating: 0, count: n * 2)
        var seed: UInt32 = 12345
        for i in 0..<n {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.05
            let t = Double(i) / rate
            let v = Float(0.3 * sin(2 * .pi * 82 * t) + 0.2 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 3300 * t)) + noise
            x[2 * i] = v; x[2 * i + 1] = v * 0.9
        }
        func cpu() -> Double {
            var ts = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
        }
        for chunk in [4096, 512] {
            let sp = AudioSpectrum(sampleRate: rate)
            feed(sp, Array(x[0..<(Int(rate) * 2)]), chunk: chunk)   // прогрев
            let t0 = cpu()
            let analyses = feed(sp, x, chunk: chunk)
            let dt = cpu() - t0
            let perSecondMs = dt / seconds * 1000
            let percent = perSecondMs / 10   // мс за 1 с = % одного ядра × 10
            print(String(format: "info bench: буфер %d кадров — %.3f мс CPU на 1 с звука (%.3f %% ядра), %d расчётов за %.0f с",
                         chunk, perSecondMs, percent, analyses, seconds))
            check(percent < 0.2, "Микробенч (буфер \(chunk)): обработка ≪ 1 % ядра", String(format: "%.3f %%", percent))
        }
    }
}
