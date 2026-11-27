import Foundation

/// Слово или слог с таймингом (пословный текст: TTML, YRC, QRC, KRC, Enhanced LRC — через LyricsCore).
struct LyricWord: Equatable, Sendable {
    var text: String
    var begin: Double
    var end: Double
    /// Продолжение предыдущего слова без пробела (слог, знак препинания, CJK).
    var joins = false

    var duration: Double { max(0, end - begin) }
    /// Доля заливки слова в момент `t` (0…1): слово заполняется слева направо ровно за своё время.
    func progress(at t: Double) -> Double {
        guard end > begin else { return t >= begin ? 1 : 0 }
        return min(1, max(0, (t - begin) / (end - begin)))
    }
}

/// Строка текста песни.
struct LyricLine: Equatable, Sendable {
    var time: Double
    var text: String
    /// Конец строки по источнику (nil — до следующей строки).
    var end: Double? = nil
    /// Слова/слоги основного вокала (пусто — построчная заливка).
    var words: [LyricWord] = []
    /// Фоновый вокал (бэк-вокал): слова мельче и тусклее основного.
    var background: [LyricWord] = []

    init(time: Double, text: String, end: Double? = nil, words: [LyricWord] = [], background: [LyricWord] = []) {
        self.time = time
        self.text = text
        self.end = end
        self.words = words
        self.background = background
    }

    var isWordSynced: Bool { !words.isEmpty }
    /// Текст фонового вокала (для статичного показа).
    var backgroundText: String { LyricLine.join(background) }

    static func join(_ w: [LyricWord]) -> String {
        var s = ""
        for (i, x) in w.enumerated() { if i > 0 && !x.joins { s += " " }; s += x.text }
        return s
    }

    func shifted(by d: Double) -> LyricLine {
        func sh(_ w: [LyricWord]) -> [LyricWord] { w.map { LyricWord(text: $0.text, begin: $0.begin + d, end: $0.end + d, joins: $0.joins) } }
        return LyricLine(time: time + d, text: text, end: end.map { $0 + d }, words: sh(words), background: sh(background))
    }
}

/// Текст песни: синхронный (LRC — строки со временем) или простой (без таймингов: караоке не показываем,
/// строки не «едут» — не делаем вид, что синхронно).
struct Lyrics: Equatable, Sendable {
    var lines: [LyricLine]
    /// false — простой текст: `time` у строк не значит ничего, `index`/`nextChange` — nil.
    var synced: Bool = true
    /// Откуда текст (имя источника каскада: «QQ Музыка», «LRCLIB»…) — для диагностики и подписи.
    var source: String? = nil

    /// Есть пословная разметка (хоть у одной строки).
    var wordSynced: Bool { synced && lines.contains { $0.isWordSynced } }

