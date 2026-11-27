import AppKit
import Foundation
import LyricsCore
import QuartzCore

/// Самотест движка текстов (часть `--selftest-media`, без сети): разбор TTML/YRC/QRC/KRC/Enhanced LRC через LyricsCore на
/// синтетических фикстурах (тексты придуманы, реальных песен нет) и перевод в модель острова, момент заливки слова
/// (±20 мс, в том числе по настоящим анимациям слоёв), выбор источника каскада (Apple без токена пропущен, пословный
/// важнее построчного, выключенный источник не спрашивается, чужая версия и «почти совпадение» отвергнуты), токен
/// в хранилище, микробенч сборки строки.
enum LyricsCoreSelfTest {
    typealias Check = LyricsSelfTest.Check

    static func run(_ check: Check) {
        formats(check)
        MainActor.assumeIsolated { timing(check) }
        selection(check)
        streaming(check)
        MainActor.assumeIsolated { trackChange(check) }
        MainActor.assumeIsolated { bench(check) }
    }

    static func noToken() -> CredentialStore { InMemoryCredentialStore() }

    // MARK: Форматы

    static func formats(_ check: Check) {
        func src(_ p: LyricsProviderID) -> LyricsSource { LyricsSource(provider: p) }
        // TTML (Apple/AMLL): слоги «Ро»+«са» — одно слово, фон-вокал x-bg (скобки снимаются).
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="ru"><head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head><body dur="1:00.000"><div begin="1.000" end="8.000"><p begin="1.000" end="4.000" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.400">Ро</span><span begin="1.400" end="1.800">са</span> <span begin="2.000" end="3.600">тиха</span> <span ttm:role="x-bg"><span begin="3.600" end="3.900">(ла</span> <span begin="3.900" end="4.000">ла)</span></span></p><p begin="5.000" end="8.000" itunes:key="L2" ttm:agent="v1"><span begin="5.000" end="6.000">вторая</span> <span begin="6.000" end="8.000">строка</span></p></div></body></tt>
        """
        if let l = try? TTMLParser.parse(ttml, source: src(.amll)), let m = LyricsService.convert(l) {
            let a = m.lines[0]
            check(m.wordSynced && m.lines.count == 2 && a.words.map(\.text) == ["Ро", "са", "тиха"]
                  && a.words.map(\.joins) == [false, true, false] && a.text == "Роса тиха"
                  && abs(a.words[2].begin - 2.0) < 1e-9 && abs(a.words[2].end - 3.6) < 1e-9 && a.end == 4.0,
                  "LyricsCore TTML: слоги, слова, время", "\(a.words.map(\.text)) \(a.text)")
            check(a.background.map(\.text) == ["ла", "ла"] && abs(a.background[0].begin - 3.6) < 1e-9 && m.source == "AMLL TTML DB",
                  "LyricsCore TTML: фон-вокал x-bg без скобок", "\(a.background.map(\.text))")
        } else { check(false, "LyricsCore TTML: разбор", "ошибка") }

        // YRC (NetEase): [начало,длит](начало,длит,0)слог…
        let yrc = """
        [1000,3000](1000,500,0)Тихо (1500,500,0)над (2000,1000,0)рекой
        [5000,2000](5000,800,0)ещё (5800,1200,0)раз
        """
        if let l = try? YRCParser.parse(yrc, source: src(.netease)), let m = LyricsService.convert(l) {
            let a = m.lines[0]
            check(m.wordSynced && a.text == "Тихо над рекой" && a.words.count == 3 && abs(a.words[1].begin - 1.5) < 1e-9
                  && abs(a.words[2].end - 3.0) < 1e-9 && m.lines[1].time == 5,
                  "LyricsCore YRC: пословно, время в мс", "\(a.words.map(\.text))")
        } else { check(false, "LyricsCore YRC: разбор", "ошибка") }

        // QRC (QQ, уже расшифрованный): [начало,длит]слог(начало,длит)…
        let qrc = """
        [1000,2000]Вот (1000,300)и (1300,200)ве(1500,500)чер(2000,1000)
        [4000,1000]снова (4000,1000)
        """
        if let l = try? QRCParser.parse(qrc, source: src(.qq)), let m = LyricsService.convert(l) {
            let a = m.lines[0]
            check(m.wordSynced && a.words.map(\.text) == ["Вот", "и", "ве", "чер"] && a.words.map(\.joins) == [false, false, false, true]
                  && a.text == "Вот и вечер" && abs(a.words[3].begin - 2.0) < 1e-9,
                  "LyricsCore QRC: слоги без пробела склеены", "\(a.words.map(\.text)) \(a.words.map(\.joins))")
        } else { check(false, "LyricsCore QRC: разбор", "ошибка") }

        // KRC (KuGou, уже раскодированный): [начало,длит]<смещение,длит,0>слог…
        let krc = """
        [language:x]
        [2000,3000]<0,500,0>Ветер <500,500,0>в <1000,2000,0>поле
        [6000,1000]<0,1000,0>тишина
        """
        if let l = try? KRCParser.parse(krc, source: src(.kugou)), let m = LyricsService.convert(l) {
            let a = m.lines[0]
            check(m.wordSynced && a.text == "Ветер в поле" && abs(a.words[2].begin - 3.0) < 1e-9 && abs(a.words[2].end - 5.0) < 1e-9,
                  "LyricsCore KRC: смещение слова от начала строки", "\(a.words.map { "\($0.text)@\($0.begin)" })")
        } else { check(false, "LyricsCore KRC: разбор", "ошибка") }

        // Enhanced LRC (LRCLIB lyricsfile и др.): <мм:сс.хх> перед словами; строка без меток — построчно.
        let elrc = """
        [00:01.00]<00:01.00>Пер<00:01.40>вый <00:02.00>день <00:03.00>
        [00:04.00]просто строка
        """
        let el = LRCParser.parse(elrc, source: src(.lrclib))
        if let m = LyricsService.convert(el) {
            let a = m.lines[0]
            check(el.syncType == .word && a.words.map(\.text) == ["Пер", "вый", "день"] && a.words.map(\.joins) == [false, true, false]
                  && abs(a.words[2].end - 3.0) < 1e-9 && m.lines[1].words.isEmpty && m.lines[1].text == "просто строка",
                  "LyricsCore Enhanced LRC: слоги и построчный хвост", "\(a.words.map(\.text))")
        } else { check(false, "LyricsCore Enhanced LRC: разбор", "ошибка") }

        // Построчный LRC и простой текст.
        let line = LyricsService.convert(LRCParser.parse("[00:10.00]а\n[00:12.00]б", source: src(.lrclib)))
        let plain = LyricsService.convert(LRCParser.parse("первая\nвторая", source: src(.lrclib)))
        check(line?.synced == true && line?.wordSynced == false && line?.lines.map(\.time) == [10, 12]
              && plain?.synced == false && plain?.plainExcerpt(5) == ["первая", "вторая"],
              "LyricsCore: построчный — без слов, простой — без таймингов", "")
        // Сдвиг на задержку вывода двигает и слова.
        if let m = LyricsService.convert(el) {
            let s = m.shifted(by: 0.25)
            check(abs(s.lines[0].words[1].begin - 1.65) < 1e-9 && abs(s.lines[0].words[1].end - 2.25) < 1e-9,
                  "Lyrics.shifted: слова тоже позже на задержку", "")
        }
    }

    // MARK: Момент заливки слова

    @MainActor
    static func timing(_ check: Check) {
        let line = LyricLine(time: 10, text: "Hello world", end: 13,
                             words: [LyricWord(text: "Hel", begin: 10, end: 10.4), LyricWord(text: "lo", begin: 10.4, end: 10.8, joins: true),
                                     LyricWord(text: "world", begin: 11, end: 12.6)],
                             background: [LyricWord(text: "oh", begin: 12.6, end: 13)])
        check(abs(line.words[2].progress(at: 11.8) - 0.5) < 1e-9 && line.words[0].progress(at: 9) == 0 && line.words[0].progress(at: 11) == 1,
              "Слово: доля заливки по своему begin/end", "")
        // Сегменты (перенос DisplaySegment): Hel+lo — одно слово 0,8 с (без выделения), world 1,6 с / 5 букв → f = 0,6.
        let segs = LyricSegment.make(line.words, background: false, emphasisAllowed: true)
        check(segs.map(\.wordIndex) == [0, 0, 1] && segs[0].emphasis == nil && abs((segs[2].emphasis ?? 0) - 0.6) < 1e-9
              && AMSpec.emphasis(duration: 1.5, letters: 8) == nil && AMSpec.emphasis(duration: 1, letters: 3) == nil
              && LyricSegment.make([LyricWord(text: "你好", begin: 0, end: 1)], background: false, emphasisAllowed: true).map(\.end) == [0.5, 1],
              "Выделение слова: d > 1 с и ≤ 7 букв, f = min(d, 2) − 1; CJK — по символу", "\(segs.map { $0.emphasis ?? -1 })")

        // Фронт заливки: ключевые точки = edge(at:), растушёвка одна на строку (без скачков через границы слогов).
        let ff = FillFront(spans: [.init(x0: 0, x1: 30, begin: 10, end: 10.4), .init(x0: 30, x1: 50, begin: 10.4, end: 10.8),
                                   .init(x0: 56, x1: 110, begin: 11, end: 12.6)], minX: 0, maxX: 110, feather: 16.8)
        let kf = ff.keyframes()
        func interp(_ t: Double) -> CGFloat {
            guard let f = kf.first, let l = kf.last else { return .nan }
            if t <= f.0 { return f.1 }
            if t >= l.0 { return l.1 }
            var i = 0
            while i + 1 < kf.count && kf[i + 1].0 <= t { i += 1 }
            let a = kf[i], b = kf[min(i + 1, kf.count - 1)]
            return b.0 > a.0 ? a.1 + (b.1 - a.1) * CGFloat((t - a.0) / (b.0 - a.0)) : b.1
        }
        var worstKF: CGFloat = 0
        var t = 9.5
        while t < 13.2 { worstKF = max(worstKF, abs(interp(t) - ff.edge(at: t))); t += 0.0137 }
        func litFrac(_ x: CGFloat, _ e: CGFloat) -> CGFloat { min(1, max(0, 0.5 - (x - e) / ff.feather)) }
        let mid = ff.edge(at: 11.8)
        check(worstKF < 0.05 && litFrac(0, ff.edge(at: 9.9)) == 0 && litFrac(110, ff.edge(at: 12.6 + 0.25)) == 1
              && abs(mid - 83) < 0.01 && ff.edge(at: 10.9) == 50 && kf.allSatisfy { $0.0 >= 10 }
              && zip(kf, kf.dropFirst()).allSatisfy { $0.0 <= $1.0 && $1.1 >= $0.1 - 0.01 },
              "Фронт: ключевые точки совпадают с edge(t), до начала тускло, после конца + 0,25 с залито, в паузе стоит",
              String(format: "расхождение %.3f pt, край в середине world %.1f, точек %d", worstKF, mid, kf.count))
        var maxJump: CGFloat = 0
        for (a, b) in zip(kf, kf.dropFirst()) where a.0 == b.0 { maxJump = max(maxJump, b.1 - a.1) }
        check(maxJump <= 6.01, "Фронт: скачки края только через пробел между словами (≤ ширины пробела)",
              String(format: "%.1f pt", maxJump))

        // Подъём/рост/свечение по формулам SimpleLyrics.
        let st0 = NodeMotion.emphasized(f: 0.6, wordBegin: 11, wordEnd: 12.6, glyph: 0, of: 5, t: 12.5, lift: 1)
        let st4 = NodeMotion.emphasized(f: 0.6, wordBegin: 11, wordEnd: 12.6, glyph: 4, of: 5, t: 11.5, lift: 1)
        let st0e = NodeMotion.emphasized(f: 0.6, wordBegin: 11, wordEnd: 12.6, glyph: 0, of: 5, t: 11.5, lift: 1)
        let late = NodeMotion.emphasized(f: 0.6, wordBegin: 11, wordEnd: 12.6, glyph: 0, of: 5, t: 20, lift: 1)
        check(st0.scale > 1.07 && st0.scale <= 1 + 0.14 * 0.6 + 1e-9 && st0.glow <= 0.4 * 0.6 + 1e-6 && st4.scale < st0e.scale
              && abs(late.scale - 1) < 0.002 && late.glow < 0.002 && abs(late.lift - 1) < 0.01
              && abs(NodeMotion.stagger(wordDuration: 1.6, glyphs: 5) - 0.128) < 1e-9
              && abs(NodeMotion.syllable(begin: 0, t: 1.5, lift: 2).lift - 2 * LyricSpring.response(1.5).step(1.5)) < 1e-9,
              "Выделенное слово: рост до 1 + 0,14·f с волной по глифам, спад после слова, подъём остаётся",
              String(format: "s=%.3f glow=%.3f, позже: s=%.3f lift=%.2f", st0.scale, st0.glow, late.scale, late.lift))
        let sp = LyricSpring(mass: 1, stiffness: 100, damping: 18)
        let ca = sp.animation(keyPath: "position.y")
        check(abs(sp.settlingDuration - ca.settlingDuration) < 0.15 && abs(LyricSpring.response(1.5).stiffness - pow(2 * .pi / 1.5, 2)) < 1e-9,
              "Пружины: settlingDuration как у CASpringAnimation, response → stiffness", String(format: "%.2f / %.2f с", sp.settlingDuration, ca.settlingDuration))

        // Часы плеера → настоящие анимации слоёв (±20 мс) при задержке вывода и скорости ×1 / ×1,25.
        let t0 = Date()
        let font = NSFont.systemFont(ofSize: 19, weight: .bold)
        for (rate, lat, bundle) in [(1.0, 0.0, "com.apple.Music"), (1.0, 0.22, "com.spotify.client"), (1.25, 0.22, "com.spotify.client")] {
            let off = LyricsSync.offset(bundleId: bundle, outputLatency: lat)
            let shifted = line.shifted(by: off)
            // Строка уже идёт (выбирается с её начала): позиция 10,3 с.
            let clock = KaraokeClock(timestamp: t0, elapsed: 10.3, rate: rate)
            let stack = LyricsStack()
            stack.update(lyrics: Lyrics(lines: [shifted]), position: 10.3 + Date().timeIntervalSince(t0) * rate, clock: clock,
                         animated: true, config: cfg(400, 60), font: { _ in font })
            let caNow = CACurrentMediaTime(), wallNow = Date()
            guard let l = stack.layers[0] else { check(false, "Заливка: строка построена", "нет слоя"); continue }
            var worstCA = 0.0, durErr = 0.0, fills = 0, lifts = 0, glows = 0
            let first = l.mainFront.keyframes().first?.0 ?? 0, last = l.mainFront.keyframes().last?.0 ?? 0
            for n in l.nodes {
                if n.container.animation(forKey: "lift") != nil { lifts += 1 }
                if n.lit.animation(forKey: "glow") != nil { glows += 1 }
                guard let a = n.mask.animation(forKey: "fill"), !n.seg.background else { continue }
                fills += 1
                let wall = wallNow.addingTimeInterval(a.beginTime - caNow)
                let want = t0.addingTimeInterval((line.words[0].begin + off - 10.3) / rate)
                worstCA = max(worstCA, abs(wall.timeIntervalSince(want)))
                durErr = max(durErr, abs(a.duration - (last - first) / rate))
            }
            // world (5 букв, выделено) — пять глифов; Hel, lo, oh — слоги (фон-вокал тоже поднимается, как у SimpleLyrics).
            check(worstCA <= 0.02 && durErr <= 0.02 && l.nodes.count == 8 && fills == 7 && lifts == 8 && glows == 5
                  && stack.selected == 0,
                  String(format: "Заливка: ±20 мс по часам (×%.2f, задержка %.0f мс)", rate, lat * 1000),
                  String(format: "слои %.1f мс, длительность %.1f мс, узлов %d, заливок %d, подъёмов %d, свечений %d",
                         worstCA * 1000, durErr * 1000, l.nodes.count, fills, lifts, glows))
        }

        // Компакт: заливка есть, подъёма/роста нет; перемотка — анимации от новой позиции.
        let c = LyricsStack()
        let one = Lyrics(lines: [line])
        c.update(lyrics: one, position: 10.05, clock: KaraokeClock(timestamp: Date(), elapsed: 10.05, rate: 1), animated: true,
                 config: cfg(160, 18, size: 12, compact: true), font: { _ in font })
        let cn = c.layers[0]?.nodes ?? []
        check(!cn.isEmpty && cn.filter { !$0.seg.background }.allSatisfy { $0.mask.animation(forKey: "fill") != nil && $0.container.animation(forKey: "lift") == nil }
              && cn.allSatisfy { $0.seg.emphasis == nil },
              "Компакт: заливка без подъёма и выделения", "\(cn.count) узлов")
        c.update(lyrics: one, position: 11.5, clock: KaraokeClock(timestamp: Date(), elapsed: 11.5, rate: 1), animated: true,
                 config: cfg(160, 18, size: 12, compact: true), font: { _ in font })
        if let a = c.layers[0]?.nodes.first?.mask.animation(forKey: "fill") {
            let started = CACurrentMediaTime() - a.beginTime   // строка началась 1,5 с назад
            check(abs(started - 1.5) <= 0.02, "Перемотка: заливка — от новой позиции", String(format: "%.3f с", started))
        } else { check(false, "Перемотка: заливка — от новой позиции", "нет анимации") }

        stackChecks(check, font: font)
    }

    @MainActor
    static func cfg(_ w: CGFloat, _ h: CGFloat, size: CGFloat = 19, compact: Bool = false) -> LyricsStack.Config {
        LyricsStack.Config(themeID: "t", fontSize: size, colorHex: "#FFFFFF", light: false, size: CGSize(width: w, height: h),
                           scale: 2, compact: compact)
    }

    /// Три строки острова: слоты, размытие, каскад, смена строки, проигрыш.
    @MainActor
    static func stackChecks(_ check: Check, font: NSFont) {
        var lines: [LyricLine] = []
        for i in 0..<6 {
            let t = Double(i) * 4
            let ws = ["раз", "два", "три"].enumerated().map { k, w in LyricWord(text: w, begin: t + Double(k), end: t + Double(k) + 0.9) }
            lines.append(LyricLine(time: t, text: "раз два три", end: t + 3, words: ws))
        }
        lines.insert(LyricLine(time: 23.5, text: ""), at: 6)   // проигрыш (пустая строка LRC)
        lines[5].time = 20
        let lyr = Lyrics(lines: lines)
        let s = LyricsStack()
        let now = Date()
        func clock(_ p: Double) -> KaraokeClock { KaraokeClock(timestamp: now, elapsed: p, rate: 1) }
        s.update(lyrics: lyr, position: 4.5, clock: clock(4.5), animated: true, config: cfg(400, 60), font: { _ in font })
        let h = s.layers[1]?.boxHeight ?? 0
        func y(_ k: Int) -> CGFloat { s.slotY(k, focus: 1, selected: 1) }
        let y0 = y(1), yp = y(0), yn = y(2), y2 = y(3)
        let nb = h * AMSpec.islandNeighborScale
        check(s.focus == 1 && s.selected == 1 && Set(s.layers.keys) == [0, 1, 2, 3] && y0 == 30
              && yp - nb / 2 >= -0.5 && yn + nb / 2 <= 60.5 && y2 - nb / 2 > 60,
              "Строки острова: активная по центру, соседи целиком в 60 pt, ±2 — за краем (въедут)",
              String(format: "высота строки %.0f, слоты %.1f / %.1f / %.1f, за краем %.1f", h, yp, y0, yn, y2))
        let r1 = LayerBlur.radius(of: s.layers[0]!.root, presented: false), r0 = LayerBlur.radius(of: s.layers[1]!.root, presented: false)
        let r2 = LayerBlur.radius(of: s.layers[3]!.root, presented: false)
        let sc = s.layers[0]!.root.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 0
        check(!LayerBlur.isAvailable || (r0 == 0 && abs(r1 - 19.0 / 34) < 1e-3 && abs(r2 - 2 * 19.0 / 34) < 1e-3),
              "Размытие: min(расстояние, 4) при 34 pt → доля кегля; активная — резкая",
              LayerBlur.isAvailable ? String(format: "%.2f / %.2f / %.2f", r1, r0, r2) : "CAFilter недоступен — без размытия")
        check(abs(sc - 13.0 / 19) < 1e-3, "Соседняя строка — 13/19 кегля активной", String(format: "%.3f", sc))
        // Следующая строка: активная едет вверх, нижние — с каскадом 0,05 с на строку.
        s.update(lyrics: lyr, position: 8.0, clock: clock(8.0), animated: true, config: cfg(400, 60), font: { _ in font })
        let a2 = s.layers[2]?.root.animation(forKey: "y"), a3 = s.layers[3]?.root.animation(forKey: "y")
        let a4 = s.layers[4]?.root.animation(forKey: "y")
        let d32 = (a3?.beginTime ?? 0) - (a2?.beginTime ?? 0), d43 = (a4?.beginTime ?? 0) - (a3?.beginTime ?? 0)
        let spring = a2 as? CASpringAnimation
        check(s.focus == 2 && s.selected == 2 && a2 != nil && abs(d32 - 0.05) < 1e-6 && abs(d43 - 0.05) < 1e-6
              && spring?.stiffness == 100 && spring?.damping == 18 && s.layers[1]?.selected == false
              && s.layers[0]?.root.superlayer != nil && s.layers[2]?.root.animation(forKey: "scale") != nil,
              "Смена строки: пружина 1/100/18, каскад 0,05 с на строку ниже, старая гаснет, новая растёт",
              String(format: "каскад %.3f / %.3f с", d32, d43))
        // Проигрыш: строки нет, фокус остаётся на последней спетой, она гаснет; перемотка далеко — без анимации.
        s.update(lyrics: lyr, position: 24, clock: clock(24), animated: true, config: cfg(400, 60), font: { _ in font })
        check(s.focus == 5 && s.selected == nil && s.layers[5]?.selected == false,
              "Проигрыш: активной нет, фокус на последней строке", "\(String(describing: s.focus)) \(String(describing: s.selected))")
        s.update(lyrics: lyr, position: 0.5, clock: clock(0.5), animated: true, config: cfg(400, 60), font: { _ in font })
        check(s.focus == 0 && s.layers.values.allSatisfy { $0.root.animation(forKey: "y") == nil } && s.layers.keys.max() == 2,
              "Перемотка далеко: строки ставятся сразу, лишние убраны", "\(s.layers.keys.sorted())")

        // Статичный кадр (пауза/снимок) — тот же фронт: слой маски стоит на edge(t).
        s.update(lyrics: lyr, position: 1.45, clock: nil, animated: false, config: cfg(400, 60), font: { _ in font })
        if let l = s.layers[0], let n = l.nodes.first(where: { $0.seg.text == "два" }) {
            let want = l.maskX(n, edge: l.mainFront.edge(at: 1.45))
            check(n.mask.animationKeys() == nil && abs(n.mask.position.x - want) < 0.01 && n.lit.opacity == 1,
                  "Пауза: статичный кадр, край — edge(t)", String(format: "%.2f", n.mask.position.x))
        }
        longLines(check, font: font)

        // Кадр через CARenderer — отдельным процессом (`--render-lyrics-frames`): в процессе самотеста рендерер ломал
        // таймеры главной очереди у последующих проверок (обложка, захват, превью — 5 FAIL, 16.11; без этой проверки — OK).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrframes-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--render-lyrics-frames", dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let deadline = Date().addingTimeInterval(90)
            while p.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if p.isRunning { p.terminate() }
            let pngs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }) ?? []
            let lit = NSImage(contentsOf: dir.appendingPathComponent("fill-108.7.png"))?
                .cgImage(forProposedRect: nil, context: nil, hints: nil).map(brightPixels) ?? 0
            check(p.terminationStatus == 0 && pngs.count == 15 && lit > 500,
                  "CARenderer: --render-lyrics-frames — 15 кадров анимаций, кадр с заливкой не пустой",
                  "код \(p.terminationStatus), кадров \(pngs.count), ярких пикселей \(lit)")
        } catch { check(false, "CARenderer: --render-lyrics-frames", "\(error)") }
    }

    /// Длинная строка (баг 16.11: «DTF», начало активной строки уезжало за левый край колонки — бегущая строка):
    /// теперь перенос на ряды мельче (как у Apple), строка всегда от левого края, рост слова у края не обрезается;
    /// бегущая строка — только в компакте.
    @MainActor
    static func longLines(_ check: Check, font: NSFont) {
        let lyr = LyricsDebugRender.longLyrics
        let st = lyr.lines[2].time
        for width in [300.0, 400, 520] as [CGFloat] {
            let s = LyricsStack()
            s.update(lyrics: lyr, position: st + 0.1, clock: KaraokeClock(timestamp: Date(), elapsed: st + 0.1, rate: 1),
                     animated: true, config: cfg(width, 60), font: { _ in font })
            guard let l = s.layers[2], s.selected == 2 else { check(false, "Длинная строка: выбрана", ""); continue }
            let sc = l.root.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 0
            let pad = max(4, ceil(19 * 0.3))
            let minX = l.nodes.map { $0.originX + pad }.min() ?? -1
            let maxX = l.nodes.map { $0.container.frame.maxX - pad }.max() ?? 0
            let rowsUsed = Set(l.nodes.map(\.row))
            let fills = l.nodes.filter { $0.mask.animation(forKey: "fill") != nil }.count
            check(l.rows >= 2 && rowsUsed.count == l.rows && abs(sc - l.fit) < 1e-6 && l.fit <= AMSpec.islandWrapScale
                  && CGFloat(l.rows) * l.fit <= 2 * AMSpec.islandWrapScale + 0.011 && l.root.anchorPoint.x == 0
                  && l.root.position.x == 0 && minX >= -0.01 && maxX * sc <= width + 0.5
                  && l.scroller.animation(forKey: "follow") == nil && l.scroller.position.x == 0 && fills == l.nodes.count,
                  String(format: "Длинная строка (колонка %.0f): перенос на ряды (≤ 2 ряда ×0,72 по высоте) от левого края, без бегущей строки", width),
                  String(format: "рядов %d, масштаб %.2f, текст %.1f…%.1f (видно до %.1f), заливок %d/%d", l.rows, sc, minX * sc, maxX * sc,
                         width, fills, l.nodes.count))
            // Соседи не налезают на перенесённую активную и видны в 60 pt (с мягким краем 6 pt).
            let hA = s.visualHeight(2, selected: true), hP = s.visualHeight(1, selected: false), hN = s.visualHeight(3, selected: false)
            let yA = s.slotY(2, focus: 2, selected: 2), yP = s.slotY(1, focus: 2, selected: 2), yN = s.slotY(3, focus: 2, selected: 2)
            check(yA == 30 && yA - hA / 2 - (yP + hP / 2) >= AMSpec.islandLineGap - 0.01 && yN - hN / 2 - (yA + hA / 2) >= AMSpec.islandLineGap - 0.01
                  && yP - hP / 2 >= -LyricsStack.bleed && yN + hN / 2 <= 60 + LyricsStack.bleed,
                  String(format: "Длинная строка (колонка %.0f): соседи не налезают, видны в 60 pt", width),
                  String(format: "активная %.1f pt по %.1f, соседи %.1f / %.1f", hA, yA, yP - hP / 2, yN + hN / 2))
            // Рост первого (выделенного) слова у левого края не уходит за поле обрезки.
            if let first = l.nodes.first, let f = first.seg.emphasis {
                let grow = (first.wordCenterX - 0) * (1 + (AMSpec.emphasisScaleMax - 1) * CGFloat(f) - 1) * sc
                check(grow <= s.hPad, "Длинная строка: рост 1,14 первого слова у левого края — в поле обрезки",
                      String(format: "влево до %.1f pt при поле %.0f", grow, s.hPad))
            }
        }
        // Компакт: один ряд, бегущая строка за фронтом (мягкие края), начало — с нуля.
        let c = LyricsStack()
        c.update(lyrics: Lyrics(lines: [lyr.lines[2]]), position: st + 0.1, clock: KaraokeClock(timestamp: Date(), elapsed: st + 0.1, rate: 1),
                 animated: true, config: cfg(200, 18, size: 12, compact: true), font: { _ in font })
        if let l = c.layers[0] {
            let follow = l.scroller.animation(forKey: "follow") as? CAKeyframeAnimation
            let vals = (follow?.values as? [CGFloat]) ?? []
            check(l.rows == 1 && l.fit == 1 && follow != nil && (vals.first ?? -1) == 0 && (vals.min() ?? 0) < -100,
                  "Компакт: длинная строка — один ряд, бегущая строка за фронтом с начала", "сдвиг до \(Int(vals.min() ?? 0)) pt")
        }
    }

    /// Пиксели ярче 0,5 (по максимуму из каналов) — грубая проверка, что кадр не пустой.
    static func brightPixels(_ img: CGImage) -> Int {
        guard let d = img.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return 0 }
        var n = 0
        for i in stride(from: 0, to: CFDataGetLength(d), by: 4) where max(p[i], p[i + 1], p[i + 2]) > 128 { n += 1 }
        return n
    }

    // MARK: Выбор источника

    struct NoNetwork: HTTPClient {
        func send(_ request: URLRequest) async throws -> HTTPResponse { throw LyricsError.network("самотест без сети") }
    }

    struct Mock: LyricsProvider {
        var id: LyricsProviderID
        var result: [LyricsCore.Lyrics]
        func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] { result }
    }

    static func mockLyrics(_ p: LyricsProviderID, word: Bool, title: String = "Тёплый ветер", artist: String = "Синтетика",
                           duration: Double = 200, near: Bool = false) -> LyricsCore.Lyrics {
        let src = LyricsSource(provider: p, trackID: "\(p.rawValue)-1", title: title, artist: artist, duration: duration,
                               confidence: 0.95, matchKind: .metadata, matchQuality: near ? .nearMiss("длительность") : .exact)
        let words = word ? [LyricsCore.LyricWord(text: "раз", begin: 1, end: 1.5), LyricsCore.LyricWord(text: "два", begin: 1.5, end: 2)] : []
        let line = LyricsCore.LyricLine(key: "L1", begin: 1, end: 2, text: "раз два", words: words)
        return LyricsCore.Lyrics(source: src, syncType: word ? .word : .line, lines: [line])
    }

    static func await_<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached { box.v = await op(); sem.signal() }
        while sem.wait(timeout: .now() + 0.02) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return box.v!
    }
    final class Box<T>: @unchecked Sendable { var v: T? }

    static func selection(_ check: Check) {
        let fm = FileManager.default
        let q = LyricsService.Query(artist: "Синтетика", title: "Тёплый ветер", album: "", duration: 200.4)
        func service(_ providers: [any LyricsProvider], creds: CredentialStore = noToken()) -> (LyricsService, URL) {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-sel-\(getpid())-\(UUID().uuidString.prefix(6))")
            return (LyricsService(cacheDir: dir, credentials: creds, providers: providers), dir)
        }
        let apple = AppleMusicProvider(http: NoNetwork(), credentials: noToken())
        let all = Set(LyricsSourceKind.allCases)

        // Apple без токена — пропущен (сети нет вовсе); пословный QQ важнее построчного LRCLIB, хоть LRCLIB и ответил.
        let (s1, d1) = service([apple, Mock(id: .qq, result: [mockLyrics(.qq, word: true)]),
                                Mock(id: .lrclib, result: [mockLyrics(.lrclib, word: false)])])
        let r1 = await_ { await s1.lookup(q, sources: all) }
        check(r1.provider == .qq && r1.lyrics?.wordSynced == true && r1.outcomes.contains { $0.hasPrefix("appleMusic: пропущен") },
              "Выбор: Apple без токена пропущен, пословный важнее построчного", "\(r1.provider?.rawValue ?? "nil") \(r1.outcomes)")
        // Выключенный источник не спрашивается.
        let (s2, d2) = service([apple, Mock(id: .qq, result: [mockLyrics(.qq, word: true)]),
                                Mock(id: .lrclib, result: [mockLyrics(.lrclib, word: false)])])
        defer { try? fm.removeItem(at: d2) }
        let r2 = await_ { await s2.lookup(q, sources: [.lrclib, .apple]) }
        check(r2.provider == .lrclib && r2.lyrics?.synced == true && r2.lyrics?.wordSynced == false
              && !r2.outcomes.isEmpty && !r2.outcomes.contains { $0.hasPrefix("qq") },
              "Выбор: QQ выключен — не спрашивается, построчный LRCLIB", "\(r2.outcomes)")
        // Повтор — из кеша, без опроса.
        let r2b = await_ { await s2.lookup(q, sources: [.lrclib, .apple]) }
        check(r2b.fromCache && r2b.lyrics != nil, "Выбор: повтор — из памяти/кеша", "")
        try? fm.removeItem(at: d1)

        // Чужая версия (Live) у более приоритетного: наш фильтр её отвергает, берём следующий.
        let (s3, d3) = service([Mock(id: .netease, result: [mockLyrics(.netease, word: true, title: "Тёплый ветер (Live)")]),
                                Mock(id: .lrclib, result: [mockLyrics(.lrclib, word: false)])])
        let r3 = await_ { await s3.lookup(q, sources: all) }
        check(r3.provider == .lrclib && r3.rejected.contains { $0.contains("live") },
              "Выбор: чужая версия (live) отвергнута фильтром LyricsMatch", "\(r3.rejected)")
        try? fm.removeItem(at: d3)

        // Только «почти совпадение» (другая длительность) — без текста; длительность ±5 с — тоже нет.
        let (s4, d4) = service([Mock(id: .qq, result: [mockLyrics(.qq, word: true, duration: 230, near: true)]),
                                Mock(id: .kugou, result: [mockLyrics(.kugou, word: true, duration: 205.5)])])
        let r4 = await_ { await s4.lookup(q, sources: all) }
        check(r4.lyrics == nil, "Выбор: почти совпадение и ±5 с — лучше без текста", "\(r4.rejected) \(r4.outcomes)")
        try? fm.removeItem(at: d4)

        // Все источники выключены — ни запроса.
        let (s5, d5) = service([Mock(id: .lrclib, result: [mockLyrics(.lrclib, word: false)])])
        let r5 = await_ { await s5.lookup(q, sources: []) }
        check(r5.lyrics == nil && r5.outcomes.isEmpty, "Выбор: все источники выключены — без поиска", "")
        try? fm.removeItem(at: d5)

        // Токен: сохранить/проверить/удалить (в памяти; Keychain самотест не трогает). Apple с токеном — доступен.
        let store = InMemoryCredentialStore()
        let (s6, d6) = service([], creds: store)
        let ok = await_ { await s6.setAppleToken("  \"abc\"\n") }
        let has = await_ { await s6.hasAppleToken() }
        let saved = await_ { try? await store.value(for: .mediaUserToken) }
        let avail = await_ { await AppleMusicProvider(http: NoNetwork(), credentials: store).isAvailable() }
        _ = await_ { await s6.setAppleToken(nil) }
        let hasAfter = await_ { await s6.hasAppleToken() }
        check(ok && has && saved == "abc" && avail && !hasAfter, "Токен Apple: вставка (обрезка кавычек/пробелов), доступ, удаление",
              "\(has) \(avail) \(hasAfter)")
        try? fm.removeItem(at: d6)
    }

    // MARK: Микробенч

    /// Сколько стоит процессу одна строка пословной заливки: раскладка, картинки слогов, слои и анимации — один раз
    /// на строку (дальше кадры считает сервер отрисовки). Строка в среднем раз в 3–4 с.
    @MainActor
    static func bench(_ check: Check) {
        var words: [LyricWord] = []
        for i in 0..<9 { words.append(LyricWord(text: ["тёплый", "ветер", "над", "ре", "кой", "и", "снова", "до", "мой"][i],
                                                begin: Double(i) * 0.35, end: Double(i) * 0.35 + 0.3, joins: i == 4 || i == 8)) }
        let line = LyricLine(time: 0, text: LyricLine.join(words), end: 3.5, words: words, background: [LyricWord(text: "а-а", begin: 3.2, end: 3.5)])
        let font = NSFont.systemFont(ofSize: 19, weight: .bold)
        let v = LyricsStack()
        let n = 40
        var cpu = 0.0
        for i in 0..<n {
            var l = line; l.text += " \(i)"   // каждая — новая строка (пересборка слоёв)
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            v.update(lyrics: Lyrics(lines: [l]), position: 0, clock: KaraokeClock(timestamp: Date(), elapsed: 0, rate: 1),
                     animated: true, config: cfg(330, 60), font: { _ in font })
            CATransaction.flush()
            cpu += Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e9
        }
        let per = cpu / Double(n)
        let pct = per / 3.5 * 100
        check(per < 0.03, String(format: "Микробенч: строка из 10 слогов — %.2f мс CPU процесса (≈ %.2f %% при строке раз в 3,5 с)", per * 1000, pct),
              "\(v.layers[0]?.nodes.count ?? 0) узлов (слоги + глифы выделенных слов)")
    }
}

// MARK: Потоковый поиск (LyricsCore cd4c949: lyricsUpdates)

extension LyricsCoreSelfTest {
    /// Кто что спросил и у кого поиск отменили (заглушки ниже).
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = [], _cancelled: [String] = []
        func ask(_ t: String) { lock.lock(); _asked.append(t); lock.unlock() }
        func cancel(_ t: String) { lock.lock(); _cancelled.append(t); lock.unlock() }
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
        var cancelled: [String] { lock.lock(); defer { lock.unlock() }; return _cancelled }
    }

    /// Источник-заглушка с задержкой ответа (или ошибкой): порядок промежуточных результатов движка задаётся задержками.
    struct SlowMock: LyricsProvider {
        var id: LyricsProviderID
        var result: [LyricsCore.Lyrics] = []
        var delay: Double
        var error: LyricsError? = nil
        var calls: Calls? = nil
        func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] {
            calls?.ask(query.title)
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) } catch { calls?.cancel(query.title); throw error }
            if let error { throw error }
            return result
        }
    }

    static func plain(_ p: LyricsProviderID) -> LyricsCore.Lyrics {
        var l = mockLyrics(p, word: false)
        l.syncType = .none
        return l
    }

    final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(LyricsSourceKind?, Int, TimeInterval)] = []
        func add(_ u: LyricsService.Lookup) { lock.lock(); list.append((u.provider, u.rank, u.firstTextAfter ?? -1)); lock.unlock() }
        var all: [(LyricsSourceKind?, Int, TimeInterval)] { lock.lock(); defer { lock.unlock() }; return list }
        var text: String { all.map { "\($0.0?.rawValue ?? "?")/\($0.1)" }.joined(separator: " → ") }
    }

    static func streaming(_ check: Check) {
        let fm = FileManager.default
        let q = LyricsService.Query(artist: "Синтетика", title: "Тёплый ветер", album: "", duration: 200.4)
        func service(_ providers: [any LyricsProvider]) -> (LyricsService, URL) {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-stream-\(getpid())-\(UUID().uuidString.prefix(6))")
            return (LyricsService(cacheDir: dir, credentials: noToken(), providers: providers), dir)
        }
        func json(_ dir: URL) -> Int { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.count }

        // 1. Порядок замены: простой LRCLIB (0,05 с) → построчный NetEase (0,3) → построчный AMLL (0,45, приоритетнее, но
        //    не лучше — не заменяем) → пословный KuGou «Live» (0,6, отвергнут фильтром) → пословный QQ (0,9).
        let (s1, d1) = service([
            SlowMock(id: .amll, result: [mockLyrics(.amll, word: false)], delay: 0.45),
            SlowMock(id: .netease, result: [mockLyrics(.netease, word: false)], delay: 0.3),
            SlowMock(id: .qq, result: [mockLyrics(.qq, word: true)], delay: 0.9),
            SlowMock(id: .kugou, result: [mockLyrics(.kugou, word: true, title: "Тёплый ветер (Live)")], delay: 0.6),
            SlowMock(id: .lrclib, result: [plain(.lrclib)], delay: 0.05),
        ])
        let u1 = Updates()
        let r1 = await_ { await s1.lookup(q, sources: Set(LyricsSourceKind.allCases)) { u1.add($0) } }
        let seq = u1.all.map { "\($0.0?.rawValue ?? "?")/\($0.1)" }
        check(seq == ["lrclib/0", "netease/1", "qq/2"] && r1.provider == .qq && r1.lyrics?.wordSynced == true && r1.upgrades == 2
              && r1.rejected.contains { $0.hasPrefix("kugou/word") && $0.contains("live") },
              "Поток: замена только на лучший (простой → построчный → пословный), «Live» отвергнут, равный не заменяет",
              u1.text + " | отвергнуто: \(r1.rejected)")
        check((r1.firstTextAfter ?? 9) < 0.3 && r1.complete, "Поток: первый текст — сразу, не по итогу",
              String(format: "первый %.2f с, весь %.2f с", r1.firstTextAfter ?? -1, r1.seconds))
        try? fm.removeItem(at: d1)

        // 2. Пословный пришёл первым, построчный приоритетнее — позже: показанный пословный не заменяется.
        let (s2, d2) = service([SlowMock(id: .netease, result: [mockLyrics(.netease, word: false)], delay: 0.3),
                                SlowMock(id: .qq, result: [mockLyrics(.qq, word: true)], delay: 0.05)])
        let u2 = Updates()
        let r2 = await_ { await s2.lookup(q, sources: Set(LyricsSourceKind.allCases)) { u2.add($0) } }
        check(u2.all.count == 1 && r2.provider == .qq && r2.lyrics?.wordSynced == true,
              "Поток: пословный не меняется на построчный более приоритетного", u2.text)
        try? fm.removeItem(at: d2)

        // 3. Отмена: читатель потока отменён — источник отменён, кеш не записан, обновлений нет.
        let calls3 = Calls()
        let (s3, d3) = service([SlowMock(id: .qq, result: [mockLyrics(.qq, word: true)], delay: 1.5, calls: calls3)])
        let u3 = Updates()
        let reader = Task.detached { for await u in s3.updates(q) { u3.add(u) } }
        let t3 = Date()
        while Date().timeIntervalSince(t3) < 0.25 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        reader.cancel()
        while calls3.cancelled.isEmpty && Date().timeIntervalSince(t3) < 2 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        let cancelledAfter = Date().timeIntervalSince(t3)
        while Date().timeIntervalSince(t3) < 1.8 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        check(calls3.cancelled == ["Тёплый ветер"] && u3.all.isEmpty && json(d3) == 0,
              "Поток: отмена читателя отменяет поиск источника, кеш не пишется",
              String(format: "отменён через %.2f с, обновлений %d, файлов %d", cancelledAfter, u3.all.count, json(d3)))
        try? fm.removeItem(at: d3)

        // 4. Сбой источника и пусто — «не найдено» не запоминаем (ни в памяти, ни на диске): следующий поиск спрашивает снова.
        let calls4 = Calls()   // только упавший QQ (успешный пустой ответ LRCLIB движок помнит ~10 мин сам)
        let (s4, d4) = service([SlowMock(id: .qq, delay: 0.02, error: .network("таймаут запроса"), calls: calls4),
                                SlowMock(id: .lrclib, delay: 0.02)])
        let r4 = await_ { await s4.lookup(q) }
        let r4b = await_ { await s4.lookup(q) }
        check(r4.lyrics == nil && r4.hadFailures && !r4.offline && !r4b.fromCache && r4b.hadFailures && calls4.asked.count == 2 && json(d4) == 0,
              "Сбой + ничего не нашли: «не найдено» не кешируется", "запросов \(calls4.asked.count), файлов \(json(d4))")
        try? fm.removeItem(at: d4)

        // 5. Нет сети у всех — тихо: offline, ни ошибок, ни записи; повтор спрашивает снова.
        let calls5 = Calls()
        let (s5, d5) = service([SlowMock(id: .qq, delay: 0.02, error: .offline, calls: calls5),
                                SlowMock(id: .lrclib, delay: 0.02, error: .offline, calls: calls5)])
        let r5 = await_ { await s5.lookup(q) }
        let r5b = await_ { await s5.lookup(q) }
        check(r5.lyrics == nil && r5.offline && r5b.offline && calls5.asked.count == 4 && json(d5) == 0,
              "Нет сети: тихо (offline), не запоминается", "запросов \(calls5.asked.count)")
        try? fm.removeItem(at: d5)

        // 6. Чистое «не найдено» (все ответили) — запоминается: повтор без запросов.
        let calls6 = Calls()
        let (s6, d6) = service([SlowMock(id: .lrclib, delay: 0.02, calls: calls6)])
        _ = await_ { await s6.lookup(q) }
        let r6b = await_ { await s6.lookup(q) }
        check(r6b.fromCache && calls6.asked.count == 1, "«Не найдено» без сбоев — запоминается", "запросов \(calls6.asked.count)")
        try? fm.removeItem(at: d6)

        // 7. AMLL без длительности записи (source.duration = nil с cd4c949): по метаданным не отвергается, текст длиннее
        //    трека на 20+ с — отвергается.
        var am = mockLyrics(.amll, word: true, title: "Numb", artist: "Linkin Park")
        am.source.duration = nil
        let numb = LyricsService.Query(artist: "Linkin Park", title: "Numb", album: "Meteora", duration: 185.6)
        var amLong = am
        amLong.lines[0].end = 230
        check(LyricsService.rejectReason(am, query: numb) == nil && LyricsService.rejectReason(amLong, query: numb) != nil,
              "AMLL: без длительности записи «Numb» принят, текст длиннее трека — нет",
              LyricsService.rejectReason(amLong, query: numb) ?? "")
    }

    /// Смена трека в модели: поиск прежнего отменяется, его текст не показывается; новый поиск идёт; возврат — текст приходит.
    @MainActor
    static func trackChange(_ check: Check) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-lyrics-switch-\(getpid())")
        defer { try? fm.removeItem(at: dir) }
        let calls = Calls()
        let svc = LyricsService(cacheDir: dir, credentials: noToken(),
                                providers: [SlowMock(id: .qq, result: [mockLyrics(.qq, word: true)], delay: 0.8, calls: calls)])
        let model = MediaModel()
        model.lyricsService = svc
        var prefs = MediaPrefs(); prefs.lyricsEnabled = true
        model.prefs = prefs
        func spin(_ t: TimeInterval, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(t)
            while Date() < end && !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        var a = NowPlaying(title: "Тёплый ветер"); a.artist = "Синтетика"; a.bundleId = MediaApps.music
        a.isPlaying = true; a.duration = 200.4; a.artworkId = "sw-a"
        if let jpeg = MediaSelfTest.coverJPEG(3, side: 64) { model.ingestArtwork(id: "sw-a", data: jpeg) }
        model.simulateMediaRemote(a)
        spin(1) { calls.asked.contains("Тёплый ветер") }
        var b = a; b.title = "Другая песня"
        model.simulateMediaRemote(b)
        spin(2) { calls.cancelled.contains("Тёплый ветер") }
        spin(1.5) { calls.asked.contains("Другая песня") && model.lyrics != nil }
        let aKey = LyricsService.cacheKey(.init(artist: a.artist, title: a.title, album: "", duration: a.duration))
        check(calls.cancelled.contains("Тёплый ветер") && calls.asked.contains("Другая песня") && model.lyrics == nil
              && svc.cache.load(key: aKey) == nil,
              "Смена трека: поиск прежнего отменён, чужой текст не показан, кеш прежнего не записан",
              "спрошено \(calls.asked), отменено \(calls.cancelled)")
        model.simulateMediaRemote(a)
        spin(2.5) { model.lyrics != nil }
        check(model.lyrics?.wordSynced == true, "Смена трека: вернулись — текст пришёл потоком в модель", "")
        model.stop()
    }
}
