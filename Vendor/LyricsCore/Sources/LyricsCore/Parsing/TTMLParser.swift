import Foundation

/// Разбор Apple TTML (`/syllable-lyrics`, `/lyrics`, кэш Music.app) и совместимых файлов AMLL TTML DB.
/// Опора — `docs/research/ttml-format.md`.
public enum TTMLParser {
    public struct Options: Sendable {
        /// Снимать скобки с фонового вокала: «(oh)» → «oh».
        public var stripBackgroundParentheses = true
        public init() {}
        public static let `default` = Options()
    }

    public static func parse(_ string: String, source: LyricsSource, options: Options = .default) throws -> Lyrics {
        guard let data = string.data(using: .utf8) else { throw LyricsError.parse("TTML: не UTF-8") }
        return try parse(data, source: source, options: options)
    }

    public static func parse(_ data: Data, source: LyricsSource, options: Options = .default) throws -> Lyrics {
        let root = try XMLTree.parse(data)
        guard root.name == "tt" else { throw LyricsError.parse("TTML: корень «\(root.name)», ожидался tt") }
        var ctx = Context(options: options)
        return try ctx.build(root: root, source: source)
    }

    // MARK: - внутреннее

    private struct Context {
        let options: Options
        var agents: [LyricAgent] = []
        var songwriters: [String] = []
        var leadingSilence: TimeInterval?
        var metadata: [String: [String]] = [:]
        /// key строки → переводы / транслитерации
        var translations: [String: [LyricAnnotation]] = [:]
        var transliterations: [String: [LyricAnnotation]] = [:]

        init(options: Options) { self.options = options }

        mutating func build(root: XMLNode, source: LyricsSource) throws -> Lyrics {
            let timingAttr = root.attributes["itunes:timing"]?.lowercased()
            let language = root.attributes["xml:lang"].flatMap { $0.isEmpty ? nil : $0 }

            if let head = root.first(named: "head") { parseHead(head) }

            guard let body = root.first(named: "body") else {
                throw LyricsError.parse("TTML: нет body")
            }
            let bodyDur = body.attributes["dur"].flatMap(TimeCode.parse)
            let bodyAgent = body.attributes["ttm:agent"]
            let wordMode = timingAttr == "word"
                || (timingAttr == nil && body.descendants(named: "span").contains { $0.attributes["begin"] != nil })

            var lines: [LyricLine] = []
            var usedKeys = Set<String>()
            var anyTimed = false
            var anyWordTimed = false

            func handleP(_ p: XMLNode, agent: String?, part: String?) {
                var line = parseParagraph(p, wordMode: wordMode, fallbackAgent: agent, fallbackPart: part)
                if line.key.isEmpty || usedKeys.contains(line.key) {
                    var n = lines.count + 1
                    while usedKeys.contains("L\(n)") { n += 1 }
                    line.key = "L\(n)"
                }
                usedKeys.insert(line.key)
                if line.begin != nil { anyTimed = true }
                if !line.words.isEmpty { anyWordTimed = true }
                lines.append(line)
            }

            for child in body.elements {
                switch child.name {
                case "div":
                    let divAgent = child.attributes["ttm:agent"] ?? bodyAgent
                    let part = child.attributes["itunes:songPart"] ?? child.attributes["itunes:song-part"]
                    // Вложенные div (редко) тоже поддержим.
                    func walk(_ d: XMLNode, agent: String?, part: String?) {
                        for e in d.elements {
                            if e.name == "p" { handleP(e, agent: agent, part: part) }
                            else if e.name == "div" {
                                walk(e, agent: e.attributes["ttm:agent"] ?? agent,
                                     part: e.attributes["itunes:songPart"] ?? e.attributes["itunes:song-part"] ?? part)
                            }
                        }
                    }
                    walk(child, agent: divAgent, part: part)
                case "p":
                    handleP(child, agent: bodyAgent, part: nil)
                default:
                    break
                }
            }

            // Переводы и транслитерации из sidecar.
            for i in lines.indices {
                if let t = translations[lines[i].key] { lines[i].translations.append(contentsOf: t) }
                if let t = transliterations[lines[i].key] { lines[i].transliterations.append(contentsOf: t) }
            }

            // Тип синхронизации.
            let sync: SyncType
            if !anyTimed { sync = .none }
            else if wordMode && anyWordTimed { sync = .word }
            else if timingAttr == nil && anyWordTimed { sync = .word }
            else { sync = .line }

            // Проставим недостающие end по началу следующей строки.
            if sync != .none {
                for i in lines.indices where lines[i].end == nil {
                    if i + 1 < lines.count, let nb = lines[i + 1].begin { lines[i].end = nb }
                    else if let b = lines[i].begin { lines[i].end = bodyDur.map { max($0, b) } ?? b }
                }
            }

            // Агенты, на которые есть ссылки, но нет объявления.
            var known = Set(agents.map { $0.id })
            for l in lines {
                if let a = l.agentID, !known.contains(a) {
                    agents.append(LyricAgent(id: a, kind: a.count > 3 ? .group : .person))
                    known.insert(a)
                }
            }

            var src = source
            if src.format == nil { src.format = "ttml-\(sync.rawValue)" }
            return Lyrics(source: src, language: language, syncType: sync, lines: lines, agents: agents,
                          songwriters: songwriters, duration: bodyDur, leadingSilence: leadingSilence, metadata: metadata)
        }

