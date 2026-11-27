import Foundation

/// AMLL TTML DB (github.com/amll-dev/amll-ttml-db): пословные TTML.
/// Устройство репозитория (проверено 14.11.2026): `<платформа>-lyrics/<id>.ttml` и `<платформа>-lyrics/index.jsonl`;
/// платформы `am` (Apple Music id), `ncm` (NetEase id), `qq` (QQ mid), `spotify`. В `index.jsonl` у записи — `id` и
/// пары `metadata` (`musicName`, `artists`, `album`, `isrc`, `appleMusicId`, `ncmMusicId`, `qqMusicId`, `spotifyId`).
public struct AMLLProvider: LyricsProvider {
    public let id: LyricsProviderID = .amll
    /// Ищет по `neteaseId`/`qqSongMid`, которые находят другие провайдеры.
    public var usesCrossProviderIDs: Bool { true }

    public struct Options: Sendable {
        public var rawBase = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"
        /// Искать по индексам (несколько МБ, кэшируются на диск), если прямого попадания по id нет.
        public var useIndexSearch = true
        /// Как поступать, когда индекса на диске ещё нет (или он устарел).
        public var indexDownload: IndexDownload = .background
        public var indexTTL: TimeInterval = 24 * 3600
        public var requestTimeout: TimeInterval = 15
        public init() {}
    }

    /// `background` — не задерживать каскад: поиск идёт по тому, что есть на диске, а свежий индекс докачивается
    /// в фоне для следующих запросов (первый раз по метаданным ничего не найдётся; по id каталога — найдётся).
    /// `await` — дождаться скачивания (первый запрос будет долгим, ~10 МБ).
    public enum IndexDownload: Sendable { case background, await }

    let http: HTTPClient
    let options: Options
    let matcher: TrackMatcher
    let indexStore: AMLLIndexStore
    /// Итог поиска по индексу для отпечатка запроса: повторный запрос каскада (с id из других сервисов) и исчерпывающий
    /// поиск после обычного не гоняют поиск по индексу заново.
    let indexMemo = ResponseMemo<ProviderResponse>(ttl: 600, capacity: 64)

