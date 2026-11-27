import Foundation
import LyricsCore

/// Deezer — тексты без входа (16.11): поиск `api.deezer.com/search` (открытый), текст — GraphQL `pipe.deezer.com/api`
/// с анонимным JWT из `auth.deezer.com/login/anonymous` (живёт 6 мин, ключей пользователя не нужно). Отдаёт пословный
/// (`synchronizedWordByWordLines`), построчный (`synchronizedLines`) или простой текст (`text`).
///
/// Проверено curl'ом 16.11.2026 с этого Мака: русский рэп SODA LUV — DTF, TURBINA, CMD + Z, КАРИНА построчно; TAMPON —
/// только простой; The Weeknd «Blinding Lights» — пословно. Таблица по источникам — отчёт ветки work/mxm.
///
/// Подключён к каскаду LyricsCore через публичный протокол `LyricsProvider`. `LyricsProviderID` в пакете закрытый, своего
/// значения для внешних источников нет — Deezer ходит под `.local` (в LyricsCore 16.11 `.local` никем не занят и движком
/// особо не обрабатывается). Когда владелец LyricsCore добавит `.deezer` (патч описан владельцу) — поменять `id`.
///
/// Бережно к сервису: не чаще запроса в 0,25 с на процесс, после отказа (403/429/5xx, нет JWT) — пауза 30 с → 2 → 8 →
/// 32 мин → 1 ч, сброс после первого успешного ответа. JWT в памяти процесса, не на диске, нигде не печатается.
struct DeezerLyricsProvider: LyricsProvider {
    static let providerID: LyricsProviderID = .local
    let id: LyricsProviderID = DeezerLyricsProvider.providerID

    let http: HTTPClient
    let gate: DeezerGate
    let matcher: TrackMatcher
    let apiHost: String
    let pipeHost: String
    let authHost: String
    /// Сколько подходящих записей спрашивать (обычно хватает первой: у альбома и делюкса один текст).
    let maxCandidates: Int