        // MARK: head

        mutating func parseHead(_ head: XMLNode) {
            for md in head.descendants(named: "metadata") {
                for a in md.elements(named: "agent") {
                    guard let id = a.attributes["xml:id"], !agents.contains(where: { $0.id == id }) else { continue }
                    let kind = LyricAgent.Kind(rawValue: a.attributes["type"] ?? "person") ?? .other
                    let name = a.first(named: "name")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    agents.append(LyricAgent(id: id, kind: kind, name: (name?.isEmpty ?? true) ? nil : name))
                }
                // Расширение AMLL: <amll:meta key="isrc" value="…"/>
                for m in md.elements(named: "meta") {
                    if let k = m.attributes["key"], let v = m.attributes["value"] {
                        metadata[k, default: []].append(v)
                    }
                }
                for im in md.elements(named: "iTunesMetadata") {
                    if let ls = im.attributes["leadingSilence"], let v = TimeCode.parse(ls) { leadingSilence = v }
                    if let sw = im.first(named: "songwriters") {
                        for w in sw.elements(named: "songwriter") {
                            let t = w.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { songwriters.append(t) }
                        }
                    }
                    if let tr = im.first(named: "translations") {
                        for t in tr.elements(named: "translation") {
                            let kind = LyricAnnotation.Kind(rawValue: t.attributes["type"] ?? "subtitle") ?? .subtitle
                            collect(t, kind: kind, into: &translations)
                        }
                    }
                    if let tr = im.first(named: "transliterations") {
                        for t in tr.elements(named: "transliteration") {
                            collect(t, kind: .transliteration, into: &transliterations)
                        }
                    }
                }
            }
        }

        func collect(_ container: XMLNode, kind: LyricAnnotation.Kind, into dict: inout [String: [LyricAnnotation]]) {
            let lang = container.attributes["xml:lang"]
            for t in container.elements(named: "text") {
                guard let key = t.attributes["for"] else { continue }
                let parsed = parseInline(t, wordMode: true, fallbackBegin: nil, fallbackEnd: nil)
                let text = parsed.main.isEmpty ? parsed.plain : parsed.main.joinedText()
                guard !text.isEmpty || parsed.backgroundText != nil else { continue }
                let bgText = parsed.background.isEmpty ? parsed.backgroundText : parsed.background.joinedText()
                let timed = parsed.main.contains { $0.end > 0 }
                dict[key, default: []].append(LyricAnnotation(kind: kind, language: lang, text: text,
                                                              words: timed ? parsed.main : [],
                                                              backgroundText: bgText))
            }
        }

        // MARK: p

