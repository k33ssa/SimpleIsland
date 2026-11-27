import Foundation
import IslandCore
import LyricsCore

/// Самотест источника Musixmatch (часть `--selftest-media`): разбор `macro.subtitles.get` и `track.richsync.get` на
/// синтетических фикстурах (форма как у живых ответов 26.11, тексты придуманы), сопоставление, порядок источников,
/// токен (сохраняется, из нулей — не годится, captcha — пауза часами без новых `token.get`), частота, память ответов,
/// сквозной поиск через `LyricsService` на заглушке HTTP. `net` — `network`: живой поиск по тестовым трекам.
enum MusixmatchSelfTest {
    typealias Check = LyricsSelfTest.Check
    typealias StubHTTP = DeezerLyricsSelfTest.StubHTTP
    typealias Counter = DeezerLyricsSelfTest.Counter

    static func run(_ check: Check) {
        parsing(check)
        matching(check)
        order(check)
        token(check)
        gate(check)
        endToEnd(check)
    }

    // MARK: Фикстуры (синтетика)

    static func macro(track: String, subtitles: String? = nil, lyrics: String? = nil, lyricsStatus: Int = 200) -> String {
        let subs = subtitles.map { s in
            #"{"message":{"header":{"status_code":200,"available":1},"body":{"subtitle_list":[{"subtitle":{"subtitle_id":1,"subtitle_body":"# + "\"" + s + "\"" + #","subtitle_length":200}}]}}}"#
        } ?? #"{"message":{"header":{"status_code":200,"available":0},"body":{"subtitle_list":[]}}}"#
        let lyr = lyrics.map { l in
            #"{"message":{"header":{"status_code":200},"body":{"lyrics":{"lyrics_id":2,"restricted":0,"instrumental":0,"lyrics_body":"# + "\"" + l + "\"" + "}}}}"
        } ?? #"{"message":{"header":{"status_code":\#(lyricsStatus)},"body":[]}}"#
        return #"{"message":{"header":{"status_code":200},"body":{"macro_calls":{"track.lyrics.get":"# + lyr
            + #","track.subtitles.get":"# + subs + #","userblob.get":{"message":{"header":{"status_code":404}}},"matcher.track.get":"#
            + track + "}}}}"
    }

    static func track(_ name: String, _ artist: String, _ len: Int, richsync: Int = 0, subtitles: Int = 0, lyrics: Int = 1,
                      instrumental: Int = 0) -> String {
        #"{"message":{"header":{"status_code":200,"confidence":950,"mode":"search"},"body":{"track":{"track_id":11,"commontrack_id":22,"#
            + #""track_name":"\#(name)","artist_name":"\#(artist)","album_name":"Альбом","track_length":\#(len),"has_lyrics":\#(lyrics),"#
            + #""has_subtitles":\#(subtitles),"has_richsync":\#(richsync),"instrumental":\#(instrumental)}}}}"#
    }

