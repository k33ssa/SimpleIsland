import Foundation

/// Тексты Apple Music (`amp-api`): `/syllable-lyrics` → при 404 `/lyrics`.
/// Нужен media-user-token пользователя (из `CredentialStore`); developer token добывается сам.
/// Токены в логи не попадают. Тексты Apple — только для локального кэша на устройстве пользователя.
public struct AppleMusicProvider: LyricsProvider {
    public let id: LyricsProviderID = .appleMusic

    public struct Options: Sendable {
        /// Язык интерфейса для параметра `l` (по умолчанию — первый из системных).
        public var language: String
        /// Запрашивать переводы/транслитерации (`extend=ttmlLocalizations`).
        public var requestLocalizations = true
        public var host = "https://amp-api.music.apple.com"
        public var requestTimeout: TimeInterval = 10
        public init(language: String = Locale.preferredLanguages.first ?? "en-US") { self.language = language }
    }

    let http: HTTPClient
    let credentials: CredentialStore
    let tokens: AppleDeveloperTokenProvider
    let options: Options
    let matcher: TrackMatcher
    private let storefrontCache = StorefrontCache()

    public init(http: HTTPClient, credentials: CredentialStore, tokens: AppleDeveloperTokenProvider? = nil,
                options: Options = Options(), matcher: TrackMatcher = TrackMatcher()) {
        self.http = http
        self.credentials = credentials
        self.tokens = tokens ?? AppleDeveloperTokenProvider(http: http, store: credentials)
        self.options = options
        self.matcher = matcher
    }

