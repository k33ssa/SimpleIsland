import Foundation
import LyricsCore

/// Самотест текстов песен (часть `--selftest-media`): разбор LRC, сопоставление трека с записями LRCLIB, отказ при
/// чужом тексте, кеш, позиция и поправка на задержку вывода; движок LyricsCore — `LyricsCoreSelfTest`. `net` — прогон
/// по реальным трекам через каскад LyricsCore.
enum LyricsSelfTest {
    typealias Check = (Bool, String, String) -> Void

    static func run(_ check: Check) {
        lrc(check)
        matching(check)
        cache(check)
        cacheLimits(check)
        position(check)
        MainActor.assumeIsolated { musicAnchor(check) }
        LyricsCoreSelfTest.run(check)
        AppleMusicLoginSelfTest.run(check)
        DeezerLyricsSelfTest.run(check)
        YandexMusicSelfTest.run(check)
        MusixmatchSelfTest.run(check)
    }

    // MARK: LRC

    static func lrc(_ check: Check) {
        // offset стоит ниже первых строк — всё равно на весь текст; [мм:сс:хх]; пословные метки; пустая строка.
        let l = LRC.parse("""
        \u{FEFF}[ti:Песня]
        [00:01.00]раз
        [offset:-250]
        [00:03:50]два <00:03.60>слова <00:04.10>тут
        [00:05.00]
        [00:06.00][00:02.00]повтор
        [00:07.123]тысячные
        без метки
        """)
        check(l.map(\.text) == ["раз", "повтор", "два слова тут", "", "повтор", "тысячные"], "LRC: порядок, повторы, пословные метки",
              l.map(\.text).joined(separator: "|"))
        let times = l.map { ($0.time * 1000).rounded() / 1000 }
        check(times == [1.25, 2.25, 3.75, 5.25, 6.25, 7.373], "LRC: offset −250 мс на весь текст, [мм:сс:хх], тысячные",
              "\(times)")
        check(LRC.parseTime("01:02:03.5") == 3723.5 && LRC.parseTime("1:5") == 65 && LRC.parseTime("ar:x") == nil,
              "LRC: ч:мм:сс.хх и мусорные теги", "")
        let pl = LRC.plain("Первая\n\n[00:01.00]Вторая")
        let plain = Lyrics(lines: pl, synced: false)
        check(plain.plainExcerpt(5) == ["Первая", "Вторая"] && plain.index(at: 10) == nil && plain.nextChange(after: 0) == nil
              && plain.progress(of: 0, at: 1, duration: 10) == 0,
              "Простой текст: без строки «сейчас», без смены и заливки", "\(plain.plainExcerpt(5))")
        let s = Lyrics(lines: [LyricLine(time: 10, text: "a"), LyricLine(time: 12, text: "b")]).shifted(by: 0.2)
        check(s.index(at: 10.1) == nil && s.index(at: 10.2) == 0 && s.nextChange(after: 10.2) == 12.2,
              "Lyrics.shifted: строка начинается позже на задержку", "")
    }

    // MARK: Сопоставление