        func parseParagraph(_ p: XMLNode, wordMode: Bool, fallbackAgent: String?, fallbackPart: String?) -> LyricLine {
            let begin = p.attributes["begin"].flatMap(TimeCode.parse)
            let end = p.attributes["end"].flatMap(TimeCode.parse)
            let parsed = parseInline(p, wordMode: wordMode, fallbackBegin: begin, fallbackEnd: end)

            var words = wordMode ? parsed.main : []
            let text = parsed.plain
            let bgWords = wordMode ? parsed.background : []
            let bgText = parsed.backgroundText

            // Время строки: из атрибутов, иначе — по словам.
            var b = begin, e = end
            if b == nil { b = (words + bgWords).map { $0.begin }.min() }
            if e == nil { e = (words + bgWords).map { $0.end }.max() }
            words = words.map { w in
                var w = w
                if w.end < w.begin { w.end = w.begin }
                return w
            }
            var line = LyricLine(key: p.attributes["itunes:key"] ?? "", begin: b, end: e, text: text, words: words,
                                 background: bgWords, backgroundText: bgText,
                                 agentID: p.attributes["ttm:agent"] ?? fallbackAgent,
                                 songPart: p.attributes["itunes:songPart"] ?? p.attributes["itunes:song-part"] ?? fallbackPart)
            // inline-переводы/романизации
            line.translations.append(contentsOf: parsed.inlineTranslations)
            line.transliterations.append(contentsOf: parsed.inlineRoman)
            return line
        }

        struct Inline {
            var main: [LyricWord] = []
            var background: [LyricWord] = []
            var plain = ""                      // «чистый» текст без таймингов
            var backgroundText: String?
            var inlineTranslations: [LyricAnnotation] = []
            var inlineRoman: [LyricAnnotation] = []
        }

        /// Разбор содержимого `<p>` / `<text>`: спаны, пробелы-границы, фоновый вокал, inline-роли.
        func parseInline(_ node: XMLNode, wordMode: Bool, fallbackBegin: TimeInterval?, fallbackEnd: TimeInterval?) -> Inline {
            var out = Inline()
            var plainParts: [String] = []
            var bgPlain: [String] = []
            // пробел между предыдущим и следующим словом
            var pendingSpace = true      // начало строки — «граница»
            var firstWord = true

            func addWord(_ rawText: String, begin: TimeInterval?, end: TimeInterval?, into words: inout [LyricWord], pendingSpace: inout Bool, first: inout Bool) {
                guard !rawText.isEmpty else { return }
                let leading = rawText.first!.isWhitespace
                let trailing = rawText.last!.isWhitespace
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { pendingSpace = true; return }
                let b = begin ?? fallbackBegin ?? 0
                let e = end ?? fallbackEnd ?? b
                let continuation = !(first || pendingSpace || leading)
                words.append(LyricWord(text: trimmed, begin: b, end: max(b, e), isContinuation: continuation))
                first = false
                pendingSpace = trailing
            }

            func walk(_ n: XMLNode, inBackground: Bool, words: inout [LyricWord], pendingSpace: inout Bool, first: inout Bool, plain: inout [String]) {
                for c in n.children {
                    switch c {
                    case .text(let t):
                        let hasContent = !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if !hasContent {
                            if !t.isEmpty { pendingSpace = true }
                            if !t.isEmpty { plain.append(" ") }
                        } else {
                            plain.append(t)
                            // Текст вне спана слов не создаёт; он нужен только для построчного режима.
                            pendingSpace = true
                        }
                    case .element(let e):
                        guard e.name == "span" else { continue }
                        let role = e.attributes["ttm:role"]
                        if role == "x-bg" && !inBackground {
                            var bg: [LyricWord] = out.background
                            var bgPending = bg.isEmpty ? true : pendingSpace
                            var bgFirst = bg.isEmpty
                            var bgP: [String] = []
                            walk(e, inBackground: true, words: &bg, pendingSpace: &bgPending, first: &bgFirst, plain: &bgP)
                            out.background = bg
                            bgPlain.append(bgP.joined())
                            // фон — граница слова для основного вокала
                            pendingSpace = true
                        } else if role == "x-translation" || role == "x-roman" {
                            let text = e.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                if role == "x-translation" {
                                    out.inlineTranslations.append(LyricAnnotation(kind: .subtitle, language: e.attributes["xml:lang"], text: text))
                                } else {
                                    out.inlineRoman.append(LyricAnnotation(kind: .transliteration, language: e.attributes["xml:lang"], text: text))
                                }
                            }
                        } else if e.attributes["tts:ruby"] != nil {
                            // Ruby: берём базовый текст как слово (фуригана не показываем).
                            handleRuby(e, words: &words, pendingSpace: &pendingSpace, first: &first, plain: &plain, begin: e.attributes["begin"], end: e.attributes["end"])
                        } else if e.attributes["begin"] != nil || e.elements.isEmpty {
                            // конечный span со временем (слог/слово) либо без времени
                            let t = e.textContent
                            plain.append(t)
                            let b = e.attributes["begin"].flatMap(TimeCode.parse)
                            let en = e.attributes["end"].flatMap(TimeCode.parse)
                            // dur вместо end
                            var end2 = en
                            if end2 == nil, let b, let d = e.attributes["dur"].flatMap(TimeCode.parse) { end2 = b + d }
                            addWord(t, begin: b, end: end2, into: &words, pendingSpace: &pendingSpace, first: &first)
                        } else {
                            // span-обёртка без времени
                            walk(e, inBackground: inBackground, words: &words, pendingSpace: &pendingSpace, first: &first, plain: &plain)
                        }
                    }
                }
            }

