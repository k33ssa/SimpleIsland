import Foundation

/// Сопоставление трека плеера с записью LRCLIB: нормализация названий и исполнителей, допуск по длительности,
/// оценка кандидата и отказ при плохом совпадении («лучше без текста, чем чужой»).
/// Логика — по образцу `apple-music-native-lyrics` (LyricsCore/Matching), упрощённо. С 15.11 поиск ведёт LyricsCore
/// (`LyricsService`), а это — второй фильтр поверх его выбора: пометки версии (live/remix/…), название, исполнитель.
enum LyricsMatch {
    /// Допуск по длительности: как у самого LRCLIB `/api/get` (целые секунды, ±2).
    static let durationTolerance: Double = 2

    // MARK: Нормализация

    /// Регистр, диакритика (ё → е, й → и), ширина, `&` → `and`, пунктуация → пробел, схлопнутые пробелы.
    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        var out = ""
        var space = true
        for ch in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                space = false
            } else if !space {
                out.append(" ")
                space = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Латиница: «Кино» → «kino», «Zемфира» (смешанные буквы) → «zemfira». Для сравнения кириллицы с латиницей.
    static func latin(_ folded: String) -> String {
        guard folded.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return folded }
        let t = folded.applyingTransform(.toLatin, reverse: false) ?? folded
        return fold(t)
    }

    // MARK: Название

    struct Title: Equatable {
        /// Основа названия (нормализованная), без пометок версии и feat.
        var base: String
        /// Основа как написано — для запросов в LRCLIB.
        var display: String
        /// Значимые пометки (другая запись: live, remix, acoustic…).
        var significant: Set<String>
        /// Приглашённые исполнители из названия (нормализованные).
        var featured: [String]
    }

    /// Значимые пометки: другой текст/тайминг. Ключ — тег, значения — слова (после `fold`).
    private static let significantRules: [(String, [String])] = [
        ("live", ["live", "concert", "unplugged", "концерт", "живое", "live version", "ao vivo", "en vivo"]),
        ("remix", ["remix", "rmx", "rework", "bootleg", "club mix", "dub mix", "ремикс", "vip mix", "flip"]),
        ("acoustic", ["acoustic", "акустика", "акустическая", "акустическая версия"]),
        ("instrumental", ["instrumental", "inst", "off vocal", "инструментал", "минус", "без слов"]),
        ("karaoke", ["karaoke", "караоке"]),
        ("demo", ["demo", "демо", "early version", "rough mix"]),
        ("speed", ["sped up", "speed up", "slowed", "slowed reverb", "nightcore", "ускоренная", "замедленная", "8d audio"]),
        ("cover", ["cover", "кавер", "tribute"]),
        ("extended", ["extended", "extended mix", "extended version", "long version", "расширенная"]),
    ]

    /// Второстепенные пометки: тот же текст и почти тот же тайминг (длительность всё равно проверяется).
    private static let minorWords: [String] = [
        "remaster", "remastered", "remastering", "digitally remastered", "ремастер", "ремастеринг", "remasterizado",
        "explicit", "clean", "censored", "ненормативная лексика", "deluxe", "expanded", "anniversary", "bonus track",
        "special edition", "делюкс", "mono", "stereo", "album version", "original version", "original mix",
        "single version", "radio edit", "radio version", "edit", "version", "версия", "original", "оригинал",
        "soundtrack", "ost", "from the motion picture", "from the film", "саундтрек", "edition", "mix", "remix 2",
        "mixed", "mastered", "bonus", "mtv", "hd", "hq", "official", "audio",
    ]

    private static let featPrefixes = ["feat.", "feat ", "featuring ", "ft.", "ft ", "with ", "при участии ", "при уч. ", "совместно с "]

    /// Разбор названия: вырезает « - Remastered 2011», «(feat. …)», «[Explicit]», «(Live)» и т. п.
    static func parseTitle(_ title: String) -> Title {
        var significant = Set<String>()
        var featured: [String] = []
        // 1. Группы в скобках.
        var kept = ""
        var i = title.startIndex
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "【": "】", "（": "）"]
        while i < title.endIndex {
            let ch = title[i]
            if let close = pairs[ch], let j = title[title.index(after: i)...].firstIndex(of: close) {
                let inner = String(title[title.index(after: i)..<j])
                if !classify(inner, significant: &significant, featured: &featured) { kept += String(title[i...j]) }
                i = title.index(after: j)
                continue
            }
            kept.append(ch)
            i = title.index(after: i)
        }
        // 2. Хвост « - …» (несколько: «Song - Live - 2011 Remaster»).
        var changed = true
        while changed {
            changed = false
            for sep in [" - ", " – ", " — ", " / "] {
                if let r = kept.range(of: sep, options: .backwards) {
                    let tail = String(kept[r.upperBound...])
                    if classify(tail, significant: &significant, featured: &featured) {
                        kept = String(kept[..<r.lowerBound]); changed = true
                        break
                    }
                }
            }
        }
        // 3. feat. без скобок: «Song feat. X».
        let lower = kept.lowercased()
        for m in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let r = lower.range(of: m) {
                let cut = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let start = lower.distance(from: lower.startIndex, to: r.upperBound)
                featured += splitArtists(String(kept.dropFirst(start)))
                kept = String(kept.prefix(cut))
                break
            }
        }
        let display = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = fold(display)
        return Title(base: base.isEmpty ? fold(title) : base, display: display.isEmpty ? title : display,
                     significant: significant, featured: featured)
    }

    /// `true` — группа служебная (feat., версия, год), её нужно вырезать из основы названия.
    private static func classify(_ group: String, significant: inout Set<String>, featured: inout [String]) -> Bool {
        let raw = group.trimmingCharacters(in: .whitespaces)
        let lower = raw.lowercased()
        for p in featPrefixes where lower.hasPrefix(p) {
            featured += splitArtists(String(raw.dropFirst(p.count)))
            return true
        }
        let f = fold(raw)
        if f.isEmpty { return true }
        let words = f.split(separator: " ").map(String.init)
        // «2011», «2011 Remaster», «Remastered 2009» — годы и цифры не мешают.
        let meaningful = words.filter { !$0.allSatisfy(\.isNumber) }
        if meaningful.isEmpty { return words.count <= 2 && f.count <= 9 }
        var found = Set<String>()
        for (tag, kws) in significantRules where kws.contains(where: { has(f, words, $0) }) { found.insert(tag) }
        let minor = minorWords.contains { has(f, words, $0) }
        if found.isEmpty && !minor { return false }
        // Длинная фраза со словом «version»/«mix» — скорее часть названия, чем пометка.
        if found.isEmpty && meaningful.count > 4 { return false }
        significant.formUnion(found)
        return true
    }

    private static func has(_ folded: String, _ words: [String], _ kw: String) -> Bool {
        let k = fold(kw)
        guard !k.isEmpty else { return false }
        if k.contains(" ") { return " \(folded) ".contains(" \(k) ") }
        // Слово целиком (с допуском окончаний: remastered, remixed).
        return words.contains { $0 == k || (k.count >= 4 && $0.hasPrefix(k) && $0.count - k.count <= 2) }
    }

    // MARK: Исполнители

    private static let artistSeparators = [",", ";", "/", "&", " x ", " × ", " and ", " и ", " feat. ", " feat ", " ft. ",
                                           " ft ", " featuring ", " with ", " vs. ", " vs ", " + "]

    /// Имена как написаны: «A & B feat. C» → [A, B, C].
    static func splitArtistsRaw(_ s: String) -> [String] {
        var parts = [s]
        for sep in artistSeparators {
            parts = parts.flatMap { p -> [String] in
                guard sep.hasPrefix(" ") else { return p.components(separatedBy: sep) }
                var out: [String] = []
                var rest = p[...]
                while let r = rest.range(of: sep, options: .caseInsensitive) {
                    out.append(String(rest[..<r.lowerBound])); rest = rest[r.upperBound...]
                }
                out.append(String(rest))
                return out
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func splitArtists(_ s: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in splitArtistsRaw(s) {
            let f = fold(p)
            if !f.isEmpty, seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    /// Основной исполнитель — для запросов («Кино & Виктор Цой» → «Кино»).
    static func primaryArtist(_ s: String) -> String { splitArtistsRaw(s).first ?? s }

    // MARK: Сходство

    /// Сходство 0…1 нормализованных строк (с латиницей: «кино» ~ «kino»).
    static func similarity(_ a: String, _ b: String) -> Double {
        let direct = rawSimilarity(a, b)
        if direct >= 1 { return 1 }
        let la = latin(a), lb = latin(b)
        if la == a && lb == b { return direct }
        return max(direct, rawSimilarity(la, lb) * 0.98)
    }

    private static func rawSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        var best = levenshteinRatio(a, b)
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        if !ta.isEmpty && !tb.isEmpty {
            best = max(best, 2 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count))
        }
        // Одна строка внутри другой по границам слов: «love» в «love story» — 0,66, не совпадение.
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 3, " \(long) ".contains(" \(short) ") {
            best = max(best, 0.5 + 0.4 * Double(short.count) / Double(long.count))
        }
        return min(best, 0.99)
    }

    static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Оценка кандидата

    struct Candidate: Equatable, Sendable {
        var id: Int = 0
        var title: String
        var artist: String
        var album: String = ""
        var duration: Double = 0
        var instrumental = false
        var synced: String?
        var plain: String?

        var hasSynced: Bool { !(synced?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        var hasPlain: Bool { !(plain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    struct Evaluation: Equatable {
        var score: Double
        var title: Double
        var artist: Double
        /// Расхождение длительностей, с (nil — у одной из сторон её нет).
        var durationDelta: Double?
        var accepted: Bool
        var reason: String?
    }

    /// `durationTolerance` — допуск длительности (LRCLIB ±2 с; фильтр поверх LyricsCore — ±3 с, как у его QQ/KuGou/AMLL).
    static func evaluate(_ q: LyricsService.Query, _ c: Candidate, durationTolerance tol: Double = durationTolerance) -> Evaluation {
        let qt = parseTitle(q.title), ct = parseTitle(c.title)
        let title = max(similarity(qt.base, ct.base), similarity(fold(q.title), fold(c.title)))
        var qa = splitArtists(q.artist); for f in qt.featured where !qa.contains(f) { qa.append(f) }
        var ca = splitArtists(c.artist); for f in ct.featured where !ca.contains(f) { ca.append(f) }
        var artist = similarity(fold(q.artist), fold(c.artist))
        // Любой из исполнителей запроса нашёлся у кандидата («A & B» ~ «A»): основной — полностью, гость — чуть меньше.
        for (k, a) in qa.enumerated() {
            let best = ca.map { similarity(a, $0) }.max() ?? 0
            artist = max(artist, k == 0 ? best : best * 0.9)
        }
        var delta: Double?
        if q.duration >= 1, c.duration > 0 { delta = abs(q.duration.rounded() - c.duration.rounded()) }
        var versionMismatch = qt.significant.symmetricDifference(ct.significant)
        // Концертный альбом («Маленький человек. Live») при студийном в запросе — другая запись, даже если в названии
        // трека пометки нет (15.11, сеть: «Земфира — Искала» 239 с подбиралась из live-альбома 237 с).
        if !q.album.isEmpty, !c.album.isEmpty {
            let qal = albumTags(q.album), cal = albumTags(c.album)
            if qal.contains("live") != cal.contains("live") { versionMismatch.insert("live") }
        }
        let durScore = delta.map { max(0, 1 - $0 / 10) } ?? 0.5
        var albumBonus = 0.0
        if !q.album.isEmpty, !c.album.isEmpty, similarity(parseTitle(q.album).base, parseTitle(c.album).base) >= 0.9 {
            albumBonus = 0.03
        }
        let score = min(1, 0.5 * title + 0.35 * artist + 0.15 * durScore + albumBonus)

        // Без длительности версию проверить нечем — пороги строже.
        let minTitle = delta == nil ? 0.92 : 0.8
        let minArtist = delta == nil ? 0.85 : 0.6
        var reason: String?
        if let d = delta, d > tol { reason = "длительность ±\(Int(d)) с" }
        else if !versionMismatch.isEmpty { reason = "другая версия: \(versionMismatch.sorted().joined(separator: ", "))" }
        else if title < minTitle { reason = String(format: "название %.2f", title) }
        else if artist < minArtist { reason = String(format: "исполнитель %.2f", artist) }
        else if !c.hasSynced && !c.hasPlain && !c.instrumental { reason = "без текста" }
        return Evaluation(score: score, title: title, artist: artist, durationDelta: delta, accepted: reason == nil,
                          reason: reason)
    }

    /// Пометки альбома: концертный ли он. «Маленький человек. Live (Disc 2)», «MTV Unplugged», «Live at Wembley»,
    /// «Концерт в Олимпийском» — да; «Live Through This» (студийный) — нет: слово live должно стоять последним
    /// (после снятия «Disc 2», «CD1», годов) или в связке «live at/in», либо быть явной пометкой в скобках.
    static func albumTags(_ album: String) -> Set<String> {
        var t = parseTitle(album).significant.intersection(["live"])
        var words = fold(album).split(separator: " ").map(String.init)
        while let w = words.last, w.allSatisfy(\.isNumber) || ["disc", "cd", "vol", "диск", "часть", "pt", "part"].contains(w)
                || w.hasPrefix("cd") && w.dropFirst(2).allSatisfy(\.isNumber) {
            words.removeLast()
        }
        let joined = " " + words.joined(separator: " ") + " "
        if words.last == "live" || words.last == "unplugged" || joined.contains(" live at ") || joined.contains(" live in ")
            || joined.contains(" концерт") || joined.contains(" unplugged ") {
            t.insert("live")
        }
        return t
    }

    /// Лучший кандидат: принятые; синхронный текст важнее простого; дальше — score и близость длительности.
    /// nil — подходящего нет (чужой текст не показываем).
    static func best(_ q: LyricsService.Query, _ cands: [Candidate]) -> (Candidate, Evaluation)? {
        let ok = cands.map { ($0, evaluate(q, $0)) }.filter { $0.1.accepted }
        func rank(_ c: Candidate) -> Int { c.hasSynced ? 2 : (c.hasPlain ? 1 : 0) }
        return ok.max { a, b in
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            if abs(a.1.score - b.1.score) > 0.001 { return a.1.score < b.1.score }
            return (a.1.durationDelta ?? 99) > (b.1.durationDelta ?? 99)
        }
    }
}
