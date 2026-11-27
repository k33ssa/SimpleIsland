import Foundation

/// Теги версии трека. Значимые меняют сам текст/тайминг (live, remix…), второстепенные — почти нет (remaster).
public enum VersionTag: String, Sendable, CaseIterable, Codable {
    case live, remix, acoustic, instrumental, demo, radioEdit, extended, karaoke, cover, speedChanged, reprise
    case remaster, deluxe, explicit, clean, mono, stereo, albumVersion, soundtrack

    /// Значимое различие — другая запись, тексту и времени доверять нельзя.
    public var isSignificant: Bool {
        switch self {
        case .live, .remix, .acoustic, .instrumental, .demo, .radioEdit, .extended, .karaoke, .cover, .speedChanged, .reprise:
            return true
        default:
            return false
        }
    }
}

public enum TextNormalizer {
    public struct ParsedTitle: Sendable, Equatable {
        /// Основа названия в нормализованном виде (без распознанных пометок версии и feat.).
        public var base: String
        /// Основа названия с исходным регистром — для запросов в API (без пометок версии и feat.).
        public var display: String
        public var tags: Set<VersionTag>
        /// Приглашённые исполнители (нормализованные).
        public var featured: [String]
        /// Исходные тексты вырезанных пометок — для отладки и показа.
        public var qualifiers: [String]
    }

    // MARK: fold