    public init(http: HTTPClient, cacheDirectory: URL? = nil, options: Options = Options(),
                matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 8))) {
        self.http = http
        self.options = options
        self.matcher = matcher
        self.indexStore = AMLLIndexStore(http: http, base: options.rawBase, directory: cacheDirectory,
                                         ttl: options.indexTTL, timeout: options.requestTimeout)
    }

    /// Заранее скачать индексы (например, при запуске по Wi-Fi), чтобы поиск по метаданным работал сразу.
    public func prefetchIndexes() async {
        for folder in ["am-lyrics", "ncm-lyrics"] { _ = try? await indexStore.entries(folder: folder, mode: .await) }
    }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        try await response(for: query).lyrics
    }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        // 1. прямое попадание по id каталога Apple
        if let am = query.catalogId, let l = try await file(folder: "am-lyrics", id: am, query: query, kind: .catalogID, confidence: 1) {
            return ProviderResponse(lyrics: [l])
        }
        if let ne = query.neteaseId, let l = try await file(folder: "ncm-lyrics", id: ne, query: query, kind: .externalID, confidence: 1, verify: true) {
            return ProviderResponse(lyrics: [l])
        }
        if let qq = query.qqSongMid, let l = try await file(folder: "qq-lyrics", id: qq, query: query, kind: .externalID, confidence: 1, verify: true) {
            return ProviderResponse(lyrics: [l])
        }
        guard options.useIndexSearch else { return ProviderResponse(lyrics: [], note: "поиск по индексу выключен") }

        // 2. индексы: сначала Apple (там есть ISRC и id), потом NetEase (самая большая)
        let memoKey = [query.fingerprint, query.isrc ?? "", query.catalogId ?? ""].joined(separator: "|")
        if let cached = await indexMemo.get(memoKey) { return cached }
        let r = try await indexSearch(query)
        if r.complete { await indexMemo.set(memoKey, r.response) }
        return r.response
    }

    private func indexSearch(_ query: TrackQuery) async throws -> (response: ProviderResponse, complete: Bool) {
        var complete = true
        var near: [Lyrics] = []
        var checked = 0
        for (folder, key) in [("am-lyrics", "am"), ("ncm-lyrics", "ncm")] {
            guard let entries = try await indexStore.entries(folder: folder, mode: options.indexDownload) else { complete = false; continue }
            try Task.checkCancellation()
            let hits = Self.search(entries, query: query, matcher: matcher, platform: key)
            checked += hits.count
            for hit in hits.prefix(2) {
                if let l = try await file(folder: folder, id: hit.entry.id, query: query, kind: hit.kind,
                                          confidence: hit.score, verify: true) {
                    if l.source.matchQuality.isNearMiss { near.append(l); continue }
                    return (ProviderResponse(lyrics: [l]), complete)
                }
            }
        }
        if !near.isEmpty { return (ProviderResponse(lyrics: Array(near.prefix(2)), note: "кандидатов в индексе: \(checked), текст не совпал по длительности трека"), complete) }
        var note = checked == 0 ? "в индексах AMLL нет подходящей записи (id каталога, ISRC, название)" : "кандидатов в индексе: \(checked), текст не найден"
        if !complete { note += "; индекс ещё скачивается" }
        return (ProviderResponse(lyrics: [], note: note), complete)
    }

    // MARK: - индекс

    struct Hit { var entry: AMLLIndexEntry; var score: Double; var kind: LyricsSource.MatchKind }

    static func search(_ entries: [AMLLIndexEntry], query: TrackQuery, matcher: TrackMatcher, platform: String) -> [Hit] {
        var hits: [Hit] = []
        if let isrc = query.isrc {
            for e in entries where e.isrcs.contains(isrc) { hits.append(Hit(entry: e, score: 1, kind: .isrc)) }
        }
        if let am = query.catalogId {
            for e in entries where e.appleIDs.contains(am) && !hits.contains(where: { $0.entry.id == e.id }) {
                hits.append(Hit(entry: e, score: 1, kind: .catalogID))
            }
        }
        if !hits.isEmpty { return hits }
        // по метаданным: у AMLL нет длительности — доверие ниже, порог выше
        var strict = matcher
        strict.config.minScoreWithoutDuration = 0.86
        var cands: [TrackCandidate] = []
        var byID: [String: AMLLIndexEntry] = [:]
        let qTitle = TextNormalizer.parseTitle(query.title).base
        let qTokens = AMLLIndexEntry.tokens(qTitle)
        for e in entries {
            // дешёвый предфильтр: общее слово в названии (в латинском скелете — кириллица и латиница сравнимы)
            if qTokens.isDisjoint(with: e.titleTokens) { continue }
            if TextNormalizer.similarity(qTitle, e.titleBase) < 0.55 { continue }
            cands.append(TrackCandidate(id: e.id, title: e.title, artists: e.artists, album: e.album))
            byID[e.id] = e
        }
        var q = query
        q.duration = nil   // у записей нет длительности
        for r in strict.rank(q, cands) where r.evaluation.accepted {
            if let e = byID[r.candidate.id] { hits.append(Hit(entry: e, score: min(r.evaluation.score, 0.95), kind: .metadata)) }
            if hits.count >= 3 { break }
        }
        return hits
    }

    // MARK: - файл

    func file(folder: String, id: String, query: TrackQuery, kind: LyricsSource.MatchKind, confidence: Double,
              verify: Bool = false) async throws -> Lyrics? {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(options.rawBase)/\(folder)/\(safe).ttml") else { return nil }
        let resp = try await http.send(.make(url, headers: ["User-Agent": UserAgent.amnl, "Accept": "text/plain"],
                                             timeout: options.requestTimeout))
        if resp.status == 404 { return nil }
        try resp.requireOK()
        let src = LyricsSource(provider: .amll, trackID: "\(folder)/\(id)", confidence: confidence, matchKind: kind)
        var lyrics = try TTMLParser.parse(resp.data, source: src)
        lyrics.source.title = lyrics.metadata["musicName"]?.first
        lyrics.source.artist = lyrics.metadata["artists"]?.joined(separator: ", ")
        if lyrics.isEmpty { return nil }
        // проверка по длительности: конец последней строки не должен сильно превышать длительность трека
        if verify, let qd = query.duration, let last = lyrics.lines.compactMap({ $0.end }).max(), last > qd + 20 {
            Log.net.info("amll: \(id, privacy: .public) — текст длиннее трека, только как near-miss")
            lyrics.source.matchQuality = .nearMiss("текст заканчивается на \(Int(last.rounded())) с, а трек — \(Int(qd.rounded())) с")
            return lyrics
        }
        // `source.duration` — длительность записи у источника. У AMLL её нет (конец текста ≠ длина трека: «Numb» отвергался
        // при сверке по длительности у потребителей), поэтому nil; конец текста — в `lyrics.duration`.
        lyrics.source.duration = nil
        return lyrics
    }
}

