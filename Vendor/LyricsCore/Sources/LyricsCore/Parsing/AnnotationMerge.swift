import Foundation

/// Прикрепление переводов/транслитераций из отдельного LRC (NetEase `tlyric`/`ytlrc`/`romalrc`, QQ `trans`/`contentts`)
/// к строкам основного текста по времени начала.
public enum AnnotationMerge {
    /// - Parameters:
    ///   - annotation: разобранный LRC перевода (построчный).
    ///   - tolerance: максимальная разница начал строк, секунды.
    public static func attach(_ annotation: Lyrics, to lyrics: Lyrics, kind: LyricAnnotation.Kind,
                              language: String? = nil, tolerance: TimeInterval = 1.0) -> Lyrics {
        guard lyrics.syncType != .none, annotation.syncType != .none else { return lyrics }
        var result = lyrics
        var used = Set<Int>()
        for a in annotation.lines {
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "//", let ab = a.begin else { continue }
            // ближайшая ещё не занятая строка
            var best: (idx: Int, delta: TimeInterval)?
            for (i, l) in result.lines.enumerated() where !used.contains(i) {
                guard let lb = l.begin else { continue }
                let d = abs(lb - ab)
                if d <= tolerance, best == nil || d < best!.delta { best = (i, d) }
            }
            guard let b = best else { continue }
            used.insert(b.idx)
            let ann = LyricAnnotation(kind: kind, language: language, text: text)
            if kind == .transliteration { result.lines[b.idx].transliterations.append(ann) }
            else { result.lines[b.idx].translations.append(ann) }
        }
        return result
    }

    /// Разбирает текст перевода: LRC (`[mm:ss.xx]`) либо QRC-подобные строки `[мс,мс]…`.
    static func parseAnnotationText(_ text: String, source: LyricsSource) -> Lyrics? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.firstMatch(of: /(?m)^\[\d+,\d+\]/) != nil {
            // строки вида [начало_мс,длит_мс]текст… — текст без таймингов слов
            var lines: [LyricLine] = []
            for raw in t.split(separator: "\n") {
                guard let m = raw.firstMatch(of: /^\[(\d+),(\d+)\](.*)$/) else { continue }
                let b = Double(m.output.1)! / 1000, d = Double(m.output.2)! / 1000
                var body = String(m.output.3)
                body = body.replacingOccurrences(of: #"\(\d+,\d+(,\d+)?\)"#, with: "", options: .regularExpression)
                lines.append(LyricLine(key: "L\(lines.count + 1)", begin: b, end: b + d, text: body.trimmingCharacters(in: .whitespaces)))
            }
            return lines.isEmpty ? nil : Lyrics(source: source, syncType: .line, lines: lines)
        }
        let l = LRCParser.parse(t, source: source)
        return l.syncType == .none ? nil : l
    }
}
