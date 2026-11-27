import AppKit
import Foundation
import ImageIO
import IslandCore
import SwiftUI

/// Самотест логики модуля без экрана и без прав: `SimpleIsland --selftest-media [net] [live]`.
/// Ничего не переключает в плеере пользователя: помощник MediaRemote запускается только в режимах probe/get (чтение).
/// `net` — дополнительно запрос в LRCLIB (известная песня) с кешем во временном каталоге.
public enum MediaSelfTest {
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        // Дочерний процесс для проверки «после выхода приложения детей нет» (запускает сам самотест).
        if arguments.first == "child" { return runChild() }
        if let i = arguments.firstIndex(of: "watch") {
            let sec = arguments.dropFirst(i + 1).first.flatMap(Double.init) ?? 120
            return watch(seconds: sec, sync: arguments.contains("sync"))
        }
        let check = Checker()

        // 1. LRC
        let lrc = LRC.parse("""
        [ar:Кто-то]
        [offset:+500]
        [00:10.00][00:30.00]припев
        [00:20.50]куплет
        [01:02:03.00]очень поздно
        не строка
        """)
        check(lrc.map(\.text) == ["припев", "куплет", "припев", "очень поздно"], "LRC: строки и повторные метки",
              lrc.map(\.text).joined(separator: "|"))
        check(abs(lrc[0].time - 9.5) < 0.001 && abs(lrc[1].time - 20.0) < 0.001, "LRC: offset 500 мс",
              "\(lrc[0].time) \(lrc[1].time)")
        check(abs(lrc[3].time - 3722.5) < 0.001, "LRC: часы", "\(lrc[3].time)")
        let l = Lyrics(lines: lrc)
        check(l.index(at: 5) == nil && l.index(at: 9.5) == 0 && l.index(at: 25) == 1 && l.index(at: 9999) == 3,
              "Lyrics.index")
        check(abs(l.progress(of: 0, at: 12.5, duration: 0) - 0.5) < 0.001, "Lyrics.progress (6 с максимум)",
              "\(l.progress(of: 0, at: 12.5, duration: 0))")
        check(l.nextChange(after: 10) == 20 && l.nextChange(after: 4000) == nil, "Lyrics.nextChange")

        // 1г. Виджет «Эквалайзер».
        EqualizerSelfTest.run { ok, name, detail in check(ok, name, detail) }

        // 1д. Медиаклавиши → последнему музыкальному приложению (заглушка вместо системы).
        MediaKeysSelfTest.run { ok, name, detail in check(ok, name, detail) }

        // 1в. Обложка: цепочка источников (MediaRemote → AppleScript → заглушка).
        ArtworkChainSelfTest.run { ok, name, detail in check(ok, name, detail) }

        // 1б. Тексты: LRC, сопоставление с LRCLIB, кеш, позиция и задержка вывода (`LyricsSelfTest`).
        LyricsSelfTest.run { ok, name, detail in check(ok, name, detail) }

        // 2. Позиция без опроса
        var n = NowPlaying(title: "t"); n.duration = 100; n.elapsed = 10; n.timestamp = Date(timeIntervalSinceNow: -5)
        n.isPlaying = true; n.rate = 2
        check(abs(n.position() - 20) < 0.2, "NowPlaying.position: играет ×2", "\(n.position())")
        n.isPlaying = false
        check(abs(n.position() - 10) < 0.001, "NowPlaying.position: пауза")
        n.isPlaying = true; n.elapsed = 99
        check(n.position() == 100, "NowPlaying.position: не дальше длительности")

        // 2в. «Прямой эфир» только для настоящих потоков (скрин 16.11: песня Музыки без Duration от MediaRemote).
        do {
            var mr = NowPlaying(title: "College"); mr.artist = "BenjiCold"; mr.bundleId = MediaApps.music
            mr.elapsed = 40; mr.isPlaying = true
            check(mr.timeline == .unknown && !mr.isLive, "эфир: песня Музыки без длительности — не эфир", "\(mr.timeline)")
            var sc = mr; sc.viaScript = true; sc.duration = 187
            let merged = MediaModel.mergeScript(mr, script: sc)
            check(merged.duration == 187 && merged.timeline == .timed && !merged.viaScript,
                  "эфир: длительность из AppleScript того же трека", "\(merged.duration)")
            var other = sc; other.title = "Другая"
            check(MediaModel.mergeScript(mr, script: other).duration == 0, "эфир: чужой трек AppleScript не подмешивается")
            var radio = sc; radio.duration = 0; radio.liveFlag = true
            check(MediaModel.mergeScript(mr, script: radio).isLive, "эфир: AppleScript «missing value» — поток")
            var flag = mr; flag.liveFlag = true
            check(flag.isLive, "эфир: MediaRemote IsAlwaysLive")
            var web = NowPlaying(title: "Радио"); web.bundleId = "com.google.Chrome"; web.elapsed = 300; web.isPlaying = true
            check(web.isLive, "эфир: браузер — позиция идёт без длительности")
            web.elapsed = 0
            check(web.timeline == .unknown, "эфир: браузер на нуле без длительности — ещё неизвестно")
            var timed = flag; timed.duration = 200
            check(timed.timeline == .timed, "эфир: длительность есть — обычный прогресс, даже с флагом")
        }

        // 2г. Скорость — одно правило (`MediaModel.speedSupported`).
        do {
            var song = NowPlaying(title: "s"); song.duration = 200; song.bundleId = MediaApps.music
            check(!MediaModel.speedSupported(song, rejected: []), "скорость: песня Музыки — нет")
            song.bundleId = MediaApps.spotify
            check(!MediaModel.speedSupported(song, rejected: []), "скорость: Spotify — нет")
            var pod = NowPlaying(title: "p"); pod.duration = 3600; pod.bundleId = "com.apple.podcasts"
            check(MediaModel.speedSupported(pod, rejected: []), "скорость: подкаст — есть")
            check(!MediaModel.speedSupported(pod, rejected: ["com.apple.podcasts"]), "скорость: не подтвердил — нет")
            var viaScript = pod; viaScript.viaScript = true
            check(!MediaModel.speedSupported(viaScript, rejected: []), "скорость: AppleScript — нет")
            var live = pod; live.duration = 0; live.elapsed = 50
            check(!MediaModel.speedSupported(live, rejected: []), "скорость: эфир — нет")
            var web = pod; web.bundleId = "com.google.Chrome"; web.mediaType = "MRMediaRemoteMediaTypeMusic"
            check(!MediaModel.speedSupported(web, rejected: []), "скорость: источник назвал музыкой — нет")
            web.mediaType = ""
            check(MediaModel.speedSupported(web, rejected: []), "скорость: видео в браузере — есть")
        }

        // 2д. Меню устройств вывода: с выходом, без своих агрегатов, текущее первым с галочкой.
        do {
            let all = [
                OutputDeviceEntry(id: 5, uid: "usb", name: "USB DAC", kind: .usb, outputChannels: 2, canBeDefault: true),
                OutputDeviceEntry(id: 2, uid: "BuiltIn", name: "Динамики MacBook Pro", kind: .builtIn, outputChannels: 2, canBeDefault: true),
                OutputDeviceEntry(id: 7, uid: "bt", name: "AirPods Pro", kind: .bluetooth, outputChannels: 2, canBeDefault: true),
                OutputDeviceEntry(id: 9, uid: "SimpleIsland.EQ.X", name: "SimpleIsland EQ", kind: .other, outputChannels: 2, canBeDefault: true),
                OutputDeviceEntry(id: 11, uid: "mic", name: "Микрофон", kind: .builtIn, outputChannels: 0, canBeDefault: true),
                OutputDeviceEntry(id: 12, uid: "hidden", name: "Скрытое", kind: .other, outputChannels: 2, canBeDefault: false),
                OutputDeviceEntry(id: 13, uid: "usb2", name: "USB DAC", kind: .usb, outputChannels: 2, canBeDefault: true),
            ]
            let m = OutputDeviceWatcher.menuItems(all, defaultID: 2)
            check(m.map(\.title) == ["Динамики MacBook Pro", "AirPods Pro", "USB DAC", "USB DAC (2)"],
                  "вывод: список устройств", m.map(\.title).joined(separator: "|"))
            check(m.filter(\.isCurrent).map(\.id) == [2], "вывод: галочка у текущего")
            check(m[0].systemImage == "laptopcomputer" && m[1].systemImage == "airpodspro" && m[2].systemImage == "hifispeaker",
                  "вывод: значки по типу", m.map(\.systemImage).joined(separator: " "))
            let real = OutputDeviceWatcher.menuItems(OutputDeviceWatcher.allDevices(),
                                                     defaultID: OutputDeviceWatcher.defaultOutputID())
            check(real.filter(\.isCurrent).count <= 1, "вывод: CoreAudio этой машины — не больше одной галочки",
                  real.map { ($0.isCurrent ? "✓" : "") + $0.title }.joined(separator: " | "))
        }