    static func matching(_ check: Check) {
        typealias C = LyricsMatch.Candidate
        func q(_ a: String, _ t: String, _ d: Double, album: String = "") -> LyricsService.Query {
            LyricsService.Query(artist: a, title: t, album: album, duration: d)
        }
        func ok(_ query: LyricsService.Query, _ c: C) -> Bool { LyricsMatch.evaluate(query, c).accepted }
        let lrc = "[00:01.00]x"

        let p = LyricsMatch.parseTitle("Bohemian Rhapsody - Remastered 2011")
        check(p.base == "bohemian rhapsody" && p.significant.isEmpty, "Название: « - Remastered 2011»", p.base)
        let f = LyricsMatch.parseTitle("Numb (feat. Jay-Z) [Explicit]")
        check(f.base == "numb" && f.featured == ["jay z"], "Название: (feat.) и [Explicit]", "\(f.base) \(f.featured)")
        let lv = LyricsMatch.parseTitle("Звезда по имени Солнце (Live)")
        check(lv.base == "звезда по имени солнце" && lv.significant == ["live"], "Название: (Live) — значимая пометка",
              "\(lv.significant)")
        let keep = LyricsMatch.parseTitle("(I Can't Get No) Satisfaction")
        check(keep.base == "i can t get no satisfaction", "Название: смысловые скобки остаются", keep.base)
        let tail = LyricsMatch.parseTitle("Song Title - Live at Wembley - 2011 Remaster")
        check(tail.base == "song title" && tail.significant == ["live"], "Название: два хвоста « - …»", tail.base)
        check(LyricsMatch.fold("Ёлка, ЁЖ & Co.") == "елка еж and co", "fold: регистр, ё/е, &, пунктуация",
              LyricsMatch.fold("Ёлка, ЁЖ & Co."))
        check(LyricsMatch.similarity(LyricsMatch.fold("Кино"), LyricsMatch.fold("Kino")) > 0.9,
              "Кириллица ~ латиница: Кино ~ Kino", "")
        check(LyricsMatch.splitArtists("Баста & Скриптонит feat. Lil Kate") == ["баста", "скриптонит", "lil kate"],
              "Исполнители: & и feat.", "\(LyricsMatch.splitArtists("Баста & Скриптонит feat. Lil Kate"))")

        // Реальные случаи (названия как в Музыке/Spotify против записей LRCLIB).
        check(ok(q("Queen", "Bohemian Rhapsody - Remastered 2011", 354.9),
                 C(title: "Bohemian Rhapsody", artist: "Queen", duration: 355, synced: lrc)),
              "Матч: ремастер ~ оригинал, длительность 354,9 ~ 355", "")
        check(ok(q("Кино", "Группа крови", 285.6), C(title: "Группа Крови", artist: "Кино", duration: 287, synced: lrc)),
              "Матч: регистр, ±1,4 с", "")
        check(ok(q("Кино", "Группа крови", 285.6), C(title: "Gruppa krovi", artist: "Kino", duration: 286, synced: lrc)),
              "Матч: транслит кириллица ~ латиница", "")
        check(ok(q("Linkin Park & JAY-Z", "Numb / Encore", 205),
                 C(title: "Numb/Encore", artist: "JAY-Z & Linkin Park", duration: 206, synced: lrc)),
              "Матч: дуэт в другом порядке", "")
        check(ok(q("Calvin Harris", "This Is What You Came For (feat. Rihanna)", 222),
                 C(title: "This Is What You Came For", artist: "Calvin Harris feat. Rihanna", duration: 222, synced: lrc)),
              "Матч: feat. в названии ~ feat. в артисте", "")
        check(ok(q("Земфира", "Хочешь?", 210), C(title: "Хочешь", artist: "Земфира", duration: 209, synced: lrc)),
              "Матч: пунктуация в названии", "")
        // Отказы.
        check(!ok(q("Кино", "Группа крови", 285.6), C(title: "Группа крови", artist: "Кино", duration: 240, synced: lrc)),
              "Отказ: другая запись (240 с вместо 286)", "")
        check(!ok(q("Кино", "Группа крови", 285.6), C(title: "Группа крови", artist: "Кино", duration: 288.9, synced: lrc)),
              "Отказ: длительность +3 с (допуск ±2)", "")
        check(!ok(q("Queen", "Bohemian Rhapsody", 355), C(title: "Bohemian Rhapsody", artist: "Panic! At The Disco", duration: 355, synced: lrc)),
              "Отказ: тот же трек, другой исполнитель (кавер)", "")
        check(!ok(q("Taylor Swift", "Love Story", 235), C(title: "Love", artist: "Taylor Swift", duration: 235, synced: lrc)),
              "Отказ: «Love» ≠ «Love Story»", "")
        check(!ok(q("Кино", "Звезда по имени Солнце", 225), C(title: "Звезда по имени Солнце (Live)", artist: "Кино", duration: 226, synced: lrc)),
              "Отказ: студийная ≠ Live", "")
        check(!ok(q("Земфира", "Искала", 239, album: "Четырнадцать недель тишины"),
                  C(title: "Искала", artist: "Земфира", album: "Маленький человек. Live", duration: 237, synced: lrc)),
              "Отказ: трек с концертного альбома при студийном", "")
        check(LyricsMatch.albumTags("Маленькии Человек\u{2024} Live (Disc 2)") == ["live"]
              && LyricsMatch.albumTags("MTV Unplugged") == ["live"] && LyricsMatch.albumTags("Live Through This").isEmpty
              && LyricsMatch.albumTags("Live at Wembley '86") == ["live"] && LyricsMatch.albumTags("Группа крови").isEmpty,
              "Альбом: концертный / студийный", "")
        check(!ok(q("Кино", "Кукушка", 0), C(title: "Кукушка (cover)", artist: "Полина Гагарина", duration: 0, synced: lrc)),
              "Отказ без длительности: кавер другого исполнителя", "")
        check(ok(q("Кино", "Кукушка", 0), C(title: "Кукушка", artist: "Кино", duration: 400, synced: lrc)),
              "Без длительности: точное совпадение артиста и названия — да", "")
        check(!ok(q("Кино", "Кукушка", 0), C(title: "Кукушка 2", artist: "Кино", duration: 400, synced: lrc)),
              "Без длительности: похожее название — нет (порог строже)", "")

        // Выбор кандидата: синхронный важнее простого; ближе по длительности; чужие — мимо.
        let query = q("Кино", "Группа крови", 285.6, album: "Группа крови")
        let cands = [
            C(id: 1, title: "Группа крови", artist: "Кино", album: "Последний герой", duration: 240, synced: lrc),
            C(id: 2, title: "Группа крови", artist: "Кино", album: "Группа крови", duration: 287, plain: "текст"),
            C(id: 3, title: "Группа крови", artist: "Кино", album: "Легенда", duration: 284, synced: lrc),
            C(id: 4, title: "Группа крови", artist: "Кино", album: "Группа крови", duration: 286, synced: lrc),
            C(id: 5, title: "Группа крови", artist: "Би-2", duration: 286, synced: lrc),
        ]
        check(LyricsMatch.best(query, cands)?.0.id == 4, "Выбор: синхронный, ближе по длительности, тот же альбом",
              "\(LyricsMatch.best(query, cands)?.0.id ?? -1)")
        check(LyricsMatch.best(query, [cands[1], cands[0]])?.0.id == 2, "Выбор: только простой текст — берём его", "")
        check(LyricsMatch.best(query, [cands[0], cands[4]]) == nil, "Выбор: ничего подходящего — без текста", "")
    }

    // MARK: Кеш

    static func cache(_ check: Check) {
        let a = LyricsService.Query(artist: "Кино", title: "Группа крови", album: "", duration: 285.6)
        var b = a; b.artist = "КИНО"; b.title = "Группа Крови"; b.album = "x"
        var c = a; c.duration = 240
        check(LyricsService.cacheKey(a) == LyricsService.cacheKey(b) && LyricsService.cacheKey(a) != LyricsService.cacheKey(c),
              "Кеш: ключ без регистра/альбома, с длительностью", "")
    }

