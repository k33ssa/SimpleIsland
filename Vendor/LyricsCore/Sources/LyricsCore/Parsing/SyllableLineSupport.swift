import Foundation

/// Общие помощники для пословных форматов NetEase (YRC) и QQ (QRC).
enum SyllableSupport {
    struct Segment {
        var text: String
        var begin: TimeInterval
        var duration: TimeInterval
    }

    static func isPunctuationOnly(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }
    }

    /// Превращает сегменты (слово «с хвостовым пробелом» либо пробел отдельным сегментом) в слова.
    /// Знаки препинания приклеиваются к предыдущему слову, `end` берётся максимальный.
    static func words(from segments: [Segment]) -> [LyricWord] {
        var words: [LyricWord] = []
        var pendingSpace = true
        for seg in segments {
            let raw = seg.text
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let leading = raw.first?.isWhitespace ?? false
            let trailing = raw.last?.isWhitespace ?? false
            if trimmed.isEmpty {
                if !raw.isEmpty { pendingSpace = true }
                continue
            }
            let begin = seg.begin
            let end = seg.begin + max(0, seg.duration)
            if isPunctuationOnly(trimmed), !pendingSpace, !leading, var last = words.popLast() {
                last.text += trimmed
                last.end = max(last.end, end)
                words.append(last)
                pendingSpace = trailing
                continue
            }
            let continuation = !(words.isEmpty || pendingSpace || leading)
            words.append(LyricWord(text: trimmed, begin: begin, end: end, isContinuation: continuation))
            pendingSpace = trailing
        }
        return words
    }

    // MARK: - фоновый вокал

    private static let openers: Set<Character> = ["(", "（"]
    private static let closers: Set<Character> = [")", "）"]

    /// Выделяет фоновый вокал, если в строке есть группа слов, целиком взятая в скобки
    /// (в начале или в конце строки), и при этом остаётся основной вокал.
    /// Выведено из практики (Queen в NetEase: «（oooh, poor boy）»), надёжного флага в формате нет.
    static func splitBackground(_ words: [LyricWord]) -> (main: [LyricWord], background: [LyricWord]) {
        guard words.count >= 2 else { return (words, []) }
        func startsGroup(_ w: LyricWord) -> Bool { w.text.first.map { openers.contains($0) } ?? false }
        func endsGroup(_ w: LyricWord) -> Bool { w.text.last.map { closers.contains($0) } ?? false }
        func strip(_ ws: [LyricWord]) -> [LyricWord] {
            var ws = ws
            if let f = ws.first?.text.first, openers.contains(f) { ws[0].text.removeFirst() }
            if let l = ws.last?.text.last, closers.contains(l) { ws[ws.count - 1].text.removeLast() }
            ws = ws.filter { !$0.text.isEmpty }
            if !ws.isEmpty { ws[0].isContinuation = false }
            return ws
        }
        func balanced(_ ws: ArraySlice<LyricWord>) -> Bool {
            var depth = 0
            for w in ws {
                for ch in w.text {
                    if openers.contains(ch) { depth += 1 }
                    if closers.contains(ch) { depth -= 1; if depth < 0 { return false } }
                }
            }
            return depth == 0
        }
        // группа в конце
        if endsGroup(words[words.count - 1]),
           let startIdx = words.indices.last(where: { startsGroup(words[$0]) }),
           startIdx > 0, balanced(words[startIdx...]) {
            let bg = strip(Array(words[startIdx...]))
            let main = Array(words[..<startIdx])
            if !bg.isEmpty && !main.isEmpty { return (main, bg) }
        }
        // группа в начале
        if startsGroup(words[0]),
           let endIdx = words.indices.first(where: { endsGroup(words[$0]) }),
           endIdx < words.count - 1, balanced(words[...endIdx]) {
            let bg = strip(Array(words[...endIdx]))
            var main = Array(words[(endIdx + 1)...])
            if !bg.isEmpty && !main.isEmpty {
                main[0].isContinuation = false
                return (main, bg)
            }
        }
        return (words, [])
    }

    // MARK: - служебные строки

    static let creditPattern = try! Regex(
        #"^\s*(作词|作詞|作曲|编曲|編曲|制作人|製作人|制作|监制|混音|母带|录音|吉他|鼓|贝斯|和声|词|曲|OP|SP|Lyrics?\s*(by)?|Composed?\s*(by)?|Composer|Written\s*(by)?|Arranged?\s*(by)?|Arranger|Produced\s*(by)?|Producer|Words\s*by|Music\s*by|Lyricist|Songwriters?|Mix(ed)?\s*(by)?|Master(ed)?\s*(by)?|Vocals?|Guitar|Bass|Drums|Publisher|Label)\s*[:：]"#
    ).ignoresCase()

    static func isCredit(_ text: String) -> Bool {
        text.firstMatch(of: creditPattern) != nil
    }

    /// Достаёт «кто автор» из кредитной строки: `作词 : Freddie Mercury` → Freddie Mercury (только слова автора песни).
    static func writer(fromCredit text: String) -> String? {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let writerKeys = ["作词", "作詞", "作曲", "词", "曲", "lyrics", "lyrics by", "lyric", "composed by", "composer", "written by", "words by", "music by", "lyricist", "songwriter", "songwriters", "compose", "composed"]
        if writerKeys.contains(key) { return value }
        return nil
    }

    /// Отрезает ведущие служебные строки (кредиты, строка-заголовок «Название - Исполнитель»).
    /// Возвращает оставшиеся строки и найденных авторов.
    static func stripLeadingCredits(_ lines: [LyricLine], knownTitle: String? = nil) -> (lines: [LyricLine], writers: [String]) {
        var writers: [String] = []
        var i = 0
        func norm(_ s: String) -> String {
            TextNormalizer.fold(s)
        }
        while i < lines.count {
            let l = lines[i]
            let isCredit = SyllableSupport.isCredit(l.text)
            var isTitle = false
            if i == 0, let b = l.begin, b < 0.05 {
                let synthetic = (l.end ?? 0) - b <= 0.2
                let hasDash = l.text.contains(" - ") || l.text.contains(" – ")
                var matchesTitle = false
                if let t = knownTitle, !t.isEmpty {
                    let nt = norm(t)
                    let nl = norm(l.text)
                    matchesTitle = !nt.isEmpty && nl.contains(nt)
                }
                isTitle = synthetic || hasDash || matchesTitle
            }
            if isCredit || isTitle {
                if let w = writer(fromCredit: l.text) {
                    for part in w.split(whereSeparator: { "/、,&;；".contains($0) }) {
                        let name = part.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && !writers.contains(name) { writers.append(name) }
                    }
                }
                i += 1
            } else {
                break
            }
            if i > 12 { break }
        }
        return (Array(lines[i...]), writers)
    }

    /// Вырезает строку-заголовок «<название> - <исполнители>» в первых двух строках (QQ: «Tobey (Explicit) - Eminem/Big Sean»),
    /// если левая часть совпадает с названием трека, а в правой есть известный исполнитель. Это не текст песни.
    public static func stripHeaderLine(_ lyrics: Lyrics, title: String, artist: String) -> Lyrics {
        guard !title.isEmpty, !artist.isEmpty else { return lyrics }
        let qt = TextNormalizer.parseTitle(title)
        var known = TextNormalizer.splitArtists(artist)
        for f in qt.featured where !known.contains(f) { known.append(f) }
        let baseTitle = qt.base
        func isHeader(_ text: String) -> Bool {
            for sep in [" - ", " – ", " — "] {
                var from = text.startIndex
                while let r = text.range(of: sep, range: from..<text.endIndex) {
                    let left = String(text[..<r.lowerBound]), right = String(text[r.upperBound...])
                    from = r.upperBound
                    let lt = TextNormalizer.parseTitle(left).base
                    guard !lt.isEmpty, TextNormalizer.similarity(lt, baseTitle) >= 0.85 else { continue }
                    let names = right.split(whereSeparator: { "/、,&;；".contains($0) }).map { TextNormalizer.fold(String($0)) }
                    if names.contains(where: { n in !n.isEmpty && known.contains { TextNormalizer.similarity(n, $0) >= 0.85 } }) { return true }
                }
            }
            return false
        }
        var out = lyrics
        var removed = false
        var idx = 0, seen = 0
        while idx < out.lines.count, seen < 2 {
            if out.lines[idx].isGap { idx += 1; continue }   // пустые строки не считаются
            seen += 1
            if isHeader(out.lines[idx].text) { out.lines.remove(at: idx); removed = true; break }
            idx += 1
        }
        if removed {
            // Заголовок мог стоять перед кредитами («Lyrics by：…») — после него они снова ведущие.
            let r = stripLeadingCredits(out.lines, knownTitle: nil)
            out.lines = r.lines
            for w in r.writers where !out.songwriters.contains(w) { out.songwriters.append(w) }
            for i in out.lines.indices where out.lines[i].key.firstMatch(of: /^L\d+$/) != nil { out.lines[i].key = "L\(i + 1)" }
        }
        return out
    }
}
