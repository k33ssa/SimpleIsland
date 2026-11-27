import CryptoKit
import Foundation
import IslandCore
import LyricsCore

/// Яндекс Музыка — построчный текст (LRC) из каталога Яндекса (21.11). Нужен для треков, которых нет ни в Apple Music,
/// ни у китайских сервисов: «utopi» — cruise lirro, sutra (21.11: Apple/NetEase/QQ/KuGou/LRCLIB — нет, Deezer — только
/// простой, у Яндекса `hasAvailableSyncLyrics = true`).
///
/// Как ходим (проверено curl 21.11.2026, сверено с открытым клиентом MarshalX/yandex-music-api — `get_sign_request`,
/// `tracks_lyrics`):
/// * поиск — без входа: `GET api.music.yandex.net/search?text=…&type=track&page=0` с `X-Yandex-Music-Client`;
/// * текст — только с токеном пользователя (`Authorization: OAuth …`; без него 401 not-authenticated):
///   `GET /tracks/{id}/lyrics?format=LRC&timeStamp={unix}&sign={base64(HMAC-SHA256(ключ, "{id}{timeStamp}"))}` →
///   `result.downloadUrl` (хранилище Яндекса) → сам LRC. Пословных форматов у этого API не нашли (SYLLABLE/WORD без
///   входа не проверить — тоже 401); если в LRC окажутся метки `<мм:сс.хх>` (Enhanced LRC), `LRCParser` даст пословный.
///
/// Спрашивается, только когда учётка подключена (`isAvailable` — есть токен). Токен — файл секретов (`SecretFile`, права
/// 600, служба `local.simpleisland.lyrics`, ключ `yandexMusicToken`), уходит только на `api.music.yandex.net`, нигде не
/// печатается. Бережно к сервису: запрос не чаще 0,3 с, после 429/5xx — пауза 30 с → … → 1 ч (`YandexGate`).
///
/// В каскаде LyricsCore у внешних источников один id — `.local`, а движок помнит ответы провайдеров по id (10 мин):
/// два провайдера под `.local` получали бы ответы друг друга. Поэтому Яндекс и Deezer ходят в каскад одним составным
/// провайдером `OwnLyricsProviders`, а чей текст — видно по `source.format` (`yandex-…` / `deezer-…`).
struct YandexMusicLyricsProvider: LyricsProvider {
    static let providerID: LyricsProviderID = .local
    /// Начало `source.format` у текстов Яндекса.
    static let formatPrefix = "yandex"
    static let clientHeader = "YandexMusicAndroid/24023621"
    /// Ключ подписи запроса текста (открытый, из приложения Яндекс Музыки; `DEFAULT_SIGN_KEY` у MarshalX).
    static let signKey = "p93jhgh689SBReK6ghtw62"

    let id: LyricsProviderID = YandexMusicLyricsProvider.providerID
    let http: HTTPClient
    let gate: YandexGate
    let token: YandexMusicToken
    let matcher: TrackMatcher
    let apiHost: String
    let maxCandidates: Int
    let now: @Sendable () -> Date

