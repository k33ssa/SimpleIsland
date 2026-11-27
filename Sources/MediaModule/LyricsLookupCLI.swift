import Foundation

/// Отладка текстов: тот же каскад, что у острова (настоящий кэш и токен Apple из файла секретов), с разбором по
/// источникам. `SimpleIsland --lyrics-lookup "<название>" "<исполнитель>" [альбом] [длительность, с] [--fresh]`.
/// `--fresh` — мимо кэша «не найдено» (в памяти процесса кэша нет, дисковый кэш движка — перепроверить заново).
public enum LyricsLookupCLI {
    public static func run(_ args: [String]) -> Int32 {
        let plain = args.filter { !$0.hasPrefix("--") }
        guard plain.count >= 2 else {
            print("использование: --lyrics-lookup \"название\" \"исполнитель\" [альбом] [длительность] [--fresh]")
            return 2
        }
        let q = LyricsService.Query(artist: plain[1], title: plain[0], album: plain.count > 2 ? plain[2] : "",
                                    duration: plain.count > 3 ? Double(plain[3]) ?? 0 : 0)
        let fresh = args.contains("--fresh")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 1
        Task.detached {
            let svc = LyricsService.shared
            if fresh { await svc.forgetForDebug(q) }
            let r = await svc.lookup(q)
            print("итог: \(r.lyrics == nil ? "текста нет" : "есть") · источник \(r.provider?.rawValue ?? "—") · из кэша \(r.fromCache)"
                  + " · \(String(format: "%.1f", r.seconds)) с" + (r.hadFailures ? " · были сбои источников" : ""))
            if let l = r.lyrics {
                print("синхронизация: \(l.wordSynced ? "по словам" : l.synced ? "по строкам" : "нет"), строк \(l.lines.count)")
            }
            for o in r.outcomes { print("  источник: \(o)") }
            for x in r.rejected { print("  отвергнуто: \(x)") }
            code = r.lyrics == nil ? 1 : 0
            sem.signal()
        }
        sem.wait()
        return code
    }
}
