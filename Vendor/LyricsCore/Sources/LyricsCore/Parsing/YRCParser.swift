import Foundation

/// NetEase YRC: `[начало_мс,длит_мс](начало,длит,0)слово (…)…`. Метка идёт ПЕРЕД текстом сегмента.
public enum YRCParser {
    public struct Options: Sendable {
        /// Название трека — помогает отрезать строку-заголовок.
        public var knownTitle: String?
        public var detectBackground = true
        public var stripCredits = true
        public init(knownTitle: String? = nil) { self.knownTitle = knownTitle }
    }

    public static func parse(_ text: String, source: LyricsSource, options: Options = Options()) throws -> Lyrics {
        var lines: [LyricLine] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }   // строки-JSON {"t":…} и прочее пропускаем
            guard let closeIdx = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<closeIdx].split(separator: ",")
            guard head.count == 2, let startMs = Double(head[0]), let durMs = Double(head[1]) else { continue }
            let body = String(line[line.index(after: closeIdx)...])
            let segments = parseSegments(body)
            guard !segments.isEmpty else { continue }
            var words = SyllableSupport.words(from: segments)
            var background: [LyricWord] = []
            if options.detectBackground {
                let split = SyllableSupport.splitBackground(words)
                words = split.main
                background = split.background
            }
            let begin = startMs / 1000
            let end = (startMs + durMs) / 1000
            lines.append(LyricLine(key: "L\(lines.count + 1)", begin: begin, end: max(begin, end),
                                   text: words.joinedText(), words: words, background: background))
        }
        guard !lines.isEmpty else { throw LyricsError.parse("YRC: нет строк") }
        var writers: [String] = []
        if options.stripCredits {
            let r = SyllableSupport.stripLeadingCredits(lines, knownTitle: nil)
            lines = r.lines
            writers = r.writers
            // Переименуем ключи подряд.
            for i in lines.indices { lines[i].key = "L\(i + 1)" }
        }
        guard !lines.isEmpty else { throw LyricsError.parse("YRC: остались только кредиты") }
        var src = source
        if src.format == nil { src.format = "yrc" }
        return Lyrics(source: src, syncType: .word, lines: lines, songwriters: writers)
    }

    /// Сегменты: `(начало_мс,длит_мс,флаг)текст`.
    static func parseSegments(_ body: String) -> [SyllableSupport.Segment] {
        let chars = Array(body)
        var segments: [SyllableSupport.Segment] = []
        var i = 0
        var text = ""
        var cur: (start: Double, dur: Double)?
        func flush() {
            if let c = cur { segments.append(.init(text: text, begin: c.start / 1000, duration: c.dur / 1000)) }
            text = ""
        }
        while i < chars.count {
            if chars[i] == "(", let (consumed, a, b) = marker(chars, from: i) {
                flush()
                cur = (a, b)
                i += consumed
                continue
            }
            text.append(chars[i])
            i += 1
        }
        flush()
        return segments
    }

    /// Пытается прочитать `(цифры,цифры,число)` начиная с `from`.
    private static func marker(_ c: [Character], from: Int) -> (Int, Double, Double)? {
        var i = from + 1
        func number(allowNegative: Bool = false) -> Double? {
            var s = ""
            if allowNegative, i < c.count, c[i] == "-" { s.append("-"); i += 1 }
            let st = i
            while i < c.count, c[i].isASCII, c[i].isNumber { s.append(c[i]); i += 1 }
            guard i > st else { return nil }
            return Double(s)
        }
        guard let a = number(), i < c.count, c[i] == "," else { return nil }
        i += 1
        guard let b = number(), i < c.count, c[i] == "," else { return nil }
        i += 1
        guard number(allowNegative: true) != nil, i < c.count, c[i] == ")" else { return nil }
        i += 1
        return (i - from, a, b)
    }
}