    /// Регистр, диакритика, ширина символов, `&` → `and`, пунктуация → пробел, схлопнутые пробелы.
    /// Буквы «ё/й» превращаются в «е/и» (диакритика) — для сравнения это допустимо.
    public static func fold(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        var out = ""
        var prevSpace = true
        for ch in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || isCJKLike(ch) {
                out.unicodeScalars.append(ch)
                prevSpace = false
            } else if !prevSpace {
                out.append(" ")
                prevSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    private static func isCJKLike(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    // MARK: заголовок

    private static let qualifierRules: [(VersionTag, [String])] = [
        (.live, ["live", "concert", "unplugged", "mtv", "ライブ", "ライヴ", "现场", "現場", "演唱会", "живое", "концерт", "в живую", "en vivo", "en direct", "dal vivo", "ao vivo"]),
        (.remaster, ["remaster", "remastered", "remastering", "digitally remastered", "リマスター", "重制", "ремастер", "remasterizado"]),
        (.remix, ["remix", "rmx", "mix by", "rework", "bootleg", "club mix", "dub mix", "リミックス", "混音", "ремикс", "flip", "vip mix", "edit by"]),
        (.acoustic, ["acoustic", "акустика", "акустическая", "アコースティック", "原声", "unplugged version"]),
        (.instrumental, ["instrumental", "inst.", "off vocal", "karaoke version", "инструментал", "インスト", "伴奏", "纯音乐", "без слов"]),
        (.karaoke, ["karaoke", "караоке", "カラオケ"]),
        (.demo, ["demo", "демо", "デモ", "early version", "rough mix"]),
        (.radioEdit, ["radio edit", "radio version", "single edit", "short version", "edit", "radio mix", "clean edit"]),
        (.extended, ["extended", "long version", "full version", "12\" version", "12 inch", "extended mix", "расширенная"]),
        (.cover, ["cover", "tribute", "翻唱", "カバー", "кавер"]),
        (.speedChanged, ["sped up", "speed up", "slowed", "reverb", "nightcore", "8d audio", "pitched", "chopped", "ускоренная", "замедленная"]),
        (.reprise, ["reprise", "репризa", "реприза"]),
        (.deluxe, ["deluxe", "expanded", "anniversary", "bonus track", "special edition", "collector", "super deluxe", "デラックス", "делюкс"]),
        (.explicit, ["explicit", "ненормативная"]),
        (.clean, ["clean", "censored"]),
        (.mono, ["mono"]),
        (.stereo, ["stereo"]),
        (.albumVersion, ["album version", "original version", "original mix", "album mix", "single version", "original", "оригинал", "オリジナル", "version"]),
        (.soundtrack, ["soundtrack", "ost", "from the motion picture", "from the film", "original motion picture", "саундтрек", "from the movie", "original score"]),
    ]

    private static let featMarkers = ["feat.", "feat ", "featuring", "ft.", "ft ", "with ", "w/ ", "при участии", "при уч.", "совместно с", "con ", "avec "]

    private static func matchesKeyword(_ foldedGroup: String, _ kw: String) -> Bool {
        let k = fold(kw)
        guard !k.isEmpty else { return false }
        if k.unicodeScalars.contains(where: { isCJKLike($0) }) { return foldedGroup.contains(k) }
        // слово целиком (с допуском окончаний remastered/remixed)
        let tokens = foldedGroup.split(separator: " ").map(String.init)
        if k.contains(" ") { return " \(foldedGroup) ".contains(" \(k) ") }
        return tokens.contains { $0 == k || ($0.hasPrefix(k) && ($0.count - k.count) <= 2 && k.count >= 4) }
    }

    /// Разбирает название: вытаскивает feat., пометки версии из скобок и из хвоста « - Remastered 2011».
    public static func parseTitle(_ title: String) -> ParsedTitle {
        var tags = Set<VersionTag>()
        var featured: [String] = []
        var qualifiers: [String] = []

        // 1. группы в скобках
        var kept = ""
        var i = title.startIndex
        let openers: [Character: Character] = ["(": ")", "[": "]", "（": "）", "【": "】", "{": "}"]
        while i < title.endIndex {
            let ch = title[i]
            if let closer = openers[ch], let j = title[title.index(after: i)...].firstIndex(of: closer) {
                let inner = String(title[title.index(after: i)..<j])
                if classify(inner, tags: &tags, featured: &featured) {
                    qualifiers.append(inner.trimmingCharacters(in: .whitespaces))
                } else {
                    kept += String(title[i...j])
                }
                i = title.index(after: j)
                continue
            }
            kept.append(ch)
            i = title.index(after: i)
        }

        // 2. хвост « - …» / « – …» / « — …»
        for sep in [" - ", " – ", " — "] {
            if let r = kept.range(of: sep, options: .backwards) {
                let tail = String(kept[r.upperBound...])
                if classify(tail, tags: &tags, featured: &featured, tailMode: true) {
                    qualifiers.append(tail.trimmingCharacters(in: .whitespaces))
                    kept = String(kept[..<r.lowerBound])
                    break
                }
            }
        }

        // 3. feat. без скобок: «Song feat. X»
        let lower = kept.lowercased()
        for m in [" feat. ", " feat ", " ft. ", " featuring ", " ft "] {
            if let r = lower.range(of: m) {
                let nameStart = kept.index(kept.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))
                let names = String(kept[nameStart...])
                featured.append(contentsOf: splitArtists(names))
                qualifiers.append("feat. " + names)
                kept = String(kept[..<kept.index(kept.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
                break
            }
        }

        var base = fold(kept)
        if base.isEmpty { base = fold(title) }
        let display = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTitle(base: base, display: display.isEmpty ? title : display, tags: tags, featured: featured, qualifiers: qualifiers)
    }

    /// `true`, если группа — пометка (версия/feat.), её надо вырезать из основы.
    private static func classify(_ group: String, tags: inout Set<VersionTag>, featured: inout [String], tailMode: Bool = false) -> Bool {
        let raw = group.trimmingCharacters(in: .whitespaces)
        let lower = raw.lowercased()
        for m in featMarkers where lower.hasPrefix(m) || lower.hasPrefix(m.trimmingCharacters(in: .whitespaces) + " ") {
            let name = String(raw.dropFirst(m.trimmingCharacters(in: .whitespaces).count)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
            featured.append(contentsOf: splitArtists(name))
            return true
        }
        let f = fold(raw)
        guard !f.isEmpty else { return true }
        var found = Set<VersionTag>()
        for (tag, kws) in qualifierRules where kws.contains(where: { matchesKeyword(f, $0) }) { found.insert(tag) }
        // «version» сам по себе слишком общий: считаем пометкой, только если нет других тегов и группа короткая
        if found == [.albumVersion] && f.split(separator: " ").count > 3 { found = [] }
        // голый год/«2011 Remaster» уже найден; одинокий год в скобках — тоже пометка
        let onlyYear = f.allSatisfy { $0.isNumber || $0 == " " } && f.count >= 4 && f.count <= 9
        if found.isEmpty && !onlyYear { return false }
        if tailMode && found.isEmpty { return false }
        tags.formUnion(found)
        return true
    }

    // MARK: артисты

    private static let artistSeparators = [",", ";", "/", "&", "、", "，", "；", " x ", " × ", " and ", " и ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " vs. ", " vs ", " + "]

    /// Делит строку исполнителей на имена (как написано, без нормализации).
    public static func splitArtistsRaw(_ s: String) -> [String] {
        var parts = [s]
        for sep in artistSeparators {
            parts = parts.flatMap { p -> [String] in
                sep.hasPrefix(" ") ? splitCaseInsensitive(p, sep) : p.components(separatedBy: sep)
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Делит строку исполнителей на нормализованные имена.
    public static func splitArtists(_ s: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in splitArtistsRaw(s) {
            let f = fold(p)
            if !f.isEmpty, seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    private static func splitCaseInsensitive(_ s: String, _ sep: String) -> [String] {
        var result: [String] = []
        var rest = s[...]
        while let r = rest.range(of: sep, options: .caseInsensitive) {
            result.append(String(rest[..<r.lowerBound]))
            rest = rest[r.upperBound...]
        }
        result.append(String(rest))
        return result
    }

    // MARK: сходство строк

    /// Сходство 0...1 двух нормализованных строк. Кириллица и латиница сравниваются ещё и через латинский «скелет»
    /// (`latinSkeleton`): «кино» ~ «kino», «оксимирон» ~ «oxxxymiron».
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let plain = similarityRaw(a, b)
        guard plain < 0.97, hasCyrillic(a) != hasCyrillic(b) else { return plain }
        let sa = latinSkeleton(a), sb = latinSkeleton(b)
        if sa == sb { return max(plain, 0.97) }
        // скелеты — приблизительное сравнение: чуть дисконтируем, чтобы точное совпадение по написанию было выше
        return max(plain, similarityRaw(sa, sb) * 0.95)
    }

    static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    private static let cyrToLat: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "i",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
        "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh", "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "iu", "я": "ia",
        "і": "i", "ї": "i", "є": "e", "ґ": "g", "ў": "u",
    ]

    /// Латинский «скелет» нормализованной строки (после `fold`) для сравнения разных написаний одного имени:
    /// транслитерация кириллицы, затем упрощения латиницы (x→ks, y/j→i, kh→h, w→v, ph→f, c/q/ck→k), повторы букв схлопнуты.
    /// Только для сравнения: в запросы к API не идёт.
    public static func latinSkeleton(_ folded: String) -> String {
        var t = ""
        for ch in folded { t += cyrToLat[ch] ?? String(ch) }
        t = collapseRepeats(t)
        for (from, to) in [("tch", "ch"), ("ch", "\u{1}"), ("sch", "sh"), ("kh", "h"), ("ck", "k"), ("ph", "f"), ("x", "ks"),
                           ("y", "i"), ("j", "i"), ("w", "v"), ("q", "k"), ("c", "k"), ("\u{1}", "ch")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return collapseRepeats(t)
    }

    private static func collapseRepeats(_ s: String) -> String {
        var out = ""
        var prev: Character?
        for ch in s where ch != prev || ch == " " || ch.isNumber { out.append(ch); prev = ch }
        return out
    }

    private static func similarityRaw(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let lev = levenshteinRatio(a, b)
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        var best = lev
        if !ta.isEmpty && !tb.isEmpty {
            let inter = Double(ta.intersection(tb).count)
            best = max(best, 2 * inter / Double(ta.count + tb.count))
        }
        // одна строка целиком внутри другой по границам слов
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
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