        // 2а. Вспышка «новый трек» — только по настройке и только на смену трека (политика уведомлений, UX 15.11).
        var t1 = NowPlaying(title: "Первый"); t1.artist = "А"; t1.isPlaying = true
        var t2 = NowPlaying(title: "Второй"); t2.artist = "А"; t2.isPlaying = true
        check(!MediaTrackFlash.shouldFlash(enabled: false, old: t1, new: t2, uptime: 60, tabVisible: false),
              "вспышка трека: по умолчанию выкл.")
        check(MediaPrefs().flashOnTrackChange == false, "вспышка трека: настройка по умолчанию выкл.")
        check(MediaTrackFlash.shouldFlash(enabled: true, old: t1, new: t2, uptime: 60, tabVisible: false),
              "вспышка трека: включена — на смену трека")
        check(!MediaTrackFlash.shouldFlash(enabled: true, old: nil, new: t2, uptime: 60, tabVisible: false)
              && !MediaTrackFlash.shouldFlash(enabled: true, old: t1, new: t1, uptime: 60, tabVisible: false),
              "вспышка трека: не на первое появление и не на тот же трек")
        var paused = t2; paused.isPlaying = false
        var untitled = t2; untitled.title = "  "
        check(!MediaTrackFlash.shouldFlash(enabled: true, old: t1, new: paused, uptime: 60, tabVisible: false)
              && !MediaTrackFlash.shouldFlash(enabled: true, old: t1, new: t2, uptime: 60, tabVisible: true)
              && !MediaTrackFlash.shouldFlash(enabled: true, old: t1, new: untitled, uptime: 60, tabVisible: false),
              "вспышка трека: не на паузе, не при открытой вкладке, не без названия")
        check(formatTime(108) == "1:48" && formatTime(3723) == "1:02:03", "formatTime")

        // 2б. Расписание перерисовок (`PlaybackSchedule`): кадр — ровно когда меняется видимое (время, «осталось»,
        // полоска волны, строка текста), между кадрами — ничего. Скорость ×2, дробная длительность 10,5 с.
        do {
            let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
            var p = NowPlaying(title: "s"); p.duration = 10.5; p.elapsed = 0; p.timestamp = t0; p.isPlaying = true; p.rate = 2
            let lyr = Lyrics(lines: LRC.parse("[00:05.25]раз\n[00:07.90]два"))
            let sch = PlaybackSchedule(now: p, lyrics: lyr, bars: 92)
            let step = 10.5 / 92
            func pos(_ d: Date) -> Double { min(10.5, d.timeIntervalSince(t0) * 2) }
            func visible(_ d: Date) -> String {
                let x = pos(d)
                return "\(formatTime(x))|\(formatTime(max(0, 10.5 - x).rounded(.up)))|\(Int((92 * x / 10.5).rounded()))|\(lyr.index(at: x) ?? -1)"
            }
            // первая граница — полоска волны на 0,5 шага: (0,5·step)/2 с часов
            let first = sch.next(after: t0).map { $0.timeIntervalSince(t0) } ?? -1
            check(abs(first - (0.5 * step / 2 + 0.002)) < 1e-6, "PlaybackSchedule: первая граница — полоска волны (×2)",
                  "\(first)")
            // pos 5,2 → ближайшее — строка текста 5,25 (раньше полоски 46,5·step = 5,307 и секунды 6)
            let afterLine = sch.next(after: t0.addingTimeInterval(2.6)).map { pos($0) } ?? -1
            check(abs(afterLine - 5.254) < 0.001, "PlaybackSchedule: начало строки текста", "\(afterLine)")
            // «осталось» с дробной длительностью (одна полоска — чтобы не мешала): pos 1,2 → 1,5 (−9 → −8), раньше 2
            let rem = PlaybackSchedule(now: p, lyrics: nil, bars: 1).next(after: t0.addingTimeInterval(0.6)).map { pos($0) } ?? -1
            check(abs(rem - 1.504) < 0.001, "PlaybackSchedule: граница «осталось» при дробной длительности", "\(rem)")
            // весь трек: между соседними кадрами видимое не меняется, на каждом кадре — меняется; конец — nil
            var dates: [Date] = []
            for d in sch.entries(from: t0, mode: .normal) { dates.append(d); if dates.count > 400 { break } }
            var silentOK = true, changeOK = true, monotonic = true
            for k in 1..<dates.count {
                monotonic = monotonic && dates[k] > dates[k - 1]
                let before = dates[k].addingTimeInterval(-0.003)
                if visible(dates[k - 1]) != visible(before) { silentOK = false }
                if pos(dates[k]) < 10.5, visible(dates[k]) == visible(dates[k - 1]) { changeOK = false }
            }
            check(monotonic && silentOK && dates.count < 140 && pos(dates.last ?? t0) >= 10.5 - 1e-9,
                  "PlaybackSchedule: весь трек — кадры по возрастанию, между ними видимое не меняется, конец трека — стоп",
                  "кадров \(dates.count), тишина \(silentOK)")
            check(changeOK, "PlaybackSchedule: на каждом кадре что-то видимое меняется (нет лишних кадров)")
            var live = p; live.duration = 0; live.liveFlag = true
            check(PlaybackSchedule(now: live, lyrics: nil, bars: 92).next(after: t0) == nil,
                  "PlaybackSchedule: прямой эфир без текста — ни одного кадра")
            // Длительность ещё неизвестна (не эфир): идут только секунды прошедшего времени.
            var unknown = p; unknown.duration = 0
            let un = PlaybackSchedule(now: unknown, lyrics: nil, bars: 92).next(after: t0)
            check(unknown.timeline == .unknown && un != nil && un!.timeIntervalSince(t0) <= 1.01,
                  "PlaybackSchedule: длительность неизвестна — тикает только время", "\(un.map { $0.timeIntervalSince(t0) } ?? -1)")
        }

        // 3. Волна
        let w1 = Waveform.bars(seed: "a|b|c", count: 92), w2 = Waveform.bars(seed: "a|b|c", count: 92)
        let w3 = Waveform.bars(seed: "x|y|z", count: 92)
        check(w1 == w2 && w1 != w3, "Waveform: детерминирована id трека")
        check(w1.allSatisfy { $0 >= 0.2 && $0 <= 1.0 }, "Waveform: высоты 0,2…1", "\(w1.min()!)…\(w1.max()!)")

