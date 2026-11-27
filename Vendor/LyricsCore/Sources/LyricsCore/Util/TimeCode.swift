import Foundation

/// Разбор и форматирование времени TTML/LRC.
public enum TimeCode {
    /// Разбирает `HH:MM:SS.mmm`, `MM:SS.mmm`, `SS.mmm`, `12.3s`, `250ms`, `1m`, `2h`.
    public static func parse(_ raw: String) -> TimeInterval? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.count <= 3 else { return nil }
            var total: Double = 0
            for (i, p) in parts.enumerated() {
                var piece = String(p)
                if i == parts.count - 1, piece.hasSuffix("s") { piece.removeLast() }
                guard let v = Double(piece), v >= 0 else { return nil }
                let weight: Double = parts.count == 3 ? [3600, 60, 1][i] : [60, 1][i]
                total += v * weight
            }
            return total
        }
        var unit: Double = 1
        if s.hasSuffix("ms") { s.removeLast(2); unit = 0.001 }
        else if s.hasSuffix("s") { s.removeLast() }
        else if s.hasSuffix("m") { s.removeLast(); unit = 60 }
        else if s.hasSuffix("h") { s.removeLast(); unit = 3600 }
        guard let v = Double(s), v >= 0 else { return nil }
        return v * unit
    }

    /// Формат Apple: `S.mmm` до минуты, `M:SS.mmm` до часа, `H:MM:SS.mmm` дальше.
    public static func format(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let totalMs = Int((clamped * 1000).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let min = (totalSec / 60) % 60
        let hr = totalSec / 3600
        if hr > 0 { return String(format: "%d:%02d:%02d.%03d", hr, min, sec, ms) }
        if min > 0 { return String(format: "%d:%02d.%03d", min, sec, ms) }
        return String(format: "%d.%03d", sec, ms)
    }
}