    // Лимиты кеша на диске (LyricsCache с пределами, 15.11): 200 файлов, 5 МБ, 30 дней; «Очистить» — всё.
    static func cacheLimits(_ check: Check) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-prune-\(getpid())")
        defer { try? fm.removeItem(at: dir) }
        try? fm.removeItem(at: dir)
        let clock = ClockBox()
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken(), now: { clock.now })
        func json() -> [URL] { ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" } }
        func bytes() -> Int { json().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) } }
        func lyr(_ text: String, word: Bool = true) -> LyricsCore.Lyrics {
            var l = LyricsCoreSelfTest.mockLyrics(.lrclib, word: word)
            l.lines[0].text = text
            return l
        }
        var worst = 0
        for i in 0..<210 {
            svc.cache.store(key: "k\(i)", best: lyr("строка \(i)"), alternatives: [])
            worst = max(worst, json().count)
            usleep(1500)   // разные даты изменения: чистка убирает старые первыми
        }
        check(json().count <= LyricsService.maxEntries && worst <= LyricsService.maxEntries + 1
              && svc.cache.load(key: "k209") != nil && svc.cache.load(key: "k0") == nil,
              "Кеш текстов: не больше 200 записей — чистка сразу при превышении, старые первыми",
              "\(json().count) файлов, в пике \(worst)")
        let big = String(repeating: "я", count: 600_000)   // ~1,2 МБ в UTF-8
        for i in 0..<8 { svc.cache.store(key: "big\(i)", best: lyr(big + "\(i)"), alternatives: []); usleep(1500) }
        check(bytes() <= LyricsService.maxBytes && svc.cache.load(key: "big7") != nil,
              "Кеш текстов: не больше 5 МБ (последний большой — на месте)", "\(bytes() / 1024) КБ, \(json().count) файлов")
        svc.cache.store(key: "word", best: lyr("пословный"), alternatives: [])
        svc.cache.store(key: "none", best: nil, alternatives: [])
        clock.now = clock.now.addingTimeInterval(4 * 86400)
        let negGone = svc.cache.load(key: "none") == nil, wordKept = svc.cache.load(key: "word") != nil
        clock.now = clock.now.addingTimeInterval(27 * 86400)
        check(negGone && wordKept && svc.cache.load(key: "word") == nil,
              "Кеш текстов: «не найдено» живёт 3 дня, пословный — 30 дней", "\(negGone) \(wordKept)")
        let sem = DispatchSemaphore(value: 0)
        let box = IntBox()
        Task.detached { await svc.clearAll(); box.v = await svc.diskUsage(); sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        check(box.v == 0, "Кеш текстов: «Очистить кеш» — пусто", "\(box.v)")
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date()
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return t }
            set { lock.lock(); t = newValue; lock.unlock() }
        }
    }

    private final class IntBox: @unchecked Sendable { var v = -1 }

    // MARK: Позиция

    static func position(_ check: Check) {
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
        var n = NowPlaying(title: "t"); n.duration = 200; n.elapsed = 50; n.timestamp = t0; n.isPlaying = true; n.rate = 1
        check(abs(n.position(at: t0.addingTimeInterval(2.5)) - 52.5) < 1e-9, "Позиция: экстраполяция от timestamp", "")
        n.rate = 1.5
        check(abs(n.position(at: t0.addingTimeInterval(2)) - 53) < 1e-9, "Позиция: скорость ×1,5", "")
        n.isPlaying = false
        check(n.position(at: t0.addingTimeInterval(30)) == 50, "Позиция: на паузе стоит", "")
        n.isPlaying = true; n.rate = 1; n.elapsed = 120; n.timestamp = t0.addingTimeInterval(5)   // перемотка
        check(abs(n.position(at: t0.addingTimeInterval(6)) - 121) < 1e-9, "Позиция: после перемотки — от новой точки", "")
        // Метка времени из прошлого (обновление пришло с опозданием) — всё равно от неё, не от момента прихода.
        let lyr = Lyrics(lines: LRC.parse("[02:00.00]a\n[02:02.00]b\n[02:04.00]c"))
        check(lyr.index(at: n.position(at: t0.addingTimeInterval(7.1))) == 1, "Строка: смена ровно в момент метки LRC", "")
        // Задержка вывода: строка «b» (02:02) в ушах — позже на 0,2 с.
        let sh = lyr.shifted(by: LyricsSync.delay(bundleId: "com.spotify.client", outputLatency: 0.2))
        check(sh.index(at: 122.1) == 0 && sh.index(at: 122.21) == 1, "Задержка 0,2 с (Bluetooth): строка сменится позже", "")
        check(LyricsSync.delay(bundleId: "com.apple.Music", outputLatency: 0.2) == 0
              && LyricsSync.delay(bundleId: "com.spotify.client", outputLatency: 0.01) == 0
              && LyricsSync.delay(bundleId: nil, outputLatency: 9) == 3 && LyricsSync.delay(bundleId: nil, outputLatency: nil) == 0,
              "Задержка: Музыка сама учитывает, <30 мс — нет, >3 с — 3, неизвестно — 0", "")
        // Точность момента смены строки (±50 мс): расписание кадров раскрытого плеера (`PlaybackSchedule`) и таймер
        // компакта дают кадр в момент «метка LRC + задержка вывода − упреждение», при скорости ×1 и ×1,25.
        for (rate, lat, bundle) in [(1.0, 0.0, "com.apple.Music"), (1.0, 0.22, "com.spotify.client"), (1.25, 0.22, "com.spotify.client")] {
            var p = NowPlaying(title: "s"); p.duration = 200; p.elapsed = 118.3; p.timestamp = t0; p.isPlaying = true; p.rate = rate
            let off = LyricsSync.offset(bundleId: bundle, outputLatency: lat)
            let shown = lyr.shifted(by: off)
            let sch = PlaybackSchedule(now: p, lyrics: shown, bars: 92)
            // Ищем кадр, на котором строка сменилась на «b».
            var d = t0, frame: Date?
            for _ in 0..<2000 {
                guard let nx = sch.next(after: d) else { break }
                if shown.index(at: p.position(at: nx)) == 1 { frame = nx; break }
                d = nx
            }
            let want = t0.addingTimeInterval((122 + off - 118.3) / rate)
            let err = frame.map { $0.timeIntervalSince(want) } ?? 99
            check(abs(err) <= 0.05, String(format: "Смена строки: ±50 мс (×%.2f, задержка %.0f мс, %@)", rate, lat * 1000, bundle),
                  String(format: "ошибка %+.1f мс", err * 1000))
        }
        let progress = lyr.progress(of: 1, at: 123, duration: 200)
        check(abs(progress - 0.5) < 1e-9, "Заливка: по времени строки (середина строки — 50 %)", "\(progress)")
        if let lat = OutputDeviceWatcher.outputLatency() {
            print("info Задержка вывода сейчас: \(Int((lat * 1000).rounded())) мс")
        }
    }

    // MARK: Сеть

    /// Реальные треки через каскад LyricsCore (без Apple: токена у самотеста нет): какой источник ответил, есть ли
    /// пословная разметка, что отверг наш фильтр. Возвращает false, если сети нет.
    static func network(_ check: Check) -> Bool {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-net-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Индексы AMLL — там же, где у приложения (скачиваются не чаще раза в сутки), как после старта модуля.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let idx = base.appendingPathComponent("SimpleIsland/amll-index", isDirectory: true)
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken(), amllIndexDir: idx)
        do {
            let rss0 = residentMB()
            let t0 = Date()
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .background) { await svc.startup(amll: true); sem.signal() }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            let size = LyricsService.files(idx).reduce(0) { $0 + $1.1 }
            print(String(format: "info Индексы AMLL: %.1f с, %.1f МБ на диске, память процесса +%.0f МБ", Date().timeIntervalSince(t0),
                         Double(size) / 1_048_576, residentMB() - rss0))
        }
        typealias Q = LyricsService.Query
        // (запрос, ожидание: true — должен найтись синхронный, false — отказ, nil — как получится)
        let cases: [(Q, Bool?)] = [
            (Q(artist: "Queen", title: "Bohemian Rhapsody - Remastered 2011", album: "A Night at the Opera (2011 Remaster)", duration: 354.3), true),
            (Q(artist: "The Weeknd", title: "Blinding Lights", album: "After Hours", duration: 200.0), true),
            (Q(artist: "Dua Lipa", title: "Houdini", album: "", duration: 185.9), nil),
            (Q(artist: "Linkin Park", title: "Numb", album: "Meteora", duration: 185.6), true),
            (Q(artist: "Кино", title: "Группа крови", album: "Группа крови", duration: 285.4), true),
            (Q(artist: "Монеточка", title: "Каждый раз", album: "", duration: 0), nil),
            (Q(artist: "Земфира", title: "Искала", album: "Четырнадцать недель тишины", duration: 239.0), nil),
            (Q(artist: "Сплин", title: "Выхода нет", album: "Гранатовый альбом", duration: 236.0), nil),
            (Q(artist: "Несуществующая группа 4821", title: "Bohemian Rhapsody", album: "", duration: 355), false),
        ]
        var online = false
        var summary: [String] = []
        for (q, expect) in cases {
            let sem = DispatchSemaphore(value: 0)
            let box = Box()
            let t0 = Date()
            Task.detached { box.lookup = await svc.lookup(q); sem.signal() }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            let dt = Date().timeIntervalSince(t0)
            guard let r = box.lookup else { continue }
            let answered = r.outcomes.contains { !$0.contains("сбой") && !$0.contains("пропущен") }
            if !answered && r.lyrics == nil { print("skip «\(q.artist) — \(q.title)»: нет ответа ни от одного источника"); continue }
            online = true
            let kind: String
            if let l = r.lyrics {
                kind = (l.wordSynced ? "пословный" : l.synced ? "построчный" : "простой") + " \(l.lines.count) строк, \(l.source ?? "?")"
                    + (l.lines.contains { !$0.background.isEmpty } ? ", фон-вокал" : "")
            } else {
                kind = "нет текста"
            }
            let name = "Тексты «\(q.artist) — \(q.title)» \(Int(q.duration)) с: \(kind)"
            let detail = String(format: "%.1f с (первый текст %@)", dt, r.firstTextAfter.map { String(format: "%.2f с", $0) } ?? "—") + (r.rejected.isEmpty ? "" : "; отвергнуто фильтром: " + r.rejected.joined(separator: " | "))
            switch expect {
            case true?: check(r.lyrics?.synced == true, name, detail)
            case false?: check(r.lyrics == nil, name, detail)
            case nil: print("info " + name + " — " + detail)
            }
            for o in r.outcomes { print("       \(o)") }
            let first = r.firstTextAfter.map { String(format: "%.2f с", $0) } ?? "—"
            summary.append("| \(q.artist) — \(q.title) | \(r.provider?.title ?? "—") | \(r.lyrics?.wordSynced == true ? "да" : r.lyrics == nil ? "—" : "нет") | \(first) | \(String(format: "%.1f с", dt)) | \(r.upgrades) |")
        }
        if online { print("info Итог сети:\n| трек | источник | пословно | первый текст | весь поиск | замен |\n|---|---|---|---|---|---|\n" + summary.joined(separator: "\n")) }
        return online
    }

    private final class Box: @unchecked Sendable {
        var lookup: LyricsService.Lookup?
    }

    /// Резидентная память процесса, МБ.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}

