import Foundation

/// NetEase Cloud Music: открытый поиск `/api/search/get` и `/api/song/lyric?yv=1` (пословный `yrc` приходит открытым текстом).
/// Неофициальный API: уже менялся (см. `docs/research/netease-qq.md`), поэтому ошибки формата не фатальны для каскада.
public struct NetEaseProvider: LyricsProvider {
    public let id: LyricsProviderID = .netease

    let http: HTTPClient
    let baseURL: String
    let matcher: TrackMatcher
    /// Сколько кандидатов опрашивать (у NetEase на один трек по 5–8 записей с разным набором текстов).
    let maxCandidates: Int

    public init(http: HTTPClient, baseURL: String = "https://music.163.com", maxCandidates: Int = 5,
                matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 8))) {
        self.http = http
        self.baseURL = baseURL
        self.maxCandidates = maxCandidates
        self.matcher = matcher
    }

    private var headers: [String: String] {
        ["User-Agent": UserAgent.browser, "Referer": "https://music.163.com/", "Accept": "application/json"]
    }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        try await response(for: query).lyrics
    }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        var candidates: [TrackCandidate] = []
        if let known = query.neteaseId {
            candidates = [TrackCandidate(id: known, title: query.title, artists: [query.artist], duration: query.duration)]
        } else {
            let parsed = TextNormalizer.parseTitle(query.title)
            let primary = TextNormalizer.splitArtistsRaw(query.artist).first ?? query.artist
            candidates = try await search("\(parsed.display) \(primary)")
            if candidates.isEmpty { candidates = try await search(parsed.display) }
            // Есть выдача, но ни одного подходящего (исполнитель в записи иначе написан) — пробуем только по названию.
            if !candidates.isEmpty, matcher.triage(query, candidates).accepted.isEmpty, matcher.triage(query, candidates).nearMisses.isEmpty {
                let more = try await search(parsed.display)
                var seen = Set(candidates.map(\.id))
                for c in more where seen.insert(c.id).inserted { candidates.append(c) }
            }
        }
        let ranked: [(candidate: TrackCandidate, evaluation: MatchEvaluation)]
        var triage = MatchTriage()
        if query.neteaseId != nil {
            ranked = candidates.map { ($0, MatchEvaluation(score: 1, title: 1, artist: 1, duration: nil, album: nil, versionPenalty: 0,
                                                           versionMismatch: [], isrcMatch: false, accepted: true, rejectReason: nil)) }
        } else {
            triage = matcher.triage(query, candidates)
            ranked = triage.accepted
        }

        var hints: TrackHints?
        if query.neteaseId == nil, let top = ranked.first, top.evaluation.score >= 0.85 { hints = TrackHints(neteaseId: top.candidate.id) }
        var results: [Lyrics] = []
        var errors = CandidateErrors()
        for (cand, ev) in ranked.prefix(maxCandidates) {
            try Task.checkCancellation()
            let src = LyricsSource(provider: .netease, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                   duration: cand.duration, confidence: ev.score,
                                   matchKind: query.neteaseId != nil ? .externalID : .metadata)
            guard let l = try await errors.attempt({ try await fetchLyrics(id: cand.id, source: src, knownTitle: query.title, knownArtist: query.artist) }) else { continue }
            results.append(l)
            if l.syncType == .word { break }   // пословный нашли — остальные кандидаты не нужны
        }
        if results.isEmpty {
            for (cand, ev, reason) in triage.nearMisses.prefix(LRCLIBProvider.maxNearMisses) {
                try Task.checkCancellation()
                let src = LyricsSource(provider: .netease, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                       duration: cand.duration, confidence: ev.score, matchKind: .metadata,
                                       matchQuality: .nearMiss(reason))
                if let l = try await errors.attempt({ try await fetchLyrics(id: cand.id, source: src, knownTitle: query.title, knownArtist: query.artist) }) { results.append(l) }
            }
        }
        try errors.throwIfNothing(!results.isEmpty)
        results.sort { a, b in a.syncType != b.syncType ? a.syncType > b.syncType : a.source.confidence > b.source.confidence }
        var note: String?
        if !results.contains(where: { !$0.source.matchQuality.isNearMiss }) {
            note = triage.summary
            if !triage.accepted.isEmpty { note! += ", у принятых нет текста" }
        }
        return ProviderResponse(lyrics: results, note: note, hints: hints)
    }

    // MARK: - поиск

    func search(_ term: String) async throws -> [TrackCandidate] {
        guard let url = URLBuilder.url(baseURL + "/api/search/get", query: [("s", term), ("type", "1"), ("offset", "0"), ("limit", "10")]) else { return [] }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        return try Self.parseSearch(resp.data)
    }

    static func parseSearch(_ data: Data) throws -> [TrackCandidate] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.badResponse("NetEase: поиск не JSON")
        }
        try checkCode(obj)
        guard let result = obj["result"] as? [String: Any] else {
            // Зашифрованный ответ приходит строкой в поле `result` — формат изменился.
            if obj["result"] is String { throw LyricsError.badResponse("NetEase: поиск вернул зашифрованный ответ") }
            return []
        }
        guard let songs = result["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { s in
            guard let idNum = (s["id"] as? NSNumber), let name = s["name"] as? String else { return nil }
            let artists = (s["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let album = (s["album"] as? [String: Any])?["name"] as? String
            let ms = (s["duration"] as? NSNumber)?.doubleValue
            return TrackCandidate(id: idNum.stringValue, title: name, artists: artists, album: album, duration: ms.map { $0 / 1000 })
        }
    }

    /// NetEase отвечает HTTP 200 с `code` в теле: -460/-462 («网络太拥挤», антибот), 405 (лимит), 301 (нужен вход), 400/404…
    /// Раньше такой ответ без `result` читался как «не найдено» и мог закэшироваться.
    static func checkCode(_ obj: [String: Any]) throws {
        guard let code = BodyCode.int(obj["code"]), code != 200 else { return }
        switch code {
        case -460, -462, 405, 509: throw LyricsError.rateLimited(retryAfter: nil)
        case 301, 302: throw LyricsError.unauthorized
        case 404: return   // нет такой записи — «не найдено»
        default: throw LyricsError.badResponse("NetEase: code \(code)")
        }
    }

    // MARK: - текст

    func fetchLyrics(id: String, source: LyricsSource, knownTitle: String, knownArtist: String = "") async throws -> Lyrics? {
        guard let url = URLBuilder.url(baseURL + "/api/song/lyric",
                                       query: [("id", id), ("lv", "1"), ("kv", "1"), ("tv", "-1"), ("yv", "1"), ("rv", "-1")]) else { return nil }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        guard let l = try Self.makeLyrics(from: resp.data, source: source, knownTitle: knownTitle) else { return nil }
        return SyllableSupport.stripHeaderLine(l, title: knownTitle, artist: knownArtist)
    }

    static func makeLyrics(from data: Data, source: LyricsSource, knownTitle: String? = nil) throws -> Lyrics? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.badResponse("NetEase: текст не JSON")
        }
        try checkCode(obj)
        if obj["pureMusic"] as? Bool == true || obj["nolyric"] as? Bool == true {
            return Lyrics(source: source, syncType: .none, lines: [], isInstrumental: true)
        }
        func lyric(_ key: String) -> String? {
            guard let d = obj[key] as? [String: Any], let s = d["lyric"] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : s
        }
        var result: Lyrics?
        if let yrc = lyric("yrc") {
            var src = source; src.format = "yrc"
            var opts = YRCParser.Options(knownTitle: knownTitle)
            opts.knownTitle = knownTitle
            if let l = try? YRCParser.parse(yrc, source: src, options: opts) { result = l }
        }
        if result == nil, let lrc = lyric("lrc") {
            var src = source; src.format = "lrc"
            var l = LRCParser.parse(lrc, source: src)
            if l.syncType != .none {
                let r = SyllableSupport.stripLeadingCredits(l.lines)
                // кредиты NetEase в LRC идут первыми строками с метками 25/50/75 мс
                l.lines = r.lines
                l.songwriters = r.writers
                for i in l.lines.indices { l.lines[i].key = "L\(i + 1)" }
            }
            if !l.lines.isEmpty { result = l }
        }
        guard var lyrics = result else { return nil }
        // переводы и транслитерация
        let trSrc = LyricsSource(provider: source.provider)
        if let t = lyric("ytlrc") ?? lyric("tlyric"), let ann = AnnotationMerge.parseAnnotationText(t, source: trSrc) {
            lyrics = AnnotationMerge.attach(ann, to: lyrics, kind: .subtitle, language: nil)
        }
        if let r = lyric("romalrc"), let ann = AnnotationMerge.parseAnnotationText(r, source: trSrc) {
            lyrics = AnnotationMerge.attach(ann, to: lyrics, kind: .transliteration, language: nil)
        }
        return lyrics.lines.isEmpty ? nil : lyrics
    }
}
