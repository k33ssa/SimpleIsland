import Foundation

/// Генератор TTML в формате Apple (см. `docs/research/ttml-format.md` §8).
/// Внутри `<p>` нет переносов и отступов: пробелы в TTML значимы.
public enum TTMLWriter {
    public struct Options: Sendable {
        /// Оборачивать фоновый вокал в скобки (как в документах Apple).
        public var parenthesizeBackground = true
        /// Красивые переносы между `<div>`/`<p>` (внутри `<p>` их нет в любом случае).
        public var prettyPrint = true
        public init() {}
    }

    public static func write(_ lyrics: Lyrics, options: Options = Options()) -> String {
        let nl = options.prettyPrint ? "\n" : ""
        let ind1 = options.prettyPrint ? "  " : ""
        let ind2 = options.prettyPrint ? "    " : ""
        let ind3 = options.prettyPrint ? "      " : ""
        let ind4 = options.prettyPrint ? "        " : ""
        let timing = lyrics.syncType == .word ? "Word" : "Line"

        var out = ""
        out += "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" itunes:timing=\"\(timing)\""
        if let lang = lyrics.language { out += " xml:lang=\"\(esc(lang))\"" }
        out += ">" + nl
        out += ind1 + "<head>" + nl + ind2 + "<metadata>" + nl

        // агенты: объявленные + встретившиеся
        var agents = lyrics.agents
        var seen = Set(agents.map { $0.id })
        for l in lyrics.lines { if let a = l.agentID, !seen.contains(a) { agents.append(LyricAgent(id: a)); seen.insert(a) } }
        for a in agents {
            if let name = a.name {
                out += ind3 + "<ttm:agent type=\"\(a.kind.rawValue)\" xml:id=\"\(esc(a.id))\"><ttm:name type=\"full\">\(esc(name))</ttm:name></ttm:agent>" + nl
            } else {
                out += ind3 + "<ttm:agent type=\"\(a.kind.rawValue)\" xml:id=\"\(esc(a.id))\"/>" + nl
            }
        }

        out += ind3 + "<iTunesMetadata xmlns=\"http://music.apple.com/lyric-ttml-internal\" leadingSilence=\"\(fmtSilence(lyrics.leadingSilence ?? 0))\">" + nl
        // переводы
        let tr = groupAnnotations(lyrics.lines, translations: true)
        if !tr.isEmpty {
            out += ind4 + "<translations>" + nl
            for g in tr {
                let typeAttr = g.kind == .replacement ? "replacement" : "subtitle"
                out += ind4 + "  <translation type=\"\(typeAttr)\"" + (g.language.map { " xml:lang=\"\(esc($0))\"" } ?? "") + ">" + nl
                for (key, a) in g.items { out += ind4 + "    " + textElement(key: key, annotation: a, options: options) + nl }
                out += ind4 + "  </translation>" + nl
            }
            out += ind4 + "</translations>" + nl
        }
        let tl = groupAnnotations(lyrics.lines, translations: false)
        if !tl.isEmpty {
            out += ind4 + "<transliterations>" + nl
            for g in tl {
                out += ind4 + "  <transliteration" + (g.language.map { " xml:lang=\"\(esc($0))\"" } ?? "") + ">" + nl
                for (key, a) in g.items { out += ind4 + "    " + textElement(key: key, annotation: a, options: options) + nl }
                out += ind4 + "  </transliteration>" + nl
            }
            out += ind4 + "</transliterations>" + nl
        }
        if !lyrics.songwriters.isEmpty {
            out += ind4 + "<songwriters>" + nl
            for w in lyrics.songwriters { out += ind4 + "  <songwriter>\(esc(w))</songwriter>" + nl }
            out += ind4 + "</songwriters>" + nl
        }
        out += ind3 + "</iTunesMetadata>" + nl
        out += ind2 + "</metadata>" + nl + ind1 + "</head>" + nl

        out += ind1 + "<body"
        if let d = lyrics.duration { out += " dur=\"\(TimeCode.format(d))\"" }
        out += ">" + nl

        // группировка в div по songPart (подряд идущие строки с одинаковым значением)
        var groups: [(part: String?, lines: [(Int, LyricLine)])] = []
        for (i, l) in lyrics.lines.enumerated() {
            if let last = groups.last, last.part == l.songPart {
                groups[groups.count - 1].lines.append((i, l))
            } else {
                groups.append((l.songPart, [(i, l)]))
            }
        }
        for g in groups {
            out += ind2 + "<div"
            if lyrics.syncType != .none {
                if let b = g.lines.compactMap({ $0.1.begin }).min() { out += " begin=\"\(TimeCode.format(b))\"" }
                if let e = g.lines.compactMap({ $0.1.end ?? $0.1.begin }).max() { out += " end=\"\(TimeCode.format(e))\"" }
            }
            if let p = g.part { out += " itunes:songPart=\"\(esc(p))\"" }
            out += ">" + nl
            for (_, l) in g.lines {
                out += ind3 + paragraph(l, syncType: lyrics.syncType, options: options) + nl
            }
            out += ind2 + "</div>" + nl
        }
        out += ind1 + "</body>" + nl + "</tt>" + nl
        return out
    }

