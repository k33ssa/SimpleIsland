import Foundation
import LyricsCore

/// Самотест источника Deezer (часть `--selftest-media`): разбор ответов поиска и GraphQL на синтетических фикстурах
/// (форма как у живых ответов 16.11, тексты придуманы), сопоставление «TAMPON|» с запросом из Музыки, порядок источников,
/// JWT (кеш, срок, обновление), пауза после отказов, сквозной поиск через `LyricsService` на заглушке HTTP.
/// `net` — `network`: живой поиск TAMPON / DTF / Blinding Lights.
enum DeezerLyricsSelfTest {
    typealias Check = LyricsSelfTest.Check

    static func run(_ check: Check) {
        parsing(check)
        matching(check)
        order(check)
        gate(check)
        endToEnd(check)
    }

    // MARK: Фикстуры (синтетика)

    static let searchJSON = """
    {"data":[{"id":2216831097,"readable":true,"title":"TAMPON|","title_short":"TAMPON|","title_version":"","isrc":"RUA1D2325845",
    "duration":161,"artist":{"id":1,"name":"SODA LUV"},"album":{"id":2,"title":"НИЧЕГО ЛИЧНОГО 2 (DELUXE)"}},
    {"id":555,"title":"TAMPON","duration":122,"artist":{"name":"PolsKii"},"album":{"title":"TAMPON"}},
    {"id":556,"title":"TAMPON (Remix)","duration":170,"artist":{"name":"SODA LUV"},"album":{"title":"Remixes"}}],"total":3}
    """
    static let wordJSON = """
    {"data":{"track":{"id":"1","lyrics":{"id":"9","text":"раз два\\nтри",
    "synchronizedWordByWordLines":[{"start":13747,"end":14200,"words":[{"start":13747,"end":13922,"word":"раз "},{"start":13950,"end":14200,"word":"два"}]},
    {"start":20000,"end":20500,"words":[{"start":20000,"end":20500,"word":"три"}]}],
    "synchronizedLines":[{"line":"раз два","milliseconds":13570,"duration":1060}]}}}}
    """
    static let lineJSON = """
    {"data":{"track":{"id":"2","lyrics":{"id":"8","text":"раз\\nдва","synchronizedWordByWordLines":null,
    "synchronizedLines":[{"lrcTimestamp":"[00:06.65]","line":"раз","lineTranslated":null,"milliseconds":6650,"duration":2220},
    {"lrcTimestamp":"[00:08.87]","line":"два","lineTranslated":null,"milliseconds":8870,"duration":0}]}}}}
    """
    static let plainJSON = """
    {"data":{"track":{"id":"3","lyrics":{"id":"7","text":"первая строка\\n\\nвторая строка","synchronizedWordByWordLines":[],"synchronizedLines":[]}}}}
    """
    static let noneJSON = """
    {"errors":[{"message":"Lyrics does not exists","path":["track","lyrics"]}],"data":{"track":{"id":"4","lyrics":null}}}
    """
    static let expiredJSON = """
    {"errors":[{"message":"Given jwt token is not valid anymore, please refresh it or re-authenticate"}],"data":null}
    """
    /// JWT с `exp` = 2_000_000_000 (подпись — мусор, её никто не проверяет).
    static func fakeJWT(exp: Int = 2_000_000_000) -> String {
        let p = Data("{\"unlogged\":true,\"exp\":\(exp),\"iat\":\(exp - 360)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9." + p + ".c2lnbmF0dXJlLXNpZ25hdHVyZQ"
    }

    static let src = LyricsSource(provider: DeezerLyricsProvider.providerID, trackID: "1", title: "T", artist: "A", duration: 161)

    // MARK: Разбор

    static func parsing(_ check: Check) {
        let s = (try? DeezerLyricsProvider.parseSearch(Data(searchJSON.utf8))) ?? []
        check(s.count == 3 && s[0].id == "2216831097" && s[0].candidate.title == "TAMPON" && s[0].candidate.duration == 161
              && s[0].candidate.artists == ["SODA LUV"] && s[0].candidate.album == "НИЧЕГО ЛИЧНОГО 2 (DELUXE)",
              "Deezer: поиск разобран, «TAMPON|» → «TAMPON»", s.map { "\($0.id) \($0.candidate.title)" }.joined(separator: ", "))
        var quota = false
        do { _ = try DeezerLyricsProvider.parseSearch(Data(#"{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}"#.utf8)) }
        catch let e as LyricsError { if case .rateLimited = e { quota = true } } catch {}
        check(quota, "Deezer: «Quota limit exceeded» в теле — лимит, а не «не найдено»", "")

        if case .lyrics(let w) = DeezerLyricsProvider.parseLyrics(Data(wordJSON.utf8), source: src), let conv = LyricsService.convert(w) {
            let l0 = conv.lines.first
            check(w.syncType == .word && w.source.format == "deezer-word" && conv.wordSynced && conv.lines.count == 2
                  && l0?.words.map(\.text) == ["раз", "два"] && abs((l0?.time ?? 0) - 13.747) < 1e-6
                  && abs((l0?.words[1].end ?? 0) - 14.2) < 1e-6 && conv.source == "Deezer" && l0?.text == "раз два",
                  "Deezer: пословный текст (мс → с, пробелы в словах срезаны, подпись «Deezer»)", "\(conv.lines.map(\.text))")
        } else { check(false, "Deezer: пословный текст", "не разобран") }

        if case .lyrics(let l) = DeezerLyricsProvider.parseLyrics(Data(lineJSON.utf8), source: src), let conv = LyricsService.convert(l) {
            check(l.syncType == .line && conv.synced && !conv.wordSynced && conv.lines.map(\.text) == ["раз", "два"]
                  && abs(conv.lines[0].time - 6.65) < 1e-6 && abs((conv.lines[0].end ?? 0) - 8.87) < 1e-6 && conv.lines[1].end == nil,
                  "Deezer: построчный текст (конец строки по duration, 0 — до следующей)", "\(conv.lines.map { ($0.time, $0.end ?? -1) })")
        } else { check(false, "Deezer: построчный текст", "не разобран") }

        if case .lyrics(let p) = DeezerLyricsProvider.parseLyrics(Data(plainJSON.utf8), source: src), let conv = LyricsService.convert(p) {
            check(p.syncType == .none && !conv.synced && conv.plainExcerpt(2) == ["первая строка", "вторая строка"],
                  "Deezer: простой текст — без синхронизации", "")
        } else { check(false, "Deezer: простой текст", "не разобран") }

        var none = false, expired = false
        if case .none = DeezerLyricsProvider.parseLyrics(Data(noneJSON.utf8), source: src) { none = true }
        if case .expired = DeezerLyricsProvider.parseLyrics(Data(expiredJSON.utf8), source: src) { expired = true }
        check(none && expired, "Deezer: «Lyrics does not exists» — нет текста; «jwt … not valid» — обновить JWT", "")
    }

    // MARK: Сопоставление

    static func matching(_ check: Check) {
        let s = (try? DeezerLyricsProvider.parseSearch(Data(searchJSON.utf8))) ?? []
        let m = DeezerLyricsProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) }).matcher
        // Как присылает Музыка (скрин пользователя 16.11).
        let q = TrackQuery(title: "TAMPON (feat. 163ONMYNECK)", artist: "SODA LUV", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 161.691)
        let t = m.triage(q, s.map(\.candidate))
        check(t.accepted.map(\.candidate.id) == ["2216831097"], "Deezer: TAMPON (feat.) ↔ «TAMPON|» 161 с принят, чужой и ремикс 170 с — нет",
              t.summary)
    }

    // MARK: Порядок

    static func order(_ check: Check) {
        let all = LyricsSourceKind.allCases
        let old = ["apple", "amll", "netease", "qq", "kugou", "lrclib"]           // настройки до Deezer
        let o1 = LyricsSourceKind.ordered(old)
        let o2 = LyricsSourceKind.ordered(["lrclib", "lrclib", "nope", "apple"])
        check(LyricsSourceKind.ordered([]) == all && o1 == all && Array(o2.prefix(3)) == [.lrclib, .apple, .amll]
              && o2.last == .deezer && Set(o2) == Set(all) && o2.count == all.count,
              "Порядок источников: по умолчанию, новый встаёт на своё место, повторы и незнакомые — мимо",
              o2.map(\.rawValue).joined(separator: ","))
    }

    // MARK: JWT и пауза

    static func gate(_ check: Check) {
        check(DeezerGate.backoff(1) == 30 && DeezerGate.backoff(2) == 120 && DeezerGate.backoff(3) == 480 && DeezerGate.backoff(9) == 3600,
              "Deezer: пауза после отказов 30 с → 2 → 8 мин … ≤ 1 ч", "")
        let exp = DeezerGate.expiry(of: fakeJWT())
        check(exp == Date(timeIntervalSince1970: 2_000_000_000) && DeezerGate.expiry(of: "abc") == nil, "Deezer: срок JWT из exp", "")

        let auth = Counter()
        let http = StubHTTP { req in
            if req.url?.host == "auth.test" { auth.add(); return HTTPResponse(data: Data("{\"jwt\":\"\(fakeJWT())\"}".utf8), status: 200) }
            return HTTPResponse(data: Data(), status: 429)
        }
        let g = DeezerGate(minInterval: 0)
        let r = LyricsCoreSelfTest.await_ { () -> (String, String, Bool, Bool, Int) in
            let a = (try? await g.jwt(http: http, authHost: "https://auth.test")) ?? ""
            let b = (try? await g.jwt(http: http, authHost: "https://auth.test")) ?? ""
            // 429 → пауза; следующий запрос даже не уходит в сеть.
            var req = URLRequest(url: URL(string: "https://api.test/search")!)
            req.httpMethod = "GET"
            _ = try? await g.send(req, http: http)
            let cooling = await g.isCoolingDown
            let before = http.calls
            _ = try? await g.send(req, http: http)
            let skipped = http.calls == before
            return (a, b, cooling, skipped, await g.failures)
        }
        check(!r.0.isEmpty && r.0 == r.1 && auth.n == 1, "Deezer: JWT берётся один раз и живёт до exp", "запросов JWT: \(auth.n)")
        check(r.2 && r.3 && r.4 == 1, "Deezer: 429 — пауза, запросы в паузе в сеть не уходят", "отказов \(r.4)")
    }

    // MARK: Сквозной поиск на заглушке

    static func endToEnd(_ check: Check) {
        let auth = Counter()
        let gql = Counter()
        let http = StubHTTP { req in
            let host = req.url?.host ?? ""
            if host == "auth.test" { auth.add(); return HTTPResponse(data: Data("{\"jwt\":\"\(fakeJWT())\"}".utf8), status: 200) }
            if host == "api.test" { return HTTPResponse(data: Data(searchJSON.utf8), status: 200) }
            if host == "pipe.test" {
                gql.add()
                // Первый ответ — «JWT протух» раньше срока: провайдер обязан взять новый и повторить.
                return HTTPResponse(data: Data((gql.n == 1 ? expiredJSON : lineJSON).utf8), status: 200)
            }
            return HTTPResponse(data: Data(), status: 404)
        }
        let p = DeezerLyricsProvider(http: http, gate: DeezerGate(minInterval: 0), apiHost: "https://api.test",
                                     pipeHost: "https://pipe.test", authHost: "https://auth.test")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-deezer-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken(), providers: [p])
        let q = LyricsService.Query(artist: "SODA LUV", title: "TAMPON (feat. 163ONMYNECK)", album: "", duration: 161.691)
        let r = LyricsCoreSelfTest.await_ { await svc.lookup(q) }
        check(r.provider == .deezer && r.lyrics?.synced == true && r.lyrics?.source == "Deezer" && r.lyrics?.lines.count == 2
              && auth.n == 2 && gql.n == 2,
              "Deezer: сквозной поиск через каскад LyricsCore (протухший JWT обновлён, текст построчный, подпись «Deezer»)",
              "\(r.outcomes.joined(separator: "; ")) JWT \(auth.n), GraphQL \(gql.n)")
        let off = LyricsCoreSelfTest.await_ { await svc.lookup(q, sources: Set(LyricsSourceKind.allCases).subtracting([.deezer])) }
        check(off.lyrics == nil && gql.n == 2, "Deezer: выключенный источник не спрашивается", off.outcomes.joined(separator: "; "))
    }

