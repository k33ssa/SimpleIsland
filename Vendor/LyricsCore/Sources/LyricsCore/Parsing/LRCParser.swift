import Foundation

/// LRC и Enhanced LRC (`<mm:ss.xx>` перед словом).
public enum LRCParser {
    public struct Options: Sendable {
        /// Длительность трека — для конца последней строки.
        public var trackDuration: TimeInterval?
        /// Применять тег `[offset:±мс]`.
        public var applyOffset = true
        /// Запасная длина последней строки, если конец неизвестен.
        public var lastLineFallback: TimeInterval = 5
        public init(trackDuration: TimeInterval? = nil) { self.trackDuration = trackDuration }
    }

    /// Разбирает LRC. Если во входе нет ни одной метки времени — возвращает несинхронизированный текст.
    public static func parse(_ text: String, source: LyricsSource, options: Options = Options()) -> Lyrics {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var tags: [String: [String]] = [:]
        var raw: [RawLine] = []
        var plainLines: [String] = []

        for lineStr in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineStr).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            // [bg: текст] — фоновый вокал предыдущей строки (расширение Enhanced LRC)
            if let m = line.firstMatch(of: /^\s*\[bg:\s*(.*?)\s*\]\s*$/) {
                raw.append(RawLine(stamps: [], body: "", isBackground: true, backgroundBody: String(m.output.1)))
                continue
            }
            var rest = Substring(line)
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
                  let t = parseStamp(String(rest[rest.index(after: rest.startIndex)..<close])) {
                stamps.append(t)
                rest = rest[rest.index(after: close)...]
            }
            if stamps.isEmpty {
                if let m = line.firstMatch(of: /^\s*\[([A-Za-z]+):(.*)\]\s*$/), isTagKey(m.output.1.lowercased()) {
                    tags[m.output.1.lowercased(), default: []].append(String(m.output.2).trimmingCharacters(in: .whitespaces))
                    continue
                }
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { plainLines.append(t) }
                continue
            }
            raw.append(RawLine(stamps: stamps, body: String(rest), isBackground: false, backgroundBody: nil))
        }

        let offset: TimeInterval = options.applyOffset ? (Double(tags["offset"]?.first ?? "").map { $0 / 1000 } ?? 0) : 0
        var metadata = tags
        metadata["offset"] = nil
        let language = tags["lang"]?.first

        guard raw.contains(where: { !$0.stamps.isEmpty }) else {
            var lines = plainLines.enumerated().map { LyricLine(key: "L\($0.offset + 1)", text: $0.element) }
            if lines.isEmpty { lines = [] }
            return Lyrics(source: tagged(source, "lrc-plain"), language: language, syncType: .none, lines: lines, metadata: metadata)
        }

        // Разворачиваем несколько меток на строке в отдельные строки.
        struct Entry { var time: TimeInterval; var body: String; var bg: String? }
        var entries: [Entry] = []
        var pendingBG: String?
        for r in raw {
            if r.isBackground {
                // [bg:...] относится к предыдущей строке
                if !entries.isEmpty { entries[entries.count - 1].bg = r.backgroundBody } else { pendingBG = r.backgroundBody }
                continue
            }
            for st in r.stamps { entries.append(Entry(time: max(0, st - offset), body: r.body, bg: nil)) }
        }
        if let pbg = pendingBG, !entries.isEmpty, entries[0].bg == nil { entries[0].bg = pbg }
        entries = entries.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }.map { $0.element }

        var lines: [LyricLine] = []
        var anyWords = false
        for (i, e) in entries.enumerated() {
            let nextBegin: TimeInterval? = i + 1 < entries.count ? entries[i + 1].time : nil
            var end = nextBegin ?? options.trackDuration.map { max($0, e.time) } ?? (e.time + options.lastLineFallback)
            if end < e.time { end = e.time }
            let parsedBody = parseBody(e.body, lineBegin: e.time, lineEnd: end)
            var line = LyricLine(key: "L\(i + 1)", begin: e.time, end: end, text: parsedBody.text, words: parsedBody.words,
                                 agentID: parsedBody.agent)
            if !parsedBody.words.isEmpty {
                anyWords = true
                // конец последнего слова мог быть задан закрывающей меткой — тогда конец строки тоже
                if let wl = parsedBody.words.last, parsedBody.explicitEnd { line.end = max(line.end ?? 0, wl.end) ; if let nb = nextBegin { line.end = min(line.end ?? nb, nb) } }
            }
            if let bg = e.bg {
                let bb = parseBody(bg, lineBegin: e.time, lineEnd: end)
                line.background = bb.words
                line.backgroundText = bb.text
                if !bb.words.isEmpty { anyWords = true }
            }
            lines.append(line)
        }
        return Lyrics(source: tagged(source, anyWords ? "lrc-enhanced" : "lrc"), language: language,
                      syncType: anyWords ? .word : .line, lines: lines,
                      agents: Array(Set(lines.compactMap { $0.agentID })).sorted().map { LyricAgent(id: $0) },
                      duration: options.trackDuration, metadata: metadata)
    }

    // MARK: -

    private struct RawLine {
        var stamps: [TimeInterval]
        var body: String
        var isBackground: Bool
        var backgroundBody: String?
    }

    private static func tagged(_ s: LyricsSource, _ format: String) -> LyricsSource {
        var s = s
        if s.format == nil { s.format = format }
        return s
    }

    private static let tagKeys: Set<String> = ["ti", "ar", "al", "au", "by", "offset", "length", "re", "ve", "tool", "lang", "bg", "la", "sr", "id"]
    private static func isTagKey(_ k: String) -> Bool { tagKeys.contains(k) }
    private static func isMetaLine(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]") && t.contains(":")
    }

    /// `mm:ss.xx`, `mm:ss:xx`, `mm:ss`, `h:mm:ss.xx`; доля — любое число знаков.
    static func parseStamp(_ s: String) -> TimeInterval? {
        let str = s.trimmingCharacters(in: .whitespaces)
        guard let first = str.first, first.isNumber else { return nil }
        var parts = str.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var secStr = parts.removeLast()
        var frac = 0.0
        if let dot = secStr.firstIndex(where: { $0 == "." || $0 == "," }) {
            let f = String(secStr[secStr.index(after: dot)...])
            guard f.allSatisfy({ $0.isNumber }) else { return nil }
            frac = Double("0." + (f.isEmpty ? "0" : f)) ?? 0
            secStr = String(secStr[..<dot])
        }
        guard let sec = Double(secStr), sec >= 0, secStr.allSatisfy({ $0.isNumber }) else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber } }) else { return nil }
        var total = sec + frac
        if parts.count == 2 { total += Double(parts[0])! * 3600 + Double(parts[1])! * 60 }
        else { total += Double(parts[0])! * 60 }
        return total
    }

    struct Body {
        var text: String
        var words: [LyricWord]
        var agent: String?
        var explicitEnd: Bool
    }

    /// Тело строки: текст с возможными метками `<mm:ss.xx>`.
    static func parseBody(_ body: String, lineBegin: TimeInterval, lineEnd: TimeInterval) -> Body {
        var s = body
        var agent: String?
        // префикс вокалиста: "v1:" / "v2:" / "M:" / "F:" / "D:"
        let trimmedLead = s.drop(while: { $0 == " " })
        if let m = trimmedLead.firstMatch(of: /^(v\d+|[MFD]):\s?/) {
            agent = String(m.output.1)
            if agent == "M" { agent = "v1" } else if agent == "F" { agent = "v2" } else if agent == "D" { agent = "v1000" }
            s = String(trimmedLead[m.range.upperBound...])
        }
        guard s.contains("<") else {
            return Body(text: s.trimmingCharacters(in: .whitespaces), words: [], agent: agent, explicitEnd: false)
        }
        // Разбиваем на сегменты: (метка?, текст)
        struct Seg { var time: TimeInterval?; var text: String }
        var segs: [Seg] = []
        var current = Seg(time: nil, text: "")
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "<", let close = s[idx...].firstIndex(of: ">"),
               let t = parseStamp(String(s[s.index(after: idx)..<close])) {
                if current.time != nil || !current.text.isEmpty { segs.append(current) }
                current = Seg(time: t, text: "")
                idx = s.index(after: close)
                continue
            }
            current.text.append(ch)
            idx = s.index(after: idx)
        }
        segs.append(current)
        if !segs.contains(where: { $0.time != nil }) {
            return Body(text: s.trimmingCharacters(in: .whitespaces), words: [], agent: agent, explicitEnd: false)
        }

        var words: [LyricWord] = []
        var explicitEnd = false
        var pendingSpace = true
        for (i, seg) in segs.enumerated() {
            let raw = seg.text
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let leading = raw.first == " "
            let trailing = raw.last == " "
            if trimmed.isEmpty {
                // пустой сегмент: закрывающая метка конца либо пробел
                if i == segs.count - 1, let t = seg.time, var last = words.popLast() {
                    last.end = max(last.begin, t); words.append(last); explicitEnd = true
                } else if !raw.isEmpty { pendingSpace = true }
                continue
            }
            let begin = seg.time ?? words.last?.end ?? lineBegin
            // конец — начало следующей метки, иначе конец строки
            var end = lineEnd
            if let next = segs[(i + 1)...].first(where: { $0.time != nil })?.time { end = next }
            let cont = !(words.isEmpty || pendingSpace || leading)
            words.append(LyricWord(text: trimmed, begin: begin, end: max(begin, end), isContinuation: cont))
            pendingSpace = trailing
        }
        let text = words.joinedText()
        return Body(text: text, words: words, agent: agent, explicitEnd: explicitEnd)
    }
}