extension LyricsSelfTest {
    /// Опора позиции Музыки (баг 16.11 «текст опаздывает на несколько секунд»): пара MediaRemote отставала от
    /// `player position` на 0,2–1,2 с и больше к концу трека; `player position` — ступеньки ~1,02 с, опора — момент ступеньки.
    @MainActor
    static func musicAnchor(_ check: Check) {
        let t = Date()
        typealias R = ScriptSource.PositionRead
        let a = R(pos: 41.0, mid: t, span: 0.01, title: "Песня"), b = R(pos: 42.024, mid: t.addingTimeInterval(0.06), span: 0.01, title: "Песня")
        let st = ScriptSource.step(prev: a, cur: b)
        check(st?.pos == 42.024 && abs((st?.at.timeIntervalSince(t) ?? 0) - 0.03) < 1e-6
              && ScriptSource.step(prev: a, cur: R(pos: 41.0, mid: b.mid, span: 0.01, title: "Песня")) == nil
              && ScriptSource.step(prev: a, cur: R(pos: 30.0, mid: b.mid, span: 0.01, title: "Песня")) == nil
              && ScriptSource.step(prev: a, cur: R(pos: 44.0, mid: b.mid, span: 0.01, title: "Песня")) == nil
              && ScriptSource.step(prev: a, cur: R(pos: 42.0, mid: b.mid, span: 0.01, title: "Другая")) == nil,
              "Позиция Музыки: ступенька player position — новое значение в середине между чтениями; перемотка/другой трек — нет",
              "\(String(describing: st))")
        // MediaRemote: «0 с в момент начала трека» (опоздал на 1,17 с); опора ступеньки свежее — позиция по ней.
        var mr = NowPlaying(title: "Песня"); mr.artist = "А"; mr.bundleId = MediaApps.music; mr.isPlaying = true; mr.rate = 1
        mr.elapsed = 0; mr.timestamp = t.addingTimeInterval(-60)
        let anchor = MediaModel.PositionAnchor(elapsed: 61.17, at: t.addingTimeInterval(-1), title: "Песня")
        let fixed = MediaModel.anchored(mr, anchor)
        check(abs(fixed.position(at: t) - 62.17) < 1e-6 && abs(mr.position(at: t) - 60) < 1e-6,
              "Позиция Музыки: свежая опора ступеньки заменяет отставшую пару MediaRemote (−1,17 с → 0)",
              String(format: "было %.2f, стало %.2f", mr.position(at: t), fixed.position(at: t)))
        var newer = mr; newer.elapsed = 10; newer.timestamp = t   // перемотка после опоры — у MediaRemote свежее
        var other = mr; other.title = "Другая"
        var paused = mr; paused.isPlaying = false
        let near = MediaModel.PositionAnchor(elapsed: 59.02, at: t.addingTimeInterval(-1), title: "Песня")   // 20 мс
        var spot = mr; spot.bundleId = MediaApps.spotify
        check(MediaModel.anchored(newer, anchor) == newer && MediaModel.anchored(other, anchor) == other
              && MediaModel.anchored(paused, anchor) == paused && MediaModel.anchored(mr, near) == mr
              && MediaModel.anchored(spot, anchor) == spot && MediaModel.anchored(mr, nil) == mr,
              "Позиция Музыки: опора не трогает перемотку свежее неё, другой трек, паузу, расхождение ≤ 40 мс, не Музыку", "")
    }

