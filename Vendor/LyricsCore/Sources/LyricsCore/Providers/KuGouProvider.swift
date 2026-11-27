import Foundation

/// KuGou: открытый поиск песен (`songsearch.kugou.com`), поиск текстов (`lyrics.kugou.com/search`) и пословный KRC
/// (`/download?fmt=krc`, XOR + zlib), запасной LRC. Ключей не нужно; API неофициальный, как у NetEase/QQ.
/// Проверено вживую 15.11.2026 (в том числе западные треки: официальные KRC-тексты есть и у них).
public struct KuGouProvider: LyricsProvider {
    public let id: LyricsProviderID = .kugou

    let http: HTTPClient
    let searchHost: String
    let lyricsHost: String
    let matcher: TrackMatcher
    let maxCandidates: Int

    public init(http: HTTPClient, searchHost: String = "https://songsearch.kugou.com", lyricsHost: String = "https://lyrics.kugou.com",
                maxCandidates: Int = 4,
                matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 8))) {
        self.http = http
        self.searchHost = searchHost
        self.lyricsHost = lyricsHost
        self.maxCandidates = maxCandidates
        self.matcher = matcher
    }

    private var headers: [String: String] { ["User-Agent": UserAgent.browser, "Accept": "application/json"] }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] { try await response(for: query).lyrics }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        let parsed = TextNormalizer.parseTitle(query.title)
        let primary = TextNormalizer.splitArtistsRaw(query.artist).first ?? query.artist
        let cands = try await findCandidates(query: query, title: parsed.display, primary: primary)
        let triage = matcher.triage(query, cands)

        var results: [Lyrics] = []
        var errors = CandidateErrors()
        for (cand, ev) in triage.accepted.prefix(maxCandidates) {
            try Task.checkCancellation()
            let src = LyricsSource(provider: .kugou, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                   duration: cand.duration, confidence: ev.score, matchKind: .metadata)
            if let l = try await errors.attempt({ try await fetch(hash: cand.id, candidate: cand, source: src, query: query) }) {
                results.append(l)
                if l.syncType == .word { break }
            }
        }
        if results.isEmpty {
            for (cand, ev, reason) in triage.nearMisses.prefix(LRCLIBProvider.maxNearMisses) {
                try Task.checkCancellation()
                let src = LyricsSource(provider: .kugou, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                       duration: cand.duration, confidence: ev.score, matchKind: .metadata, matchQuality: .nearMiss(reason))
                if let l = try await errors.attempt({ try await fetch(hash: cand.id, candidate: cand, source: src, query: query) }) { results.append(l) }
            }
        }
        try errors.throwIfNothing(!results.isEmpty)
        results.sort { a, b in a.syncType != b.syncType ? a.syncType > b.syncType : a.source.confidence > b.source.confidence }
        var note: String?
        if !results.contains(where: { !$0.source.matchQuality.isNearMiss }) {
            note = triage.summary
            if !triage.accepted.isEmpty { note! += ", у принятых нет текста" }
        }
        return ProviderResponse(lyrics: results, note: note)
    }

    // MARK: - поиск песен

    /// Проверено вживую 15.11.2026: `song_search_v2` на один и тот же запрос то отдаёт 10 записей, то пустой список
    /// (`status: 1`, ошибки нет) — примерно в 60 % запросов; из-за этого у потребителей было «0 кандидатов» на 9 из 9 треков.
    /// Поэтому пустой ответ — не «не найдено»: повтор, затем запасной `mobiles.kugou.com/api/v3/search/song` (https,
    /// стабильный, но хуже ищет по «название + исполнитель» — ему даём и просто название).
    func findCandidates(query: TrackQuery, title: String, primary: String) async throws -> [TrackCandidate] {
        var lastError: Error?
        var all: [TrackCandidate] = []
        func merge(_ list: [TrackCandidate]) {
            var seen = Set(all.map { $0.id.lowercased() })
            for c in list where seen.insert(c.id.lowercased()).inserted { all.append(c) }
        }
        func good() -> Bool { !matcher.triage(query, all).accepted.isEmpty }
        let steps: [() async throws -> [TrackCandidate]] = [
            { try await self.search("\(title) \(primary)") },
            { try await self.search("\(title) \(primary)") },          // повтор: пустой ответ у v2 часто случаен
            { try await self.searchMobile("\(title) \(primary)") },
            { try await self.searchMobile(title) },
            { try await self.search(title) },
        ]
        for step in steps {
            try Task.checkCancellation()
            do { merge(try await step()) } catch let e as LyricsError where e == .cancelled { throw e } catch { lastError = error }
            if good() { break }
        }
        if all.isEmpty, let lastError { throw lastError }
        return all
    }

    let mobileHost = "https://mobiles.kugou.com"

    func searchMobile(_ term: String) async throws -> [TrackCandidate] {
        guard let url = URLBuilder.url(mobileHost + "/api/v3/search/song",
                                       query: [("format", "json"), ("keyword", term), ("page", "1"), ("pagesize", "10")]) else { return [] }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireJSON("KuGou")
        return try Self.parseMobileSearch(resp.data)
    }

    static func parseMobileSearch(_ data: Data) throws -> [TrackCandidate] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.badResponse("KuGou: поиск не JSON") }
        if let st = BodyCode.int(obj["status"]), st != 1 { throw LyricsError.badResponse("KuGou: status \(st)") }
        guard let list = (obj["data"] as? [String: Any])?["info"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { s in
            guard let hash = s["hash"] as? String, !hash.isEmpty, let name = s["songname"] as? String, seen.insert(hash.lowercased()).inserted else { return nil }
            let singer = ((s["singername"] as? String) ?? "").replacingOccurrences(of: "、", with: "/")
            let artists = TextNormalizer.splitArtistsRaw(singer).isEmpty ? [singer] : TextNormalizer.splitArtistsRaw(singer)
            let dur = BodyCode.int(s["duration"]).map(Double.init)
            return TrackCandidate(id: hash, title: name, artists: artists, album: s["album_name"] as? String, duration: dur.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    func search(_ term: String) async throws -> [TrackCandidate] {
        guard let url = URLBuilder.url(searchHost + "/song_search_v2",
                                       query: [("keyword", term), ("page", "1"), ("pagesize", "10"), ("platform", "WebFilter"), ("filter", "2")]) else { return [] }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireJSON("KuGou")
        return try Self.parseSearch(resp.data)
    }

    static func parseSearch(_ data: Data) throws -> [TrackCandidate] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsError.badResponse("KuGou: поиск не JSON") }
        if let st = BodyCode.int(obj["status"]), st != 1 { throw LyricsError.badResponse("KuGou: status \(st)") }
        if let ec = BodyCode.int(obj["error_code"]), ec != 0 { throw LyricsError.badResponse("KuGou: error_code \(ec)") }
        guard let list = (obj["data"] as? [String: Any])?["lists"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { s in
            guard let hash = s["FileHash"] as? String, let name = s["SongName"] as? String, seen.insert(hash.lowercased()).inserted else { return nil }
            let singer = ((s["SingerName"] as? String) ?? "").replacingOccurrences(of: "、", with: "/")
            let artists = TextNormalizer.splitArtistsRaw(singer).isEmpty ? [singer] : TextNormalizer.splitArtistsRaw(singer)
            let dur = (s["Duration"] as? NSNumber)?.doubleValue
            return TrackCandidate(id: hash, title: name, artists: artists, album: s["AlbumName"] as? String, duration: dur.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    // MARK: - текст

    struct LyricCandidate: Equatable { var id: String; var accessKey: String }

    func fetch(hash: String, candidate: TrackCandidate, source: LyricsSource, query: TrackQuery) async throws -> Lyrics? {
        let keyword = "\(candidate.artists.first ?? query.artist) - \(candidate.title)"
        let ms = Int(((candidate.duration ?? query.duration) ?? 0) * 1000)
        guard let url = URLBuilder.url(lyricsHost + "/search", query: [("ver", "1"), ("man", "yes"), ("client", "pc"), ("keyword", keyword),
                                                                        ("duration", String(ms)), ("hash", hash)]) else { return nil }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        for lc in Self.parseLyricCandidates(resp.data).prefix(2) {
            try Task.checkCancellation()
            if let l = try await download(lc, source: source, query: query) { return l }
        }
        return nil
    }

    static func parseLyricCandidates(_ data: Data) -> [LyricCandidate] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = obj["candidates"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            let id = (c["id"] as? String) ?? (c["id"] as? NSNumber)?.stringValue
            guard let id, let key = c["accesskey"] as? String else { return nil }
            return LyricCandidate(id: id, accessKey: key)
        }
    }

    func download(_ lc: LyricCandidate, source: LyricsSource, query: TrackQuery) async throws -> Lyrics? {
        for fmt in ["krc", "lrc"] {
            guard let url = URLBuilder.url(lyricsHost + "/download", query: [("ver", "1"), ("client", "pc"), ("id", lc.id), ("accesskey", lc.accessKey),
                                                                              ("fmt", fmt), ("charset", "utf8")]) else { continue }
            let resp = try await http.send(.make(url, headers: headers))
            try resp.requireOK()
            if var l = Self.makeLyrics(from: resp.data, fmt: fmt, source: source, knownTitle: query.title) {
                l = SyllableSupport.stripHeaderLine(l, title: query.title, artist: query.artist)
                if !l.lines.isEmpty { return l }
            }
        }
        return nil
    }

    static func makeLyrics(from data: Data, fmt: String, source: LyricsSource, knownTitle: String?) -> Lyrics? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let b64 = obj["content"] as? String, !b64.isEmpty else { return nil }
        if fmt == "krc" {
            guard let text = try? KRCParser.decode(base64: b64) else { return nil }
            return try? KRCParser.parse(text, source: source, knownTitle: knownTitle)
        }
        guard let d = Data(base64Encoded: b64), let text = String(data: d, encoding: .utf8) else { return nil }
        var src = source; src.format = "lrc"
        var l = LRCParser.parse(text, source: src)
        guard l.syncType != .none else { return nil }
        let r = SyllableSupport.stripLeadingCredits(l.lines)
        l.lines = r.lines
        l.songwriters = r.writers
        for i in l.lines.indices { l.lines[i].key = "L\(i + 1)" }
        return l.lines.isEmpty ? nil : l
    }
}