    // MARK: Сеть (`--selftest-media net`)

    /// Живой поиск только у Deezer + весь каскад для TAMPON. false — нет сети.
    static func network(_ check: Check) -> Bool {
        let http = URLSessionHTTPClient(timeout: 10, retries: 1)
        let p = DeezerLyricsProvider(http: http)
        typealias T = (TrackQuery, SyncType?)
        let cases: [T] = [
            (TrackQuery(title: "TAMPON (feat. 163ONMYNECK)", artist: "SODA LUV", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 161.691), SyncType.none),
            (TrackQuery(title: "DTF", artist: "SODA LUV", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 193.958), .line),
            (TrackQuery(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 200.04), .word),
        ]
        var online = false
        for (q, expect) in cases {
            let t0 = Date()
            let r = LyricsCoreSelfTest.await_ { () -> Result<ProviderResponse, LyricsError> in
                do { return .success(try await p.response(for: q)) }
                catch let e as LyricsError { return .failure(e) } catch { return .failure(.network("\(type(of: error))")) }
            }
            let dt = String(format: "%.1f с", Date().timeIntervalSince(t0))
            switch r {
            case .failure(let e):
                print("skip Deezer «\(q.artist) — \(q.title)»: \(e.description) (\(dt))")
            case .success(let resp):
                online = true
                let best = resp.lyrics.first
                let got = best.map { "\($0.syncType.rawValue), \($0.lines.count) строк, id \($0.source.trackID ?? "?")" } ?? "нет (\(resp.note ?? ""))"
                // Каталог меняется: ждём «не хуже», а не ровно.
                check(best.map { $0.syncType >= (expect ?? .none) } ?? false,
                      "Deezer живьём «\(q.artist) — \(q.title)»: ожидалось ≥ \((expect ?? .none).rawValue)", "\(got), \(dt)")
            }
        }
        guard online else { return false }
        // Весь каскад (как в приложении, без токена Apple): что покажет остров для TAMPON.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-deezer-net-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken())
        let q = LyricsService.Query(artist: "SODA LUV", title: "TAMPON (feat. 163ONMYNECK)", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 161.691)
        let r = LyricsCoreSelfTest.await_ { await svc.lookup(q) }
        let kind = r.lyrics.map { $0.wordSynced ? "пословный" : $0.synced ? "построчный" : "простой" } ?? "нет"
        print("info Каскад для TAMPON без токена Apple: \(kind), \(r.lyrics?.source ?? "—") — синхронный есть только у Apple Music (нужен токен)")
        for o in r.outcomes { print("       \(o)") }
        return true
    }

    // MARK: Заглушки

    final class StubHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let handler: @Sendable (URLRequest) -> HTTPResponse
        init(_ h: @escaping @Sendable (URLRequest) -> HTTPResponse) { handler = h }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            bump()
            return handler(request)
        }
        private func bump() { lock.lock(); count += 1; lock.unlock() }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0
        func add() { lock.lock(); v += 1; lock.unlock() }
        var n: Int { lock.lock(); defer { lock.unlock() }; return v }
    }
}
