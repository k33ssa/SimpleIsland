import Foundation
import LyricsCore

// Диагностика каскада: lyricsctl "<title>" "<artist>" [duration_sec] [album] [catalogId]
// Печатает исход каждого источника и лучший результат. Кэш не используется.
// Замер: lyricsctl --bench <файл.tsv> [--exhaustive] — строки «title<TAB>artist<TAB>album<TAB>duration<TAB>catalogId»;
// режим как в приложении (без исчерпывающего опроса), без кэша; печатает время до первого текста и полное время.
let a = CommandLine.arguments

func firstLine(_ l: Lyrics) -> String { l.lines.first(where: { !$0.text.isEmpty })?.text ?? "" }
func short(_ s: ProviderOutcome.Status) -> String {
    switch s {
    case .found(_, let b): return b.rawValue
    case .notFound: return "—"
    case .failed(let e): return "ERR(\(e))"
    case .skipped: return "skip"
    case .cancelled: return "cancel"
    }
}

if a.count >= 3, a[1] == "--bench" {
    let rows = (try? String(contentsOfFile: a[2], encoding: .utf8))?.split(separator: "\n").map { $0.components(separatedBy: "\t") } ?? []
    let exhaustive = a.contains("--exhaustive")
    let engine = LyricsEngine.standard(credentials: InMemoryCredentialStore())
    var opts = FetchOptions(); opts.useCache = false; opts.exhaustive = exhaustive
    print("track\tfirst_s\tfirst\ttotal_s\tbest\tapprox\tproviders")
    var sumFirst = 0.0, sumTotal = 0.0, word = 0, line = 0, plain = 0, none = 0, approx = 0
    for r in rows where r.count >= 2 {
        let q = TrackQuery(catalogId: r.count > 4 && !r[4].isEmpty ? r[4] : nil, title: r[0], artist: r[1],
                           album: r.count > 2 && !r[2].isEmpty ? r[2] : nil, duration: r.count > 3 ? TimeInterval(r[3]) : nil)
        let t0 = Date()
        var firstAt: TimeInterval?
        var firstDesc = "-"
        var result: LyricsResult?
        for await update in engine.lyricsUpdates(for: q, options: opts) {
            if firstAt == nil, let b = update.best {
                firstAt = Date().timeIntervalSince(t0)
                firstDesc = "\(b.source.provider.rawValue)/\(b.syncType.rawValue)"
            }
            result = update
        }
        let total = Date().timeIntervalSince(t0)
        guard let res = result else { continue }
        let bestDesc = res.best.map { "\($0.source.provider.rawValue)/\($0.syncType.rawValue)" } ?? "none"
        switch res.best?.syncType {
        case .word?: word += 1
        case .line?: line += 1
        case .none?: plain += 1
        case nil: none += 1
        }
        if res.bestIsApproximate { approx += 1 }
        sumFirst += firstAt ?? total; sumTotal += total
        let prov = res.outcomes.map { "\($0.provider.rawValue):\(short($0.status))@\(String(format: "%.1f", $0.seconds))" }.joined(separator: " ")
        print("\(r[0].prefix(28)) — \(r[1].prefix(18))\t\(firstAt.map { String(format: "%.2f", $0) } ?? "-")\t\(firstDesc)\t\(String(format: "%.2f", total))\t\(bestDesc)\t\(res.bestIsApproximate ? "approx" : "")\t\(prov)")
    }
    let n = Double(max(1, rows.count))
    print(String(format: "ИТОГО: %d треков; среднее до первого текста %.2f с; среднее полное %.2f с; word %d, line %d, plain %d, ничего %d, approx %d",
                 rows.count, sumFirst / n, sumTotal / n, word, line, plain, none, approx))
    exit(0)
}

guard a.count >= 3 else {
    print("usage: lyricsctl <title> <artist> [duration] [album] [catalogId] | lyricsctl --bench <file.tsv> [--exhaustive]"); exit(2)
}
let q = TrackQuery(catalogId: a.count > 5 ? a[5] : nil, title: a[1], artist: a[2],
                   album: a.count > 4 && !a[4].isEmpty ? a[4] : nil,
                   duration: a.count > 3 ? TimeInterval(a[3]) : nil)
let engine = LyricsEngine.standard(credentials: InMemoryCredentialStore())
var opts = FetchOptions(); opts.useCache = false; opts.exhaustive = true
let r = await engine.lyrics(for: q, options: opts)
if let rq = r.query {
    print("QUERY:", rq.title, "|", rq.artist, "|", rq.duration.map { String(Int($0)) } ?? "?", "|", rq.catalogId ?? "-", "| fp:", rq.fingerprint)
}
for o in r.outcomes {
    print(String(format: "%-10@ %5.1fs  %@", o.provider.rawValue as NSString, o.seconds, String(describing: o.status) as NSString)
          + (o.note.map { "  — " + $0 } ?? ""))
}
if let b = r.best {
    print("BEST:", b.source.provider.rawValue, b.syncType.rawValue, r.bestIsApproximate ? "APPROX(\(r.approximateReason ?? ""))" : "exact", "lines:", b.lines.count, "conf:", b.source.confidence,
          "first:", firstLine(b))
    for l in b.lines.prefix(5) { print("   |", l.begin.map { String(format: "%6.2f", $0) } ?? "      ", l.text) }
} else { print("BEST: none") }
for l in r.alternatives {
    let q = l.source.matchQuality.reason.map { "NEAR-MISS (\($0))" } ?? "exact"
    print("ALT:", l.source.provider.rawValue, l.syncType.rawValue, l.lines.count, l.source.confidence, q,
          "dur:", l.source.duration.map { String(Int($0)) } ?? "?", "first:", firstLine(l))
}
