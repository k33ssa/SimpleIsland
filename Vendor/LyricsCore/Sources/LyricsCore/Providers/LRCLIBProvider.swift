import Foundation

/// LRCLIB: `/api/get` по подписи трека, затем `/api/search`. Пословный текст — из поля `lyricsfile` (YAML),
/// построчный — `syncedLyrics`, иначе `plainLyrics`.
public struct LRCLIBProvider: LyricsProvider {
    public let id: LyricsProviderID = .lrclib

    let http: HTTPClient
    let baseURL: String
    let matcher: TrackMatcher
    /// Сколько записей из поиска превращать в тексты (лучшие по score).
    let maxResults: Int

    /// Допуск длительности 10 → 6 с (15.11.2026): у LRCLIB тексты присылают пользователи, и записи с разницей 7–8 с —
    /// как правило, другая версия (радио-edit, клип, ремастер с другой тишиной). 6–40 с теперь идут в near-miss.
    public init(http: HTTPClient, baseURL: String = "https://lrclib.net", maxResults: Int = 3,
                matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 2.5, durationHardLimit: 6))) {
        self.http = http
        self.baseURL = baseURL
        self.maxResults = maxResults
        self.matcher = matcher
    }

    struct Record: Decodable {
        var id: Int
        var trackName: String?
        var name: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
        var lyricsfile: String?
        var hasWordSync: Bool?
    }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        try await response(for: query).lyrics
    }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        let parsed = TextNormalizer.parseTitle(query.title)
        let primaryArtist = Self.primaryArtist(query.artist)
        var records: [Record] = []
        var seen = Set<Int>()
        func add(_ r: Record) { if seen.insert(r.id).inserted { records.append(r) } }

        // 1. точное попадание по подписи
        for (title, artist) in Self.signatures(query: query, parsed: parsed, primary: primaryArtist) {
            if let r = try await get(title: title, artist: artist, album: query.album, duration: query.duration) { add(r) }
            if !records.isEmpty { break }
            try Task.checkCancellation()
        }
        // 2. поиск (если точного попадания нет или в нём нет пословной разметки — вдруг есть другая запись)
        if records.isEmpty || !records.contains(where: { $0.hasWordSync == true }) {
            do {
                var found: [Record] = []
                var artistsToTry = [primaryArtist]
                if query.artist != primaryArtist { artistsToTry.append(query.artist) }
                for a in artistsToTry {
                    found = try await search(title: parsed.display, artist: a)
                    if !found.isEmpty { break }
                    try Task.checkCancellation()
                }
                for r in found { add(r) }
                if found.isEmpty, records.isEmpty {
                    for r in try await search(q: "\(primaryArtist) \(parsed.display)") { add(r) }
                }
            } catch is CancellationError {
                throw LyricsError.cancelled
            } catch LyricsError.cancelled {
                throw LyricsError.cancelled
            } catch {
                // Дополнительный поиск не обязателен, если запись уже есть.
                if records.isEmpty { throw error }
                Log.net.info("lrclib: поиск не удался, остаёмся с точным попаданием")
            }
        }

        // 3. оценка и отбор
        func candidates() -> [TrackCandidate] {
            records.map { r in
                TrackCandidate(id: String(r.id), title: r.trackName ?? r.name ?? "", artists: [r.artistName ?? ""],
                               album: r.albumName, duration: r.duration)
            }
        }
        var triage = matcher.triage(query, candidates())
        // Структурный поиск ничего подходящего не дал (другое написание исполнителя/названия) — свободный запрос `q`.
        if triage.accepted.isEmpty, triage.nearMisses.isEmpty {
            if let extra = try? await search(q: "\(parsed.display) \(primaryArtist)") {
                for r in extra { add(r) }
                triage = matcher.triage(query, candidates())
            }
        }
        let ranked = triage.accepted
        var out: [Lyrics] = []
        for (cand, ev) in ranked.prefix(maxResults) {
            guard let rec = records.first(where: { String($0.id) == cand.id }) else { continue }
            let src = LyricsSource(provider: .lrclib, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                   duration: cand.duration, confidence: ev.score,
                                   matchKind: ev.isrcMatch ? .isrc : .metadata)
            if let l = Self.makeLyrics(rec, source: src) { out.append(l) }
        }
        // word → line → plain, внутри уровня — по уверенности
        out.sort { a, b in
            if a.syncType != b.syncType { return a.syncType > b.syncType }
            return a.source.confidence > b.source.confidence
        }
        if out.isEmpty {
            // Ничего подходящего — предлагаем «почти совпадения» (другая длительность) только как варианты на выбор.
            for (cand, ev, reason) in triage.nearMisses.prefix(Self.maxNearMisses) {
                guard let rec = records.first(where: { String($0.id) == cand.id }) else { continue }
                let src = LyricsSource(provider: .lrclib, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                       duration: cand.duration, confidence: ev.score, matchKind: .metadata,
                                       matchQuality: .nearMiss(reason))
                if let l = Self.makeLyrics(rec, source: src) { out.append(l) }
            }
        }
        var note: String?
        if !out.contains(where: { !$0.source.matchQuality.isNearMiss }) {
            note = triage.summary
            if !triage.accepted.isEmpty { note! += ", у принятых нет текста" }
        }
        return ProviderResponse(lyrics: out, note: note)
    }

    static let maxNearMisses = 2

    // MARK: - запросы

    static func primaryArtist(_ artist: String) -> String {
        let parts = TextNormalizer.splitArtistsRaw(artist)
        return parts.first ?? artist
    }

    static func signatures(query: TrackQuery, parsed: TextNormalizer.ParsedTitle, primary: String) -> [(String, String)] {
        let out: [(String, String)] = [(query.title, query.artist), (parsed.display, primary), (parsed.display, query.artist)]
        var seen = Set<String>()
        return out.filter { seen.insert($0.0 + "\u{1}" + $0.1).inserted }
    }

    func get(title: String, artist: String, album: String?, duration: TimeInterval?) async throws -> Record? {
        var q: [(String, String)] = [("track_name", title), ("artist_name", artist)]
        if let a = album, !a.isEmpty { q.append(("album_name", a)) }
        if let d = duration { q.append(("duration", String(Int(d.rounded())))) }
        guard let url = URLBuilder.url(baseURL + "/api/get", query: q) else { return nil }
        let resp = try await http.send(request(url))
        if resp.status == 404 { return nil }
        try resp.requireJSON("LRCLIB")
        // Раньше `try?` — HTML-заглушка или обрезанный ответ превращались в «не найдено» (и в негативный кэш).
        do { return try JSONDecoder().decode(Record.self, from: resp.data) } catch { throw LyricsError.badResponse("LRCLIB: ответ /api/get не разобран") }
    }

    func search(title: String, artist: String) async throws -> [Record] {
        try await searchRequest([("track_name", title), ("artist_name", artist)])
    }

    func search(q: String) async throws -> [Record] {
        try await searchRequest([("q", q)])
    }

    private func searchRequest(_ query: [(String, String)]) async throws -> [Record] {
        guard let url = URLBuilder.url(baseURL + "/api/search", query: query) else { return [] }
        let resp = try await http.send(request(url))
        if resp.status == 404 { return [] }
        try resp.requireJSON("LRCLIB")
        do { return try JSONDecoder().decode([Record].self, from: resp.data) } catch { throw LyricsError.badResponse("LRCLIB: ответ /api/search не разобран") }
    }

    private func request(_ url: URL) -> URLRequest {
        .make(url, headers: ["User-Agent": UserAgent.amnl, "Lrclib-Client": UserAgent.amnl, "Accept": "application/json"], timeout: 10)
    }

    // MARK: - запись → Lyrics

    static func makeLyrics(_ r: Record, source: LyricsSource) -> Lyrics? {
        if r.instrumental == true {
            return Lyrics(source: source, syncType: .none, lines: [], isInstrumental: true)
        }
        if let yaml = r.lyricsfile, !yaml.isEmpty, let l = try? parseLyricsfile(yaml, source: source) { return l }
        if let s = r.syncedLyrics, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var opts = LRCParser.Options()
            opts.trackDuration = r.duration
            var src = source; src.format = "syncedLyrics"
            let l = LRCParser.parse(s, source: src, options: opts)
            if l.syncType != .none { return l }
        }
        if let p = r.plainLyrics, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var src = source; src.format = "plainLyrics"
            return LRCParser.parse(p, source: src)
        }
        return nil
    }

    /// `lyricsfile`: YAML `version/metadata/lines[{text,start_ms,end_ms,words[{text,start_ms}]}]`.
    /// Возвращает `nil` для текста без слов (тогда берём `syncedLyrics`), чтобы не терять качество.
    static func parseLyricsfile(_ yaml: String, source: LyricsSource) throws -> Lyrics? {
        let root = try MiniYAML.parse(yaml)
        guard let linesNode = root["lines"]?.array, !linesNode.isEmpty else { return nil }
        var lines: [LyricLine] = []
        var anyWords = false
        for (i, item) in linesNode.enumerated() {
            let text = item["text"]?.string ?? ""
            let begin = item["start_ms"]?.double.map { $0 / 1000 }
            let end = item["end_ms"]?.double.map { $0 / 1000 }
            var words: [LyricWord] = []
            if let ws = item["words"]?.array, !ws.isEmpty {
                var segs: [SyllableSupport.Segment] = []
                let starts = ws.map { $0["start_ms"]?.double.map { $0 / 1000 } }
                for (j, w) in ws.enumerated() {
                    guard let t = w["text"]?.string, let s = starts[j] else { continue }
                    var e = w["end_ms"]?.double.map { $0 / 1000 }
                    if e == nil { e = (j + 1 < ws.count ? starts[j + 1] : nil) ?? end ?? s }
                    segs.append(.init(text: t, begin: s, duration: max(0, (e ?? s) - s)))
                }
                words = SyllableSupport.words(from: segs)
            }
            if !words.isEmpty { anyWords = true }
            lines.append(LyricLine(key: "L\(i + 1)", begin: begin ?? words.first?.begin, end: end ?? words.last?.end,
                                   text: words.isEmpty ? text : words.joinedText(), words: words))
        }
        guard lines.contains(where: { $0.begin != nil }) else { return nil }
        // Только если слов действительно много; иначе это построчный текст — пусть разберёт LRC-ветка
        guard anyWords else { return nil }
        for i in lines.indices where lines[i].end == nil {
            lines[i].end = i + 1 < lines.count ? lines[i + 1].begin : lines[i].begin
        }
        var src = source
        src.format = "lyricsfile"
        let meta = root["metadata"]
        return Lyrics(source: src, language: meta?["language"]?.string, syncType: .word, lines: lines,
                      duration: meta?["duration_ms"]?.double.map { $0 / 1000 })
    }
}