    init(http: HTTPClient, gate: DeezerGate = .shared, apiHost: String = "https://api.deezer.com",
         pipeHost: String = "https://pipe.deezer.com", authHost: String = "https://auth.deezer.com", maxCandidates: Int = 2,
         matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 6))) {
        self.http = http
        self.gate = gate
        self.apiHost = apiHost
        self.pipeHost = pipeHost
        self.authHost = authHost
        self.maxCandidates = maxCandidates
        self.matcher = matcher
    }

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] { try await response(for: query).lyrics }

    func response(for query: TrackQuery) async throws -> ProviderResponse {
        let parsed = TextNormalizer.parseTitle(query.title)
        let primary = TextNormalizer.splitArtistsRaw(query.artist).first ?? query.artist
        var records: [Track] = []
        var seen = Set<String>()
        // Свободный запрос «исполнитель название»: строгий `artist:"…" track:"…"` не находит «TAMPON|» (16.11).
        for term in ["\(primary) \(parsed.display)", parsed.display] {
            for t in try await search(term) where seen.insert(t.id).inserted { records.append(t) }
            if !matcher.triage(query, records.map(\.candidate)).accepted.isEmpty { break }
            try Task.checkCancellation()
        }
        let triage = matcher.triage(query, records.map(\.candidate))
        var out: [LyricsCore.Lyrics] = []
        var errors = 0
        var lastError: Error?
        for (cand, ev) in triage.accepted.prefix(maxCandidates) {
            let src = LyricsSource(provider: id, trackID: cand.id, title: cand.title, artist: cand.artists.first,
                                   duration: cand.duration, confidence: ev.score, matchKind: ev.isrcMatch ? .isrc : .metadata)
            do {
                if let l = try await lyrics(trackID: cand.id, source: src) { out.append(l) }
            } catch let e as LyricsError where e == .cancelled {
                throw e
            } catch {
                errors += 1; lastError = error
            }
            if out.contains(where: { $0.syncType == .word }) { break }
        }
        if out.isEmpty, errors > 0, let lastError { throw lastError }
        out.sort { $0.syncType != $1.syncType ? $0.syncType > $1.syncType : $0.source.confidence > $1.source.confidence }
        var note: String?
        if out.isEmpty { note = triage.summary + (triage.accepted.isEmpty ? "" : ", у принятых нет текста") }
        return ProviderResponse(lyrics: out, note: note)
    }

    // MARK: Поиск

    struct Track {
        var id: String
        var candidate: TrackCandidate
    }

    func search(_ term: String) async throws -> [Track] {
        guard var c = URLComponents(string: apiHost + "/search") else { return [] }
        c.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "15")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        let r = try await gate.send(req, http: http)
        return try Self.parseSearch(r.data)
    }

    /// Ответ `api.deezer.com/search` → кандидаты. Ошибка в теле (`{"error": {"code": 4, "message": "Quota limit exceeded"}}`)
    /// — исключение (лимит), а не «не найдено».
    static func parseSearch(_ data: Data) throws -> [Track] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.badResponse("deezer search: не JSON")
        }
        if let e = obj["error"] as? [String: Any] {
            let code = BodyCodeInt(e["code"]) ?? 0
            if code == 4 { throw LyricsError.rateLimited(retryAfter: 5) }
            throw LyricsError.badResponse("deezer search: \(code)")
        }
        let list = obj["data"] as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let id = BodyCodeInt(s["id"]).map(String.init) ?? (s["id"] as? String) else { return nil }
            let rawTitle = (s["title"] as? String) ?? ""
            let artist = (s["artist"] as? [String: Any])?["name"] as? String ?? ""
            let album = (s["album"] as? [String: Any])?["title"] as? String
            let dur = (s["duration"] as? NSNumber)?.doubleValue
            // «TAMPON|» — так в каталоге Deezer (и NetEase/QQ): палку на конце убираем, иначе сравнение названий хуже.
            let title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "| ").union(.whitespaces))
            return Track(id: id, candidate: TrackCandidate(id: id, title: title, artists: [artist], album: album,
                                                            duration: dur, isrc: s["isrc"] as? String))
        }
    }

    // MARK: Текст

    static let lyricsQuery = """
    query GetLyrics($trackId: String!) { track(trackId: $trackId) { id lyrics { id text \
    synchronizedWordByWordLines { start end words { start end word } } \
    synchronizedLines { line milliseconds duration } } } }
    """

    func lyrics(trackID: String, source: LyricsSource) async throws -> LyricsCore.Lyrics? {
        for attempt in 0..<2 {
            let jwt = try await gate.jwt(http: http, authHost: authHost, forceNew: attempt > 0)
            guard let url = URL(string: pipeHost + "/api") else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
            let body: [String: Any] = ["operationName": "GetLyrics", "variables": ["trackId": trackID], "query": Self.lyricsQuery]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let r = try await gate.send(req, http: http)
            switch Self.parseLyrics(r.data, source: source) {
            case .lyrics(let l): return l
            case .none: return nil
            case .expired: continue        // JWT истёк раньше срока — один раз взять новый
            }
        }
        throw LyricsError.unauthorized
    }

    enum Parsed { case lyrics(LyricsCore.Lyrics), none, expired }

    /// Ответ GraphQL → текст LyricsCore. Пословный важнее построчного, построчный важнее простого.
    static func parseLyrics(_ data: Data, source: LyricsSource) -> Parsed {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        let errors = (obj["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        if errors.contains(where: { $0.lowercased().contains("jwt") || $0.lowercased().contains("re-authenticate") }) { return .expired }
        guard let l = ((obj["data"] as? [String: Any])?["track"] as? [String: Any])?["lyrics"] as? [String: Any] else { return .none }
        func sec(_ v: Any?) -> Double? { (v as? NSNumber).map { $0.doubleValue / 1000 } ?? (v as? String).flatMap(Double.init).map { $0 / 1000 } }
        var src = source

        let wbw = l["synchronizedWordByWordLines"] as? [[String: Any]] ?? []
        var lines: [LyricsCore.LyricLine] = []
        for (i, x) in wbw.enumerated() {
            let ws: [LyricsCore.LyricWord] = (x["words"] as? [[String: Any]] ?? []).compactMap { w in
                guard let t = (w["word"] as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty, let b = sec(w["start"]) else { return nil }
                return LyricsCore.LyricWord(text: t, begin: b, end: max(b, sec(w["end"]) ?? b))
            }
            guard let b = sec(x["start"]) ?? ws.first?.begin, !ws.isEmpty else { continue }
            lines.append(LyricsCore.LyricLine(key: "L\(i + 1)", begin: b, end: sec(x["end"]) ?? ws.last?.end, words: ws))
        }
        if !lines.isEmpty {
            src.format = "deezer-word"
            return .lyrics(LyricsCore.Lyrics(source: src, syncType: .word, lines: lines))
        }

        let synced = l["synchronizedLines"] as? [[String: Any]] ?? []
        for (i, x) in synced.enumerated() {
            guard let b = sec(x["milliseconds"]) else { continue }
            let text = ((x["line"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let end = sec(x["duration"]).flatMap { $0 > 0 ? b + $0 : nil }
            lines.append(LyricsCore.LyricLine(key: "L\(i + 1)", begin: b, end: end, text: text))
        }
        if lines.contains(where: { !$0.text.isEmpty }) {
            src.format = "deezer-line"
            return .lyrics(LyricsCore.Lyrics(source: src, syncType: .line, lines: lines))
        }

        let text = (l["text"] as? String) ?? ""
        let plain = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated().map {
            LyricsCore.LyricLine(key: "L\($0.offset + 1)", text: String($0.element).trimmingCharacters(in: .whitespaces))
        }
        guard plain.contains(where: { !$0.text.isEmpty }) else { return .none }
        src.format = "deezer-plain"
        return .lyrics(LyricsCore.Lyrics(source: src, syncType: .none, lines: plain))
    }
}

/// Число из JSON (NSNumber или строка).
private func BodyCodeInt(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }

/// Общие на процесс JWT, частота запросов и пауза после отказов Deezer.
actor DeezerGate {
    static let shared = DeezerGate()

    /// Не чаще запроса в столько секунд (у открытого API Deezer лимит 50 запросов / 5 с — мы далеко ниже).
    let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastRequest = Date.distantPast
    private var token: String?
    private var tokenUntil = Date.distantPast
    private(set) var failures = 0
    private(set) var blockedUntil = Date.distantPast

    init(minInterval: TimeInterval = 0.25, now: @escaping @Sendable () -> Date = { Date() }) {
        self.minInterval = minInterval
        self.now = now
    }

    /// Пауза после `n` отказов подряд: 30 с, 2, 8, 32 мин, дальше 1 ч.
    static func backoff(_ n: Int) -> TimeInterval { n <= 0 ? 0 : min(3600, 30 * pow(4, Double(n - 1))) }

    var isCoolingDown: Bool { now() < blockedUntil }

    func noteFailure() {
        failures += 1
        blockedUntil = now().addingTimeInterval(Self.backoff(failures))
    }

    func noteSuccess() { failures = 0; blockedUntil = .distantPast }

    /// Запрос с ограничением частоты; 403/429/5xx — отказ сервиса (пауза растёт), остальное — как есть.
    func send(_ req: URLRequest, http: HTTPClient) async throws -> HTTPResponse {
        if isCoolingDown { throw LyricsError.rateLimited(retryAfter: blockedUntil.timeIntervalSince(now())) }
        let wait = lastRequest.addingTimeInterval(minInterval).timeIntervalSince(now())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastRequest = now()
        let r = try await http.send(req)
        switch r.status {
        case 200..<300:
            noteSuccess()
            return r
        case 401:
            throw LyricsError.unauthorized
        case 403, 429, 500...599:
            noteFailure()
            throw r.status == 429 ? LyricsError.rateLimited(retryAfter: r.retryAfter) : LyricsError.badStatus(r.status)
        default:
            throw LyricsError.badStatus(r.status)
        }
    }

    /// Анонимный JWT (кеш в памяти до `exp` − 30 с). Значение не логируется.
    func jwt(http: HTTPClient, authHost: String, forceNew: Bool = false) async throws -> String {
        if !forceNew, let t = token, now() < tokenUntil { return t }
        token = nil
        guard let url = URL(string: authHost + "/login/anonymous?jo=p&rto=c") else { throw LyricsError.notConfigured("deezer auth") }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(DeezerLyricsProvider.browserUA, forHTTPHeaderField: "User-Agent")
        let r = try await send(req, http: http)
        guard let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any], let t = obj["jwt"] as? String, t.count > 20 else {
            noteFailure()
            throw LyricsError.badResponse("deezer: нет JWT")
        }
        token = t
        let exp = Self.expiry(of: t) ?? now().addingTimeInterval(300)
        tokenUntil = min(exp.addingTimeInterval(-30), now().addingTimeInterval(3600))
        return t
    }

    /// `exp` из полезной нагрузки JWT (без проверки подписи — только чтобы не спрашивать новый раньше времени).
    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = (o["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Для самотеста: сбросить состояние.
    func reset() { token = nil; tokenUntil = .distantPast; failures = 0; blockedUntil = .distantPast; lastRequest = .distantPast }
}