        // 4. Цвета обложки: красный 50 %, синий 30 %, зелёный 20 %
        if let cg = stripes([(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1), 0.5),
                             (NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1), 0.3),
                             (NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1), 0.2)]) {
            let p = ArtworkPalette.dominantColors(of: cg)
            let desc = p.map { String(format: "(%.2f %.2f %.2f)", $0.r, $0.g, $0.b) }.joined(separator: " ")
            check(p.count == 3, "Palette: три цвета", desc)
            if p.count == 3 {
                check(p[0].r > 0.7 && p[0].g < 0.3, "Palette: первый — красный (больше всего)", desc)
                check(p.contains { $0.b > 0.7 && $0.r < 0.3 } && p.contains { $0.g > 0.6 && $0.r < 0.3 },
                      "Palette: синий и зелёный найдены", desc)
            }
        }
        if let cg = stripes([(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1), 1)]) {
            check(ArtworkPalette.dominantColors(of: cg).count == 3, "Palette: однотонная картинка → 3 оттенка")
        }
        if let img = MediaModel.renderPlaceholder(.warm), let cg = img.cgImageForPalette {
            let p = ArtworkPalette.dominantColors(of: cg)
            check(p.count == 3 && p.allSatisfy { $0.hsb.s > 0.3 }, "Palette: мок-обложка «тёплая» — насыщенные цвета",
                  p.map { String(format: "(%.2f %.2f %.2f)", $0.r, $0.g, $0.b) }.joined(separator: " "))
        }

        // 5. Протокол помощника
        let src = MediaRemoteSource()
        var got: MediaRemoteSource.State?
        var art: (String, Data)?
        src.onState = { got = $0 }
        src.onArtwork = { art = ($0, $1) }
        // Как в приложении: разбор и base64 — в `MediaRemoteSource.parse` (не на главном), применение — `handle`.
        var parsedBytes = false
        let reader = LineReader { line in
            if let obj = MediaRemoteSource.parse(String(decoding: line, as: UTF8.self)) {
                MainActor.assumeIsolated {
                    if obj["bytes"] is Data && obj["data"] == nil { parsedBytes = true }
                    src.handle(obj)
                }
            }
        }
        let jsonLine = #"{"type":"artwork","id":"abc","mime":"image/png","data":"AQID"}"# + "\n"
            + #"{"type":"now","playing":true,"pid":42,"bundle":"com.google.Chrome.helper","parentBundle":"com.google.Chrome","info":{"Title":" Песня ","Artist":"Кто","Album":"","Duration":200.5,"ElapsedTime":12,"PlaybackRate":1,"Timestamp":1794621683.0},"artworkId":"abc"}"# + "\n"
        let bytes = Data(jsonLine.utf8)
        // Кусками по 7 байт — как может прийти из трубы.
        stride(from: 0, to: bytes.count, by: 7).forEach { reader.feed(bytes[$0..<min(bytes.count, $0 + 7)]) }
        check(art?.0 == "abc" && art?.1 == Data([1, 2, 3]) && parsedBytes,
              "Протокол: обложка base64 декодируется при разборе (вне главного потока), не в handle")
        if let st = got, let np = MediaRemoteSource.nowPlaying(from: st, appName: "Chrome") {
            check(np.title == "Песня" && np.artist == "Кто" && np.duration == 200.5 && np.isPlaying
                  && np.bundleId == "com.google.Chrome" && np.artworkId == "abc"
                  && abs(np.timestamp.timeIntervalSince1970 - 1794621683) < 0.001,
                  "Протокол: строка now → NowPlaying (родительское приложение, обрезка пробелов)")
        } else {
            check(false, "Протокол: строка now разобрана")
        }
        let empty = MediaRemoteSource.State(playing: false, pid: 0, bundle: nil, parentBundle: nil, info: [:], artworkId: nil)
        check(MediaRemoteSource.nowPlaying(from: empty, appName: nil) == nil, "Протокол: пустой info → ничего не играет")

        // 6. Настройки: старый/неполный JSON не ломает остальное
        let prefs = try? JSONDecoder().decode(MediaPrefs.self, from: Data(#"{"source":"spotify","unknown":1}"#.utf8))
        check(prefs?.source == .spotify && prefs?.lyricsEnabled == true && prefs?.compactLyrics == false,
              "MediaPrefs: неполный JSON")
        let bad = try? JSONDecoder().decode(MediaPrefs.self, from: Data(#"{"source":"plasma"}"#.utf8))
        check(bad?.source == .auto, "MediaPrefs: неизвестный источник → «Авто»")

        // 7. Ключ кеша текста
        let q = LyricsService.Query(artist: "Queen", title: "Bohemian Rhapsody", album: "", duration: 355.2)
        let q2 = LyricsService.Query(artist: "QUEEN", title: "bohemian rhapsody", album: "x", duration: 354.9)
        check(LyricsService.cacheKey(q) == LyricsService.cacheKey(q2), "Lyrics: ключ кеша без регистра/альбома")

        // 7б. Что уходит в LRCLIB: только музыка, браузер — по отдельной настройке
        var chrome = NowPlaying(title: "Видео"); chrome.artist = "Канал"; chrome.bundleId = "com.google.Chrome"
        var musicType = chrome; musicType.mediaType = "MRMediaRemoteMediaTypeMusic"
        var spotify = chrome; spotify.bundleId = MediaApps.spotify
        check(!chrome.isMusicContent && musicType.isMusicContent && spotify.isMusicContent,
              "Lyrics: браузер без MediaType — не песня; Spotify и MediaType=Music — песня")
        let oldPrefs = try? JSONDecoder().decode(MediaPrefs.self, from: Data(#"{"lyricsEnabled":true}"#.utf8))
        check(oldPrefs?.lyricsAnyApp == false, "MediaPrefs: текст для браузеров по умолчанию выключен")

        // 7в. Обложка 16:9 не вылезает за квадрат 148 pt (ревью: вылезала на ~57 pt влево)
        if let wide = Self.wideImage() {
            let view = ZStack { CoverView(image: wide, placeholder: nil, size: 148, radius: 22, shadow: nil, appBadge: nil) }
                .frame(width: 400, height: 200)
            let r = ImageRenderer(content: view); r.scale = 1
            if let cg = r.cgImage {
                let outside = Self.alphaAt(cg, x: 400 / 2 - 74 - 8, y: 100) + Self.alphaAt(cg, x: 400 / 2 + 74 + 8, y: 100)
                let inside = Self.alphaAt(cg, x: 200, y: 100)
                check(outside == 0 && inside > 200, "Обложка 16:9 обрезана по квадрату", "снаружи \(outside), внутри \(inside)")
            } else {
                check(false, "Обложка 16:9: рендер")
            }
        }

        // 7г. AppleScript — всегда в одном и том же потоке
        let tsem = DispatchSemaphore(value: 0)
        let threads = ThreadIds()
        let st = ScriptThread(name: "selftest.applescript")
        for _ in 0..<5 { st.async { threads.add(Thread.current); tsem.signal() } }
        for _ in 0..<5 { _ = tsem.wait(timeout: .now() + 2) }
        check(threads.count == 5 && threads.unique == 1 && !threads.sawMain, "ScriptThread: все блоки в одном потоке (не главном)",
              "\(threads.count) блоков, потоков \(threads.unique)")

        // 8. Системное (только чтение)
        let dev = OutputDeviceWatcher.current()
        check(dev != nil, "CoreAudio: устройство вывода", dev.map { "\($0.name) \($0.kind)" } ?? "нет")
        let ae = ScriptSource.automationStatus(MediaApps.music, ask: false)
        print("info Автоматизация → Музыка: \(ae) (0 — разрешено, -1743 — запрещено, -1744 — не спрашивали, -600 — не запущена)")

        // 9. Помощник MediaRemote: probe + get (чтение, без команд)
        if let dylib = MediaRemoteSource.locateDylib() {
            let probe = runHelper(dylib: dylib, mode: "probe")
            check(probe?["type"] as? String == "probe" && probe?["info"] as? Bool == true,
                  "Помощник: probe (dylib загружена в /usr/bin/perl, MediaRemote найден)", "\(probe ?? [:])")
            let get = runHelper(dylib: dylib, mode: "get")
            check(get?["type"] as? String == "now", "Помощник: get отвечает строкой now")
            if let g = get {
                let st = MediaRemoteSource.State(playing: g["playing"] as? Bool ?? false, pid: Int32((g["pid"] as? Int) ?? 0),
                                                 bundle: g["bundle"] as? String, parentBundle: g["parentBundle"] as? String,
                                                 info: g["info"] as? [String: Any] ?? [:], artworkId: g["artworkId"] as? String)
                let np = MediaRemoteSource.nowPlaying(from: st, appName: appDisplayName(bundleId: st.bundle, pid: st.pid))
                print("info Сейчас: " + (np.map { "«\($0.title)» — \($0.artist), \($0.appName ?? $0.bundleId ?? "?"), "
                    + "\($0.isPlaying ? "играет" : "пауза"), \(formatTime($0.position()))/\(formatTime($0.duration))" }
                    ?? "ничего не играет"))
            }
            helperThumbTests(check: check, dylib: dylib)
        } else {
            print("skip Помощник: нет SimpleIslandMR.dylib (scripts/build-media-helper.sh)")
        }
        longLineTest(check: check)

        // 10. LRCLIB (по флагу net): кеш во временном каталоге
        if arguments.contains("net") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-test-\(getpid())")
            let svc = LyricsService(cacheDir: dir)
            let sem = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task.detached {
                box.value = await svc.lyrics(for: q)
                box.cached = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            if let lyr = box.value {
                check(lyr.lines.count > 20, "LRCLIB: синхронный текст получен", "\(lyr.lines.count) строк")
                check(box.cached == 1, "LRCLIB: записан кеш на диск")
            } else {
                print("skip LRCLIB: нет ответа (офлайн?) — плеер в этом случае просто без строки текста")
            }
            try? FileManager.default.removeItem(at: dir)
        }
        if arguments.contains("net") {
            if !LyricsSelfTest.network({ ok, name, detail in check(ok, name, detail) }) {
                print("skip LRCLIB: реальные треки — нет сети")
            }
            if !DeezerLyricsSelfTest.network({ ok, name, detail in check(ok, name, detail) }) {
                print("skip Deezer: нет ответа (офлайн или пауза после отказа)")
            }
            if !YandexMusicSelfTest.network({ ok, name, detail in check(ok, name, detail) }) {
                print("skip Яндекс Музыка: нет ответа (офлайн или пауза после отказа)")
            }
            if !MusixmatchSelfTest.network({ ok, name, detail in check(ok, name, detail) }) {
                print("skip Musixmatch: пропущено — нет ответа (офлайн, captcha или пауза после отказа)")
            }
        }

        // 11. Живой прогон модели (по флагу live): помощник MediaRemote в режиме stream, только чтение.
        if arguments.contains("live") {
            let ctx = ModuleContext(moduleId: "media", settings: SimpleIslandSettings(inMemory: SettingsData()),
                                    themes: ThemeStore(load: false), activities: ActivityCenter(), hud: HUDCenter(),
                                    notifications: IslandNotifications(), island: IslandStateCenter(),
                                    isSnapshot: false, openTab: { _ in })
            let model = MediaModel()
            // Свой кеш: живой прогон не должен писать отметки «не найдено» в настоящий кеш приложения.
            let liveCache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-live-\(getpid())")
            model.lyricsService = LyricsService(cacheDir: liveCache)
            defer { try? FileManager.default.removeItem(at: liveCache) }
            model.start(context: ctx)
            var liveGroups: [pid_t] = []
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && (model.now == nil || (model.now?.artworkId != nil && model.artwork == nil)
                                        || (model.prefs.lyricsEnabled && model.lyrics == nil && Date() < deadline.addingTimeInterval(-3))) {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            liveGroups = model.helperPID.map { [$0] } ?? []
            if let n = model.now {
                print("info live: «\(n.title)» — \(n.artist) [\(n.appName ?? n.bundleId ?? "?")] "
                      + "\(n.isPlaying ? "играет" : "пауза") \(formatTime(n.position()))/\(formatTime(n.duration)), "
                      + "обложка \(model.artwork.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "нет"), "
                      + "цветов \(model.palette.count), текст \(model.lyrics.map { "\($0.lines.count) строк" } ?? "нет")")
                check(ctx.activities.activities.contains { $0.id == MediaModel.activityId }, "live: компакт-активность повешена")
                check(model.artwork == nil || ctx.activities.ambientGlows["media"]?.count == 3, "live: свечение из 3 цветов обложки")
                LyricsSelfTest.liveSync(model: model, check: { ok, name, detail in check(ok, name, detail) })
            } else {
                print("info live: ничего не играет (\(model.availability))")
            }
            model.stop()
            check(ctx.activities.activities.isEmpty && ctx.activities.ambientGlows["media"] == nil,
                  "live: stop() снял активность и свечение")
            if let dylib = MediaRemoteSource.locateDylib() { helperArtworkResendTest(check: check, dylib: dylib) }
            let left = waitGone(liveGroups, timeout: 3)
            check(left.isEmpty, "live: помощник завершён после stop()", "\(left)")
        }

        // 12. Помощник на ManagedProcess: перезапуск, выход приложения (SIGTERM / kill -9), сон и пробуждение.
        let pidDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-media-pids-\(getpid())")
        try? FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)
        ManagedProcess.pidDirectory = pidDir   // pid-файлы детей — не в каталог настоящего приложения
        defer { try? FileManager.default.removeItem(at: pidDir) }
        if MediaRemoteSource.locateDylib() != nil {
            helperProcessTests(check: check)
            helperEdgeTests(check: check)
            exitTests(check: check, pidDir: pidDir)
            wakeTests(check: check)
        } else {
            print("skip Помощник/выход/пробуждение: нет SimpleIslandMR.dylib (scripts/build-media-helper.sh)")
        }

        // 13. Обложки: ImageDownsampler, кэш с лимитом, цвета вне главного потока, 200 смен трека — память.
        artworkMemoryTest(check: check, changes: 200)

        // 14. «Далее»: разбор ответа Музыки и показ только для текущего трека.
        nextTrackTests(check: check)

        // 14a. Обложка прошлого трека не держится дольше секунды; канал фона «Хамелеона» — только обложка.
        artworkHoldTests(check: check)

        // 14b. Эквалайзер по настоящему звуку, видео/музыка, превью YouTube, микробенч (без захвата и сети).
        liveAudioTests(check: check)

        // 15. Фон «Хамелеона»: тема просит фон из обложки, у obsidian — нет.
        let chamURL = SimpleIslandPaths.repoThemes?.appendingPathComponent("chameleon.json")
        if let chamURL, let data = try? Data(contentsOf: chamURL), let cham = try? Theme.decode(data) {
            check(cham.background.source == .artwork, "Хамелеон: background.source = artwork (ядро красит фон обложкой)")
        } else {
            print("skip Хамелеон: не найден design/themes/chameleon.json (ни в текущем каталоге, ни выше бинарника)")
        }
        check(Theme.obsidian.background.source == .theme, "obsidian: фон темы, не из обложки")
        if let t = try? Theme.decode(Data(#"{"id":"x","background":{"source":"plasma"}}"#.utf8)) {
            check(t.background.source == .theme && t.background.type == Theme.obsidian.background.type,
                  "Тема: неизвестный background.source → theme, остальное — из obsidian")
        }

        let failures = check.failures
        print(failures == 0 ? "MEDIA SELFTEST: OK" : "MEDIA SELFTEST: \(failures) FAIL")
        return failures == 0 ? 0 : 1
    }

    /// Проверка: печатает «ok/FAIL», считает провалы.
    final class Checker {
        private(set) var failures = 0
        func callAsFunction(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            print((ok ? "ok   " : "FAIL ") + name + (detail().isEmpty ? "" : " — " + detail()))
            if !ok { failures += 1 }
        }
    }

    private final class ThreadIds: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [ObjectIdentifier] = []
        private(set) var sawMain = false
        func add(_ t: Thread) { lock.lock(); ids.append(ObjectIdentifier(t)); if t.isMainThread { sawMain = true }; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
        var unique: Int { lock.lock(); defer { lock.unlock() }; return Set(ids).count }
    }

    /// Картинка 16:9 (как обложка YouTube из Chrome).
    @MainActor private static func wideImage() -> NSImage? {
        let w = 320, h = 180
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Альфа пикселя (0…255), y — сверху.
    private static func alphaAt(_ cg: CGImage, x: Int, y: Int) -> Int {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return Int(p[3])
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Lyrics?
        var cached = 0
    }

    /// Картинка из горизонтальных полос заданной доли.
    private static func stripes(_ parts: [(NSColor, Double)]) -> CGImage? {
        let w = 64, h = 64
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = 0.0
        for (c, frac) in parts {
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: Double(w), height: Double(h) * frac))
            y += Double(h) * frac
        }
        return ctx.makeImage()
    }

    /// Один запуск помощника в режиме чтения (через ManagedProcess), первая строка JSON.
    @MainActor
    private static func runHelper(dylib: URL, mode: String, env extra: [String: String] = [:]) -> [String: Any]? {
        var env = MediaRemoteSource.helperEnvironment(mode: mode)
        env.merge(extra) { $1 }
        let p = ManagedProcess(executable: "/usr/bin/perl", arguments: ["-e", MediaRemoteSource.perlScript, dylib.path],
                               environment: env, restart: .never)
        p.maxLineBytes = 32 << 20
        var first: String?
        var exited = false
        p.onLine = { if first == nil { first = $0 } }
        p.onExit = { _ in exited = true }
        guard p.start() else { return nil }
        let deadline = Date().addingTimeInterval(6)
        while !exited && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        if !exited { p.stop(grace: 0.5) }
        guard let line = first else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// `--selftest-media watch [сек]`: живая модель (помощник MediaRemote + AppleScript, только чтение) без острова,
    /// журнал обложек (`ArtworkLog`) — в stdout; раз в 5 с — что показано. Ничего не переключает в плеере.
    @MainActor
    static func watch(seconds: Double, sync: Bool = false) -> Int32 {
        ArtworkLog.echo = true
        let ctx = ModuleContext(moduleId: "media", settings: SimpleIslandSettings(inMemory: SettingsData()),
                                themes: ThemeStore(load: false), activities: ActivityCenter(), hud: HUDCenter(),
                                notifications: IslandNotifications(), island: IslandStateCenter(),
                                isSnapshot: false, openTab: { _ in })
        let model = MediaModel()
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false; prefs.liveVisualizer = false
        ctx.saveSettings(prefs)   // `start` читает настройки из контекста: без захвата звука и запроса прав
        model.start(context: ctx)
        setvbuf(stdout, nil, _IOLBF, 0)
        let end = Date().addingTimeInterval(seconds)
        var nextPrint = Date()
        var nextSync = Date().addingTimeInterval(1)
        var probing = false
        let probe = ScriptSource()
        if sync { probe.start(apps: [MediaApps.music]) }
        defer { probe.stop() }
        var placeholderSince: Date?
        var worst: TimeInterval = 0
        while Date() < end {
            // Весь цикл за 50 мс, а не «один источник + сон»: так главная очередь копила хвост и модель отставала на минуту.
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            let n = model.now
            let missing = n != nil && !(n!.isVideo) && model.artwork == nil
            if missing { placeholderSince = placeholderSince ?? Date() } else if let p = placeholderSince {
                worst = max(worst, Date().timeIntervalSince(p)); placeholderSince = nil
            }
            if sync, Date() >= nextSync, model.now != nil, !probing {
                // Сверка (только чтение): ступенька `player position` Музыки (±40 мс) против нашей позиции в тот момент.
                nextSync = Date().addingTimeInterval(3)
                probing = true
                probe.samplePosition(MediaApps.music, completion: { pos, at, title in
                    probing = false
                    guard let n = model.now, n.isMusicApp else { return }
                    let lat = OutputDeviceWatcher.outputLatency()
                    let off = LyricsSync.offset(bundleId: n.bundleId, outputLatency: lat)
                    print(String(format: "sync: «%@» наша %.3f Музыка %.3f разница %+.0f мс via %@ метка %.1f с назад, опор %d (отказ %d), задержка вывода %@ сдвиг текста %+.0f мс",
                                 title, n.position(at: at), pos, (n.position(at: at) - pos) * 1000,
                                 n.viaScript ? "applescript" : "mediaremote", Date().timeIntervalSince(n.timestamp),
                                 model.positionSamples, model.positionSamplesRejected,
                                 lat.map { String(format: "%.0f мс", $0 * 1000) } ?? "нет", off * 1000))
                }, failed: { probing = false })
            }
            if Date() >= nextPrint {
                nextPrint = Date().addingTimeInterval(5)
                print("watch: «\(n?.title ?? "—")» \(n?.isPlaying == true ? "играет" : "пауза") via \(n?.viaScript == true ? "applescript" : "mediaremote") "
                      + "id \(n?.artworkId ?? "нет") показана \(model.shownArtworkIdForTest ?? "нет") обложка \(model.artwork != nil ? "есть" : "НЕТ")")
            }
        }
        if let p = placeholderSince { worst = max(worst, Date().timeIntervalSince(p)) }
        print("watch: дольше всего без обложки при треке — \(String(format: "%.1f", worst)) с, дозапросов \(model.artworkRequests)")
        model.stop()
        return 0
    }

    final class PosBox: @unchecked Sendable { var pos: Double?; var mid: Date?; var span: TimeInterval = 0 }

    /// Помощник: команда `artwork` пересылает данные обложки того же id (живой MediaRemote, только чтение).
    @MainActor
    private static func helperArtworkResendTest(check: Checker, dylib: URL) {
        let p = ManagedProcess(executable: "/usr/bin/perl", arguments: ["-e", MediaRemoteSource.perlScript, dylib.path],
                               environment: MediaRemoteSource.helperEnvironment(mode: "stream"), restart: .never)
        p.maxLineBytes = 32 << 20
        p.providesStdin = true   // без трубы stdin помощник видит EOF и сразу выходит
        var arts: [String] = []
        var lineId: String?
        p.onLine = { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            if o["type"] as? String == "artwork", let id = o["id"] as? String { arts.append(id) }
            if o["type"] as? String == "now", lineId == nil { lineId = (o["artworkId"] as? String) ?? "" }
        }
        guard p.start() else { check(false, "live: помощник stream запущен"); return }
        defer { p.stop(grace: 0.5) }
        _ = spinCF(until: { lineId != nil }, timeout: 4)
        guard let id = lineId, !id.isEmpty, arts.contains(id) else {
            print("skip live: команда artwork — сейчас у MediaRemote нет обложки (\(lineId ?? "нет строки"))")
            return
        }
        let before = arts.count
        _ = p.send("refresh")
        _ = spinCF(until: { false }, timeout: 0.6)
        check(arts.count == before, "live: refresh не пересылает ту же обложку (данные — раз на id)", "\(arts.count - before)")
        _ = p.send("artwork")
        _ = spinCF(until: { arts.count > before }, timeout: 3)
        check(arts.count > before && arts.last == id, "live: команда artwork пересылает обложку того же id", "\(arts.suffix(2))")
    }

    /// Ожидание без `RunLoop.run(until:)` (CLAUDE.md «Грабли»: висел в mach_msg).
    @MainActor
    static func spinCF(until cond: () -> Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        return cond()
    }

    // MARK: Процессы

    /// Живые процессы группы `g` (proc_listpids, без внешних утилит).
    static func groupMembers(_ g: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = buf.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(g), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Процесс есть (не зомби: `proc_pidinfo` у зомби не отдаёт bsdinfo с живым статусом — проверяем kill и группу).
    static func alive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Подождать, пока группы (и их ведущие) исчезнут; вернуть оставшиеся pid.
    @MainActor
    static func waitGone(_ groups: [pid_t], timeout: TimeInterval) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        func left() -> [pid_t] { groups.flatMap { g in groupMembers(g) + (alive(g) ? [g] : []) } }
        let tick = keepAwake()
        defer { tick.cancel() }
        while !left().isEmpty && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return Array(Set(left())).sorted()
    }

    @MainActor
    private static func spin(until cond: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let tick = keepAwake()
        defer { tick.cancel() }
        while !cond() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return cond()
    }

    /// Будильник главного потока на время ожидания: `RunLoop.run(until:)` иногда не просыпался по своему сроку и
    /// висел в mach_msg минутами (14.11 под нагрузкой: проверка удержания обложки, 2 из 3 прогонов, App Nap уже
    /// выключен `beginActivity`). Таймер главной очереди будит цикл каждые 50 мс — после пробуждения он видит, что
    /// срок прошёл, и возвращается. Только в самотесте.
    static func keepAwake() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler {}
        t.resume()
        return t
    }

    /// Перезапуск после падения помощника, команды через stdin, stop() гасит группу.
    @MainActor
    private static func helperProcessTests(check: Checker) {
        let src = MediaRemoteSource()
        var states = 0
        src.onState = { _ in states += 1 }
        src.start()
        _ = spin(until: { (src.process?.pid ?? 0) > 0 && states > 0 }, timeout: 4)
        let pid1 = src.process?.pid ?? 0
        check(pid1 > 0 && states > 0, "Помощник: ManagedProcess запустил perl, первая строка now пришла (stdin — труба, не EOF)",
              "pid \(pid1), строк \(states)")
        check(groupMembers(pid1).contains(pid1), "Помощник: своя группа процессов (pgid = pid)", "\(groupMembers(pid1))")
        let before = states
        src.send("refresh")
        check(spin(until: { states > before }, timeout: 3), "Помощник: команда в stdin (refresh) → новая строка now")
        // Падение помощника → перезапуск с паузой (ManagedProcess, 1 с), тот же объект источника.
        if pid1 > 0 { kill(pid1, SIGKILL) }
        let restarted = spin(until: { let p = src.process?.pid ?? 0; return p > 0 && p != pid1 }, timeout: 5)
        let pid2 = src.process?.pid ?? 0
        check(restarted && src.isRunning && !src.failed && src.process?.restartCount == 1,
              "Помощник: kill -9 помощника → перезапуск с паузой", "pid \(pid1) → \(pid2), перезапусков \(src.process?.restartCount ?? -1)")
        check(waitGone([pid1], timeout: 1).isEmpty, "Помощник: убитый не остался зомби/сиротой")
        src.stop()
        let left = waitGone([pid2], timeout: 3)
        check(left.isEmpty && !src.isRunning, "Помощник: stop() — группа погашена (EOF stdin / SIGTERM)", "\(left)")
        check(spin(until: { ManagedProcess.liveGroups.isEmpty }, timeout: 3), "Помощник: реестр детей пуст после stop()",
              "\(ManagedProcess.liveGroups)")
    }

    /// Дочерний процесс-«приложение»: свой MediaRemoteSource, выход как у AppDelegate (SIGTERM → остановить модули →
    /// `ManagedProcess.terminateAll()` → exit). Печатает «ready <pid помощника>».
    @MainActor
    private static func runChild() -> Int32 {
        if let dir = ProcessInfo.processInfo.environment["SIMPLEISLAND_TEST_PIDDIR"] {
            ManagedProcess.pidDirectory = URL(fileURLWithPath: dir)
        }
        let src = MediaRemoteSource()
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            MainActor.assumeIsolated {
                src.stop()                       // env.stopModules()
                ManagedProcess.terminateAll()    // applicationWillTerminate
                exit(0)
            }
        }
        term.resume()
        src.start()
        guard spin(until: { (src.process?.pid ?? 0) > 0 }, timeout: 4) else { print("nohelper"); return 2 }
        print("ready \(src.process?.pid ?? 0)")
        fflush(stdout)
        _ = spin(until: { false }, timeout: 30)
        withExtendedLifetime(term) {}
        return 3
    }

    /// Выход «приложения» по SIGTERM и по kill -9: помощника не остаётся.
    @MainActor
    private static func exitTests(check: Checker, pidDir: URL) {
        guard let me = Bundle.main.executableURL?.path else { return }
        for (sig, name) in [(SIGTERM, "SIGTERM (штатный выход)"), (SIGKILL, "kill -9 (помощник уходит по EOF stdin)")] {
            var env = ProcessInfo.processInfo.environment
            env["SIMPLEISLAND_TEST_PIDDIR"] = pidDir.path
            let child = ManagedProcess(executable: me, arguments: ["--selftest-media", "child"], environment: env, restart: .never)
            var helper: pid_t = 0
            var code: Int32?
            child.onLine = { line in
                if line.hasPrefix("ready "), let p = pid_t(line.dropFirst(6)) { helper = p }
            }
            child.onExit = { code = $0 }
            guard child.start() else { check(false, "Выход: дочерний процесс запущен", ""); continue }
            let appPid = child.pid
            guard spin(until: { helper > 0 || code != nil }, timeout: 6), helper > 0 else {
                check(false, "Выход \(name): помощник в дочернем «приложении» запущен", "код \(code.map(String.init) ?? "—")")
                child.stop(grace: 0.5)
                continue
            }
            kill(appPid, sig)
            _ = spin(until: { code != nil }, timeout: 4)
            let left = waitGone([helper], timeout: 3)
            let expected: Int32 = sig == SIGTERM ? 0 : -SIGKILL
            check(code == expected && left.isEmpty, "Выход \(name): «приложение» вышло, детей не осталось",
                  "код \(code.map(String.init) ?? "нет"), помощник \(helper), осталось \(left)")
            if !left.isEmpty { for p in left { kill(p, SIGKILL) } }
        }
    }

    /// Сон → помощник погашен; пробуждение → новый процесс (переподписка на Now Playing); разблокировка — refresh.
    @MainActor
    private static func wakeTests(check: Checker) {
        let settings = SimpleIslandSettings(inMemory: SettingsData())
        let ctx = ModuleContext(moduleId: "media", settings: settings, themes: ThemeStore(load: false),
                                activities: ActivityCenter(), hud: HUDCenter(), notifications: IslandNotifications(),
                                island: IslandStateCenter(), isSnapshot: false, openTab: { _ in })
        var prefs = MediaPrefs(); prefs.source = .any; prefs.lyricsEnabled = false   // без AppleScript и сети
        ctx.saveSettings(prefs)
        let model = MediaModel()
        model.start(context: ctx)
        _ = spin(until: { (model.helperPID ?? 0) > 0 }, timeout: 4)
        let pid1 = model.helperPID ?? 0
        check(pid1 > 0, "Пробуждение: помощник работает до сна", "pid \(pid1)")
        let system = SystemStateCenter.shared
        system.handle(.willSleep)
        let gone = waitGone([pid1], timeout: 3)
        check(model.asleep && model.helperPID == nil && gone.isEmpty, "Сон (onSystemEvent .willSleep): помощник погашен",
              "осталось \(gone)")
        system.handle(.didWake)
        _ = spin(until: { (model.helperPID ?? 0) > 0 }, timeout: 4)
        let pid2 = model.helperPID ?? 0
        check(!model.asleep && pid2 > 0 && pid2 != pid1 && model.resubscribes == 1,
              "Пробуждение (.didWake): новый помощник — переподписка на поток Now Playing", "pid \(pid1) → \(pid2)")
        system.handle(.screenLocked)
        system.handle(.screenUnlocked)
        check(model.resubscribes == 2 && model.helperPID == pid2, "Разблокировка: перепроверка без перезапуска (refresh)",
              "переподписок \(model.resubscribes)")
        // `.didWake` потерялся: после сна пришли только «экран проснулся»/«разблокирован» — это пробуждение.
        system.handle(.willSleep)
        _ = waitGone([pid2], timeout: 3)
        system.handle(.screensDidWake)
        _ = spin(until: { (model.helperPID ?? 0) > 0 }, timeout: 4)
        let pid3 = model.helperPID ?? 0
        check(!model.asleep && pid3 > 0 && pid3 != pid2, "Сон без .didWake: .screensDidWake снимает «спит», новый помощник",
              "спит \(model.asleep), pid \(pid2) → \(pid3)")
        model.stop()
        ctx.removeSystemEventHandlers()
        check(waitGone([pid3], timeout: 3).isEmpty, "Пробуждение: после stop() помощника нет")
    }

    // MARK: Обложки и память

    /// phys_footprint процесса, байт (как считает система, не RSS).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// JPEG 1200×1200 (как большая обложка из Музыки): градиент двух цветов по номеру.
    static func coverJPEG(_ i: Int, side: Int = 1200) -> Data? {
        autoreleasepool {
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let h1 = Double(i % 37) / 37, h2 = Double((i * 7) % 41) / 41
            let c1 = NSColor(hue: h1, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor
            let c2 = NSColor(hue: h2, saturation: 0.7, brightness: 0.5, alpha: 1).cgColor
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c1, c2] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: side, y: side), options: [])
            ctx.setFillColor(NSColor(hue: h2, saturation: 1, brightness: 1, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 3, height: side / 3))
            guard let img = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { return nil }
            return out as Data
        }
    }

    @MainActor
    private static func artworkMemoryTest(check: Checker, changes: Int) {
        let ctx = ModuleContext(moduleId: "media", settings: SimpleIslandSettings(inMemory: SettingsData()),
                                themes: ThemeStore(load: false), activities: ActivityCenter(), hud: HUDCenter(),
                                notifications: IslandNotifications(), island: IslandStateCenter(),
                                isSnapshot: false, openTab: { _ in })
        let model = MediaModel()
        model.context = ctx
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        let warmup = 20
        var base: Int64 = 0
        var shown = 0, maxPx = 0
        let mainBefore = ArtworkPalette.mainThreadCalls
        let start = Date()
        let initial = footprint()
        // Каждая смена трека — в своём autorelease-пуле, как в приложении: там строка помощника приходит блоком
        // главной очереди, и цикл событий осушает пул после каждого. Самотест зовёт модель напрямую, вне цикла —
        // без пула autorelease-объекты копились бы до выхода (замер: +70 МБ за 200 смен, все — «в пуле», не утечка).
        for i in 0..<(warmup + changes) { autoreleasepool {
            guard let jpeg = coverJPEG(i) else { return }
            let id = "cover-\(i)"
            var n = NowPlaying(title: "Трек \(i)")
            n.artist = "Исполнитель \(i % 7)"; n.album = "Альбом"; n.duration = 200; n.isPlaying = true
            n.bundleId = "selftest.player"; n.artworkId = id
            // Как помощник: обложка — раньше строки трека.
            model.ingestArtwork(id: id, data: jpeg)
            model.simulateMediaRemote(n)
            if spin(until: { model.shownArtworkIdForTest == id }, timeout: 3) { shown += 1 }
            // Размер в пикселях — из представления (cgImage(forProposedRect:) рисовал бы копию в autorelease-пул).
            if let rep = model.artwork?.representations.first { maxPx = max(maxPx, rep.pixelsWide, rep.pixelsHigh) }
            if i == warmup - 1 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                base = footprint()
            }
        } }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let end = footprint()
        let growth = Double(end - base) / 1_048_576
        print(String(format: "info Память: до обложек %.1f МБ, после %d прогревочных %.1f МБ, после ещё %d — %.1f МБ",
                     Double(initial) / 1_048_576, 20, Double(base) / 1_048_576, changes, Double(end) / 1_048_576))
        let total = warmup + changes
        check(shown == total, "Обложки: \(total) смен трека — каждая обложка показана", "\(shown)/\(total)")
        check(maxPx > 0 && maxPx <= Int(MediaModel.coverPointSize * 2), "Обложки: миниатюра ImageIO ≤ размера показа ×2",
              "\(maxPx) px из 1200")
        check(growth <= 5, "Память: \(changes) смен трека — рост phys_footprint ≤ 5 МБ",
              String(format: "%.1f МБ (%.1f → %.1f МБ), %.1f с", growth, Double(base) / 1_048_576, Double(end) / 1_048_576,
                     Date().timeIntervalSince(start)))
        check(ArtworkPalette.mainThreadCalls == mainBefore, "Цвета обложки считаются вне главного потока",
              "на главном: \(ArtworkPalette.mainThreadCalls - mainBefore)")
        check(model.palette.count == 3 && (ctx.activities.ambientGlows["media"]?.count ?? 0) == 3,
              "Обложки: 3 цвета → свечение (setGlow)")
        // Та же обложка ещё раз — не декодируется.
        let decodes = model.artworkDecodes
        if let jpeg = coverJPEG(warmup + changes - 1) { model.ingestArtwork(id: "cover-\(warmup + changes - 1)", data: jpeg) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        check(model.artworkDecodes == decodes, "Обложки: повтор той же обложки не декодируется заново")
        model.stop()
        check(model.artwork == nil && ctx.activities.ambientGlows["media"] == nil, "Обложки: stop() снял картинку и свечение")
    }

    // MARK: Ревью media2: помощник, длинные строки, обложки

    /// Картинка side×side (PNG или JPEG) с шумом — чтобы PNG был тяжёлым, как настоящая большая обложка.
    static func coverImage(side: Int, type: String) -> Data? {
        autoreleasepool {
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var seed: UInt32 = 12345
            for y in 0..<side {
                let row = px + y * ctx.bytesPerRow
                for x in 0..<side {
                    seed = seed &* 1664525 &+ 1013904223
                    let o = x * 4
                    row[o] = UInt8(truncatingIfNeeded: x * 255 / side) ^ UInt8(truncatingIfNeeded: seed >> 28)
                    row[o + 1] = UInt8(truncatingIfNeeded: y * 255 / side)
                    row[o + 2] = UInt8(truncatingIfNeeded: seed >> 24)
                }
            }
            guard let img = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, nil)
            guard CGImageDestinationFinalize(dst) else { return nil }
            return out as Data
        }
    }

    /// Помощник уменьшает обложку сам: большой PNG → JPEG ≤ 600 px (строка — сотни КБ, не десятки МБ).
    @MainActor
    private static func helperThumbTests(check: Checker, dylib: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-thumb-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let big = coverImage(side: 3000, type: "public.png"), let small = coverImage(side: 300, type: "public.jpeg") else {
            check(false, "Помощник thumb: тестовые картинки"); return
        }
        let bigURL = dir.appendingPathComponent("big.png"), smallURL = dir.appendingPathComponent("small.jpg")
        try? big.write(to: bigURL); try? small.write(to: smallURL)
        let r = runHelper(dylib: dylib, mode: "thumb", env: ["SIMPLEISLAND_MR_THUMB": bigURL.path])
        let w = r?["w"] as? Int ?? 0, h = r?["h"] as? Int ?? 0, b64 = r?["b64"] as? Int ?? 0
        check(r?["mime"] as? String == "image/jpeg" && max(w, h) == 600 && b64 > 0 && b64 < 1 << 20
              && b64 < MediaRemoteSource.maxLineBytes,
              "Помощник: обложка 3000×3000 PNG уменьшена в помощнике (≤ 600 px JPEG, строка < 1 МБ)",
              String(format: "PNG %.1f МБ → %d×%d, base64 %d КБ", Double(big.count) / 1_048_576, w, h, b64 / 1024))
        let r2 = runHelper(dylib: dylib, mode: "thumb", env: ["SIMPLEISLAND_MR_THUMB": smallURL.path])
        check(r2?["out"] as? Int == small.count, "Помощник: маленькая обложка (300 px) уходит как есть",
              "\(r2?["in"] ?? "?") → \(r2?["out"] ?? "?") байт")
    }

    /// Длинная строка (13 МБ без перевода) собирается из кусков трубы за линейное время: `\n` ищется только в новом.
    @MainActor
    private static func longLineTest(check: Checker) {
        let size = 13_000_000
        let p = ManagedProcess(executable: "/usr/bin/perl", arguments: ["-e", "print 'a' x \(size); print \"\\nb\\n\";"],
                               restart: .never)
        p.maxLineBytes = 32 << 20
        var lines: [Int] = []
        var last = ""
        var exited = false
        p.onLine = { lines.append($0.utf8.count); last = $0 }
        p.onExit = { _ in exited = true }
        let t0 = Date()
        guard p.start() else { check(false, "Длинная строка: perl запущен"); return }
        _ = spin(until: { exited && lines.count >= 2 }, timeout: 20)
        let dt = Date().timeIntervalSince(t0)
        check(lines.first == size && last == "b" && dt < 5,
              "ManagedProcess: строка 13 МБ из \(p.readCallbacks) кусков — целиком и быстро (поиск \\n только в новом куске)",
              String(format: "%.2f с, строк %d", dt, lines.count))
    }

    /// Помощник: `retiring` не копит неработающих, строки старого процесса не применяются, сбой запуска perl —
    /// сразу на запасной путь, длинная команда в stdin не пишется кусками.
    @MainActor
    private static func helperEdgeTests(check: Checker) {
        let src = MediaRemoteSource()
        var titles: [String] = []
        src.onState = { titles.append(($0.info["Title"] as? String) ?? "") }
        src.start()
        _ = spin(until: { (src.process?.pid ?? 0) > 0 && !titles.isEmpty }, timeout: 4)
        // Длинная команда (> PIPE_BUF) — отказ, короткая — уходит.
        let p0 = src.process
        let long = p0?.send(String(repeating: "x", count: 600)) ?? true
        let short = p0?.send("refresh") ?? false
        check(!long && short, "ManagedProcess.send: строка > 512 байт — false (не пишется кусками), короткая — true")
        // Строка от остановленного процесса не применяется.
        let old = src.process
        src.restart()
        _ = spin(until: { (src.process?.pid ?? 0) > 0 && src.process !== old }, timeout: 4)
        let stale = #"{"type":"now","playing":true,"pid":1,"info":{"Title":"СТАРЫЙ ПРОЦЕСС"}}"#
        old?.onLine?(stale)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        check(!titles.contains("СТАРЫЙ ПРОЦЕСС"), "Помощник: строка остановленного процесса не применяется")
        // Помощник упал и ждёт перезапуска — stop() не оставляет объект в retiring.
        let pid = src.process?.pid ?? 0
        if pid > 0 { kill(pid, SIGKILL) }
        _ = spin(until: { src.process?.isRunning == false }, timeout: 3)
        _ = spin(until: { src.retiringCount == 0 }, timeout: 3)   // старый от restart() вышел
        src.stop()
        check(src.retiringCount == 0 && src.process == nil, "Помощник: stop() во время паузы перед перезапуском — retiring пуст",
              "в retiring \(src.retiringCount)")
        _ = waitGone([pid], timeout: 2)
        // perl не запустился — сразу «не работает» (на AppleScript), без бесконечных попыток.
        MediaRemoteSource.perlPath = "/nonexistent/simpleisland-perl"
        defer { MediaRemoteSource.perlPath = "/usr/bin/perl" }
        let bad = MediaRemoteSource()
        var failure: String?
        bad.onFailure = { failure = $0 }
        bad.start()
        check(bad.failed && failure != nil && bad.process == nil && !bad.isRunning,
              "Помощник: сбой запуска perl → сразу запасной путь (onFailure)", failure ?? "нет onFailure")
        let spawnFailed = ManagedProcess(executable: "/nonexistent/simpleisland-x", restart: .always)
        var rc: Int32 = 0
        spawnFailed.onSpawnFailure = { rc = $0 }
        let started = spawnFailed.start()
        spawnFailed.stop()
        check(!started && rc != 0, "ManagedProcess.onSpawnFailure: код ошибки posix_spawn", "\(rc)")
    }

    /// Обложка прошлого трека не висит дольше `artworkHoldSeconds`; фон «Хамелеона» — только канал обложки.
    @MainActor
    private static func artworkHoldTests(check: Checker) {
        let ctx = ModuleContext(moduleId: "media", settings: SimpleIslandSettings(inMemory: SettingsData()),
                                themes: ThemeStore(load: false), activities: ActivityCenter(), hud: HUDCenter(),
                                notifications: IslandNotifications(), island: IslandStateCenter(),
                                isSnapshot: false, openTab: { _ in })
        let model = MediaModel()
        model.context = ctx
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        guard let a = coverJPEG(3, side: 400), let b = coverJPEG(9, side: 400) else { check(false, "Обложки: тестовые"); return }
        var n = NowPlaying(title: "Первый"); n.artist = "А"; n.isPlaying = true; n.bundleId = "selftest.player"; n.artworkId = "A"
        model.ingestArtwork(id: "A", data: a)
        model.simulateMediaRemote(n)
        _ = spin(until: { model.shownArtworkIdForTest == "A" }, timeout: 3)
        let colorsA = ctx.activities.artworkColors
        check(colorsA?.count == 3, "Хамелеон: цвета обложки — в канале фона (setArtworkColors)")
        // Свечение другого модуля (полка: синее) фон не трогает; чужое «снять» — не снимает.
        ctx.activities.setAmbientGlow([.blue, .blue], for: "shelf")
        ctx.activities.setArtworkColors(nil, for: "shelf")
        check(ctx.activities.artworkColors == colorsA && ctx.activities.artworkOwner == "media",
              "Хамелеон: свечение полки/агентов не красит фон, чужой модуль не снимает цвета обложки")
        var n2 = n; n2.title = "Второй"; n2.artworkId = "B"
        model.simulateMediaRemote(n2)
        let held = model.artwork != nil
        // Запас на загруженный Мак: проверяем, что обложку держат и потом снимают, а не точность таймера. При load
        // 25–44 (14.11) проверка падала и с запасом +5 с (2 из 6), причина не найдена — в подробностях видно, что осталось.
        _ = spin(until: { model.artwork == nil }, timeout: MediaModel.artworkHoldSeconds + 5)
        check(held && model.artwork == nil && model.palette.isEmpty && ctx.activities.artworkColors == nil
              && ctx.activities.ambientGlows["media"] == nil,
              "Обложка: новый трек без обложки — прежняя держится ≤ 1 с, потом снята (с палитрой и фоном)",
              "держали \(held), обложка \(model.artwork != nil), палитра \(model.palette.count), "
              + "фон \(ctx.activities.artworkColors?.count ?? 0), свечение \(ctx.activities.ambientGlows["media"] != nil)")
        model.ingestArtwork(id: "B", data: b)
        _ = spin(until: { model.shownArtworkIdForTest == "B" }, timeout: 3)
        check(model.artwork != nil && ctx.activities.artworkColors?.count == 3, "Обложка: пришла позже — показана")
        model.stop()
        check(ctx.activities.artworkColors == nil && ctx.activities.artworkOwner == nil, "Хамелеон: stop() снял цвета фона")
    }

    // MARK: Далее

    @MainActor
    private static func nextTrackTests(check: Checker) {
        check(ScriptSource.parseNext("  Сигнал из окна ") == "Сигнал из окна" && ScriptSource.parseNext("") == nil,
              "Далее: разбор поля Музыки (пусто — неизвестно)")
        // Текст скриптов (поведение Музыки самотест без неё не проверит — только вживую).
        check(ScriptSource.musicNextScript.contains("shuffle enabled") && ScriptSource.musicNextScript.contains("song repeat")
              && !ScriptSource.musicReadScript.contains("whose"),
              "Далее (текст скрипта): перемешивание/повтор одной — пусто; поиск по плейлисту — не в чтении на каждое событие")
        // Скрипт «Далее» — раз на трек (не на каждую паузу/игру) и при открытии вкладки.
        let src = ScriptSource()
        var asked: [String] = []
        src.nextLoaderForTest = { _, key in asked.append(key) }
        let row1 = ["playing", "Первый", "А", "Альбом", "200", "10", "", ""]
        src.simulateRead(bundle: MediaApps.music, fields: row1)
        src.simulateRead(bundle: MediaApps.music, fields: ["paused"] + row1.dropFirst())
        src.simulateRead(bundle: MediaApps.music, fields: row1)
        check(src.nextLoads == 1, "Далее: скрипт — один раз на трек (3 события того же трека)", "\(src.nextLoads)")
        src.refreshNext()
        check(src.nextLoads == 2, "Далее: открытие вкладки — перечитать (перемешивание могли включить без смены трека)")
        var row2 = row1; row2[1] = "Второй"
        src.simulateRead(bundle: MediaApps.music, fields: row2)
        check(src.nextLoads == 3 && asked.count == 3 && asked[2] != asked[0], "Далее: новый трек — новый запрос")
        src.stop()
        let model = MediaModel()
        var prefs = MediaPrefs(); prefs.lyricsEnabled = false
        model.prefs = prefs
        var n = NowPlaying(title: "Первый"); n.artist = "А"; n.bundleId = MediaApps.music; n.isPlaying = true
        model.simulateMediaRemote(n)
        model.simulateNext(bundle: MediaApps.music, trackKey: n.trackKey, title: "Второй")
        check(model.nextTitle == "Второй", "Далее: показан для текущего трека")
        model.simulateNext(bundle: MediaApps.music, trackKey: "чужой", title: "Третий")
        check(model.nextTitle == "Второй", "Далее: ответ про другой трек не применяется")
        var n2 = n; n2.title = "Второй"
        model.simulateMediaRemote(n2)
        check(model.nextTitle == nil, "Далее: смена трека — скрыто до нового ответа")
        model.simulateNext(bundle: MediaApps.spotify, trackKey: n2.trackKey, title: "Х")
        check(model.nextTitle == nil, "Далее: ответ другого приложения не применяется")
        model.stop()
    }
}
