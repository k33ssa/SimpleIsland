import Foundation

/// QQ Music QRC: `[начало_мс,длит_мс]слово(начало,длит) слово(начало,длит)…`. Метка идёт ПОСЛЕ текста.
public enum QRCParser {
    public struct Options: Sendable {
        public var knownTitle: String?
        public var detectBackground = true
        public var stripCredits = true
        public init(knownTitle: String? = nil) { self.knownTitle = knownTitle }
    }

    /// Разбирает расшифрованный QRC: либо XML-обёртку (`<QrcInfos>…LyricContent="…"`), либо уже сам текст.
    public static func parse(_ decrypted: String, source: LyricsSource, options: Options = Options()) throws -> Lyrics {
        let (body, tags) = unwrap(decrypted)
        var lines: [LyricLine] = []
        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let closeIdx = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<closeIdx].split(separator: ",")
            guard head.count == 2, let startMs = Double(head[0]), let durMs = Double(head[1]) else { continue }
            let segments = parseSegments(String(line[line.index(after: closeIdx)...]))
            guard !segments.isEmpty else { continue }
            var words = SyllableSupport.words(from: segments)
            var background: [LyricWord] = []
            if options.detectBackground {
                let split = SyllableSupport.splitBackground(words)
                words = split.main
                background = split.background
            }
            let begin = startMs / 1000
            lines.append(LyricLine(key: "L\(lines.count + 1)", begin: begin, end: max(begin, (startMs + durMs) / 1000),
                                   text: words.joinedText(), words: words, background: background))
        }
        guard !lines.isEmpty else { throw LyricsError.parse("QRC: нет строк") }
        var writers: [String] = []
        if options.stripCredits {
            let r = SyllableSupport.stripLeadingCredits(lines, knownTitle: options.knownTitle ?? tags["ti"]?.first)
            lines = r.lines
            writers = r.writers
            for i in lines.indices { lines[i].key = "L\(i + 1)" }
        }
        guard !lines.isEmpty else { throw LyricsError.parse("QRC: остались только кредиты") }
        var src = source
        if src.format == nil { src.format = "qrc" }
        return Lyrics(source: src, syncType: .word, lines: lines, songwriters: writers, metadata: tags)
    }

    /// Достаёт текст из XML-обёртки и теги `[ti:]`, `[ar:]`…
    static func unwrap(_ s: String) -> (String, [String: [String]]) {
        var text = s
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if let r = text.range(of: "LyricContent=\"") {
            let rest = text[r.upperBound...]
            // Конец — последняя закрывающая кавычка перед `/>`: внутри текста могут быть неэкранированные кавычки.
            var endIdx: String.Index?
            for pat in ["\"/>", "\" />"] {
                if let e = rest.range(of: pat, options: .backwards) { endIdx = max(endIdx ?? e.lowerBound, e.lowerBound) }
            }
            if let e = endIdx { text = unescape(String(rest[..<e])) }
            else { text = unescape(String(rest)) }
        }
        var tags: [String: [String]] = [:]
        var bodyLines: [Substring] = []
        for l in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let m = t.firstMatch(of: /^\[([A-Za-z]+):(.*)\]$/) {
                let v = String(m.output.2).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { tags[m.output.1.lowercased(), default: []].append(v) }
                continue
            }
            bodyLines.append(l)
        }
        return (bodyLines.joined(separator: "\n"), tags)
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Сегменты `текст(начало,длит)`.
    static func parseSegments(_ body: String) -> [SyllableSupport.Segment] {
        let c = Array(body)
        var segments: [SyllableSupport.Segment] = []
        var text = ""
        var i = 0
        while i < c.count {
            if c[i] == "(", let (consumed, a, b) = marker(c, from: i) {
                segments.append(.init(text: text, begin: a / 1000, duration: b / 1000))
                text = ""
                i += consumed
                continue
            }
            text.append(c[i])
            i += 1
        }
        // «хвост» без метки — присоединим к последнему сегменту как текст без времени (не теряем знаки)
        if !text.trimmingCharacters(in: .whitespaces).isEmpty, var last = segments.popLast() {
            last.text += text
            segments.append(last)
        }
        return segments
    }

    private static func marker(_ c: [Character], from: Int) -> (Int, Double, Double)? {
        var i = from + 1
        func number() -> Double? {
            var s = ""
            while i < c.count, c[i].isASCII, c[i].isNumber { s.append(c[i]); i += 1 }
            return s.isEmpty ? nil : Double(s)
        }
        guard let a = number(), i < c.count, c[i] == "," else { return nil }
        i += 1
        guard let b = number(), i < c.count, c[i] == ")" else { return nil }
        i += 1
        return (i - from, a, b)
    }
}