    /// Живая сверка позиции с Музыкой (`--selftest-media live`, Музыка играет): наша позиция (`NowPlaying.position`,
    /// то, по чему меняются строки) против `player position` в момент её ступеньки (`ScriptSource.samplePosition`,
    /// ±40 мс). Только чтение.
    @MainActor
    static func liveSync(model: MediaModel, check: Check, samples: Int = 6) {
        // MediaRemote мог показать другое приложение (Chrome на паузе) — тогда Музыка придёт через AppleScript.
        let wait = Date().addingTimeInterval(5)
        while Date() < wait && !(model.now?.isMusicApp == true && model.now?.isPlaying == true) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        if !(model.now?.isMusicApp == true) {
            let r = ScriptSource.run(ScriptSource.musicReadScript)
            print("info live: чтение Музыки AppleScript — ошибка \(r.errorNumber.map(String.init) ?? "нет"), "
                  + (r.descriptor.map { ScriptSource.parseList($0).prefix(6).joined(separator: " | ") } ?? "пусто"))
        }
        guard let n0 = model.now, n0.isMusicApp, n0.isPlaying else {
            print("skip live-сверка позиции: Музыка не играет (сейчас: \(model.now.map { "\($0.title) \($0.bundleId ?? "?") \($0.isPlaying) script=\($0.viaScript)" } ?? "нет"), доступ \(model.availability))"); return
        }
        // Одно чтение `player position` отстаёт на 0…1 с (ступеньки ~1,02 с) — сверяем в момент ступеньки.
        var deltas: [Double] = []
        let probe = ScriptSource()
        probe.start(apps: [MediaApps.music])
        defer { probe.stop() }
        for i in 0..<samples {
            var got: (Double, Date)? = nil
            var done = false
            probe.samplePosition(MediaApps.music, completion: { p, at, _ in got = (p, at); done = true }, failed: { done = true })
            let until = Date().addingTimeInterval(3)
            while !done && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            guard let (p, at) = got, let n = model.now, n.isPlaying, n.trackKey == n0.trackKey else { continue }
            let ours = n.position(at: at)
            let d = ours - p
            deltas.append(d)
            print(String(format: "info live-сверка %d: наша %.3f, Музыка %.3f, разница %+.0f мс (%@, опор %d)",
                         i + 1, ours, p, d * 1000, n.viaScript ? "AppleScript" : "MediaRemote", model.positionSamples))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        guard !deltas.isEmpty else { print("skip live-сверка: нет замеров"); return }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let worst = deltas.map(abs).max() ?? 0
        check(abs(mean) <= 0.1 && worst <= 0.25, "live: позиция совпадает с Музыкой (среднее ≤ 100 мс, худшее ≤ 250 мс)",
              String(format: "среднее %+.0f мс, худшее %.0f мс, замеров %d", mean * 1000, worst * 1000, deltas.count))
    }

    private final class SampleBox: @unchecked Sendable {
        var pos: Double?
        var mid: Date?
        var span: Double = 0
    }
}

/// Виджет «Эквалайзер»: регистрация (id, по умолчанию выключен, своя вкладка на модели «Медиа») и состояния.
enum EqualizerSelfTest {
    @MainActor
    static func run(_ check: LyricsSelfTest.Check) {
        let media = MediaIslandModule()
        let eq = media.equalizerModule
        check(eq.id == "equalizer" && eq.title == "Эквалайзер" && eq.providesTab && !eq.tabEnabledByDefault
              && eq.expandedView() != nil && (eq as? EqualizerIslandModule)?.model === media.model,
              "Эквалайзер: модуль equalizer, вкладка выключена по умолчанию, та же модель «Медиа»", "")
        check(eq.snapshotStates().map(\.name) == ["playing", "music-off", "music-permission", "spotify", "permission", "silence", "custom", "custom-editor", "manual", "manual-editor", "custom-editor-off"],
              "Эквалайзер: снимки", "\(eq.snapshotStates().map(\.name))")
        let m = media.model
        m.applyMock(nil, placeholder: nil, lyrics: nil)
        check(EqualizerState.of(m) == .silence, "Эквалайзер: ничего не играет — тишина", "")
        m.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
        m.mockAudioPermission(.notDetermined)
        check(EqualizerState.of(m) == .needsPermission, "Эквалайзер: нет права — кнопка «Разрешить»", "")
        m.mockAudioPermission(.granted)
        check(EqualizerState.of(m) == .live, "Эквалайзер: играет и право есть — по звуку", "")
        var p = m.prefs; p.liveVisualizer = false; m.prefs = p
        check(EqualizerState.of(m) == .off, "Эквалайзер: выключен в настройках — кнопка «Включить»", "")
        check(m.audioFeed.hasDemand == false, "Эквалайзер: без показа полосок спроса на захват нет", "")
        // 15.11: трек на паузе — «пауза», не «тишина»; играет, право есть, а из захвата одни нули — «нет доступа».
        p.liveVisualizer = true; m.prefs = p
        var paused = MediaMocks.track(playing: true); paused.isPlaying = false
        m.applyMock(paused, placeholder: .warm, lyrics: nil)
        check(EqualizerState.of(m) == .paused, "Эквалайзер: трек на паузе — «пауза», а не «тишина»", "")
        check(EqualizerState.of(hasTrack: true, playing: true, liveVisualizer: true, permission: .granted, silentTooLong: true) == .noSignal
              && EqualizerState.of(hasTrack: true, playing: true, liveVisualizer: true, permission: .denied, silentTooLong: true) == .needsPermission
              && EqualizerState.of(hasTrack: false, playing: false, liveVisualizer: true, permission: .granted, silentTooLong: true) == .silence,
              "Эквалайзер: играет, а звук не идёт — «Нет доступа к звуку» + «Разрешить»", "")
        check(!EqualizerSignalWatch.hasSignal(Array(repeating: 0, count: 24)) && EqualizerSignalWatch.hasSignal([0, 0.3, 0]),
              "Эквалайзер: нули из захвата — не сигнал", "")
        let rest = EqualizerState.restingLevels(count: 24)
        let rw = EqualizerState.restingBarWidth(height: 56, maxWidth: 16)
        check(rest.count == 24 && rest.allSatisfy { $0 * 56 >= rw * 2 } && Set(rest.map { Int($0 * 100) }).count > 3 && rw < 16,
              "Эквалайзер: полоски в покое — низкие столбики (выше ширины вдвое, разной высоты), не ряд овалов",
              "w=\(rw) min=\(rest.min() ?? 0)")

        // Эквалайзер «Музыки»: разбор ответа AppleScript, порядок сетки, выбор.
        let sep = MusicEqualizer.separator
        let parsed = MusicEqualizer.parse("true" + sep + "Rock" + sep + ["Acoustic", "Bass Booster", "Rock", "Manual", "", "Rock"].joined(separator: sep))
        check(parsed == .init(enabled: true, current: "Rock", presets: ["Acoustic", "Bass Booster", "Rock", "Manual"]),
              "Эквалайзер Музыки: разбор «вкл · текущий · пресеты» (пустые и повторы — прочь)", "\(String(describing: parsed))")
        check(MusicEqualizer.parse("false" + sep + "" + sep + "Pop")?.current == nil
              && MusicEqualizer.parse("false" + sep + "" + sep + "Pop")?.enabled == false,
              "Эквалайзер Музыки: выключен, текущего нет", "")
        check(MusicEqualizer.parse("") == nil && MusicEqualizer.parse("execution error") == nil,
              "Эквалайзер Музыки: мусор — nil", "")
        check(MusicEqualizer.parse("true" + sep + "Рок" + sep + "Рок" + sep + "Усилитель низких")?.presets == ["Рок", "Усилитель низких"],
              "Эквалайзер Музыки: русские названия пресетов", "")
        check(MusicEqualizer.gridOrder(["Manual", "Acoustic", "Rock"]) == ["Acoustic", "Rock", "Manual"], "Эквалайзер Музыки: «Manual» — в конце сетки", "")
        check(MusicEqualizer.quoted("R&B \"x\" \\") == "\"R&B \\\"x\\\" \\\\\"", "Эквалайзер Музыки: кавычки в названии экранируются",
              MusicEqualizer.quoted("R&B \"x\" \\"))
        check(MusicEqualizer.selectScript("Bass Booster").contains("set current EQ preset to EQ preset \"Bass Booster\"")
              && MusicEqualizer.selectScript("Bass Booster").contains("set EQ enabled to true")
              && MusicEqualizer.enableScript(false).hasSuffix("set EQ enabled to false"),
              "Эквалайзер Музыки: скрипты выбора и вкл/выкл", "")
        let me = MusicEqualizer()
        me.mock(.init(enabled: false, current: "Rock", presets: MusicEqualizer.mockPresets), access: .ready)
        check(!me.isSelected("Rock"), "Эквалайзер Музыки: выключен — пресет не подсвечен", "")
        me.select("Pop")
        check(me.isSelected("Pop") && !me.isSelected("Rock") && me.state?.enabled == true,
              "Эквалайзер Музыки: выбор пресета включает эквалайзер и подсвечивает кнопку", "")
        me.setEnabled(false)
        check(me.state?.enabled == false && !me.isSelected("Pop"), "Эквалайзер Музыки: «выкл»", "")
        check(EqualizerControls.of(m) == .music, "Эквалайзер: играет Музыка — управление её эквалайзером", "")
        var sp = MediaMocks.track(playing: true); sp.bundleId = MediaApps.spotify; sp.appName = "Spotify"
        m.applyMock(sp, placeholder: .warm, lyrics: nil)
        check(EqualizerControls.of(m) == .otherApp("Spotify"), "Эквалайзер: Spotify — «есть только у Музыки», только спектр", "")
        m.applyMock(nil, placeholder: nil, lyrics: nil)
        check(EqualizerControls.of(m) == .music, "Эквалайзер: ничего не играет — эквалайзер Музыки", "")
    }
}

/// Цепочка источников обложки: MediaRemote → (нет за 1 с) переспрос помощника и AppleScript → заглушка.
enum ArtworkChainSelfTest {
    @MainActor
    static func run(_ check: LyricsSelfTest.Check) {
        let model = MediaModel()
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        guard let jpeg = MediaSelfTest.coverJPEG(5, side: 300) else { check(false, "Обложка-цепочка: тестовая картинка", ""); return }
        // MediaRemote: Музыка играет, ArtworkData нет.
        var mr = NowPlaying(title: "Airplanes, Part II"); mr.artist = "B.o.B"; mr.album = "Adventures (Deluxe)"
        mr.bundleId = MediaApps.music; mr.isPlaying = true; mr.duration = 319
        model.simulateMediaRemote(mr)
        check(model.coverImage == nil && model.now?.artworkId == nil, "Обложка-цепочка: MediaRemote без картинки — пока пусто", "")
        // AppleScript того же трека (альбом записан иначе) принёс картинку.
        var sc = mr; sc.viaScript = true; sc.album = "B.o.B Presents: Adventures"; sc.artworkId = "script-1"
        model.ingestArtwork(id: "script-1", data: jpeg)
        model.simulateScript(sc)
        _ = spin(3) { model.coverImage != nil }
        check(model.now?.viaScript == false && model.now?.artworkId == "script-1" && model.coverImage != nil,
              "Обложка-цепочка: MediaRemote без обложки + AppleScript с обложкой → обложка AppleScript",
              "\(model.now?.artworkId ?? "нет")")
        // Пришла обложка MediaRemote — она главнее.
        var mr2 = mr; mr2.artworkId = "mr-1"
        model.ingestArtwork(id: "mr-1", data: MediaSelfTest.coverJPEG(7, side: 300) ?? jpeg)
        model.simulateMediaRemote(mr2)
        _ = spin(3) { model.shownArtworkIdForTest == "mr-1" }
        check(model.shownArtworkIdForTest == "mr-1", "Обложка-цепочка: своя обложка MediaRemote важнее", "")
        // Другой трек у AppleScript — чужую обложку не берём.
        var other = mr; other.title = "Другая песня"; other.artworkId = nil
        var scOld = sc; scOld.artworkId = "script-1"
        model.simulateScript(scOld)
        model.simulateMediaRemote(other)
        check(model.now?.artworkId == nil, "Обложка-цепочка: обложку другого трека не подставляем", "")
        // Нет нигде — переспрос через 1 с (и ещё раз), потом заглушка.
        let before = model.artworkRetries
        _ = spin(1.6) { model.artworkRetries > before }
        check(model.artworkRetries == before + 1, "Обложка-цепочка: нет за 1 с — переспросили источники", "\(model.artworkRetries - before)")
        _ = spin(2.5) { model.coverImage == nil && model.artworkRetries > before + 1 }
        check(model.coverImage == nil, "Обложка-цепочка: нет нигде — заглушка (прежняя снята)", "")
        model.stop()
        albumSequence(check)
    }

