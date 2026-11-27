import Foundation
import IslandCore
import LyricsCore

/// Musixmatch — самый большой каталог текстов (26.11): пословный richsync, построчные subtitles, простой текст. Нужен,
/// чтобы находить всё, чего нет у Apple/Яндекса/китайских сервисов (Big Sean «Blessings» — пословно, «utopi» — простой).
///
/// Как ходим (проверено curl 26.11.2026 с этого Мака; сверено с открытым кодом syncedlyrics `providers/musixmatch.py`
/// и onetagger `musixmatch.rs` — те же методы `ws/1.1`, ответ `message.header.status_code` в теле):
/// * токен — `GET apic.musixmatch.com/ws/1.1/token.get?app_id=mac-ios-v2.0` → `user_token` (54 hex). Токен
///   `apic-desktop` (`web-desktop-app-v1.0`) приходит из нулей — бесполезен. Повторный `token.get` через минуту —
///   `401 hint=captcha`: токен берём **редко** и держим в файле секретов (`SecretFile`, служба
///   `local.simpleisland.lyrics`, ключ `musixmatchToken`), нигде не печатаем. Captcha не обходим: пауза часами
///   (1 → 2 → 4 … ≤ 12 ч, переживает перезапуск — ключ `musixmatchTokenBackoff`), до её конца источник «недоступен»;
/// * поиск и текст одним запросом — `macro.subtitles.get` (matcher.track.get: has_richsync/has_subtitles/instrumental,
///   track.subtitles.get — построчный JSON, track.lyrics.get — простой);
/// * пословный — `track.richsync.get?commontrack_id=…` (`richsync_body` — JSON: строки `ts`/`te`, куски `l[].c` со
///   смещением `o` от начала строки, пробелы — отдельные куски).
///
/// Бережно: не чаще запроса в 0,5 с на процесс; captcha на запросе с токеном — пауза 1 ч → … ≤ 12 ч; 429/5xx — 30 с →
/// … ≤ 1 ч; ответы (в т. ч. «нет текста») помним 30 мин в памяти, итог — в кеше `LyricsService` на диске.
/// В каскад идёт частью составного `.local` (`OwnLyricsProviders`), чей текст — `source.format` (`musixmatch-…`).
struct MusixmatchLyricsProvider: LyricsProvider {
    static let providerID: LyricsProviderID = .local
    static let formatPrefix = "musixmatch"
    static let appID = "mac-ios-v2.0"
    static let userAgent = "Musixmatch/2023 CFNetwork Darwin"

    let id: LyricsProviderID = MusixmatchLyricsProvider.providerID
    let http: HTTPClient
    let gate: MusixmatchGate
    let token: MusixmatchToken
    let matcher: TrackMatcher
    let apiHost: String