    // MARK: -

    private static func paragraph(_ l: LyricLine, syncType: SyncType, options: Options) -> String {
        var s = "<p"
        if syncType != .none {
            if let b = l.begin { s += " begin=\"\(TimeCode.format(b))\"" }
            if let e = l.end ?? l.begin { s += " end=\"\(TimeCode.format(e))\"" }
        }
        s += " itunes:key=\"\(esc(l.key))\""
        if let a = l.agentID { s += " ttm:agent=\"\(esc(a))\"" }
        s += ">"
        if syncType == .word, !l.words.isEmpty {
            s += spans(l.words)
            if !l.background.isEmpty {
                s += " " + bgSpan(l.background, options: options)
            }
        } else {
            s += esc(l.text)
            if let bg = l.backgroundText, !bg.isEmpty {
                s += " <span ttm:role=\"x-bg\">\(esc(options.parenthesizeBackground ? "(\(bg))" : bg))</span>"
            }
        }
        s += "</p>"
        return s
    }

    /// `<span>`'ы слов. Между словами — один пробел, у продолжений слова — ничего.
    private static func spans(_ words: [LyricWord]) -> String {
        var s = ""
        for (i, w) in words.enumerated() {
            if i > 0 && !w.isContinuation { s += " " }
            s += "<span begin=\"\(TimeCode.format(w.begin))\" end=\"\(TimeCode.format(w.end))\">\(esc(w.text))</span>"
        }
        return s
    }

    private static func bgSpan(_ words: [LyricWord], options: Options) -> String {
        var ws = words
        if options.parenthesizeBackground, !ws.isEmpty {
            ws[0].text = "(" + ws[0].text
            ws[ws.count - 1].text += ")"
        }
        return "<span ttm:role=\"x-bg\">" + spans(ws) + "</span>"
    }

    private struct AnnotationGroup {
        var kind: LyricAnnotation.Kind
        var language: String?
        var items: [(String, LyricAnnotation)]
    }

    private static func groupAnnotations(_ lines: [LyricLine], translations: Bool) -> [AnnotationGroup] {
        var groups: [AnnotationGroup] = []
        for l in lines {
            for a in (translations ? l.translations : l.transliterations) {
                if let i = groups.firstIndex(where: { $0.kind == a.kind && $0.language == a.language }) {
                    groups[i].items.append((l.key, a))
                } else {
                    groups.append(AnnotationGroup(kind: a.kind, language: a.language, items: [(l.key, a)]))
                }
            }
        }
        return groups
    }

    private static func textElement(key: String, annotation a: LyricAnnotation, options: Options) -> String {
        var s = "<text for=\"\(esc(key))\">"
        if !a.words.isEmpty { s += spans(a.words) } else { s += esc(a.text) }
        if let bg = a.backgroundText, !bg.isEmpty {
            s += " <span ttm:role=\"x-bg\">\(esc(bg))</span>"
        }
        s += "</text>"
        return s
    }

    private static func fmtSilence(_ t: TimeInterval) -> String {
        if t == 0 { return "0" }
        return String(format: "%.3f", t)
    }

    static func esc(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(ch)
            }
        }
        return r
    }
}