    /// Найдено вживую 16.11 (поток помощника, альбом SODA LUV подряд): на смене трека MediaRemote шлёт строку нового
    /// трека без ArtworkData, через ~1 с — с тем же id обложки, что у прошлого трека (тот же альбом — те же байты), а
    /// данные второй раз не шлёт. Раньше: nil → обложка снята, id без данных → нота до конца трека.
    @MainActor
    static func albumSequence(_ check: LyricsSelfTest.Check) {
        let model = MediaModel()
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        guard let jpeg = MediaSelfTest.coverJPEG(11, side: 300), let other = MediaSelfTest.coverJPEG(12, side: 300) else {
            check(false, "Обложка-альбом: тестовая картинка", ""); return
        }
        var t1 = NowPlaying(title: "DTF"); t1.artist = "Исполнитель"; t1.album = "Альбом 2 (DELUXE)"
        t1.bundleId = MediaApps.music; t1.isPlaying = true; t1.duration = 194; t1.artworkId = "X"
        model.ingestArtwork(id: "X", data: jpeg)          // помощник: обложка раньше строки
        model.simulateMediaRemote(t1)
        _ = spin(3) { model.shownArtworkIdForTest == "X" }
        check(model.shownArtworkIdForTest == "X", "Обложка-альбом: первый трек — обложка показана", "")
        // Строка нового трека без ArtworkData.
        var t2 = t1; t2.title = "CARPE DIEM"; t2.duration = 160; t2.artworkId = nil
        model.simulateMediaRemote(t2)
        check(model.coverImage != nil, "Обложка-альбом: новый трек того же альбома без id — прежняя держится", "")
        // Ждём дольше обычного удержания: даже если обложку сняли, вернуть её должен тот же id без новых данных.
        _ = spin(MediaModel.artworkAlbumHoldSeconds + 0.6) { false }
        var t2b = t2; t2b.artworkId = "X"
        model.simulateMediaRemote(t2b)                     // id тот же, данных помощник не шлёт
        check(model.coverImage != nil && model.shownArtworkIdForTest == "X",
              "Обложка-альбом: тот же id без повторных данных — обложка из кэша (раньше — нота)",
              "показана \(model.shownArtworkIdForTest ?? "нет")")
        // Сразу id (без строки без обложки) — тоже из кэша, без ожидания.
        var t3 = t2b; t3.title = "Третий"; t3.artworkId = "X"
        model.simulateMediaRemote(t3)
        check(model.shownArtworkIdForTest == "X" && model.coverImage != nil, "Обложка-альбом: следующий трек с тем же id — сразу", "")
        // Пауза/игра: MediaRemote отстал («пауза»), AppleScript того же трека «играет» без своей обложки → тот же трек,
        // обложку не снимаем.
        var mrPaused = t3; mrPaused.isPlaying = false
        var sc = t3; sc.viaScript = true; sc.artworkId = nil; sc.album = "Альбом 2"; sc.isPlaying = true
        model.simulateScript(sc)
        model.simulateMediaRemote(mrPaused)
        check(model.now?.viaScript == true && model.coverImage != nil,
              "Обложка-альбом: смена источника на AppleScript без обложки (тот же трек) — обложка остаётся", "")
        _ = spin(MediaModel.artworkAlbumHoldSeconds + 0.6) { false }
        check(model.coverImage != nil, "Обложка-альбом: …и не снимается по таймеру удержания", "")
        model.simulateMediaRemote(t3)
        model.simulateScript(nil)
        check(model.shownArtworkIdForTest == "X" && model.coverImage != nil, "Обложка-альбом: вернулись на MediaRemote — та же обложка", "")
        // MediaRemote назвал id, данных которого нет нигде, а у AppleScript того же трека картинка есть — берём её.
        var t4 = t3; t4.title = "Четвёртый"; t4.artworkId = "Y-нет-данных"
        var sc4 = t4; sc4.viaScript = true; sc4.artworkId = "script-4"
        model.ingestArtwork(id: "script-4", data: other)
        model.simulateScript(sc4)
        model.simulateMediaRemote(t4)
        _ = spin(3) { model.shownArtworkIdForTest == "script-4" }
        check(model.now?.artworkId == "script-4" && model.shownArtworkIdForTest == "script-4",
              "Обложка-альбом: id MediaRemote без данных → картинка AppleScript того же трека", "\(model.now?.artworkId ?? "нет")")
        // Дозапрос — с ограничением частоты.
        var t5 = t4; t5.title = "Пятый"; t5.artworkId = "Z-нет-данных"
        model.simulateScript(nil)
        let r0 = model.artworkRequests
        model.simulateMediaRemote(t5)
        let r1 = model.artworkRequests
        _ = model.requestArtwork("самотест")
        _ = model.requestArtwork("самотест")
        check(r1 == r0 + 1 && model.artworkRequests == r1, "Обложка-альбом: id без данных → один дозапрос, повторы чаще 1,5 с отсеяны",
              "\(r1 - r0), потом \(model.artworkRequests - r1)")
        model.stop()
    }

    @MainActor private static func spin(_ t: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }
}