            var mainWords: [LyricWord] = []
            walk(node, inBackground: false, words: &mainWords, pendingSpace: &pendingSpace, first: &firstWord, plain: &plainParts)
            out.main = mainWords
            // Чистый текст: схлопнуть пробелы.
            out.plain = collapse(plainParts.joined())
            // Сначала склеим текст из слов, если span'ы были: чтобы пробелы совпали с границами слов.
            if !mainWords.isEmpty { out.plain = mainWords.joinedText() }
            if !out.background.isEmpty {
                if options.stripBackgroundParentheses { out.background = stripParens(out.background) }
                out.backgroundText = out.background.joinedText()
            } else if !bgPlain.isEmpty {
                let t = collapse(bgPlain.joined(separator: " "))
                out.backgroundText = options.stripBackgroundParentheses ? stripParens(t) : t
            }
            return out
        }

        func handleRuby(_ e: XMLNode, words: inout [LyricWord], pendingSpace: inout Bool, first: inout Bool, plain: inout [String], begin: String?, end: String?) {
            // base-текст контейнера
            var base = ""
            func findBase(_ n: XMLNode) {
                for c in n.elements {
                    if c.attributes["tts:ruby"] == "base" { base += c.textContent }
                    else if c.attributes["tts:ruby"] == "textContainer" || c.attributes["tts:ruby"] == "text" { continue }
                    else { findBase(c) }
                }
            }
            if e.attributes["tts:ruby"] == "base" { base = e.textContent } else { findBase(e) }
            if base.isEmpty { base = e.textContent }
            let times = e.descendants(named: "span").compactMap { $0.attributes["begin"].flatMap(TimeCode.parse) }
            let ends = e.descendants(named: "span").compactMap { $0.attributes["end"].flatMap(TimeCode.parse) }
            let b = begin.flatMap(TimeCode.parse) ?? times.min() ?? 0
            let en = end.flatMap(TimeCode.parse) ?? ends.max() ?? b
            plain.append(base)
            let leading = base.first?.isWhitespace ?? false
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            words.append(LyricWord(text: trimmed, begin: b, end: max(b, en), isContinuation: !(first || pendingSpace || leading)))
            first = false
            pendingSpace = base.last?.isWhitespace ?? false
        }

        func collapse(_ s: String) -> String {
            var out = ""
            var prevSpace = true
            for ch in s {
                if ch.isWhitespace {
                    if !prevSpace { out.append(" "); prevSpace = true }
                } else { out.append(ch); prevSpace = false }
            }
            if out.hasSuffix(" ") { out.removeLast() }
            return out
        }

        func stripParens(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            if (t.hasPrefix("(") || t.hasPrefix("（")) { t.removeFirst() }
            if (t.hasSuffix(")") || t.hasSuffix("）")) { t.removeLast() }
            return t.trimmingCharacters(in: .whitespaces)
        }

        func stripParens(_ words: [LyricWord]) -> [LyricWord] {
            guard !words.isEmpty else { return words }
            var w = words
            func strip(_ t: String, leading: Bool, trailing: Bool) -> String {
                var t = t
                if leading, let f = t.first, f == "(" || f == "（" { t.removeFirst() }
                if trailing, let l = t.last, l == ")" || l == "）" { t.removeLast() }
                return t
            }
            w[0].text = strip(w[0].text, leading: true, trailing: w.count == 1)
            if w.count > 1 { w[w.count - 1].text = strip(w[w.count - 1].text, leading: false, trailing: true) }
            return w.filter { !$0.text.isEmpty }.enumerated().map { (i, x) in
                var x = x
                if i == 0 { x.isContinuation = false }
                return x
            }
        }
    }
}
