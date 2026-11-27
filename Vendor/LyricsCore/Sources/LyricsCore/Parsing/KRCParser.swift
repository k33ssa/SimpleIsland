import Foundation

/// KuGou KRC: `[начало_мс,длит_мс]<смещение_мс,длит_мс,0>слово<…>…`. Смещение слова отсчитывается от начала строки.
/// Служебные теги (`[ti:…]`, `[language:…]`) пропускаются.
public enum KRCParser {
    public static func parse(_ text: String, source: LyricsSource, knownTitle: String? = nil) throws -> Lyrics {
        var lines: [LyricLine] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<close].split(separator: ",")
            guard head.count == 2, let startMs = Double(head[0]), let durMs = Double(head[1]) else { continue }
            let segments = parseSegments(String(line[line.index(after: close)...]), lineStart: startMs)
            guard !segments.isEmpty else { continue }
            var words = SyllableSupport.words(from: segments)
            let split = SyllableSupport.splitBackground(words)
            words = split.main
            let begin = startMs / 1000
            lines.append(LyricLine(key: "L\(lines.count + 1)", begin: begin, end: max(begin, (startMs + durMs) / 1000),
                                   text: words.joinedText(), words: words, background: split.background))
        }
        guard !lines.isEmpty else { throw LyricsError.parse("KRC: нет строк") }
        let r = SyllableSupport.stripLeadingCredits(lines, knownTitle: nil)
        lines = r.lines
        for i in lines.indices { lines[i].key = "L\(i + 1)" }
        guard !lines.isEmpty else { throw LyricsError.parse("KRC: остались только кредиты") }
        var src = source
        if src.format == nil { src.format = "krc" }
        return Lyrics(source: src, syncType: .word, lines: lines, songwriters: r.writers)
    }

    /// Сегменты `<смещение,длит,флаг>текст`; время — абсолютное (от начала трека).
    static func parseSegments(_ body: String, lineStart: Double) -> [SyllableSupport.Segment] {
        var segments: [SyllableSupport.Segment] = []
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let nums = rest[rest.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            let afterTag = rest.index(after: close)
            let next = rest[afterTag...].firstIndex(of: "<") ?? rest.endIndex
            if nums.count == 3, let off = Double(nums[0]), let dur = Double(nums[1]) {
                segments.append(.init(text: String(rest[afterTag..<next]), begin: (lineStart + off) / 1000, duration: dur / 1000))
            }
            rest = rest[next...]
        }
        return segments
    }

    /// Расшифровка тела ответа `download?fmt=krc`: base64 → отбросить 4 байта заголовка → XOR с фиксированным ключом → zlib.
    static let xorKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    public static func decode(base64: String) throws -> String {
        guard let raw = Data(base64Encoded: base64), raw.count > 8 else { throw LyricsError.parse("KRC: не base64") }
        let body = raw.dropFirst(4)
        var plain = [UInt8](); plain.reserveCapacity(body.count)
        for (i, b) in body.enumerated() { plain.append(b ^ xorKey[i % xorKey.count]) }
        let inflated = try Inflate.zlib(Data(plain))
        guard let s = String(data: inflated, encoding: .utf8) else { throw LyricsError.parse("KRC: не UTF-8") }
        return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }
}
