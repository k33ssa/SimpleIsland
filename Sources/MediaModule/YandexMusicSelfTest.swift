import Foundation
import IslandCore
import LyricsCore

/// Самотест Яндекс Музыки (часть `--selftest-media`): разбор поиска и ответа текста на синтетических фикстурах (форма
/// как у живых ответов 21.11, тексты придуманы), подпись запроса, адрес с подписью, сопоставление «utopi» с несколькими
/// исполнителями, LRC → построчный/пословный, разбор `#access_token` из редиректа, `/account/status`, составной `.local`
/// (Яндекс + Deezer: порядок, без входа Яндекс не спрашивается), пауза после отказов, сброс кеша «без синхронизации».
/// `net` — живой анонимный поиск «utopi».
enum YandexMusicSelfTest {
    typealias Check = LyricsSelfTest.Check
    typealias StubHTTP = DeezerLyricsSelfTest.StubHTTP
    typealias Counter = DeezerLyricsSelfTest.Counter

    static func run(_ check: Check) {
        parsing(check)
        signing(check)
        matching(check)
        auth(check)
        order(check)
        gate(check)
        endToEnd(check)
        purge(check)
    }

    // MARK: Фикстуры

    static let searchJSON = """
    {"invocationInfo":{"req-id":"x"},"result":{"type":"track","page":0,"perPage":20,"text":"cruise lirro utopi","tracks":{"total":3,"results":[
    {"id":157094546,"realId":"157094546","title":"utopi","available":true,"durationMs":190270,
     "artists":[{"id":1,"name":"cruise lirro"},{"id":2,"name":"sutra"}],"albums":[{"id":44461838,"title":"utopi","type":"single"}],
     "lyricsAvailable":true,"lyricsInfo":{"hasAvailableSyncLyrics":true,"hasAvailableTextLyrics":true}},
    {"id":"555","title":"utopi","version":"Slowed","durationMs":231000,"artists":[{"name":"cruise lirro"}],"albums":[{"title":"utopi (slowed)"}],
     "lyricsInfo":{"hasAvailableSyncLyrics":false,"hasAvailableTextLyrics":true}},
    {"id":556,"title":"Utopia","durationMs":190000,"artists":[{"name":"Someone Else"}],"albums":[],"lyricsInfo":{"hasAvailableSyncLyrics":true}}
    ]}}}
    """
    static let lyricsInfoJSON = """
    {"invocationInfo":{"req-id":"y"},"result":{"downloadUrl":"https://music-lyrics.s3.yandex.net/lyrics/1/abc.lrc","lyricId":1,"externalLyricId":"e","writers":["A"],"major":{"id":1,"name":"LYRICFIND"}}}
    """
    static let notAuthJSON = #"{"invocationInfo":{"req-id":"z"},"error":{"name":"not-authenticated","message":""}}"#
    static let lrc = """
    [ti:utopi]
    [00:12.30]первая строка
    [00:15.80]вторая строка
    [00:19.05]
    [00:21.40]третья строка
    """
    static let enhancedLRC = "[00:01.00]<00:01.00>раз <00:01.50>два\n[00:03.00]<00:03.00>три"

    static let token = "y0_SELFTEST_TOKEN_0123456789"

    // MARK: Разбор