struct AMLLIndexEntry: Sendable, Equatable {
    var id: String
    var title: String
    var artists: [String]
    var album: String?
    var isrcs: [String]
    var appleIDs: [String]
    /// Нормализованная основа названия и её слова в латинском «скелете» — считаются один раз при разборе индекса,
    /// а не на каждый запрос (раньше поиск по ~20 тыс. записей занимал 5–9 с в отладочной сборке).
    var titleBase: String = ""
    var titleTokens: Set<Substring> = []

    init(id: String, title: String, artists: [String], album: String?, isrcs: [String], appleIDs: [String]) {
        self.id = id; self.title = title; self.artists = artists; self.album = album; self.isrcs = isrcs; self.appleIDs = appleIDs
        titleBase = TextNormalizer.parseTitle(title).base
        titleTokens = AMLLIndexEntry.tokens(titleBase)
    }

    static func tokens(_ base: String) -> Set<Substring> {
        Set(TextNormalizer.latinSkeleton(base).split(separator: " "))
    }
}

/// Скачивает `index.jsonl`, держит копию на диске (TTL, условный запрос по ETag) и в памяти.
actor AMLLIndexStore {
    private let http: HTTPClient
    private let base: String
    private let directory: URL?
    private let ttl: TimeInterval
    private let timeout: TimeInterval
    /// `date` — когда индекс скачан (дата файла), `loaded` — когда разобран в память.
    private var memory: [String: (date: Date, loaded: Date, entries: [AMLLIndexEntry])] = [:]
    /// Когда последний раз пытались обновить индекс (чтобы при недоступном GitHub не долбить сеть и не разбирать файл заново).
    private var lastRefreshAttempt: [String: Date] = [:]
    private var inflight: [String: Task<[AMLLIndexEntry], Error>] = [:]

    init(http: HTTPClient, base: String, directory: URL?, ttl: TimeInterval, timeout: TimeInterval) {
        self.http = http
        self.base = base
        self.directory = directory
        self.ttl = ttl
        self.timeout = timeout
    }

    /// Записи индекса. `nil` — индекса пока нет, он докачивается в фоне (режим `.background`).
    func entries(folder: String, mode: AMLLProvider.IndexDownload) async throws -> [AMLLIndexEntry]? {
        if let m = memory[folder] {
            if Date().timeIntervalSince(m.date) < ttl { return m.entries }
            // Устаревший индекс в памяти: не разбирать файл заново на каждый запрос (раньше так и было, пока фоновое
            // обновление не закончится — а если GitHub недоступен, то всегда). Отдаём что есть, обновление — не чаще раза в 10 мин.
            if mode == .background {
                if Date().timeIntervalSince(lastRefreshAttempt[folder] ?? .distantPast) > 600 { startRefresh(folder) }
                return m.entries
            }
        }
        // Копия на диске (в том числе устаревшая) годится для поиска сразу.
        if let (data, date) = readDisk(folder) {
            let parsed = Self.parse(data)
            memory[folder] = (date, Date(), parsed)
            if Date().timeIntervalSince(date) < ttl { return parsed }
            switch mode {
            case .background: startRefresh(folder); return parsed
            case .await: return (try? await refresh(folder)) ?? parsed
            }
        }
        switch mode {
        case .background:
            startRefresh(folder)
            return nil
        case .await:
            return try await refresh(folder)
        }
    }

    private func startRefresh(_ folder: String) {
        guard inflight[folder] == nil else { return }
        lastRefreshAttempt[folder] = Date()
        inflight[folder] = Task { [self] in try await download(folder) }
        Task { [self] in
            _ = try? await inflight[folder]?.value
            clearInflight(folder)
        }
    }

    private func clearInflight(_ folder: String) { inflight[folder] = nil }

    private func refresh(_ folder: String) async throws -> [AMLLIndexEntry] {
        if let t = inflight[folder] { return try await t.value }
        let t = Task { [self] in try await download(folder) }
        inflight[folder] = t
        defer { inflight[folder] = nil }
        return try await t.value
    }

    private func fileURLs(_ folder: String) -> (data: URL, etag: URL)? {
        guard let d = directory else { return nil }
        return (d.appendingPathComponent("amll-index-\(folder).jsonl"), d.appendingPathComponent("amll-index-\(folder).etag"))
    }

    private func readDisk(_ folder: String) -> (Data, Date)? {
        guard let f = fileURLs(folder)?.data, let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let date = attrs[.modificationDate] as? Date, let data = try? Data(contentsOf: f), !data.isEmpty else { return nil }
        return (data, date)
    }

    private func download(_ folder: String) async throws -> [AMLLIndexEntry] {
        guard let url = URL(string: "\(base)/\(folder)/index.jsonl") else { throw LyricsError.badResponse("URL индекса") }
        var headers = ["User-Agent": UserAgent.amnl]
        let files = fileURLs(folder)
        var cached: Data?
        if let f = files, let (d, _) = readDisk(folder), let etag = try? String(contentsOf: f.etag, encoding: .utf8) {
            headers["If-None-Match"] = etag
            cached = d
        }
        let resp = try await http.send(.make(url, headers: headers, timeout: max(timeout, 60)))
        let data: Data
        if resp.status == 304, let c = cached {
            data = c
            if let f = files { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.data.path) }
        } else {
            try resp.requireOK()
            data = resp.data
            if let f = files {
                try? FileManager.default.createDirectory(at: f.data.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? resp.data.write(to: f.data, options: .atomic)
                if let etag = resp.header("ETag") { try? etag.write(to: f.etag, atomically: true, encoding: .utf8) }
            }
        }
        let parsed = Self.parse(data)
        memory[folder] = (Date(), Date(), parsed)
        Log.net.info("amll: индекс \(folder, privacy: .public): \(parsed.count) записей")
        return parsed
    }

    static func parse(_ data: Data) -> [AMLLIndexEntry] {
        var out: [AMLLIndexEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = obj["id"] as? String, let meta = obj["metadata"] as? [[Any]] else { continue }
            var dict: [String: [String]] = [:]
            for pair in meta where pair.count == 2 {
                if let k = pair[0] as? String, let v = pair[1] as? [String] { dict[k] = v }
            }
            guard let title = dict["musicName"]?.first else { continue }
            out.append(AMLLIndexEntry(id: id, title: title, artists: dict["artists"] ?? [], album: dict["album"]?.first,
                                      isrcs: (dict["isrc"] ?? []).map(TrackQuery.normalizeISRC),
                                      appleIDs: dict["appleMusicId"] ?? []))
        }
        return out
    }
}