    public func isAvailable() async -> Bool {
        guard let v = try? await credentials.value(for: .mediaUserToken) else { return false }
        return !(v.isEmpty)
    }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        try await response(for: query).lyrics
    }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        // По id каталога совпадение всегда точное (`.exact`); через поиск по метаданным — только принятые матчером.
        guard let mut = try await credentials.value(for: .mediaUserToken), !mut.isEmpty else {
            throw LyricsError.notConfigured("media-user-token")
        }
        let sf = try await storefront(for: query, mut: mut)

        var trackID = query.catalogId
        var kind: LyricsSource.MatchKind = .catalogID
        var confidence = 1.0
        var found: (title: String?, artist: String?, duration: TimeInterval?)?
        if trackID == nil {
            guard let r = try await resolve(query, storefront: sf, mut: mut) else {
                return ProviderResponse(lyrics: [], note: "трек не найден в каталоге Apple по названию и исполнителю (id каталога нет)")
            }
            trackID = r.id; kind = r.kind; confidence = r.confidence
            found = (r.title, r.artist, r.duration)
        }
        guard let id = trackID else { return ProviderResponse(lyrics: [], note: "нет id каталога") }

        for path in ["syllable-lyrics", "lyrics"] {
            guard let ttml = try await fetchTTML(path: path, id: id, storefront: sf, mut: mut) else { continue }
            let src = LyricsSource(provider: .appleMusic, trackID: id, title: found?.title ?? query.title,
                                   artist: found?.artist ?? query.artist, duration: found?.duration,
                                   confidence: confidence, matchKind: kind, format: nil)
            let parsed = try TTMLParser.parse(ttml, source: src)
            guard !parsed.isEmpty else { continue }
            Log.net.info("apple: \(path, privacy: .public) \(id, privacy: .public) → \(parsed.syncType.rawValue, privacy: .public)")
            return ProviderResponse(lyrics: [parsed])
        }
        return ProviderResponse(lyrics: [], note: "у Apple нет текста для этого трека")
    }

    // MARK: - storefront

    private actor StorefrontCache {
        var value: String?
        func get() -> String? { value }
        func set(_ v: String) { value = v }
    }

    func storefront(for query: TrackQuery, mut: String) async throws -> String {
        if let s = query.storefront, !s.isEmpty { return s }
        if let s = await storefrontCache.get() { return s }
        if let s = try await credentials.value(for: .appleStorefront), !s.isEmpty {
            await storefrontCache.set(s)
            return s
        }
        let data = try await amp(path: "/v1/me/storefront", query: [], mut: mut)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]], let sf = arr.first?["id"] as? String else {
            throw LyricsError.badResponse("storefront")
        }
        await storefrontCache.set(sf)
        try? await credentials.set(sf, for: .appleStorefront)
        return sf
    }

    // MARK: - запросы

    /// GET к amp-api с авторизацией. На 401/403 один раз перевыпускает developer token.
    func amp(path: String, query: [(String, String)], mut: String) async throws -> Data {
        var refreshed = false
        while true {
            let token = try await tokens.token(forceRefresh: false)
            guard let url = URLBuilder.url(options.host + path, query: query) else { throw LyricsError.badResponse("URL") }
            let req = URLRequest.make(url, headers: [
                "Authorization": "Bearer \(token)",
                "media-user-token": mut,
                "Origin": "https://music.apple.com",
                "Referer": "https://music.apple.com/",
                "User-Agent": UserAgent.browser,
                "Accept": "application/json",
            ], timeout: options.requestTimeout)
            let resp = try await http.send(req)
            if resp.status == 401 || resp.status == 403 {
                if !refreshed {
                    refreshed = true
                    Log.net.info("apple: \(resp.status) — перевыпускаю developer token")
                    await tokens.invalidate()
                    _ = try await tokens.token(forceRefresh: true)
                    continue
                }
                throw LyricsError.unauthorized
            }
            if resp.status == 404 { throw LyricsError.notFound }
            try resp.requireOK()
            return resp.data
        }
    }

    func fetchTTML(path: String, id: String, storefront: String, mut: String) async throws -> String? {
        var query: [(String, String)] = [("l", options.language)]
        if options.requestLocalizations { query.append(("extend", "ttmlLocalizations")) }
        let full = "/v1/catalog/\(storefront)/songs/\(id)/\(path)"
        let data: Data
        do {
            data = try await amp(path: full, query: query, mut: mut)
        } catch LyricsError.notFound {
            return nil
        } catch LyricsError.badStatus(400) where options.requestLocalizations {
            // сервер не принял extend — повторим без него
            do { data = try await amp(path: full, query: [("l", options.language)], mut: mut) }
            catch LyricsError.notFound { return nil }
        }
        return Self.extractTTML(from: data, preferredLanguage: options.language)
    }

    /// `data[0].attributes.ttmlLocalizations` (строка или словарь локаль→TTML) либо `ttml`.
    static func extractTTML(from data: Data, preferredLanguage: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]], let attrs = arr.first?["attributes"] as? [String: Any] else { return nil }
        if let s = attrs["ttmlLocalizations"] as? String, !s.isEmpty { return s }
        if let d = attrs["ttmlLocalizations"] as? [String: Any], !d.isEmpty {
            let lang = preferredLanguage.lowercased()
            let short = lang.split(separator: "-").first.map(String.init) ?? lang
            let keys = d.keys.sorted()
            let key = keys.first { $0.lowercased() == lang } ?? keys.first { $0.lowercased().hasPrefix(short) } ?? keys.first!
            if let s = d[key] as? String, !s.isEmpty { return s }
        }
        if let s = attrs["ttml"] as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - поиск id каталога (для треков без playbackStoreID)

    struct Resolved { var id: String; var kind: LyricsSource.MatchKind; var confidence: Double; var title: String?; var artist: String?; var duration: TimeInterval? }

    func resolve(_ query: TrackQuery, storefront sf: String, mut: String) async throws -> Resolved? {
        if let isrc = query.isrc {
            let data = try? await amp(path: "/v1/catalog/\(sf)/songs", query: [("filter[isrc]", isrc)], mut: mut)
            if let data, let c = Self.candidates(from: data, path: ["data"]), let first = c.first {
                return Resolved(id: first.id, kind: .isrc, confidence: 1, title: first.title, artist: first.artists.first, duration: first.duration)
            }
        }
        let term = "\(TextNormalizer.parseTitle(query.title).display) \(query.artist)"
        let data = try await amp(path: "/v1/catalog/\(sf)/search", query: [("term", term), ("types", "songs"), ("limit", "10")], mut: mut)
        guard let cands = Self.candidates(from: data, path: ["results", "songs", "data"]) else { return nil }
        guard let top = matcher.rank(query, cands).first, top.evaluation.accepted else { return nil }
        return Resolved(id: top.candidate.id, kind: .metadata, confidence: top.evaluation.score,
                        title: top.candidate.title, artist: top.candidate.artists.first, duration: top.candidate.duration)
    }

    static func candidates(from data: Data, path: [String]) -> [TrackCandidate]? {
        guard var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in path {
            guard let d = node as? [String: Any], let next = d[key] else { return nil }
            node = next
        }
        guard let arr = node as? [[String: Any]] else { return nil }
        let out: [TrackCandidate] = arr.compactMap { item in
            guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any],
                  let name = a["name"] as? String else { return nil }
            let artist = (a["artistName"] as? String) ?? ""
            let ms = (a["durationInMillis"] as? NSNumber)?.doubleValue
            return TrackCandidate(id: id, title: name, artists: [artist], album: a["albumName"] as? String,
                                  duration: ms.map { $0 / 1000 }, isrc: a["isrc"] as? String)
        }
        return out.isEmpty ? nil : out
    }
}