    static func parsing(_ check: Check) {
        let s = (try? YandexMusicLyricsProvider.parseSearch(Data(searchJSON.utf8))) ?? []
        check(s.count == 3 && s[0].id == "157094546" && s[0].candidate.artists == ["cruise lirro", "sutra"]
              && abs((s[0].candidate.duration ?? 0) - 190.27) < 1e-6 && s[0].hasSync && s[0].candidate.album == "utopi"
              && s[1].id == "555" && s[1].candidate.title == "utopi (Slowed)" && !s[1].hasSync && s[1].hasText
              && s[2].id == "556" && !s[2].hasText,
              "Яндекс: поиск разобран (id числом/строкой, все исполнители, версия в названии, мс → с, есть ли текст)",
              s.map { "\($0.id) \($0.candidate.title) sync=\($0.hasSync)" }.joined(separator: ", "))
        var err = false
        do { _ = try YandexMusicLyricsProvider.parseSearch(Data("<html>".utf8)) } catch { err = true }
        check(err, "Яндекс: не-JSON в поиске — сбой, а не «не найдено»", "")

        let dl = try? YandexMusicLyricsProvider.parseLyricsInfo(Data(lyricsInfoJSON.utf8))
        var unauth = false
        do { _ = try YandexMusicLyricsProvider.parseLyricsInfo(Data(notAuthJSON.utf8)) } catch let e as LyricsError { unauth = e == .unauthorized } catch {}
        let empty = try? YandexMusicLyricsProvider.parseLyricsInfo(Data(#"{"result":{}}"#.utf8))
        check(dl.flatMap { $0 }?.host == "music-lyrics.s3.yandex.net" && unauth && empty == .some(nil),
              "Яндекс: ответ /lyrics → downloadUrl; not-authenticated — нет доступа; без ссылки — текста нет", "")

        let ok = ["https://music-lyrics.s3.yandex.net/a.lrc", "https://storage.mds.yandex.net/x", "https://music.yandex.ru/l"]
        let bad = ["http://music-lyrics.s3.yandex.net/a.lrc", "https://evil.com/a.lrc", "https://yandex.net.evil.com/a",
                   "https://notyandex.net/a", "https://yandex.ru.evil.com/a"]
        check(ok.allSatisfy { YandexMusicLyricsProvider.isYandexDownload(URL(string: $0)!) }
              && !bad.contains { YandexMusicLyricsProvider.isYandexDownload(URL(string: $0)!) },
              "Яндекс: файл текста берём только по https с доменов Яндекса", "")

        let src = LyricsSource(provider: .local, trackID: "157094546", title: "utopi", artist: "cruise lirro, sutra",
                               duration: 190.27, format: "yandex-lrc")
        if let l = YandexMusicLyricsProvider.parseLRC(lrc, source: src, duration: 190.27), let conv = LyricsService.convert(l) {
            check(l.syncType == .line && l.source.format == "yandex-lrc" && LyricsSourceKind.of(l.source) == .yandex
                  && conv.synced && !conv.wordSynced && conv.source == "Яндекс Музыка"
                  && conv.lines.filter { !$0.text.isEmpty }.map(\.text) == ["первая строка", "вторая строка", "третья строка"]
                  && abs(conv.lines[0].time - 12.3) < 1e-6,
                  "Яндекс: LRC → построчный текст, подпись «Яндекс Музыка», источник узнаётся по формату", "\(conv.lines.map(\.text))")
        } else { check(false, "Яндекс: LRC → построчный текст", "не разобран") }
        if let w = YandexMusicLyricsProvider.parseLRC(enhancedLRC, source: src, duration: 10), let conv = LyricsService.convert(w) {
            check(w.syncType == .word && conv.wordSynced && conv.lines.first?.words.map(\.text) == ["раз", "два"],
                  "Яндекс: Enhanced LRC (метки слов) → пословный", "\(conv.lines.map(\.text))")
        } else { check(false, "Яндекс: Enhanced LRC → пословный", "не разобран") }
        check(YandexMusicLyricsProvider.parseLRC("\n\n", source: src, duration: 10) == nil, "Яндекс: пустой файл — текста нет", "")
        let deezer = LyricsSource(provider: .local, format: "deezer-line")
        check(LyricsSourceKind.of(deezer) == .deezer && LyricsSourceKind.of(LyricsSource(provider: .netease)) == .netease,
              "Источник текста: `.local` + deezer-… — Deezer, остальные по id", "")
    }

    // MARK: Подпись

    static func signing(_ check: Check) {
        // Векторы посчитаны python (hmac/hashlib/base64) по `get_sign_request` из MarshalX/yandex-music-api.
        let a = YandexMusicLyricsProvider.sign(trackID: "157094546", timestamp: 1_763_740_800)
        let b = YandexMusicLyricsProvider.sign(trackID: "1", timestamp: 1_700_000_000)
        check(a == "Z1YND45N+iRVMOk8xWqI1hcezuXgdYgFEFs2g1WmMgM=" && b == "6Dzv8y14nw5mpoFC0HC0PQLiEUg1FSltm71hhVEn6cA=",
              "Яндекс: подпись base64(HMAC-SHA256(ключ, id+timeStamp)) совпадает с эталоном", a)
        let u = YandexMusicLyricsProvider.lyricsURL(apiHost: "https://api.music.yandex.net", trackID: "157094546", format: "LRC",
                                                    timestamp: 1_763_740_800, sign: a)?.absoluteString ?? ""
        check(u == "https://api.music.yandex.net/tracks/157094546/lyrics?format=LRC&timeStamp=1763740800&sign=Z1YND45N%2BiRVMOk8xWqI1hcezuXgdYgFEFs2g1WmMgM%3D",
              "Яндекс: подпись в адресе закодирована (`+` → %2B, `=` → %3D)", u)
    }

    // MARK: Сопоставление

    static func matching(_ check: Check) {
        let s = (try? YandexMusicLyricsProvider.parseSearch(Data(searchJSON.utf8))) ?? []
        let m = YandexMusicLyricsProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) }).matcher
        let variants = ["cruise lirro, sutra", "cruise lirro & sutra", "cruise lirro feat. sutra", "cruise lirro"]
        var res: [String] = []
        for a in variants {
            let q = TrackQuery(title: "utopi", artist: a, album: "utopi", duration: 190)
            res.append(m.triage(q, s.map(\.candidate)).accepted.map(\.candidate.id).joined(separator: ","))
        }
        check(res.allSatisfy { $0 == "157094546" }, "Яндекс: «utopi» 190 с ↔ запись 190,27 с при исполнителях через «,», «&», feat.; slowed 231 с и чужой — нет",
              res.joined(separator: " | "))
        let far = m.triage(TrackQuery(title: "utopi", artist: "cruise lirro, sutra", duration: 200), s.map(\.candidate))
        check(far.accepted.isEmpty, "Яндекс: длительность ±3 с — 200 с против 190,27 не принимается", far.summary)
    }

    // MARK: Вход

    static func auth(_ check: Check) {
        typealias A = YandexMusicAuth
        let u = A.authorizeURL.absoluteString
        check(u == "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d",
              "Яндекс: адрес входа — implicit flow с client_id приложения Яндекс Музыки", u)
        let cases: [(String, A.Redirect?)] = [
            ("https://music.yandex.ru/#access_token=\(token)&token_type=bearer&expires_in=31536000", .token(token)),
            ("https://oauth.yandex.ru/verification_code#access_token=\(token)&token_type=bearer", .token(token)),
            ("yandexmusic://auth/finish#access_token=\(token)&expires_in=1", .token(token)),
            ("https://music.yandex.ru/#error=access_denied&error_description=user%20denied", .error("user denied")),
            ("https://evil.com/#access_token=\(token)", nil),
            ("https://music.yandex.ru.evil.com/#access_token=\(token)", nil),
            ("http://music.yandex.ru/#access_token=\(token)", nil),
            ("https://music.yandex.ru/#access_token=short", nil),
            (A.authorizeURL.absoluteString, nil),
            ("https://passport.yandex.ru/auth?retpath=https%3A%2F%2Foauth.yandex.ru%2Fauthorize%3Fresponse_type%3Dtoken", nil),
        ]
        let bad = cases.filter { A.parseRedirect(URL(string: $0.0)!) != $0.1 }.map(\.0)
        check(bad.isEmpty, "Яндекс: токен из `#access_token` редиректа — только с доменов Яндекса по https или своей схемы",
              bad.joined(separator: " ; "))
        check(A.isYandexHost("yandex.ru") && A.isYandexHost("oauth.yandex.com") && A.isYandexHost("music.yandex.kz")
              && !A.isYandexHost("notyandex.ru") && !A.isYandexHost("yandex.ru.evil.com"), "Яндекс: проверка домена", "")

        let st = A.parseStatus(Data(#"{"result":{"account":{"uid":42,"login":"user1","now":"x"},"plus":{"hasPlus":true}}}"#.utf8))
        let anon = A.parseStatus(Data(#"{"result":{"account":{"now":"x","region":225}}}"#.utf8))
        check(st == .connected(login: "user1", plus: true) && anon == .invalid,
              "Яндекс: /account/status — вошли (uid, логин, Плюс); без uid — вход не принят", "\(st) / \(anon)")
        let http = StubHTTP { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            return auth == "OAuth \(token)"
                ? HTTPResponse(data: Data(#"{"result":{"account":{"uid":1,"login":"u"}}}"#.utf8), status: 200)
                : HTTPResponse(data: Data(), status: 401)
        }
        let r = LyricsCoreSelfTest.await_ {
            (await A.verify(token: token, http: http, host: "https://api.test"), await A.verify(token: "bad", http: http, host: "https://api.test"))
        }
        check(r.0 == .connected(login: "u", plus: nil) && r.1 == .invalid, "Яндекс: проверка токена (200 — подключена, 401 — войти заново)", "")

        let file = SecretFile(memoryOnly: true)
        let t = YandexMusicToken(file: file)
        t.set("  \(token)\n")
        let saved = t.current()
        let other = file.value(service: LyricsService.keychainService, account: CredentialKey.mediaUserToken.rawValue)
        t.set(nil)
        check(saved == token && other == nil && t.current() == nil,
              "Яндекс: токен в файле секретов (служба local.simpleisland.lyrics, свой ключ), «Выйти» удаляет", "")
    }

    // MARK: Порядок и составной `.local`

    static func order(_ check: Check) {
        let all = LyricsSourceKind.allCases
        check(Array(all.prefix(3)) == [.apple, .amll, .yandex] && all.firstIndex(of: .yandex)! < all.firstIndex(of: .netease)!,
              "Яндекс: по умолчанию включён и стоит перед NetEase",
              all.map(\.rawValue).joined(separator: ","))
        let old = LyricsSourceKind.ordered(["lrclib", "apple", "amll", "netease", "qq", "kugou", "deezer"])
        check(old.firstIndex(of: .yandex) == 3 && old[2] == .amll, "Яндекс: в сохранённом порядке встаёт за AMLL",
              old.map(\.rawValue).joined(separator: ","))

        let y = YandexMusicLyricsProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) })
        let d = DeezerLyricsProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) })
        let parts: [OwnLyricsProviders.Part] = [.init(kind: .apple, provider: AppleMusicProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) }, credentials: InMemoryCredentialStore())),
                                                .init(kind: .yandex, provider: y), .init(kind: .netease, provider: NetEaseProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) })),
                                                .init(kind: .deezer, provider: d)]
        let c = LyricsService.collapseOwn(parts)
        let one = LyricsService.collapseOwn(parts.filter { $0.kind != .yandex })
        check(c.map(\.id) == [.appleMusic, .local, .netease] && (c[1] as? OwnLyricsProviders)?.parts.map(\.kind) == [.yandex, .deezer]
              && one.map(\.id) == [.appleMusic, .netease, .local] && one[2] is DeezerLyricsProvider,
              "Яндекс + Deezer — одно звено `.local` на месте первого (у движка память ответов по id); один — как есть",
              c.map(\.id.rawValue).joined(separator: ","))
    }

    // MARK: Пауза

    static func gate(_ check: Check) {
        let http = StubHTTP { req in HTTPResponse(data: Data(), status: req.url?.path == "/auth" ? 401 : 429) }
        let g = YandexGate(minInterval: 0)
        let r = LyricsCoreSelfTest.await_ { () -> (Bool, Bool, Bool, Int) in
            _ = try? await g.send(URLRequest(url: URL(string: "https://api.test/auth")!), http: http, authorized: true)
            let rejected = await g.tokenRejected, coolingAfter401 = await g.isCoolingDown
            _ = try? await g.send(URLRequest(url: URL(string: "https://api.test/x")!), http: http)
            let cooling = await g.isCoolingDown
            let before = http.calls
            _ = try? await g.send(URLRequest(url: URL(string: "https://api.test/x")!), http: http)
            return (rejected, !coolingAfter401, cooling && http.calls == before, await g.failures)
        }
        check(r.0 && r.1 && r.2 && r.3 == 1, "Яндекс: 401 — «войти заново» без паузы; 429 — пауза, запросы в паузе не уходят",
              "\(r)")
    }

    // MARK: Сквозной поиск на заглушке

    static func stubDeezerHTTP(lineJSON: Bool) -> StubHTTP {
        StubHTTP { req in
            switch req.url?.host ?? "" {
            case "auth.test": return HTTPResponse(data: Data("{\"jwt\":\"\(DeezerLyricsSelfTest.fakeJWT())\"}".utf8), status: 200)
            case "api.test":
                let s = #"{"data":[{"id":77,"title":"utopi","duration":190,"artist":{"name":"cruise lirro"},"album":{"title":"utopi"}}]}"#
                return HTTPResponse(data: Data(s.utf8), status: 200)
            case "pipe.test":
                return HTTPResponse(data: Data((lineJSON ? DeezerLyricsSelfTest.lineJSON : DeezerLyricsSelfTest.plainJSON).utf8), status: 200)
            default: return HTTPResponse(data: Data(), status: 404)
            }
        }
    }

    static func endToEnd(_ check: Check) {
        let searches = Counter(), lyricsCalls = Counter(), files = Counter()
        let authSeen = Counter()
        let yhttp = StubHTTP { req in
            let path = req.url?.path ?? ""
            if req.url?.host == "ym.test", path == "/search" { searches.add(); return HTTPResponse(data: Data(searchJSON.utf8), status: 200) }
            if req.url?.host == "ym.test", path.hasSuffix("/lyrics") {
                lyricsCalls.add()
                let q = req.url?.query ?? ""
                guard req.value(forHTTPHeaderField: "Authorization") == "OAuth \(token)", q.contains("format=LRC"), q.contains("sign=") else {
                    return HTTPResponse(data: Data(notAuthJSON.utf8), status: 401)
                }
                return HTTPResponse(data: Data(lyricsInfoJSON.utf8), status: 200)
            }
            if req.url?.host == "music-lyrics.s3.yandex.net" {
                files.add()
                if req.value(forHTTPHeaderField: "Authorization") != nil { authSeen.add() }
                return HTTPResponse(data: Data(lrc.utf8), status: 200)
            }
            return HTTPResponse(data: Data(), status: 404)
        }
        let file = SecretFile(memoryOnly: true)
        let tok = YandexMusicToken(file: file)
        let y = YandexMusicLyricsProvider(http: yhttp, gate: YandexGate(minInterval: 0), token: tok, apiHost: "https://ym.test")
        let d = DeezerLyricsProvider(http: stubDeezerHTTP(lineJSON: false), gate: DeezerGate(minInterval: 0), apiHost: "https://api.test",
                                     pipeHost: "https://pipe.test", authHost: "https://auth.test")
        let q = LyricsService.Query(artist: "cruise lirro, sutra", title: "utopi", album: "utopi", duration: 190)
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-yandex-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }

        // 1. Без входа: Яндекс не спрашивается вовсе (даже поиск), остров показывает простой текст Deezer.
        let svc = LyricsService(cacheDir: base.appendingPathComponent("a"), credentials: LyricsCoreSelfTest.noToken(), providers: [y, d])
        let r0 = LyricsCoreSelfTest.await_ { await svc.lookup(q) }
        check(r0.provider == .deezer && r0.lyrics?.synced == false && searches.n == 0 && lyricsCalls.n == 0
              && r0.outcomes.contains { $0.contains("yandex: пропущен (нет входа)") },
              "Яндекс: без входа не спрашивается (ни поиска), текст — простой от Deezer", r0.outcomes.joined(separator: "; "))

        // 2. Вошли: сброс (память движка, кеш «без синхронизации») → построчный от Яндекса.
        tok.set(token)
        let purged = LyricsCoreSelfTest.await_ { await svc.accountChanged() }
        let r1 = LyricsCoreSelfTest.await_ { await svc.lookup(q) }
        let all = (r1.outcomes + r1.rejected).joined(separator: "; ")
        check(purged == 1 && r1.provider == .yandex && r1.lyrics?.synced == true && r1.lyrics?.source == "Яндекс Музыка"
              && searches.n == 1 && lyricsCalls.n == 1 && files.n == 1 && authSeen.n == 0
              && r1.outcomes.contains { $0.contains("yandex: line") } && r1.outcomes.contains { $0.hasPrefix("yandex+deezer:") },
              "Яндекс: после входа — построчный текст (поиск 1, подписанный запрос 1, файл без токена), простой из кеша сброшен",
              "сброшено \(purged); поиск \(searches.n), lyrics \(lyricsCalls.n), файл \(files.n); \(all)")
        check(!all.contains(token), "Яндекс: токена нет в разборе поиска", "")

        // 3. Равная синхронизация (оба построчно): решает порядок пользователя.
        let d2 = DeezerLyricsProvider(http: stubDeezerHTTP(lineJSON: true), gate: DeezerGate(minInterval: 0), apiHost: "https://api.test",
                                      pipeHost: "https://pipe.test", authHost: "https://auth.test")
        let svc2 = LyricsService(cacheDir: base.appendingPathComponent("b"), credentials: LyricsCoreSelfTest.noToken(), providers: [y, d2])
        let q2 = LyricsService.Query(artist: "cruise lirro", title: "utopi", album: "", duration: 190)
        let byDefault = LyricsCoreSelfTest.await_ { await svc2.lookup(q2) }
        var custom = LyricsSourceKind.allCases.filter { $0 != .deezer }
        custom.insert(.deezer, at: 0)
        let deezerFirst = LyricsCoreSelfTest.await_ { await svc2.lookup(q2, order: custom) }
        check(byDefault.provider == .yandex && deezerFirst.provider == .deezer,
              "Яндекс и Deezer оба построчно: выше в порядке — тот и показан", "\(byDefault.provider?.rawValue ?? "—") / \(deezerFirst.provider?.rawValue ?? "—")")

        // 4. Выключенный Яндекс не спрашивается.
        let before = searches.n
        let off = LyricsCoreSelfTest.await_ { await svc2.lookup(LyricsService.Query(artist: "cruise lirro", title: "utopi", album: "x", duration: 190),
                                                                   sources: Set(LyricsSourceKind.allCases).subtracting([.yandex])) }
        check(off.provider == .deezer && searches.n == before, "Яндекс: выключенный источник не спрашивается", off.outcomes.joined(separator: "; "))

        // 5. Токен отвергнут (401): сбой, а не «не найдено» — итог не кешируется.
        tok.set("y0_REVOKED_TOKEN_000000")
        let svc3 = LyricsService(cacheDir: base.appendingPathComponent("c"), credentials: LyricsCoreSelfTest.noToken(), providers: [y])
        let bad = LyricsCoreSelfTest.await_ { await svc3.lookup(q) }
        check(bad.lyrics == nil && bad.hadFailures && svc3.cache.load(key: LyricsService.cacheKey(q)) == nil,
              "Яндекс: 401 на тексте — сбой источника, «не найдено» не запоминается", bad.outcomes.joined(separator: "; "))
        tok.set(nil)
    }

    // MARK: Сброс кеша

    static func purge(_ check: Check) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-yandex-purge-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken(), providers: [])
        let src = LyricsSource(provider: .lrclib, title: "t", artist: "a")
        let line = LyricsCore.Lyrics(source: src, syncType: .line, lines: [LyricsCore.LyricLine(key: "L1", begin: 1, text: "x")])
        let plain = LyricsCore.Lyrics(source: src, syncType: .none, lines: [LyricsCore.LyricLine(key: "L1", text: "x")])
        svc.cache.store(key: "k-line", best: line, alternatives: [])
        svc.cache.store(key: "k-plain", best: plain, alternatives: [])
        svc.cache.store(key: "k-none", best: nil, alternatives: [])
        let n = svc.purgeUnsyncedCache()
        check(n == 2 && svc.cache.load(key: "k-line") != nil && svc.cache.load(key: "k-plain") == nil && svc.cache.load(key: "k-none") == nil,
              "Вход в Яндекс: из кеша уходят «не найдено» и простой текст, синхронный остаётся", "удалено \(n)")
    }

    // MARK: Сеть (`--selftest-media net`)

    /// Живой анонимный поиск «utopi» (токен не нужен). false — нет сети.
    static func network(_ check: Check) -> Bool {
        let p = YandexMusicLyricsProvider(http: URLSessionHTTPClient(timeout: 10, retries: 1), gate: YandexGate(),
                                          token: YandexMusicToken(file: SecretFile(memoryOnly: true)))
        let q = TrackQuery(title: "utopi", artist: "cruise lirro, sutra", album: "utopi", duration: 190)
        let t0 = Date()
        let r = LyricsCoreSelfTest.await_ { () -> Result<[YandexMusicLyricsProvider.Track], LyricsError> in
            do { return .success(try await p.search("cruise lirro utopi")) }
            catch let e as LyricsError { return .failure(e) } catch { return .failure(.network("\(type(of: error))")) }
        }
        let dt = String(format: "%.1f с", Date().timeIntervalSince(t0))
        switch r {
        case .failure(let e):
            print("skip Яндекс: анонимный поиск — \(e.description) (\(dt))")
            return false
        case .success(let list):
            let acc = p.matcher.triage(q, list.map(\.candidate)).accepted.map(\.candidate.id)
            let hit = list.first { acc.contains($0.id) }
            check(hit?.id == "157094546" && hit?.hasSync == true,
                  "Яндекс живьём: анонимный поиск «utopi» — cruise lirro, sutra → id 157094546, есть синхронный текст",
                  "принято \(acc), \(list.count) записей, \(dt)")
            let none = LyricsCoreSelfTest.await_ { await p.isAvailable() }
            check(!none, "Яндекс живьём: без входа текст не спрашивается (isAvailable = false)", "")
            return true
        }
    }
}