    init(http: HTTPClient, gate: MusixmatchGate = .shared, token: MusixmatchToken = .shared,
         apiHost: String = "https://apic.musixmatch.com",
         matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 6))) {
        self.http = http
        self.gate = gate
        self.token = token
        self.apiHost = apiHost
        self.matcher = matcher
    }

    /// Есть токен или его можно попросить (не в паузе после captcha), и запросы не в паузе.
    func isAvailable() async -> Bool { await gate.isUsable(token: token) }

    func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] { try await response(for: query).lyrics }

    func response(for query: TrackQuery) async throws -> ProviderResponse {
        let key = query.cacheKey
        if let hit = await gate.remembered(key) { return hit }
        let r = try await fetch(query)
        await gate.remember(key, r)
        return r
    }

    private func fetch(_ query: TrackQuery) async throws -> ProviderResponse {
        let parsed = TextNormalizer.parseTitle(query.title)
        var items = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
                     URLQueryItem(name: "subtitle_format", value: "mxm"),
                     URLQueryItem(name: "q_track", value: parsed.display.isEmpty ? query.title : parsed.display),
                     URLQueryItem(name: "q_artist", value: query.artist)]
        if let a = query.album, !a.isEmpty { items.append(URLQueryItem(name: "q_album", value: a)) }
        if let d = query.duration, d >= 1 {
            let s = String(Int(d.rounded()))
            items += [URLQueryItem(name: "q_duration", value: s), URLQueryItem(name: "f_subtitle_length", value: s),
                      URLQueryItem(name: "f_subtitle_length_max_deviation", value: "40")]
        }
        let macro = try await call("macro.subtitles.get", items)
        guard let m = Self.parseMacro(macro) else { throw LyricsError.badResponse("musixmatch: нет matcher.track.get") }
        guard let track = m.track else { return ProviderResponse(lyrics: [], note: "в каталоге нет") }
        let triage = matcher.triage(query, [track.candidate])
        guard let ev = triage.accepted.first?.1 else { return ProviderResponse(lyrics: [], note: triage.summary) }
        if track.instrumental { return ProviderResponse(lyrics: [], note: "инструментал") }
        let src = LyricsSource(provider: id, trackID: track.candidate.id, title: track.candidate.title,
                               artist: track.candidate.artists.joined(separator: ", "), duration: track.candidate.duration,
                               confidence: ev.score, matchKind: .metadata)
        var out: [LyricsCore.Lyrics] = []
        if track.hasRichsync {
            do {
                let rs = try await call("track.richsync.get", [URLQueryItem(name: "format", value: "json"),
                                                               URLQueryItem(name: "commontrack_id", value: track.commontrackID)])
                if let l = Self.parseRichsync(rs, source: src) { out.append(l) }
            } catch let e as LyricsError where e == .cancelled {
                throw e
            } catch is CancellationError {
                throw LyricsError.cancelled
            } catch {
                // Пословного не дали — построчный/простой из того же ответа всё равно годятся.
            }
        }
        if out.isEmpty, let l = m.subtitles(source: src) { out.append(l) }
        if out.isEmpty, let l = m.plain(source: src) { out.append(l) }
        return ProviderResponse(lyrics: out, note: out.isEmpty ? "\(triage.summary), у принятого нет текста" : nil)
    }

    /// Запрос `ws/1.1/<метод>` с токеном. Токен отвергнут (401 не captcha) — один раз взять новый.
    func call(_ method: String, _ items: [URLQueryItem]) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let tok = try await gate.token(http: http, apiHost: apiHost, store: token)
            guard var c = URLComponents(string: apiHost + "/ws/1.1/" + method) else { throw LyricsError.notConfigured("musixmatch") }
            c.queryItems = items + [URLQueryItem(name: "app_id", value: Self.appID), URLQueryItem(name: "usertoken", value: tok)]
            // `+` в значении URLComponents не кодирует — сервер прочёл бы пробел.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = c.url else { throw LyricsError.notConfigured("musixmatch") }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let obj = try await gate.send(req, http: http)
            switch Self.status(obj) {
            case .ok: return obj
            case .notFound: return [:]
            case .captcha:
                await gate.noteCaptcha()
                throw LyricsError.rateLimited(retryAfter: nil)
            case .renew:
                if attempt == 0 { await gate.dropToken(store: token); continue }
                throw LyricsError.unauthorized
            case .limited:
                await gate.noteFailure()
                throw LyricsError.rateLimited(retryAfter: nil)
            case .other(let code):
                throw LyricsError.badStatus(code)
            }
        }
        throw LyricsError.unauthorized
    }

    // MARK: Разбор

    enum Status: Equatable { case ok, notFound, captcha, renew, limited, other(Int) }

    /// `message.header.status_code` (+ `hint`): 200 — есть, 404 — нет, 401 captcha — пауза, 401 прочее — новый токен.
    static func status(_ obj: [String: Any]) -> Status {
        let h = (obj["message"] as? [String: Any])?["header"] as? [String: Any] ?? [:]
        let code = intValue(h["status_code"]) ?? 0
        let hint = ((h["hint"] as? String) ?? "").lowercased()
        switch code {
        case 200: return .ok
        case 404: return .notFound
        case 401: return hint.contains("captcha") ? .captcha : .renew
        case 402, 429: return .limited
        case 500...599: return .limited
        default: return .other(code)
        }
    }

    static func body(_ obj: [String: Any]) -> [String: Any]? { (obj["message"] as? [String: Any])?["body"] as? [String: Any] }

    struct Track: Sendable {
        var candidate: TrackCandidate
        var commontrackID: String
        var hasRichsync: Bool
        var hasSubtitles: Bool
        var hasLyrics: Bool
        var instrumental: Bool
    }

    struct Macro: @unchecked Sendable {
        var track: Track?
        var subtitleBody: String?
        var lyricsBody: String?
        var lyricsRestricted = false

        func subtitles(source: LyricsSource) -> LyricsCore.Lyrics? {
            guard let b = subtitleBody, let d = b.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
            var pts: [(Double, String)] = []
            for x in arr {
                guard let t = doubleValue((x["time"] as? [String: Any])?["total"]) else { continue }
                pts.append((t, ((x["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)))
            }
            pts.sort { $0.0 < $1.0 }
            let lines = pts.enumerated().map { i, p in
                LyricsCore.LyricLine(key: "L\(i + 1)", begin: p.0, end: i + 1 < pts.count ? pts[i + 1].0 : nil, text: p.1)
            }
            guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
            var s = source
            s.format = MusixmatchLyricsProvider.formatPrefix + "-line"
            return LyricsCore.Lyrics(source: s, syncType: .line, lines: lines)
        }

        func plain(source: LyricsSource) -> LyricsCore.Lyrics? {
            guard !lyricsRestricted, let b = lyricsBody else { return nil }
            var rows = b.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            // Хвост бесплатного доступа: «******* This Lyrics is NOT for Commercial use *******» и номер — не текст песни.
            if let i = rows.firstIndex(where: { $0.hasPrefix("*******") }) { rows = Array(rows[..<i]) }
            while rows.last?.isEmpty == true { rows.removeLast() }
            guard rows.contains(where: { !$0.isEmpty }) else { return nil }
            var s = source
            s.format = MusixmatchLyricsProvider.formatPrefix + "-plain"
            return LyricsCore.Lyrics(source: s, syncType: .none,
                                     lines: rows.enumerated().map { LyricsCore.LyricLine(key: "L\($0.offset + 1)", text: $0.element) })
        }
    }

    /// Ответ `macro.subtitles.get` → трек и тексты. nil — ответ без `matcher.track.get` (не тот формат).
    static func parseMacro(_ obj: [String: Any]) -> Macro? {
        guard let calls = body(obj)?["macro_calls"] as? [String: Any], let mt = calls["matcher.track.get"] as? [String: Any] else {
            return obj.isEmpty ? Macro() : nil
        }
        var m = Macro()
        if status(mt) == .ok, let t = body(mt)?["track"] as? [String: Any], let tid = idString(t["track_id"]) {
            let rawTitle = (t["track_name"] as? String) ?? ""
            // «TAMPON|» — так в каталоге (как у Deezer): палку на конце убираем.
            let title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "| ").union(.whitespaces))
            let artists = TextNormalizer.splitArtistsRaw((t["artist_name"] as? String) ?? "")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let dur = doubleValue(t["track_length"]).flatMap { $0 > 0 ? $0 : nil }
            m.track = Track(candidate: TrackCandidate(id: tid, title: title, artists: artists, album: t["album_name"] as? String,
                                                      duration: dur),
                            commontrackID: idString(t["commontrack_id"]) ?? tid,
                            hasRichsync: intValue(t["has_richsync"]) == 1, hasSubtitles: intValue(t["has_subtitles"]) == 1,
                            hasLyrics: intValue(t["has_lyrics"]) == 1, instrumental: intValue(t["instrumental"]) == 1)
        }
        if let s = calls["track.subtitles.get"] as? [String: Any], status(s) == .ok,
           let list = body(s)?["subtitle_list"] as? [[String: Any]], let sub = list.first?["subtitle"] as? [String: Any] {
            m.subtitleBody = sub["subtitle_body"] as? String
        }
        if let l = calls["track.lyrics.get"] as? [String: Any], status(l) == .ok,
           let ly = body(l)?["lyrics"] as? [String: Any] {
            m.lyricsBody = ly["lyrics_body"] as? String
            m.lyricsRestricted = intValue(ly["restricted"]) == 1
        }
        return m
    }

    /// Ответ `track.richsync.get` → пословный текст. Слово — кусок без пробелов; конец слова — начало следующего куска
    /// (пробела) или конец строки; кусок вплотную к предыдущему (без пробела между) — продолжение слова (слог).
    static func parseRichsync(_ obj: [String: Any], source: LyricsSource) -> LyricsCore.Lyrics? {
        guard let rs = body(obj)?["richsync"] as? [String: Any], let b = rs["richsync_body"] as? String, let d = b.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        var lines: [LyricsCore.LyricLine] = []
        for x in arr {
            guard let ts = doubleValue(x["ts"]) else { continue }
            let te = doubleValue(x["te"]) ?? ts
            let parts: [(String, Double)] = (x["l"] as? [[String: Any]] ?? []).compactMap { p in
                guard let c = p["c"] as? String else { return nil }
                return (c, ts + (doubleValue(p["o"]) ?? 0))
            }
            var words: [LyricsCore.LyricWord] = []
            var afterSpace = true
            for (i, p) in parts.enumerated() {
                let text = p.0.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { afterSpace = true; continue }
                let end = i + 1 < parts.count ? parts[i + 1].1 : te
                words.append(LyricsCore.LyricWord(text: text, begin: p.1, end: max(p.1, min(end, max(te, p.1))),
                                                  isContinuation: !afterSpace && !words.isEmpty))
                afterSpace = p.0.last?.isWhitespace ?? false
            }
            guard !words.isEmpty else { continue }
            lines.append(LyricsCore.LyricLine(key: "L\(lines.count + 1)", begin: ts, end: te, words: words))
        }
        guard !lines.isEmpty else { return nil }
        var s = source
        s.format = formatPrefix + "-word"
        return LyricsCore.Lyrics(source: s, syncType: .word, lines: lines)
    }

    static func intValue(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
    static func doubleValue(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
    static func idString(_ v: Any?) -> String? { intValue(v).map(String.init) ?? (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
}

// MARK: - Токен

/// Токен Musixmatch и пауза после captcha на `token.get` — в файле секретов острова (служба `local.simpleisland.lyrics`,
/// ключи `musixmatchToken`, `musixmatchTokenBackoff` = «отказов|unix-время конца паузы»). Пауза переживает перезапуск:
/// иначе каждый запуск снова просил бы токен и продлевал captcha. Самотесты — свой `SecretFile(memoryOnly:)`.
struct MusixmatchToken: Sendable {
    static let service = LyricsService.keychainService
    static let account = "musixmatchToken"
    static let backoffAccount = "musixmatchTokenBackoff"
    static let shared = MusixmatchToken(file: .shared)

    let file: SecretFile
    /// false — только читать (самотест `net` берёт токен, сохранённый приложением, и ничего не пишет).
    var writable = true

    func current() -> String? {
        guard let v = file.value(service: Self.service, account: Self.account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              v.count >= 20 else { return nil }
        return v
    }

    func set(_ value: String?) {
        guard writable else { return }
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        file.set((v?.isEmpty ?? true) ? nil : v, service: Self.service, account: Self.account)
    }

    /// (отказов подряд, конец паузы).
    func backoff() -> (Int, Date) {
        let raw = file.value(service: Self.service, account: Self.backoffAccount) ?? ""
        let p = raw.split(separator: "|")
        guard p.count == 2, let n = Int(p[0]), let t = Double(p[1]) else { return (0, .distantPast) }
        return (n, Date(timeIntervalSince1970: t))
    }

    func setBackoff(_ n: Int, until: Date) {
        guard writable else { return }
        file.set(n == 0 ? nil : "\(n)|\(Int(until.timeIntervalSince1970))", service: Self.service, account: Self.backoffAccount)
    }
}

// MARK: - Частота, пауза, память ответов

/// Общие на процесс ограничение частоты (≥ 0,5 с между запросами), паузы и память ответов Musixmatch.
actor MusixmatchGate {
    static let shared = MusixmatchGate()

    let minInterval: TimeInterval
    /// Сколько помнить ответ провайдера по треку (в т. ч. «нет текста»), с.
    let memoTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var lastRequest = Date.distantPast
    private(set) var failures = 0
    private(set) var captchas = 0
    private(set) var blockedUntil = Date.distantPast
    /// Сколько раз за процесс спрашивали `token.get` (для самотеста и журнала).
    private(set) var tokenRequests = 0
    private var memo: [String: (ProviderResponse, Date)] = [:]
    private var memoOrder: [String] = []

    init(minInterval: TimeInterval = 0.5, memoTTL: TimeInterval = 1800, now: @escaping @Sendable () -> Date = { Date() }) {
        self.minInterval = minInterval
        self.memoTTL = memoTTL
        self.now = now
    }

    /// Пауза после `n` отказов подряд (429/5xx): 30 с, 2, 8, 32 мин, дальше 1 ч.
    static func backoff(_ n: Int) -> TimeInterval { n <= 0 ? 0 : min(3600, 30 * pow(4, Double(n - 1))) }
    /// Пауза после `n` captcha подряд: 1, 2, 4, 8 ч, дальше 12 ч.
    static func captchaBackoff(_ n: Int) -> TimeInterval { n <= 0 ? 0 : min(12 * 3600, 3600 * pow(2, Double(n - 1))) }

    var isCoolingDown: Bool { now() < blockedUntil }

    func isUsable(token: MusixmatchToken) -> Bool {
        if isCoolingDown { return false }
        return token.current() != nil || now() >= token.backoff().1
    }

    func noteFailure() {
        failures += 1
        blockedUntil = max(blockedUntil, now().addingTimeInterval(Self.backoff(failures)))
    }

    /// Captcha на запросе с токеном: всё в паузу на часы (токен не трогаем — после паузы он обычно снова работает).
    func noteCaptcha() {
        captchas += 1
        blockedUntil = max(blockedUntil, now().addingTimeInterval(Self.captchaBackoff(captchas)))
    }

    func remembered(_ key: String) -> ProviderResponse? {
        guard let (r, t) = memo[key], now().timeIntervalSince(t) < memoTTL else { return nil }
        return r
    }

    func remember(_ key: String, _ r: ProviderResponse) {
        if memo[key] == nil { memoOrder.append(key) }
        memo[key] = (r, now())
        while memoOrder.count > 32 { memo[memoOrder.removeFirst()] = nil }
    }

    /// Запрос с ограничением частоты → JSON. HTTP 429/5xx — пауза растёт; статус в теле разбирает провайдер.
    func send(_ req: URLRequest, http: HTTPClient) async throws -> [String: Any] {
        if isCoolingDown { throw LyricsError.rateLimited(retryAfter: blockedUntil.timeIntervalSince(now())) }
        let wait = lastRequest.addingTimeInterval(minInterval).timeIntervalSince(now())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        try Task.checkCancellation()
        lastRequest = now()
        let r = try await http.send(req)
        switch r.status {
        case 200..<300:
            guard let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] else {
                throw LyricsError.badResponse("musixmatch: не JSON")
            }
            if MusixmatchLyricsProvider.status(obj) == .ok { failures = 0 }
            return obj
        case 401:
            // Тот же смысл, что 401 в теле: пусть разбирает провайдер.
            return ["message": ["header": ["status_code": 401, "hint": "renew"]]]
        case 429, 500...599:
            noteFailure()
            throw r.status == 429 ? LyricsError.rateLimited(retryAfter: r.retryAfter) : LyricsError.badStatus(r.status)
        default:
            throw LyricsError.badStatus(r.status)
        }
    }

    /// Токен: сохранённый, иначе `token.get` (не в паузе после captcha). Значение не логируется.
    func token(http: HTTPClient, apiHost: String, store: MusixmatchToken) async throws -> String {
        if let t = store.current() { return t }
        let (n, until) = store.backoff()
        if now() < until { throw LyricsError.rateLimited(retryAfter: until.timeIntervalSince(now())) }
        guard var c = URLComponents(string: apiHost + "/ws/1.1/token.get") else { throw LyricsError.notConfigured("musixmatch") }
        c.queryItems = [URLQueryItem(name: "app_id", value: MusixmatchLyricsProvider.appID), URLQueryItem(name: "format", value: "json")]
        guard let url = c.url else { throw LyricsError.notConfigured("musixmatch") }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(MusixmatchLyricsProvider.userAgent, forHTTPHeaderField: "User-Agent")
        tokenRequests += 1
        let obj: [String: Any]
        do { obj = try await send(req, http: http) } catch {
            if !(error is CancellationError) && (error as? LyricsError) != .cancelled {
                // Сеть/5xx: следующая попытка не раньше чем через 10 мин (и пауза растёт, как после captcha).
                store.setBackoff(n + 1, until: now().addingTimeInterval(max(600, Self.captchaBackoff(n + 1) / 6)))
            }
            throw error
        }
        let tok = (MusixmatchLyricsProvider.body(obj)?["user_token"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // Токен из нулей (так отвечает `apic-desktop`) или captcha — не годится: пауза часами, сохраняется на диск.
        guard MusixmatchLyricsProvider.status(obj) == .ok, Self.isRealToken(tok) else {
            store.setBackoff(n + 1, until: now().addingTimeInterval(Self.captchaBackoff(n + 1)))
            throw LyricsError.rateLimited(retryAfter: Self.captchaBackoff(n + 1))
        }
        store.set(tok)
        store.setBackoff(0, until: .distantPast)
        return tok
    }

    static func isRealToken(_ t: String) -> Bool { t.count >= 20 && t.contains { $0 != "0" && $0 != "-" } }

    /// Токен отвергнут (401 не captcha): забыть его — следующий запрос попросит новый (с учётом паузы).
    func dropToken(store: MusixmatchToken) { store.set(nil) }

    /// Для самотеста: сбросить состояние.
    func reset() {
        failures = 0; captchas = 0; blockedUntil = .distantPast; lastRequest = .distantPast; tokenRequests = 0
        memo = [:]; memoOrder = []
    }
}