    static let subtitleBody = #"[{\"text\":\"раз два\",\"time\":{\"total\":13.14}},{\"text\":\"\",\"time\":{\"total\":16.57}},{\"text\":\"три\",\"time\":{\"total\":27.1}}]"#
    static let wordMacro = macro(track: track("Синица", "Тестовый Артист feat. Гость", 200, richsync: 1, subtitles: 1),
                                 subtitles: subtitleBody, lyrics: #"раз два\n\nтри"#)
    static let lineMacro = macro(track: track("Синица", "Тестовый Артист", 200, subtitles: 1), subtitles: subtitleBody,
                                 lyrics: #"раз два\n\nтри"#)
    static let plainMacro = macro(track: track("TAMPON|", "SODA LUV feat. 163ONMYNECK", 161),
                                  lyrics: #"первая строка\nвторая строка\n\n******* This Lyrics is NOT for Commercial use *******\n(1409624512345)"#)
    static let noneMacro = macro(track: track("all eyes on me", "echstacy", 103, lyrics: 0), lyricsStatus: 404)
    static let instrumentalMacro = macro(track: track("Синица", "Тестовый Артист", 200, lyrics: 0, instrumental: 1), lyricsStatus: 404)
    static let notInCatalog = #"{"message":{"header":{"status_code":200},"body":{"macro_calls":{"matcher.track.get":{"message":{"header":{"status_code":404},"body":[]}}}}}}"#
    /// «Раз» — слово, «д» + «ва» — слоги одного слова (без пробела между кусками), «три» — следующая строка.
    static let richsyncJSON = #"{"message":{"header":{"status_code":200},"body":{"richsync":{"richsync_id":5,"richsync_body":"[{\"ts\":13.5,\"te\":14.4,\"l\":[{\"c\":\"Раз\",\"o\":0},{\"c\":\" \",\"o\":0.3},{\"c\":\"д\",\"o\":0.35},{\"c\":\"ва\",\"o\":0.5}],\"x\":\"Раз два\"},{\"ts\":27.3,\"te\":28.1,\"l\":[{\"c\":\"три\",\"o\":0}],\"x\":\"три\"}]"}}}}"#
    static let captchaJSON = #"{"message":{"header":{"status_code":401,"execute_time":0.002,"hint":"captcha"},"body":""}}"#
    static let renewJSON = #"{"message":{"header":{"status_code":401,"hint":"renew"},"body":""}}"#
    static let realToken = "2611a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829"
    static let tokenJSON = #"{"message":{"header":{"status_code":200},"body":{"user_token":"\#(realToken)","app_id":"mac-ios-v2.0"}}}"#
    static let zeroTokenJSON = #"{"message":{"header":{"status_code":200},"body":{"user_token":"\#(String(repeating: "0", count: 54))"}}}"#

    static func obj(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    static let src = LyricsSource(provider: MusixmatchLyricsProvider.providerID, trackID: "11", title: "T", artist: "A", duration: 200)

    // MARK: Разбор

    static func parsing(_ check: Check) {
        let m = MusixmatchLyricsProvider.parseMacro(obj(wordMacro))
        let t = m?.track
        check(t?.candidate.id == "11" && t?.commontrackID == "22" && t?.hasRichsync == true && t?.candidate.duration == 200
              && t?.candidate.artists == ["Тестовый Артист", "Гость"] && t?.candidate.album == "Альбом",
              "Musixmatch: matcher.track.get разобран (id, commontrack, has_richsync, исполнители через feat.)",
              "\(t.map { "\($0.candidate.artists)" } ?? "нет")")

        if let w = MusixmatchLyricsProvider.parseRichsync(obj(richsyncJSON), source: src), let conv = LyricsService.convert(w) {
            let l0 = conv.lines.first
            check(w.syncType == .word && w.source.format == "musixmatch-word" && LyricsSourceKind.of(w.source) == .musixmatch
                  && conv.wordSynced && conv.lines.count == 2 && l0?.words.map(\.text) == ["Раз", "д", "ва"]
                  && l0?.words.map(\.joins) == [false, false, true] && abs((l0?.words[0].end ?? 0) - 13.8) < 1e-6
                  && abs((l0?.words[2].begin ?? 0) - 14.0) < 1e-6 && abs((l0?.words[2].end ?? 0) - 14.4) < 1e-6
                  && conv.source == "Musixmatch" && l0?.text == "Раз два",
                  "Musixmatch: richsync → пословный (слово до следующего куска, слоги без пробела — продолжение, подпись «Musixmatch»)",
                  "\(conv.lines.map(\.text)) \(l0?.words.map { ($0.text, $0.begin, $0.end) } ?? [])")
        } else { check(false, "Musixmatch: richsync → пословный", "не разобран") }

        if let l = MusixmatchLyricsProvider.parseMacro(obj(lineMacro))?.subtitles(source: src), let conv = LyricsService.convert(l) {
            check(l.syncType == .line && l.source.format == "musixmatch-line" && conv.synced && !conv.wordSynced
                  && conv.lines.map(\.text) == ["раз два", "", "три"] && abs(conv.lines[0].time - 13.14) < 1e-6
                  && abs((conv.lines[0].end ?? 0) - 16.57) < 1e-6 && conv.lines[2].end == nil,
                  "Musixmatch: subtitles → построчный (конец строки — начало следующей)", "\(conv.lines.map { ($0.text, $0.time) })")
        } else { check(false, "Musixmatch: subtitles → построчный", "не разобран") }

        if let p = MusixmatchLyricsProvider.parseMacro(obj(plainMacro))?.plain(source: src), let conv = LyricsService.convert(p) {
            check(p.syncType == .none && !conv.synced && conv.lines.map(\.text) == ["первая строка", "вторая строка"],
                  "Musixmatch: простой текст без хвоста «NOT for Commercial use»", "\(conv.lines.map(\.text))")
        } else { check(false, "Musixmatch: простой текст", "не разобран") }

        let none = MusixmatchLyricsProvider.parseMacro(obj(noneMacro))
        let absent = MusixmatchLyricsProvider.parseMacro(obj(notInCatalog))
        check(none?.track != nil && none?.plain(source: src) == nil && none?.subtitles(source: src) == nil
              && absent != nil && absent?.track == nil,
              "Musixmatch: нет текста (lyrics 404) и нет в каталоге (matcher 404) — пусто, не сбой", "")

        typealias S = MusixmatchLyricsProvider.Status
        let st = [captchaJSON, renewJSON, tokenJSON, #"{"message":{"header":{"status_code":404}}}"#].map { MusixmatchLyricsProvider.status(obj($0)) }
        check(st == [S.captcha, .renew, .ok, .notFound], "Musixmatch: статус в теле (401 captcha / 401 renew / 200 / 404)", "\(st)")
        check(MusixmatchGate.isRealToken(realToken) && !MusixmatchGate.isRealToken(String(repeating: "0", count: 54))
              && !MusixmatchGate.isRealToken("abc"), "Musixmatch: токен из нулей (apic-desktop) — не токен", "")
    }

    // MARK: Сопоставление

    static func matching(_ check: Check) {
        let m = MusixmatchLyricsProvider(http: StubHTTP { _ in HTTPResponse(data: Data(), status: 500) }).matcher
        let tampon = MusixmatchLyricsProvider.parseMacro(obj(plainMacro))!.track!.candidate
        let q = TrackQuery(title: "TAMPON (feat. 163ONMYNECK)", artist: "SODA LUV", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 161.691)
        let ok = m.triage(q, [tampon]).accepted.count == 1
        var far = tampon; far.duration = 170
        var other = tampon; other.artists = ["PolsKii"]
        let farOK = m.triage(q, [far]).accepted.isEmpty, otherOK = m.triage(q, [other]).accepted.isEmpty
        check(ok && farOK && otherOK, "Musixmatch: TAMPON (feat.) ↔ «TAMPON|» 161 с принят; 170 с и чужой исполнитель — нет",
              m.triage(q, [far, other]).summary)
    }

    // MARK: Порядок

    static func order(_ check: Check) {
        let all = LyricsSourceKind.allCases
        let iy = all.firstIndex(of: .yandex)!, im = all.firstIndex(of: .musixmatch)!, ine = all.firstIndex(of: .netease)!
        let saved = LyricsSourceKind.ordered(["lrclib", "apple", "amll", "yandex", "netease", "qq", "kugou", "deezer"])
        check(im == iy + 1 && ine == im + 1 && saved.firstIndex(of: .musixmatch) == 4 && saved[3] == .yandex
              && LyricsSourceKind.own == [.yandex, .musixmatch, .deezer],
              "Musixmatch: по умолчанию после Яндекса и перед NetEase, в сохранённом порядке встаёт за Яндексом",
              saved.map(\.rawValue).joined(separator: ","))
        let dead = StubHTTP { _ in HTTPResponse(data: Data(), status: 500) }
        let parts: [OwnLyricsProviders.Part] = [.init(kind: .yandex, provider: YandexMusicLyricsProvider(http: dead)),
                                                .init(kind: .musixmatch, provider: MusixmatchLyricsProvider(http: dead)),
                                                .init(kind: .netease, provider: NetEaseProvider(http: dead)),
                                                .init(kind: .deezer, provider: DeezerLyricsProvider(http: dead))]
        let c = LyricsService.collapseOwn(parts)
        check(c.map(\.id) == [.local, .netease] && (c[0] as? OwnLyricsProviders)?.parts.map(\.kind) == [.yandex, .musixmatch, .deezer]
              && LyricsSourceKind.of(MusixmatchLyricsProvider(http: dead)) == .musixmatch,
              "Musixmatch: в одном звене `.local` с Яндексом и Deezer", c.map(\.id.rawValue).joined(separator: ","))
    }

    // MARK: Токен

    static func token(_ check: Check) {
        let file = SecretFile(memoryOnly: true)
        let store = MusixmatchToken(file: file)
        let clock = Clock()
        let g = MusixmatchGate(minInterval: 0, now: { clock.now })
        let tokenCalls = Counter()
        let mode = Box("captcha")
        let http = StubHTTP { req in
            guard req.url?.path.hasSuffix("token.get") == true else { return HTTPResponse(data: Data(), status: 404) }
            tokenCalls.add()
            let body = mode.v == "captcha" ? captchaJSON : mode.v == "zero" ? zeroTokenJSON : tokenJSON
            return HTTPResponse(data: Data(body.utf8), status: 200)
        }
        let r = LyricsCoreSelfTest.await_ { () -> (Bool, Int, Bool, Bool, Int, String?, Bool, Int) in
            let first = (try? await g.token(http: http, apiHost: "https://mxm.test", store: store)) == nil
            let n1 = tokenCalls.n
            // В паузе после captcha `token.get` не уходит, источник «недоступен».
            let second = (try? await g.token(http: http, apiHost: "https://mxm.test", store: store)) == nil
            let usable = await g.isUsable(token: store)
            let n2 = tokenCalls.n
            // Пауза кончилась (1 ч) — токен из нулей тоже не годится, пауза растёт.
            clock.now = clock.now.addingTimeInterval(3601)
            mode.v = "zero"
            _ = try? await g.token(http: http, apiHost: "https://mxm.test", store: store)
            let (fails, until) = store.backoff()
            clock.now = until.addingTimeInterval(1)
            mode.v = "ok"
            let t = try? await g.token(http: http, apiHost: "https://mxm.test", store: store)
            let n3 = tokenCalls.n
            _ = try? await g.token(http: http, apiHost: "https://mxm.test", store: store)
            return (first && second, n1 * 10 + n2, usable, store.backoff().0 == 0, fails, t, store.current() == realToken, tokenCalls.n - n3)
        }
        check(r.0 && r.1 == 11 && !r.2, "Musixmatch: captcha на token.get — пауза, повторный token.get в паузе не уходит", "token.get: \(r.1)")
        check(r.4 == 2 && r.5 == realToken && r.6 && r.3 && r.7 == 0,
              "Musixmatch: токен из нулей — пауза растёт; настоящий — в файле секретов, дальше без token.get", "отказов \(r.4)")
        let saved = file.value(service: LyricsService.keychainService, account: "musixmatchToken")
        check(saved == realToken, "Musixmatch: токен — служба local.simpleisland.lyrics, ключ musixmatchToken", "")
    }

    // MARK: Частота, captcha с токеном, память

    static func gate(_ check: Check) {
        check(MusixmatchGate.captchaBackoff(1) == 3600 && MusixmatchGate.captchaBackoff(2) == 7200 && MusixmatchGate.captchaBackoff(9) == 43200
              && MusixmatchGate.backoff(1) == 30 && MusixmatchGate.backoff(9) == 3600,
              "Musixmatch: пауза captcha 1 → 2 → 4 ч … ≤ 12 ч, 429/5xx 30 с … ≤ 1 ч", "")
        // Частота: три запроса подряд — не чаще 0,5 с.
        let fast = StubHTTP { _ in HTTPResponse(data: Data(tokenJSON.utf8), status: 200) }
        let g = MusixmatchGate()
        let dt = LyricsCoreSelfTest.await_ { () -> TimeInterval in
            let t0 = Date()
            for _ in 0..<3 { _ = try? await g.send(URLRequest(url: URL(string: "https://mxm.test/ws/1.1/x")!), http: fast) }
            return Date().timeIntervalSince(t0)
        }
        check(dt >= 0.95 && dt < 3, "Musixmatch: не чаще запроса в 0,5 с", String(format: "3 запроса за %.2f с", dt))

        // Captcha на запросе с токеном: всё в паузу, дальше в сеть не ходим.
        let file = SecretFile(memoryOnly: true)
        let store = MusixmatchToken(file: file)
        store.set(realToken)
        let http = StubHTTP { _ in HTTPResponse(data: Data(captchaJSON.utf8), status: 200) }
        let g2 = MusixmatchGate(minInterval: 0)
        let p = MusixmatchLyricsProvider(http: http, gate: g2, token: store, apiHost: "https://mxm.test")
        let q = TrackQuery(title: "Синица", artist: "Тестовый Артист", duration: 200)
        let r = LyricsCoreSelfTest.await_ { () -> (Bool, Bool, Int, Bool) in
            let failed = (try? await p.response(for: q)) == nil
            let before = http.calls
            _ = try? await p.response(for: q)
            return (failed, await g2.isCoolingDown, http.calls - before, await p.isAvailable())
        }
        check(r.0 && r.1 && r.2 == 0 && !r.3 && store.current() == realToken,
              "Musixmatch: captcha с токеном — пауза часами, запросы в паузе в сеть не уходят, токен цел", "после паузы запросов: \(r.2)")
    }

    // MARK: Сквозной поиск на заглушке

    static func endToEnd(_ check: Check) {
        let macroCalls = Counter(), richCalls = Counter(), tokenCalls = Counter()
        let renewOnce = Counter()
        let http = StubHTTP { req in
            let path = req.url?.path ?? ""
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if path.hasSuffix("token.get") { tokenCalls.add(); return HTTPResponse(data: Data(tokenJSON.utf8), status: 200) }
            if path.hasSuffix("macro.subtitles.get") {
                // Первый ответ — «токен протух» (401 renew): провайдер обязан взять новый и повторить.
                if renewOnce.n == 0 { renewOnce.add(); return HTTPResponse(data: Data(renewJSON.utf8), status: 200) }
                macroCalls.add()
                let track = items.first { $0.name == "q_track" }?.value ?? ""
                return HTTPResponse(data: Data((track == "Синица" ? wordMacro : noneMacro).utf8), status: 200)
            }
            if path.hasSuffix("track.richsync.get") {
                richCalls.add()
                let ok = items.contains { $0.name == "commontrack_id" && $0.value == "22" }
                return HTTPResponse(data: Data((ok ? richsyncJSON : #"{"message":{"header":{"status_code":404}}}"#).utf8), status: 200)
            }
            return HTTPResponse(data: Data(), status: 404)
        }
        let store = MusixmatchToken(file: SecretFile(memoryOnly: true))
        store.set("old" + realToken)
        let gate = MusixmatchGate(minInterval: 0)
        let p = MusixmatchLyricsProvider(http: http, gate: gate, token: store, apiHost: "https://mxm.test")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-mxm-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LyricsService(cacheDir: dir, credentials: LyricsCoreSelfTest.noToken(), providers: [p])
        let q = LyricsService.Query(artist: "Тестовый Артист", title: "Синица (feat. Гость)", album: "", duration: 200.4)
        let r = LyricsCoreSelfTest.await_ { await svc.lookup(q) }
        check(r.provider == .musixmatch && r.lyrics?.wordSynced == true && r.lyrics?.source == "Musixmatch" && r.lyrics?.lines.count == 2
              && tokenCalls.n == 1 && macroCalls.n == 1 && richCalls.n == 1 && store.current() == realToken,
              "Musixmatch: сквозной поиск через каскад (протухший токен заменён, пословный richsync, подпись «Musixmatch»)",
              "\(r.outcomes.joined(separator: "; ")) token \(tokenCalls.n), macro \(macroCalls.n), richsync \(richCalls.n)")
        // Память ответов: тот же запрос к провайдеру — без сети.
        let tq = LyricsService.trackQuery(LyricsService.Query(artist: "echstacy", title: "all eyes on me", album: "", duration: 103))
        let n = LyricsCoreSelfTest.await_ { () -> (Int, Int, String?) in
            let a = try? await p.response(for: tq)
            let before = http.calls
            _ = try? await p.response(for: tq)
            return (a?.lyrics.count ?? -1, http.calls - before, a?.note)
        }
        check(n.0 == 0 && n.1 == 0, "Musixmatch: «нет текста» — пусто без сбоя, повтор из памяти без сети", "\(n.2 ?? "")")
        let callsBefore = http.calls
        let off = LyricsCoreSelfTest.await_ { await svc.lookup(q, sources: Set(LyricsSourceKind.allCases).subtracting([.musixmatch])) }
        check(off.lyrics == nil && http.calls == callsBefore, "Musixmatch: выключенный источник не спрашивается", off.outcomes.joined(separator: "; "))
    }

    // MARK: Сеть (`--selftest-media net`)

    /// Живой поиск у Musixmatch. Токен — сохранённый приложением (файл секретов, только чтение) или один `token.get`
    /// в памяти. Captcha / пауза — «пропущено», не FAIL. false — нет ответа вовсе.
    static func network(_ check: Check) -> Bool {
        let real = MusixmatchToken(file: SecretFile(migrateFromKeychain: false), writable: false)
        let store = real.current() != nil ? real : MusixmatchToken(file: SecretFile(memoryOnly: true))
        let from = real.current() != nil ? "сохранённый" : "новый в памяти"
        let p = MusixmatchLyricsProvider(http: URLSessionHTTPClient(timeout: 10, retries: 0), gate: MusixmatchGate(), token: store)
        typealias T = (TrackQuery, SyncType?)
        let cases: [T] = [
            (TrackQuery(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 200.04), .word),
            (TrackQuery(title: "Blessings", artist: "Big Sean", duration: 252), .word),
            (TrackQuery(title: "utopi", artist: "cruise lirro", duration: 190), SyncType.none),
            (TrackQuery(title: "TAMPON (feat. 163ONMYNECK)", artist: "SODA LUV", album: "НИЧЕГО ЛИЧНОГО 2 (DELUXE)", duration: 161.691), SyncType.none),
            (TrackQuery(title: "all eyes on me", artist: "echstacy", duration: 103), nil),
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
                print("skip Musixmatch «\(q.artist) — \(q.title)»: пропущено — \(e.description) (токен \(from), \(dt))")
                if case .rateLimited = e { return true }      // captcha/пауза: дальше не спрашиваем
            case .success(let resp):
                online = true
                let best = resp.lyrics.first
                let got = best.map { "\($0.syncType.rawValue), \($0.lines.count) строк, id \($0.source.trackID ?? "?")" } ?? "нет (\(resp.note ?? ""))"
                if let expect {
                    check(best.map { $0.syncType >= expect } ?? false,
                          "Musixmatch живьём «\(q.artist) — \(q.title)»: ожидалось ≥ \(expect.rawValue)", "\(got), \(dt)")
                } else {
                    print("info Musixmatch живьём «\(q.artist) — \(q.title)»: \(got) (ожидалось «нет»), \(dt)")
                }
            }
        }
        return online
    }

    // MARK: Заглушки

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return t }
            set { lock.lock(); t = newValue; lock.unlock() }
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var s: String
        init(_ s: String) { self.s = s }
        var v: String {
            get { lock.lock(); defer { lock.unlock() }; return s }
            set { lock.lock(); s = newValue; lock.unlock() }
        }
    }
}