    init(http: HTTPClient, gate: YandexGate = .shared, token: YandexMusicToken = .shared,
         apiHost: String = "https://api.music.yandex.net", maxCandidates: Int = 2,
         matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 6)),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.gate = gate
        self.token = token
        self.apiHost = apiHost
        self.maxCandidates = maxCandidates
        self.matcher = matcher
        self.now = now
    }

    func isAvailable() async -> Bool { token.current() != nil }

    func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] { try await response(for: query).lyrics }

    func response(for query: TrackQuery) async throws -> ProviderResponse {
        guard let tok = token.current() else { throw LyricsError.notConfigured("Яндекс Музыка: нет входа") }
        let parsed = TextNormalizer.parseTitle(query.title)
        let primary = TextNormalizer.splitArtistsRaw(query.artist).first ?? query.artist
        var records: [Track] = []
        var seen = Set<String>()
        for term in ["\(primary) \(parsed.display)", parsed.display] {
            for t in try await search(term) where seen.insert(t.id).inserted { records.append(t) }
            if !matcher.triage(query, records.map(\.candidate)).accepted.isEmpty { break }
            try Task.checkCancellation()
        }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let triage = matcher.triage(query, records.map(\.candidate))
        var out: [LyricsCore.Lyrics] = []
        var errors = 0
        var lastError: Error?
        var noLyrics = 0
        for (cand, ev) in triage.accepted.prefix(maxCandidates) {
            guard let t = byID[cand.id], t.hasSync || t.hasText else { noLyrics += 1; continue }
            let src = LyricsSource(provider: id, trackID: cand.id, title: cand.title, artist: cand.artists.joined(separator: ", "),
                                   duration: cand.duration, confidence: ev.score, matchKind: ev.isrcMatch ? .isrc : .metadata,
                                   format: Self.formatPrefix + (t.hasSync ? "-lrc" : "-text"))
            do {
                if let l = try await lyrics(trackID: cand.id, format: t.hasSync ? "LRC" : "TEXT", token: tok, source: src,
                                            duration: cand.duration ?? query.duration ?? 0) {
                    out.append(l)
                }
            } catch let e as LyricsError where e == .cancelled {
                throw e
            } catch is CancellationError {
                throw LyricsError.cancelled
            } catch {
                errors += 1; lastError = error
            }
            if out.contains(where: { $0.syncType >= .line }) { break }
        }
        if out.isEmpty, errors > 0, let lastError { throw lastError }
        out.sort { $0.syncType != $1.syncType ? $0.syncType > $1.syncType : $0.source.confidence > $1.source.confidence }
        var note: String?
        if out.isEmpty {
            note = triage.summary + (triage.accepted.isEmpty ? "" : (noLyrics > 0 ? ", у принятых нет текста в каталоге" : ", текст пуст"))
        }
        return ProviderResponse(lyrics: out, note: note)
    }

    // MARK: Поиск (без входа)

    struct Track: Sendable {
        var id: String
        var candidate: TrackCandidate
        var hasSync: Bool
        var hasText: Bool
    }

    func search(_ term: String) async throws -> [Track] {
        guard var c = URLComponents(string: apiHost + "/search") else { return [] }
        c.queryItems = [URLQueryItem(name: "text", value: term), URLQueryItem(name: "type", value: "track"),
                        URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "nocorrect", value: "false")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let r = try await gate.send(req, http: http)
        guard r.status == 200 else { throw LyricsError.badStatus(r.status) }
        return try Self.parseSearch(r.data)
    }

    /// Ответ `/search` → кандидаты (название с версией «(Remix)», все исполнители, длительность, есть ли текст).
    static func parseSearch(_ data: Data) throws -> [Track] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.badResponse("yandex search: не JSON")
        }
        if let e = obj["error"] as? [String: Any] { throw LyricsError.badResponse("yandex search: \(e["name"] ?? "ошибка")") }
        let list = ((obj["result"] as? [String: Any])?["tracks"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return list.compactMap { t in
            guard let id = idString(t["id"]) ?? idString(t["realId"]) else { return nil }
            var title = ((t["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if let v = (t["version"] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty { title += " (\(v))" }
            let artists = (t["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            let album = (t["albums"] as? [[String: Any]])?.first?["title"] as? String
            let dur = (t["durationMs"] as? NSNumber).map { $0.doubleValue / 1000 }
            let info = t["lyricsInfo"] as? [String: Any]
            let sync = (info?["hasAvailableSyncLyrics"] as? Bool) ?? false
            let text = (info?["hasAvailableTextLyrics"] as? Bool) ?? ((t["lyricsAvailable"] as? Bool) ?? false)
            return Track(id: id, candidate: TrackCandidate(id: id, title: title, artists: artists, album: album, duration: dur),
                         hasSync: sync, hasText: text)
        }
    }

    // MARK: Текст (с токеном)

    /// Подпись запроса текста: base64(HMAC-SHA256(ключ, "{id}{timeStamp}")) — как `get_sign_request` у MarshalX.
    static func sign(trackID: String, timestamp: Int, key: String = signKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(trackID)\(timestamp)".utf8), using: SymmetricKey(data: Data(key.utf8)))
        return Data(mac).base64EncodedString()
    }

    /// Адрес запроса текста. Подпись — base64 с `+`, `/`, `=`: кодируем строго (иначе `+` дойдёт пробелом).
    static func lyricsURL(apiHost: String, trackID: String, format: String, timestamp: Int, sign: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return URL(string: "\(apiHost)/tracks/\(enc(trackID))/lyrics?format=\(enc(format))&timeStamp=\(timestamp)&sign=\(enc(sign))")
    }

    /// Ссылка на файл текста — только https в доменах Яндекса (токен туда не отправляется, но и чужой адрес не берём).
    static func isYandexDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let h = url.host?.lowercased() else { return false }
        return YandexMusicAuth.isYandexHost(h) || h == "yandex.net" || h.hasSuffix(".yandex.net")
    }

    func lyrics(trackID: String, format: String, token tok: String, source: LyricsSource, duration: Double) async throws -> LyricsCore.Lyrics? {
        let ts = Int(now().timeIntervalSince1970)
        guard let url = Self.lyricsURL(apiHost: apiHost, trackID: trackID, format: format, timestamp: ts,
                                       sign: Self.sign(trackID: trackID, timestamp: ts)) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        req.setValue("OAuth " + tok, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let r = try await gate.send(req, http: http, authorized: true)
        if r.status == 404 { return nil }
        guard r.status == 200 else { throw LyricsError.badStatus(r.status) }
        guard let dl = try Self.parseLyricsInfo(r.data) else { return nil }
        guard Self.isYandexDownload(dl) else { throw LyricsError.badResponse("yandex: чужой адрес текста") }
        var get = URLRequest(url: dl, timeoutInterval: 8)
        get.setValue(Self.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        let file = try await gate.send(get, http: http)
        if file.status == 404 { return nil }
        guard file.status == 200 else { throw LyricsError.badStatus(file.status) }
        return Self.parseLRC(file.text, source: source, duration: duration)
    }

    /// Ответ `/tracks/{id}/lyrics` → `downloadUrl`. Ошибка в теле — исключение; нет ссылки — текста нет.
    static func parseLyricsInfo(_ data: Data) throws -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.badResponse("yandex lyrics: не JSON")
        }
        if let e = obj["error"] as? [String: Any] {
            let name = (e["name"] as? String) ?? ""
            if name == "not-authenticated" || name == "session-expired" { throw LyricsError.unauthorized }
            if name == "not-found" || name == "lyrics-not-found" { return nil }
            throw LyricsError.badResponse("yandex lyrics: \(name)")
        }
        guard let s = (obj["result"] as? [String: Any])?["downloadUrl"] as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Файл текста (LRC или простой) → текст LyricsCore. Формат (`yandex-lrc`/`yandex-text`) остаётся из `source`.
    static func parseLRC(_ text: String, source: LyricsSource, duration: Double) -> LyricsCore.Lyrics? {
        let l = LRCParser.parse(text, source: source, options: .init(trackDuration: duration >= 1 ? duration : nil))
        return l.lines.contains(where: { !$0.text.isEmpty || !$0.words.isEmpty }) ? l : nil
    }
}

private func idString(_ v: Any?) -> String? {
    if let n = v as? NSNumber { return n.stringValue }
    if let s = v as? String, !s.isEmpty { return s }
    return nil
}

// MARK: - Токен

/// Токен Яндекс Музыки (OAuth implicit flow, вход — в окне на странице Яндекса). В файле секретов острова: служба
/// `local.simpleisland.lyrics`, ключ `yandexMusicToken`. Самотесты — свой `SecretFile(memoryOnly:)`.
struct YandexMusicToken: Sendable {
    static let service = LyricsService.keychainService
    static let account = "yandexMusicToken"
    static let shared = YandexMusicToken(file: .shared)

    let file: SecretFile

    func current() -> String? {
        guard let v = file.value(service: Self.service, account: Self.account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return nil }
        return v
    }

    func set(_ value: String?) {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        file.set((v?.isEmpty ?? true) ? nil : v, service: Self.service, account: Self.account)
    }
}

// MARK: - Частота и пауза

/// Общие на процесс ограничение частоты и пауза после отказов Яндекса (как `DeezerGate`).
actor YandexGate {
    static let shared = YandexGate()

    let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastRequest = Date.distantPast
    private(set) var failures = 0
    private(set) var blockedUntil = Date.distantPast
    /// Яндекс отверг токен (401 на запросе текста) — для подсказки «войдите заново».
    private(set) var tokenRejected = false

    init(minInterval: TimeInterval = 0.3, now: @escaping @Sendable () -> Date = { Date() }) {
        self.minInterval = minInterval
        self.now = now
    }

    var isCoolingDown: Bool { now() < blockedUntil }

    func noteFailure() {
        failures += 1
        blockedUntil = now().addingTimeInterval(DeezerGate.backoff(failures))
    }

    func noteSuccess() { failures = 0; blockedUntil = .distantPast }

    /// Запрос с ограничением частоты. 2xx и 404 — ответ как есть; 401/403 — `unauthorized` (на запросе с токеном —
    /// пометка «токен отвергнут»); 429/5xx — пауза растёт.
    func send(_ req: URLRequest, http: HTTPClient, authorized: Bool = false) async throws -> HTTPResponse {
        if isCoolingDown { throw LyricsError.rateLimited(retryAfter: blockedUntil.timeIntervalSince(now())) }
        let wait = lastRequest.addingTimeInterval(minInterval).timeIntervalSince(now())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastRequest = now()
        let r = try await http.send(req)
        switch r.status {
        case 200..<300:
            noteSuccess()
            if authorized { tokenRejected = false }
            return r
        case 404:
            return r
        case 401, 403:
            if authorized { tokenRejected = true }
            throw LyricsError.unauthorized
        case 429, 500...599:
            noteFailure()
            throw r.status == 429 ? LyricsError.rateLimited(retryAfter: r.retryAfter) : LyricsError.badStatus(r.status)
        default:
            throw LyricsError.badStatus(r.status)
        }
    }

    func reset() { failures = 0; blockedUntil = .distantPast; lastRequest = .distantPast; tokenRejected = false }
}

// MARK: - Составной провайдер `.local`

/// Наши источники (Яндекс, Musixmatch, Deezer) одним звеном каскада под id `.local`: у движка LyricsCore память ответов и
/// приоритет — по id, а свободный id для внешних источников один. Части опрашиваются параллельно; чей текст — по
/// `source.format`. Порядок между ними (и относительно остальных) при равной синхронизации держит
/// `LyricsService.choose` по порядку пользователя. Разбор по частям — `OwnLyricsReport` (для `--lyrics-lookup`).
struct OwnLyricsProviders: LyricsProvider {
    struct Part: Sendable {
        var kind: LyricsSourceKind
        var provider: any LyricsProvider
    }

    let id: LyricsProviderID = .local
    let parts: [Part]

    func isAvailable() async -> Bool {
        for p in parts where await p.provider.isAvailable() { return true }
        return false
    }

    func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] { try await response(for: query).lyrics }

    func response(for query: TrackQuery) async throws -> ProviderResponse {
        enum R: Sendable { case skipped, ok(ProviderResponse), failed(String, Bool) }
        let results: [Int: (R, TimeInterval)] = await withTaskGroup(of: (Int, R, TimeInterval).self) { g in
            for (i, p) in parts.enumerated() {
                g.addTask {
                    let t0 = Date()
                    guard await p.provider.isAvailable() else { return (i, .skipped, 0) }
                    do { return (i, .ok(try await p.provider.response(for: query)), Date().timeIntervalSince(t0)) }
                    catch {
                        let cancelled = error is CancellationError || (error as? LyricsError) == .cancelled
                        let text = (error as? LyricsError)?.description ?? "\(type(of: error))"
                        return (i, .failed(text, cancelled), Date().timeIntervalSince(t0))
                    }
                }
            }
            var out: [Int: (R, TimeInterval)] = [:]
            for await (i, r, s) in g { out[i] = (r, s) }
            return out
        }
        if Task.isCancelled { throw LyricsError.cancelled }
        var lyrics: [LyricsCore.Lyrics] = []
        var lines: [String] = []
        var notes: [String] = []
        var firstError: String?
        var cancelled = false
        for (i, p) in parts.enumerated() {
            guard let (r, s) = results[i] else { continue }
            let t = String(format: "%.1f", s)
            switch r {
            case .skipped:
                lines.append("\(p.kind.rawValue): пропущен (\(p.kind == .yandex ? "нет входа" : p.kind == .musixmatch ? "нет токена или пауза после captcha" : "недоступен"))")
            case .ok(let resp):
                lyrics += resp.lyrics
                if let top = resp.lyrics.map(\.syncType).max() {
                    lines.append("\(p.kind.rawValue): \(top.rawValue) ×\(resp.lyrics.count), \(t) с")
                } else {
                    lines.append("\(p.kind.rawValue): нет" + (resp.note.map { " (\($0))" } ?? "") + ", \(t) с")
                    if let n = resp.note { notes.append("\(p.kind.rawValue): \(n)") }
                }
            case .failed(let e, let c):
                cancelled = cancelled || c
                firstError = firstError ?? "\(p.kind.rawValue): \(e)"
                lines.append("\(p.kind.rawValue): сбой \(e), \(t) с")
            }
        }
        OwnLyricsReport.shared.set(query.cacheKey, lines)
        if lyrics.isEmpty {
            if cancelled { throw LyricsError.cancelled }
            // Часть упала, остальные пусто: «не найдено» не доказано — сбой (движок не закеширует отрицательный итог).
            if let e = firstError { throw LyricsError.network(e) }
        }
        return ProviderResponse(lyrics: lyrics, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}

/// Последний разбор составного провайдера по частям (ключ — `TrackQuery.cacheKey`, несколько последних).
final class OwnLyricsReport: @unchecked Sendable {
    static let shared = OwnLyricsReport()
    private let lock = NSLock()
    private var map: [String: [String]] = [:]
    private var order: [String] = []

    func set(_ key: String, _ lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        if map[key] == nil { order.append(key) }
        map[key] = lines
        while order.count > 8 { map[order.removeFirst()] = nil }
    }

    func take(_ key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: key) ?? []
    }
}