    /// Индекс строки, которая звучит в момент `t` (nil — до первой строки или текст без таймингов).
    func index(at t: Double) -> Int? {
        guard synced, let first = lines.first, t >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Доля пройденного в строке `i` (0…1) — для «караоке»-заливки.
    func progress(of i: Int, at t: Double, duration: Double) -> Double {
        guard synced, lines.indices.contains(i) else { return 0 }
        return min(1, max(0, (t - lines[i].time) / span(of: i, duration: duration)))
    }

    /// За сколько секунд трека строка `i` заливается целиком.
    func span(of i: Int, duration: Double) -> Double {
        guard lines.indices.contains(i) else { return 1 }
        let start = lines[i].time
        var end = i + 1 < lines.count ? lines[i + 1].time : (duration > start ? duration : start + 4)
        // Конец строки из источника (TTML/YRC/LRC LyricsCore) — если раньше следующей: заливка не тянется в паузу.
        if let e = lines[i].end, e > start + 0.2 { end = min(end, e) }
        // Длинные проигрыши: строку «допеваем» не дольше 6 с, дальше она просто горит целиком.
        return max(0.5, min(end - start, 6))
    }

    /// Когда сменится строка после момента `t` (для одного таймера вместо опроса).
    func nextChange(after t: Double) -> Double? {
        guard synced else { return nil }
        return lines.first { $0.time > t }?.time
    }

    /// Тот же текст, сдвинутый на `d` секунд позже (поправка на задержку вывода звука).
    func shifted(by d: Double) -> Lyrics {
        guard synced, d != 0 else { return self }
        return Lyrics(lines: lines.map { $0.shifted(by: d) }, synced: true, source: source)
    }

    /// Первые непустые строки простого текста (показ без таймингов).
    func plainExcerpt(_ n: Int) -> [String] {
        Array(lines.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(n))
    }
}

enum LRC {
    /// Разбор LRC: `[мм:сс.хх] текст`, несколько меток на строке, `[offset:±мс]` (на весь текст, где бы ни стоял),
    /// `[мм:сс:хх]` (сотые через двоеточие), пословные метки `<мм:сс.хх>` вырезаются, служебные теги (`[ar:…]`)
    /// и строки без метки пропускаются; пустые строки с меткой остаются — это проигрыш.
    static func parse(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var offset: Double = 0
        for raw in s.split(whereSeparator: \.isNewline) {
            var line = Substring(raw).drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let t = parseTime(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)
                                          .replacingOccurrences(of: "+", with: "")) {
                    offset = ms / 1000
                }
                line = line[line.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            }
            guard !times.isEmpty else { continue }
            let text = stripWordTags(String(line)).trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(time: t, text: text)) }
        }
        // Положительный offset — текст раньше (стандарт LRC).
        if offset != 0 { out = out.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) } }
        // Стабильная сортировка: строки с одинаковым временем — в порядке файла.
        return out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// Простой текст (без таймингов): строки как есть; LRC-метки, если попались, вырезаются.
    static func plain(_ s: String) -> [LyricLine] {
        s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { raw in
            var line = Substring(raw)
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") { line = line[line.index(after: close)...] }
            return LyricLine(time: 0, text: stripWordTags(String(line)).trimmingCharacters(in: .whitespaces))
        }
    }

    /// `<00:12.34>слово` — пословная разметка (enhanced LRC): метки убрать, текст оставить.
    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            if let close = rest[open...].firstIndex(of: ">"), parseTime(rest[rest.index(after: open)..<close]) != nil {
                rest = rest[rest.index(after: close)...]
            } else {
                out.append("<"); rest = rest[rest.index(after: open)...]
            }
        }
        out += rest
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    /// `мм:сс(.хх)`, `ч:мм:сс.хх`, `мм:сс:хх` (последнее — сотые, если в последней части нет точки и она двузначная).
    static func parseTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let nums = parts.map { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        guard nums.allSatisfy({ $0 != nil }) else { return nil }
        let v = nums.compactMap { $0 }
        guard v.allSatisfy({ $0 >= 0 }) else { return nil }
        if v.count == 2 { return v[0] * 60 + v[1] }
        let last = parts[2]
        if !last.contains(".") && !last.contains(","), last.count <= 3, v[1] < 60 {
            // [мм:сс:хх] — хх сотые (или тысячные, если три цифры).
            return v[0] * 60 + v[1] + v[2] / pow(10, Double(last.count))
        }
        return v[0] * 3600 + v[1] * 60 + v[2]
    }
}

/// Синхронизация текста с тем, что слышно.
enum LyricsSync {
    /// Плееры на AVFoundation сами учитывают задержку вывода в позиции, которую отдают в Now Playing
    /// (догадка по устройству AVPlayer: его часы идут от аудиоустройства с учётом задержки — не проверено замером).
    static let selfCompensating: Set<String> = [
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX", "com.apple.Safari",
    ]

    /// Строка входит чуть раньше своей метки LRC: смена строки анимируется (затухание 0,25 с), и без упреждения
    /// новая строка проявлялась бы уже после начала пения — «текст не успевает» (15.11). Как в Музыке: `animationHeadstart`
    /// 0,1 с (спека SimpleLyrics; было 0,15 до 16.11) — и смена строки, и заливка слогов идут на 0,1 с раньше.
    static let lineLead: Double = 0.1

    /// Итоговый сдвиг строк (с, плюс — позже): задержка вывода минус упреждение.
    static func offset(bundleId: String?, outputLatency: Double?) -> Double {
        delay(bundleId: bundleId, outputLatency: outputLatency) - lineLead
    }

    /// На сколько секунд сдвинуть строки позже: позиция плеера опережает звук в ушах на задержку вывода
    /// (Bluetooth 0,1–0,3 с, AirPlay до 2 с). Меньше 30 мс — не трогаем; больше 3 с — не верим.
    static func delay(bundleId: String?, outputLatency: Double?) -> Double {
        guard let l = outputLatency, l.isFinite, l >= 0.03 else { return 0 }
        if let b = bundleId, selfCompensating.contains(b) { return 0 }
        return min(l, 3)
    }
}
